// OEngine — Spec 4 §14, the `MasterClock` seam; Spec 4 §2, clocks and time.

import Foundation
import OCore

/// Spec 4 §2 — "All engine time is monotonic (mach absolute time); the wall
/// clock is read only to stamp log lines and resolve [Time], so an NTP
/// adjustment mid-service can never move a frame."
public struct MonotonicTime: Hashable, Comparable, Codable, Sendable {
    public var nanoseconds: Int64

    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    public static let zero = MonotonicTime(nanoseconds: 0)

    public static func < (a: MonotonicTime, b: MonotonicTime) -> Bool { a.nanoseconds < b.nanoseconds }

    /// The interval from `b` to `a`, in nanoseconds.
    public static func - (a: MonotonicTime, b: MonotonicTime) -> Int64 { a.nanoseconds - b.nanoseconds }

    public func advanced(by nanoseconds: Int64) -> MonotonicTime {
        MonotonicTime(nanoseconds: self.nanoseconds + nanoseconds)
    }
}

/// Spec 4 §2 — one tick of the master clock: the frame counter Spec 3 uses as
/// `frame`, the master's reference reading for this tick ("DeckLink hardware
/// reference time, or the display link's target timestamp") and the moment the
/// render thread woke.
public struct TickTime: Equatable, Sendable {
    public var tick: Int64
    public var reference: MonotonicTime
    public var wake: MonotonicTime

    public init(tick: Int64, reference: MonotonicTime, wake: MonotonicTime) {
        self.tick = tick
        self.reference = reference
        self.wake = wake
    }
}

/// Spec 4 §14 — `MasterClock`: "DeckLink hardware clock, CADisplayLink" in
/// v1; "LTC, MTC and Art-Net timecode as clocks (v2)" through the same seam.
/// Spec 4 §2 — "One master tick ... Every tick increments the frame counter".
///
/// A clock delivers ticks to its handler on a thread of its own choosing: the
/// software clock on the caller's thread, synchronously; a hardware clock from
/// its callback thread, where the handler wakes the render thread.
public protocol MasterClock: AnyObject, Sendable {
    var name: String { get }
    /// Spec 4 §2 — monotonic engine time now.
    func now() -> MonotonicTime
    /// Start delivering ticks at `rate`, the master rate of Spec 4 §2.
    func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void)
    func stop()
}

extension FrameRate {
    /// The length of one tick at this rate, in whole nanoseconds.
    public var nanosecondsPerFrame: Int64 {
        guard num > 0, den > 0 else { return 0 }
        return (1_000_000_000 * Int64(den)) / Int64(num)
    }

    /// Frames per second as a double, for comparisons only.
    public var perSecond: Double {
        guard den > 0 else { return 0 }
        return Double(num) / Double(den)
    }

    /// The rate with its numerator and denominator divided by their greatest
    /// common divisor, so 60000/1001 and 120000/2002 are one family.
    public var reduced: FrameRate {
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = max(1, gcd(abs(num), abs(den)))
        return FrameRate(num: num / g, den: den / g)
    }
}
