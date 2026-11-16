// OEngine — Spec 10 §2, the render thread's word that a preview or a picture was drawn.

import Foundation
import Synchronization

/// Spec 10 §2 — "After each preview frame completes, a message names the
/// stack and the surface that holds the newest frame". One aux pass the
/// render thread encoded: which surface of which stack or channel it wrote,
/// and the receipt of the GPU work that writes it. The Mach channel's sender
/// waits for that work to finish before it names the surface, so the app
/// "reads only finished frames".
public struct AuxNotice: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case preview
        case picture
    }

    public var kind: Kind
    /// The stack's number for a preview, the channel's for a picture.
    public var number: Int32
    /// Which of the three surfaces holds the frame.
    public var slot: Int32
    public var receipt: EncodeReceipt

    public init(kind: Kind, number: Int32, slot: Int32, receipt: EncodeReceipt) {
        self.kind = kind
        self.number = number
        self.slot = slot
        self.receipt = receipt
    }
}

/// Spec 4 §3 — "Hand-offs are lock-free": the notices from the render thread
/// to the Mach channel's sender. Single producer (the render thread), single
/// consumer (the sender). Preallocated; a full ring drops the notice and
/// counts it, so the producer never waits and never allocates. A dropped
/// notice costs the app one frame of a preview: the next one names a newer.
public final class AuxNoticeRing: @unchecked Sendable {
    public let capacity: Int
    private let notices: UnsafeMutablePointer<AuxNotice>
    private let head = Atomic<Int64>(0)   // next write
    private let tail = Atomic<Int64>(0)   // next read
    private let droppedCount = Atomic<Int64>(0)

    public init(capacity: Int = 1024) {
        self.capacity = max(2, capacity)
        notices = UnsafeMutablePointer<AuxNotice>.allocate(capacity: self.capacity)
        notices.initialize(repeating: AuxNotice(kind: .preview, number: 0, slot: 0, receipt: EncodeReceipt(tick: 0, token: 0)), count: self.capacity)
    }

    deinit {
        notices.deinitialize(count: capacity)
        notices.deallocate()
    }

    /// Render thread: store one notice. False, and counted, when the ring is full.
    @discardableResult
    public func write(_ notice: AuxNotice) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t < Int64(capacity) else {
            droppedCount.add(1, ordering: .relaxed)
            return false
        }
        notices[Int(h % Int64(capacity))] = notice
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// The sender: hand every unread notice to `body`, oldest first.
    public func drain(_ body: (AuxNotice) -> Void) {
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        while t < h {
            body(notices[Int(t % Int64(capacity))])
            t += 1
        }
        tail.store(t, ordering: .releasing)
    }

    public var dropped: Int64 { droppedCount.load(ordering: .relaxed) }
    public var unread: Int64 { head.load(ordering: .relaxed) - tail.load(ordering: .relaxed) }
}
