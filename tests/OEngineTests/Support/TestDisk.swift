import Foundation
import OCore
@testable import OEngine

/// Spec 9 §8 — "The clock, the time zone, free space and the file system's
/// failures are seams, so tests need no real disk to fill and no waiting":
/// the disk as a test sets it. Every append and replace the engine makes is
/// recorded, with every sync; `full` makes each write fail for want of space,
/// and `freeBytes` is what the volume reports.
final class TestDisk: @unchecked Sendable {
    struct Write: Equatable {
        var path: String
        var bytes: Data
        var name: String { (path as NSString).lastPathComponent }
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private let lock = NSLock()
    private var isFull = false
    private var free: Int64 = 1 << 40
    private var written: [Write] = []
    private var synced: [String] = []

    var full: Bool {
        get { lock.lock(); defer { lock.unlock() }; return isFull }
        set { lock.lock(); isFull = newValue; lock.unlock() }
    }

    var freeBytes: Int64 {
        get { lock.lock(); defer { lock.unlock() }; return free }
        set { lock.lock(); free = newValue; lock.unlock() }
    }

    /// Every write done since the last `clear`, in order.
    var writes: [Write] { lock.lock(); defer { lock.unlock() }; return written }
    /// The path of every sync since the last `clear`, in order.
    var syncs: [String] { lock.lock(); defer { lock.unlock() }; return synced }

    func writes(to name: String) -> [Write] { writes.filter { $0.name == name } }
    func syncs(of name: String) -> Int { syncs.filter { ($0 as NSString).lastPathComponent == name }.count }

    func clear() {
        lock.lock()
        written.removeAll()
        synced.removeAll()
        lock.unlock()
    }

    /// The seam the engine's writers are built with.
    var disk: Disk {
        Disk(seams: Disk.Seams(
            refuse: { [self] url in full ? .full("no space left on device: \(url.lastPathComponent)") : nil },
            freeBytes: { [self] _ in freeBytes },
            wrote: { [self] url, bytes in lock.lock(); written.append(Write(path: url.path, bytes: bytes)); lock.unlock() },
            synced: { [self] url in lock.lock(); synced.append(url.path); lock.unlock() }))
    }
}
