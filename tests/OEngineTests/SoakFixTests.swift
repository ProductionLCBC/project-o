import XCTest
import Metal
import OCore
@testable import OEngine

/// The three-hour soak of 2026-11-01 (two displays, no card) held every
/// display and GPU threshold and failed two others; these tests pin the four
/// causes. Spec 4 §15: "Until every line above is green, no UI work starts."

// MARK: - Spec 4 §5, §6 — a still's texture is freed after the ring depth

final class StillTextureLifetimeTests: XCTestCase {
    func test_releasedStillFreesItsTextureAfterTheRingDepth() throws {
        let backend = try MetalHarness.backend()
        let url = EngineFixtures.mediaRoot.appendingPathComponent("backgrounds/cross.png")
        let before = backend.resources.allocated
        let still = StillSource(url: url, fitWithin: PixelSize(width: 1920, height: 1080), backend: backend)
        try still.load()
        XCTAssertEqual(backend.resources.allocated, before + 1)
        still.release()
        // The plans in flight may still name it: nothing is freed until the ring depth has passed.
        backend.resources.sweep(consumedTick: 0)
        XCTAssertEqual(backend.resources.allocated, before + 1, "held until every plan that could name it was consumed")
        backend.resources.sweep(consumedTick: Int64(PlanRing.depth))
        XCTAssertEqual(backend.resources.allocated, before, "freed after the ring depth, not after forever")
        XCTAssertEqual(backend.resources.pendingRelease, 0)
    }

    /// The soak wrote the cross still once a pass and leaked a texture each
    /// time; through the engine, repeated writes and clears must settle.
    func test_repeatedStillWritesDoNotAccumulateTextures() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot, metal: metal)
        func cycle() {
            engine.send("channel 1 write media \(EngineFixtures.cross)")
            XCTAssertTrue(waitUntil(5) { engine.tick(); return engine.control.model.channels[1]?.live.media?.ready == true })
            engine.tick(count: 4)
            engine.send("channel 1 clear")
            engine.tick(count: 8)
        }
        cycle()
        cycle()
        let settled = metal.resources.allocated
        for _ in 0..<5 { cycle() }
        XCTAssertEqual(metal.resources.allocated, settled, "every still's texture came back")
    }
}

// MARK: - Spec 4 §8 — a variable box's raster replaces the previous one

final class VariableRasterTests: XCTestCase {
    final class MovingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = HeadlessEngine.fixedWallClock()
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
    }

    func test_timeBoxKeepsOneRasterAcrossMinutes() throws {
        let metal = try MetalHarness.backend()
        let clock = MovingClock()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot,
                                        metal: metal, wallClock: { clock.now })
        let cache = try XCTUnwrap(engine.textCache)
        engine.tick(count: 3)
        let warm = cache.statistics
        XCTAssertGreaterThan(warm.entries, 0, "the [Time] box has its raster")
        for minute in 1...5 {
            clock.advance(seconds: 60)
            engine.tick(count: 3)
            let now = cache.statistics
            XCTAssertEqual(now.rasterized, warm.rasterized + minute, "a new raster each minute")
            XCTAssertEqual(now.entries, warm.entries, "and the previous minute's raster is gone (Spec 4 §8: the result replaces the cache entry)")
        }
        let stack2 = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        XCTAssertEqual(stack2.boxes.first { if case .static = $0.binding.kind { return true } else { return false } }?.text, "10:05 AM")
    }

    func test_cacheReleaseDropsAnEntryAndItsTextures() throws {
        let backend = RecordingBackend()
        let cache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: backend, synchronous: true)
        let style = BoxTextStyle()
        let job = TextJob(key: TextKey.make(text: "Amen", style: style, box: PixelSize(width: 800, height: 200), fit: TextFit(), outputHeight: 1080),
                          text: "Amen", style: style, box: PixelSize(width: 800, height: 200), fit: TextFit(), outputHeight: 1080)
        cache.request(job)
        XCTAssertNotNil(cache.entry(for: job))
        let allocated = backend.resources.allocated
        XCTAssertGreaterThan(allocated, 0)
        cache.release(job.key)
        XCTAssertNil(cache.entry(for: job))
        XCTAssertEqual(cache.statistics.entries, 0)
        XCTAssertEqual(cache.statistics.bytes, 0)
        cache.sweep(consumedTick: Int64(PlanRing.depth) * 2)
        XCTAssertEqual(backend.resources.allocated, 0, "the line textures went back after the ring depth")
        cache.release(job.key)   // releasing twice is harmless
    }
}

// MARK: - Spec 4 §11 — an instance starts with a preroll

final class AudioPrerollTests: XCTestCase {
    func output() -> AudioOutput {
        AudioOutput(number: 1, label: "Default", device: .uid("software"), channels: [0, 1])
    }

    func test_anInstanceWaitsForAPrerollBeforeItPlaysCountsOrTicks() throws {
        // A real device's host clock is far from zero; the clock must not read that as time played.
        let device = SoftwareAudioDevice(hostTimeNs: 5_000_000_000_000)
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let ring = AudioRing(channels: 2, capacityFrames: 48_000)
        let a = AudioInstance(handle: InstanceHandle(rawValue: 1), ring: ring, inMs: 1500, syncOffsetMs: 0,
                              routing: graph.routing(forAudioOutputs: [1], instanceChannels: 2))
        XCTAssertTrue(graph.add(a, gainDb: 0))
        let silent = device.pull(frames: 480)
        XCTAssertEqual(silent.map(abs).max() ?? 1, 0, "nothing has arrived: silence by design")
        XCTAssertEqual(graph.underruns, 0, "an instance that has not started has nothing to miss")
        XCTAssertEqual(graph.mediaTimeMs(of: a), 1500, accuracy: 0.001, "the clock holds at the in-point until the first samples reach the device")
        _ = ring.write([Float](repeating: 0.25, count: 2 * (AudioGraph.prerollFrames - 1)))
        _ = device.pull(frames: 480)
        XCTAssertEqual(graph.underruns, 0, "one frame short of the preroll: still waiting")
        XCTAssertEqual(graph.mediaTimeMs(of: a), 1500, accuracy: 0.001)
        _ = ring.write([Float](repeating: 0.25, count: 2))
        let playing = device.pull(frames: 480)
        XCTAssertEqual(playing[0], 0.25, accuracy: 1e-6, "the preroll is there: it plays")
        XCTAssertEqual(graph.mediaTimeMs(of: a), 1510, accuracy: 0.01, "ten milliseconds delivered")
        // Started, then dry: that is an underrun.
        _ = device.pull(frames: AudioGraph.prerollFrames)
        XCTAssertEqual(graph.underruns, 480, "the frames the ring could not supply once playing")
    }

    func test_aShortClipThatHasEndedStartsWithoutAPreroll() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let ring = AudioRing(channels: 2, capacityFrames: 4096)
        _ = ring.write([Float](repeating: 0.5, count: 2 * 100))
        ring.markEnded()
        let a = AudioInstance(handle: InstanceHandle(rawValue: 2), ring: ring, inMs: 0, syncOffsetMs: 0,
                              routing: graph.routing(forAudioOutputs: [1], instanceChannels: 2))
        XCTAssertTrue(graph.add(a, gainDb: 0))
        let out = device.pull(frames: 200)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[150 * 2], 0, accuracy: 1e-6)
        XCTAssertEqual(graph.underruns, 0, "a clip's end is not an underrun")
    }

    func test_theUnderrunTotalNeverDropsWhenAnInstanceLeaves() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output()])
        try graph.start()
        let ring = AudioRing(channels: 2, capacityFrames: 8192)
        _ = ring.write([Float](repeating: 0.1, count: 2 * 2000))
        let a = AudioInstance(handle: InstanceHandle(rawValue: 3), ring: ring, inMs: 0, syncOffsetMs: 0,
                              routing: graph.routing(forAudioOutputs: [1], instanceChannels: 2))
        XCTAssertTrue(graph.add(a, gainDb: 0))
        _ = device.pull(frames: 3000)
        XCTAssertEqual(graph.underruns, 1000)
        graph.remove(a)
        _ = device.pull(frames: 480)
        XCTAssertEqual(graph.underruns, 1000, "a monotonic total, so the soak's minute deltas are real")
    }
}

// MARK: - Spec 4 §12, §13 — the watchdog's slack and the minute record

final class WatchdogSlackTests: XCTestCase {
    let tick: Int64 = 16_666_667

    func reading(sinkSince: Int64) -> LivenessReading {
        let now: Int64 = 100 * tick
        return LivenessReading(now: MonotonicTime(nanoseconds: now), tickNanoseconds: tick,
                               lastPlanConsumed: MonotonicTime(nanoseconds: now - tick / 2), lastPlanBuilt: MonotonicTime(nanoseconds: now - tick / 2),
                               sinkLastPresent: [1: MonotonicTime(nanoseconds: now - sinkSince)], queues: [])
    }

    /// "within the last two frame intervals", with half a tick of slack for a
    /// display link that fires a millisecond late at the sampling instant.
    func test_sinkRuleHasHalfATickOfSlack() {
        XCTAssertEqual(Watchdog.check(reading(sinkSince: 2 * tick + tick / 10)), [], "a late callback is not a stall")
        XCTAssertEqual(Watchdog.check(reading(sinkSince: 2 * tick + tick / 2 - 1)), [])
        XCTAssertEqual(Watchdog.check(reading(sinkSince: 2 * tick + tick / 2 + 1)).count, 1)
        XCTAssertEqual(Watchdog.check(reading(sinkSince: 3 * tick)).count, 1)
    }

    func test_minuteRecordsCarryPerMinuteWatchdogCountsAndUnderruns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-minutes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let events = SettableCounter()
        let recoveries = SettableCounter()
        let underruns = SettableCounter()
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: MetricsRing(capacity: 16), presents: [],
                                        tickNanoseconds: tick,
                                        sources: BlackBoxRecorder.MinuteSources(audioUnderruns: { underruns.value },
                                                                                watchdogEvents: { events.value },
                                                                                watchdogRecoveries: { recoveries.value }),
                                        log: EngineLog(category: "test"))
        events.set(3); recoveries.set(1); underruns.set(100)
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        events.set(5); recoveries.set(1); underruns.set(100)
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        events.set(5); recoveries.set(2); underruns.set(150)
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: tick, sdiOutputs: [], displayOutputs: [1])
        XCTAssertEqual(run.minutes.map(\.watchdogEvents), [3, 2, 0], "what happened in that minute, not since start")
        XCTAssertEqual(run.minutes.map(\.watchdogRecoveries), [1, 0, 1])
        XCTAssertEqual(run.minutes.map(\.audioUnderruns), [100, 0, 50])
        XCTAssertEqual(SoakThresholds.evaluate(run), [.audioUnderruns(count: 150), .watchdogRecoveries(count: 2)])
    }
}

/// A settable counter for test sources.
final class SettableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func set(_ value: Int) { lock.lock(); count = value; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Spec 4 §12 — the last-good readback reuses its buffers

final class ReadbackReuseTests: XCTestCase {
    func test_lastGoodRefreshReusesItsStagingAndPixels() throws {
        let metal = try MetalHarness.backend()
        let handle = metal.makeStill(MetalHarness.solid(width: 64, height: 32, LinearPixel(r: 0.2, g: 0.4, b: 0.6, a: 1)), label: "solid")
        metal.refreshLastGood(output: 7, stack: handle)
        let first = try XCTUnwrap(metal.lastGoodFrame(output: 7))
        XCTAssertEqual(first[10, 10].g, 0.4, accuracy: 0.002)
        for _ in 0..<20 { metal.refreshLastGood(output: 7, stack: handle) }
        XCTAssertEqual(metal.lastGoodStagingBuffers, 1, "one staging buffer per output, kept")
        let again = try XCTUnwrap(metal.lastGoodFrame(output: 7))
        XCTAssertEqual(again.width, 64)
        XCTAssertEqual(again[10, 10].b, 0.6, accuracy: 0.002)
    }
}
