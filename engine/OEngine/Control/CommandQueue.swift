// OEngine — Spec 4 §3, "the command queue" the control thread owns.

import Foundation
import OCore

/// Spec 2 §8 — "Commands take effect on the next engine frame boundary after
/// they are accepted, so a group of writes lands on the same frame." Groups
/// arrive from the OSC thread and the API; the control thread drains them
/// when it builds the next plan. A lock is fine here: nothing on the render
/// path touches it.
public final class CommandQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var groups: [CommandGroup] = []

    public init() {}

    public func enqueue(_ group: CommandGroup) {
        lock.lock()
        groups.append(group)
        lock.unlock()
    }

    /// Everything queued, in arrival order, leaving the queue empty.
    public func drain() -> [CommandGroup] {
        lock.lock()
        defer { lock.unlock() }
        let out = groups
        groups.removeAll(keepingCapacity: true)
        return out
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return groups.count
    }
}
