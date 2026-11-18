import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §2 — what the window says about the engine, in the spec's words:
/// "Starting the engine…"; "The engine stopped. Restarting…", and "From the
/// third such end the banner says how many there have been and shows the
/// console log's last lines"; "The engine isn't responding" with "Restart
/// the engine", "which says the screens go black for a moment and, while
/// the `saving` topic counts unsaved documents, that they will be lost";
/// and Quit's question (choice U-2).
@MainActor
final class EngineBannerTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_noBannerWhileTheEngineIsConnected() {
        XCTAssertNil(EngineBanner.make(for: .connected))
        XCTAssertNil(EngineBanner.make(for: .idle))
        XCTAssertNil(EngineBanner.make(for: .quitting))
    }

    func test_startingSaysSoAndOffersNothing() {
        XCTAssertEqual(EngineBanner.make(for: .starting), EngineBanner(text: "Starting the engine…", tone: .working, console: [], offersRestart: false))
    }

    func test_theEngineStoppedRestartsByItselfAndCountsFromTheThirdEnd() {
        XCTAssertEqual(EngineBanner.make(for: .restarting(ends: 1, console: [])),
                       EngineBanner(text: "The engine stopped. Restarting…", tone: .failure, console: [], offersRestart: false))
        XCTAssertEqual(EngineBanner.make(for: .restarting(ends: 2, console: []))?.text, "The engine stopped. Restarting…")
        let third = EngineBanner.make(for: .restarting(ends: 3, console: ["fatal: the GPU went away"]))
        XCTAssertEqual(third?.text, "The engine has stopped 3 times. Restarting…")
        XCTAssertEqual(third?.console, ["fatal: the GPU went away"], "so whoever is there can see why")
        XCTAssertEqual(third?.offersRestart, false, "it is being started again already")
    }

    func test_whatNeedsTheOperatorOffersRestartTheEngine() {
        XCTAssertEqual(EngineBanner.make(for: .notResponding), EngineBanner(text: "The engine isn’t responding", tone: .failure, console: [], offersRestart: true))
        XCTAssertEqual(EngineBanner.make(for: .noSocket(console: ["a line"])), EngineBanner(text: "The engine hasn’t opened its connection.", tone: .failure, console: ["a line"], offersRestart: true))
        XCTAssertEqual(EngineBanner.make(for: .noHello)?.offersRestart, true)
        let other = EngineBanner.make(for: .wrongAPI(engine: "0.9.0"))
        XCTAssertEqual(other?.text, "This engine is version 0.9.0 and speaks another version of the API, so Project O can’t drive it.")
        XCTAssertEqual(other?.offersRestart, true, "asks to restart it, the same way")
        XCTAssertEqual(EngineBanner.make(for: .firstRunRefused(console: []))?.offersRestart, false, "the setup sheet opens again instead")
    }

    func test_restartTheEngineSaysTheScreensGoBlackAndWhatWillBeLost() {
        XCTAssertEqual(RestartConfirmation.make(unsaved: 0), RestartConfirmation(title: "Restart the engine?", body: ["The screens go black for a moment."]))
        XCTAssertEqual(RestartConfirmation.make(unsaved: 3).body, ["The screens go black for a moment.", "3 changes aren’t saved yet and will be lost."])
        XCTAssertEqual(RestartConfirmation.make(unsaved: 1).body.last, "1 change isn’t saved yet and will be lost.")
    }

    /// Spec 10 §2, "Versions", as corrected on Adam's answer at Area 13's
    /// first stop, 2026-11-17 — "When the app finds an engine of another
    /// build running, as after Keep outputs running and an update, the
    /// banner says so and offers Restart the engine for as long as the
    /// builds differ, so the new build's Keychain prompt comes while
    /// someone is there (R2)." No sheet opens by itself: the banner
    /// interrupts nothing, and its button asks before it restarts.
    func test_anEngineOfAnotherBuildIsSaidInTheBannerWithRestartTheEngine() {
        let another = AnotherBuild(engine: "0.9.0", app: "1.0.0")
        XCTAssertEqual(EngineBanner.make(for: .connected, anotherBuild: another),
                       EngineBanner(text: "The engine running is version 0.9.0 and this is Project O 1.0.0. Restart it when the screens can go black for a moment.",
                                    tone: .notice, console: [], offersRestart: true))
        XCTAssertNil(EngineBanner.make(for: .connected, anotherBuild: nil), "the same build: no banner")
        XCTAssertEqual(EngineBanner.make(for: .starting, anotherBuild: another)?.text, "Starting the engine…", "while the engine is away the banner says that")
        XCTAssertEqual(EngineBanner.make(for: .notResponding, anotherBuild: another)?.text, "The engine isn’t responding")
    }

    func test_quitAsksWithItsThreeButtonsAndCountsWhatIsNotSaved() {
        let plain = QuitQuestion.make(unsaved: 0)
        XCTAssertEqual(plain.title, "Quit Project O? The outputs will stop.")
        XCTAssertNil(plain.detail)
        XCTAssertEqual([plain.quit, plain.keepOutputs, plain.cancel], ["Quit", "Keep outputs running", "Cancel"])
        XCTAssertEqual(QuitQuestion.make(unsaved: 3).detail, "3 changes aren’t saved yet")
    }

    func test_eachFirstRunProblemAndEachReasonHasItsSentence() {
        XCTAssertEqual(FirstRunWording.sentence(for: .campusMissing), "Enter the campus name.")
        XCTAssertEqual(FirstRunWording.sentence(for: .libraryPlace(.guardedFolder("Documents"))),
                       "The library can’t be in Documents, which macOS guards. Choose a folder outside Desktop, Documents and Downloads.")
        XCTAssertEqual(FirstRunWording.sentence(for: .machinePlace(.otherVolume)), "This Mac’s folder must be on its startup disk.")
        XCTAssertTrue(FirstRunWording.sentence(for: .socketPathTooLong(bytes: 131)).contains("131 bytes"))
        XCTAssertEqual(FirstRunWording.sentence(for: .noLibraryThere(found: [])), "That folder holds no library: there is no library.json in it.")
        XCTAssertEqual(FirstRunWording.sentence(for: .noLibraryThere(found: ["Budget.xlsx", "Photos"])),
                       "That folder holds no library: there is no library.json in it. It holds Budget.xlsx and Photos.")
        XCTAssertEqual(FirstRunWording.sentence(for: .machineInsideLibrary), "This Mac’s folder can’t be inside the library’s folder, which is synced.")
        for problem: FirstRunProblem in [.libraryPlace(.otherVolume), .libraryPlace(.notAbsolute), .machinePlace(.guardedFolder("Desktop")), .machinePlace(.notAbsolute)] {
            XCTAssertFalse(FirstRunWording.sentence(for: problem).contains("firstRun."), "\(problem) has a sentence")
        }
        XCTAssertEqual(UnavailableWording.sentence(for: .engineAway), "The engine is away.")
        XCTAssertEqual(UnavailableWording.sentence(for: .locked), "The station is locked.")
        XCTAssertEqual(UnavailableWording.sentence(for: .readOnlyMasters), "Masters are read-only on this Mac.")
    }
}
