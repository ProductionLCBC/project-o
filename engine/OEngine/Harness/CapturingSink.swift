// OEngine — Spec 4 §14, "a texture-capturing sink".

import Foundation
import Synchronization

/// Spec 4 §14 — the harness's sink: presents on the software clock's cadence
/// and keeps what it presented. With the recording backend it keeps the
/// completed-frame records; with the Metal backend the harness reads the
/// stack texture back into a `CapturedFrame` for golden comparison.
public final class CapturingSink: OutputSink, @unchecked Sendable {
    public let output: Int
    public let encode: EncodeKind = .capture
    public let ring = FrameRing()
    public let presents = PresentRing()
    private let lastPresentNs = Atomic<Int64>(0)
    private let lock = NSLock()
    private var presented: [CompletedFrame] = []
    private var rePresented: Int64 = 0
    private var lastPresentedTick: Int64 = -1
    /// Set by the harness: whether a receipt's work has completed.
    public var isComplete: @Sendable (EncodeReceipt) -> Bool = { _ in true }
    /// Set by the harness with a Metal backend: read the frame back.
    public var capture: (@Sendable (CompletedFrame) -> CapturedFrame?)?
    private var captured: CapturedFrame?

    public init(output: Int) {
        self.output = output
    }

    public var lastPresent: MonotonicTime { MonotonicTime(nanoseconds: lastPresentNs.load(ordering: .acquiring)) }

    public func start() throws {}
    public func stop() {}

    /// Spec 4 §2 — "presents the newest one on its own cadence": take the
    /// newest completed frame; re-present and count a drop when none is new.
    public func present(now: MonotonicTime) {
        lock.lock()
        defer { lock.unlock() }
        if let newest = ring.newest, isComplete(newest.receipt), newest.tick != lastPresentedTick {
            presented.append(newest)
            lastPresentedTick = newest.tick
            if let capture { captured = capture(newest) }
            presents.write(PresentRecord(output: output, frame: newest.tick, rePresented: false,
                                         latencyNs: max(0, now.nanoseconds - newest.tick), completion: .completed, dropsSinceStart: rePresented))
        } else if lastPresentedTick >= 0 {
            rePresented += 1
            presents.write(PresentRecord(output: output, frame: lastPresentedTick, rePresented: true, latencyNs: 0,
                                         completion: nil, dropsSinceStart: rePresented))
        }
        lastPresentNs.store(now.nanoseconds, ordering: .releasing)
    }

    /// Every frame presented so far, oldest first.
    public var presentedFrames: [CompletedFrame] {
        lock.lock()
        defer { lock.unlock() }
        return presented
    }

    public var rePresentCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return rePresented
    }

    /// The last frame read back, when a capture closure is set.
    public var lastCaptured: CapturedFrame? {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
}
