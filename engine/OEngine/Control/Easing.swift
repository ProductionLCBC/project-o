// OEngine — Spec 1 §2, easing applied to a transition's progress (Spec 4 §4:
// "progress 0–1 for this tick, easing").

import Foundation
import OCore

extension Easing {
    /// The eased value of linear progress `t` in 0...1. `easeInOut` is
    /// symmetric about the midpoint, so a half-way dissolve is a half mix.
    public func apply(_ t: Float) -> Float {
        let x = min(1, max(0, t))
        switch self {
        case .linear:
            return x
        case .easeIn:
            return x * x
        case .easeOut:
            return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            return x < 0.5 ? 2 * x * x : 1 - (-2 * x + 2) * (-2 * x + 2) / 2
        }
    }
}
