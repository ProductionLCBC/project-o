// OEngine — Spec 8 §6, `media delete` and `media undelete` through the edit
// gate; Spec 9 §6, the restore commands through the same gate.

import Foundation
import OCore
import OFormats

/// Spec 8 §6 — a delete or undelete waiting for its files to move. Adam's
/// answer of 2026-11-11 (7): "runtime commands run; queued edits and media
/// commands, and edits held by cues fired meanwhile, wait behind a parked
/// delete", so every edit applies in the order it arrived.
///
/// Spec 9 §6 — a restore waits the same way while its file is read: "the
/// restore is validated, the reading, checking and writing happen on a
/// worker, and then the checks run again and the restore applies in one step
/// on the control thread. Meanwhile runtime commands keep flowing, and edits,
/// undos and redos wait in the queue behind it". One thing waits at a time.
public struct MediaPark: Sendable {
    public enum Kind: Sendable {
        /// "A group that holds a `media delete` ... is validated whole; then
        /// every file it deletes moves; then the checks run again, and the
        /// group applies in one step." Spec 9 §6 — "In a group sent from the
        /// UI, the API, the command bar or OSC, the whole group waits and
        /// applies with it, or is rejected with it."
        case direct(CommandGroup)
        /// "A delete held in a cue, macro, key binding or scheduler entry lets
        /// the rest of its group run at once. The delete applies after its
        /// files move, or is logged `blocked`": the held edits from it on.
        /// Spec 9 §6 says the same of a held restore.
        case held([HeldEdit])
    }

    public var id: Int
    public var kind: Kind
    public var moves: [MediaMove]
    /// Spec 9 §6 — what the snapshot worker reads for it.
    public var reads: [RestoreKey]
    /// Whether the media worker was asked to move files, even none.
    public var movesAsked: Bool
    public var startedAt: MonotonicTime
    /// What the media worker did, once it has answered.
    var moved: Result<[String: [MediaTrashedFile]], Rejection>?
    /// What the snapshot worker read, once it has answered.
    var read: [RestoreKey: Result<RestoreMaterial, Rejection>]?

    /// Both workers have answered.
    var isResolved: Bool { moved != nil && read != nil }

    /// The items whose files are moving.
    public var ids: Set<String> { Set(moves.map(\.id)) }
    /// The log groups it holds.
    var groups: Set<GroupID> {
        switch kind {
        case .direct(let group): return [group.id]
        case .held(let held): return Set(held.map(\.group))
        }
    }
}

/// What waits behind a parked delete.
enum ParkWaiter {
    case group(CommandGroup)
    case held([HeldEdit])
}

/// Spec 8 §6 — a held delete's group's `library` event, waiting for it.
struct HeldEvent {
    var source: CommandSource
    var changed: [LibraryChange]
    var seq: Int
    var cause: LibraryEvent.Cause = .edit
}

extension ControlLoop {
    /// Whether a group waits behind a parked delete or restore: it holds an
    /// edit, a media command, an edit undo or redo, or a restore.
    static func waitsBehindPark(_ group: CommandGroup) -> Bool {
        group.commands.contains { entry in
            switch entry.command {
            case .edit, .media, .undo, .redo, .systemRestoreList, .systemRestoreSnapshot: return true
            default: return false
            }
        }
    }

    /// Spec 8 §6 — "An item on air is refused with `onAir` ...: one whose
    /// file a channel has open, for its content, an outgoing transition or a
    /// prefetched reader, or that a channel's content now resolves to. A
    /// channel keeps the file it opened at its write, so after a replace it
    /// can still be playing the old item." A write that landed while the
    /// item's files were moving counts too.
    func onAirIDs() -> Set<String> {
        var ids: Set<String> = []
        for channel in model.state.channels.values {
            if let ref = channel.content.media?.ref, let resolved = MediaResolver.resolve(ref, library: library, machine: machine) {
                ids.insert(resolved.id)
            }
        }
        for rt in model.channels.values {
            if case .media(let m) = rt.live, m.source != nil || m.parkedOpen, let id = m.entry?.id { ids.insert(id) }
            if case .content(let c)? = rt.outgoing, case .media(let m) = c, m.source != nil, let id = m.entry?.id { ids.insert(id) }
        }
        ids.formUnion(sourceFactory.prefetchedIDs)
        return ids
    }

    /// Spec 8 §6, step 2 — what a delete moves: "the item's file, and any
    /// identical copy the walk found", in either folder, an override's target
    /// included; what an undelete puts back: the files its record names.
    func mediaMove(for command: MediaCommand) -> MediaMove? {
        switch command {
        case .delete(let id, _):
            guard let (entry, tier) = MediaResolver.entry(for: id, library: library.mediaIndex, machine: machine.mediaLocal) else { return nil }
            var locations: [MediaLocation] = []
            if let own = MediaResolver.location(of: entry, tier: tier, overrides: machine.mediaLocal.overrides).location,
               (mediaFiles[own] ?? .absent) != .absent {
                locations.append(own)
            }
            for (location, state) in mediaFiles.sorted(by: { $0.key < $1.key }) where state == .holds(id) && !locations.contains(location) {
                locations.append(location)
            }
            return MediaMove(id: id, kind: .trash(locations), size: entry.size, modified: entry.modified)
        case .undelete(let id, let files):
            let entry = MediaResolver.entry(for: id, library: library.mediaIndex, machine: machine.mediaLocal)?.entry
            return MediaMove(id: id, kind: .restore(files), size: entry?.size, modified: entry?.modified)
        default:
            return nil
        }
    }

    /// What a worker that isn't there answers for each thing asked of it.
    private func unanswered(_ work: GateWork) -> (moved: Rejection?, read: Rejection?) {
        let moved = work.movesAsked && mediaWorker == nil
            ? Rejection(reason: .noTrash, message: "no media worker runs here, so no file can move to the Trash") : nil
        let read = !work.reads.isEmpty && snapshots == nil
            ? Rejection(reason: .conflict, message: "nothing is restored here: the engine has no roots on disk") : nil
        return (moved, read)
    }

    /// Spec 8 §6, "In a group" — validated whole, the deletes applied without
    /// files so the commands after them see them; then the files move. Spec
    /// 9 §6 — a restore in the group passes its first checks here, and the
    /// worker reads its file.
    func parkDirect(_ group: CommandGroup, frame: Int64, now: MonotonicTime) {
        let work = gateWork(for: group.commands.map(\.command))
        let missing = unanswered(work)
        if let rejection = missing.moved ?? missing.read {
            reject(group, rejection)
            return
        }
        let settler = GroupSettler(timers: timers, clears: pendingClears, frame: frame, rate: pacing.masterRate, popupSlots: variables.popupSlots)
        if case .failure(let rejection) = CommandRunner.run(group, state: model.state, context: projectionContext(frame: frame, source: group.source),
                                                             editing: editingContext,
                                                             settle: { command, _, result in settler.settle(command, result: result) },
                                                             media: { [unowned self] command, source in prepareMedia(command, source: source) },
                                                             history: history, restores: restoreInputs(nil),
                                                             snapshot: snapshots == nil ? .unavailable : .pending) {
            reject(group, rejection)
            return
        }
        startPark(.direct(group), work: work, frame: frame, now: now)
    }

    /// Spec 8 §6 — a held delete passed its first check: the held edits from
    /// it on wait for its files. Spec 9 §6 — a held restore, or a held undo
    /// or redo of one, waits for its read the same way.
    func parkHeld(_ held: [HeldEdit], frame: Int64, now: MonotonicTime) {
        guard let first = held.first else { return }
        let work = gateWork(for: [first.command])
        guard !work.isEmpty else {
            // Nothing to wait for after all: they run now.
            _ = runHeldNow(held, frame: frame, now: now, moved: [:], materials: [:], waited: true)
            return
        }
        let missing = unanswered(work)
        if missing.moved != nil || missing.read != nil {
            var moved: [String: Result<[MediaTrashedFile], Rejection>] = [:]
            var materials: [RestoreKey: Result<RestoreMaterial, Rejection>] = [:]
            for move in work.moves { moved[move.id] = .failure(missing.moved ?? Rejection(reason: .conflict, message: "the files didn't move")) }
            for key in work.reads { materials[key] = .failure(missing.read ?? Rejection(reason: .conflict, message: "nothing was read")) }
            _ = runHeldNow(held, frame: frame, now: now, moved: moved, materials: materials, waited: true)
            return
        }
        startPark(.held(held), work: work, frame: frame, now: now)
    }

    /// Spec 8 §6 — the worker's urgent queue moves the files; the walk doesn't
    /// count them gone meanwhile. Spec 9 §6 — the snapshot worker reads the
    /// version or the snapshot, and for a snapshot writes the one "Before it
    /// replaces anything", of the roots as they are now.
    func startPark(_ kind: MediaPark.Kind, work: GateWork, frame: Int64, now: MonotonicTime) {
        var park = MediaPark(id: nextParkID, kind: kind, moves: work.moves, reads: work.reads, movesAsked: work.movesAsked, startedAt: now)
        nextParkID += 1
        if !work.movesAsked { park.moved = .success([:]) }
        if work.reads.isEmpty { park.read = [:] }
        mediaPark = park
        if work.movesAsked {
            log.info("media: \(work.moves.map(\.id).joined(separator: ", ")) waits while \(work.moves.flatMap(\.locations).count) file(s) move")
            mediaWorker?.moveFiles(park: park.id, moves: work.moves)
        }
        if !work.reads.isEmpty {
            log.info("restore: waiting while \(work.reads.count) file(s) are read")
            let restoresSnapshot = work.reads.contains { if case .snapshot = $0 { return true } else { return false } }
            snapshots?.read(park: park.id, work.reads, before: restoresSnapshot ? snapshotRequest(.restore, token: 0) : nil)
        }
    }

    /// Spec 8 §6 — the worker answered for a park.
    func parkMoved(_ id: Int, _ result: Result<[String: [MediaTrashedFile]], Rejection>, frame: Int64, now: MonotonicTime) {
        guard var park = mediaPark, park.id == id else {
            // A park given up on: its files go back.
            if let moves = abandonedParks.removeValue(forKey: id), case .success(let done) = result {
                mediaWorker?.undoMoves(done, moves: moves, park: id)
            }
            return
        }
        park.moved = result
        mediaPark = park
        finishIfResolved(frame: frame, now: now)
    }

    /// Spec 9 §6 — the snapshot worker read what a parked restore needs.
    func parkRead(_ id: Int, _ results: [RestoreKey: Result<RestoreMaterial, Rejection>], frame: Int64, now: MonotonicTime) {
        // A park given up on: what was read for it is dropped.
        guard var park = mediaPark, park.id == id else { return }
        park.read = results
        mediaPark = park
        finishIfResolved(frame: frame, now: now)
    }

    private func finishIfResolved(frame: Int64, now: MonotonicTime) {
        guard let park = mediaPark, park.isResolved else { return }
        mediaPark = nil
        finish(park, frame: frame, now: now)
    }

    /// Spec 8 §6 (plan) — "Any failure, or no report within ten seconds, puts
    /// every moved file back and rejects the group with `onAir`, `noTrash` or
    /// `conflict`." Spec 9 §6 (plan) — a restore whose read hasn't answered
    /// in thirty seconds fails with `conflict`.
    func checkParkTimeout(frame: Int64, now: MonotonicTime) {
        guard var park = mediaPark else { return }
        let limit = park.reads.isEmpty ? mediaParkTimeout : restoreParkTimeout
        guard now - park.startedAt >= limit else { return }
        mediaPark = nil
        let late = Rejection(reason: .conflict, message: park.reads.isEmpty ? "the files didn't move within ten seconds"
                                                                             : "the restore's files weren't read within thirty seconds")
        if park.moved == nil, park.movesAsked {
            abandonedParks[park.id] = park.moves
            log.warning("media: the files of \(park.ids.sorted().joined(separator: ", ")) didn't move within ten seconds; they go back when they do")
            park.moved = .failure(late)
        }
        if park.read == nil {
            log.warning("restore: the worker didn't answer within thirty seconds")
            var failed: [RestoreKey: Result<RestoreMaterial, Rejection>] = [:]
            for key in park.reads { failed[key] = .failure(late) }
            park.read = failed
        }
        finish(park, frame: frame, now: now)
    }

    /// "then the checks run again, and the group applies in one step. Any
    /// failure puts every moved file back".
    func finish(_ park: MediaPark, frame: Int64, now: MonotonicTime) {
        let result = park.moved ?? .success([:])
        let materials = park.read ?? [:]
        // Spec 9 §6 — versions the worker found on disk count from now, so none is written over.
        for (key, material) in materials {
            if case .version(let list, _) = key, case .success(.version(_, let kept)) = material { documents?.noteKept(list: list, versions: kept) }
        }
        var goingBack = false
        switch park.kind {
        case .direct(let group):
            switch result {
            case .failure(let rejection):
                reject(group, rejection)
            case .success(let done):
                if !runNow(group, frame: frame, now: now, moved: done.mapValues { .success($0) }, materials: materials), park.movesAsked {
                    mediaWorker?.undoMoves(done, moves: park.moves, park: park.id)
                    goingBack = true
                }
            }
        case .held(let held):
            var moved: [String: Result<[MediaTrashedFile], Rejection>] = [:]
            for move in park.moves {
                switch result {
                case .failure(let rejection): moved[move.id] = .failure(rejection)
                case .success(let done): moved[move.id] = .success(done[move.id] ?? [])
                }
            }
            let applied = runHeldNow(held, frame: frame, now: now, moved: moved, materials: materials, waited: true)
            if case .success(let done) = result {
                let refused = park.moves.filter { !applied.contains($0.id) }
                if !refused.isEmpty {
                    mediaWorker?.undoMoves(done, moves: refused, park: park.id)
                    goingBack = true
                }
            }
        }
        if goingBack {
            reopenAfterUndo = park.id
        } else {
            openParked(frame: frame)
        }
        // The walk's looks were set aside meanwhile: a fresh one.
        mediaWorker?.requestWalk()
        // Spec 9 §6 (plan) — files that arrived while a restore was read are looked at now.
        if !park.reads.isEmpty { documents?.writer.requestScan() }
        releaseBehindPark(frame: frame, now: now)
    }

    /// Runs held edits now; the ids of the deletes and undeletes that applied.
    /// `waited` says the first of them has already waited for its worker: if
    /// the runner would park it again with nothing new to wait for, it is
    /// logged `blocked` instead of waiting for ever.
    @discardableResult
    func runHeldNow(_ held: [HeldEdit], frame: Int64, now: MonotonicTime, moved: [String: Result<[MediaTrashedFile], Rejection>],
                    materials: [RestoreKey: Result<RestoreMaterial, Rejection>] = [:], waited: Bool = false) -> Set<String> {
        guard let source = held.first?.source else { return [] }
        var outcome = CommandRunner.runHeld(held, state: model.state, context: projectionContext(frame: frame, source: source), editing: editingContext,
                                            media: { [unowned self] command, source in prepareMedia(command, source: source) }, moved: moved,
                                            history: history, restores: restoreInputs(materials))
        if waited, let first = held.first, outcome.parked.first == first, outcome.executed.isEmpty {
            // What it waited for changed under it (the step on top is another now, say): it doesn't wait twice.
            outcome.executed.append(ExecutedCommand(group: first.group, source: first.source, command: first.command, result: .blocked, effects: [],
                                                    fire: first.fire,
                                                    refusal: Rejection(reason: .conflict, message: "what it waited for changed while it waited")))
            let rest = Array(outcome.parked.dropFirst())
            outcome.parked = []
            absorb(outcome, client: nil, frame: frame, now: now)
            if !rest.isEmpty { runHeldNow(rest, frame: frame, now: now, moved: [:]) }
            return []
        }
        absorb(outcome, client: nil, frame: frame, now: now)
        var applied: Set<String> = []
        for line in outcome.executed where line.result == .ok {
            if case .media(let media) = line.command, media.movesFiles, let id = media.ids.first { applied.insert(id) }
        }
        return applied
    }

    /// Spec 8 §6, Adam's answer 7 — once a park resolves, what waited behind
    /// it runs, in order, until another delete parks.
    func releaseBehindPark(frame: Int64, now: MonotonicTime) {
        while mediaPark == nil, !behindPark.isEmpty {
            switch behindPark.removeFirst() {
            case .group(let group): run(group, frame: frame, now: now)
            case .held(let held): runHeldNow(held, frame: frame, now: now, moved: [:])
            }
        }
    }
}
