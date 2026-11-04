// OEngine — Spec 4 §11, "SDI embedded audio ... Its mix is produced by the
// same graph on a timer thread (there is no device callback) and scheduled
// against the DeckLink stream time"; Spec 4 §12, the silence stand-in for a
// lost device (Area 16).

import Foundation
import OCore
import Synchronization

/// Spec 4 §10 — "Embedded audio is enabled on the same output at 48 kHz,
/// 24-bit in 32-bit words, scheduled against the same stream time as the
/// video": where a paced device sends its blocks. The DeckLink sink is the
/// one implementation; a fake card stands in for it in the tests.
public protocol StreamAudioDestination: AnyObject, Sendable {
    /// The card's stream time now, in nanoseconds; nil while the card is not running.
    var streamTimeNowNs: Int64? { get }
    /// How far ahead of the stream time blocks are scheduled: the sink's video lead.
    var audioLeadNs: Int64 { get }
    /// Schedules interleaved 24-in-32-bit samples at `streamTime`; returns the frames the card took.
    func scheduleAudio(_ samples: UnsafeBufferPointer<Int32>, frames: Int, streamTime: Int64) -> Int
    /// `handler` runs whenever the card starts or stops running.
    func observeStream(_ handler: @escaping @Sendable () -> Void)
}

public extension StreamAudioDestination {
    func observeStream(_ handler: @escaping @Sendable () -> Void) {}
}

/// A clock a test sets by hand, in nanoseconds.
public final class SettableNanoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    public init(nowNs: Int64) {
        value = nowNs
    }

    public var nowNs: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

/// Spec 4 §11 — a device driven by its own timer thread instead of a Core
/// Audio callback. Every 10 ms block it runs the graph's render callback with
/// the block's time and hands the mix to its destination: the DeckLink sink's
/// `scheduleAudio`, where blocks land contiguously on the card's stream time
/// and stay the video lead ahead of it, so "embedded audio and the picture
/// share one clock"; or nowhere, as the silence stand-in of Spec 4 §12,
/// consuming on the machine clock so the rings, the instance clocks and the
/// picture keep moving while a lost device's output is silent. While a card
/// is not running the embedded feed behaves as the stand-in and joins the
/// card's stream time when it starts.
///
/// With `threaded` false nothing runs by itself: `step()` does one pass, for
/// the tests. The destination call happens on the timer thread, never in a
/// Core Audio callback (Spec 4 §3).
public final class PacedAudioDevice: AudioDevice, @unchecked Sendable {
    public static let blockFrames = 480
    public static let blockNs: Int64 = 10_000_000
    /// A block further behind than this is a jump, not a late wake: the feed
    /// resyncs to now instead of scheduling the gap.
    public static let resyncAfterNs: Int64 = 500_000_000
    /// How long the thread sleeps between passes: half a block.
    static let sleepNs: Int64 = 5_000_000

    public let name: String
    public let sampleRate: Double = 48_000
    public let channelCount: Int
    public let destination: (any StreamAudioDestination)?
    private let clock: @Sendable () -> Int64
    private let threaded: Bool
    private let log: EngineLog?
    private let lock = NSLock()
    private var render: AudioRenderCallback?
    private var next: Int64?
    private var stream = false
    private var refusalLogged = false
    private let floats: UnsafeMutablePointer<Float>
    private let ints: UnsafeMutablePointer<Int32>
    private let running = Atomic<Bool>(false)
    private let onStreamFlag = Atomic<Bool>(false)
    private let scheduledCount = Atomic<Int64>(0)
    private let refusedCount = Atomic<Int64>(0)
    private let resyncCount = Atomic<Int64>(0)
    private var thread: Thread?

    public init(name: String, channelCount: Int, destination: (any StreamAudioDestination)?,
                clock: @escaping @Sendable () -> Int64 = { MonotonicClock.now().nanoseconds }, threaded: Bool = true, log: EngineLog? = nil) {
        self.name = name
        self.channelCount = max(1, channelCount)
        self.destination = destination
        self.clock = clock
        self.threaded = threaded
        self.log = log
        let count = PacedAudioDevice.blockFrames * self.channelCount
        floats = UnsafeMutablePointer<Float>.allocate(capacity: count)
        floats.initialize(repeating: 0, count: count)
        ints = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        ints.initialize(repeating: 0, count: count)
    }

    deinit {
        floats.deallocate()
        ints.deallocate()
    }

    /// True while the blocks go to the card's stream time; false while they
    /// are consumed on the machine clock.
    public var onStream: Bool { onStreamFlag.load(ordering: .relaxed) }
    public var blocksScheduled: Int64 { scheduledCount.load(ordering: .relaxed) }
    /// Blocks a running card refused; their samples are dropped, not replayed.
    public var refused: Int64 { refusedCount.load(ordering: .relaxed) }
    /// Joins of the stream time and jumps resynced.
    public var resyncs: Int64 { resyncCount.load(ordering: .relaxed) }
    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// The clock the graph's media time reads: the card's stream time while on it, else the machine clock.
    public var hostTimeNowNs: Int64 { destination?.streamTimeNowNs ?? clock() }

    public func start(render: @escaping AudioRenderCallback) throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        lock.lock()
        self.render = render
        next = nil
        lock.unlock()
        guard threaded else { return }
        let thread = Thread { [self] in
            RealtimeThread.promote(periodNs: PacedAudioDevice.blockNs)
            while running.load(ordering: .relaxed) {
                autoreleasepool { step() }
                RealtimeThread.sleep(until: MonotonicClock.now().nanoseconds + PacedAudioDevice.sleepNs)
            }
        }
        thread.name = "o.engine.audio.paced.\(name)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stops the pacing; returns after a pass in flight has finished, so a
    /// swap never has two consumers on a ring.
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        lock.lock()
        render = nil
        next = nil
        lock.unlock()
        thread = nil
    }

    /// One pass: every block due up to now plus the lead is rendered and
    /// delivered. Blocks are contiguous on the current time axis; a change
    /// of axis (the card started or stopped) or a jump re-anchors at now.
    public func step() {
        lock.lock()
        guard let render else {
            lock.unlock()
            return
        }
        let streamNow = destination?.streamTimeNowNs
        let onStream = streamNow != nil
        let now = streamNow ?? clock()
        let lead = onStream ? (destination?.audioLeadNs ?? 0) : 0
        if next == nil || onStream != stream {
            if next != nil {
                resyncCount.add(1, ordering: .relaxed)
                log?.info(onStream ? "\(name): joined the card's stream time" : "\(name): left the card's stream time; consuming on the machine clock")
            }
            stream = onStream
            onStreamFlag.store(onStream, ordering: .relaxed)
            next = now
        }
        guard var due = next else {
            lock.unlock()
            return
        }
        if now - due > PacedAudioDevice.resyncAfterNs {
            resyncCount.add(1, ordering: .relaxed)
            log?.warning("\(name): resynced \((now - due) / 1_000_000) ms behind")
            due = now
        }
        let frames = PacedAudioDevice.blockFrames
        let channels = channelCount
        while due <= now + lead {
            render(floats, frames, due)
            if onStream, let destination {
                for i in 0..<(frames * channels) { ints[i] = PacedAudioDevice.sample24in32(floats[i]) }
                let written = destination.scheduleAudio(UnsafeBufferPointer(start: ints, count: frames * channels), frames: frames, streamTime: due)
                if written >= frames {
                    scheduledCount.add(1, ordering: .relaxed)
                } else {
                    refusedCount.add(1, ordering: .relaxed)
                    if !refusalLogged {
                        refusalLogged = true
                        log?.error("\(name): the card refused a block of embedded audio; dropping refused blocks")
                    }
                }
            }
            due += PacedAudioDevice.blockNs
        }
        next = due
        lock.unlock()
    }

    /// Spec 4 §10 — "24-bit in 32-bit words": the 24-bit sample in the top bytes.
    @inline(__always)
    static func sample24in32(_ sample: Float) -> Int32 {
        let scaled = (max(-1, min(1, sample)) * 8_388_607).rounded()
        return Int32(scaled) << 8
    }
}
