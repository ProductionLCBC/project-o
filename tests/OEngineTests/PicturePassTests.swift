import XCTest
import IOSurface
import Metal
import OCore
@testable import OEngine
@testable import OMach

/// Spec 4 §10 and Spec 10 §2 (choice U-3) — the channel picture: "Another aux
/// pass, at most 30 times a second like the previews, makes a live picture of
/// each channel with pixel content for the operator app's channel strip: its
/// channel texture fit into 256 by 144 over black, filtered in one pass so it
/// doesn't alias, without a mip chain"; "A channel whose media is missing
/// gets a black picture, never its texture's old pixels"; "the pictures are
/// skipped first under GPU pressure". Spec 10 §18, Area 19, the Mach channel.
final class PicturePassTests: XCTestCase {
    var backend: MetalBackend!

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    let red = LinearPixel(r: 1, g: 0, b: 0, a: 1)
    let green = LinearPixel(r: 0, g: 1, b: 0, a: 1)
    let black = LinearPixel(r: 0, g: 0, b: 0, a: 1)

    /// Red on the left half, green on the right.
    func halves(width: Int, height: Int) -> CapturedFrame {
        var frame = CapturedFrame(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { frame[x, y] = x < width / 2 ? red : green }
        }
        return frame
    }

    func pictureTarget() -> TextureHandle {
        backend.makeTexture(TextureDescriptor(role: .preview, size: ControlLoop.pictureSize, label: "picture"))
    }

    func draw(_ source: TextureHandle, into target: TextureHandle, clear: Bool = false, options: EncodeOptions = EncodeOptions(), frame: Int64 = 0) throws -> CapturedFrame {
        let plan = FramePlan(frame: frame, auxPasses: [AuxPass(kind: .picture, stack: 0, source: source, target: target, channel: 1, clear: clear)])
        backend.prepare(plan)
        let receipt = backend.encode(TickTime(tick: frame, reference: .zero, wake: .zero), plan: plan, picks: PickedFrames(capacity: 4), options: options)
        backend.waitForCompletion(of: receipt)
        return try XCTUnwrap(backend.readback8(target))
    }

    func test_thePictureIsASurfaceOf256By144() throws {
        let target = pictureTarget()
        let texture = try XCTUnwrap(backend.resources.object(target) as? MTLTexture)
        XCTAssertEqual(texture.width, 256)
        XCTAssertEqual(texture.height, 144)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm_srgb)
        let surface = try XCTUnwrap(backend.surface(of: target), "backed by an IOSurface, which is what the Mach channel sends")
        XCTAssertEqual(IOSurfaceGetWidth(surface), 256)
        XCTAssertEqual(IOSurfaceGetHeight(surface), 144)
    }

    /// A 16:9 channel fills the picture; every picture pixel is the mean of
    /// the block it covers, so a pattern of single-pixel checks comes out an
    /// even grey instead of the moiré a single tap would give.
    func test_aSixteenByNineChannelFillsThePictureAndDoesNotAlias() throws {
        var checks = CapturedFrame(width: 1024, height: 576)
        for y in 0..<576 {
            for x in 0..<1024 {
                let lit = (x + y) % 2 == 0
                checks[x, y] = x < 512 ? (lit ? LinearPixel(r: 1, g: 1, b: 1, a: 1) : black) : green
            }
        }
        let picture = try draw(backend.makeStill(checks, label: "checks"), into: pictureTarget())
        XCTAssertEqual(picture.width, 256)
        XCTAssertEqual(picture.height, 144)
        for (x, y) in [(3, 3), (60, 70), (126, 140), (17, 101)] {
            MetalHarness.assertPixel(picture[x, y], LinearPixel(r: 0.5, g: 0.5, b: 0.5, a: 1), accuracy: 0.02, "the checks average to mid grey in linear light at \(x),\(y)")
        }
        MetalHarness.assertPixel(picture[130, 70], green, accuracy: 0.01, "right of the middle, the plain half")
        MetalHarness.assertPixel(picture[255, 143], green, accuracy: 0.01, "to the last pixel: nothing outside the picture")
    }

    /// "fit into 256 by 144 over black": a channel of another shape keeps its
    /// shape, centred, and the rest of the picture is black and opaque.
    func test_aChannelOfAnotherShapeIsFitOverBlack() throws {
        let goldens = MetalHarness.goldens("aux")
        // A square channel: 144 by 144 in the middle, columns 56 to 199.
        let square = try draw(backend.makeStill(halves(width: 96, height: 96), label: "square"), into: pictureTarget())
        MetalHarness.assertPixel(square[20, 72], black, "left of the picture: black, and opaque")
        MetalHarness.assertPixel(square[54, 72], black, "to its edge")
        MetalHarness.assertPixel(square[58, 72], red, accuracy: 0.01, "the left half")
        MetalHarness.assertPixel(square[126, 5], red, accuracy: 0.01)
        MetalHarness.assertPixel(square[130, 140], green, accuracy: 0.01, "the right half")
        MetalHarness.assertPixel(square[197, 72], green, accuracy: 0.01)
        MetalHarness.assertPixel(square[202, 72], black, "right of it")
        try MetalHarness.assertGolden(goldens, "picture-square", square)

        // A channel wider than 16:9: full width, rows 48 to 95.
        let wide = try draw(backend.makeStill(halves(width: 384, height: 72), label: "wide"), into: pictureTarget())
        MetalHarness.assertPixel(wide[60, 20], black, "above")
        MetalHarness.assertPixel(wide[60, 46], black)
        MetalHarness.assertPixel(wide[60, 50], red, accuracy: 0.01)
        MetalHarness.assertPixel(wide[200, 93], green, accuracy: 0.01)
        MetalHarness.assertPixel(wide[200, 98], black, "below")
        try MetalHarness.assertGolden(goldens, "picture-wide", wide)
    }

    /// The channel texture is premultiplied: over black its colour is the
    /// picture's, and the picture is opaque wherever the strip shows it.
    func test_aTranslucentChannelIsShownOverBlack() throws {
        let half = MetalHarness.solid(width: 64, height: 36, LinearPixel(r: 0.5, g: 0, b: 0, a: 0.5))   // red at half opacity, premultiplied
        let picture = try draw(backend.makeStill(half, label: "half"), into: pictureTarget())
        MetalHarness.assertPixel(picture[128, 72], LinearPixel(r: 0.5, g: 0, b: 0, a: 1), accuracy: 0.01, "half red over black, opaque")
        let clear = MetalHarness.solid(width: 64, height: 36, LinearPixel(r: 0, g: 0, b: 0, a: 0))
        let empty = try draw(backend.makeStill(clear, label: "clear"), into: pictureTarget())
        MetalHarness.assertPixel(empty[128, 72], black, "a clear channel reads black, not transparent")
    }

    /// "A channel whose media is missing gets a black picture, never its texture's old pixels."
    func test_aMissingChannelsPictureIsBlackWhateverItsTextureHolds() throws {
        let source = backend.makeStill(halves(width: 64, height: 36), label: "old pixels")
        let target = pictureTarget()
        let before = try draw(source, into: target)
        MetalHarness.assertPixel(before[40, 72], red, accuracy: 0.01)
        let after = try draw(source, into: target, clear: true, frame: 1)
        XCTAssertTrue(after.pixels.allSatisfy { $0.r == 0 && $0.g == 0 && $0.b == 0 && $0.a == 1 }, "black and opaque, every pixel")
    }

    /// "the pictures are skipped first under GPU pressure": the surface holds what it had.
    func test_thePictureIsSkippedUnderPressureAndTheSurfaceHolds() throws {
        let target = pictureTarget()
        let drawn = try draw(backend.makeStill(halves(width: 64, height: 36), label: "halves"), into: target)
        MetalHarness.assertPixel(drawn[40, 72], red, accuracy: 0.01)
        let held = try draw(backend.makeStill(MetalHarness.solid(width: 64, height: 36, green), label: "green"), into: target,
                            options: EncodeOptions(skipAux: true), frame: 1)
        MetalHarness.assertPixel(held[40, 72], red, accuracy: 0.01, "not drawn: the last picture holds")
    }

    /// Where the channel lands and how many of its pixels each picture pixel takes in.
    func test_theFitAndTheTaps() {
        let hd = MetalBackend.pictureUniforms(source: PixelSize(width: 1920, height: 1080), target: ControlLoop.pictureSize)
        XCTAssertEqual(hd.fit, SIMD4(0, 0, 1, 1), "16:9 fills it")
        XCTAssertEqual(hd.taps.x, 8, "7.5 channel pixels to a picture pixel: eight taps each way")
        XCTAssertEqual(hd.taps.y, 8)
        let square = MetalBackend.pictureUniforms(source: PixelSize(width: 96, height: 96), target: ControlLoop.pictureSize)
        XCTAssertEqual(square.fit.x, 0.21875, accuracy: 1e-6, "56 of 256")
        XCTAssertEqual(square.fit.z, 0.5625, accuracy: 1e-6, "144 of 256")
        XCTAssertEqual(square.fit.y, 0)
        XCTAssertEqual(square.fit.w, 1)
        XCTAssertEqual(square.taps.x, 1, "a channel smaller than its picture takes one tap")
        let uhd = MetalBackend.pictureUniforms(source: PixelSize(width: 7680, height: 4320), target: ControlLoop.pictureSize)
        XCTAssertEqual(uhd.taps.x, 30, "8K: thirty each way, under the cap of 32")
    }
}

/// Spec 10 §2, the Mach channel, end to end over Metal: what the client maps
/// from the ports it was sent is what the engine drew.
final class MetalMachChannelTests: XCTestCase {
    func lit(_ pixel: [UInt8]?) -> Bool {
        guard let pixel, pixel.count >= 3 else { return false }
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) > 90
    }

    func test_theClientReadsTheStacksPreviewAndTheChannelsPictureFromTheSurfacesItWasSent() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        media: EngineFixtures.media, metal: metal)
        let channel = try engine.engine.openMachChannel()
        defer { channel.stop() }
        let client = MachClient()
        defer { client.disconnect() }
        try client.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { client.state.previewSets == 2 && client.state.pictureSets == 3 }, "the surfaces arrive at connect")
        XCTAssertEqual(client.state.previews[1]?.width, 120, "a quarter of the 480-wide main stack")
        XCTAssertEqual(client.state.previews[1]?.height, 67)
        XCTAssertEqual(client.state.pictures[1]?.width, 256)
        XCTAssertEqual(client.state.pictures[1]?.height, 144)

        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.send("channel 2 write text \"Amen\"")
        var live = false
        for _ in 0..<200 where !live {
            engine.tick()
            if case .instance? = engine.lastPlan?.channelPasses.first(where: { $0.channel == 1 })?.incoming.source { live = true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(live, "the clip decodes")
        let before = (client.state.previewFrames.count, client.state.pictureFrames.count)
        engine.tick(count: 6)
        XCTAssertTrue(waitUntil(5) { client.state.previewFrames.count > before.0 && client.state.pictureFrames.count > before.1 }, "frames are named as they finish")

        // The client's own mapping of the newest surfaces: the stack with the clip and the text, and the clip's picture.
        var previewLit = 0
        var pictureLit = 0
        for y in stride(from: 2, to: 66, by: 4) {
            for x in stride(from: 2, to: 118, by: 4) where lit(client.previewPixel(stack: 1, x: x, y: y)) { previewLit += 1 }
        }
        for y in stride(from: 2, to: 142, by: 6) {
            for x in stride(from: 2, to: 254, by: 6) where lit(client.picturePixel(channel: 1, x: x, y: y)) { pictureLit += 1 }
        }
        XCTAssertGreaterThan(previewLit, 20, "the main stack's preview shows what is on it")
        XCTAssertGreaterThan(pictureLit, 50, "channel 1's picture shows the clip")
        XCTAssertEqual(client.picturePixel(channel: 1, x: 128, y: 72)?.last, 255, "opaque")
        XCTAssertNil(client.state.newestPicture[2], "text gets no picture")
        XCTAssertNil(client.state.newestPicture[3], "nor an empty channel")
        XCTAssertEqual(metal.missingPipelineCount, 0)
    }
}
