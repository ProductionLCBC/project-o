// OEngine — Spec 4 §8, text rasterization: the `TextRenderer` seam's v1
// implementation, "Per-line Core Graphics raster" over a Core Text layout.

import Foundation
import CoreGraphics
import CoreText
import OCore

/// Spec 4 §8 — "Layout is Core Text: an attributed string from the field text
/// and the box's Text Style (font by PostScript name, size resolved from
/// points-at-1080 or percent of output height, weight, colour, spacing,
/// all-caps), laid out into a CTFrame within the box's pixel width."
/// "Raster is Core Graphics into a premultiplied BGRA8 bitmap, one texture per
/// line, with the style's outline and shadow drawn as part of the line."
/// "Fonts. v1 resolves PostScript names against installed fonts and falls
/// back to the machine's fallback font, recording the substitution."
public final class CoreTextLineRasterizer: TextRenderer, @unchecked Sendable {
    public let name = "coretext-lines"
    public let fallbackFont: String

    public init(fallbackFont: String) {
        self.fallbackFont = fallbackFont
    }

    // MARK: - Fonts

    struct ResolvedFont {
        var font: CTFont
        var substituted: String?
    }

    /// Spec 1 §2 — "variations (a map of OpenType axis tag to value ... weight
    /// is the wght axis when the font is variable and the nearest instance
    /// when it is not)".
    func resolveFont(_ values: TextStyleValues, pixelSize: Double) -> ResolvedFont {
        var font = CTFontCreateWithName(values.font as CFString, pixelSize, nil)
        var substituted: String?
        let actual = CTFontCopyPostScriptName(font) as String
        if actual.caseInsensitiveCompare(values.font) != .orderedSame {
            substituted = actual
            let fallback = CTFontCreateWithName(fallbackFont as CFString, pixelSize, nil)
            font = fallback
            substituted = CTFontCopyPostScriptName(fallback) as String
        }
        if !values.variations.isEmpty, let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]], !axes.isEmpty {
            var variation: [CFNumber: CFNumber] = [:]
            for axis in axes {
                guard let identifier = axis[kCTFontVariationAxisIdentifierKey] as? NSNumber,
                      let tag = axis[kCTFontVariationAxisNameKey] as? String ?? CoreTextLineRasterizer.axisTag(identifier.intValue) else { continue }
                if let value = values.variations[tag] ?? values.variations[CoreTextLineRasterizer.axisTag(identifier.intValue) ?? ""] {
                    variation[identifier] = value as NSNumber
                }
            }
            if !variation.isEmpty {
                let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
                font = CTFontCreateCopyWithAttributes(font, pixelSize, nil, descriptor)
            }
        }
        return ResolvedFont(font: font, substituted: substituted)
    }

    static func axisTag(_ identifier: Int) -> String? {
        let bytes = [UInt8((identifier >> 24) & 0xFF), UInt8((identifier >> 16) & 0xFF), UInt8((identifier >> 8) & 0xFF), UInt8(identifier & 0xFF)]
        return String(bytes: bytes, encoding: .ascii)
    }

    // MARK: - Layout

    struct Laid {
        var lines: [CTLine]
        /// The text of each line as laid out (the truncated line ends in an ellipsis).
        var texts: [String]
        var pixelSize: Double
        var lineHeight: Double
        var fits: Bool
        var truncated: Bool
    }

    func attributed(_ text: String, values: TextStyleValues, font: CTFont, outputHeight: Int) -> CFAttributedString {
        let string = values.allCaps ? text.uppercased() : text
        return CFAttributedStringCreate(nil, string as CFString, attributes(values: values, font: font, outputHeight: outputHeight) as CFDictionary)
    }

    /// Spec 4 §8 — the attributes every run of a box's text is drawn with: the
    /// font, the colour, the spacing, the outline and the alignment.
    func attributes(values: TextStyleValues, font: CTFont, outputHeight: Int) -> [CFString: Any] {
        let color = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            components: [CGFloat(values.color.r), CGFloat(values.color.g), CGFloat(values.color.b), CGFloat(values.color.a)])
        var attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color ?? CGColor(gray: 1, alpha: 1),
            kCTKernAttributeName: values.letterSpacing * Double(outputHeight) / 1080 as CFNumber,
        ]
        if values.outline.width > 0 {
            let outlineColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                       components: [CGFloat(values.outline.color.r), CGFloat(values.outline.color.g), CGFloat(values.outline.color.b), CGFloat(values.outline.color.a)])
            attributes[kCTStrokeColorAttributeName] = outlineColor ?? CGColor(gray: 0, alpha: 1)
            // Core Text's stroke width is a percentage of the point size; negative strokes and fills.
            let pixelSize = CTFontGetSize(font)
            attributes[kCTStrokeWidthAttributeName] = -(values.outline.width * Double(outputHeight) / 1080) * 100 / max(1, pixelSize) as CFNumber
        }
        var alignment: CTTextAlignment
        switch values.alignment {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        var lineBreak = CTLineBreakMode.byWordWrapping
        let settings: [CTParagraphStyleSetting] = [
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: &alignment),
            CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: &lineBreak),
        ]
        attributes[kCTParagraphStyleAttributeName] = CTParagraphStyleCreate(settings, settings.count)
        return attributes
    }

    /// Spec 6 §4 — "keeps the whole lines that fit, counted from the top. The
    /// last one ends in an ellipsis": a kept line's own text with an ellipsis
    /// after it, drawn like the rest of the line, its end cut back only as far
    /// as the ellipsis needs to fit `width`. Never the next line run into it.
    func endingInEllipsis(_ text: String, values: TextStyleValues, font: CTFont, outputHeight: Int, width: Double) -> (line: CTLine, text: String) {
        let attributes = self.attributes(values: values, font: font, outputHeight: outputHeight) as CFDictionary
        var shown = text
        while true {
            while let last = shown.last, last.isWhitespace { shown.removeLast() }
            let candidate = shown + "\u{2026}"
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, candidate as CFString, attributes))
            if shown.isEmpty || CTLineGetTypographicBounds(line, nil, nil, nil) <= width + 0.5 { return (line, candidate) }
            shown.removeLast()
        }
    }

    /// Lay the text out at one size within the box; `fits` when every line is
    /// within the width and the lines fit the height.
    func layout(_ text: String, values: TextStyleValues, pixelSize: Double, box: PixelSize, outputHeight: Int, maxLines: Int?) -> (Laid, ResolvedFont) {
        let resolved = resolveFont(values, pixelSize: pixelSize)
        let attributed = attributed(text, values: values, font: resolved.font, outputHeight: outputHeight)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: CGFloat(box.width), height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        var lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        let ascent = CTFontGetAscent(resolved.font)
        let descent = CTFontGetDescent(resolved.font)
        let leading = CTFontGetLeading(resolved.font)
        let lineHeight = (ascent + descent + leading) * values.lineSpacing
        var truncated = false
        let visible = CTFrameGetVisibleStringRange(frame)
        let total = CFAttributedStringGetLength(attributed)
        let source = values.allCaps ? text.uppercased() : text
        let utf16 = Array(source.utf16)
        func substring(_ range: CFRange) -> String {
            guard range.location >= 0, range.location + range.length <= utf16.count else { return "" }
            return String(utf16CodeUnits: Array(utf16[range.location..<(range.location + range.length)]), count: range.length)
                .trimmingCharacters(in: .newlines)
        }
        var texts = lines.map { substring(CTLineGetStringRange($0)) }
        if let maxLines, maxLines > 0, lines.count > maxLines {
            // Spec 4 §8 — "maxLines truncates after N lines with an ellipsis and reports the overflow"; Spec 6 §4 —
            // the kept lines are whole, and the last one is its own text ending in the ellipsis.
            truncated = true
            let last = endingInEllipsis(texts[maxLines - 1], values: values, font: resolved.font, outputHeight: outputHeight, width: Double(box.width))
            lines = Array(lines.prefix(maxLines - 1)) + [last.line]
            texts = Array(texts.prefix(maxLines - 1)) + [last.text]
        }
        let widest = lines.map { CoreTextLineRasterizer.visibleWidth(of: $0) }.max() ?? 0
        let fits = visible.length == total && widest <= Double(box.width) + 0.5 && Double(lines.count) * lineHeight <= Double(box.height) + 0.5
        return (Laid(lines: lines, texts: texts, pixelSize: pixelSize, lineHeight: lineHeight, fits: fits, truncated: truncated), resolved)
    }

    // MARK: - Rasterize

    /// Spec 4 §8 — layout, the fit policy, then one bitmap per line.
    public func rasterize(_ job: TextJob) throws -> TextRaster {
        let values = job.style.values
        let fullSize = values.size.pixels(outputHeight: job.outputHeight)
        let minSize = TextSize(value: job.fit.minSize, unit: .pt).pixels(outputHeight: job.outputHeight)
        var chosen: (Laid, ResolvedFont)
        switch job.fit.policy {
        case .shrinkToFit:
            // "shrinkToFit binary-searches the point size between minSize and the style's size until the frame fits the box in both dimensions."
            var low = min(minSize, fullSize)
            var high = fullSize
            chosen = layout(job.text, values: values, pixelSize: high, box: job.box, outputHeight: job.outputHeight, maxLines: nil)
            if !chosen.0.fits {
                var best = layout(job.text, values: values, pixelSize: low, box: job.box, outputHeight: job.outputHeight, maxLines: nil)
                for _ in 0..<8 where high - low > 0.5 {
                    let mid = (low + high) / 2
                    let trial = layout(job.text, values: values, pixelSize: mid, box: job.box, outputHeight: job.outputHeight, maxLines: nil)
                    if trial.0.fits {
                        best = trial
                        low = mid
                    } else {
                        high = mid
                    }
                }
                chosen = best
            }
        case .maxLines:
            chosen = layout(job.text, values: values, pixelSize: fullSize, box: job.box, outputHeight: job.outputHeight, maxLines: max(1, job.fit.maxLines))
        }
        var (laid, font) = chosen
        // Spec 6 §4 — "Text can still overflow in two ways: shrinkToFit doesn't fit at minSize, or the N lines of
        // maxLines are taller than the box. Either way the engine draws at that size and keeps the whole lines that
        // fit, counted from the top. The last one ends in an ellipsis ... An overflowing block starts at the box's top
        // whatever its anchor, so the first lines show." When not one line fits, nothing draws.
        let boxHeight = Double(job.box.height)
        let overflowsBox = Double(laid.lines.count) * laid.lineHeight > boxHeight + 0.5
        if overflowsBox {
            let whole = Int((boxHeight + 0.5) / max(1, laid.lineHeight))
            if whole > 0 {
                (laid, font) = layout(job.text, values: values, pixelSize: laid.pixelSize, box: job.box, outputHeight: job.outputHeight, maxLines: whole)
            } else {
                laid = Laid(lines: [], texts: [], pixelSize: laid.pixelSize, lineHeight: laid.lineHeight, fits: false, truncated: true)
            }
        }
        // Spec 6 §4 — "It places the block of lines in the box: the first line at the box's top, the block
        // centred, or the last line at the box's bottom."
        let blockHeight = Double(laid.lines.count) * laid.lineHeight
        let top = overflowsBox ? 0 : CoreTextLineRasterizer.top(of: blockHeight, in: boxHeight, anchor: values.verticalAlignment)
        // Spec 6 §4 — "`outline.width`, `shadow.x`, `shadow.y`, `shadow.blur` ... are points on the 1080-line
        // canvas, scaled with the output's height", the bitmap's padding for them included.
        let scale = Double(job.outputHeight) / 1080
        let shadowPad = values.shadow.color.a > 0 ? (values.shadow.blur * 2 + max(abs(values.shadow.x), abs(values.shadow.y))) * scale : 0
        let outlinePad = values.outline.width > 0 ? values.outline.width * scale : 0
        let pad = Int((shadowPad + outlinePad).rounded(.up)) + 2
        var lines: [RasterLine] = []
        var layoutLines: [LayoutLine] = []
        for (index, line) in laid.lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let typographic = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            // A soft-wrapped line ends in the space it broke at; it is aligned by what it shows (Spec 6 §4,
            // "Nothing draws outside the box").
            let width = CoreTextLineRasterizer.visibleWidth(of: line)
            let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            let left = min(0, Double(glyphBounds.minX))
            let right = max(typographic, Double(glyphBounds.maxX))
            let bitmapWidth = max(1, Int((right - left).rounded(.up)) + pad * 2)
            let bitmapHeight = max(1, Int(laid.lineHeight.rounded(.up)) + pad * 2)
            var x: Double
            switch values.alignment {
            case .left: x = 0
            case .center: x = (Double(job.box.width) - width) / 2
            case .right: x = Double(job.box.width) - width
            }
            let y = top + Double(index) * laid.lineHeight
            guard let pixels = raster(line, width: bitmapWidth, height: bitmapHeight, pad: Double(pad), left: left, ascent: Double(ascent),
                                      lineHeight: laid.lineHeight, values: values, outputHeight: job.outputHeight) else { continue }
            lines.append(RasterLine(frame: PixelRect(x: Float(x + left - Double(pad)), y: Float(y - Double(pad)), width: Float(bitmapWidth), height: Float(bitmapHeight)),
                                    width: bitmapWidth, height: bitmapHeight, bytesPerRow: bitmapWidth * 4, pixels: pixels))
            layoutLines.append(LayoutLine(text: index < laid.texts.count ? laid.texts[index] : "",
                                          origin: PixelRect(x: Float(x), y: Float(y), width: Float(width), height: Float(laid.lineHeight)),
                                          runs: CoreTextLineRasterizer.runs(of: line)))
        }
        // Spec 6 §4 — "the overflow is reported for the editor and pre-flight".
        return TextRaster(lines: lines, layout: TextLayout(pointSize: laid.pixelSize * 1080 / Double(job.outputHeight), lines: layoutLines,
                                                           overflowed: laid.truncated || overflowsBox),
                          substitutedFont: font.substituted)
    }

    /// Spec 4 §8 — a line's width without the whitespace it ends in, which
    /// draws nothing: what alignment and the fit policies measure.
    static func visibleWidth(of line: CTLine) -> Double {
        max(0, CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    /// Spec 6 §4 — where the block's first line starts in a box of `height`:
    /// at the top, centred, or with the last line at the bottom. A block
    /// taller than the box starts at the top.
    static func top(of blockHeight: Double, in height: Double, anchor: VerticalAlignment) -> Double {
        switch anchor {
        case .top: return 0
        case .center: return max(0, (height - blockHeight) / 2)
        case .bottom: return max(0, height - blockHeight)
        }
    }

    /// One line into a premultiplied BGRA8 sRGB bitmap, top row first.
    func raster(_ line: CTLine, width: Int, height: Int, pad: Double, left: Double, ascent: Double, lineHeight: Double,
                values: TextStyleValues, outputHeight: Int) -> Data? {
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldSmoothFonts(true)
            // Core Graphics draws with y up; the baseline sits ascent below the top of the line box.
            let baselineY = Double(height) - pad - ascent
            context.textPosition = CGPoint(x: pad - left, y: baselineY)
            if values.shadow.color.a > 0 {
                let shadowColor = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          components: [CGFloat(values.shadow.color.r), CGFloat(values.shadow.color.g), CGFloat(values.shadow.color.b), CGFloat(values.shadow.color.a)])
                let scale = Double(outputHeight) / 1080
                context.setShadow(offset: CGSize(width: values.shadow.x * scale, height: -values.shadow.y * scale), blur: values.shadow.blur * scale, color: shadowColor)
            }
            CTLineDraw(line, context)
            return true
        }
        return drawn ? bytes : nil
    }

    /// Spec 4 §8 — "the list of glyph runs: for every line, every glyph's ID, font, position and advance".
    static func runs(of line: CTLine) -> [GlyphRun] {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        return runs.map { run in
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let attributes = CTRunGetAttributes(run) as? [CFString: Any]
            let fontName = (attributes?[kCTFontAttributeName]).map { CTFontCopyPostScriptName($0 as! CTFont) as String } ?? ""
            return GlyphRun(font: fontName, glyphs: glyphs.map { UInt16($0) }, positions: positions.map { Float($0.x) }, advances: advances.map { Float($0.width) })
        }
    }
}
