import XCTest
import OCore
@testable import OEngine

/// Spec 6 §4 — "Vertical anchor (P1). The Text Style gains
/// `verticalAlignment`, beside `alignment`: `top`, `center` or `bottom` ... It
/// places the block of lines in the box: the first line at the box's top, the
/// block centred, or the last line at the box's bottom." Spec 4 §8 —
/// "Horizontal and vertical alignment come from the style (`alignment`,
/// `verticalAlignment`)."
final class TextAnchorTests: XCTestCase {
    typealias T = TextJobs
    let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")
    let box = PixelSize(width: 1728, height: 864)
    let text = "Great is Thy faithfulness,\nO God my Father"

    func layout(_ anchor: VerticalAlignment) throws -> TextLayout {
        try rasterizer.rasterize(T.job(text, style: T.plain(anchor: anchor), box: box)).layout
    }

    func test_theBlockSitsAtTheTopTheCentreOrTheBottomOfTheBox() throws {
        let top = try layout(.top)
        let lineHeight = Double(try XCTUnwrap(top.lines.first).origin.height)
        XCTAssertEqual(top.lines.count, 2)
        XCTAssertEqual(Double(top.lines[0].origin.y), 0, accuracy: 0.5, "the first line at the box's top")

        let centre = try layout(.center)
        XCTAssertEqual(Double(centre.lines[0].origin.y), (864 - 2 * lineHeight) / 2, accuracy: 0.5, "the block centred")

        let bottom = try layout(.bottom)
        let last = try XCTUnwrap(bottom.lines.last)
        XCTAssertEqual(Double(last.origin.y) + lineHeight, 864, accuracy: 0.5, "the last line at the box's bottom")
        XCTAssertEqual(bottom.lines.map(\.text), top.lines.map(\.text), "the anchor moves the block, not the breaks")
    }

    /// Spec 4 §8 — the cache key holds the "text style value", anchor included.
    func test_theAnchorIsInTheCacheKey() {
        let keys = [VerticalAlignment.top, .center, .bottom].map { T.job(text, style: T.plain(anchor: $0)).key }
        XCTAssertEqual(Set(keys.map(\.hash)).count, 3)
    }
}
