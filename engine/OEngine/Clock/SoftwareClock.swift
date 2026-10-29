// OEngine — Spec 4 §14, "tests can run it headless with a software clock".

import Foundation
import OCore

/// Spec 4 §14 — the software clock of the headless harness: a tick happens
/// when the test says so, delivered synchronously on the caller's thread, and
/// monotonic time is the tick count times the tick length. Nothing about the
/// engine knows it is not a hardware clock.
public final class SoftwareClock: MasterClock, @unchecked Sendable {
    public let name = "software"
    private var tick: Int64 = -1
    private var tickNanoseconds: Int64 = FrameRate.fps60.nanosecondsPerFrame
    private var handler: (@Sendable (TickTime) -> Void)?

    public init() {}

    /// The tick most recently delivered, or -1 before the first.
    public var currentTick: Int64 { tick }

    public func now() -> MonotonicTime {
        MonotonicTime(nanoseconds: max(0, tick) * tickNanoseconds)
    }

    public func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void) {
        tickNanoseconds = rate.nanosecondsPerFrame
        self.handler = handler
    }

    public func stop() {
        handler = nil
    }

    /// Deliver the next tick now, on this thread.
    public func advance() {
        tick += 1
        let time = now()
        handler?(TickTime(tick: tick, reference: time, wake: time))
    }
}

/// Spec 4 §2 — "All engine time is monotonic (mach absolute time)". The
/// production clocks read this; the software clock does not.
public enum MonotonicClock {
    public static func now() -> MonotonicTime {
        MonotonicTime(nanoseconds: Int64(clamping: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
    }
}
