// OEngine — Spec 9 §4, the writes of `state/last.json`.

import Foundation
import OCore

/// Spec 9 §4 — "`machine/state/last.json` holds ShowState (Spec 3 §2) as the
/// engine last projected it, and some facts about the run that wrote it":
///
/// - "At launch the engine writes it before it does anything else with the
///   last state: with its run's uuid, `clean: false`, and `restored: true`
///   when it is about to put that state back".
/// - "After a runtime group, within a second, and at most once a second while
///   groups keep coming, so a caption feed can't hold it back."
/// - "At least once a minute while the engine runs, so `writtenAt` says when
///   the run was last alive, not when the last cue was fired."
/// - "When the engine stops on request ... writes the file at once with
///   `clean: true`."
///
/// "`restored` stays `true` for the first minute after a restore, whatever
/// runs in it, and is `false` after that ... Every write is atomic (Spec 1
/// §5) and happens whether or not `restoreLastState` is on. Edits never
/// change ShowState (Spec 5 §2), so they don't write it."
///
/// The control thread says what to write and when, on engine time; a utility
/// queue encodes and writes, so the control thread never waits for the disk.
/// The launch's write and the stop's are the two that wait: the first so a
/// state that crashes the engine finds `restored: true` already on disk, the
/// second so a clean stop is on disk before the process goes.
final class LastStateKeeper: @unchecked Sendable {
    /// "within a second, and at most once a second".
    static let changeInterval: Int64 = 1_000_000_000
    /// "At least once a minute while the engine runs".
    static let refreshInterval: Int64 = 60_000_000_000
    /// "for the first minute after a restore".
    static let restoredInterval: Int64 = 60_000_000_000

    let url: URL
    let run: UUID
    private let disk: Disk
    /// Spec 9 §7 — what every writer knows of the disk.
    private let status: DiskStatus?
    private let stamp: @Sendable () -> String
    private let queue = DispatchQueue(label: "o.engine.state", qos: .utility)
    /// Spec 9 §7 — the file was removed for a full disk, and isn't written until the full state ends.
    private var removed = false

    // The control side's own.
    private var written: (state: ShowState, clears: [Int], restored: Bool)?
    private var dirty = false
    private var lastWriteAt: MonotonicTime?
    private var restoredUntil: MonotonicTime?

    private let lock = NSLock()
    private var failed: [Disk.Failure] = []

    /// `url` is `machine/state/last.json`; `stamp` is the wall clock as a
    /// `writtenAt`, in the machine's time zone.
    init(url: URL, run: UUID, disk: Disk, status: DiskStatus? = nil, stamp: @escaping @Sendable () -> String) {
        self.url = url
        self.run = run
        self.disk = disk
        self.status = status
        self.stamp = stamp
    }

    // MARK: - The control side

    /// Spec 9 §4 — the launch's write, before anything is put back: `state`
    /// is the state about to be put back when `restoring`, else "the empty
    /// state it starts from". On disk when this returns.
    func begin(state: ShowState, restoring: Bool, now: MonotonicTime) {
        restoredUntil = restoring ? now.advanced(by: Self.restoredInterval) : nil
        write(state: state, clears: [], clean: false, restored: restoring, now: now, wait: true)
    }

    /// Spec 9 §4 — once a build: the state as the build left it, with the
    /// popup slots whose clear-after is still counting. `changed` says a
    /// runtime group or a restore ran in this build, so the state is worth
    /// comparing. Written when it differs from what the file holds and a
    /// second has passed since the last write; when a minute has; and when
    /// the minute after a restore ends.
    ///
    /// Spec 9 §7 — "A full disk ... The engine removes `state/last.json`,
    /// which frees space and needs none, so a stale last state can't come
    /// back later. It isn't written again until the full state ends", and
    /// then it is written at once.
    func keep(state: ShowState, pendingClears: [Int], changed: Bool, now: MonotonicTime) {
        guard let written, let lastWriteAt else { return }
        if changed, !dirty { dirty = state != written.state || pendingClears != written.clears }
        let restored = restoredUntil.map { now < $0 } ?? false
        if status?.full == true {
            if !removed {
                removed = true
                queue.async { [self] in try? disk.remove(url) }
            }
            return
        }
        if removed {
            removed = false
            write(state: state, clears: pendingClears, clean: false, restored: restored, now: now, wait: false)
            return
        }
        let since = now - lastWriteAt
        guard (dirty && since >= Self.changeInterval) || since >= Self.refreshInterval || restored != written.restored else { return }
        write(state: state, clears: pendingClears, clean: false, restored: restored, now: now, wait: false)
    }

    /// Spec 9 §4 — the stop on request: "writes the file at once with
    /// `clean: true`". On disk when this returns.
    ///
    /// Spec 9 §7 — on a disk still full the file stays removed: the next
    /// launch finds none, and starts empty.
    func end(state: ShowState, pendingClears: [Int], now: MonotonicTime) {
        let restored = restoredUntil.map { now < $0 } ?? false
        if status?.full == true {
            queue.sync { [self] in try? disk.remove(url) }
            return
        }
        write(state: state, clears: pendingClears, clean: true, restored: restored, now: now, wait: true)
    }

    private func write(state: ShowState, clears: [Int], clean: Bool, restored: Bool, now: MonotonicTime, wait: Bool) {
        written = (state, clears, restored)
        dirty = false
        lastWriteAt = now
        let last = LastState(writtenAt: stamp(), run: run, clean: clean, restored: restored, pendingClears: clears, state: state)
        let work = { [self] in
            do {
                try disk.replace(last.data, at: url)
            } catch {
                let failure = Disk.Failure(error)
                // Spec 9 §7 — "When a write fails for want of space": the full state starts, and the file goes.
                status?.failed(failure)
                if failure.isFull { try? disk.remove(url) }
                lock.lock()
                failed.append(failure)
                lock.unlock()
            }
        }
        if wait { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    // MARK: - Any thread

    /// The writes that failed since this was last asked, in order.
    func takeFailures() -> [Disk.Failure] {
        lock.lock()
        defer { lock.unlock() }
        let out = failed
        failed.removeAll()
        return out
    }

    /// Everything handed over so far is written.
    func waitUntilIdle() {
        queue.sync {}
    }
}
