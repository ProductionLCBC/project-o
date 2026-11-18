import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §13, "The roots" — "a sheet asks for the campus name and where to
/// keep the library, with `~/Project O/` as the default ... Both places must
/// be on the startup volume, outside Desktop, Documents and Downloads (Spec
/// 8 §2), and short enough for the socket (§2)." The checks the sheet makes
/// before any engine is started (Area 19 reading: the place is the app's to
/// check).
final class FirstRunCheckTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/operator")
    private var places: MediaPlaces {
        MediaPlaces(home: "/Users/operator", isOnStartupVolume: { !$0.hasPrefix("/Volumes/") })
    }

    private func problems(_ choice: FirstRunChoice, holding: [String: [String]] = [:]) -> [FirstRunProblem] {
        FirstRunCheck.problems(with: choice, places: places) { holding[$0.path] }
    }

    func test_theDefaultPutsBothRootsInProjectOInTheHomeFolder() {
        let choice = FirstRunChoice(campus: "Manheim", place: .new(folder: FirstRunChoice.defaultFolder(home: home)))
        XCTAssertEqual(choice.roots.library.path, "/Users/operator/Project O/library")
        XCTAssertEqual(choice.roots.machine.path, "/Users/operator/Project O/machine")
        XCTAssertEqual(choice.roots.socket.path, "/Users/operator/Project O/machine/engine.sock")
        XCTAssertEqual(problems(choice), [])
        XCTAssertEqual(FirstRunChoice.defaultMachineRoot(home: home).path, "/Users/operator/Project O/machine")
    }

    func test_aCampusNameIsAskedFor() {
        let choice = FirstRunChoice(campus: "   ", place: .new(folder: FirstRunChoice.defaultFolder(home: home)))
        XCTAssertEqual(problems(choice), [.campusMissing])
    }

    func test_aPlaceMacOSGuardsOrOffTheStartupVolumeIsRefused() {
        let documents = FirstRunChoice(campus: "Manheim", place: .new(folder: home.appendingPathComponent("Documents/Project O")))
        XCTAssertEqual(problems(documents), [.libraryPlace(.guardedFolder("Documents")), .machinePlace(.guardedFolder("Documents"))])
        let drive = FirstRunChoice(campus: "Manheim", place: .new(folder: URL(fileURLWithPath: "/Volumes/Show Drive/Project O")))
        XCTAssertEqual(problems(drive), [.libraryPlace(.otherVolume), .machinePlace(.otherVolume)])
    }

    func test_aPlaceTooDeepForTheSocketIsRefusedWithTheBytesItWouldTake() {
        let deep = home.appendingPathComponent(String(repeating: "a-long-folder-name/", count: 5) + "Project O")
        let choice = FirstRunChoice(campus: "Manheim", place: .new(folder: deep))
        let socket = choice.roots.socket.path.utf8.count
        XCTAssertGreaterThan(socket, 103)
        XCTAssertEqual(problems(choice), [.socketPathTooLong(bytes: socket)])
    }

    func test_aLibraryAlreadyThereMustHoldLibraryJsonAndTheSheetSaysWhatItFound() {
        let synced = home.appendingPathComponent("Synced/LCBC Library")
        let machine = FirstRunChoice.defaultMachineRoot(home: home)
        let choice = FirstRunChoice(campus: "Manheim", place: .existing(library: synced, machine: machine))
        XCTAssertEqual(problems(choice, holding: [synced.path: ["library.json", "lists", "media"]]), [])
        XCTAssertEqual(problems(choice, holding: [synced.path: [".DS_Store", "Photos", "Budget.xlsx"]]), [.noLibraryThere(found: ["Budget.xlsx", "Photos"])],
                       "so a wrong folder never gets a first-run library")
        XCTAssertEqual(problems(choice), [.noLibraryThere(found: [])], "a folder that isn't there holds no library either")
    }

    func test_theMachineRootNeverGoesInsideTheSyncedFolder() {
        let synced = home.appendingPathComponent("Synced/LCBC Library")
        let inside = FirstRunChoice(campus: "Manheim", place: .existing(library: synced, machine: synced.appendingPathComponent("machine")))
        XCTAssertEqual(problems(inside, holding: [synced.path: ["library.json"]]), [.machineInsideLibrary])
        let beside = FirstRunChoice(campus: "Manheim", place: .existing(library: synced, machine: home.appendingPathComponent("Synced/LCBC Library machine")))
        XCTAssertEqual(problems(beside, holding: [synced.path: ["library.json"]]), [], "a folder whose name only starts the same isn't inside it")
    }
}

/// Spec 10 §2, "When the engine stops" — "a black, borderless curtain ... on
/// the screen of each display output other than the main window's". Spec 10
/// §2, "When an output covers the app", and §18 — "while an output covers
/// the window, presses in it do nothing, but with the window raised ... a
/// click on Restart the engine restarts it, and with the engine gone the
/// window takes clicks."
final class ScreensTests: XCTestCase {
    private func output(_ number: Int, _ device: String, kind: String = "display") throws -> Output {
        try JSONCoding.decode(Output.self, from: .object([
            "number": .number(Double(number)), "label": .string("Output \(number)"), "kind": .string(kind), "device": .string(device),
            "defaultStack": .number(1), "uuid": .string("0d7d0000-0000-4000-8000-00000000000\(number)"), "colorRange": .string("full"),
            "format": .object(["width": .number(1920), "height": .number(1080), "interlaced": .bool(false), "rate": .object(["num": .number(60), "den": .number(1)])]),
            "transitions": .object(["switch": .number(1), "blackout": .number(2)]), "genlock": .null, "keyFillPartner": .null, "keyMode": .string("shaped"),
        ]))
    }

    private func situation(window: String? = "display:OPERATOR", released: Set<String> = [], states: [Int: String] = [1: "presenting", 2: "presenting", 3: "presenting"]) throws -> ScreenSituation {
        let outputs = [try output(1, "display:WALL"), try output(2, "display:CONFIDENCE"), try output(3, "decklink:1", kind: "sdi")]
        var statuses: [Int: OutputStatus] = [:]
        for (number, state) in states { statuses[number] = OutputStatus(number: number, stack: 1, state: state) }
        return ScreenSituation(outputs: outputs, statuses: statuses, screens: ["display:OPERATOR", "display:WALL", "display:CONFIDENCE"],
                               windowScreen: window, released: released)
    }

    func test_everyDisplayOutputsScreenButTheWindowsGetsACurtain() throws {
        XCTAssertEqual(CurtainPlan.screens(in: try situation()), ["display:WALL", "display:CONFIDENCE"], "and a card's output has no screen to curtain")
        XCTAssertEqual(CurtainPlan.screens(in: try situation(window: "display:CONFIDENCE")), ["display:WALL"], "never the main window's own screen")
    }

    func test_aScreenThatIsNotThereOrThatWasReleasedGetsNone() throws {
        var unplugged = try situation()
        unplugged.screens = ["display:OPERATOR", "display:WALL"]
        XCTAssertEqual(CurtainPlan.screens(in: unplugged), ["display:WALL"])
        XCTAssertEqual(CurtainPlan.screens(in: try situation(released: ["display:WALL"])), ["display:CONFIDENCE"], "a released screen is the operator's again")
    }

    func test_anOutputPresentingOnTheWindowsScreenCoversItWhileTheEngineIsConnected() throws {
        let behind = try situation(window: "display:CONFIDENCE")
        XCTAssertEqual(CoveredWindow.coveringOutput(in: behind, connected: true), 2, "Project O is behind output 2")
        XCTAssertFalse(CoveredWindow.takesClicks(in: behind, connected: true, raised: false), "presses in it do nothing")
        XCTAssertTrue(CoveredWindow.takesClicks(in: behind, connected: true, raised: true), "raised over the outputs, it takes clicks")
        XCTAssertTrue(CoveredWindow.takesClicks(in: behind, connected: false, raised: false), "with the engine gone the window takes clicks")
        XCTAssertNil(CoveredWindow.coveringOutput(in: behind, connected: false))
    }

    func test_anOutputThatIsNotPresentingCoversNothing() throws {
        let clear = try situation()
        XCTAssertNil(CoveredWindow.coveringOutput(in: clear, connected: true))
        XCTAssertTrue(CoveredWindow.takesClicks(in: clear, connected: true, raised: false))
        for state in ["released", "absent", "paused"] {
            let other = try situation(window: "display:WALL", states: [1: state, 2: "presenting"])
            XCTAssertNil(CoveredWindow.coveringOutput(in: other, connected: true), "an output that is \(state) has no window on the screen")
        }
    }
}
