// OApp — Spec 10 §4, §6, §8: the pool's divider, where the window may stand, and an output's details.

import Foundation
import OCore

/// Spec 10 §6, "The divider" — "snaps to three states (UX spec): collapsed,
/// which shows the pool's header and one strip of the twenty most recently
/// used items, so drag-to-channel still works; default, about a third of the
/// center; and expanded. Double-click toggles collapsed and default."
public enum PoolDivider {
    /// The panel's height in a state, for a center this high. `collapsed` is
    /// what the header and one strip of tiles take, which the view knows.
    public static func height(_ state: ViewSettings.PanelState, center: Double, collapsed: Double) -> Double {
        switch state {
        case .collapsed: return collapsed
        case .default: return max(180, (center / 3).rounded(.down))
        case .expanded: return max(240, (center * 0.6).rounded(.down))
        }
    }

    /// The state a drag that leaves the panel this high snaps to: the nearest of the three.
    public static func snap(height: Double, center: Double, collapsed: Double) -> ViewSettings.PanelState {
        let states: [ViewSettings.PanelState] = [.collapsed, .default, .expanded]
        var best = ViewSettings.PanelState.default
        var distance = Double.infinity
        for state in states {
            let away = abs(Self.height(state, center: center, collapsed: collapsed) - height)
            if away < distance {
                distance = away
                best = state
            }
        }
        return best
    }

    /// "Double-click toggles collapsed and default": an expanded panel folds away too.
    public static func toggled(_ state: ViewSettings.PanelState) -> ViewSettings.PanelState {
        state == .collapsed ? .default : .collapsed
    }
}

/// Spec 10 §4, "One main window" — "The app opens it on a screen no output
/// uses, and moves it to one when it ends up on an output's screen, moved by
/// hand or by a change of screens, if such a screen exists."
public enum WindowPlacement {
    /// A screen of this Mac, by the engine's name for it, and how large it is.
    public struct Screen: Equatable, Sendable {
        public var name: String
        public var area: Double

        public init(name: String, area: Double) {
            self.name = name
            self.area = area
        }
    }

    /// The screens outputs use: those its display outputs name, but for the
    /// ones the app released this run (Spec 10 §9), which hold no output now.
    public static func outputScreens(_ outputs: [Output], released: Set<String>) -> Set<String> {
        Set(outputs.filter { $0.kind == .display }.map(\.device)).subtracting(released)
    }

    /// The screen the window should move to, or nil when it stays where it
    /// is: it stands on a screen no output uses, or no such screen exists.
    /// Of several free screens it takes the largest (Area 13 reading).
    public static func target(window: String?, screens: [Screen], outputs: Set<String>) -> String? {
        guard let window, outputs.contains(window) else { return nil }
        let free = screens.filter { !outputs.contains($0.name) }
        var best: Screen?
        for screen in free where screen.area > (best?.area ?? 0) { best = screen }
        return best?.name
    }
}

/// Spec 10 §8 — an output's details: "its device, format, reference, state,
/// and its presented, late and dropped counts from `metrics`".
public struct OutputDetails: Equatable, Sendable {
    public var number: Int
    public var label: String
    /// The device by its name where this Mac has it, else by the id the output holds.
    public var device: String
    public var format: VideoFormat
    /// "for SDI, its reference (`locked`, `freeRun` or `none`)"; nil for a display.
    public var reference: String?
    public var state: OutputDot.State
    public var stack: Int
    public var isBlackedOut: Bool
    /// Since the engine started, as the last `metrics` event gave them; nil until one names this output.
    public var presented: Int?
    public var late: Int?
    public var dropped: Int?
    /// Spec 10 §8 — "for an output on a screen, Release This Screen ... or Put
    /// Back on This Screen while they are released": the screen as
    /// `display:<uuid>`, or nil for an output on a card or the network.
    public var screen: String?

    public static func make(output: Output, dot: OutputDot, status: OutputStatus?, devices: DetectedDevices?, metrics: [String: JSONValue]?) -> OutputDetails {
        let name = devices?.screens.first { $0.device == output.device }?.name ?? devices?.ports.first { $0.device == output.device }?.name
        var details = OutputDetails(number: output.number, label: output.label, device: name ?? output.device, format: output.format,
                                    reference: status?.reference, state: dot.state, stack: dot.stack, isBlackedOut: dot.isBlackedOut)
        if output.device.lowercased().hasPrefix("display:") { details.screen = output.device }
        for value in metrics?.items("outputs") ?? [] {
            guard let counts = value.objectValue, counts.integer("output") == output.number else { continue }
            details.presented = counts.integer("presented")
            details.late = counts.integer("displayedLate")
            details.dropped = counts.integer("dropped")
        }
        return details
    }
}
