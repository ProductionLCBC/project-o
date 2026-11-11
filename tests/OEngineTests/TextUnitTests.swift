import XCTest
import OCore
@testable import OEngine

/// Spec 6 §4 — "Units (P2). `outline.width`, `shadow.x`, `shadow.y`,
/// `shadow.blur` and `letterSpacing` are points on the 1080-line canvas,
/// scaled with the output's height like a `size` in `pt`. A style therefore
/// looks the same on a 4K wall and a 1080p monitor ... `main` has drawn this
/// way since Area 4, except for the padding of each line's bitmap. That
/// padding is sized from the unscaled shadow, which can clip a shadow above
/// 1080 lines, so Area 6 scales it too." Spec 6 §11: "A style rendered at 1080
/// and 2160 lines matches within a pixel, shadow included."
final class TextUnitTests: XCTestCase {
    typealias T = TextJobs
    let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")

    func test_aStyleAt1080And2160LinesMatchesWithinAPixelShadowIncluded() throws {
        var style = T.plain(size: 60)
        // A long soft shadow cast to the right: sideways the line has no spacing to hide a clipped edge in,
        // and its tail reaches past a bitmap padded for the unscaled shadow at 2160 lines.
        style.shadow = Shadow(x: 30, y: 10, blur: 30, color: Color(r: 0, g: 0, b: 0, a: 1))
        style.outline = Outline(width: 3, color: .black)
        style.letterSpacing = 2
        let text = "Glory to God"
        let hd = try rasterizer.rasterize(T.job(text, style: style, box: PixelSize(width: 1600, height: 400), outputHeight: 1080))
        let uhd = try rasterizer.rasterize(T.job(text, style: style, box: PixelSize(width: 3200, height: 800), outputHeight: 2160))
        let small = try XCTUnwrap(hd.lines.first), large = try XCTUnwrap(uhd.lines.first)
        XCTAssertLessThanOrEqual(T.borderAlpha(small), 1, "nothing of the shadow is cut off at 1080")
        XCTAssertLessThanOrEqual(T.borderAlpha(large), 1, "nothing of the shadow is cut off at 2160")
        let a = try XCTUnwrap(T.ink(small)), b = try XCTUnwrap(T.ink(large))
        XCTAssertEqual(b.minX / 2, a.minX, accuracy: 1, "left edge of the ink, shadow and outline included")
        XCTAssertEqual(b.maxX / 2, a.maxX, accuracy: 1)
        XCTAssertEqual(b.minY / 2, a.minY, accuracy: 1)
        XCTAssertEqual(b.maxY / 2, a.maxY, accuracy: 1, "the shadow's lower edge")
    }
}
