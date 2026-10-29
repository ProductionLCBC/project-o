// OEngine — Spec 4 §14, the `TextRenderer` seam; Spec 4 §8, text rasterization.

import Foundation
import OCore

/// Spec 4 §14 — `TextRenderer`: "Per-line Core Graphics raster" in v1;
/// "Glyph atlas or SDF glyphs from the same Core Text layout" later. Spec 4
/// §8 — the rasterizer "turns (text fields, text style, box frame in pixels)
/// into textures the stack pass can sample, and it does so off the render
/// thread, cached, and in a form that keeps the door open to per-glyph
/// animation."
public protocol TextRenderer: AnyObject, Sendable {
    var name: String { get }
    /// Spec 4 §8 — layout, fit and raster one job. Off the render thread.
    func rasterize(_ job: TextJob) throws -> TextRaster
}

/// Spec 4 §8 — the result of one rasterization: one bitmap per line, the
/// layout the stack pass positions the lines by, and the glyph runs kept
/// "so that when per-glyph animation arrives, the renderer can switch to a
/// glyph atlas".
public struct TextRaster: Sendable {
    public var lines: [RasterLine]
    public var layout: TextLayout
    /// Spec 4 §8 — the font that drew it, and whether it stood in for the
    /// one the style asked for (recorded for pre-flight).
    public var substitutedFont: String?

    public init(lines: [RasterLine], layout: TextLayout, substitutedFont: String? = nil) {
        self.lines = lines
        self.layout = layout
        self.substitutedFont = substitutedFont
    }

    /// The cache weighs entries by their texture bytes (Spec 4 §5, §8).
    public var bytes: Int { lines.reduce(0) { $0 + $1.bytes } }
}

/// One line's premultiplied BGRA8 bitmap and where it sits in the box.
public struct RasterLine: @unchecked Sendable {
    /// The line's frame in box pixels, including outline and shadow extents.
    public var frame: PixelRect
    public var width: Int
    public var height: Int
    public var bytesPerRow: Int
    public var pixels: Data

    public init(frame: PixelRect, width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        self.frame = frame
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }

    public var bytes: Int { pixels.count }
}

/// Spec 4 §8 — "The glyph-run model is kept ... for every line, every glyph's
/// ID, font, position and advance", plus the fitted point size and whether
/// `maxLines` truncated ("reports the overflow for the pre-flight and the editor").
public struct TextLayout: Equatable, Sendable {
    public var pointSize: Double
    public var lines: [LayoutLine]
    public var overflowed: Bool

    public init(pointSize: Double, lines: [LayoutLine], overflowed: Bool) {
        self.pointSize = pointSize
        self.lines = lines
        self.overflowed = overflowed
    }
}

public struct LayoutLine: Equatable, Sendable {
    public var text: String
    public var origin: PixelRect
    public var runs: [GlyphRun]

    public init(text: String, origin: PixelRect, runs: [GlyphRun]) {
        self.text = text
        self.origin = origin
        self.runs = runs
    }
}

public struct GlyphRun: Equatable, Sendable {
    public var font: String
    public var glyphs: [UInt16]
    public var positions: [Float]
    public var advances: [Float]

    public init(font: String, glyphs: [UInt16], positions: [Float], advances: [Float]) {
        self.font = font
        self.glyphs = glyphs
        self.positions = positions
        self.advances = advances
    }
}
