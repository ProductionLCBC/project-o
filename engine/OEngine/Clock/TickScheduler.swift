// OEngine — Spec 4 §2, "Where the tick comes from": the render thread's
// disciplined timer and the clock fallback.

import Foundation
import Darwin
import OCore
import Synchronization

/// Spec 4 §2 — the last row of the clock table has a further fallback: a
/// plain timer at the master rate, for a machine with neither a DeckLink nor
/// a display link (the headless process on a Mac with no screen, the tests).
public final class TimerClock: MasterClock, @unchecked Sendable {
    public let name = "timer"
    private var thread: Thread?
    private let running = Atomic<Bool>(false)

    public init() {}

    public func now() -> MonotonicTime { MonotonicClock.now() }

    public func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void) {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let period = rate.nanosecondsPerFrame
        let thread = Thread { [self] in
            RealtimeThread.promote(periodNs: period)
            var tick: Int64 = 0
            var next = MonotonicClock.now().nanoseconds + period
            while self.running.load(ordering: .relaxed) {
                RealtimeThread.sleep(until: next)
                guard self.running.load(ordering: .relaxed) else { break }
                let now = MonotonicClock.now()
                handler(TickTime(tick: tick, reference: MonotonicTime(nanoseconds: next), wake: now))
                tick += 1
                next += period
                // Never try to catch up more than a tick: late is late.
                if now.nanoseconds > next + period { next = now.nanoseconds + period }
            }
        }
        thread.name = "o.engine.clock.timer"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        thread = nil
    }
}

/// Spec 4 §3 — "Render: real-time (time-constraint policy)".
public enum RealtimeThread {
    /// Ask the kernel for the time-constraint policy on the calling thread.
    public static func promote(periodNs: Int64) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toAbs = Double(timebase.denom) / Double(timebase.numer)
        var policy = thread_time_constraint_policy(
            period: UInt32(Double(periodNs) * toAbs),
            computation: UInt32(Double(periodNs / 4) * toAbs),
            constraint: UInt32(Double(periodNs / 2) * toAbs),
            preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy>.size / MemoryLayout<integer_t>.size)
        withUnsafeMutablePointer(to: &policy) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                _ = thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), rebound, count)
            }
        }
    }

    /// Sleep until a monotonic nanosecond time (mach_wait_until).
    public static func sleep(until nanoseconds: Int64) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let abs = UInt64(max(0, nanoseconds)) * UInt64(timebase.denom) / UInt64(timebase.numer)
        mach_wait_until(abs)
    }
}

/// Spec 4 §2 — "The render thread's wake-up is a timer disciplined to the
/// master clock: each tick it reads the master's time ..., corrects its phase,
/// and never free-runs for more than one tick without a reference reading. If
/// the master clock disappears (a card unplugged), the engine falls back to the
/// next row in the table within one second and logs it."
///
/// The scheduler owns the render thread. The active clock's ticks land in a
/// mailbox and wake the thread; when none comes within a tick and a half the
/// thread free-runs one tick (so every output still gets a frame, Spec 4 §1);
/// after a second without a reference it moves to the next clock.
public final class TickScheduler: @unchecked Sendable {
    public static let fallbackAfterNs: Int64 = 1_000_000_000

    private let clocks: [any MasterClock]
    private let rate: FrameRate
    private let log: EngineLog
    private let onTick: @Sendable (TickTime) -> Void
    private let onFallback: (@Sendable (String) -> Void)?
    private let semaphore = DispatchSemaphore(value: 0)
    private let mailboxReference = Atomic<Int64>(0)
    private let mailboxTick = Atomic<Int64>(-1)
    private let activeIndex = Atomic<Int>(0)
    private let running = Atomic<Bool>(false)
    private let freeRuns = Atomic<Int64>(0)
    private let fallbackCount = Atomic<Int64>(0)
    private let ticks = Atomic<Int64>(0)
    private var thread: Thread?

    public init(clocks: [any MasterClock], rate: FrameRate, log: EngineLog, onFallback: (@Sendable (String) -> Void)? = nil,
                onTick: @escaping @Sendable (TickTime) -> Void) {
        self.clocks = clocks
        self.rate = rate
        self.log = log
        self.onTick = onTick
        self.onFallback = onFallback
    }

    public var activeClock: any MasterClock { clocks[min(clocks.count - 1, activeIndex.load(ordering: .relaxed))] }
    public var freeRunTicks: Int64 { freeRuns.load(ordering: .relaxed) }
    public var fallbacks: Int64 { fallbackCount.load(ordering: .relaxed) }
    public var tickCount: Int64 { ticks.load(ordering: .relaxed) }

    public func start() {
        guard !clocks.isEmpty, !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        startClock(at: 0)
        let period = rate.nanosecondsPerFrame
        let thread = Thread { [self] in
            RealtimeThread.promote(periodNs: period)
            var tick: Int64 = 0
            var lastReference = MonotonicClock.now()
            var lastReferenceAt = MonotonicClock.now()
            while running.load(ordering: .relaxed) {
                let result = semaphore.wait(timeout: .now() + .nanoseconds(Int(period + period / 2)))
                guard running.load(ordering: .relaxed) else { break }
                let now = MonotonicClock.now()
                if result == .success {
                    let reference = MonotonicTime(nanoseconds: mailboxReference.load(ordering: .acquiring))
                    lastReference = reference
                    lastReferenceAt = now
                    onTick(TickTime(tick: tick, reference: reference, wake: now))
                } else {
                    // Spec 4 §2 — free-run one tick on the last reference, phase advanced.
                    freeRuns.add(1, ordering: .relaxed)
                    lastReference = lastReference.advanced(by: period)
                    onTick(TickTime(tick: tick, reference: lastReference, wake: now))
                    if now - lastReferenceAt > TickScheduler.fallbackAfterNs {
                        fallBack()
                        lastReferenceAt = now
                    }
                }
                tick += 1
                ticks.add(1, ordering: .relaxed)
            }
        }
        thread.name = "o.engine.render"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        clocks[activeIndex.load(ordering: .relaxed)].stop()
        semaphore.signal()
        thread = nil
    }

    private func startClock(at index: Int) {
        activeIndex.store(index, ordering: .releasing)
        clocks[index].start(rate: rate) { [self] time in
            mailboxReference.store(time.reference.nanoseconds, ordering: .releasing)
            mailboxTick.store(time.tick, ordering: .relaxed)
            semaphore.signal()
        }
    }

    /// Spec 4 §2 — "falls back to the next row in the table within one second and logs it".
    private func fallBack() {
        let current = activeIndex.load(ordering: .relaxed)
        guard current + 1 < clocks.count else {
            log.error("master clock \(clocks[current].name) gives no reference and there is no clock left to fall back to")
            return
        }
        clocks[current].stop()
        fallbackCount.add(1, ordering: .relaxed)
        log.error("master clock \(clocks[current].name) disappeared; falling back to \(clocks[current + 1].name)")
        startClock(at: current + 1)
        onFallback?(clocks[current + 1].name)
    }
}
