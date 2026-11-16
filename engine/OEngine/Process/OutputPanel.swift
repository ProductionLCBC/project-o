// OEngine — Spec 10 §2, the window an output presents in.

import AppKit

/// Spec 10 §2, "The engine as a process" — "Its output windows sit at the
/// screen-saver window level as non-activating panels on every Space, which
/// stay put through Mission Control and Show Desktop: they never take the
/// keyboard or make the engine the active app, and they absorb the clicks
/// that land on them, so a click on an output never reaches a window beneath
/// it." Spec 4 §10 — "One borderless, opaque window per screen ... above
/// every other window but the few of the operator app's that must sit over an
/// output".
@MainActor
final class OutputPanel: NSPanel {
    /// "at the screen-saver window level": the app's confirmation sits one
    /// level above an output and its curtain one below (Spec 10 §2, §11).
    static let outputLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))

    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.outputLevel
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        // "they absorb the clicks that land on them": the panel takes mouse events and does nothing with them.
        ignoresMouseEvents = false
        // "on every Space, which stay put through Mission Control and Show Desktop".
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // An accessory process is never the active app, and a panel hides when its app isn't, unless told otherwise.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        contentView = OutputView(frame: CGRect(origin: .zero, size: frame.size))
    }

    /// "they never take the keyboard".
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Spec 10 §2 — "they absorb the clicks that land on them": the panel's
/// content view takes every mouse event and passes none on.
@MainActor
final class OutputView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
}
