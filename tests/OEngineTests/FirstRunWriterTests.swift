import Foundation
import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 10 §13, "The engine writes the defaults (C1: the app never writes in
/// the roots)" — "when the library root has no `library.json`, it writes the
/// first-run library ... When the machine root has no `machine.json`, it
/// writes [the machine's documents] ... A machine root with `machine.json`
/// but a library root without `library.json`, or the other way round, gets
/// only the missing side." Spec 10 §18, Area 19, first run: "The engine
/// writes §13's defaults once and never over existing files".
///
/// What the documents hold is `FirstRunDocumentTests`' (OCoreTests); here they
/// reach the disk, in temporary folders, from a device list the test gives.
final class FirstRunWriterTests: XCTestCase {
    var folder: URL!
    var library: URL { folder.appendingPathComponent("library") }
    var machine: URL { folder.appendingPathComponent("machine") }

    override func setUpWithError() throws {
        folder = try ShortFolder.make()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A laptop holding the app's window, a wall display and the laptop's speakers.
    let devices = DetectedDevices(
        screens: [
            DetectedScreen(device: "display:0A0A0A0A-0000-4000-8000-000000000001", name: "Built-in Retina Display",
                           frame: ScreenFrame(x: 0, y: 0, width: 1512, height: 982), mode: VideoFormat(width: 3024, height: 1964, rate: FrameRate(num: 120))),
            DetectedScreen(device: "display:0B0B0B0B-0000-4000-8000-000000000002", name: "DELL U2720Q",
                           frame: ScreenFrame(x: 1512, y: 0, width: 1920, height: 1080), mode: VideoFormat(width: 3840, height: 2160, rate: FrameRate(num: 60))),
        ],
        audio: [DetectedAudioDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", channels: 2, isDefault: true)])
    let ownScreen = "display:0A0A0A0A-0000-4000-8000-000000000001"

    func request(campus: String? = "Manheim", operatorScreen: String?? = .none) -> FirstRunWriter.Request {
        FirstRunWriter.Request(libraryRoot: library, machineRoot: machine, campus: campus,
                               operatorScreen: operatorScreen ?? ownScreen, timeZone: "America/Chicago")
    }

    /// Every file under a folder with its bytes, by relative path.
    func contents(of root: URL) -> [String: Data] {
        var found: [String: Data] = [:]
        let prefix = root.standardizedFileURL.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return found }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            found[String(url.standardizedFileURL.path.dropFirst(prefix.count))] = try? Data(contentsOf: url)
        }
        return found
    }

    func copyFixture(library: Bool, machine: Bool) throws {
        if library { try FileManager.default.copyItem(at: EngineFixtures.libraryRoot, to: self.library) }
        if machine { try FileManager.default.copyItem(at: EngineFixtures.machineRoot, to: self.machine) }
    }

    func written(_ outcome: FirstRunWriter.Outcome, file: StaticString = #filePath, line: UInt = #line) throws -> FirstRunWriter.Written {
        guard case .wrote(let written) = outcome else {
            XCTFail("first run wrote nothing: \(outcome)", file: file, line: line)
            throw XCTSkip("no result to read")
        }
        return written
    }

    // MARK: - A fresh install

    func test_aFreshInstallGetsBothSidesAndTheyLoadCleanly() throws {
        let result = try written(FirstRunWriter.run(request(), devices: { self.devices }))
        XCTAssertEqual(result.library.sorted(), ["audio-transitions.json", "channels.json", "grades.json", "library.json", "media-index.json",
                                                 "presets/001-default.json", "presets/002-clock.json", "text-styles.json", "transitions.json"])
        XCTAssertEqual(result.machine.sorted(), ["audio-outputs.json", "clocks.json", "inputs.json", "keys.json", "machine.json", "media-local.json",
                                                 "outputs.json", "stacks.json"])
        XCTAssertEqual(result.kept, [])
        XCTAssertEqual(result.library.last, "library.json", "the side's own document goes last, so a launch cut short is finished by the next")
        XCTAssertEqual(result.machine.last, "machine.json")
        // "`media/` with `imports/` as the default import folder and `fonts/`".
        var isFolder: ObjCBool = false
        for name in ["media/imports", "media/fonts"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent(name).path, isDirectory: &isFolder) && isFolder.boolValue, name)
        }
        XCTAssertEqual(Set(contents(of: library).keys), Set(result.library), "the documents and nothing else")
        XCTAssertEqual(Set(contents(of: machine).keys), Set(result.machine))

        // What it wrote is what the engine loads, with nothing to report.
        let roots = try LoadedRoots.load(libraryRoot: library, machineRoot: machine)
        XCTAssertEqual(roots.issueLines, [], "the first-run roots load cleanly")
        XCTAssertFalse(roots.hasErrors)
        XCTAssertEqual(roots.library.info.name, "Manheim Library", "named for its campus")
        XCTAssertEqual(roots.library.channels.map(\.label), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(roots.library.channels.map(\.renderSize), [.largest, .largest, .largest])
        XCTAssertEqual(roots.library.presets.map(\.label), ["Default", "Clock"])
        XCTAssertEqual(roots.machine.settings.campusName, "Manheim")
        XCTAssertEqual(roots.machine.settings.timeZone, "America/Chicago")
        XCTAssertEqual(roots.machine.settings.libraryMode, .writable)
        XCTAssertEqual(roots.machine.settings.mediaRoot, "../library/media", "the path from the machine root to the library's media")
        XCTAssertEqual(roots.machine.outputs.map(\.label), ["DELL U2720Q"], "the wall, and never the screen with the app's window")
        XCTAssertEqual(roots.machine.outputs.map(\.device), ["display:0B0B0B0B-0000-4000-8000-000000000002"])
        XCTAssertEqual(roots.machine.stacks.map(\.label), ["Main", "Confidence"])
        XCTAssertEqual(roots.machine.audioOutputs.map(\.device), [.uid("BuiltInSpeakerDevice")])
        XCTAssertEqual(roots.machine.keys.map(\.key), ["space", "right", "left", "shift+escape"])
        XCTAssertEqual(result.outputs.map(\.number), [1])
        XCTAssertTrue(FirstRunWriter.lines(result, request: request()).contains("first run: output 1 is DELL U2720Q"), "each new output is named")

        // "once": the next launch finds both sides and writes nothing.
        let before = contents(of: folder)
        XCTAssertEqual(FirstRunWriter.run(request(), devices: { XCTFail("the devices aren't read again"); return self.devices }), .nothing)
        XCTAssertEqual(contents(of: folder), before)
    }

    func test_twoInstallsAreTwoLibrariesAndTwoMachines() throws {
        _ = try written(FirstRunWriter.run(request(), devices: { self.devices }))
        let first = try LoadedRoots.load(libraryRoot: library, machineRoot: machine)
        let other = try ShortFolder.make()
        defer { try? FileManager.default.removeItem(at: other) }
        let second = FirstRunWriter.Request(libraryRoot: other.appendingPathComponent("library"), machineRoot: other.appendingPathComponent("machine"),
                                            campus: "Harrisburg", operatorScreen: ownScreen, timeZone: "America/New_York")
        _ = try written(FirstRunWriter.run(second, devices: { self.devices }))
        let another = try LoadedRoots.load(libraryRoot: second.libraryRoot, machineRoot: second.machineRoot)
        XCTAssertNotEqual(first.library.info.uuid, another.library.info.uuid)
        XCTAssertNotEqual(first.machine.settings.uuid, another.machine.settings.uuid, "the machine's uuid names its Keychain items and its engine")
        XCTAssertEqual(first.library.preset(1)?.uuid, another.library.preset(1)?.uuid, "the built-ins are the same everywhere")
    }

    // MARK: - One side only

    func test_nothingIsWrittenWhenBothSidesExist() throws {
        try copyFixture(library: true, machine: true)
        let before = contents(of: folder)
        XCTAssertEqual(FirstRunWriter.run(request(), devices: { XCTFail("no device is read"); return self.devices }), .nothing)
        XCTAssertEqual(contents(of: folder), before, "not a byte")
        XCTAssertNil(FirstRunWriter.refusal(request(campus: nil, operatorScreen: .some(nil))), "and such a launch needs neither option")
    }

    /// "A machine root with `machine.json` but a library root without `library.json` ... gets only the missing side."
    func test_aMachineWithoutALibraryGetsOnlyTheLibraryNamedForTheMachinesCampus() throws {
        try copyFixture(library: false, machine: true)
        let before = contents(of: machine)
        // Writing only the library side needs neither option (Adam's answer of 2026-11-15).
        let bare = request(campus: nil, operatorScreen: .some(nil))
        XCTAssertNil(FirstRunWriter.refusal(bare))
        let result = try written(FirstRunWriter.run(bare, devices: { XCTFail("no device is read for the library"); return self.devices }))
        XCTAssertEqual(result.machine, [])
        XCTAssertEqual(result.library.count, 9)
        XCTAssertEqual(contents(of: machine), before, "the machine is as it was")
        let made = Loader.library(from: try LocalFiles.snapshot(ofRoot: library))
        XCTAssertEqual(made.report.issues, [])
        XCTAssertEqual(made.library.info.name, "Manheim Library", "the fixture machine's campus is Manheim")
    }

    /// "or the other way round": a library that is already there, such as one
    /// synced from central, and a machine root elsewhere.
    func test_aLibraryThatIsAlreadyThereGetsAMachineWhoseMediaRootReachesIt() throws {
        let central = folder.appendingPathComponent("Central/LCBC Library")
        try FileManager.default.createDirectory(at: central.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: EngineFixtures.libraryRoot, to: central)
        let before = contents(of: central)
        var picked = request()
        picked.libraryRoot = central
        let result = try written(FirstRunWriter.run(picked, devices: { self.devices }))
        XCTAssertEqual(result.library, [], "a library that is there never gets a first-run library")
        XCTAssertEqual(result.machine.count, 8)
        XCTAssertEqual(contents(of: central), before)
        let roots = try LoadedRoots.load(libraryRoot: central, machineRoot: machine)
        XCTAssertEqual(roots.machine.settings.mediaRoot, "../Central/LCBC Library/media")
        XCTAssertFalse(roots.hasErrors, roots.issueLines.joined(separator: "\n"))
        XCTAssertEqual(roots.library.info.name, "LCBC Library", "the library keeps its own name")
        XCTAssertFalse(roots.mediaIDs.isEmpty, "and its media is found through the machine's mediaRoot")
    }

    func test_theMediaRootIsThePathBetweenTheRoots() {
        func path(_ machine: String, _ library: String) -> String {
            FirstRunWriter.relativePath(from: URL(fileURLWithPath: machine), to: URL(fileURLWithPath: library).appendingPathComponent("media"))
        }
        XCTAssertEqual(path("/Users/av/Project O/machine", "/Users/av/Project O/library"), "../library/media", "the default layout")
        XCTAssertEqual(path("/Users/av/Project O/machine", "/Users/Shared/Central/Library"), "../../../Shared/Central/Library/media")
        XCTAssertEqual(path("/Users/av/Project O/machine/", "/Users/av/Project O/machine/library"), "library/media")
        XCTAssertEqual(path("/a/machine", "/b/library"), "../../b/library/media")
    }

    // MARK: - Never over an existing file

    func test_aDocumentThatIsThereIsLeftAsItIsAndTheRestAreWritten() throws {
        // A library root with a channels.json of someone's own and no library.json, as a launch cut short would leave it.
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let own = Data("{ \"app\": \"0.1.0\", \"channels\": [], \"kind\": \"channels\", \"schema\": 1 }\n".utf8)
        try own.write(to: library.appendingPathComponent("channels.json"))
        let result = try written(FirstRunWriter.run(request(), devices: { self.devices }))
        XCTAssertEqual(result.kept, ["channels.json"])
        XCTAssertFalse(result.library.contains("channels.json"))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("channels.json")), own, "never written over")
        XCTAssertTrue(result.library.contains("library.json"), "and the side is finished")
        XCTAssertTrue(FirstRunWriter.lines(result, request: request()).contains("first run: channels.json was already there and was left as it was"))
        XCTAssertEqual(FirstRunWriter.run(request(), devices: { self.devices }), .nothing, "done: the next launch writes nothing")
    }

    // MARK: - A launch without the options

    /// Adam's answer of 2026-11-15 — "A hand launch without the flags is
    /// refused ... the engine writes nothing and exits with a line saying
    /// first run needs both."
    func test_withoutTheCampusAndTheAppsScreenAFreshMachineIsRefusedAndNothingIsWritten() throws {
        for bare in [request(campus: nil), request(operatorScreen: .some(nil)), request(campus: nil, operatorScreen: .some(nil)), request(campus: "")] {
            let refusal = try XCTUnwrap(FirstRunWriter.refusal(bare))
            XCTAssertTrue(refusal.contains("--campus") && refusal.contains("--operator-screen"), refusal)
            guard case .refused = FirstRunWriter.run(bare, devices: { XCTFail("no device is read"); return self.devices }) else { return XCTFail("refused") }
        }
        XCTAssertEqual(contents(of: folder), [:], "nothing was written: not the library either")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        // A screen that isn't named as one is refused too.
        let wrong = try XCTUnwrap(FirstRunWriter.refusal(request(operatorScreen: .some("main"))))
        XCTAssertTrue(wrong.contains("display:<uuid>"), wrong)
    }

    /// The same through the command line: status 2, and the machine root the lock would have made is gone again.
    func test_theCommandLineRefusesAHandLaunchOnAFreshRootAndLeavesNothingBehind() throws {
        let fresh = folder.appendingPathComponent("Project O")
        let status = OEngineCommandLine.run(arguments: ["run", "--library", fresh.appendingPathComponent("library").path,
                                                        "--machine", fresh.appendingPathComponent("machine").path, "--no-lan"])
        XCTAssertEqual(status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "no folder, no lock file, no document")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
