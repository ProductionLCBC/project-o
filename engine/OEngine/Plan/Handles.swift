// OEngine — Spec 4 §4, the handles and pixel geometry a frame plan is made of.

import Foundation
import OCore

/// Spec 4 §4 — a plan is "a plain value"; GPU resources appear in it by
/// handle, resolved through the backend's `ResourceTable` on the render
/// thread (an array read, no dictionary, no allocation).
public struct TextureHandle: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    /// No texture: a poster that does not exist, a text line still rasterizing.
    public static let none = TextureHandle(rawValue: -1)

    public var isNone: Bool { rawValue < 0 }
}

/// Spec 4 §6 — a playing instance's slot in the `SourceTable`.
public struct InstanceHandle: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
}

/// A size in pixels.
public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ size: Size) {
        self.init(width: size.width, height: size.height)
    }

    public var aspect: Double { height > 0 ? Double(width) / Double(height) : 0 }
    public var pixelCount: Int { width * height }
}

/// A rectangle in pixels of its stack's output size (Spec 1 §2: box frames
/// are "normalized 0–1 of the stack's output size"; this is that frame
/// multiplied out). Float keeps sub-pixel placement for letterboxing.
public struct PixelRect: Equatable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ frame: Frame, in size: PixelSize) {
        self.init(x: Float(frame.x * Double(size.width)), y: Float(frame.y * Double(size.height)),
                  width: Float(frame.w * Double(size.width)), height: Float(frame.h * Double(size.height)))
    }

    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// A sub-rectangle of a texture in normalized coordinates, for the fit modes
/// that crop (Spec 4 §9: `fill` and `crop`).
public struct UVRect: Equatable, Codable, Sendable {
    public var u: Float
    public var v: Float
    public var width: Float
    public var height: Float

    public init(u: Float, v: Float, width: Float, height: Float) {
        self.u = u
        self.v = v
        self.width = width
        self.height = height
    }

    public static let full = UVRect(u: 0, v: 0, width: 1, height: 1)
}

/// A colour as the shaders take it: four floats. Spec 1 §5 colours are sRGB
/// 0–1; whether a value here is encoded or linear is said where it is used.
public struct ColorValue: Equatable, Codable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(_ color: Color) {
        self.init(r: Float(color.r), g: Float(color.g), b: Float(color.b), a: Float(color.a))
    }

    public static let clear = ColorValue(r: 0, g: 0, b: 0, a: 0)
    public static let black = ColorValue(r: 0, g: 0, b: 0, a: 1)

    public static func lerp(_ a: ColorValue, _ b: ColorValue, _ t: Float) -> ColorValue {
        ColorValue(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }
}

/// One premultiplied linear-light pixel, the unit of Spec 4 §1 guarantee 4
/// ("Every source becomes linear-light Rec.709 RGBA16Float, premultiplied").
public struct LinearPixel: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static let transparent = LinearPixel(r: 0, g: 0, b: 0, a: 0)
    public static let black = LinearPixel(r: 0, g: 0, b: 0, a: 1)

    public static func lerp(_ a: LinearPixel, _ b: LinearPixel, _ t: Float) -> LinearPixel {
        LinearPixel(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t, a: a.a + (b.a - a.a) * t)
    }
}
