// OEngine — Spec 9 §7, what the engine's writers know of the disk together.

import Foundation
import Synchronization

/// Spec 9 §7 — "A low disk. When free space on the machine root's volume
/// falls under 1 GB (Spec 8 §3's line), automatic snapshots and the black
/// box's tick and present lines pause, and the `saving` topic warns" and "A
/// full disk (Spec 4 §12). When a write fails for want of space" the state
/// file goes, the logs go to memory, the black box and snapshots stop, and
/// "Every 30 seconds the engine tries the waiting writes again. When one
/// succeeds, the full state ends".
///
/// One value shared by every writer of a launched engine: the documents, the
/// logs, `state/last.json`, snapshots and the black box. Any of them says a
/// write failed for want of space; a waiting write that then succeeds says
/// the full state has ended; the log thread measures free space once a
/// second. Reading it is two atomic loads, so the control thread and the
/// black box's thread read it freely; nothing here touches the disk but
/// `measure`, which the log thread calls.
public final class DiskStatus: Sendable {
    /// Spec 9 §7 — "under 1 GB (Spec 8 §3's line)".
    public static let lowBytes: Int64 = 1 << 30
    /// Spec 9 §7 — "Every 30 seconds the engine tries the waiting writes again."
    public static let retryInterval: Int64 = 30_000_000_000

    private let disk: Disk
    private let root: URL
    private let isFull = Atomic<Bool>(false)
    private let isLow = Atomic<Bool>(false)

    /// `root` is the machine root, whose volume is the one measured.
    public init(disk: Disk, root: URL) {
        self.disk = disk
        self.root = root
    }

    /// Spec 9 §7 — a write failed for want of space, and no waiting write has succeeded since.
    public var full: Bool { isFull.load(ordering: .relaxed) }
    /// Spec 9 §7 — less than 1 GB is free on the machine root's volume.
    public var low: Bool { isLow.load(ordering: .relaxed) }

    /// Spec 9 §7 — the `saving` topic's `disk`: "`ok`, `low` or `full`".
    public var word: String { full ? "full" : (low ? "low" : "ok") }

    /// A write failed: "for want of space" starts the full state; any other
    /// failure keeps its writer's ordinary retry.
    public func failed(_ failure: Disk.Failure) {
        if failure.isFull { isFull.store(true, ordering: .relaxed) }
    }

    /// A write that waited on the full disk succeeded: "the full state ends".
    public func wrote() {
        isFull.store(false, ordering: .relaxed)
    }

    /// Free space on the machine root's volume, read now. On a utility thread.
    public func measure() {
        guard let free = disk.freeBytes(at: root) else { return }
        isLow.store(free < Self.lowBytes, ordering: .relaxed)
    }
}
