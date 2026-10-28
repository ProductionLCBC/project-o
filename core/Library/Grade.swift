// OCore — Spec 1 §2, Grade.

import Foundation

/// Spec 1 §2 — Grade: "`hue`, `saturation`, `brightness`, `contrast`, `blur`,
/// `tint` (RGBA), `opacity`. All numbers with a defined identity value, so a
/// grade of all-identity is a no-op."
public struct Grade: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var hue: Double
    public var saturation: Double
    public var brightness: Double
    public var contrast: Double
    public var blur: Double
    public var tint: Color
    public var opacity: Double
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", uuid: UUID = UUID(), hue: Double = 0, saturation: Double = 1,
                brightness: Double = 0, contrast: Double = 1, blur: Double = 0, tint: Color = .clear, opacity: Double = 1,
                extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
        self.contrast = contrast
        self.blur = blur
        self.tint = tint
        self.opacity = opacity
        self.extra = extra
    }

    /// The identity values: hue 0, saturation 1, brightness 0, contrast 1,
    /// blur 0, clear tint, opacity 1.
    public var isIdentity: Bool {
        hue == 0 && saturation == 1 && brightness == 0 && contrast == 1 && blur == 0 && tint.a == 0 && opacity == 1
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case number, label, uuid, hue, saturation, brightness, contrast, blur, tint, opacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        hue = try c.value(.hue, default: 0)
        saturation = try c.value(.saturation, default: 1)
        brightness = try c.value(.brightness, default: 0)
        contrast = try c.value(.contrast, default: 1)
        blur = try c.value(.blur, default: 0)
        tint = try c.value(.tint, default: .clear)
        opacity = try c.value(.opacity, default: 1)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(hue, forKey: .hue)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(blur, forKey: .blur)
        try c.encode(tint, forKey: .tint)
        try c.encode(opacity, forKey: .opacity)
    }
}
