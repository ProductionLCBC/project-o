import XCTest
import Metal
import OCore
@testable import OEngine

/// Spec 4 §5 — "Everything the render thread touches is allocated before it
/// is needed ... Allocation happens at three moments only: show load, a stack
/// or output change (between ticks ...), and a decoder session start on the
/// decode thread. Never on the render thread." The backend's own scratch
/// textures, the full-size one of a gamma-blend stack (Spec 4 §9) and the
/// half-size pair of a blurring channel (Spec 4 §7), are made when a plan is
/// prepared, on the control side, and follow a stack or a channel that
/// changes size (Area 14). And Spec 4 §1 — "A missing frame is a repeat,
/// never black": the display encode says when it drew nothing.
final class MetalScratchTests: XCTestCase {
    var backend: MetalBackend!
    let small = PixelSize(width: 96, height: 54)
    let large = PixelSize(width: 192, height: 108)

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    /// A gamma-blend stack pass at `size`: white at half opacity over black.
    func gammaPass(stack: Int, size: PixelSize) -> StackPass {
        let white = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "white")
        let full = PixelRect(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
        let box = ResolvedBox(channel: 1, frame: full, content: .pixels(PixelQuad(texture: white, frame: full, uv: .full)), opacity: 0.5)
        let target = backend.makeTexture(TextureDescriptor(role: .stack, size: size, label: "stack \(stack)"))
        return StackPass(stack: stack, target: target, size: size, base: .black, gammaBlend: true, boxes: [box])
    }

    /// Encodes a plan as the render thread does, without preparing it, and reads a stack's centre pixel.
    func encode(_ pass: StackPass) throws -> LinearPixel {
        let receipt = backend.encode(TickTime(tick: 0, reference: .zero, wake: .zero), plan: FramePlan(frame: 0, stackPasses: [pass]),
                                     picks: PickedFrames(capacity: 4), options: EncodeOptions())
        backend.waitForCompletion(of: receipt)
        let frame = try XCTUnwrap(backend.readback(pass.target))
        return frame[pass.size.width / 2, pass.size.height / 2]
    }

    var encoded: LinearPixel {
        let half = ColorMath.srgbDecode(0.5)
        return LinearPixel(r: half, g: half, b: half, a: 1)
    }

    func test_aGammaBlendStacksScratchIsMadeInPrepareAndNeverInEncode() throws {
        let first = gammaPass(stack: 1, size: small)
        XCTAssertEqual(backend.scratchTexturesMade, 0)
        backend.prepare(FramePlan(frame: 0, stackPasses: [first]))
        XCTAssertEqual(backend.scratchTexturesMade, 1)
        MetalHarness.assertPixel(try encode(first), encoded, accuracy: 0.01, "composited in encoded space, linearized again")
        XCTAssertEqual(backend.scratchTexturesMade, 1)
        backend.prepare(FramePlan(frame: 1, stackPasses: [first]))
        XCTAssertEqual(backend.scratchTexturesMade, 1, "the same size: the scratch it has")

        // The stack changes size (Spec 4 §5): its next plan is prepared at the new size.
        let second = gammaPass(stack: 1, size: large)
        backend.prepare(FramePlan(frame: 2, stackPasses: [second]))
        XCTAssertEqual(backend.scratchTexturesMade, 2)
        // A plan from before the change, still to be encoded, finds the scratch of its own size.
        MetalHarness.assertPixel(try encode(first), encoded, accuracy: 0.01)
        MetalHarness.assertPixel(try encode(second), encoded, accuracy: 0.01)
        XCTAssertEqual(backend.scratchTexturesMade, 2, "encoding made nothing")

        // A pass no plan prepared: the render thread makes nothing for it, and draws it unlinearized.
        let unprepared = gammaPass(stack: 2, size: small)
        _ = try encode(unprepared)
        XCTAssertEqual(backend.scratchTexturesMade, 2)
    }

    /// Spec 4 §10 — the thumbnail job renders a stack at its own size on its
    /// own thread: its scratch is its own, and the live one stays.
    func test_theThumbnailJobsScratchIsItsOwn() throws {
        let live = gammaPass(stack: 1, size: large)
        backend.prepare(FramePlan(frame: 0, stackPasses: [live]))
        XCTAssertEqual(backend.scratchTexturesMade, 1)
        let offline = gammaPass(stack: 1, size: small)
        let thumbnail = backend.makeTexture(TextureDescriptor(role: .thumbnail, size: small, label: "thumbnail"))
        XCTAssertTrue(backend.renderOffline(offline, into: thumbnail))
        XCTAssertEqual(backend.scratchTexturesMade, 2)
        XCTAssertTrue(backend.renderOffline(offline, into: thumbnail))
        XCTAssertEqual(backend.scratchTexturesMade, 2, "the same size again: the one it has")
        MetalHarness.assertPixel(try encode(live), encoded, accuracy: 0.01, "the live stack's scratch was left alone")
        XCTAssertEqual(backend.scratchTexturesMade, 2)
    }

    /// Spec 4 §7 — "blur: a separable two-pass Gaussian at half resolution":
    /// the pair is half the channel's size, and made again when that changes.
    func test_aBlurringChannelsScratchFollowsItsSize() throws {
        let still = backend.makeStill(MetalHarness.solid(width: 8, height: 8, LinearPixel(r: 1, g: 0, b: 0, a: 1)), label: "red")
        var grade = GradeParameters.identity
        grade.blur = 8
        func pass(_ size: PixelSize) -> ChannelPass {
            let target = backend.makeTexture(TextureDescriptor(role: .channel, size: size, mipmapped: true, label: "channel 1"))
            return ChannelPass(channel: 1, target: target, size: size,
                               incoming: SourceBinding(source: .texture(still), layout: .linearRGBA16, matrix: .bt709, range: .full, size: PixelSize(width: 8, height: 8)),
                               grade: grade)
        }
        backend.prepare(FramePlan(frame: 0, channelPasses: [pass(small)]))
        XCTAssertEqual(backend.scratchTexturesMade, 2, "the pair")
        XCTAssertEqual(backend.blurScratchSize(channel: 1), PixelSize(width: 48, height: 27))
        backend.prepare(FramePlan(frame: 1, channelPasses: [pass(small)]))
        XCTAssertEqual(backend.scratchTexturesMade, 2)
        backend.prepare(FramePlan(frame: 2, channelPasses: [pass(large)]))
        XCTAssertEqual(backend.scratchTexturesMade, 4, "the channel changed size: a pair at half the new size")
        XCTAssertEqual(backend.blurScratchSize(channel: 1), PixelSize(width: 96, height: 54))
        let frame = try XCTUnwrap(MetalHarness.render(pass(large), backend: backend))
        XCTAssertGreaterThan(frame[96, 54].r, 0.5, "and the blurred picture still draws")
    }

    /// The display sink presents only what was drawn: a frame whose stack
    /// texture is gone (its stack was made again and the old ring freed,
    /// Spec 4 §5) draws nothing, and the encode says so.
    func test_theDisplayEncodeSaysWhenItDrewNothing() throws {
        let stack = backend.makeStill(MetalHarness.solid(width: 16, height: 16, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "stack")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgr10a2Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let drawable = try XCTUnwrap(backend.device.makeTexture(descriptor: descriptor))
        func frame(_ handle: TextureHandle) -> CompletedFrame {
            CompletedFrame(tick: 0, stack: handle, second: .none, mix: 0, destination: 0, receipt: EncodeReceipt(tick: 0, token: 0), referenceNs: 0)
        }
        let command = try XCTUnwrap(backend.queue.makeCommandBuffer())
        XCTAssertTrue(backend.encodeDisplay(frame(stack), into: drawable, command: command))
        backend.resources.release(stack, afterTick: 0)
        backend.resources.sweep(consumedTick: 10)
        XCTAssertFalse(backend.encodeDisplay(frame(stack), into: drawable, command: command), "its texture is gone: nothing was drawn")
        XCTAssertFalse(backend.encodeDisplay(frame(.none), into: drawable, command: command))
        command.commit()
    }
}
