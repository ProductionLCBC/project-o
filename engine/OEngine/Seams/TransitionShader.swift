// OEngine — Spec 4 §14, the `TransitionShader` seam; Spec 4 §7 stage 3.

import Foundation
import OCore

/// Spec 4 §14 — `TransitionShader`: "cut, dissolve, fadeThroughColor" in v1;
/// "Custom shader transitions with parameter blocks (v2)". Spec 4 §7 — "custom
/// (later): A `TransitionShader` conformer supplies a fragment function and a
/// parameter block; the pass binds both."
///
/// A conformer names the fragment function variant and fills the parameter
/// block the channel pass binds for one tick.
public protocol TransitionShader: Sendable {
    /// The function-constant selector of the channel shader's variant.
    var variant: TransitionVariant { get }
    /// Spec 4 §7 — the parameter block for eased progress `t`.
    func parameters(progress: Float, color: ColorValue?) -> TransitionParameters
}

/// Spec 4 §7 — the shader variants compiled at launch (one per transition type).
public enum TransitionVariant: Int32, Codable, Sendable {
    case cut = 0
    case dissolve = 1
    case fadeThroughColor = 2
}

/// Spec 4 §7 — "the mix happens here", with the parameters the shader reads:
/// eased progress and the fade-through colour, "opaque and premultiplied".
public struct TransitionParameters: Equatable, Sendable {
    public var progress: Float
    public var color: ColorValue

    public init(progress: Float, color: ColorValue) {
        self.progress = progress
        self.color = color
    }
}

/// Spec 4 §7 — the three built-in types as the table defines them:
/// cut: incoming only; dissolve: `lerp(outgoing, incoming, t)`;
/// fadeThroughColor: `t < 0.5`: `lerp(outgoing, colour, 2t)`; else
/// `lerp(colour, incoming, 2t - 1)`.
public struct BuiltInTransition: TransitionShader, Equatable {
    public let type: TransitionType

    public init(_ type: TransitionType) {
        self.type = type
    }

    public var variant: TransitionVariant {
        switch type {
        case .cut: return .cut
        case .dissolve: return .dissolve
        case .fadeThroughColor: return .fadeThroughColor
        }
    }

    public func parameters(progress: Float, color: ColorValue?) -> TransitionParameters {
        let opaque = color.map { ColorValue(r: $0.r, g: $0.g, b: $0.b, a: 1) } ?? ColorValue(r: 0, g: 0, b: 0, a: 1)
        return TransitionParameters(progress: min(1, max(0, progress)), color: opaque)
    }

    /// Spec 4 §7 — the mix of one premultiplied linear colour pair, as the
    /// shader computes it; the tests check the shader against this.
    public func mix(outgoing: LinearPixel, incoming: LinearPixel, progress t: Float, color: ColorValue?) -> LinearPixel {
        switch type {
        case .cut:
            return incoming
        case .dissolve:
            return LinearPixel.lerp(outgoing, incoming, t)
        case .fadeThroughColor:
            let c = parameters(progress: t, color: color).color
            let through = LinearPixel(r: c.r, g: c.g, b: c.b, a: 1)
            return t < 0.5 ? LinearPixel.lerp(outgoing, through, 2 * t) : LinearPixel.lerp(through, incoming, 2 * t - 1)
        }
    }
}
