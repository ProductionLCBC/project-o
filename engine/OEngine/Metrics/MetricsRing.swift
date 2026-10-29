// OEngine — Spec 4 §13, "Every tick writes one record into a preallocated ring".

import Foundation
import Synchronization

/// Spec 4 §3 — "Metrics are written into a preallocated ring the measurement
/// thread drains." Single producer (the render thread), single consumer (the
/// black box thread). A full ring drops the record and counts the drop; the
/// producer never waits (Spec 4 §1 guarantee 3).
public final class MetricsRing: @unchecked Sendable {
    public let capacity: Int
    private let records: UnsafeMutablePointer<TickRecord>
    private let head = Atomic<Int64>(0)   // next write
    private let tail = Atomic<Int64>(0)   // next read
    private let droppedCount = Atomic<Int64>(0)

    public init(capacity: Int) {
        self.capacity = max(2, capacity)
        records = UnsafeMutablePointer<TickRecord>.allocate(capacity: self.capacity)
        records.initialize(repeating: TickRecord(), count: self.capacity)
    }

    deinit {
        records.deinitialize(count: capacity)
        records.deallocate()
    }

    /// Render thread: store one record. False, and counted, when the ring is full.
    @discardableResult
    public func write(_ record: TickRecord) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t < Int64(capacity) else {
            droppedCount.add(1, ordering: .relaxed)
            return false
        }
        records[Int(h % Int64(capacity))] = record
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Measurement thread: hand every unread record to `body`, oldest first.
    public func drain(_ body: (TickRecord) -> Void) {
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        while t < h {
            body(records[Int(t % Int64(capacity))])
            t += 1
        }
        tail.store(t, ordering: .releasing)
    }

    public var dropped: Int64 { droppedCount.load(ordering: .relaxed) }
    public var unread: Int64 { head.load(ordering: .relaxed) - tail.load(ordering: .relaxed) }
}

/// Spec 4 §13 — the per-output ring of presentation records, written by a
/// sink's own thread and drained by the black box thread.
public final class PresentRing: @unchecked Sendable {
    public let capacity: Int
    private let records: UnsafeMutablePointer<PresentRecord>
    private let head = Atomic<Int64>(0)
    private let tail = Atomic<Int64>(0)
    private let droppedCount = Atomic<Int64>(0)

    public init(capacity: Int = 1024) {
        self.capacity = max(2, capacity)
        records = UnsafeMutablePointer<PresentRecord>.allocate(capacity: self.capacity)
        records.initialize(repeating: PresentRecord(output: 0, frame: 0, rePresented: false, latencyNs: 0, completion: nil, dropsSinceStart: 0),
                           count: self.capacity)
    }

    deinit {
        records.deinitialize(count: capacity)
        records.deallocate()
    }

    @discardableResult
    public func write(_ record: PresentRecord) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t < Int64(capacity) else {
            droppedCount.add(1, ordering: .relaxed)
            return false
        }
        records[Int(h % Int64(capacity))] = record
        head.store(h + 1, ordering: .releasing)
        return true
    }

    public func drain(_ body: (PresentRecord) -> Void) {
        var t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        while t < h {
            body(records[Int(t % Int64(capacity))])
            t += 1
        }
        tail.store(t, ordering: .releasing)
    }

    public var dropped: Int64 { droppedCount.load(ordering: .relaxed) }
}
