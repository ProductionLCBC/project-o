import XCTest
import AVFoundation
import CoreMedia
import OCore
@testable import OEngine

/// Spec 4 §16, Recovery — "Each row of section 12 is simulated in the harness
/// and produces the documented response and log line." Rows that need a
/// card, a screen or an audio device are covered by their sink's own state
/// tests; memory pressure and thermal state only log.
final class RecoveryTests: XCTestCase {
    /// "Decoder error on a frame: Skip the frame, repeat the previous, count
    /// it; after 10 consecutive errors, hold the last frame, mark the instance
    /// missing, log once."
    func test_decoderErrorsAreCountedAndTenInARowHoldTheLastFrame() throws {
        let url = try ClipFixtures.url(for: ClipFixtures.h264)
        let log = EngineLog(category: "test-recovery")
        let source = VideoFileSource(url: url, inMs: 0, outMs: nil, loop: false, device: nil, demuxer: GarbageAfterDemuxer(goodSamples: 3), log: log)
        source.start()
        defer { source.release() }
        XCTAssertTrue(waitUntil(15) { source.isReady })
        XCTAssertTrue(waitUntil(15) { source.isFailed }, "ten bad frames in a row mark the instance failed")
        XCTAssertGreaterThanOrEqual(source.decodeErrors, 10)
        var picked = PickedFrame()
        _ = source.pick(mediaTimeMs: 0, into: &picked)
        XCTAssertNotEqual(source.pick(mediaTimeMs: 5000, into: &picked), .nothing, "the last good frame holds")
        XCTAssertTrue(log.contains("10 consecutive errors"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(log.recent.filter { $0.message.contains("10 consecutive errors") }.count, 1, "logged once")
    }

    /// "Frame not ready at tick: Repeat the previous channel texture; count videoRepeat for that channel."
    func test_frameNotReadyRepeatsAndCountsVideoRepeat() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        let source = try XCTUnwrap(engine.fakeSources?.liveSources.first)
        source.framesMs = [0, 1000]   // nothing new for a second of ticks
        engine.tick(count: 5)
        let records = engine.drainMetrics()
        XCTAssertEqual(records.last?.videoRepeat, [1], "channel 1 repeated")
        XCTAssertGreaterThan(engine.renderLoop.totalRepeats, 0)
        XCTAssertEqual(engine.lastPlan?.channelPasses.count, 1, "the pass still runs; the previous frame is sampled again")
    }

    /// "Render thread misses a tick: Sinks present or re-schedule their last frame; count tickMissed."
    func test_sinkRePresentsWhenNoNewFrameArrived() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        engine.tick(count: 2)
        let sink = try XCTUnwrap(engine.sinks[1])
        XCTAssertEqual(sink.rePresentCount, 0)
        sink.present(now: engine.clock.now().advanced(by: 16_000_000))   // a refresh with nothing new
        XCTAssertEqual(sink.rePresentCount, 1)
        var records: [PresentRecord] = []
        sink.presents.drain { records.append($0) }
        XCTAssertEqual(records.last?.rePresented, true)
        let late = engine.livenessReading()
        XCTAssertEqual(Watchdog.check(late), [])
        var reading = late
        reading.now = reading.now.advanced(by: 3 * reading.tickNanoseconds)
        XCTAssertEqual(Watchdog.check(reading).count, 3, "a render thread silent for three ticks is reported, and both sinks that waited on it")
    }

    /// "Metal device lost or command buffer error: Hold last frames on every
    /// sink from CPU copies ...; rebuild pipelines and heaps; resume; log as a
    /// severe event."
    func test_gpuErrorRebuildsPipelinesAndHoldsTheLastFrame() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        let backend = try XCTUnwrap(engine.recording)
        engine.tick(count: 2)
        let sink = try XCTUnwrap(engine.sinks[1])
        let presentedBefore = sink.presentedFrames.count
        backend.failNextCompletion = true
        engine.tick()   // this tick's work fails
        XCTAssertEqual(sink.presentedFrames.count, presentedBefore, "the failed frame is not presented; the previous one holds")
        engine.tick()   // the render thread sees the failure at its next tick
        XCTAssertEqual(engine.renderLoop.gpuFailures, 1)
        engine.tick()   // and the control side recovers when it builds the next plan
        XCTAssertEqual(backend.rebuilds, 1)
        XCTAssertEqual(engine.engine.recoveries, 1)
        XCTAssertEqual(engine.engine.watchdog.recoveries, 1)
        XCTAssertTrue(engine.log.recent.contains { $0.level == .severe && $0.message.contains("rebuilt") })
        engine.tick()
        XCTAssertGreaterThan(sink.presentedFrames.count, presentedBefore, "and presentation resumes")
    }

    /// "Display disconnected: Pause that sink, keep its ring; resume at the configured mode when it returns."
    func test_displaySinkStatePausesAndResumes() {
        var state = DisplaySinkState()
        let allComplete: (Int64) -> Bool = { _ in true }
        XCTAssertEqual(state.refresh(newestPublished: 2, elapsedTicks: 1, isComplete: allComplete), .skip, "stopped sinks do nothing")
        state.phase = .running
        XCTAssertEqual(state.refresh(newestPublished: 2, elapsedTicks: 1, isComplete: allComplete), .present(1), "one frame behind the newest")
        XCTAssertEqual(state.refresh(newestPublished: 2, elapsedTicks: 0, isComplete: allComplete), .rePresent, "no master time passed: the same frame again")
        state.screenChanged(available: false)
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.refresh(newestPublished: 3, elapsedTicks: 1, isComplete: allComplete), .skip, "paused: the ring is kept, nothing is presented")
        state.screenChanged(available: true)
        XCTAssertEqual(state.phase, .running)
        XCTAssertEqual(state.refresh(newestPublished: 3, elapsedTicks: 1, isComplete: allComplete), .present(2))
        XCTAssertEqual(state.presented, 2)
        XCTAssertEqual(state.rePresented, 1)
    }

    /// Spec 4 §10 — "takes the newest completed frame from the output's ring":
    /// one frame behind the master, so the race between the sink's vsync and
    /// the render thread on the same vsync never decides what shows; a frame
    /// still on the GPU falls back to the one before it; nothing new due is a
    /// re-present (Spec 4 §13) on a matched screen and a hold on a faster one.
    func test_displaySinkRefreshIsOneFrameBehindAndDeterministic() {
        var state = DisplaySinkState()
        state.phase = .running
        // The render thread publishes tick k on vsync k; the GPU finishes a little later.
        var inFlight: Int64 = -1
        let complete: (Int64) -> Bool = { $0 != inFlight }
        // Vsync 10, the master already ran: 10 is in flight, 9 is shown.
        inFlight = 10
        XCTAssertEqual(state.refresh(newestPublished: 10, elapsedTicks: 1, isComplete: complete), .present(9))
        // Vsync 11, the sink's callback ran before the master's: newest is still 10, now complete; 10 is shown.
        inFlight = -1
        XCTAssertEqual(state.refresh(newestPublished: 10, elapsedTicks: 1, isComplete: complete), .present(10))
        // Vsync 12, the master ran first and the GPU is slow: 12 in flight, 11 complete.
        inFlight = 12
        XCTAssertEqual(state.refresh(newestPublished: 12, elapsedTicks: 1, isComplete: complete), .present(11))
        // Vsync 13: the frame due (12) is still on the GPU: the previous one stays, counted.
        XCTAssertEqual(state.refresh(newestPublished: 13, elapsedTicks: 1, isComplete: complete), .rePresent)
        XCTAssertEqual(state.rePresented, 1)
        // Vsync 14: 12 finished; 13 is due and complete.
        inFlight = 14
        XCTAssertEqual(state.refresh(newestPublished: 14, elapsedTicks: 1, isComplete: complete), .present(13))
        // The sink's thread was starved for three vsyncs: it catches up to one behind.
        inFlight = -1
        XCTAssertEqual(state.refresh(newestPublished: 20, elapsedTicks: 3, isComplete: complete), .present(19))
        // Unlocked drift, the screen faster than the master: a vsync with no master time is a re-present.
        XCTAssertEqual(state.refresh(newestPublished: 20, elapsedTicks: 0.4, isComplete: complete), .rePresent)
        XCTAssertEqual(state.refresh(newestPublished: 21, elapsedTicks: 0.6, isComplete: complete), .present(20))
        XCTAssertEqual(state.presented, 6)
        XCTAssertEqual(state.rePresented, 2)

        // A 30p output on a 60 Hz screen: every other refresh holds, uncounted.
        var slow = DisplaySinkState()
        slow.phase = .running
        slow.ticksPerFrame = 2
        slow.screenMatchesOutput = false
        XCTAssertEqual(slow.refresh(newestPublished: 10, elapsedTicks: 1, isComplete: complete), .present(8))
        XCTAssertEqual(slow.refresh(newestPublished: 10, elapsedTicks: 1, isComplete: complete), .hold)
        XCTAssertEqual(slow.refresh(newestPublished: 12, elapsedTicks: 1, isComplete: complete), .present(10))
        XCTAssertEqual(slow.refresh(newestPublished: 12, elapsedTicks: 1, isComplete: complete), .hold)
        XCTAssertEqual(slow.rePresented, 0)
    }

    /// Spec 4 §12 — before the first tick, build or present there is nothing to have missed.
    func test_watchdogIgnoresWhatHasNotStarted() {
        let tick: Int64 = 16_666_667
        let fresh = LivenessReading(now: MonotonicTime(nanoseconds: 1_000_000_000_000), tickNanoseconds: tick,
                                    lastPlanConsumed: MonotonicTime(nanoseconds: 0), lastPlanBuilt: MonotonicTime(nanoseconds: 0),
                                    sinkLastPresent: [1: MonotonicTime(nanoseconds: 0)], queues: [])
        XCTAssertEqual(Watchdog.check(fresh), [])
    }

    /// "DeckLink card unplugged or mode unsupported: Pause that sink" — and with
    /// the stub, unavailable from the start; the engine runs on.
    func test_deckLinkUnavailableLeavesTheSinkPaused() throws {
        let backend = try MetalHarness.backend()
        let log = EngineLog(category: "test-decklink")
        let sink = DeckLinkSink(output: 2, persistentID: "decklink:none", format: VideoFormat(width: 1920, height: 1080, rate: .fps60), audioChannels: 2,
                                backend: backend, log: log)
        XCTAssertNoThrow(try sink.start())
        XCTAssertEqual(sink.currentPhase, DeckLinkSink.sdkAvailable ? sink.currentPhase : .unavailable)
        XCTAssertTrue(log.contains("unavailable") || DeckLinkSink.sdkAvailable)
        XCTAssertEqual(sink.scheduleAudio([0, 0], frames: 1, streamTime: 0), 0, "nothing is scheduled on an unavailable card")
        sink.stop()
        XCTAssertEqual(sink.currentPhase, .stopped)
    }

    /// "Media file disappears mid-play: Hold the last frame; mark missing; the next write replaces it."
    func test_mediaVanishingHoldsTheLastFrameAndMarksTheSourceFailed() throws {
        let url = try ClipFixtures.url(for: ClipFixtures.h264Loop)
        let log = EngineLog(category: "test-recovery")
        let source = VideoFileSource(url: url, inMs: 0, outMs: nil, loop: true, device: nil, demuxer: VanishingDemuxer(), log: log)
        source.start()
        defer { source.release() }
        XCTAssertTrue(waitUntil(15) { source.isReady })
        // Play through the clip so the decoder reaches the loop point and tries to reopen the file.
        var picked = PickedFrame()
        for tick in 0...75 {
            _ = waitUntil(2) { source.queueDepth > 0 || source.isFailed }
            _ = source.pick(mediaTimeMs: Double(tick) * 1000 / 60, into: &picked)
        }
        XCTAssertTrue(waitUntil(15) { source.isFailed }, "the reader cannot reopen the file at the loop")
        XCTAssertNotEqual(source.pick(mediaTimeMs: 2500, into: &picked), .nothing, "the last frame holds")
        XCTAssertTrue(log.contains("cannot reopen"))
    }

    /// "Control thread stalls: ... watchdog logs after 500 ms" and the plan is reused: Spec 4 §3.
    func test_controlStallIsReportedByTheWatchdog() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        engine.tick(count: 2)
        engine.stallControl(ticks: 40)
        engine.tick(count: 40)
        let reading = engine.livenessReading()
        let findings = Watchdog.check(reading)
        XCTAssertTrue(findings.contains { if case .controlThreadStalled = $0 { return true } else { return false } }, "\(findings)")
        XCTAssertTrue(engine.drainMetrics().suffix(40).allSatisfy(\.planReused))
        engine.engine.watchdog.record(findings)
        XCTAssertTrue(engine.log.contains("control thread built no plan"))
    }
}

/// A demuxer that hands over a few real samples, then garbage with a valid
/// format description, so the decoder reports errors.
final class GarbageAfterDemuxer: Demuxer, @unchecked Sendable {
    let name = "garbage"
    let goodSamples: Int
    private let inner = AVAssetReaderDemuxer()

    init(goodSamples: Int) {
        self.goodSamples = goodSamples
    }

    func open(_ url: URL, startMs: Double) throws -> any DemuxSession {
        GarbageSession(inner: try inner.open(url, startMs: startMs), goodSamples: goodSamples)
    }

    final class GarbageSession: DemuxSession, @unchecked Sendable {
        let inner: any DemuxSession
        let goodSamples: Int
        var delivered = 0
        var format: CMFormatDescription?

        init(inner: any DemuxSession, goodSamples: Int) {
            self.inner = inner
            self.goodSamples = goodSamples
        }

        var description: DemuxedStream { inner.description }

        func nextVideoSample() -> CompressedSample? {
            guard let sample = inner.nextVideoSample() else { return nil }
            delivered += 1
            guard delivered > goodSamples else { return sample }
            // Replace the bytes with noise but keep the timing and format.
            guard CFGetTypeID(sample.payload as CFTypeRef) == CMSampleBufferGetTypeID() else { return sample }
            let original = sample.payload as! CMSampleBuffer
            guard let format = CMSampleBufferGetFormatDescription(original) else { return sample }
            var block: CMBlockBuffer?
            let length = 256
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
                                                     offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return sample }
            var noise = (0..<length).map { _ in UInt8.random(in: 0...255) }
            noise[0] = 0
            noise[1] = 0
            noise[2] = 0
            noise[3] = 1
            _ = noise.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
            var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(original), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
                                            decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(original))
            var sizes = length
            var garbage: CMSampleBuffer?
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
                                            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &garbage) == noErr,
                  let garbage else { return sample }
            return CompressedSample(presentationMs: sample.presentationMs, durationMs: sample.durationMs, isKeyframe: false, payload: garbage)
        }

        func close() { inner.close() }
    }
}

/// A demuxer whose file "vanishes": the first open works, every later open fails.
final class VanishingDemuxer: Demuxer, @unchecked Sendable {
    let name = "vanishing"
    private let inner = AVAssetReaderDemuxer()
    private var opens = 0
    private let lock = NSLock()

    func open(_ url: URL, startMs: Double) throws -> any DemuxSession {
        lock.lock()
        opens += 1
        let first = opens == 1
        lock.unlock()
        guard first else { throw DemuxError.cannotStart("file vanished") }
        return try inner.open(url, startMs: startMs)
    }
}
