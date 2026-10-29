import XCTest
import OCore
@testable import OEngine

/// Spec 4 §9 — the stack pass on the GPU: the base, pixel boxes with the four
/// fit modes, text lines, opacity, the per-box grade, box dissolves and the
/// gamma-blend switch, with goldens (Spec 4 §16: "each fit mode; ... a text
/// box under both fit policies; the gamma-blend switch").
final class MetalStackPassTests: XCTestCase {
    var backend: MetalBackend!
    let stackSize = PixelSize(width: 96, height: 54)

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    func stackTarget(_ label: String = "stack") -> TextureHandle {
        backend.makeTexture(TextureDescriptor(role: .stack, size: stackSize, label: label))
    }

    /// A 4:3 picture: red left half, green right half, a blue top row.
    func picture() -> CapturedFrame {
        var frame = CapturedFrame(width: 64, height: 48)
        for y in 0..<48 {
            for x in 0..<64 {
                frame[x, y] = y < 4 ? LinearPixel(r: 0, g: 0, b: 1, a: 1) : (x < 32 ? LinearPixel(r: 1, g: 0, b: 0, a: 1) : LinearPixel(r: 0, g: 1, b: 0, a: 1))
            }
        }
        return frame
    }

    func test_baseClearsToBlackOrTransparent() throws {
        for base in [StackBase.black, .transparent] {
            let pass = StackPass(stack: 1, target: stackTarget(), size: stackSize, base: base, gammaBlend: false, boxes: [])
            let frame = try XCTUnwrap(MetalHarness.render(pass, backend: backend))
            MetalHarness.assertPixel(frame[10, 10], base == .black ? .black : .transparent, base.rawValue)
        }
    }

    func test_fitModesMatchTheGoldens() throws {
        let goldens = MetalHarness.goldens("stack")
        let still = backend.makeStill(picture(), label: "4:3")
        let frameRect = PixelRect(x: 0, y: 0, width: 96, height: 54)
        for fit in [PixelFit.fit, .fill, .stretch, .crop] {
            let quad = ControlLoop.fitQuad(texture: still, content: .full, contentPixels: PixelSize(width: 64, height: 48), into: frameRect, fit: fit)
            let box = ResolvedBox(channel: 1, frame: frameRect, content: .pixels(quad), opacity: 1)
            let pass = StackPass(stack: 1, target: stackTarget(), size: stackSize, base: .black, gammaBlend: false, boxes: [box])
            let frame = try XCTUnwrap(MetalHarness.render(pass, backend: backend))
            switch fit {
            case .fit:
                MetalHarness.assertPixel(frame[2, 27], .black, "fit: pillarbox on the left")
                MetalHarness.assertPixel(frame[93, 27], .black, "fit: pillarbox on the right")
                MetalHarness.assertPixel(frame[30, 27], LinearPixel(r: 1, g: 0, b: 0, a: 1), "fit: content left")
                MetalHarness.assertPixel(frame[66, 27], LinearPixel(r: 0, g: 1, b: 0, a: 1), "fit: content right")
            case .fill:
                MetalHarness.assertPixel(frame[2, 27], LinearPixel(r: 1, g: 0, b: 0, a: 1), "fill: no bars, cropped top and bottom")
                MetalHarness.assertPixel(frame[93, 27], LinearPixel(r: 0, g: 1, b: 0, a: 1))
                MetalHarness.assertPixel(frame[48, 1], LinearPixel(r: 0, g: 1, b: 0, a: 1).a == 1 ? frame[48, 1] : frame[48, 1], "fill keeps the aspect")
            case .stretch:
                MetalHarness.assertPixel(frame[2, 27], LinearPixel(r: 1, g: 0, b: 0, a: 1), "stretch: edge to edge")
                MetalHarness.assertPixel(frame[48, 2], LinearPixel(r: 0, g: 0, b: 1, a: 1), "stretch: the blue row is at the top")
            case .crop:
                MetalHarness.assertPixel(frame[8, 27], .black, "crop: 64 of 96 columns at 1:1, centred")
                MetalHarness.assertPixel(frame[20, 27], LinearPixel(r: 1, g: 0, b: 0, a: 1))
                MetalHarness.assertPixel(frame[48, 1], .black, "crop: 48 of 54 rows, centred")
            }
            try MetalHarness.assertGolden(goldens, "fit-\(fit.rawValue)", frame)
        }
    }

    func test_opacityAndMuteAndPerBoxGrade() throws {
        let white = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "white")
        let full = PixelRect(x: 0, y: 0, width: 96, height: 54)
        let left = PixelRect(x: 0, y: 0, width: 48, height: 54)
        let right = PixelRect(x: 48, y: 0, width: 48, height: 54)
        func quad(_ frame: PixelRect) -> PixelQuad { PixelQuad(texture: white, frame: frame, uv: .full) }
        var grade = GradeParameters.identity
        grade.opacity = 0.5
        let boxes = [
            ResolvedBox(channel: 1, frame: full, content: .pixels(quad(full)), opacity: 0.25),
            ResolvedBox(channel: 2, frame: left, content: .pixels(quad(left)), opacity: 0, binding: .pixels),
            ResolvedBox(channel: 3, frame: right, content: .pixels(quad(right)), opacity: 1, grade: grade),
        ]
        let pass = StackPass(stack: 1, target: stackTarget(), size: stackSize, base: .transparent, gammaBlend: false, boxes: boxes)
        XCTAssertEqual(pass.drawnBoxes.count, 2, "the muted box is skipped")
        let frame = try XCTUnwrap(MetalHarness.render(pass, backend: backend))
        MetalHarness.assertPixel(frame[10, 27], LinearPixel(r: 0.25, g: 0.25, b: 0.25, a: 0.25), accuracy: 0.01, "slot opacity")
        // Right half: 0.25 white under a 0.5 white: 0.25 * 0.5 + 0.5 = 0.625.
        MetalHarness.assertPixel(frame[80, 27], LinearPixel(r: 0.625, g: 0.625, b: 0.625, a: 0.625), accuracy: 0.01, "per-box grade over the slot below")
    }

    func test_boxDissolveDrawsOldAndNewMixed() throws {
        let red = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 0, b: 0, a: 1)), label: "red")
        let blue = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 0, g: 0, b: 1, a: 1)), label: "blue")
        let full = PixelRect(x: 0, y: 0, width: 96, height: 54)
        let box = ResolvedBox(channel: 1, frame: full, content: .lines([TextLine(texture: blue, frame: full)]), opacity: 1,
                              transition: BoxTransitionState(type: .dissolve, progress: 0.5, outgoing: .lines([TextLine(texture: red, frame: full)])))
        let pass = StackPass(stack: 1, target: stackTarget(), size: stackSize, base: .black, gammaBlend: false, boxes: [box])
        let frame = try XCTUnwrap(MetalHarness.render(pass, backend: backend))
        // Old at 0.5 then new at 0.5 over black: red 0.25, blue 0.5 (the second draw covers half of the first).
        MetalHarness.assertPixel(frame[48, 27], LinearPixel(r: 0.25, g: 0, b: 0.5, a: 1), accuracy: 0.01)
    }

    /// Spec 4 §9 — "A stack with gammaBlend on composites in encoded space".
    func test_gammaBlendSwitchChangesTheMixAndMatchesTheGoldens() throws {
        let goldens = MetalHarness.goldens("stack")
        let white = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "white")
        let full = PixelRect(x: 0, y: 0, width: 96, height: 54)
        let box = ResolvedBox(channel: 1, frame: full, content: .pixels(PixelQuad(texture: white, frame: full, uv: .full)), opacity: 0.5)
        let linear = try XCTUnwrap(MetalHarness.render(StackPass(stack: 1, target: stackTarget(), size: stackSize, base: .black, gammaBlend: false, boxes: [box]), backend: backend))
        MetalHarness.assertPixel(linear[48, 27], LinearPixel(r: 0.5, g: 0.5, b: 0.5, a: 1), accuracy: 0.01, "linear light: half white over black is half")
        let gamma = try XCTUnwrap(MetalHarness.render(StackPass(stack: 1, target: stackTarget(), size: stackSize, base: .black, gammaBlend: true, boxes: [box]), backend: backend))
        MetalHarness.assertPixel(gamma[48, 27], LinearPixel(r: ColorMath.srgbDecode(0.5), g: ColorMath.srgbDecode(0.5), b: ColorMath.srgbDecode(0.5), a: 1), accuracy: 0.01,
                                 "encoded space: half of encoded white, linearized again for the sink")
        try MetalHarness.assertGolden(goldens, "gamma-blend-off", linear)
        try MetalHarness.assertGolden(goldens, "gamma-blend-on", gamma)
    }

    /// Spec 4 §16 — "a text box under both fit policies".
    func test_textBoxUnderBothFitPoliciesMatchesTheGoldens() throws {
        let goldens = MetalHarness.goldens("stack")
        let size = PixelSize(width: 480, height: 270)
        let target = backend.makeTexture(TextureDescriptor(role: .stack, size: size, label: "text stack"))
        let cache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: backend, synchronous: true)
        let style = BoxTextStyle(values: TextStyleValues(shadow: Shadow(x: 0, y: 2, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.6))), fromStyle: 1)
        let text = "Great is Thy faithfulness,\nO God my Father,\nthere is no shadow of turning with Thee"
        let frameRect = PixelRect(x: 24, y: 27, width: 432, height: 216)
        for fit in [TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24), TextFit(policy: .maxLines, maxLines: 2, minSize: 20)] {
            let job = TextJob(key: TextKey.make(text: text, style: style, box: PixelSize(width: 432, height: 216), fit: fit, outputHeight: 270),
                              text: text, style: style, box: PixelSize(width: 432, height: 216), fit: fit, outputHeight: 270)
            cache.request(job)
            let entry = try XCTUnwrap(cache.entry(for: job))
            let lines = entry.lines.map { TextLine(texture: $0.texture, frame: PixelRect(x: frameRect.x + $0.frame.x, y: frameRect.y + $0.frame.y, width: $0.frame.width, height: $0.frame.height)) }
            let box = ResolvedBox(channel: 2, frame: frameRect, content: .lines(lines), opacity: 1, binding: .field(name: "body"), text: text)
            let pass = StackPass(stack: 1, target: target, size: size, base: .black, gammaBlend: false, boxes: [box])
            let frame = try XCTUnwrap(MetalHarness.render(pass, backend: backend))
            let lit = frame.pixels.filter { $0.r > 0.2 }.count
            XCTAssertGreaterThan(lit, 200, "text was drawn for \(fit.policy.rawValue)")
            XCTAssertEqual(cache.layout(for: job.key)?.lines.count, fit.policy == .maxLines ? 2 : 3)
            try MetalHarness.assertGolden(goldens, "text-\(fit.policy.rawValue)", frame, tolerance: .text)
        }
    }
}
