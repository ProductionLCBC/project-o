// OEngine — Spec 4 §11, "a lock-free ring of about 200 ms per instance".

import Foundation
import Synchronization

/// Spec 4 §11 — the per-instance sample ring: interleaved float frames,
/// written by the instance's decode thread, read by the device callback.
/// Single producer, single consumer, no lock, no allocation after
/// construction.
public final class AudioRing: @unchecked Sendable {
    public let channels: Int
    public let capacityFrames: Int
    private let samples: UnsafeMutablePointer<Float>
    private let head = Atomic<Int64>(0)   // frames written
    private let tail = Atomic<Int64>(0)   // frames read
    private let ended = Atomic<Bool>(false)

    public init(channels: Int, capacityFrames: Int = 12_000) {
        self.channels = max(1, channels)
        self.capacityFrames = max(64, capacityFrames)
        samples = UnsafeMutablePointer<Float>.allocate(capacity: self.capacityFrames * self.channels)
        samples.initialize(repeating: 0, count: self.capacityFrames * self.channels)
    }

    deinit {
        samples.deallocate()
    }

    public var framesAvailable: Int { Int(head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)) }
    public var framesFree: Int { capacityFrames - Int(head.load(ordering: .relaxed) - tail.load(ordering: .acquiring)) }
    public var isEnded: Bool { ended.load(ordering: .acquiring) }

    /// Producer: append interleaved frames; returns how many fit.
    @discardableResult
    public func write(_ frames: UnsafeBufferPointer<Float>) -> Int {
        let count = min(frames.count / channels, framesFree)
        guard count > 0, let base = frames.baseAddress else { return 0 }
        let h = head.load(ordering: .relaxed)
        for i in 0..<count {
            let slot = Int((h + Int64(i)) % Int64(capacityFrames))
            for c in 0..<channels { samples[slot * channels + c] = base[i * channels + c] }
        }
        head.store(h + Int64(count), ordering: .releasing)
        return count
    }

    public func write(_ frames: [Float]) -> Int {
        frames.withUnsafeBufferPointer { write($0) }
    }

    /// Consumer: one frame, or silence and false when the ring is empty.
    @inline(__always)
    public func readFrame(into out: UnsafeMutablePointer<Float>) -> Bool {
        let t = tail.load(ordering: .relaxed)
        guard t < head.load(ordering: .acquiring) else {
            for c in 0..<channels { out[c] = 0 }
            return false
        }
        let slot = Int(t % Int64(capacityFrames))
        for c in 0..<channels { out[c] = samples[slot * channels + c] }
        tail.store(t + 1, ordering: .releasing)
        return true
    }

    /// Consumer: skip frames without reading them.
    public func skip(frames: Int) {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        tail.store(min(h, t + Int64(frames)), ordering: .releasing)
    }

    public func markEnded() { ended.store(true, ordering: .releasing) }

    /// Producer side: drop everything (Spec 4 §11, "stop flushes the ring").
    public func flush() {
        let h = head.load(ordering: .relaxed)
        tail.store(h, ordering: .releasing)
        ended.store(false, ordering: .relaxed)
    }

    public var framesRead: Int64 { tail.load(ordering: .relaxed) }
}
