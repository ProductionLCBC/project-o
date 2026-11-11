import XCTest
import OCore
@testable import OEngine

/// Spec 6 §4 — "Overflow (P3). Text can still overflow in two ways:
/// `shrinkToFit` doesn't fit at `minSize`, or the N lines of `maxLines` are
/// taller than the box. Either way the engine draws at that size and keeps the
/// whole lines that fit, counted from the top. The last one ends in an
/// ellipsis, as `maxLines` already does when it cuts text, and the overflow is
/// reported for the editor and pre-flight. An overflowing block starts at the
/// box's top whatever its anchor, so the first lines show. Nothing draws
/// outside the box except a kept line's own outline and shadow ... Each policy
/// ignores the other's field, as on `main`: `maxLines` never shrinks the text,
/// and `shrinkToFit` has no line limit." (Choice T-8.)
final class TextOverflowTests: XCTestCase {
    typealias T = TextJobs
    let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")
    let long = String(repeating: "Great is Thy faithfulness, O God my Father. ", count: 12)

    func assertWholeLinesFromTheTop(_ layout: TextLayout, boxHeight: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(layout.overflowed, "reported", file: file, line: line)
        guard let first = layout.lines.first, let last = layout.lines.last else { return XCTFail("a line was kept", file: file, line: line) }
        let lineHeight = Double(first.origin.height)
        XCTAssertEqual(layout.lines.count, Int(boxHeight / lineHeight), "the whole lines that fit", file: file, line: line)
        XCTAssertEqual(Double(first.origin.y), 0, accuracy: 0.5, "an overflowing block starts at the box's top", file: file, line: line)
        XCTAssertLessThanOrEqual(Double(last.origin.y) + lineHeight, boxHeight + 0.5, "every kept line is whole", file: file, line: line)
        XCTAssertTrue(last.text.hasSuffix("\u{2026}"), "the last one ends in an ellipsis: \(last.text)", file: file, line: line)
    }

    func test_shrinkToFitThatDoesNotFitAtMinSizeKeepsTheWholeLinesThatFitFromTheTop() throws {
        let fit = TextFit(policy: .shrinkToFit, maxLines: 2, minSize: 24)
        let raster = try rasterizer.rasterize(T.job(long, style: T.plain(anchor: .bottom), box: PixelSize(width: 800, height: 120), fit: fit))
        XCTAssertEqual(raster.layout.pointSize, 24, accuracy: 0.01, "drawn at minSize")
        assertWholeLinesFromTheTop(raster.layout, boxHeight: 120)
        XCTAssertGreaterThan(raster.layout.lines.count, 2, "shrinkToFit has no line limit")
        XCTAssertEqual(raster.lines.count, raster.layout.lines.count)
    }

    func test_maxLinesTallerThanTheBoxKeepsTheWholeLinesThatFit() throws {
        let fit = TextFit(policy: .maxLines, maxLines: 4, minSize: 20)
        let six = "Line one\nLine two\nLine three\nLine four\nLine five\nLine six"
        let raster = try rasterizer.rasterize(T.job(six, style: T.plain(anchor: .center), box: PixelSize(width: 1600, height: 200), fit: fit))
        XCTAssertEqual(raster.layout.pointSize, 72, accuracy: 0.01, "maxLines never shrinks the text")
        assertWholeLinesFromTheTop(raster.layout, boxHeight: 200)
        XCTAssertLessThan(raster.layout.lines.count, 4)
        XCTAssertEqual(raster.layout.lines.first?.text, "Line one")
    }

    /// "keeps the whole lines that fit ... The last one ends in an ellipsis":
    /// the last kept line is its own text with the ellipsis after it, never
    /// the next line run into it (lyrics break their lines by hand), and its
    /// end is cut back only as far as the ellipsis needs to fit the box.
    func test_theLastKeptLineIsItsOwnTextEndingInAnEllipsis() throws {
        let fit = TextFit(policy: .maxLines, maxLines: 2, minSize: 20)
        let lyric = "Great is Thy faithfulness,\nO God my Father,\nthere is no shadow of turning with Thee"
        let raster = try rasterizer.rasterize(T.job(lyric, style: T.plain(), box: PixelSize(width: 1728, height: 864), fit: fit))
        XCTAssertEqual(raster.layout.lines.map(\.text), ["Great is Thy faithfulness,", "O God my Father,\u{2026}"])
        let drawn = raster.layout.lines[1].runs.reduce(0) { $0 + $1.glyphs.count }
        XCTAssertEqual(drawn, "O God my Father,\u{2026}".count, "the glyphs drawn are the line's own and the ellipsis")

        let wrapped = try rasterizer.rasterize(T.job(long, style: T.plain(), box: PixelSize(width: 800, height: 400), fit: fit))
        let last = try XCTUnwrap(wrapped.layout.lines.last)
        XCTAssertTrue(last.text.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(Double(last.origin.width), 800.5, "a full line is cut back to make room for the ellipsis")
    }

    /// Reading of T-8 in this area: when not one line fits, nothing draws.
    func test_whenNotOneLineFitsNothingDrawsAndTheOverflowIsReported() throws {
        let raster = try rasterizer.rasterize(T.job("Amen", style: T.plain(), box: PixelSize(width: 800, height: 40),
                                                    fit: TextFit(policy: .shrinkToFit, maxLines: 1, minSize: 60)))
        XCTAssertTrue(raster.layout.overflowed)
        XCTAssertTrue(raster.lines.isEmpty)
        XCTAssertTrue(raster.layout.lines.isEmpty)
    }

    /// "as `maxLines` already does when it cuts text": the ellipsis is part of
    /// the line, drawn in the line's own colour, not left black.
    func test_theEllipsisIsDrawnInTheLinesOwnColour() throws {
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let fit = TextFit(policy: .maxLines, maxLines: 1, minSize: 20)
        let raster = try rasterizer.rasterize(T.job(long, style: T.plain(color: red), box: PixelSize(width: 1200, height: 400), fit: fit))
        let line = try XCTUnwrap(raster.lines.first)
        // The rightmost inked column belongs to the ellipsis.
        var rightmost = -1
        for x in stride(from: line.width - 1, through: 0, by: -1) where (0..<line.height).contains(where: { T.alpha(line, x, $0) > 128 }) {
            rightmost = x
            break
        }
        XCTAssertGreaterThan(rightmost, 0)
        for y in 0..<line.height where T.alpha(line, rightmost, y) > 128 {
            let red = line.pixels[y * line.bytesPerRow + rightmost * 4 + 2]
            XCTAssertGreaterThan(Int(red), Int(T.alpha(line, rightmost, y)) / 2, "the ellipsis is red like its line")
        }
    }

    func test_theCacheCountsOverflows() throws {
        let cache = TextCache(renderer: rasterizer, backend: RecordingBackend(), synchronous: true)
        cache.request(T.job("Amen"))
        XCTAssertEqual(cache.statistics.overflows, 0)
        cache.request(T.job(long, box: PixelSize(width: 800, height: 120)))
        XCTAssertEqual(cache.statistics.overflows, 1)
    }
}
