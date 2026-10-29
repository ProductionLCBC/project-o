// OEngine — Spec 4 §3, the frame plan hand-off.

import Foundation
import Synchronization

/// Spec 4 §3 — "State reaches the render thread as an immutable value behind
/// an atomic pointer." "The control thread builds the frame plan for tick N+1
/// while the render thread encodes tick N, so the render thread only ever
/// reads a finished plan."
///
/// Three slots: the control thread writes the next free slot and publishes
/// its index with a release store; the render thread loads the index with an
/// acquire load and reads that slot. The control thread never writes the slot
/// the render thread last consumed, so no lock is needed and nothing is
/// allocated after construction except the plan values themselves, which the
/// control thread builds. The index is an `Int`, not a pointer, because the
/// Swift atomics are `Sendable` only for `Sendable` payloads.
public final class PlanRing: @unchecked Sendable {
    public static let depth = 3
    private let slots: UnsafeMutablePointer<FramePlan>
    private let publishedIndex = Atomic<Int>(-1)
    private let consumedIndex = Atomic<Int>(-1)
    private var nextWrite = 0

    public init() {
        slots = UnsafeMutablePointer<FramePlan>.allocate(capacity: PlanRing.depth)
        slots.initialize(repeating: .empty, count: PlanRing.depth)
    }

    deinit {
        slots.deinitialize(count: PlanRing.depth)
        slots.deallocate()
    }

    /// Control thread: store a finished plan and publish it.
    public func publish(_ plan: FramePlan) {
        var index = nextWrite
        // Skip the slot the render thread is reading.
        if index == consumedIndex.load(ordering: .acquiring) { index = (index + 1) % PlanRing.depth }
        slots[index] = plan
        publishedIndex.store(index, ordering: .releasing)
        nextWrite = (index + 1) % PlanRing.depth
    }

    /// Render thread, Spec 4 §4 step 1: "Read the newest frame plan (pointer
    /// load)". Nil when nothing new was published since the last take.
    public func take() -> FramePlan? {
        let index = publishedIndex.load(ordering: .acquiring)
        guard index >= 0, index != consumedIndex.load(ordering: .relaxed) else { return nil }
        consumedIndex.store(index, ordering: .releasing)
        return slots[index]
    }

    /// Render thread: the plan taken last, for reuse on a control stall.
    public var current: FramePlan? {
        let index = consumedIndex.load(ordering: .relaxed)
        guard index >= 0 else { return nil }
        return slots[index]
    }
}
