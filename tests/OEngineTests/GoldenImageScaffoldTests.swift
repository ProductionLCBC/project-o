import XCTest
@testable import OEngine

/// Spec 4 §16 — "Golden images. A saved frame plan over fixture content renders
/// in the headless harness to textures that match stored PNGs within a
/// tolerance". The scaffolding: a captured frame, its PNG form, the compare and
/// the `--update` path `scripts/golden.sh` uses.
final class GoldenImageScaffoldTests: XCTestCase {
    func gradient(width: Int, height: Int) -> CapturedFrame {
        var frame = CapturedFrame(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                frame[x, y] = LinearPixel(r: Float(x) / Float(max(1, width - 1)), g: Float(y) / Float(max(1, height - 1)), b: 0.5, a: 1)
            }
        }
        return frame
    }

    func test_pngRoundTripKeepsEveryPixelWithinEightBitPrecision() throws {
        let frame = gradient(width: 16, height: 8)
        let png = try GoldenImage.png(from: frame)
        let back = try GoldenImage.frame(fromPNG: png)
        XCTAssertEqual(back.width, 16)
        XCTAssertEqual(back.height, 8)
        let diff = GoldenImage.compare(frame, back)
        XCTAssertLessThanOrEqual(diff.maxCodeDifference, 1)
        XCTAssertLessThanOrEqual(diff.meanCodeDifference, 0.5)
    }

    func test_compareReportsTheWorstPixel() {
        let a = gradient(width: 4, height: 4)
        var b = a
        b[2, 1] = LinearPixel(r: 1, g: 1, b: 1, a: 1)
        let diff = GoldenImage.compare(a, b)
        XCTAssertGreaterThan(diff.maxCodeDifference, 10)
        XCTAssertEqual(diff.worstPixel.x, 2)
        XCTAssertEqual(diff.worstPixel.y, 1)
        XCTAssertFalse(diff.isWithin(GoldenTolerance.default))
        XCTAssertTrue(GoldenImage.compare(a, a).isWithin(GoldenTolerance.default))
    }

    func test_compareRejectsSizeMismatch() {
        let diff = GoldenImage.compare(gradient(width: 4, height: 4), gradient(width: 5, height: 4))
        XCTAssertFalse(diff.sizesMatch)
        XCTAssertFalse(diff.isWithin(GoldenTolerance.default))
    }

    func test_updateWritesTheGoldenAndCheckCompares() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("goldens-\(UUID().uuidString)")
        let store = GoldenStore(folder: folder, update: true)
        let frame = gradient(width: 8, height: 8)
        let first = try store.check("gradient", frame)
        XCTAssertEqual(first, .written)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("gradient.png").path))
        let checking = GoldenStore(folder: folder, update: false)
        XCTAssertEqual(try checking.check("gradient", frame), .matched)
        var other = frame
        other[0, 0] = LinearPixel(r: 1, g: 0, b: 0, a: 1)
        guard case .mismatch(let diff, let diffPath) = try checking.check("gradient", other) else { return XCTFail("expected a mismatch") }
        XCTAssertGreaterThan(diff.maxCodeDifference, 1)
        XCTAssertTrue(diffPath.hasSuffix("gradient.golden-diff.png"))
        XCTAssertEqual(try checking.check("missing", frame), .missing)
    }

    func test_sRGBEncodeDecodeAreInverse() {
        for v in stride(from: Float(0), through: 1, by: 0.05) {
            XCTAssertEqual(GoldenImage.srgbDecode(GoldenImage.srgbEncode(v)), v, accuracy: 0.0005)
        }
        XCTAssertEqual(GoldenImage.srgbEncode(0.18), 0.4613, accuracy: 0.001)
    }
}
