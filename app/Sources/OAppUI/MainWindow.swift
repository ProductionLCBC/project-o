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
        super.sendEvent(event)
    }

    /// Spec 10 §4 — "It can't be hidden or minimized".
    override func miniaturize(_ sender: Any?) {}
    override func zoom(_ sender: Any?) {}
}

/// Spec 10 §4, "One main window". In the first build it holds the banner
/// and one line of status; the regions of §4–§8 take the line's place.
@MainActor
final class MainWindowController {
    let window: MainWindow
    let banner = BannerView()
    private let status = NSTextField(labelWithString: "")

    init() {
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
        // "the app has no Hide, Minimize or Zoom items": nor the buttons that do the same.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        status.font = .systemFont(ofSize: 15, weight: .regular)
        status.textColor = Palette.dimText
        status.alignment = .center
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        banner.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(banner)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: content.leadingAnchor), banner.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            banner.topAnchor.constraint(equalTo: content.topAnchor),
            status.centerXAnchor.constraint(equalTo: content.centerXAnchor), status.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 20),
        ])
        window.contentView = content
    }

    /// Shows where the app stands with the engine.
    func show(_ phase: EngineSupervisor.Phase) {
        banner.show(EngineBanner.make(for: phase))
        status.stringValue = phase == .connected ? Strings.text(.engineConnected) : ""
        status.isHidden = status.stringValue.isEmpty
    }

    var shownStatus: String { status.stringValue }
}
