import Foundation
import OCore
@testable import OEngine

/// Text jobs and raster readings for the Spec 6 §4 tests.
enum TextJobs {
    static func job(_ text: String, style: TextStyleValues = TextStyleValues(), box: PixelSize = PixelSize(width: 1728, height: 864),
                    fit: TextFit = TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24), outputHeight: Int = 1080,
                    tabular: Bool = false) -> TextJob {
        let boxStyle = BoxTextStyle(values: style)
        return TextJob(key: TextKey.make(text: text, style: boxStyle, box: box, fit: fit, outputHeight: outputHeight, tabular: tabular),
                       text: text, style: boxStyle, box: box, fit: fit, outputHeight: outputHeight, tabular: tabular)
    }

    /// A plain style with no shadow or outline, so a line's ink is its glyphs alone.
    static func plain(size: Double = 72, anchor: VerticalAlignment = .center, color: Color = .white) -> TextStyleValues {
        var style = TextStyleValues()
        style.size = TextSize(value: size)
        style.verticalAlignment = anchor
        style.color = color
        style.shadow = Shadow()
        style.outline = Outline()
        return style
    }

    /// The alpha of a line bitmap's pixel (BGRA8, premultiplied, top row first).
    static func alpha(_ line: RasterLine, _ x: Int, _ y: Int) -> UInt8 {
        line.pixels[y * line.bytesPerRow + x * 4 + 3]
    }

    /// The largest alpha on the bitmap's outermost rows and columns: anything
    /// above zero there was cut off by the bitmap's edge.
    static func borderAlpha(_ line: RasterLine) -> UInt8 {
        var most: UInt8 = 0
        for x in 0..<line.width { most = max(most, alpha(line, x, 0), alpha(line, x, line.height - 1)) }
        for y in 0..<line.height { most = max(most, alpha(line, 0, y), alpha(line, line.width - 1, y)) }
        return most
    }

    /// The bounds of a line's ink (alpha above `threshold`), in box pixels.
    static func ink(_ line: RasterLine, threshold: UInt8 = 25) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for y in 0..<line.height {
            for x in 0..<line.width where alpha(line, x, y) > threshold {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard minX <= maxX else { return nil }
        let ox = Double(line.frame.x), oy = Double(line.frame.y)
        return (ox + Double(minX), oy + Double(minY), ox + Double(maxX + 1), oy + Double(maxY + 1))
    }
}
