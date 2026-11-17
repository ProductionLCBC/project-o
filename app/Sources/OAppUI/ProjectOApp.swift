// OAppUI — Spec 10 §1, the operator app's entry.

import AppKit
import OApp

/// Spec 10 §1 — "The operator app is the window a volunteer runs a Sunday
/// from. It is a client of the engine". The shell target's `main.swift`
/// calls `main()` and holds nothing else, so everything the app does is in
/// package targets that `swift build` compiles and `swift test` reaches.
public enum ProjectOApp {
    /// Spec 10 §1 — runs the app: the application object, its delegate, and
    /// the run loop. It returns when the app quits.
    @MainActor
    public static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
