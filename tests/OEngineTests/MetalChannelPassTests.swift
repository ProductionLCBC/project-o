import XCTest
import OCore
@testable import OEngine

/// Spec 4 §7 — the channel pass on the GPU: stage 1 against the CPU reference
/// for every source layout (Spec 4 §16, Colour), the letterboxed fit, the
/// grade, the three transitions and the snapshot, with goldens (Spec 4 §16:
/// "each transition type at 0, 0.5 and 1; ... each grade parameter at two
/// values").
final class MetalChannelPassTests: XCTestCase {
    var backend: MetalBackend!

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    func target(_ width: Int, _ height: Int, label: String = "target") -> TextureHandle {
        backend.makeTexture(TextureDescriptor(role: .channel, size: PixelSize(width: width, height: height), mipmapped: true, label: label))
    }

    func binding(_ handle: TextureHandle, layout: SourceLayout, size: PixelSize) -> SourceBinding {
        SourceBinding(source: .texture(handle), layout: layout, matrix: .bt709, range: .full, size: size)
    }

    // MARK: - Colour through each layout (Spec 4 §16)

    struct LayoutCase {
        var layout: SourceLayout
        var planes: [Data]
        var range: ColorRange
        var expected: LinearPixel
        var name: String
    }

    func ycbcrPlanes(_ layout: SourceLayout, width: Int, height: Int, y: Int, cb: Int, cr: Int) -> [Data] {
        switch layout {
        case .nv12:
            let luma = Data(repeating: UInt8(y), count: width * height)
            var chroma = Data(count: (width / 2) * (height / 2) * 2)
            for i in 0..<((width / 2) * (height / 2)) {
                chroma[i * 2] = UInt8(cb)
                chroma[i * 2 + 1] = UInt8(cr)
            }
            return [luma, chroma]
        default:
            let chromaHeight = layout == .p010 ? height / 2 : height
            var luma = Data(count: width * height * 2)
            luma.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt16.self)
                for i in 0..<(width * height) { p[i] = UInt16(y) << 6 }
            }
            var chroma = Data(count: (width / 2) * chromaHeight * 4)
            chroma.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt16.self)
                for i in 0..<((width / 2) * chromaHeight) {
                    p[i * 2] = UInt16(cb) << 6
                    p[i * 2 + 1] = UInt16(cr) << 6
                }
            }
            return [luma, chroma]
        }
    }

    func referenceYCbCr(_ layout: SourceLayout, y: Int, cb: Int, cr: Int, range: ColorRange) -> LinearPixel {
        let scale = ColorMath.codeScale(for: layout)
        if layout == .nv12 {
            return ColorMath.stage1YCbCr(y: Float(y) / 255, cb: Float(cb) / 255, cr: Float(cr) / 255, layout: layout, matrix: .bt709, range: range)
        }
        func u16(_ code: Int) -> Float { Float(code << 6) / 65535 * scale }
        return ColorMath.stage1YCbCr(y: u16(y), cb: u16(cb), cr: u16(cr), layout: layout, matrix: .bt709, range: range)
    }

    func test_stage1MatchesTheReferenceForEveryLayout() throws {
        let size = PixelSize(width: 8, height: 8)
        var cases: [LayoutCase] = []
        for (y, cb, cr, name) in [(16, 128, 128, "black"), (235, 128, 128, "white"), (126, 128, 128, "grey"), (63, 102, 240, "red"), (32, 240, 118, "blue")] {
            cases.append(LayoutCase(layout: .nv12, planes: ycbcrPlanes(.nv12, width: 8, height: 8, y: y, cb: cb, cr: cr), range: .limited,
                                    expected: referenceYCbCr(.nv12, y: y, cb: cb, cr: cr, range: .limited), name: "nv12 " + name))
        }
        for layout in [SourceLayout.p010, .yuv422p10] {
            for (y, cb, cr, name) in [(64, 512, 512, "black"), (940, 512, 512, "white"), (502, 512, 512, "grey"), (250, 409, 960, "red")] {
                cases.append(LayoutCase(layout: layout, planes: ycbcrPlanes(layout, width: 8, height: 8, y: y, cb: cb, cr: cr), range: .limited,
                                        expected: referenceYCbCr(layout, y: y, cb: cb, cr: cr, range: .limited), name: "\(layout.rawValue) " + name))
            }
        }
        // RGBA16 straight alpha: half-float 0.5 everywhere.
        var halves = Data(count: 8 * 8 * 8)
        halves.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float16.self)
            for i in 0..<(8 * 8 * 4) { p[i] = Float16(0.5) }
        }
        cases.append(LayoutCase(layout: .rgba16, planes: [halves], range: .full, expected: ColorMath.stage1RGBA(r: 0.5, g: 0.5, b: 0.5, a: 0.5), name: "rgba16 half"))
        // BGRA8 sRGB premultiplied: 128 grey, opaque.
        var bgra = Data(count: 8 * 8 * 4)
        for i in 0..<(8 * 8) {
            bgra[i * 4] = 128
            bgra[i * 4 + 1] = 128
            bgra[i * 4 + 2] = 128
            bgra[i * 4 + 3] = 255
        }
        let grey = ColorMath.srgbDecode(128 / 255)
        cases.append(LayoutCase(layout: .bgra8sRGB, planes: [bgra], range: .full, expected: LinearPixel(r: grey, g: grey, b: grey, a: 1), name: "bgra8 sRGB grey"))
        // Linear RGBA16: pass-through.
        var linear = Data(count: 8 * 8 * 8)
        linear.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float16.self)
            for i in 0..<(8 * 8) {
                p[i * 4] = Float16(0.25)
                p[i * 4 + 1] = Float16(0.5)
                p[i * 4 + 2] = Float16(0.75)
                p[i * 4 + 3] = Float16(1)
            }
        }
        cases.append(LayoutCase(layout: .linearRGBA16, planes: [linear], range: .full, expected: LinearPixel(r: 0.25, g: 0.5, b: 0.75, a: 1), name: "linear"))

        for c in cases {
            guard let planes = backend.makePlanes(layout: c.layout, size: size, planes: c.planes) else { return XCTFail("planes for \(c.name)") }
            let picks = PickedFrames(capacity: 4)
            picks[0] = planes
            picks.setResult(.frame, at: 0)
            let pass = ChannelPass(channel: 1, target: target(8, 8), size: size,
                                   incoming: SourceBinding(source: .instance(InstanceHandle(rawValue: 0), mediaTimeMs: 0), layout: c.layout,
                                                           matrix: .bt709, range: c.range, size: size))
            guard let frame = MetalHarness.render(pass, picks: picks, backend: backend) else { return XCTFail("render \(c.name)") }
            MetalHarness.assertPixel(frame[4, 4], c.expected, accuracy: 0.004, c.name)
        }
    }

    func test_bt601AndBt2020MatricesReachTheShader() throws {
        let size = PixelSize(width: 8, height: 8)
        for matrix in [ColorMatrix.bt601, .bt2020] {
            guard let planes = backend.makePlanes(layout: .nv12, size: size, planes: ycbcrPlanes(.nv12, width: 8, height: 8, y: 63, cb: 102, cr: 240)) else { return XCTFail() }
            let picks = PickedFrames(capacity: 4)
            picks[0] = planes
            let pass = ChannelPass(channel: 1, target: target(8, 8), size: size,
                                   incoming: SourceBinding(source: .instance(InstanceHandle(rawValue: 0), mediaTimeMs: 0), layout: .nv12,
                                                           matrix: matrix, range: .limited, size: size))
            guard let frame = MetalHarness.render(pass, picks: picks, backend: backend) else { return XCTFail() }
            let expected = ColorMath.stage1YCbCr(y: 63 / 255, cb: 102 / 255, cr: 240 / 255, layout: .nv12, matrix: matrix, range: .limited)
            MetalHarness.assertPixel(frame[4, 4], expected, accuracy: 0.004, matrix.rawValue)
        }
    }

    // MARK: - Fit (Spec 4 §7)

    func test_sourceIsLetterboxedWithTransparentPixels() throws {
        let still = backend.makeStill(MetalHarness.solid(width: 8, height: 6, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "4:3")
        let size = PixelSize(width: 16, height: 9)
        let pass = ChannelPass(channel: 1, target: target(16, 9), size: size, incoming: binding(still, layout: .linearRGBA16, size: PixelSize(width: 8, height: 6)))
        guard let frame = MetalHarness.render(pass, backend: backend) else { return XCTFail() }
        // 4:3 into 16:9: the content is 12 pixels wide, centred, with 2-pixel transparent bars.
        MetalHarness.assertPixel(frame[0, 4], .transparent, "left bar")
        MetalHarness.assertPixel(frame[15, 4], .transparent, "right bar")
        MetalHarness.assertPixel(frame[8, 4], LinearPixel(r: 1, g: 1, b: 1, a: 1), "centre")
        XCTAssertEqual(ControlLoop.contentRect(source: PixelSize(width: 8, height: 6), channel: size), UVRect(u: 0.125, v: 0, width: 0.75, height: 1))
    }

    // MARK: - Transitions and grades with goldens (Spec 4 §16)

    func gradientA() -> CapturedFrame { MetalHarness.gradient(width: 64, height: 36, from: LinearPixel(r: 1, g: 0.2, b: 0.1, a: 1), to: LinearPixel(r: 0.1, g: 0.2, b: 1, a: 1)) }
    func gradientB() -> CapturedFrame { MetalHarness.gradient(width: 64, height: 36, from: LinearPixel(r: 0, g: 0.8, b: 0.2, a: 1), to: LinearPixel(r: 0.9, g: 0.9, b: 0, a: 1)) }

    func test_transitionsAtThreePointsMatchTheReferenceAndTheGoldens() throws {
        let goldens = MetalHarness.goldens("channel")
        let a = gradientA()
        let b = gradientB()
        let incoming = backend.makeStill(b, label: "incoming")
        let outgoing = backend.makeStill(a, label: "outgoing")
        let size = PixelSize(width: 64, height: 36)
        for type in [TransitionType.cut, .dissolve, .fadeThroughColor] {
            for progress in [Float(0), 0.5, 1] {
                let pass = ChannelPass(channel: 1, target: target(64, 36), size: size,
                                       incoming: binding(incoming, layout: .linearRGBA16, size: size),
                                       outgoing: binding(outgoing, layout: .linearRGBA16, size: size),
                                       transition: TransitionState(type: type, progress: progress, color: ColorValue(r: 0, g: 0, b: 0, a: 1)))
                guard let frame = MetalHarness.render(pass, backend: backend) else { return XCTFail("\(type) \(progress)") }
                let x = 20
                let y = 10
                let expected = BuiltInTransition(type).mix(outgoing: a[x, y], incoming: b[x, y], progress: progress, color: ColorValue(r: 0, g: 0, b: 0, a: 1))
                MetalHarness.assertPixel(frame[x, y], expected, accuracy: 0.01, "\(type.rawValue) at \(progress)")
                try MetalHarness.assertGolden(goldens, "transition-\(type.rawValue)-\(progress)", frame)
            }
        }
    }

    func test_eachGradeParameterAtTwoValuesMatchesTheReferenceAndTheGoldens() throws {
        let goldens = MetalHarness.goldens("channel")
        let a = gradientA()
        let still = backend.makeStill(a, label: "graded")
        let size = PixelSize(width: 64, height: 36)
        var cases: [(String, GradeParameters)] = []
        for hue in [Float(45), -90] { var g = GradeParameters.identity; g.hue = hue; cases.append(("hue-\(Int(hue))", g)) }
        for s in [Float(0), 1.5] { var g = GradeParameters.identity; g.saturation = s; cases.append(("saturation-\(s)", g)) }
        for v in [Float(-0.5), 0.5] { var g = GradeParameters.identity; g.brightness = v; cases.append(("brightness-\(v)", g)) }
        for v in [Float(0.5), 1.5] { var g = GradeParameters.identity; g.contrast = v; cases.append(("contrast-\(v)", g)) }
        for v in [Float(0.3), 0.7] { var g = GradeParameters.identity; g.opacity = v; cases.append(("opacity-\(v)", g)) }
        for (name, tint) in [("tint-warm", ColorValue(r: 1, g: 0.85, b: 0.6, a: 0.5)), ("tint-blue", ColorValue(r: 0.2, g: 0.4, b: 1, a: 1))] {
            var g = GradeParameters.identity
            g.tint = tint
            cases.append((name, g))
        }
        for (name, g) in cases {
            let pass = ChannelPass(channel: 1, target: target(64, 36), size: size, incoming: binding(still, layout: .linearRGBA16, size: size), grade: g)
            guard let frame = MetalHarness.render(pass, backend: backend) else { return XCTFail(name) }
            MetalHarness.assertPixel(frame[20, 10], ColorMath.grade(a[20, 10], g), accuracy: 0.01, name)
            try MetalHarness.assertGolden(goldens, "grade-" + name, frame)
        }
    }

    func test_blurAtTwoRadiiSoftensAndMatchesTheGoldens() throws {
        let goldens = MetalHarness.goldens("channel")
        // A hard vertical edge: white left half, black right half.
        var edge = CapturedFrame(width: 64, height: 36)
        for y in 0..<36 { for x in 0..<64 { edge[x, y] = x < 32 ? LinearPixel(r: 1, g: 1, b: 1, a: 1) : LinearPixel(r: 0, g: 0, b: 0, a: 1) } }
        let still = backend.makeStill(edge, label: "edge")
        let size = PixelSize(width: 64, height: 36)
        for radius in [Float(4), 12] {
            var g = GradeParameters.identity
            g.blur = radius
            let pass = ChannelPass(channel: 1, target: target(64, 36), size: size, incoming: binding(still, layout: .linearRGBA16, size: size), grade: g)
            guard let frame = MetalHarness.render(pass, backend: backend) else { return XCTFail() }
            let atEdge = frame[32, 18].r
            XCTAssertGreaterThan(atEdge, 0.2, "the edge is softened at radius \(radius)")
            XCTAssertLessThan(atEdge, 0.8)
            XCTAssertGreaterThan(frame[2, 18].r, 0.95, "far from the edge the picture is untouched")
            try MetalHarness.assertGolden(goldens, "blur-\(Int(radius))", frame, tolerance: GoldenTolerance(maxCodeDifference: 4, meanCodeDifference: 1))
        }
        // Under pressure the blur is dropped (Spec 4 §12) and the edge stays hard.
        var g = GradeParameters.identity
        g.blur = 12
        let pass = ChannelPass(channel: 1, target: target(64, 36), size: size, incoming: binding(still, layout: .linearRGBA16, size: size), grade: g)
        guard let hard = MetalHarness.render(pass, backend: backend, options: EncodeOptions(skipAux: true, dropExtras: true)) else { return XCTFail() }
        XCTAssertGreaterThan(hard[30, 18].r, 0.95)
    }

    // MARK: - Snapshot (Spec 4 §7, Area 4 reading)

    func test_snapshotCopiesThePictureBeforeRendering() throws {
        let a = gradientA()
        let b = gradientB()
        let size = PixelSize(width: 64, height: 36)
        let targetHandle = target(64, 36)
        let snapshot = backend.makeTexture(TextureDescriptor(role: .channel, size: size, label: "snapshot"))
        let stillA = backend.makeStill(a, label: "a")
        let stillB = backend.makeStill(b, label: "b")
        // Tick 1: A on the channel.
        _ = MetalHarness.render(ChannelPass(channel: 1, target: targetHandle, size: size, incoming: binding(stillA, layout: .linearRGBA16, size: size)), backend: backend)
        // Tick 2: a dissolve to B from the snapshot of what was there.
        let pass = ChannelPass(channel: 1, target: targetHandle, size: size, incoming: binding(stillB, layout: .linearRGBA16, size: size),
                               outgoing: binding(snapshot, layout: .finished, size: size),
                               transition: TransitionState(type: .dissolve, progress: 0.5, color: nil), snapshotOutgoing: true)
        guard let frame = MetalHarness.render(pass, backend: backend, tick: 1), let copied = backend.readback(snapshot) else { return XCTFail() }
        MetalHarness.assertPixel(copied[20, 10], a[20, 10], accuracy: 0.004, "the snapshot holds the previous picture")
        MetalHarness.assertPixel(frame[20, 10], LinearPixel.lerp(a[20, 10], b[20, 10], 0.5), accuracy: 0.01, "and the dissolve runs from it")
        XCTAssertEqual(backend.snapshotCount, 1)
    }

    func test_gradeIsNotAppliedTwiceToASnapshot() throws {
        let size = PixelSize(width: 8, height: 8)
        let white = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "white")
        var g = GradeParameters.identity
        g.opacity = 0.5
        let pass = ChannelPass(channel: 1, target: target(8, 8), size: size, incoming: binding(white, layout: .finished, size: size),
                               outgoing: binding(white, layout: .finished, size: size),
                               transition: TransitionState(type: .dissolve, progress: 0.5, color: nil), grade: g)
        guard let frame = MetalHarness.render(pass, backend: backend) else { return XCTFail() }
        MetalHarness.assertPixel(frame[4, 4], LinearPixel(r: 1, g: 1, b: 1, a: 1), "finished pixels keep their grade")
    }

    // MARK: - Completion and metrics (Spec 4 §13)

    func test_completionReportsGPUTimeAfterTheWorkIsDone() throws {
        let size = PixelSize(width: 64, height: 36)
        let still = backend.makeStill(gradientA(), label: "a")
        let plan = FramePlan(frame: 3, channelPasses: [ChannelPass(channel: 1, target: target(64, 36), size: size, incoming: binding(still, layout: .linearRGBA16, size: size), generateMips: true)])
        backend.prepare(plan)
        let receipt = backend.encode(TickTime(tick: 3, reference: .zero, wake: .zero), plan: plan, picks: PickedFrames(capacity: 4), options: EncodeOptions())
        backend.waitForCompletion(of: receipt)
        let completion = try XCTUnwrap(backend.completion(of: receipt))
        XCTAssertFalse(completion.failed)
        XCTAssertGreaterThanOrEqual(completion.channelNs, 0)
        XCTAssertEqual(backend.missingPipelineCount, 0)
    }
}
