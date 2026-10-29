// OEngine — Spec 4 §7 stage 2, the grade parameters of one tick.

import Foundation
import OCore

/// Spec 4 §7 — "Stage 2, grade. Applied in linear RGB: tint (multiply),
/// brightness (multiply), contrast (scale around linear 0.18 mid-grey),
/// saturation (blend toward luma), hue (rotation matrix), opacity (multiply
/// all four components). Parameters arrive per tick, already interpolated
/// by the control thread when a grade write carried a duration, so the shader
/// is stateless." Spec 1 §2 — a Grade's fields, "All numbers with a defined
/// identity value, so a grade of all-identity is a no-op."
public struct GradeParameters: Equatable, Codable, Sendable {
    public var hue: Float
    public var saturation: Float
    public var brightness: Float
    public var contrast: Float
    public var blur: Float
    public var tint: ColorValue
    public var opacity: Float

    public init(hue: Float, saturation: Float, brightness: Float, contrast: Float, blur: Float, tint: ColorValue, opacity: Float) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.contrast = contrast
        self.blur = blur
        self.tint = tint
        self.opacity = opacity
    }

    public init(_ grade: Grade) {
        self.init(hue: Float(grade.hue), saturation: Float(grade.saturation), brightness: Float(grade.brightness),
                  contrast: Float(grade.contrast), blur: Float(grade.blur), tint: ColorValue(grade.tint), opacity: Float(grade.opacity))
    }

    /// Spec 1 §2 — the identity values: hue 0, saturation 1, brightness 0,
    /// contrast 1, blur 0, clear tint, opacity 1. "none counts as identity"
    /// when a grade animation starts from no grade (Spec 3 §4).
    public static let identity = GradeParameters(hue: 0, saturation: 1, brightness: 0, contrast: 1, blur: 0, tint: .clear, opacity: 1)

    public var isIdentity: Bool { self == .identity }

    /// Spec 3 §4 — "the engine interpolates each grade parameter from the old
    /// values ... to the new over that time".
    public static func lerp(_ a: GradeParameters, _ b: GradeParameters, _ t: Float) -> GradeParameters {
        func mix(_ x: Float, _ y: Float) -> Float { x + (y - x) * t }
        return GradeParameters(hue: mix(a.hue, b.hue), saturation: mix(a.saturation, b.saturation),
                               brightness: mix(a.brightness, b.brightness), contrast: mix(a.contrast, b.contrast),
                               blur: mix(a.blur, b.blur), tint: ColorValue.lerp(a.tint, b.tint, t), opacity: mix(a.opacity, b.opacity))
    }
}
