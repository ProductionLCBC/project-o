import XCTest
import OCore
@testable import OEngine

/// Spec 3 §4 — "A write replaces the channel's content instance, applies its
/// riders, and emits a `transition` effect that tells the engine what to
/// animate between"; "The effect's transition is, in order: the write's
/// `once` rider, else the channel's current transition attribute". Spec 4 §7,
/// stage 3 — "With one running, the outgoing content (its own stage 1 and 2
/// output from the previous instance) is mixed in premultiplied linear space
/// by type: dissolve `lerp(outgoing, incoming, t)`".
///
/// The fault Adam reported (2026-11-24): a media change with the Dissolve
/// rider (`{"ref":2,"scope":"track"}`) on a channel whose default is Cut
/// always cuts. The existing dissolve tests write onto a source that is ready
/// on the tick it lands (the fake factory's default); a real decoder never is,
/// and the engine opens no source ahead of a write, so every real media write
/// is a cold one (Spec 4 §6), and a cold write whose poster is already loaded
/// is the case these tests drive.
final class MediaDissolveEngineTests: XCTestCase {
    /// The plan side, over the fakes: the source is three ticks from its first
    /// frame, as a real decoder is, and the poster is loaded, as the lookahead
    /// (Spec 4 §8, Spec 8 §9) or any earlier write of the item leaves it.
    func test_aColdMediaWriteWithADissolveRiderDissolvesFromThePreviousPicture() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        let sources = try XCTUnwrap(engine.fakeSources)
        sources.readyAfterTicks = 3

        // Media A (the cross still) on channel 1, live and decoded.
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.cross)"))
        engine.tick(count: 5)
        let before = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        guard case .instance(let a, _) = before.incoming.source else {
            return XCTFail("media A should be decoded and live before the dissolve; the pass draws \(before.incoming.source)")
        }
        let aSource = try XCTUnwrap(sources.opened.first { $0.request.entry.id == EngineFixtures.cross })

        // Media B (dawn) with the library's Dissolve (500 ms, easeInOut) as a track rider, as Adam's command.
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.dawn) transition 2 track"))
        var passes: [(frame: Int64, pass: ChannelPass)] = []
        engine.tick()
        let landing = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        passes.append((engine.frame, landing))
        XCTAssertEqual(engine.state.channels[1]?.attributes.transition.value.ref, 2, "the track rider set the channel's transition")

        // On the landing tick A must still be on the channel: held while B's first frame decodes, or the
        // outgoing of a dissolve at progress 0. Either way never B alone.
        let landingDrawsA = landing.incoming.source.handle == a || landing.outgoing?.source.handle == a
        XCTAssertTrue(landingDrawsA, """
            the write cut: on the tick it landed the channel pass draws \(landing.incoming.source) \
            (B's poster) with outgoing \(String(describing: landing.outgoing?.source)) and transition \
            \(String(describing: landing.transition)); media A (\(a)) is gone from the channel
            """)
        XCTAssertFalse(aSource.released, "media A's source was released on the tick the dissolve's write landed, so nothing can dissolve from it")

        // Run to the middle of the dissolve.
        var middle: (frame: Int64, pass: ChannelPass)?
        for _ in 0..<60 {
            engine.tick()
            let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
            passes.append((engine.frame, pass))
            if let t = pass.transition, t.type == .dissolve, t.progress > 0.3, t.progress < 0.7 {
                middle = (engine.frame, pass)
                break
            }
        }
        let mid = try XCTUnwrap(middle, "the dissolve never reached its middle: \(passes.map { ($0.frame, $0.pass.transition) })")
        let outgoing = try XCTUnwrap(mid.pass.outgoing, "a dissolve at progress \(mid.pass.transition?.progress ?? -1) with no outgoing source")

        // What the dissolve mixes from must be A: A's instance, still playing, or a snapshot of the channel
        // texture copied while it showed A. The render thread copies the snapshot on the tick whose pass
        // has `snapshotOutgoing`, from the texture the tick before left behind.
        switch outgoing.source {
        case .instance(let handle, _):
            XCTAssertEqual(handle, a, "the dissolve's outgoing instance is not media A")
        case .texture:
            guard let copied = passes.lastIndex(where: { $0.pass.snapshotOutgoing }) else {
                return XCTFail("the outgoing is a texture but no pass since the write took a snapshot")
            }
            let taken = passes[copied]
            let left = copied > 0 ? passes[copied - 1] : (frame: taken.frame - 1, pass: before)
            let leftShowedA = left.pass.incoming.source.handle == a && left.pass.outgoing == nil
            XCTAssertTrue(leftShowedA, """
                the dissolve's outgoing is a snapshot copied on frame \(taken.frame) from what frame \(left.frame) \
                drew: \(left.pass.incoming.source), which is B's poster, not media A (\(a)). The channel \
                dissolves from B's poster to B's first frame, after a cut from A to the poster on frame \
                \(passes[0].frame): on screen, a cut
                """)
        case .none:
            XCTFail("the dissolve's outgoing has no source")
        }
    }

    /// The pixels, over Metal with the real still and video sources and the
    /// real poster loader (the harness loads posters in the lookup): the
    /// channel texture on the landing tick is still A, the dissolve mixes from
    /// A, and the cross of A still shows through on the channel and the main
    /// stack (Preset 1's pixel box, whose own Cut must not undo the channel's
    /// dissolve, Spec 4 §9) in the middle of the dissolve.
    func test_theDissolveMixesTheOldAndNewMediaOnTheChannelAndTheStack() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: EngineFixtures.library(),
                                        machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        media: EngineFixtures.media, metal: metal)

        // A: the cross still (a dark ground with a white cross), decoded off the render thread.
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.cross)"))
        let decoded = tickUntil(engine) { if case .instance = $0.incoming.source { return $0.transition == nil } else { return false } }
        XCTAssertTrue(decoded, "the cross still never decoded")
        engine.tick(count: 2)
        let texture = try XCTUnwrap(engine.control.channelTextures[1])
        let a = try XCTUnwrap(metal.readback(texture))
        let aStack = try XCTUnwrap(engine.captured(output: 1))
        let channelCross = CrossMask(a)
        let stackCross = CrossMask(aStack)
        XCTAssertFalse(channelCross.cross.isEmpty || channelCross.ground.isEmpty, "the cross and its ground were found on the channel")
        XCTAssertFalse(stackCross.cross.isEmpty || stackCross.ground.isEmpty, "the cross and its ground were found on the main stack")
        let aContrast = channelCross.contrast(a)
        let aStackContrast = stackCross.contrast(aStack)
        guard case .instance(let aHandle, _)? = engine.lastPlan?.channelPasses.first(where: { $0.channel == 1 })?.incoming.source else {
            return XCTFail("the cross is not live")
        }

        // B: dawn (a video, cold at the write, its poster loaded) with the Dissolve as a track rider.
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.dawn) transition 2 track"))
        engine.tick()
        let landing = try XCTUnwrap(metal.readback(texture))
        let landingPass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        XCTAssertLessThan(meanDifference(landing, a), 0.02, """
            on the tick the dissolve's write landed the channel no longer shows media A (cross contrast \
            \(channelCross.contrast(landing)) against A's \(aContrast)); its pass draws \(landingPass.incoming.source) \
            with outgoing \(String(describing: landingPass.outgoing?.source)): a cut to B's poster
            """)

        // Wait for the dissolve to run, then to its middle.
        let started = tickUntil(engine) { $0.transition.map { $0.type == .dissolve } ?? false }
        XCTAssertTrue(started, "the dissolve never started")
        var midPass: ChannelPass?
        for _ in 0..<60 {
            engine.tick()
            guard let pass = engine.lastPlan?.channelPasses.first(where: { $0.channel == 1 }) else { continue }
            if let t = pass.transition, t.progress >= 0.35, t.progress <= 0.65 {
                midPass = pass
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        let pass = try XCTUnwrap(midPass, "the dissolve never reached its middle")
        let progress = pass.transition?.progress ?? -1
        let mid = try XCTUnwrap(metal.readback(texture))
        let midStack = try XCTUnwrap(engine.captured(output: 1))

        // What the dissolve mixes from.
        var outgoingNote = "no outgoing"
        switch pass.outgoing?.source {
        case .instance(let handle, _)?:
            outgoingNote = "instance \(handle)"
            XCTAssertEqual(handle, aHandle, "the dissolve's outgoing instance is not media A")
        case .texture?:
            let snapshot = try XCTUnwrap(metal.readback(try XCTUnwrap(engine.control.channelSnapshots[1])))
            outgoingNote = "a snapshot with cross contrast \(channelCross.contrast(snapshot))"
            XCTAssertLessThan(meanDifference(snapshot, a), 0.02, """
                the dissolve runs from a snapshot that is not media A (its cross contrast is \
                \(channelCross.contrast(snapshot)) against A's \(aContrast)): the snapshot was copied after the \
                channel had drawn B's poster, so the dissolve is from B's poster to B
                """)
        default:
            XCTFail("a dissolve at progress \(progress) with no outgoing source")
        }

        // In the middle, A's cross still shows through, on the channel and on the stack: with B's ground
        // smooth, the contrast is about (1 - progress) of A's.
        let midContrast = channelCross.contrast(mid)
        XCTAssertGreaterThan(midContrast, 0.2 * aContrast, """
            at dissolve progress \(progress) media A's cross is gone from the channel texture: contrast \
            \(midContrast) against A's \(aContrast) (\(outgoingNote))
            """)
        let midStackContrast = stackCross.contrast(midStack)
        XCTAssertGreaterThan(midStackContrast, 0.2 * aStackContrast, """
            at dissolve progress \(progress) media A's cross is gone from the main stack: contrast \
            \(midStackContrast) against A's \(aStackContrast)
            """)
    }

    /// Spec 4 §7 as corrected 2026-11-25 — "On a channel that held no picture the outgoing is transparent, so a dissolve
    /// fades the new content in": the pipelines for a transition with no outgoing are built at warm-up, so a fade-in
    /// never compiles one on the render thread; and on the GPU the channel comes up from nothing.
    func test_aDissolveOntoAnEmptyChannelFadesInOnTheGPU() throws {
        let metal = try MetalHarness.backend()
        _ = metal.warmUp()
        for layout in [SourceLayout.nv12, .p010, .yuv422p10, .rgba16, .linearRGBA16] {
            for transition in [TransitionVariant.dissolve, .fadeThroughColor] {
                XCTAssertTrue(metal.pipelines.hasChannel(ChannelVariant(incoming: layout, outgoing: nil, transition: transition, grade: false)),
                              "\(layout) \(transition) from nothing")
            }
        }
        let engine = try HeadlessEngine(library: EngineFixtures.library(),
                                        machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        media: EngineFixtures.media, metal: metal)
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.cross) transition 2 1.0 once"))
        let started = tickUntil(engine) { pass in
            if case .instance = pass.incoming.source { return (pass.transition?.progress ?? -1) > 0.3 } else { return false }
        }
        XCTAssertTrue(started, "the fade never began")
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        let progress = Double(pass.transition?.progress ?? 0)
        let texture = try XCTUnwrap(engine.control.channelTextures[1])
        let mid = try XCTUnwrap(metal.readback(texture))
        engine.tick(count: 80)
        let full = try XCTUnwrap(metal.readback(texture))
        // Partway in, the cross's white is dimmer than when it is fully in.
        func brightest(_ frame: CapturedFrame) -> Double { Self.peakLuminance(frame) }
        XCTAssertLessThan(brightest(mid), brightest(full) * 0.9, "partway through the fade (progress \(progress)), dimmer than fully in")
        XCTAssertGreaterThan(brightest(mid), 0, "but not nothing")
    }

    // MARK: - Helpers

    /// The brightest pixel's luminance in a captured channel texture.
    private static func peakLuminance(_ frame: CapturedFrame) -> Double {
        Double(frame.pixels.map { CrossMask.luma($0) }.max() ?? 0)
    }

    /// Tick, letting the real decoders run between ticks, until channel 1's pass satisfies `condition`.
    private func tickUntil(_ engine: HeadlessEngine, ticks: Int = 300, _ condition: (ChannelPass) -> Bool) -> Bool {
        for _ in 0..<ticks {
            engine.tick()
            if let pass = engine.lastPlan?.channelPasses.first(where: { $0.channel == 1 }), condition(pass) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }

    /// The mean absolute difference of two captures' colour, per channel.
    private func meanDifference(_ x: CapturedFrame, _ y: CapturedFrame) -> Float {
        guard x.pixels.count == y.pixels.count, !x.pixels.isEmpty else { return .infinity }
        var sum: Float = 0
        for (p, q) in zip(x.pixels, y.pixels) { sum += (abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3 }
        return sum / Float(x.pixels.count)
    }
}

/// Where the cross still's white bars and its dark ground fall in a capture
/// of it, and how much brighter the bars than the ground are in another
/// capture at the same size: the share of the cross still in a mix.
private struct CrossMask {
    var cross: [Int] = []
    var ground: [Int] = []

    static func luma(_ p: LinearPixel) -> Float { 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b }

    init(_ frame: CapturedFrame) {
        for (index, pixel) in frame.pixels.enumerated() {
            let l = CrossMask.luma(pixel)
            if l > 0.6 {
                cross.append(index)
            } else if l > 0.002, l < 0.08 {
                // The ground of the still, not the stack's black base around a box.
                ground.append(index)
            }
        }
    }

    func contrast(_ frame: CapturedFrame) -> Float {
        guard !cross.isEmpty, !ground.isEmpty, frame.pixels.count > (cross + ground).max() ?? 0 else { return 0 }
        let bars = cross.reduce(Float(0)) { $0 + CrossMask.luma(frame.pixels[$1]) } / Float(cross.count)
        let rest = ground.reduce(Float(0)) { $0 + CrossMask.luma(frame.pixels[$1]) } / Float(ground.count)
        return bars - rest
    }
}

private extension SourceRef {
    /// The instance a source names, if it names one.
    var handle: InstanceHandle? {
        if case .instance(let handle, _) = self { return handle }
        return nil
    }
}
