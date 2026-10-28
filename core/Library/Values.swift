// OCore — Spec 1 §2, §3 and §5, the small value shapes the objects share.
//
// These are the fixed shapes of §5 ("Colors are `{r, g, b, a}` floats 0–1 in
// sRGB. Normalized geometry is 0–1 of the containing size ... frame rates are
// `{num, den}`"). They have no unknown-key bag: their shape is the whole value.

import Foundation

/// Spec 1 §5 — "Colors are `{r, g, b, a}` floats 0–1 in sRGB."
public struct Color: Codable, Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let white = Color(r: 1, g: 1, b: 1)
    public static let black = Color(r: 0, g: 0, b: 0)
    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)
}

/// Spec 1 §2 — Box `frame`: "`{x, y, w, h}` normalized 0–1 of the stack's
/// output size. Resolution-independent."
public struct Frame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public static let full = Frame(x: 0, y: 0, w: 1, h: 1)
}

/// Spec 1 §2 — a pixel size, `{width, height}`.
public struct Size: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public static let hd = Size(width: 1920, height: 1080)
}

/// Spec 1 §2 — Transition and Audio Transition `easing`.
public enum Easing: String, Codable, Equatable, Sendable {
    case linear, easeIn, easeOut, easeInOut
}

/// Spec 1 §3 — `colorRange`: "`full` or `limited`".
public enum ColorRange: String, Codable, Equatable, Sendable {
    case full, limited
}

/// Spec 1 §3 — Output and Input `format`: "`{width, height, rate: {num, den},
/// interlaced: bool}`. Interlace is handled in the sink by weaving a
/// progressive render."
public struct VideoFormat: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rate: FrameRate
    public var interlaced: Bool
    public var extra: [String: JSONValue]

    public init(width: Int = 1920, height: Int = 1080, rate: FrameRate = .fps60, interlaced: Bool = false,
                extra: [String: JSONValue] = [:]) {
        self.width = width
        self.height = height
        self.rate = rate
        self.interlaced = interlaced
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case width, height, rate, interlaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        rate = try c.decode(FrameRate.self, forKey: .rate)
        interlaced = try c.value(.interlaced, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rate, forKey: .rate)
        try c.encode(interlaced, forKey: .interlaced)
    }
}

/// Spec 1 §2 — Text Style `size`: "`{value, unit}`: pt is points on a
/// 1080-line canvas scaled with output height, the default; percent is a
/// percentage of output height."
public struct TextSize: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Equatable, Sendable {
        case pt, percent
    }

    public var value: Double
    public var unit: Unit

    public init(value: Double, unit: Unit = .pt) {
        self.value = value
        self.unit = unit
    }
}

/// Spec 1 §2 — Text Style `alignment`.
public enum TextAlignment: String, Codable, Equatable, Sendable {
    case left, center, right
}

/// Spec 1 §2 — Text Style `outline` `{width, color}`.
public struct Outline: Codable, Equatable, Sendable {
    public var width: Double
    public var color: Color

    public init(width: Double = 0, color: Color = .black) {
        self.width = width
        self.color = color
    }
}

/// Spec 1 §2 — Text Style `shadow` `{x, y, blur, color}`.
public struct Shadow: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var blur: Double
    public var color: Color

    public init(x: Double = 0, y: Double = 0, blur: Double = 0, color: Color = .clear) {
        self.x = x
        self.y = y
        self.blur = blur
        self.color = color
    }
}
