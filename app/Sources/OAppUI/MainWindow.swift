// OAppUI — Spec 10 §4, the one main window, and Spec 10 §2, what it does while an output covers it.

import AppKit
import OApp

/// Spec 10 §2, "When an output covers the app" — "the main window ignores
/// mouse presses, drags and scrolls, and the keys keep working. Raised, or
/// with the engine away, it takes clicks."
@MainActor
final class MainWindow: NSWindow {
    /// Whether mouse presses, drags and scrolls reach the window's views; `CoveredWindow` decides.
    var takesClicks = true

    /// The events an output over the window keeps from it.
    static func isPointerEvent(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            return true
        default:
            return false
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if !takesClicks, Self.isPointerEvent(event.type) { return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if commitFieldInPlace(ifClickedOutsideItAt: event.locationInWindow) { return }
            handKeysBack(ifClickedOutsideAFieldAt: event.locationInWindow)
        }
        super.sendEvent(event)
    }

    /// Spec 10 §10, "In-place text" — "⌘Return commits, and so does a click
    /// outside, which does nothing else: it doesn't fire, select or drag
    /// what it lands on." Says whether the press was that click, so it goes
    /// no further. Every field opened in place commits the same way (Area
    /// 13 reading: a rename's click outside saves, as the Finder's does).
    func commitFieldInPlace(ifClickedOutsideItAt point: NSPoint) -> Bool {
        guard let regions = contentView as? ShowWindowView, let editor = regions.inlineEditor else { return false }
        if editor.bounds.contains(editor.convert(point, from: nil)) { return false }
        editor.commitNow()
        return true
    }

    /// Spec 10 §9, "A text field" — "Search fields and the command bar keep
    /// the focus until Escape or a click elsewhere." A press outside the
    /// field being typed in takes the cursor out of it, so the keys go back
    /// to the show; a press inside it leaves the cursor where it is. What
    /// was typed stays in the field.
    func handKeysBack(ifClickedOutsideAFieldAt point: NSPoint) {
        guard let editor = firstResponder as? NSText, editor.isFieldEditor, let field = editor.delegate as? NSView else { return }
        if !field.bounds.contains(field.convert(point, from: nil)) { handKeysBack() }
    }

    /// Spec 10 §9 — "hands the focus back to the window ..., so the next
    /// Space sends `next`": the regions, which take no typing, have the keys.
    func handKeysBack() {
        makeFirstResponder(initialFirstResponder)
    }

    /// Called whenever the focus moves, so the top bar can say what a focused field's keys do (Spec 10 §8).
    var onFocusChange: (() -> Void)?

    @discardableResult
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let made = super.makeFirstResponder(responder)
        onFocusChange?()
        return made
    }

    /// Spec 10 §4 — "It can't be hidden or minimized".
    override func miniaturize(_ sender: Any?) {}
    override func zoom(_ sender: Any?) {}
}

/// Spec 10 §4, "One main window": the banner over the regions of §4–§8.
@MainActor
final class MainWindowController {
    let window: MainWindow
    let banner = BannerView()
    /// The window's regions (Spec 10 §4).
    let regions: ShowWindowView
    /// Spec 10 §9 — the keys' model, and what reads every key the app is given.
    let keys: KeysModel
    let keyTap: KeyTap

    /// A window over a store of its own, with no engine: what a test lays out.
    convenience init() {
        self.init(model: ShowModel(store: ShowStore(), clock: SystemAppClock()), mach: nil)
    }

    init(model: ShowModel, mach: MachLink?, clock: any AppClock = SystemAppClock()) {
        // "The window is at least 1440 by 900 points, or the screen's visible area where that is smaller".
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1440, visible.width), height: min(900, visible.height))
        window = MainWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = Strings.text(.appName)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Palette.window
        window.isReleasedWhenClosed = false
        window.minSize = size
        window.collectionBehavior = [.fullScreenPrimary]
        // Spec 10 §15 — "Tab and ⇧Tab move the focus between regions and controls": the regions draw their controls
        // again as the show moves, so the order Tab follows is worked out again as they do.
        window.autorecalculatesKeyViewLoop = true
        // "the app has no Hide, Minimize or Zoom items": nor the buttons that do the same.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        keys = KeysModel(model: model, clock: clock)
        regions = ShowWindowView(model: model, keys: keys, mach: mach, banner: banner)
        regions.frame = NSRect(origin: .zero, size: size)
        regions.autoresizingMask = [.width, .height]
        window.contentView = regions
        // Spec 10 §4, "Focus" — the window opens with the keys on its regions, which take no typing, and not on the
        // first field AppKit finds (the library's search), where a show key would be typed as a letter.
        window.initialFirstResponder = regions
        keyTap = KeyTap(keys: keys, window: window, regions: regions)
        window.onFocusChange = { [weak regions] in regions?.focusChanged() }
        regions.refreshAll()
    }

    /// Shows where the app stands with the engine, and that a connected engine is of another build (Spec 10 §2, "Versions").
    func show(_ phase: EngineSupervisor.Phase, anotherBuild: AnotherBuild? = nil) {
        banner.show(EngineBanner.make(for: phase, anotherBuild: anotherBuild))
        regions.needsLayout = true
    }
}
