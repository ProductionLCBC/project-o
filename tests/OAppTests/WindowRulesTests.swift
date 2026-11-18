import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §6, "The divider" — "snaps to three states (UX spec): collapsed,
/// which shows the pool's header and one strip of the twenty most recently
/// used items, so drag-to-channel still works; default, about a third of the
/// center; and expanded. Double-click toggles collapsed and default."
final class PoolDividerTests: XCTestCase {
    func test_eachStateHasItsHeight() {
        XCTAssertEqual(PoolDivider.height(.collapsed, center: 900, collapsed: 150), 150, "its header and one strip")
        XCTAssertEqual(PoolDivider.height(.default, center: 900, collapsed: 150), 300, "about a third of the center")
        XCTAssertEqual(PoolDivider.height(.expanded, center: 900, collapsed: 150), 540)
        XCTAssertEqual(PoolDivider.height(.default, center: 300, collapsed: 150), 180, "never so small that a row of tiles doesn't show")
    }

    func test_aDragSnapsToTheNearestOfTheThreeStates() {
        XCTAssertEqual(PoolDivider.snap(height: 160, center: 900, collapsed: 150), .collapsed)
        XCTAssertEqual(PoolDivider.snap(height: 240, center: 900, collapsed: 150), .default)
        XCTAssertEqual(PoolDivider.snap(height: 410, center: 900, collapsed: 150), .default)
        XCTAssertEqual(PoolDivider.snap(height: 430, center: 900, collapsed: 150), .expanded)
        XCTAssertEqual(PoolDivider.snap(height: 2000, center: 900, collapsed: 150), .expanded)
        XCTAssertEqual(PoolDivider.snap(height: 0, center: 900, collapsed: 150), .collapsed)
    }

    func test_aDoubleClickTogglesCollapsedAndDefault() {
        XCTAssertEqual(PoolDivider.toggled(.collapsed), .default)
        XCTAssertEqual(PoolDivider.toggled(.default), .collapsed)
        XCTAssertEqual(PoolDivider.toggled(.expanded), .collapsed, "from expanded it folds away, as from default")
    }
}

/// Spec 10 §4, "One main window" — "The app opens it on a screen no output
/// uses, and moves it to one when it ends up on an output's screen, moved by
/// hand or by a change of screens, if such a screen exists."
final class WindowPlacementTests: XCTestCase {
    private let builtIn = WindowPlacement.Screen(name: "display:BUILTIN", area: 2240 * 1260)
    private let side = WindowPlacement.Screen(name: "display:SIDE", area: 1920 * 1080)
    private let wall = WindowPlacement.Screen(name: "display:WALL", area: 3840 * 2160)

    func test_aWindowOnAScreenNoOutputUsesStaysWhereItIs() {
        XCTAssertNil(WindowPlacement.target(window: "display:BUILTIN", screens: [builtIn, side], outputs: ["display:SIDE"]))
        XCTAssertNil(WindowPlacement.target(window: "display:BUILTIN", screens: [builtIn], outputs: []))
    }

    func test_aWindowOnAnOutputsScreenMovesToOneNoOutputUses() {
        XCTAssertEqual(WindowPlacement.target(window: "display:SIDE", screens: [builtIn, side], outputs: ["display:SIDE"]), "display:BUILTIN")
    }

    func test_ofSeveralFreeScreensItTakesTheLargest() {
        // Area 13 reading — the largest screen no output uses.
        XCTAssertEqual(WindowPlacement.target(window: "display:SIDE", screens: [side, builtIn, wall], outputs: ["display:SIDE"]), "display:WALL")
        XCTAssertEqual(WindowPlacement.target(window: "display:SIDE", screens: [side, builtIn, wall], outputs: ["display:SIDE", "display:WALL"]), "display:BUILTIN")
    }

    func test_whenEveryScreenIsAnOutputsItStays() {
        XCTAssertNil(WindowPlacement.target(window: "display:SIDE", screens: [builtIn, side], outputs: ["display:SIDE", "display:BUILTIN"]),
                     "if such a screen exists")
        XCTAssertNil(WindowPlacement.target(window: nil, screens: [builtIn, side], outputs: ["display:SIDE"]), "a window on no screen yet is left to open")
    }

    func test_theOutputsScreensAreThoseOfItsDisplayOutputsThatAreNotReleased() {
        let outputs = [Output(number: 1, defaultStack: 1, label: "Main", kind: .display, device: "display:SIDE"),
                       Output(number: 2, defaultStack: 1, label: "SDI", kind: .sdi, device: "decklink:8f3a"),
                       Output(number: 3, defaultStack: 1, label: "Lobby", kind: .display, device: "display:WALL")]
        XCTAssertEqual(WindowPlacement.outputScreens(outputs, released: []), ["display:SIDE", "display:WALL"])
        XCTAssertEqual(WindowPlacement.outputScreens(outputs, released: ["display:WALL"]), ["display:SIDE"], "a released screen is no output's any more")
    }
}

/// Spec 10 §8 — "A click opens the output's details (its device, format,
/// reference, state, and its presented, late and dropped counts from
/// `metrics`) with a Stack ▸ menu that switches its live stack".
final class OutputDetailsTests: XCTestCase {
    private func metrics(_ outputs: [[String: JSONValue]]) -> [String: JSONValue] {
        ["topic": .string("metrics"), "outputs": .array(outputs.map(JSONValue.object))]
    }

    func test_theDetailsNameTheDeviceTheFormatTheStateAndTheCounts() throws {
        let catalog = try Recorded.catalog()
        let output = try XCTUnwrap(catalog.outputs.first)
        let dot = OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false)
        let devices = DetectedDevices(screens: [DetectedScreen(device: output.device, name: "V247Y E", frame: ScreenFrame(x: 0, y: 0, width: 1920, height: 1080),
                                                               mode: output.format, mirrored: false)], ports: [], audio: [])
        let details = OutputDetails.make(output: output, dot: dot, status: OutputStatus(number: 1, stack: 1, state: "presenting"), devices: devices,
                                         metrics: metrics([["output": .number(1), "presented": .number(12_601), "displayedLate": .number(3), "dropped": .number(0)]]))
        XCTAssertEqual(details.device, "V247Y E", "the device by its name")
        XCTAssertEqual(details.format, output.format)
        XCTAssertNil(details.reference, "a display has no reference")
        XCTAssertEqual(details.state, .presenting)
        XCTAssertEqual(details.stack, 1)
        XCTAssertEqual(details.presented, 12_601)
        XCTAssertEqual(details.late, 3)
        XCTAssertEqual(details.dropped, 0)
    }

    func test_aDeviceThatIsNotThereIsNamedByItsIdAndCountsWaitForMetrics() throws {
        let sdi = Output(number: 2, defaultStack: 1, label: "Program SDI", kind: .sdi, device: "decklink:8f3a21c0")
        let dot = OutputDot(number: 2, label: "Program SDI", stack: 1, state: .absent, isBlackedOut: false)
        let details = OutputDetails.make(output: sdi, dot: dot, status: OutputStatus(number: 2, stack: 1, state: "absent", reference: "freeRun"), devices: nil, metrics: nil)
        XCTAssertEqual(details.device, "decklink:8f3a21c0")
        XCTAssertEqual(details.reference, "freeRun")
        XCTAssertEqual(details.state, .absent)
        XCTAssertNil(details.presented, "no count until a metrics event names the output")
        XCTAssertNil(OutputDetails.make(output: sdi, dot: dot, status: nil, devices: nil, metrics: metrics([["output": .number(1), "presented": .number(5)]])).presented)
    }
}
