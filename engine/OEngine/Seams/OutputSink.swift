// OEngine — Spec 4 §14, the `OutputSink` seam; Spec 4 §2, decoupled presentation.

import Foundation
import Synchronization

/// Spec 4 §14 — `OutputSink`: "Display, DeckLink" in v1; "NDI, a virtual
/// output for recording or streaming" later. Spec 4 §10 — "A sink takes a
/// completed stack texture and gets it onto hardware."
///
/// Spec 4 §2 — "The render thread renders; sinks present. Each output owns a
/// ring of three completed frames and presents the newest one on its own
/// cadence (its vsync, or its scheduled DeckLink slot)."
public protocol OutputSink: AnyObject, Sendable {
    /// Spec 1 §3 — the Output object's number.
    var output: Int { get }
    /// Spec 4 §10 — the encode this sink wants from the encode pass.
    var encode: EncodeKind { get }
    /// Spec 4 §2 — the ring the render thread publishes completed frames into.
    var ring: FrameRing { get }
    /// Spec 4 §12 — when the sink last presented or scheduled a frame, for the watchdog.
    var lastPresent: MonotonicTime { get }

    func start() throws
    func stop()
}

/// Spec 4 §4 step 4 — "when its sink pass completes, publish the frame into
/// the output's ring". One entry: which stack texture, the output
/// transition's second texture and mix, and the receipt the sink checks for
/// completion before presenting.
public struct CompletedFrame: Equatable, Sendable {
    public var tick: Int64
    public var stack: TextureHandle
    public var second: SecondTexture
    public var mix: Float
    public var destination: Int
    public var receipt: EncodeReceipt

    public init(tick: Int64, stack: TextureHandle, second: SecondTexture, mix: Float, destination: Int, receipt: EncodeReceipt) {
        self.tick = tick
        self.stack = stack
        self.second = second
        self.mix = mix
        self.destination = destination
        self.receipt = receipt
    }
}

/// Spec 4 §2 — "a ring of three completed frames". Single producer (the
/// render thread, which publishes by writing a slot and then the head index)
/// and single consumer (the sink's presenter, which reads the newest slot).
/// No lock, no allocation after construction.
public final class FrameRing: @unchecked Sendable {
    public static let depth = 3
    private let slots: UnsafeMutablePointer<CompletedFrame?>
    private let head = Atomic<Int64>(-1)
    private let published = Atomic<Int64>(0)

    public init() {
        slots = UnsafeMutablePointer<CompletedFrame?>.allocate(capacity: FrameRing.depth)
        slots.initialize(repeating: nil, count: FrameRing.depth)
    }

    deinit {
        slots.deinitialize(count: FrameRing.depth)
        slots.deallocate()
    }

    /// Render thread: write the slot for this tick, then publish it.
    public func publish(_ frame: CompletedFrame) {
        let index = Int(frame.tick % Int64(FrameRing.depth))
        slots[index] = frame
        head.store(frame.tick, ordering: .releasing)
        published.add(1, ordering: .relaxed)
    }

    /// Sink side: the newest published frame, if any.
    public var newest: CompletedFrame? {
        let tick = head.load(ordering: .acquiring)
        guard tick >= 0 else { return nil }
        return slots[Int(tick % Int64(FrameRing.depth))]
    }

    /// The frame published for `tick`, if it is still in the ring.
    public func frame(forTick tick: Int64) -> CompletedFrame? {
        guard tick >= 0 else { return nil }
        let frame = slots[Int(tick % Int64(FrameRing.depth))]
        return frame?.tick == tick ? frame : nil
    }

    public var publishedCount: Int64 { published.load(ordering: .relaxed) }
}
