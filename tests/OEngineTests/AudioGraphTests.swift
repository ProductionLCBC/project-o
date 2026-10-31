import XCTest
import OCore
@testable import OEngine

/// Spec 4 §16, Audio — "The mix graph with a software device produces
/// sample-exact crossfades and ramps; the clock reading drives frame
/// selection within one frame of the expected media time; the output delay
/// line delays exactly delayMs."
final class AudioGraphTests: XCTestCase {
    func output(number: Int = 1, delayMs: Int = 0) -> AudioOutput {
        AudioOutput(number: number, label: "test", device: .uid("software"), channels: [0, 1], delayMs: delayMs)
    }

    /// An instance whose ring holds a constant value on both channels.
    func instance(_ handle: Int32, value: Float, seconds: Double = 2, graph: AudioGraph, gainDb: Double = 0, syncOffsetMs: Int = 0) -> AudioInstance {
        let ring = AudioRing(channels: 2, capacityFrames: Int(seconds * 48_000) + 16)
        _ = ring.write([Float](repeating: value, count: Int(seconds * 48_000) * 2))
        let inst = AudioInstance(handle: InstanceHandle(rawValue: handle), ring: ring, inMs: 0, syncOffsetMs: syncOffsetMs,
                                 routing: graph.routing(forAudioOutputs: [1], instanceChannels: 2))
        XCTAssertTrue(graph.add(inst, gainDb: gainDb))
        return inst
    }

    func test_crossfadeIsSampleExact() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 0.5, graph: graph)
        let b = instance(2, value: 0.25, graph: graph)
        graph.startTransition(outgoing: a, incoming: b, type: .crossfade, ms: 100, offsetMs: 0)
        let out = device.pull(frames: 4800)
        for k in [0, 1200, 2400, 3600, 4799] {
            let t = Float(k) / 4800
            XCTAssertEqual(out[k * 2], 0.5 * (1 - t) + 0.25 * t, accuracy: 1e-6, "frame \(k)")
            XCTAssertEqual(out[k * 2 + 1], out[k * 2], accuracy: 1e-6, "both channels")
        }
        let after = device.pull(frames: 10)
        XCTAssertEqual(after[0], 0.25, accuracy: 1e-6, "only the incoming remains")
    }

    func test_fadeThroughSilenceAndTheOffset() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 0.5, graph: graph)
        let b = instance(2, value: 0.25, graph: graph)
        // 100 ms through silence, starting 50 ms after the trigger: an L cut's worth of offset.
        graph.startTransition(outgoing: a, incoming: b, type: .fadeThroughSilence, ms: 100, offsetMs: 50)
        let out = device.pull(frames: 4800 * 2)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6, "before the offset the outgoing plays alone")
        XCTAssertEqual(out[2399 * 2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[(2400 + 1200) * 2], 0.25, accuracy: 1e-6, "half way out: the outgoing at half, nothing of the incoming yet")
        XCTAssertEqual(out[(2400 + 2400) * 2], 0, accuracy: 1e-6, "silence in the middle")
        XCTAssertEqual(out[(2400 + 3600) * 2], 0.125, accuracy: 1e-6, "half way in")
        XCTAssertEqual(out[(2400 + 4800) * 2], 0.25, accuracy: 1e-6, "the incoming alone")
    }

    func test_cutStopsOneAndStartsTheOtherAtTheOffset() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 0.5, graph: graph)
        let b = instance(2, value: 0.25, graph: graph)
        graph.startTransition(outgoing: a, incoming: b, type: .cut, ms: 0, offsetMs: 10)
        let out = device.pull(frames: 960)
        XCTAssertEqual(out[479 * 2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[480 * 2], 0.25, accuracy: 1e-6, "the cut lands 10 ms after the trigger")
    }

    /// Spec 4 §11 — "per-instance gain ... with a 50 ms ramp on change".
    func test_gainRampsOverFiftyMilliseconds() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 1, graph: graph)
        _ = device.pull(frames: 10)
        graph.setGain(-6, for: a)
        let out = device.pull(frames: 2400)
        let target = AudioGraph.linear(-6)
        XCTAssertEqual(out[1199 * 2], 1 + (target - 1) * 0.5, accuracy: 0.002, "half way down after 25 ms")
        XCTAssertEqual(out[2399 * 2], target, accuracy: 0.002, "at the target after 50 ms")
        XCTAssertEqual(device.pull(frames: 1)[0], target, accuracy: 1e-6)
    }

    /// Spec 4 §11 — "a fixed delay line at the end of that device's mix".
    func test_outputDelayLineDelaysExactly() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output(delayMs: 100)])
        try graph.start()
        _ = instance(1, value: 0.5, graph: graph)
        let out = device.pull(frames: 4800 + 10)
        XCTAssertEqual(out[4799 * 2], 0, accuracy: 1e-6, "silence for exactly 100 ms")
        XCTAssertEqual(out[4800 * 2], 0.5, accuracy: 1e-6, "then the signal")
        XCTAssertEqual(out[4800 * 2 + 1], 0.5, accuracy: 1e-6)
    }

    /// Spec 4 §11 — "Mute of an audio output zeroes that device's mix with a 20 ms ramp".
    func test_muteRampsOverTwentyMilliseconds() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        _ = instance(1, value: 1, graph: graph)
        _ = device.pull(frames: 10)
        graph.setMuted(true, output: 1)
        let out = device.pull(frames: 960)
        XCTAssertEqual(out[479 * 2], 0.5, accuracy: 0.003, "half way after 10 ms")
        XCTAssertEqual(out[959 * 2], 0, accuracy: 0.003)
        graph.setMuted(false, output: 1)
        XCTAssertEqual(device.pull(frames: 960)[959 * 2], 1, accuracy: 0.003)
    }

    /// Spec 4 §11 — the clock: "An instance's media time is derived from the
    /// samples of it that have reached the device". Spec 4 §12 — underruns counted.
    func test_clockFollowsDeliveredSamplesAndUnderrunsAreCounted() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 0.1, seconds: 1, graph: graph)
        _ = device.pull(frames: 24_000)
        XCTAssertEqual(a.mediaTimeMs(nowNs: device.nextHostTimeNs), 500, accuracy: 0.05, "half a second delivered")
        XCTAssertEqual(a.mediaTimeMs(nowNs: device.nextHostTimeNs + 10_000_000), 510, accuracy: 0.05, "plus the time since the device took them")
        graph.setPlaying(false, for: a)
        _ = device.pull(frames: 4800)
        XCTAssertEqual(a.mediaTimeMs(nowNs: device.nextHostTimeNs), 500, accuracy: 0.05, "paused: held")
        graph.setPlaying(true, for: a)
        _ = device.pull(frames: 24_000 + 100)
        XCTAssertEqual(a.underruns, 100, "the ring ran dry for 100 frames")
        XCTAssertEqual(graph.underruns, 100)
        a.ring.markEnded()
        _ = device.pull(frames: 100)
        XCTAssertEqual(a.underruns, 100, "an ended ring is silence, not an underrun")
    }

    /// Spec 4 §11 — "syncOffsetMs ... delays audio when positive by holding samples in the ring".
    func test_positiveSyncOffsetHoldsTheAudio() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let a = instance(1, value: 0.5, graph: graph, syncOffsetMs: 20)
        let out = device.pull(frames: 1000)
        XCTAssertEqual(out[959 * 2], 0, accuracy: 1e-6)
        XCTAssertEqual(out[960 * 2], 0.5, accuracy: 1e-6)
        XCTAssertEqual(graph.mediaTimeMs(of: a), 1000.0 / 48, accuracy: 0.01, "the clock ran through the hold, so the picture leads the sound by the offset")
    }

    func test_routingFollowsTheAudioOutputChannelMap() {
        let device = SoftwareAudioDevice(channelCount: 4)
        let right = AudioOutput(number: 2, label: "pair 2", device: .uid("software"), channels: [2, 3])
        let graph = AudioGraph(device: device, outputs: [output(), right])
        XCTAssertEqual(graph.routing(forAudioOutputs: [2], instanceChannels: 2), [2, 3])
        XCTAssertEqual(graph.routing(forAudioOutputs: [2], instanceChannels: 1), [2, 3], "mono goes to both channels of the pair")
        XCTAssertEqual(graph.routing(forAudioOutputs: [1], instanceChannels: 2), [0, 1])
    }

    func test_ringIsSingleProducerSingleConsumer() {
        let ring = AudioRing(channels: 2, capacityFrames: 64)
        XCTAssertEqual(ring.write([Float](repeating: 1, count: 140)), 64, "sixty-four frames fit")
        XCTAssertEqual(ring.framesAvailable, 64)
        XCTAssertEqual(ring.framesFree, 0)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer { out.deallocate() }
        XCTAssertTrue(ring.readFrame(into: out))
        XCTAssertEqual(out[0], 1)
        XCTAssertEqual(ring.framesFree, 1)
        ring.skip(frames: 63)
        XCTAssertFalse(ring.readFrame(into: out), "empty")
        XCTAssertEqual(out[0], 0, "silence when empty")
        XCTAssertEqual(ring.write([Float](repeating: 2, count: 4)), 2, "room again")
    }

    func test_audioDecoderFillsTheRingFromTheClapper() throws {
        let url = try ClipFixtures.url(for: ClipFixtures.clapper)
        let decoder = AudioFileDecoder(url: url, inMs: 0, outMs: nil, loop: false, channels: 2)
        decoder.start()
        defer { decoder.stop() }
        XCTAssertTrue(waitUntil(10) { decoder.ring.framesAvailable >= 9000 })
        XCTAssertFalse(decoder.isFailed)
        // The click is at one second: read through the silence, then find it.
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        defer { out.deallocate() }
        var firstLoud: Int?
        for frame in 0..<(48_000 + 2000) {
            _ = waitUntil(5) { decoder.ring.framesAvailable > 0 || decoder.ring.isEnded }
            _ = decoder.ring.readFrame(into: out)
            if abs(out[0]) > 0.5 {
                firstLoud = frame
                break
            }
        }
        XCTAssertEqual(firstLoud ?? -1, 48_000, "the click sits at exactly one second")
    }
}
