// OApp — Spec 10 §2, the screens: where the curtains go, and when an output covers the app's window.

import Foundation
import OCore

/// What the app knows of the screens and the outputs on them, in one value,
/// so the two rules below are functions of it and nothing else.
public struct ScreenSituation: Equatable, Sendable {
    /// The machine's outputs (the catalog's).
    public var outputs: [Output]
    /// What the engine reports of each (the `outputs` topic).
    public var statuses: [Int: OutputStatus]
    /// The screens this Mac has now, as `display:<uuid>`.
    public var screens: Set<String>
    /// The screen holding the main window, as `display:<uuid>`.
    public var windowScreen: String?
    /// Spec 10 §9 — the screens the app released while it runs.
    public var released: Set<String>

    public init(outputs: [Output], statuses: [Int: OutputStatus], screens: Set<String>, windowScreen: String?, released: Set<String> = []) {
        self.outputs = outputs
        self.statuses = statuses
        self.screens = screens
        self.windowScreen = windowScreen
        self.released = released
    }

    /// The display outputs, lowest number first.
    var displays: [Output] {
        outputs.filter { $0.kind == .display }.sorted { $0.number < $1.number }
    }
}

/// Spec 10 §2, "When the engine stops" — "From its first catalog on, the app
/// keeps a black, borderless curtain, on every Space, on the screen of each
/// display output other than the main window's, one level below the outputs,
/// so that when the engine's windows go, those screens show black and not
/// the desktop (Spec 4 §12)."
public enum CurtainPlan {
    /// The screens that get a curtain. Area 13 reading — one per display
    /// output whose screen is there and isn't the window's; none on a screen
    /// the operator released with ⌃⌥⌘⎋, which is theirs again; and the plan
    /// is worked out again whenever the outputs or the screens change.
    public static func screens(in situation: ScreenSituation) -> Set<String> {
        var curtained: Set<String> = []
        for output in situation.displays {
            let screen = output.device
            guard situation.screens.contains(screen), screen != situation.windowScreen, !situation.released.contains(screen) else { continue }
            curtained.insert(screen)
        }
        return curtained
    }
}

/// Spec 10 §2, "When an output covers the app" — "While the engine is
/// connected and reports an output `presenting` on the screen holding the
/// main window ..., and the window isn't raised above the outputs (§9), the
/// main window ignores mouse presses, drags and scrolls, and the keys keep
/// working. Raised, or with the engine away, it takes clicks."
public enum CoveredWindow {
    /// The lowest-numbered output presenting on the window's screen while
    /// the engine is connected, or nil when none covers it.
    public static func coveringOutput(in situation: ScreenSituation, connected: Bool) -> Int? {
        guard connected, let window = situation.windowScreen else { return nil }
        return situation.displays.first { $0.device == window && situation.statuses[$0.number]?.isPresenting == true }?.number
    }

    /// Whether the main window takes mouse presses, drags and scrolls now.
    public static func takesClicks(in situation: ScreenSituation, connected: Bool, raised: Bool) -> Bool {
        raised || coveringOutput(in: situation, connected: connected) == nil
    }
}
