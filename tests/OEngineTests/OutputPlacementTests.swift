import AppKit
import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §2, "The engine as a process" — "A display output whose screen
/// isn't there stays `absent` and opens when a screen with its id appears; it
/// never falls back to another screen." Spec 10 §9 — `releaseScreen` "takes
/// every output off the named screen for the rest of the run", and
/// `--released` keeps them closed from the start. Spec 10 §18, Area 19 — "A
/// display output whose screen is missing at launch is `absent` and opens
/// when that screen appears, never on another screen".
final class OutputPlacementTests: XCTestCase {
    static let wall = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
    static let side = "0A1B2C3D-0000-4000-8000-00000000000A"
    static let laptop = "FFFFFFFF-0000-4000-8000-00000000000F"

    func display(_ number: Int, _ uuid: String) -> Output {
        Output(number: number, defaultStack: 1, label: "Output \(number)", kind: .display, device: "display:" + uuid)
    }

    func screens(_ uuids: String...) -> [DetectedScreen] {
        uuids.enumerated().map { FakeDevices.screen($1, x: Double($0) * 1920) }
    }

    func test_anOutputGoesOnTheScreenItsDeviceNames() {
        let places = OutputPlacement.places(outputs: [display(1, Self.wall), display(2, Self.side)], screens: screens(Self.laptop, Self.side, Self.wall), released: [])
        XCTAssertEqual(places, [1: .screen(Self.wall), 2: .screen(Self.side)])
    }

    func test_anOutputWhoseScreenIsMissingIsAbsentAndNeverTakesAnotherScreen() {
        let outputs = [display(1, Self.wall), display(2, Self.side)]
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.laptop, Self.side), released: []),
                       [1: .absent, 2: .screen(Self.side)], "the laptop's screen is there and free, and output 1 doesn't take it")
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: [], released: []), [1: .absent, 2: .absent], "no screens at all is no error")
    }

    func test_itOpensWhenAScreenWithItsIdAppears() {
        let outputs = [display(1, Self.wall)]
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.laptop), released: [])[1], .absent)
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.laptop, Self.wall), released: [])[1], .screen(Self.wall))
    }

    func test_theIdIsMatchedWhateverItsCase() {
        let lower = Output(number: 1, defaultStack: 1, kind: .display, device: "display:" + Self.wall.lowercased())
        XCTAssertEqual(OutputPlacement.places(outputs: [lower], screens: screens(Self.wall), released: [])[1], .screen(Self.wall))
    }

    func test_aDeviceThatNamesNoDisplayIsAbsent() {
        // The spike fixture's placeholders name no display uuid, and an output with no device names nothing.
        let outputs = [Output(number: 1, defaultStack: 1, kind: .display, device: "display:main"), Output(number: 2, defaultStack: 1, kind: .display, device: "")]
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.wall, Self.laptop), released: []), [1: .absent, 2: .absent])
    }

    func test_onlyDisplayOutputsHaveAPlace() {
        let sdi = Output(number: 2, defaultStack: 1, kind: .sdi, device: "decklink:8f3a21c0")
        XCTAssertEqual(OutputPlacement.places(outputs: [display(1, Self.wall), sdi], screens: screens(Self.wall), released: []), [1: .screen(Self.wall)])
    }

    /// Spec 10 §9 — "takes every output off the named screen for the rest of
    /// the run"; Spec 10 §18 — "`releaseScreen` closes only that screen's
    /// outputs ... and `--released` keeps them closed from the start".
    func test_aReleasedScreenKeepsItsOutputsClosedAndNoOthers() {
        let outputs = [display(1, Self.wall), display(2, Self.laptop), display(3, Self.laptop)]
        let places = OutputPlacement.places(outputs: outputs, screens: screens(Self.wall, Self.laptop), released: [Self.laptop.lowercased()])
        XCTAssertEqual(places, [1: .screen(Self.wall), 2: .released, 3: .released])
        XCTAssertEqual(OutputPlacement.outputs(onScreen: Self.laptop, of: outputs), [2, 3], "what releaseScreen answers with")
        XCTAssertEqual(OutputPlacement.outputs(onScreen: Self.side, of: outputs), [])
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.wall), released: [Self.laptop])[2], .released,
                       "released stays released while its screen is away")
    }

    /// Spec 4 §2 — "Display outputs only: the primary output's CADisplayLink".
    func test_theClockIsTheLowestNumberedOutputWithAScreenElseTheTimer() {
        let outputs = [display(1, Self.wall), display(2, Self.side)]
        XCTAssertEqual(OutputPlacement.clockScreen(outputs: outputs, screens: screens(Self.side, Self.wall), released: []), Self.wall)
        XCTAssertEqual(OutputPlacement.clockScreen(outputs: outputs, screens: screens(Self.side), released: []), Self.side, "output 1 is absent")
        XCTAssertEqual(OutputPlacement.clockScreen(outputs: outputs, screens: screens(Self.side, Self.wall), released: [Self.wall]), Self.side)
        XCTAssertNil(OutputPlacement.clockScreen(outputs: outputs, screens: screens(Self.laptop), released: []), "no output has a screen: the timer")
        XCTAssertNil(OutputPlacement.clockScreen(outputs: [], screens: screens(Self.laptop), released: []), "a Mac with one screen and no outputs still runs")
    }

    // MARK: - The sink's state

    func test_aSinkStartedWithoutItsScreenIsAbsentAndOpensWhenItAppears() {
        var state = DisplaySinkState()
        XCTAssertEqual(state.standing, .absent, "before it starts")
        state.started(screenPresent: false)
        XCTAssertEqual(state.phase, .absent)
        XCTAssertEqual(state.standing, .absent)
        XCTAssertEqual(state.refresh(newestPublished: 5, elapsedTicks: 1, isComplete: { _ in true }), .skip, "nothing is presented anywhere")
        state.screenChanged(available: false)
        XCTAssertEqual(state.phase, .absent, "still not there")
        state.screenChanged(available: true)
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.standing, .presenting)
        XCTAssertEqual(state.refresh(newestPublished: 9, elapsedTicks: 1, isComplete: { _ in true }), .present(8), "one frame behind the newest, from its first refresh")
    }

    func test_aScreenThatGoesPausesAndOneThatReturnsResumesFromTheNewestFrame() {
        var state = DisplaySinkState()
        state.started(screenPresent: true)
        XCTAssertEqual(state.standing, .presenting)
        XCTAssertEqual(state.refresh(newestPublished: 2, elapsedTicks: 1, isComplete: { _ in true }), .present(1))
        state.screenChanged(available: false)
        XCTAssertEqual(state.standing, .paused)
        state.screenChanged(available: true)
        XCTAssertEqual(state.standing, .presenting)
        // A long time away: what was due when it went is not what shows when it is back.
        XCTAssertEqual(state.refresh(newestPublished: 600, elapsedTicks: 1, isComplete: { _ in true }), .present(599))
        XCTAssertEqual(state.presented, 2, "the counts carry on")
    }

    func test_aReleasedSinkStaysReleasedWhateverTheScreensDo() {
        var state = DisplaySinkState()
        state.started(screenPresent: true)
        state.released()
        XCTAssertEqual(state.standing, .released)
        state.screenChanged(available: false)
        state.screenChanged(available: true)
        XCTAssertEqual(state.phase, .released)
        XCTAssertEqual(state.refresh(newestPublished: 5, elapsedTicks: 1, isComplete: { _ in true }), .skip)

        // `--released`: released before it starts, it never opens.
        var early = DisplaySinkState()
        early.released()
        early.started(screenPresent: true)
        XCTAssertEqual(early.phase, .released)
    }

    /// Spec 10 §9 as corrected 2026-11-24 — "Put Back on This Screen sends `retakeScreen` with it: the engine opens those
    /// outputs' windows again, reports them `presenting`". A released sink is `absent` again, and its screen opens it.
    func test_aReleasedSinkPutBackOpensOnItsScreenAgain() {
        var state = DisplaySinkState()
        state.started(screenPresent: true)
        _ = state.refresh(newestPublished: 3, elapsedTicks: 1, isComplete: { _ in true })
        state.released()
        state.retaken()
        XCTAssertEqual(state.phase, .absent)
        state.screenChanged(available: true)
        XCTAssertEqual(state.standing, .presenting)
        XCTAssertEqual(state.refresh(newestPublished: 900, elapsedTicks: 1, isComplete: { _ in true }), .present(899),
                       "from the newest frame, one behind, as a screen that comes back")
        // Only a released sink is put back: a running one stays as it is.
        var running = DisplaySinkState()
        running.started(screenPresent: true)
        running.retaken()
        XCTAssertEqual(running.phase, .running)
        // OutputPlacement places it on its screen once the screen is no longer released.
        let outputs = [display(1, Self.wall)]
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.wall), released: [Self.wall])[1], .released)
        XCTAssertEqual(OutputPlacement.places(outputs: outputs, screens: screens(Self.wall), released: [])[1], .screen(Self.wall))
    }

    /// The real sink, with no screen to give it: it starts, is `absent`, and
    /// opens no window. Needs a Metal device for its command queue.
    @MainActor
    func test_aRealSinkWithNoScreenStartsAbsentAndCanBeReleased() throws {
        let backend = try MetalHarness.backend()
        let sink = DisplaySink(output: 7, device: "display:" + Self.wall, backend: backend, log: EngineLog(category: "test-sink"))
        XCTAssertEqual(sink.screenUUID, Self.wall)
        sink.place(on: nil)
        try sink.start()
        XCTAssertEqual(sink.currentState.phase, .absent)
        XCTAssertEqual(sink.standing, .absent)
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OutputPanel }, "no window anywhere")
        sink.place(on: nil)
        XCTAssertEqual(sink.standing, .absent)
        sink.release()
        XCTAssertEqual(sink.standing, .released)
        // Put back, with still no screen: `absent`, waiting for it, and no window.
        sink.retake()
        XCTAssertEqual(sink.standing, .absent)
        sink.place(on: nil)
        XCTAssertFalse(NSApplication.shared.windows.contains { $0 is OutputPanel })
        sink.stop()
    }
}
