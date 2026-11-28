// OEngine — Spec 4 §5, resources by handle.

import Foundation
import Synchronization

/// Spec 4 §5 — "Everything the render thread touches is allocated before it
/// is needed ... Never on the render thread." The table maps a handle to the
/// backend's GPU object. Handles are allocated and released on the control
/// side under a lock; the render thread resolves them with an array read.
///
/// Spec 4 §3 — "with no new plan, reuse the previous": the render thread can
/// read one plan for as long as the control thread takes over the next. So a
/// released handle is freed by what the render thread has taken, not by how
/// many ticks it has rendered: `sweep` is told the frame of the newest plan
/// the render thread has taken, and no release frees before a plan built
/// after it has been taken (`noteBuild`), whatever tick its caller asked for.
/// The control thread, catching up, can build twice for one frame, so "built
/// after" is a later frame, never the same one. A freed handle goes to the
/// back of the line, so it is the last to be handed out again.
public final class ResourceTable: @unchecked Sendable {
    public let capacity: Int
    private let objects: UnsafeMutablePointer<AnyObject?>
    private let descriptors: UnsafeMutablePointer<TextureDescriptor?>
    private let lock = NSLock()
    /// The free handles in the order they are handed out, from `nextFree` on.
    private var free: [Int32]
    private var nextFree = 0
    private var deferred: [(handle: TextureHandle, afterTick: Int64)] = []
    private let allocatedCount = Atomic<Int>(0)
    private let allocatedByteCount = Atomic<Int64>(0)
    private let lastConsumed = Atomic<Int64>(-1)
    /// The frame the control thread is building a plan for, or last built one for.
    private let buildFrame = Atomic<Int64>(-1)

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        objects = UnsafeMutablePointer<AnyObject?>.allocate(capacity: self.capacity)
        objects.initialize(repeating: nil, count: self.capacity)
        descriptors = UnsafeMutablePointer<TextureDescriptor?>.allocate(capacity: self.capacity)
        descriptors.initialize(repeating: nil, count: self.capacity)
        free = Array(0..<Int32(self.capacity))
    }

    deinit {
        objects.deinitialize(count: capacity)
        objects.deallocate()
        descriptors.deinitialize(count: capacity)
        descriptors.deallocate()
    }

    /// Control side: hand out a handle for `object`. `.none` when the table is full.
    public func allocate(_ object: AnyObject?, descriptor: TextureDescriptor) -> TextureHandle {
        lock.lock()
        defer { lock.unlock() }
        guard nextFree < free.count else { return .none }
        let index = free[nextFree]
        nextFree += 1
        // The handed-out front of the line is dropped now and then, so the array stays the table's size.
        if nextFree >= 256 {
            free.removeFirst(nextFree)
            nextFree = 0
        }
        objects[Int(index)] = object
        descriptors[Int(index)] = descriptor
        allocatedCount.add(1, ordering: .relaxed)
        allocatedByteCount.add(descriptor.bytes, ordering: .relaxed)
        return TextureHandle(rawValue: index)
    }

    /// Render thread: the object behind a handle. An array read.
    public func object(_ handle: TextureHandle) -> AnyObject? {
        guard handle.rawValue >= 0, Int(handle.rawValue) < capacity else { return nil }
        return objects[Int(handle.rawValue)]
    }

    public func descriptor(_ handle: TextureHandle) -> TextureDescriptor? {
        guard handle.rawValue >= 0, Int(handle.rawValue) < capacity else { return nil }
        return descriptors[Int(handle.rawValue)]
    }

    /// Spec 4 §3 — the control thread is building the plan for `frame`. A
    /// plan built now may name any handle not yet released, so a release made
    /// from here on waits for a plan built for a later frame.
    public func noteBuild(frame: Int64) {
        buildFrame.store(frame, ordering: .releasing)
    }

    /// Any thread: release a handle once the render thread has taken a plan
    /// built for `tick` or later (Spec 4 §3, frame plan lifetime), and never
    /// before it has taken one built after this release.
    public func release(_ handle: TextureHandle, afterTick tick: Int64) {
        guard !handle.isNone else { return }
        let floor = buildFrame.load(ordering: .acquiring) + 1
        lock.lock()
        deferred.append((handle, max(tick, floor)))
        lock.unlock()
    }

    /// Spec 4 §3 — the frame of the newest plan the render thread had taken at the last sweep.
    public var lastConsumedTick: Int64 { lastConsumed.load(ordering: .acquiring) }

    /// Any thread: release a handle as soon as that is safe, which is the plan
    /// ring's depth of frames past the build in hand. The spike's still source
    /// released "after forever" and leaked a texture a write.
    public func release(_ handle: TextureHandle) {
        release(handle, afterTick: max(lastConsumedTick, buildFrame.load(ordering: .acquiring)) + Int64(PlanRing.depth))
    }

    /// Control side: free the deferred handles whose tick has passed.
    /// `consumedTick` is the frame of the newest plan the render thread has
    /// taken, not the count of ticks it has rendered: a plan it reuses while
    /// the control thread is behind keeps what it names.
    public func sweep(consumedTick: Int64) {
        lastConsumed.store(consumedTick, ordering: .releasing)
        lock.lock()
        defer { lock.unlock() }
        var keep: [(handle: TextureHandle, afterTick: Int64)] = []
        for entry in deferred {
            if entry.afterTick <= consumedTick {
                let index = Int(entry.handle.rawValue)
                guard index >= 0, index < capacity else { continue }
                if let descriptor = descriptors[index] { allocatedByteCount.subtract(descriptor.bytes, ordering: .relaxed) }
                objects[index] = nil
                descriptors[index] = nil
                free.append(entry.handle.rawValue)
                allocatedCount.subtract(1, ordering: .relaxed)
            } else {
                keep.append(entry)
            }
        }
        deferred = keep
    }

    public var allocated: Int { allocatedCount.load(ordering: .relaxed) }

    /// Spec 4 §13 — "the resource table's texture bytes": every live handle's
    /// texture summed by its descriptor, deferred releases included until
    /// they are swept. An atomic, so the recorder reads it without the lock.
    public var allocatedBytes: Int64 { allocatedByteCount.load(ordering: .relaxed) }
    public var pendingRelease: Int {
        lock.lock()
        defer { lock.unlock() }
        return deferred.count
    }
}
