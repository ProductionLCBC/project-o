import XCTest
import simd
@testable import OEngine

/// Spec 4 §16, Colour — the CPU reference the shaders are checked against:
/// "Known pixel values (video range black and white, 50% grey, saturated
/// primaries) through each source layout come out at the expected linear
/// values, and back through each sink encode to the expected code values".
final class ColorReferenceTests: XCTestCase {
    func test_srgbCurveRoundTrips() {
        for v in stride(from: Float(0), through: 1, by: 0.01) {
            XCTAssertEqual(ColorMath.srgbDecode(ColorMath.srgbEncode(v)), v, accuracy: 0.0005)
        }
        XCTAssertEqual(ColorMath.srgbDecode(0.5), 0.2140, accuracy: 0.001)
        XCTAssertEqual(ColorMath.srgbEncode(0.18), 0.4613, accuracy: 0.001)
    }

    func test_eightBitLimitedRangeBlackWhiteAndGrey() {
        let black = ColorMath.stage1YCbCr(y: 16 / 255, cb: 128 / 255, cr: 128 / 255, layout: .nv12, matrix: .bt709, range: .limited)
        XCTAssertEqual(black.r, 0, accuracy: 0.001)
        XCTAssertEqual(black.g, 0, accuracy: 0.001)
        let white = ColorMath.stage1YCbCr(y: 235 / 255, cb: 128 / 255, cr: 128 / 255, layout: .nv12, matrix: .bt709, range: .limited)
        XCTAssertEqual(white.r, 1, accuracy: 0.001)
        XCTAssertEqual(white.b, 1, accuracy: 0.001)
        XCTAssertEqual(white.a, 1)
        // Code 126: (126 - 16) / 219 = 0.5023 of the encoded range, 0.2165 linear.
        let grey = ColorMath.stage1YCbCr(y: 126 / 255, cb: 128 / 255, cr: 128 / 255, layout: .nv12, matrix: .bt709, range: .limited)
        XCTAssertEqual(grey.r, ColorMath.srgbDecode((126 - 16) / 219), accuracy: 0.001)
        XCTAssertEqual(grey.r, grey.g, accuracy: 0.0001)
        XCTAssertEqual(grey.g, grey.b, accuracy: 0.0001)
    }

    func test_tenBitCodesLeftAlignedInSixteen() {
        // P010 and 4:2:2 10-bit store code << 6 in 16-bit samples.
        func u16(_ code: Int) -> Float { Float(code << 6) / 65535 }
        for layout in [SourceLayout.p010, .yuv422p10] {
            let white = ColorMath.stage1YCbCr(y: u16(940) * ColorMath.codeScale(for: layout), cb: u16(512) * ColorMath.codeScale(for: layout),
                                              cr: u16(512) * ColorMath.codeScale(for: layout), layout: layout, matrix: .bt709, range: .limited)
            XCTAssertEqual(white.r, 1, accuracy: 0.002)
            let black = ColorMath.stage1YCbCr(y: u16(64) * ColorMath.codeScale(for: layout), cb: u16(512) * ColorMath.codeScale(for: layout),
                                              cr: u16(512) * ColorMath.codeScale(for: layout), layout: layout, matrix: .bt709, range: .limited)
            XCTAssertEqual(black.r, 0, accuracy: 0.002)
        }
    }

    func test_saturatedPrimariesThroughRec709() {
        // Red: Y' = 0.2126, Cb = -0.1146, Cr = 0.5 in limited 8-bit codes 63, 102, 240.
        let red = ColorMath.stage1YCbCr(y: 63 / 255, cb: 102 / 255, cr: 240 / 255, layout: .nv12, matrix: .bt709, range: .limited)
        XCTAssertEqual(red.r, 1, accuracy: 0.03)
        XCTAssertEqual(red.g, 0, accuracy: 0.03)
        XCTAssertEqual(red.b, 0, accuracy: 0.03)
        // Blue: Y' = 0.0722, Cb = 0.5, Cr = -0.0458 in codes 32, 240, 118.
        let blue = ColorMath.stage1YCbCr(y: 32 / 255, cb: 240 / 255, cr: 118 / 255, layout: .nv12, matrix: .bt709, range: .limited)
        XCTAssertEqual(blue.b, 1, accuracy: 0.03)
        XCTAssertEqual(blue.r, 0, accuracy: 0.03)
    }

    func test_bt601ForSDSizedSourcesAndBT2020Primaries() {
        let grey601 = ColorMath.stage1YCbCr(y: 126 / 255, cb: 128 / 255, cr: 128 / 255, layout: .nv12, matrix: .bt601, range: .limited)
        XCTAssertEqual(grey601.r, grey601.g, accuracy: 0.0001)
        let white2020 = ColorMath.stage1YCbCr(y: 235 / 255, cb: 128 / 255, cr: 128 / 255, layout: .nv12, matrix: .bt2020, range: .limited)
        XCTAssertEqual(white2020.r, 1, accuracy: 0.01, "2020 white is 709 white after the primaries matrix")
        XCTAssertEqual(white2020.g, 1, accuracy: 0.01)
        XCTAssertEqual(white2020.b, 1, accuracy: 0.01)
    }

    func test_rgbaStraightAlphaIsPremultipliedAfterLinearizing() {
        let p = ColorMath.stage1RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.5)
        XCTAssertEqual(p.r, ColorMath.srgbDecode(0.5) * 0.5, accuracy: 0.0001)
        XCTAssertEqual(p.a, 0.5)
    }

    func test_gradeIdentityAndParameters() {
        let p = LinearPixel(r: 0.5, g: 0.25, b: 0.1, a: 1)
        let same = ColorMath.grade(p, .identity)
        XCTAssertEqual(same.r, p.r, accuracy: 0.00001)
        XCTAssertEqual(same.g, p.g, accuracy: 0.00001)
        XCTAssertEqual(same.b, p.b, accuracy: 0.00001)
        XCTAssertEqual(same.a, p.a, accuracy: 0.00001)
        var g = GradeParameters.identity
        g.opacity = 0.5
        let faded = ColorMath.grade(p, g)
        XCTAssertEqual(faded.r, 0.25, accuracy: 0.0001)
        XCTAssertEqual(faded.a, 0.5, accuracy: 0.0001)
        g = .identity
        g.brightness = 1
        XCTAssertEqual(ColorMath.grade(p, g).r, 1.0, accuracy: 0.0001)
        g = .identity
        g.saturation = 0
        let grey = ColorMath.grade(p, g)
        XCTAssertEqual(grey.r, grey.g, accuracy: 0.0001)
        XCTAssertEqual(grey.g, grey.b, accuracy: 0.0001)
        g = .identity
        g.contrast = 2
        XCTAssertEqual(ColorMath.grade(LinearPixel(r: 0.18, g: 0.18, b: 0.18, a: 1), g).r, 0.18, accuracy: 0.0001, "contrast pivots on mid grey")
        g = .identity
        g.hue = 120
        let rotated = ColorMath.grade(LinearPixel(r: 1, g: 0, b: 0, a: 1), g)
        XCTAssertEqual(rotated.g, 1, accuracy: 0.001, "a third of a turn about the grey axis takes red to green")
        XCTAssertEqual(rotated.r, 0, accuracy: 0.001)
        g = .identity
        g.tint = ColorValue(r: 1, g: 0, b: 0, a: 1)
        let tinted = ColorMath.grade(LinearPixel(r: 1, g: 1, b: 1, a: 1), g)
        XCTAssertEqual(tinted.g, 0, accuracy: 0.0001)
        XCTAssertEqual(tinted.r, 1, accuracy: 0.0001)
    }

    func test_sinkEncodes() {
        XCTAssertEqual(ColorMath.encodeDisplay10(.black), EncodedPixel(c0: 0, c1: 0, c2: 0, alpha: 3))
        XCTAssertEqual(ColorMath.encodeDisplay10(LinearPixel(r: 1, g: 1, b: 1, a: 1)), EncodedPixel(c0: 1023, c1: 1023, c2: 1023, alpha: 3))
        XCTAssertEqual(ColorMath.encodeDisplay10(LinearPixel(r: 0.18, g: 0.18, b: 0.18, a: 1)).c0, 472)
        XCTAssertEqual(ColorMath.encodeV210(.black), EncodedPixel(c0: 64, c1: 512, c2: 512, alpha: 0))
        XCTAssertEqual(ColorMath.encodeV210(LinearPixel(r: 1, g: 1, b: 1, a: 1)), EncodedPixel(c0: 940, c1: 512, c2: 512, alpha: 0))
        let red = ColorMath.encodeV210(LinearPixel(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(red.c0, 64 + Int((876 * 0.2126).rounded()))
        XCTAssertEqual(red.c2, 512 + 448)
    }

    func test_transitionMixerMatchesTheTable() {
        let out = LinearPixel(r: 1, g: 0, b: 0, a: 1)
        let inc = LinearPixel(r: 0, g: 0, b: 1, a: 1)
        XCTAssertEqual(BuiltInTransition(.cut).mix(outgoing: out, incoming: inc, progress: 0.3, color: nil), inc)
        let half = BuiltInTransition(.dissolve).mix(outgoing: out, incoming: inc, progress: 0.5, color: nil)
        XCTAssertEqual(half.r, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.b, 0.5, accuracy: 0.0001)
        let quarter = BuiltInTransition(.fadeThroughColor).mix(outgoing: out, incoming: inc, progress: 0.25, color: .black)
        XCTAssertEqual(quarter.r, 0.5, accuracy: 0.0001)
        XCTAssertEqual(quarter.a, 1, accuracy: 0.0001)
        let mid = BuiltInTransition(.fadeThroughColor).mix(outgoing: out, incoming: inc, progress: 0.5, color: .black)
        XCTAssertEqual(mid.r, 0, accuracy: 0.0001)
        XCTAssertEqual(mid.b, 0, accuracy: 0.0001)
    }
}
