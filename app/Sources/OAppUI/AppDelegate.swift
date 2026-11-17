// OAppUI — Spec 10 §4, the application delegate: the one main window, the menu bar, Quit.

import AppKit
import OApp

/// Spec 10 §4, "One main window" — "Closing it is ⌘Q (§2). It can't be
/// hidden or minimized: the app has no Hide, Minimize or Zoom items and no
/// Window menu, so ⌘H and ⌘M do nothing."
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var controller: AppController?
    private(set) var menuBar: MenuBar?
    var mainWindow: NSWindow? { controller?.windowController.window }

    func applicationDidFinishLaunching(_ notification: Notification) {
        openMainWindow(show: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Spec 10 §4 — the one main window, made once. "Dark only in v1."
    /// `show` is false where a test builds the window without putting it on
    /// a screen or looking for an engine.
    func openMainWindow(show: Bool, controller made: AppController? = nil) {
        guard controller == nil else { return }
        let controller = made ?? AppController()
        self.controller = controller
        controller.windowController.window.delegate = self
        // Spec 10 §4, "Menus" — "The menu bar holds every app-level action".
        let menuBar = MenuBar(controller: controller)
        self.menuBar = menuBar
        NSApplication.shared.mainMenu = menuBar.menu
        if show { controller.start() }
    }

    /// Spec 10 §4 — "Closing it is ⌘Q": the close button asks what Quit asks, and the window stays unless the app quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        return controller.shouldTerminate(systemAsked: Self.systemAskedToQuit)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.closeScreens()
    }

    /// Spec 10 §2 — "A logout, a restart or a shutdown doesn't ask": the
    /// quit event the system sends then says why it was sent.
    static var systemAskedToQuit: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [OSType(kAELogOut), OSType(kAEReallyLogOut), OSType(kAERestart), OSType(kAEShutDown)].contains(reason)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
