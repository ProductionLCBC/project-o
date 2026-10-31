import XCTest
import OCore
@testable import OEngine

/// Spec 4 §8 — layout, fit policies, per-line raster, the glyph-run model,
/// font fallback; and the cache: keys, LRU by bytes, `textLate`.
final class TextRasterizerTests: XCTestCase {
    let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")

    func job(_ text: String, style: TextStyleValues = TextStyleValues(), box: PixelSize = PixelSize(width: 1728, height: 864),
             fit: TextFit = TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24), outputHeight: Int = 1080) -> TextJob {
        let boxStyle = BoxTextStyle(values: style)
        return TextJob(key: TextKey.make(text: text, style: boxStyle, box: box, fit: fit, outputHeight: outputHeight),
                       text: text, style: boxStyle, box: box, fit: fit, outputHeight: outputHeight)
    }

    func test_oneTextureAndOneLayoutLinePerLine() throws {
        let raster = try rasterizer.rasterize(job("Great is Thy faithfulness,\nO God my Father"))
        XCTAssertEqual(raster.lines.count, 2)
        XCTAssertEqual(raster.layout.lines.map(\.text), ["Great is Thy faithfulness,", "O God my Father"])
        XCTAssertEqual(raster.layout.pointSize, 72, accuracy: 0.01, "the style's size fits, so it is kept")
        XCTAssertFalse(raster.layout.overflowed)
        XCTAssertNil(raster.substitutedFont, "HelveticaNeue-Bold is installed")
        for line in raster.lines {
            XCTAssertEqual(line.pixels.count, line.bytesPerRow * line.height)
            XCTAssertGreaterThan(line.width, 0)
            let opaque = line.pixels.enumerated().filter { $0.offset % 4 == 3 && $0.element > 0 }.count
            XCTAssertGreaterThan(opaque, 100, "glyphs were drawn")
        }
        XCTAssertLessThan(raster.lines[0].frame.y, raster.lines[1].frame.y, "lines run down the box")
        XCTAssertGreaterThan(raster.bytes, 0)
    }

    func test_glyphRunsAreKept() throws {
        let raster = try rasterizer.rasterize(job("Amazing grace"))
        let runs = raster.layout.lines.first?.runs ?? []
        XCTAssertFalse(runs.isEmpty)
        XCTAssertEqual(runs.first?.glyphs.count, 13)
        XCTAssertEqual(runs.first?.positions.count, 13)
        XCTAssertEqual(runs.first?.font, "HelveticaNeue-Bold")
        XCTAssertTrue(zip(runs.first?.positions ?? [], (runs.first?.positions ?? []).dropFirst()).allSatisfy { $0 <= $1 }, "positions advance")
    }

    /// Spec 4 §8 — "shrinkToFit binary-searches the point size between minSize
    /// and the style's size until the frame fits the box in both dimensions."
    func test_shrinkToFitShrinksLongTextAndNotShortText() throws {
        let long = String(repeating: "Great is Thy faithfulness, O God my Father. ", count: 12)
        let shrunk = try rasterizer.rasterize(job(long, box: PixelSize(width: 800, height: 300)))
        XCTAssertLessThan(shrunk.layout.pointSize, 72)
        XCTAssertGreaterThanOrEqual(shrunk.layout.pointSize, 24 - 0.01)
        let blockHeight = shrunk.lines.map { $0.frame.maxY }.max() ?? 0
        XCTAssertLessThanOrEqual(blockHeight, 300 + 40, "the block fits the box height (plus the shadow pad)")
        let short = try rasterizer.rasterize(job("Amen", box: PixelSize(width: 800, height: 300)))
        XCTAssertEqual(short.layout.pointSize, 72, accuracy: 0.01)
    }

    /// Spec 4 §8 — "maxLines truncates after N lines with an ellipsis and reports the overflow".
    func test_maxLinesTruncatesWithAnEllipsisAndReportsOverflow() throws {
        let fit = TextFit(policy: .maxLines, maxLines: 2, minSize: 20)
        let raster = try rasterizer.rasterize(job("Line one\nLine two\nLine three\nLine four", fit: fit))
        XCTAssertEqual(raster.lines.count, 2)
        XCTAssertTrue(raster.layout.overflowed)
        XCTAssertTrue(raster.layout.lines[1].text.contains("\u{2026}"), "the last kept line ends with an ellipsis: \(raster.layout.lines[1].text)")
        let within = try rasterizer.rasterize(job("Line one\nLine two", fit: fit))
        XCTAssertFalse(within.layout.overflowed)
        XCTAssertEqual(within.layout.pointSize, 72, accuracy: 0.01, "maxLines never changes the size")
    }

    func test_sizeUnitsScaleWithOutputHeight() throws {
        var style = TextStyleValues()
        style.size = TextSize(value: 72, unit: .pt)
        let hd = try rasterizer.rasterize(job("Amen", style: style, outputHeight: 1080))
        let uhd = try rasterizer.rasterize(job("Amen", style: style, box: PixelSize(width: 3456, height: 1728), outputHeight: 2160))
        XCTAssertEqual(Double(uhd.lines[0].height), Double(hd.lines[0].height) * 2, accuracy: 6, "pt is points on a 1080-line canvas scaled with output height")
        style.size = TextSize(value: 10, unit: .percent)
        let percent = try rasterizer.rasterize(job("Amen", style: style, outputHeight: 1080))
        XCTAssertEqual(Double(percent.layout.pointSize), 108, accuracy: 0.5, "ten percent of 1080 lines is 108 points at 1080")
    }

    func test_allCapsAlignmentOutlineAndShadow() throws {
        var style = TextStyleValues()
        style.allCaps = true
        style.alignment = .right
        style.outline = Outline(width: 2, color: .black)
        style.shadow = Shadow(x: 0, y: 4, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.6))
        let raster = try rasterizer.rasterize(job("amen", style: style, box: PixelSize(width: 1000, height: 200)))
        XCTAssertEqual(raster.layout.lines.first?.text, "AMEN")
        let line = try XCTUnwrap(raster.layout.lines.first)
        XCTAssertEqual(line.origin.x + line.origin.width, 1000, accuracy: 1, "right-aligned")
        let plain = try rasterizer.rasterize(job("amen", box: PixelSize(width: 1000, height: 200)))
        XCTAssertGreaterThan(raster.lines[0].height, plain.lines[0].height, "the shadow and outline extend the line's bounds")
    }

    /// Spec 4 §8 — "falls back to the machine's fallback font, recording the substitution".
    func test_unknownFontFallsBackAndIsRecorded() throws {
        var style = TextStyleValues()
        style.font = "NoSuchFont-Bold"
        let raster = try rasterizer.rasterize(job("Amen", style: style))
        XCTAssertEqual(raster.substitutedFont, "HelveticaNeue")
        XCTAssertEqual(raster.lines.count, 1)
    }

    func test_cacheKeyChangesWithEveryIngredient() {
        let base = job("Amen")
        XCTAssertEqual(base.key, job("Amen").key, "the key is stable across runs")
        XCTAssertNotEqual(base.key, job("Amen ").key)
        XCTAssertNotEqual(base.key, job("Amen", box: PixelSize(width: 100, height: 864)).key)
        XCTAssertNotEqual(base.key, job("Amen", fit: TextFit(policy: .maxLines, maxLines: 6, minSize: 24)).key)
        XCTAssertNotEqual(base.key, job("Amen", outputHeight: 2160).key)
        var style = TextStyleValues()
        style.weight = 400
        XCTAssertNotEqual(base.key, job("Amen", style: style).key)
    }

    func test_cacheMissesThenHitsAndEvictsLeastRecentlyUsedByBytes() throws {
        let backend = RecordingBackend()
        let cache = TextCache(renderer: rasterizer, backend: backend, maximumBytes: 1, synchronous: true)
        let first = job("First line")
        XCTAssertNil(cache.entry(for: first), "a miss on the first ask")
        cache.request(first)
        XCTAssertNotNil(cache.entry(for: first), "the texture from the second")
        XCTAssertEqual(cache.statistics.misses, 1)
        XCTAssertEqual(cache.statistics.hits, 1)
        XCTAssertEqual(cache.statistics.rasterized, 1)
        // Twelve more entries at one byte of budget: the earliest, unused for a while, go.
        for i in 0..<12 { cache.request(job("Line \(i)")) }
        XCTAssertGreaterThan(cache.statistics.evicted, 0)
        XCTAssertNil(cache.entry(for: first), "the least recently used entry was evicted")
        XCTAssertGreaterThan(backend.resources.pendingRelease, 0, "its textures are released after the plans that could name them")
        cache.sweep(consumedTick: 100)
        XCTAssertEqual(backend.resources.pendingRelease, 0)
    }

    func test_cacheRecordsFontSubstitutions() throws {
        let cache = TextCache(renderer: rasterizer, backend: RecordingBackend(), synchronous: true)
        var style = TextStyleValues()
        style.font = "NoSuchFont-Bold"
        cache.request(job("Amen", style: style))
        XCTAssertEqual(cache.fontSubstitutions, ["NoSuchFont-Bold -> HelveticaNeue"])
    }
}
