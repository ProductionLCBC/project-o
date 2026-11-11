import XCTest
import IOSurface
import Metal
import OCore
@testable import OEngine

/// Spec 4 §10 — "Multiviewer and preview. Aux passes downscale the stack
/// textures into small BGRA8 sRGB textures at most 30 times a second, backed
/// by IOSurfaces." Spec 4 §5 — "a quarter-size multiviewer". Spec 4 §4 step 5
/// — "Encode aux passes only if the previous tick's GPU time left headroom;
/// otherwise skip them and count the skip." Area 5 reading, approved on
/// 2026-11-03: the multiviewer is the app's arrangement of one quarter-size
/// preview per stack, and a stack no output feeds renders at the preview rate
/// as aux-only work.
final class PreviewPassTests: XCTestCase {
    var backend: MetalBackend!

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    /// A 96×52 stack: red left half, green right half, a band of pixel checks
    /// (white and black) across rows 24 to 27 that averages to mid grey.
    func picture() -> CapturedFrame {
        var frame = CapturedFrame(width: 96, height: 52)
        for y in 0..<52 {
            for x in 0..<96 {
                if (24..<28).contains(y) {
                    frame[x, y] = (x + y) % 2 == 0 ? LinearPixel(r: 1, g: 1, b: 1, a: 1) : LinearPixel(r: 0, g: 0, b: 0, a: 1)
                } else {
                    frame[x, y] = x < 48 ? LinearPixel(r: 1, g: 0, b: 0, a: 1) : LinearPixel(r: 0, g: 1, b: 0, a: 1)
                }
            }
        }
        return frame
    }

    func previewTarget() -> TextureHandle {
        backend.makeTexture(TextureDescriptor(role: .preview, size: PixelSize(width: 24, height: 13), label: "preview"))
    }

    func encode(_ plan: FramePlan, options: EncodeOptions = EncodeOptions()) {
        backend.prepare(plan)
        let receipt = backend.encode(TickTime(tick: plan.frame, reference: .zero, wake: .zero), plan: plan, picks: PickedFrames(capacity: 4), options: options)
        backend.waitForCompletion(of: receipt)
    }

    func test_previewIsAQuarterSizeAverageInASurfaceBackedTexture() throws {
        let goldens = MetalHarness.goldens("aux")
        let stack = backend.makeStill(picture(), label: "stack")
        let preview = previewTarget()
        let texture = try XCTUnwrap(backend.resources.object(preview) as? MTLTexture)
        XCTAssertNotNil(texture.iosurface, "Spec 4 §10: backed by an IOSurface")
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm_srgb)
        XCTAssertNotNil(backend.surfaceID(of: preview), "the surface id the app will map")
        encode(FramePlan(frame: 0, auxPasses: [AuxPass(kind: .preview, stack: 1, source: stack, target: preview)]))
        let frame = try XCTUnwrap(backend.readback8(preview))
        XCTAssertEqual(frame.width, 24)
        XCTAssertEqual(frame.height, 13)
        MetalHarness.assertPixel(frame[2, 3], LinearPixel(r: 1, g: 0, b: 0, a: 1), accuracy: 0.01, "left: red")
        MetalHarness.assertPixel(frame[21, 3], LinearPixel(r: 0, g: 1, b: 0, a: 1), accuracy: 0.01, "right: green")
        MetalHarness.assertPixel(frame[11, 6], LinearPixel(r: 0.5, g: 0.5, b: 0.5, a: 1), accuracy: 0.02, "the checks average to mid grey, in linear light")
        MetalHarness.assertPixel(frame[11, 9], LinearPixel(r: 1, g: 0, b: 0, a: 1), accuracy: 0.01, "below the band, left of the middle: red")
        MetalHarness.assertPixel(frame[12, 9], LinearPixel(r: 0, g: 1, b: 0, a: 1), accuracy: 0.01, "right of the middle: green")
        try MetalHarness.assertGolden(goldens, "preview-quarter", frame)
    }

    /// Spec 4 §4 step 5 — skipped under pressure: the texture holds what it had.
    func test_previewIsSkippedUnderPressureAndTheTextureHolds() throws {
        let stack = backend.makeStill(picture(), label: "stack")
        let preview = previewTarget()
        let pass = AuxPass(kind: .preview, stack: 1, source: stack, target: preview)
        encode(FramePlan(frame: 0, auxPasses: [pass]), options: EncodeOptions(skipAux: true))
        let untouched = try XCTUnwrap(backend.readback8(preview))
        XCTAssertEqual(untouched[2, 3].a, 0, "a fresh surface, never drawn")
        encode(FramePlan(frame: 1, auxPasses: [pass]))
        let drawn = try XCTUnwrap(backend.readback8(preview))
        MetalHarness.assertPixel(drawn[2, 3], LinearPixel(r: 1, g: 0, b: 0, a: 1), accuracy: 0.01)
        encode(FramePlan(frame: 2, auxPasses: [AuxPass(kind: .preview, stack: 1, source: backend.makeStill(MetalHarness.solid(width: 8, height: 8, .black), label: "black"), target: preview)]),
               options: EncodeOptions(skipAux: true))
        let held = try XCTUnwrap(backend.readback8(preview))
        MetalHarness.assertPixel(held[2, 3], LinearPixel(r: 1, g: 0, b: 0, a: 1), accuracy: 0.01, "the previous preview holds under pressure")
    }
}

/// The plan side of the previews: their rate, their source and the stacks no
/// output feeds (Spec 4 §2, §10; Area 5 reading).
final class PreviewPlanTests: XCTestCase {
    func test_previewsRunAtMostThirtyTimesASecondAndCarryTheirSource() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        let backend = try XCTUnwrap(engine.recording)
        engine.tick(count: 4)
        XCTAssertEqual(backend.encoded.map(\.auxPasses), [2, 0, 2, 0], "at 60 Hz every other tick carries the two stacks' previews")
        engine.tick()   // frame 4
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.auxPasses.map(\.kind), [.preview, .preview])
        for aux in plan.auxPasses {
            let stack = try XCTUnwrap(plan.stackPasses.first { $0.stack == aux.stack })
            XCTAssertEqual(aux.source, stack.target, "the preview downscales this tick's stack texture")
            XCTAssertEqual(aux.target, engine.control.previewTargets[aux.stack])
        }
        // A 30 Hz master: every tick is a preview tick.
        let slow = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(rate: FrameRate(num: 30)), mediaRoot: EngineFixtures.mediaRoot)
        slow.tick(count: 3)
        XCTAssertEqual(try XCTUnwrap(slow.recording).encoded.map(\.auxPasses), [2, 2, 2])
    }

    /// Area 5 reading — "the preview counts as a consumer at the preview rate":
    /// a stack no output feeds renders on preview ticks only, as aux-only work
    /// the render thread drops first under pressure, with the channels only it
    /// samples.
    func test_anUnassignedStackRendersOnPreviewTicksAsAuxOnlyWork() throws {
        var machine = try EngineFixtures.spikeMachine()
        var library = try EngineFixtures.library()
        machine.outputs.removeLast()                           // stack 2 feeds no output
        machine.stacks[0].slots = [StackSlot(channel: 2)]       // the main stack samples channel 2 only
        // Spec 6 §3 — Preset 1's "2" layout has no pixel box, so channel 1's picture on stack 2 takes a preset of its own.
        library.presets.append(Preset(number: 8, label: "Picture", uuid: EngineFixtures.uuid("c0de", 8),
                                      layouts: [.any: Layout(boxes: [Box(binding: .pixels, fit: .pixels(.fit))])]))
        machine.stacks[1].slots = [StackSlot(channel: 1, preset: 8), StackSlot(channel: 2)]   // the unassigned stack samples both
        let engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
        let backend = try XCTUnwrap(engine.recording)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.send("channel 2 write text \"x\"")
        engine.tick()   // frame 0: a preview tick
        var plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.stackPasses.map(\.stack), [1, 2])
        XCTAssertEqual(plan.stackPasses.map(\.auxOnly), [false, true], "stack 2 renders for its preview only")
        XCTAssertEqual(plan.channelPasses.map(\.channel), [1])
        XCTAssertEqual(plan.channelPasses.map(\.auxOnly), [true], "only the unassigned stack samples channel 1")
        XCTAssertEqual(plan.auxPasses.map(\.stack), [1, 2])
        XCTAssertEqual(plan.sinkPasses.map(\.output), [1])
        engine.tick()   // frame 1: not a preview tick
        plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.stackPasses.map(\.stack), [1])
        XCTAssertTrue(plan.channelPasses.isEmpty, "no due stack samples channel 1 this tick")
        XCTAssertTrue(plan.auxPasses.isEmpty)
        XCTAssertEqual(backend.encoded.map(\.stackPasses), [[1, 2], [1]])
        // Under pressure the aux-only work is skipped and counted (Spec 4 §4 step 5, §13).
        backend.simulatedGPUMilliseconds = 12
        engine.tick()   // frame 2: measured over budget
        engine.tick()   // frame 3: the render thread sees it; not a preview tick
        engine.tick()   // frame 4: a preview tick under pressure
        let encoded = try XCTUnwrap(backend.encoded.last)
        XCTAssertEqual(encoded.stackPasses, [1], "the aux-only stack pass was not encoded")
        XCTAssertEqual(encoded.channelPasses, 0, "nor the channel pass only it needed")
        XCTAssertEqual(encoded.auxSkipped, 4, "two previews, the aux-only stack pass and its channel pass")
        let record = try XCTUnwrap(engine.drainMetrics().last)
        XCTAssertEqual(record.stackPasses, 1)
        XCTAssertEqual(record.channelPasses, 0)
        XCTAssertEqual(record.auxSkipped, 4)
        XCTAssertTrue(engine.renderLoop.isSkippingAux, "other threads read the pressure state too (the thumbnail job waits on it)")
    }

    /// Spec 4 §10 — "those IOSurfaces are shared with it over a local Mach
    /// connection": the engine exposes one surface id per stack for that.
    func test_theEngineExposesOnePreviewSurfacePerStack() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        mediaRoot: EngineFixtures.mediaRoot, metal: metal)
        let surfaces = engine.engine.previewSurfaces
        XCTAssertEqual(Set(surfaces.keys), [1, 2])
        XCTAssertEqual(Set(surfaces.values).count, 2, "distinct surfaces")
        engine.send("channel 2 write text \"Amen\"")
        engine.tick(count: 3)
        let preview = try XCTUnwrap(metal.readback8(engine.control.previewTargets[1] ?? .none))
        XCTAssertEqual(preview.width, 120, "a quarter of the 480-wide main stack")
        XCTAssertGreaterThan(preview.pixels.filter { $0.r + $0.g + $0.b > 0.3 }.count, 10, "the text shows in the preview")
    }
}
