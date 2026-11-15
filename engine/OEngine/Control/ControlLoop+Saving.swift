// OEngine — Spec 9 §3, §5 and §6 on the control thread: when snapshots are
// taken, what the snapshot worker reported, and the notes of the undo stacks.

import Foundation
import OCore

/// What a snapshot asked of the worker is for.
enum SnapshotWait {
    /// Spec 9 §3 — a `launch`, `playlist` or `timer` snapshot: noted when written.
    case automatic
    /// Spec 9 §3 (Adam's answer of 2026-11-14) — a group sent directly that
    /// holds `system snapshot` "waits whole": it runs once the file is complete.
    case group(CommandGroup)
    /// Held by a cue, macro, key binding or scheduler entry: "the rest runs
    /// at once", and its line is logged once the file is complete.
    case held(HeldEdit)
}

/// Spec 8 §6 and Spec 9 §6 — what a group needs done off the control thread
/// before it can apply: media files moved, a kept version or a snapshot read.
struct GateWork {
    var moves: [MediaMove] = []
    var reads: [RestoreKey] = []
    /// A command that moves files is among them, whether or not it has any to move.
    var movesAsked = false

    var isEmpty: Bool { !movesAsked && reads.isEmpty }
}

extension ControlLoop {
    // MARK: - Attaching the worker (Spec 9 §4, at launch)

    /// Spec 9 §3 — the snapshot worker, with this run's uuid for the
    /// manifests. Called once, at launch; the ten minutes count from here.
    public func attachSnapshots(_ worker: SnapshotWorker, run: UUID, now: MonotonicTime) {
        snapshots = worker
        runID = run
        nextTimerSnapshot = now.advanced(by: snapshotInterval)
        // Spec 9 §3 — "Any other value is kept as written, read as the v1 one, and reported."
        let policy = machine.settings.snapshots
        if policy.cadence != "launchAndService" {
            log.warning("snapshots.cadence \"\(policy.cadence)\" is read as launchAndService: v1 has one cadence (Spec 9 §3)")
        }
        if policy.retention != "7d-daily-weekly" {
            log.warning("snapshots.retention \"\(policy.retention)\" is read as 7d-daily-weekly: v1 has one rule (Spec 9 §7)")
        }
    }

    /// Spec 9 §6 — whether a restore is being read: edits wait behind it,
    /// and files arriving on disk are looked at once it has applied.
    var restoreIsParked: Bool {
        mediaPark.map { !$0.reads.isEmpty } ?? false
    }

    /// Spec 9 §6 — what a restore reads besides the roots: what the worker
    /// read for it, the versions kept, the lists with unwritten edits, and
    /// whether the disk is full (§7).
    func restoreInputs(_ materials: [RestoreKey: Result<RestoreMaterial, Rejection>]?) -> RestoreInputs {
        RestoreInputs(materials: materials, kept: documents?.kept ?? KeptVersions(), unwritten: documents?.unwrittenLists ?? [],
                      diskFull: diskFull)
    }

    // MARK: - Taking snapshots (Spec 9 §3)

    /// Spec 9 §3 — "The engine copies the documents on the control thread,
    /// so a snapshot is one consistent moment": the roots as they are now,
    /// which are values, with the stamp its id comes from and the last
    /// command logged.
    func snapshotRequest(_ reason: SnapshotManifest.Reason, token: Int) -> SnapshotWorker.Take {
        let date = variables.now()
        return SnapshotWorker.Take(token: token, reason: reason, stamp: variables.fileStamp(at: date), takenAt: variables.timestamp(at: date),
                                   date: date, library: library, machine: machine, run: runID, seq: commandLog.lastSeq)
    }

    /// Asks the worker for a snapshot of the roots as they are; the token
    /// its report will carry. Without a worker nothing is asked.
    @discardableResult
    func takeSnapshot(_ reason: SnapshotManifest.Reason, now: MonotonicTime) -> Int {
        let token = nextSnapshotToken
        nextSnapshotToken += 1
        guard let snapshots else { return token }
        changedSinceSnapshot = false
        if reason.isAutomatic { snapshotWaits[token] = .automatic }
        snapshots.take(snapshotRequest(reason, token: token))
        return token
    }

    /// Spec 9 §4, step 4 — "The launch snapshot (§3)", of the roots as the
    /// launch loaded them: "At launch, after the last state and before the
    /// startup macro".
    public func takeLaunchSnapshot(now: MonotonicTime) {
        takeSnapshot(.launch, now: now)
    }

    /// Spec 9 §3 — "Every ten minutes (choice G-4)": on engine time since
    /// the last one was due, and only "when something has changed" since a
    /// snapshot was last asked for.
    func timerSnapshot(now: MonotonicTime) {
        if lastRootsChanged { changedSinceSnapshot = true }
        guard snapshots != nil, let due = nextTimerSnapshot, now >= due else { return }
        nextTimerSnapshot = now.advanced(by: snapshotInterval)
        if changedSinceSnapshot { takeSnapshot(.timer, now: now) }
    }

    /// Spec 9 §3 — a group sent directly that holds `system snapshot`: it is
    /// validated now, the snapshot is taken of the roots as they are, and the
    /// group runs "once the file is complete", its result naming it. It
    /// holds no edit back meanwhile.
    func awaitSnapshot(for group: CommandGroup, frame: Int64, now: MonotonicTime) {
        let settler = GroupSettler(timers: timers, clears: pendingClears, frame: frame, rate: pacing.masterRate, popupSlots: variables.popupSlots)
        if case .failure(let rejection) = CommandRunner.run(group, state: model.state, context: projectionContext(frame: frame, source: group.source),
                                                             editing: editingContext,
                                                             settle: { command, _, result in settler.settle(command, result: result) },
                                                             media: { [unowned self] command, source in prepareMedia(command, source: source) },
                                                             history: history, restores: restoreInputs(nil), snapshot: .pending) {
            reject(group, rejection)
            return
        }
        snapshotWaits[takeSnapshot(.command, now: now)] = .group(group)
    }

    // MARK: - What the worker reported

    /// Spec 9 §3 and §6 — the snapshot worker's reports since the last
    /// build: a snapshot written (noted when automatic, and the command that
    /// asked for one run or logged), one not written, and what was read for
    /// a parked restore.
    func absorbSnapshots(frame: Int64, now: MonotonicTime) {
        guard let worker = snapshots else { return }
        for report in worker.takeReports() {
            switch report {
            case .taken(let token, let reason, let id, _):
                lastSnapshot = id
                if reason.isAutomatic {
                    // Spec 9 §2 — `snapshot`: "After an automatic snapshot (§3)", with `id` and `reason`.
                    note("snapshot", ["id": .string(id), "reason": .string(reason.rawValue)], text: "Snapshot \(id) taken (\(reason.rawValue))")
                }
                settle(snapshotWaits.removeValue(forKey: token), .taken(id), frame: frame, now: now)
            case .unchanged(let token, _, _):
                snapshotWaits.removeValue(forKey: token)
            case .paused(let token, let reason):
                snapshotWaits.removeValue(forKey: token)
                changedSinceSnapshot = true
                log.warning("the \(reason.rawValue) snapshot wasn't taken: less than 1 GB is free (Spec 9 §7)")
            case .failed(let token, let reason, let failure):
                changedSinceSnapshot = true
                log.error("the \(reason.rawValue) snapshot couldn't be written: \(failure)")
                let rejection = Rejection(reason: failure.isFull ? .diskFull : .conflict, message: "the snapshot couldn't be written: \(failure)")
                settle(snapshotWaits.removeValue(forKey: token), .failed(rejection), frame: frame, now: now)
            case .read(let park, let results):
                parkRead(park, results, frame: frame, now: now)
            }
        }
    }

    /// The command that waited for a snapshot, now that the worker answered.
    private func settle(_ wait: SnapshotWait?, _ answer: SnapshotAnswer, frame: Int64, now: MonotonicTime) {
        switch wait {
        case .group(let group)?:
            // "A direct group holding it waits whole": it runs now, or is rejected with the failure.
            // Spec 9 §6 — unless it holds an edit and a restore is being read: then it waits its turn behind that.
            if mediaPark != nil, Self.waitsBehindPark(group) {
                snapshotAnswers[group.id] = answer
                behindPark.append(.group(group))
            } else {
                runNow(group, frame: frame, now: now, moved: nil, snapshot: answer)
            }
        case .held(let held)?:
            var line = ExecutedCommand(group: held.group, source: held.source, command: held.command, result: .ok, effects: [], fire: held.fire)
            switch answer {
            case .taken(let id): line.snapshot = id
            case .failed(let rejection):
                line.result = .blocked
                line.refusal = rejection
            case .pending, .unavailable:
                return
            }
            absorb(RunOutcome(state: model.state, executed: [line], library: library, machine: machine, kept: kept, history: history),
                   client: nil, frame: frame, now: now)
        case .automatic?, nil:
            break
        }
    }

    // MARK: - The undo stacks (Spec 5 §8, Spec 9 §2)

    /// Spec 9 §2 — `stepsDropped`: "When a reload or the media walk drops
    /// undo or redo steps (§5)", with the `groups` dropped and the `cause`
    /// (`file` or `media`). One note for all of them.
    func dropSteps(_ groups: [GroupID], cause: String) {
        guard !groups.isEmpty else { return }
        note("stepsDropped", ["groups": .array(groups.map { .string($0.rawValue) }), "cause": .string(cause)],
             text: "\(groups.count) undo step(s) dropped: " + (cause == "file" ? "their documents changed on disk" : "the media they name changed on disk"))
    }

    // MARK: - What a group waits for (Spec 8 §6, Spec 9 §6)

    /// What these commands need from the workers before they can apply: a
    /// `media delete` or `undelete` its files moved, a restore its file
    /// read, and an `undo` or a `redo` whatever the step on top needs.
    func gateWork(for commands: [Command]) -> GateWork {
        var work = GateWork()
        for command in commands {
            switch command {
            case .media(let media) where media.movesFiles:
                work.movesAsked = true
                if let move = mediaMove(for: media) { work.moves.append(move) }
            case .systemRestoreList, .systemRestoreSnapshot:
                if case .success(let key) = Restores.check(command, library: library, machine: machine, inputs: restoreInputs(nil)),
                   !work.reads.contains(key) {
                    work.reads.append(key)
                }
            case .undo, .redo:
                // Spec 5 §7 — under lock neither runs, so neither waits for anything.
                guard !machine.settings.operatorLock.enabled, let step = command == .undo ? history.undoTop : history.redoTop else { continue }
                let inner = gateWork(for: (command == .undo ? step.inverses.reversed() : step.commands).filter { !$0.isHistoryOrRestore || $0.isRestore })
                work.moves += inner.moves
                work.movesAsked = work.movesAsked || inner.movesAsked
                for key in inner.reads where !work.reads.contains(key) { work.reads.append(key) }
            default:
                break
            }
        }
        return work
    }
}
