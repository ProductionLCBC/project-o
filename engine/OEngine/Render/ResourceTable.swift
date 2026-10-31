// OEngine — Spec 4 §5, resources by handle.

import Foundation
import Synchronization

/// Spec 4 §5 — "Everything the render thread touches is allocated before it
/// is needed ... Never on the render thread." The table maps a handle to the
/// backend's GPU object. Handles are allocated and released on the control
/// side under a lock; the render thread resolves them with an array read.
/// A released handle is not reused until the control side says the last plan
/// that named it has been consumed (`release(_:afterTick:)` plus `sweep`).
public final class ResourceTable: @unchecked Sendable {
    public let capacity: Int
    private let objects: UnsafeMutablePointer<AnyObject?>
    private let descriptors: UnsafeMutablePointer<TextureDescriptor?>
    private let lock = NSLock()
    private var free: [Int32]
    private var deferred: [(handle: TextureHandle, afterTick: Int64)] = []
    private let allocatedCount = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        objects = UnsafeMutablePointer<AnyObject?>.allocate(capacity: self.capacity)
        objects.initialize(repeating: nil, count: self.capacity)
        descriptors = UnsafeMutablePointer<TextureDescriptor?>.allocate(capacity: self.capacity)
        descriptors.initialize(repeating: nil, count: self.capacity)
        free = (0..<Int32(self.capacity)).reversed()
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
        guard let index = free.popLast() else { return .none }
        objects[Int(index)] = object
        descriptors[Int(index)] = descriptor
        allocatedCount.add(1, ordering: .relaxed)
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

    /// Control side: release a handle once every plan that could name it has
    /// been consumed by the render thread (Spec 4 §3, frame plan lifetime).
    public func release(_ handle: TextureHandle, afterTick tick: Int64) {
        guard !handle.isNone else { return }
        lock.lock()
        deferred.append((handle, tick))
        lock.unlock()
    }

    /// Control side: free the deferred handles whose tick has passed.
    public func sweep(consumedTick: Int64) {
        lock.lock()
        defer { lock.unlock() }
        var keep: [(handle: TextureHandle, afterTick: Int64)] = []
        for entry in deferred {
            if entry.afterTick <= consumedTick {
                let index = Int(entry.handle.rawValue)
                guard index >= 0, index < capacity else { continue }
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
    public var pendingRelease: Int {
        lock.lock()
        defer { lock.unlock() }
        return deferred.count
    }
}
