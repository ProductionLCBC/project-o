import XCTest
import OCore
@testable import OEngine

/// Spec 4 §16, Colour — "back through each sink encode to the expected code
/// values": the display's 10-bit codes and the DeckLink v210 words against
/// the CPU reference; the output transition mix at the sink (Spec 4 §10).
final class MetalEncodeTests: XCTestCase {
    var backend: MetalBackend!

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    /// A 12×2 picture: six known greys and primaries, repeated.
    func picture() -> (CapturedFrame, [LinearPixel]) {
        let values: [LinearPixel] = [
            .black, LinearPixel(r: 1, g: 1, b: 1, a: 1), LinearPixel(r: 0.18, g: 0.18, b: 0.18, a: 1), LinearPixel(r: 0.5, g: 0.5, b: 0.5, a: 1),
            LinearPixel(r: 1, g: 0, b: 0, a: 1), LinearPixel(r: 0, g: 0, b: 1, a: 1),
        ]
        var frame = CapturedFrame(width: 12, height: 2)
        for y in 0..<2 { for x in 0..<12 { frame[x, y] = values[(x / 2) % values.count] } }
        return (frame, values)
    }

    func test_displayEncodeMatchesTheReferenceCodes() throws {
        let (frame, _) = picture()
        let stack = backend.makeStill(frame, label: "stack")
        let codes = try XCTUnwrap(backend.displayCodes(stack: stack))
        for x in 0..<12 {
            let expected = ColorMath.encodeDisplay10(frame[x, 0])
            let got = codes[x]
            XCTAssertLessThanOrEqual(abs(got.0 - expected.c0), 1, "r at \(x): \(got) vs \(expected)")
            XCTAssertLessThanOrEqual(abs(got.1 - expected.c1), 1, "g at \(x)")
            XCTAssertLessThanOrEqual(abs(got.2 - expected.c2), 1, "b at \(x)")
            XCTAssertEqual(got.3, 3, "opaque")
        }
    }

    func test_v210EncodeMatchesTheReferenceCodes() throws {
        let (frame, _) = picture()
        let stack = backend.makeStill(frame, label: "stack")
        let words = try XCTUnwrap(backend.v210Words(stack: stack, width: 12, height: 2))
        // Row 0: two groups of six pixels, four words each.
        func unpack(_ group: Int) -> (y: [Int], cb: [Int], cr: [Int]) {
            let w = Array(words[(group * 4)..<(group * 4 + 4)]).map { Int($0) }
            let y = [(w[0] >> 10) & 0x3FF, w[1] & 0x3FF, (w[1] >> 20) & 0x3FF, (w[2] >> 10) & 0x3FF, w[3] & 0x3FF, (w[3] >> 20) & 0x3FF]
            let cb = [w[0] & 0x3FF, (w[1] >> 10) & 0x3FF, (w[2] >> 20) & 0x3FF]
            let cr = [(w[0] >> 20) & 0x3FF, w[2] & 0x3FF, (w[3] >> 10) & 0x3FF]
            return (y, cb, cr)
        }
        for group in 0..<2 {
            let codes = unpack(group)
            for i in 0..<6 {
                let expected = ColorMath.encodeV210(frame[group * 6 + i, 0])
                XCTAssertLessThanOrEqual(abs(codes.y[i] - expected.c0), 1, "Y of pixel \(group * 6 + i): \(codes.y[i]) vs \(expected.c0)")
            }
            for pair in 0..<3 {
                let a = ColorMath.encodeV210(frame[group * 6 + pair * 2, 0])
                let b = ColorMath.encodeV210(frame[group * 6 + pair * 2 + 1, 0])
                XCTAssertLessThanOrEqual(abs(codes.cb[pair] - (a.c1 + b.c1) / 2), 1, "Cb of pair \(pair)")
                XCTAssertLessThanOrEqual(abs(codes.cr[pair] - (a.c2 + b.c2) / 2), 1, "Cr of pair \(pair)")
            }
        }
        XCTAssertEqual(ColorMath.encodeV210(frame[2, 0]).c0, 64 + Int((876 * ColorMath.srgbEncode(1)).rounded()), "white is code 940")
    }

    /// Spec 4 §10 — "mix the stack texture with a second texture when an
    /// output transition is running (the previous stack for a switch, black
    /// for blackout)".
    func test_sinkMixWithBlackAndWithAnotherStack() throws {
        let white = backend.makeStill(MetalHarness.solid(width: 12, height: 2, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "white")
        let red = backend.makeStill(MetalHarness.solid(width: 12, height: 2, LinearPixel(r: 1, g: 0, b: 0, a: 1)), label: "red")
        let halfBlack = try XCTUnwrap(backend.displayCodes(stack: white, second: .black, mix: 0.5))
        let expected = ColorMath.encodeDisplay10(LinearPixel(r: 0.5, g: 0.5, b: 0.5, a: 1))
        XCTAssertLessThanOrEqual(abs(halfBlack[0].0 - expected.c0), 1, "half way to black is linear 0.5")
        let switched = try XCTUnwrap(backend.displayCodes(stack: white, second: .stack(red), mix: 1))
        XCTAssertEqual(switched[0].0, 1023, "all of the second texture: red")
        XCTAssertEqual(switched[0].1, 0)
        let quarter = try XCTUnwrap(backend.displayCodes(stack: white, second: .stack(red), mix: 0.25))
        let expectedGreen = ColorMath.encodeDisplay10(LinearPixel(r: 1, g: 0.75, b: 0.75, a: 1))
        XCTAssertLessThanOrEqual(abs(quarter[0].1 - expectedGreen.c1), 1, "a quarter of red over white")
    }
}
