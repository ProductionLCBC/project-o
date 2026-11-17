// OAppUI — Spec 10 §4, the application delegate: the one main window.

import AppKit
import OApp

/// Spec 10 §4, "One main window" — the delegate opens the main window and
/// owns it for the app's life.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        openMainWindow(show: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Spec 10 §4 — the one main window, made once. "Dark only in v1."
    /// `show` is false where a test lays the window out without putting it on a screen.
    func openMainWindow(show: Bool) {
        guard mainWindow == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: !show)
        window.title = "Project O"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        mainWindow = window
        guard show else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
