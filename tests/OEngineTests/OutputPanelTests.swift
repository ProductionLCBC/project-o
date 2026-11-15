import AppKit
import Foundation
import XCTest
@testable import OEngine

/// Spec 10 §2, "The engine as a process" — "Its output windows sit at the
/// screen-saver window level as non-activating panels on every Space, which
/// stay put through Mission Control and Show Desktop: they never take the
/// keyboard or make the engine the active app, and they absorb the clicks
/// that land on them, so a click on an output never reaches a window beneath
/// it." Spec 10 §18, Area 19 — "a click on an output reaches no window
/// beneath it and never activates the engine". The panel is made and never
/// shown; what a click does on a screen is checked by hand with an engine
/// running (the brief says when).
@MainActor
final class OutputPanelTests: XCTestCase {
    /// Stands after the panel's view in the responder chain and records what reaches it.
    final class Beneath: NSResponder {
        var reached = 0
        override func mouseDown(with event: NSEvent) { reached += 1 }
        override func mouseUp(with event: NSEvent) { reached += 1 }
        override func rightMouseDown(with event: NSEvent) { reached += 1 }
        override func otherMouseDown(with event: NSEvent) { reached += 1 }
        override func scrollWheel(with event: NSEvent) { reached += 1 }
    }

    func panel() -> OutputPanel { OutputPanel(frame: CGRect(x: 0, y: 0, width: 640, height: 360)) }

    func test_itIsANonActivatingBorderlessPanelAtTheScreenSaverLevel() {
        let panel = panel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "a click never makes the engine the active app")
        XCTAssertFalse(panel.styleMask.contains(.titled))
        XCTAssertEqual(panel.level.rawValue, Int(CGWindowLevelForKey(.screenSaverWindow)), "the app's own windows sit one above and one below")
        XCTAssertTrue(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
    }

    func test_itNeverTakesTheKeyboard() {
        let panel = panel()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.contentView?.acceptsFirstResponder, false)
    }

    func test_itIsOnEverySpaceAndStaysPut() {
        let behavior = panel().collectionBehavior
        XCTAssertTrue(behavior.contains(.canJoinAllSpaces), "on every Space")
        XCTAssertTrue(behavior.contains(.stationary), "through Mission Control and Show Desktop")
        XCTAssertTrue(behavior.contains(.fullScreenAuxiliary), "over another app's full-screen Space")
        XCTAssertTrue(behavior.contains(.ignoresCycle))
    }

    func test_itStaysUpThoughTheEngineIsNeverTheActiveApp() {
        // A panel hides when its app isn't active unless told otherwise, and an accessory process never is.
        XCTAssertFalse(panel().hidesOnDeactivate)
    }

    func test_itTakesClicksAndPassesNoneOn() throws {
        let panel = panel()
        XCTAssertFalse(panel.ignoresMouseEvents, "a window that ignored the mouse would let a click through to the desktop beneath")
        let view = try XCTUnwrap(panel.contentView)
        XCTAssertTrue(view.hitTest(NSPoint(x: 10, y: 10)) === view, "every point of the output is the output's")
        XCTAssertTrue(view.acceptsFirstMouse(for: nil), "the first click is taken too, not spent on bringing a window forward")

        let beneath = Beneath()
        view.nextResponder = beneath
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown))
        view.mouseUp(with: try event(.leftMouseUp))
        view.rightMouseDown(with: try event(.rightMouseDown))
        view.otherMouseDown(with: try event(.otherMouseDown))
        XCTAssertEqual(beneath.reached, 0, "absorbed: nothing after the output in the chain hears of it")
    }
}
