// OEngine — Spec 4 §10, the DeckLink sink; Spec 4 §2, the DeckLink clock.
// Both talk to the card only through the C face of the ODeckLink module.

import Foundation
import Metal
import ODeckLink
import OCore
import Synchronization

/// Spec 4 §10 — the v210 frame ring the card reads by DMA: "an MTLBuffer with
/// shared storage that the card reads by DMA through a custom frame buffer
/// object, so the only CPU involvement is scheduling." Three buffers, one per
/// slot of the output's ring.
public final class V210Buffers: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let rowBytes: Int
    public let buffers: [MTLBuffer]

    public init?(device: MTLDevice, width: Int, height: Int) {
        self.width = width
        self.height = height
        rowBytes = ((width + 47) / 48) * 128
        var buffers: [MTLBuffer] = []
        for slot in 0..<FrameRing.depth {
            guard let buffer = device.makeBuffer(length: rowBytes * height, options: .storageModeShared) else { return nil }
            buffer.label = "v210 slot \(slot)"
            buffers.append(buffer)
        }
        self.buffers = buffers
    }

    public func buffer(forSlot slot: Int) -> MTLBuffer { buffers[((slot % FrameRing.depth) + FrameRing.depth) % FrameRing.depth] }
}

/// Spec 4 §2 — "The DeckLink hardware clock, locked to reference" or
/// "free-running". A timer thread paces itself on the card's stream time.
public final class DeckLinkClock: MasterClock, @unchecked Sendable {
    public let name = "decklink"
    public static let timeScale: Int64 = 1_000_000_000
    private let device: OpaquePointer?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)

    init(device: OpaquePointer?) {
        self.device = device
    }

    public func now() -> MonotonicTime {
        var time: Int64 = 0
        var ticksPerFrame: Int64 = 0
        guard let device, odl_hardware_time(device, DeckLinkClock.timeScale, &time, &ticksPerFrame) == ODL_OK else { return MonotonicClock.now() }
        return MonotonicTime(nanoseconds: time)
    }

    /// Spec 4 §10 — "Reference lock status is read from the card and reported".
    public var referenceLocked: Bool {
        var locked = false
        guard let device, odl_reference_locked(device, &locked) == ODL_OK else { return false }
        return locked
    }

    public func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void) {
        guard device != nil, !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let period = rate.nanosecondsPerFrame
        let thread = Thread { [self] in
            RealtimeThread.promote(periodNs: period)
            var tick: Int64 = 0
            var target = now().nanoseconds + period
            while running.load(ordering: .relaxed) {
                // Sleep on the machine clock until the card's next frame boundary, then read the card.
                let offset = target - now().nanoseconds
                RealtimeThread.sleep(until: MonotonicClock.now().nanoseconds + offset)
                guard running.load(ordering: .relaxed) else { break }
                let reference = now()
                autoreleasepool { handler(TickTime(tick: tick, reference: reference, wake: MonotonicClock.now())) }
                tick += 1
                target += period
                if reference.nanoseconds > target + period { target = reference.nanoseconds + period }
            }
        }
        thread.name = "o.engine.clock.decklink"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        thread = nil
    }
}

/// Spec 4 §10 — "DeckLink sink. The output is enabled in the configured mode
/// with 10-bit YUV (v210) frames, limited range, Rec.709. ... Frames are
/// scheduled two to three ahead on the card's stream time; the completion
/// callback reports completed, displayedLate, dropped or flushed per frame
/// and those feed the metrics. If the render thread misses a tick, the sink
/// re-schedules the previous frame so the card never starves."
///
/// Spec 4 §12 — "DeckLink card unplugged or mode unsupported: Pause that sink;
/// if it was the master clock, fall back per section 2 within one second;
/// resume when available." Without the SDK (the stub) the card is
/// unavailable from the start and the sink stays paused.
public final class DeckLinkSink: OutputSink, @unchecked Sendable {
    public enum Phase: Equatable, Sendable { case stopped, unavailable, running, paused }

    public let output: Int
    public let encode: EncodeKind = .v210
    public let ring = FrameRing()
    public let presents = PresentRing()
    public let persistentID: String
    public let format: VideoFormat
    public let audioChannels: Int
    private let backend: MetalBackend
    private let log: EngineLog
    private let lastPresentNs = Atomic<Int64>(0)
    private let lock = NSLock()
    private var phase = Phase.stopped
    private var device: OpaquePointer?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    public private(set) var buffers: V210Buffers?
    private var scheduledTick: Int64 = -1
    private var streamTime: Int64 = 0
    private var dropsSinceStart: Int64 = 0
    public private(set) var clock: DeckLinkClock?
    private var lastScheduledSlot: Int?

    public init(output: Int, persistentID: String, format: VideoFormat, audioChannels: Int, backend: MetalBackend, log: EngineLog) {
        self.output = output
        self.persistentID = persistentID
        self.format = format
        self.audioChannels = audioChannels
        self.backend = backend
        self.log = log
    }

    public var lastPresent: MonotonicTime { MonotonicTime(nanoseconds: lastPresentNs.load(ordering: .acquiring)) }

    public var currentPhase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return phase
    }

    public static var sdkAvailable: Bool { odl_sdk_available() }

    // MARK: - Lifecycle

    /// Opens the card. An unavailable card does not throw: the sink pauses
    /// and the engine runs on (Spec 4 §12).
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        var opened: OpaquePointer?
        let status = odl_open(persistentID, &opened)
        guard status == ODL_OK, let opened else {
            setPhase(.unavailable)
            log.error("DeckLink output \(output) (\(persistentID)) unavailable: \(DeckLinkSink.describe(status)); the sink is paused")
            return
        }
        device = opened
        let mode = odl_mode_t(width: Int32(format.width), height: Int32(format.height), rate_num: Int32(format.rate.num),
                              rate_den: Int32(format.rate.den), interlaced: format.interlaced)
        let enabled = odl_enable_output(opened, mode, ODL_PIXEL_V210, odl_audio_config_t(channel_count: Int32(audioChannels)))
        guard enabled == ODL_OK else {
            setPhase(.unavailable)
            log.error("DeckLink output \(output): mode \(format.width)x\(format.height) refused: \(DeckLinkSink.describe(enabled))")
            return
        }
        guard let buffers = V210Buffers(device: backend.device, width: format.width, height: format.height) else {
            setPhase(.unavailable)
            log.error("DeckLink output \(output): cannot allocate the v210 ring")
            return
        }
        self.buffers = buffers
        backend.registerV210(output: output, buffers: buffers)
        let context = Unmanaged.passUnretained(self).toOpaque()
        odl_set_callbacks(opened, { context, frameContext, result in
            guard let context else { return }
            Unmanaged<DeckLinkSink>.fromOpaque(context).takeUnretainedValue().frameCompleted(frameContext, result)
        }, { context in
            guard let context else { return }
            Unmanaged<DeckLinkSink>.fromOpaque(context).takeUnretainedValue().playbackStopped()
        }, context)
        clock = DeckLinkClock(device: opened)
        streamTime = clock?.now().nanoseconds ?? 0
        guard odl_start_playback(opened, streamTime, DeckLinkClock.timeScale) == ODL_OK else {
            setPhase(.unavailable)
            log.error("DeckLink output \(output): playback did not start")
            return
        }
        setPhase(.running)
        let thread = Thread { [self] in self.scheduleLoop() }
        thread.name = "o.engine.sink.decklink.\(output)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        log.info("DeckLink output \(output) running at \(format.width)x\(format.height)\(format.interlaced ? "i" : "p") \(format.rate.num)/\(format.rate.den)")
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        clock?.stop()
        if let device {
            odl_stop_playback(device)
            odl_disable_output(device)
            odl_close(device)
        }
        device = nil
        setPhase(.stopped)
    }

    private func setPhase(_ new: Phase) {
        lock.lock()
        phase = new
        lock.unlock()
    }

    static func describe(_ status: odl_status_t) -> String {
        switch status {
        case ODL_OK: return "ok"
        case ODL_ERR_UNAVAILABLE: return "no SDK, driver or card"
        case ODL_ERR_NOT_FOUND: return "no card with that id"
        case ODL_ERR_MODE: return "mode not supported"
        case ODL_ERR_STATE: return "wrong state"
        case ODL_ERR_SCHEDULE: return "scheduling refused"
        default: return "internal error \(status.rawValue)"
        }
    }

    // MARK: - Scheduling (the sink's own thread)

    /// Spec 4 §10 — scheduled two ahead on stream time; the previous frame
    /// re-scheduled when the render thread misses a tick.
    private func scheduleLoop() {
        let period = format.rate.nanosecondsPerFrame * (format.interlaced ? 2 : 1)
        var nextDue = streamTime
        while running.load(ordering: .relaxed), currentPhase == .running {
            let newest = ring.newest
            let ready = newest.flatMap { frame -> CompletedFrame? in
                guard let completion = backend.completion(of: frame.receipt), !completion.failed else { return nil }
                return frame
            }
            guard let device, let buffers else { break }
            var buffered: UInt32 = 0
            _ = odl_buffered_video_frames(device, &buffered)
            if buffered >= 3 {
                Thread.sleep(forTimeInterval: Double(period) / 4_000_000_000)
                continue
            }
            let slot: Int
            let tick: Int64
            var rePresented = false
            if let ready, ready.tick != scheduledTick {
                slot = ready.destination
                tick = ready.tick
                scheduledTick = ready.tick
            } else if let last = lastScheduledSlot {
                slot = last
                tick = scheduledTick
                rePresented = true
                dropsSinceStart += 1
            } else {
                Thread.sleep(forTimeInterval: 0.001)
                continue
            }
            let buffer = buffers.buffer(forSlot: slot)
            let status = odl_schedule_video(device, buffer.contents(), Int32(buffers.rowBytes), nextDue, period, DeckLinkClock.timeScale,
                                            UnsafeMutableRawPointer(bitPattern: Int(tick + 1)))
            if status != ODL_OK {
                log.error("DeckLink output \(output): schedule refused (\(DeckLinkSink.describe(status))); pausing")
                setPhase(.paused)
                break
            }
            lastScheduledSlot = slot
            nextDue += period
            presents.write(PresentRecord(output: output, frame: tick, rePresented: rePresented, latencyNs: nextDue - (clock?.now().nanoseconds ?? nextDue),
                                         completion: nil, dropsSinceStart: dropsSinceStart))
            lastPresentNs.store(MonotonicClock.now().nanoseconds, ordering: .releasing)
        }
    }

    private func frameCompleted(_ frameContext: UnsafeMutableRawPointer?, _ result: odl_completion_t) {
        let tick = Int64(Int(bitPattern: frameContext)) - 1
        let completion: SinkCompletion
        switch result {
        case ODL_COMPLETED: completion = .completed
        case ODL_DISPLAYED_LATE: completion = .displayedLate
        case ODL_DROPPED: completion = .dropped
        default: completion = .flushed
        }
        if completion == .dropped { dropsSinceStart += 1 }
        presents.write(PresentRecord(output: output, frame: tick, rePresented: false, latencyNs: 0, completion: completion, dropsSinceStart: dropsSinceStart))
    }

    private func playbackStopped() {
        log.error("DeckLink output \(output): playback stopped by the card; pausing")
        setPhase(.paused)
    }

    // MARK: - Embedded audio (Spec 4 §10, §11)

    /// Spec 4 §10 — "Embedded audio is enabled on the same output at 48 kHz,
    /// 24-bit in 32-bit words, scheduled against the same stream time as the
    /// video." Returns how many frames the card took.
    public func scheduleAudio(_ samples: [Int32], frames: Int, streamTime: Int64) -> Int {
        guard let device, currentPhase == .running else { return 0 }
        var written: UInt32 = 0
        let status = samples.withUnsafeBufferPointer { pointer in
            odl_schedule_audio(device, pointer.baseAddress, UInt32(frames), streamTime, DeckLinkClock.timeScale, &written)
        }
        return status == ODL_OK ? Int(written) : 0
    }
}
