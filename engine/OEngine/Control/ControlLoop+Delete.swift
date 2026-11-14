// OEngine — Spec 8 §6, `media delete` and `media undelete` through the edit gate.

import Foundation
import OCore
import OFormats

/// Spec 8 §6 — a delete or undelete waiting for its files to move. Adam's
/// answer of 2026-11-11 (7): "runtime commands run; queued edits and media
/// commands, and edits held by cues fired meanwhile, wait behind a parked
/// delete", so every edit applies in the order it arrived.
public struct MediaPark: Sendable {
    public enum Kind: Sendable {
        /// "A group that holds a `media delete` ... is validated whole; then
        /// every file it deletes moves; then the checks run again, and the
        /// group applies in one step."
        case direct(CommandGroup)
        /// "A delete held in a cue, macro, key binding or scheduler entry lets
        /// the rest of its group run at once. The delete applies after its
        /// files move, or is logged `blocked`": the held edits from it on.
        case held([HeldEdit])
    }

    public var id: Int
    public var kind: Kind
    public var moves: [MediaMove]
    public var startedAt: MonotonicTime

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
}

extension ControlLoop {
    /// Whether a group waits behind a parked delete: it holds an edit, a
    /// media command, or an edit undo or redo.
    static func waitsBehindPark(_ group: CommandGroup) -> Bool {
        group.commands.contains { entry in
            switch entry.command {
            case .edit, .media, .undo, .redo: return true
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

    /// Spec 8 §6, "In a group" — validated whole, the deletes applied without
    /// files so the commands after them see them; then the files move.
    func parkDirect(_ group: CommandGroup, frame: Int64, now: MonotonicTime) {
        guard mediaWorker != nil else {
            reject(group, Rejection(reason: .noTrash, message: "no media worker runs here, so no file can move to the Trash"))
            return
        }
        let settler = GroupSettler(timers: timers, clears: pendingClears, frame: frame, rate: pacing.masterRate, popupSlots: variables.popupSlots)
        if case .failure(let rejection) = CommandRunner.run(group, state: model.state, context: projectionContext(frame: frame, source: group.source),
                                                             editing: editingContext,
                                                             settle: { command, _, result in settler.settle(command, result: result) },
                                                             media: { [unowned self] command, source in prepareMedia(command, source: source) }) {
            reject(group, rejection)
            return
        }
        let moves = group.commands.compactMap { entry -> MediaMove? in
            guard case .media(let media) = entry.command, media.movesFiles else { return nil }
            return mediaMove(for: media)
        }
        startPark(.direct(group), moves: moves, now: now)
    }

    /// Spec 8 §6 — a held delete passed its first check: the held edits from
    /// it on wait for its files.
    func parkHeld(_ held: [HeldEdit], frame: Int64, now: MonotonicTime) {
        guard let first = held.first(where: { $0.command.movesFiles }), case .media(let media) = first.command,
              let move = mediaMove(for: media) else {
            // Nothing to move after all: they run now.
            _ = runHeldNow(held, frame: frame, now: now, moved: [:])
            return
        }
        guard mediaWorker != nil else {
            _ = runHeldNow(held, frame: frame, now: now,
                           moved: [move.id: .failure(Rejection(reason: .noTrash, message: "no media worker runs here, so no file can move to the Trash"))])
            return
        }
        startPark(.held(held), moves: [move], now: now)
    }

    /// Spec 8 §6 — the worker's urgent queue moves the files; the walk doesn't
    /// count them gone meanwhile.
    func startPark(_ kind: MediaPark.Kind, moves: [MediaMove], now: MonotonicTime) {
        let park = MediaPark(id: nextParkID, kind: kind, moves: moves, startedAt: now)
        nextParkID += 1
        mediaPark = park
        log.info("media: \(moves.map(\.id).joined(separator: ", ")) waits while \(moves.flatMap(\.locations).count) file(s) move")
        mediaWorker?.moveFiles(park: park.id, moves: moves)
    }

    /// Spec 8 §6 — the worker answered for a park.
    func parkMoved(_ id: Int, _ result: Result<[String: [MediaTrashedFile]], Rejection>, frame: Int64, now: MonotonicTime) {
        guard let park = mediaPark, park.id == id else {
            // A park given up on: its files go back.
            if let moves = abandonedParks.removeValue(forKey: id), case .success(let done) = result {
                mediaWorker?.undoMoves(done, moves: moves, park: id)
            }
            return
        }
        mediaPark = nil
        finish(park, result, frame: frame, now: now)
    }

    /// Spec 8 §6 (plan) — "Any failure, or no report within ten seconds, puts
    /// every moved file back and rejects the group with `onAir`, `noTrash` or
    /// `conflict`."
    func checkParkTimeout(frame: Int64, now: MonotonicTime) {
        guard let park = mediaPark, now - park.startedAt >= mediaParkTimeout else { return }
        mediaPark = nil
        abandonedParks[park.id] = park.moves
        log.warning("media: the files of \(park.ids.sorted().joined(separator: ", ")) didn't move within ten seconds; they go back when they do")
        finish(park, .failure(Rejection(reason: .conflict, message: "the files didn't move within ten seconds")), frame: frame, now: now)
    }

    /// "then the checks run again, and the group applies in one step. Any
    /// failure puts every moved file back".
    func finish(_ park: MediaPark, _ result: Result<[String: [MediaTrashedFile]], Rejection>, frame: Int64, now: MonotonicTime) {
        var goingBack = false
        switch park.kind {
        case .direct(let group):
            switch result {
            case .failure(let rejection):
                reject(group, rejection)
            case .success(let done):
                if !runNow(group, frame: frame, now: now, moved: done.mapValues { .success($0) }) {
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
            let applied = runHeldNow(held, frame: frame, now: now, moved: moved)
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
        releaseBehindPark(frame: frame, now: now)
    }

    /// Runs held edits now; the ids of the deletes and undeletes that applied.
    @discardableResult
    func runHeldNow(_ held: [HeldEdit], frame: Int64, now: MonotonicTime, moved: [String: Result<[MediaTrashedFile], Rejection>]) -> Set<String> {
        guard let source = held.first?.source else { return [] }
        let outcome = CommandRunner.runHeld(held, state: model.state, context: projectionContext(frame: frame, source: source), editing: editingContext,
                                            media: { [unowned self] command, source in prepareMedia(command, source: source) }, moved: moved)
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
