// OCore — Spec 3 §5, the live pointer and triggers.

import Foundation

/// A resolved place in the show: the list, the cue's 0-based index in it,
/// and, when reached through a playlist, the playlist and 1-based item.
struct CuePosition {
    var playlist: Playlist?
    var item: Int?
    var list: List
    var cueIndex: Int

    var cue: Cue { list.cues[cueIndex] }

    var pointer: LivePointer {
        LivePointer(playlist: playlist?.uuid, item: item, listUuid: list.uuid, cueUuid: cue.uuid)
    }
}

extension Fold {
    // MARK: - Resolving lists and positions

    /// Spec 1 §3 — a playlist item is a header, a linked master (by list
    /// number) or a local copy (by uuid, in the machine root).
    func list(for item: PlaylistItem) -> List? {
        switch item {
        case .header: return nil
        case .linked(let number): return context.library.list(number: number)
        case .local(let uuid): return context.machine.localList(uuid: uuid) ?? context.library.list(uuid: uuid)
        }
    }

    func list(uuid: UUID) -> List? {
        context.library.list(uuid: uuid) ?? context.machine.localList(uuid: uuid)
    }

    /// The position the live pointer names, or nil when there is no pointer,
    /// the pointer names no cue (a loaded playlist), or the cue is gone.
    func position(of pointer: LivePointer?) -> CuePosition? {
        guard let pointer, let listUuid = pointer.listUuid, let cueUuid = pointer.cueUuid else { return nil }
        var playlist: Playlist?
        var item: Int?
        var list: List?
        if let playlistUuid = pointer.playlist, let p = context.machine.playlist(uuid: playlistUuid) {
            playlist = p
            if let i = pointer.item, i >= 1, i <= p.items.count, let l = self.list(for: p.items[i - 1]), l.uuid == listUuid {
                item = i
                list = l
            }
        }
        if list == nil {
            guard pointer.playlist == nil, let l = self.list(uuid: listUuid) else { return nil }
            list = l
        }
        guard let resolved = list, let index = resolved.cues.firstIndex(where: { $0.uuid == cueUuid }) else { return nil }
        return CuePosition(playlist: playlist, item: item, list: resolved, cueIndex: index)
    }

    /// The first cue of the first item at or after `from` (1-based) that
    /// resolves to a list with cues, skipping headers.
    func firstPosition(in playlist: Playlist, from: Int) -> CuePosition? {
        guard from >= 1 else { return nil }
        for i in from...max(from, playlist.items.count) where i <= playlist.items.count {
            if let list = list(for: playlist.items[i - 1]), !list.cues.isEmpty {
                return CuePosition(playlist: playlist, item: i, list: list, cueIndex: 0)
            }
        }
        return nil
    }

    /// The last cue of the last item at or before `from` (1-based) that
    /// resolves to a list with cues, skipping headers.
    func lastPosition(in playlist: Playlist, upTo from: Int) -> CuePosition? {
        guard from >= 1, from <= playlist.items.count else { return nil }
        for i in stride(from: from, through: 1, by: -1) {
            if let list = list(for: playlist.items[i - 1]), !list.cues.isEmpty {
                return CuePosition(playlist: playlist, item: i, list: list, cueIndex: list.cues.count - 1)
            }
        }
        return nil
    }

    /// Spec 3 §5 — "`next` and `previous` operate on playlist positions: the
    /// cue after or before the pointer's, crossing item boundaries, skipping
    /// headers, and doing nothing past either end. With a library list live
    /// (no playlist), they stay inside that list."
    func following(_ position: CuePosition) -> CuePosition? {
        if position.cueIndex + 1 < position.list.cues.count {
            var next = position
            next.cueIndex += 1
            return next
        }
        guard let playlist = position.playlist, let item = position.item else { return nil }
        return firstPosition(in: playlist, from: item + 1)
    }

    func preceding(_ position: CuePosition) -> CuePosition? {
        if position.cueIndex > 0 {
            var previous = position
            previous.cueIndex -= 1
            return previous
        }
        guard let playlist = position.playlist, let item = position.item else { return nil }
        return lastPosition(in: playlist, upTo: item - 1)
    }

    // MARK: - Firing

    /// Spec 3 §5 — "Firing a cue means: compute the list boundary, run the
    /// cue's commands as one group with source `cue`, set the pointer, then
    /// arm the next trigger." Spec 3 §8 — the cue's commands run with
    /// `source.kind` `cue`, so lock applies to them whatever fired the cue.
    mutating func fire(_ position: CuePosition, depth: Int) {
        let list = position.list
        let cue = position.cue
        let old = state.pointer

        // Spec 3 §5 — "A boundary occurs when the fired cue's `listUuid`
        // differs from the pointer's current one, or when the pointer was
        // empty. At a boundary ... every tracked attribute on every channel
        // resets to default unless the list being entered has `trackThrough`."
        if old?.listUuid != list.uuid {
            if !list.trackThrough { resetAllAttributes() }
            effects.append(.boundary(list: list.uuid, reset: !list.trackThrough))
        }

        let source = CommandSource(kind: .cue, list: list.uuid, cue: cue.uuid, playlist: position.playlist?.uuid)
        for command in cue.commands {
            apply(command, source: source, depth: depth + 1)
        }

        let new = position.pointer
        state.pointer = new
        state.armed = arm(after: position)
        effects.append(.pointer(old: old, new: new, armed: state.armed))
    }

    /// Spec 3 §5 — triggers "arm after the fire": a Time trigger on the
    /// following cue, or the fired cue's advance-after; "when both ... are
    /// set, the shorter wins". A manual fire of any cue disarms whatever was
    /// armed, which this does by replacing `armed` wholesale. A following cue
    /// with a Timecode trigger "ignores Time and advance-after aimed at it".
    func arm(after position: CuePosition) -> ArmedTrigger? {
        guard let next = following(position) else { return nil }
        let nextCue = next.cue
        var ms: Int?
        switch nextCue.trigger {
        case .time(let t): ms = t
        case .timecode: return nil
        case .go: break
        }
        if let advance = position.cue.advanceAfterMs {
            ms = ms.map { min($0, advance) } ?? advance
        }
        guard let delay = ms else { return nil }
        return ArmedTrigger(cueUuid: nextCue.uuid, atFrame: frame + context.rate.frames(forMs: max(0, delay)))
    }

    /// Fires a position if there is one and depth allows; otherwise `noop`.
    mutating func fire(_ position: CuePosition?, command: Command, depth: Int) {
        guard let position, depth < Fold.maxDepth else {
            effects.append(.noop(command))
            return
        }
        fire(position, depth: depth)
    }

    // MARK: - Navigation commands

    /// Spec 2 §3 — `next`: "Fires the next or previous cue; crosses item
    /// boundaries; nothing past the end." From a loaded playlist with no cue
    /// fired yet, `next` fires its first cue.
    mutating func fireFollowing(command: Command, depth: Int) {
        if let position = position(of: state.pointer) {
            fire(following(position), command: command, depth: depth)
        } else if let pointer = state.pointer, pointer.cueUuid == nil, let playlistUuid = pointer.playlist,
                  let playlist = context.machine.playlist(uuid: playlistUuid) {
            fire(firstPosition(in: playlist, from: 1), command: command, depth: depth)
        } else {
            effects.append(.noop(command))
        }
    }

    mutating func firePreceding(command: Command, depth: Int) {
        fire(position(of: state.pointer).flatMap { preceding($0) }, command: command, depth: depth)
    }

    /// Spec 2 §3 — `cue N`: "Fires cue N of the live list."
    mutating func fireCue(_ number: Int, command: Command, depth: Int) {
        guard let pointer = state.pointer, let listUuid = pointer.listUuid else {
            effects.append(.noop(command))
            return
        }
        var target: CuePosition?
        if let live = position(of: pointer), number >= 1, number <= live.list.cues.count {
            target = CuePosition(playlist: live.playlist, item: live.item, list: live.list, cueIndex: number - 1)
        } else if pointer.playlist == nil, let list = list(uuid: listUuid), number >= 1, number <= list.cues.count {
            target = CuePosition(playlist: nil, item: nil, list: list, cueIndex: number - 1)
        }
        fire(target, command: command, depth: depth)
    }

    /// The list at playlist item `item` of the live playlist, if any.
    func livePlaylistItem(_ item: Int) -> (Playlist, List)? {
        guard let playlistUuid = state.pointer?.playlist, let playlist = context.machine.playlist(uuid: playlistUuid),
              item >= 1, item <= playlist.items.count, let list = list(for: playlist.items[item - 1]) else { return nil }
        return (playlist, list)
    }

    /// Spec 2 §3 — `item N cue M`: "Fires that cue and makes its item live."
    mutating func fireItem(_ item: Int, cue number: Int, command: Command, depth: Int) {
        guard let (playlist, list) = livePlaylistItem(item), number >= 1, number <= list.cues.count else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: playlist, item: item, list: list, cueIndex: number - 1), command: command, depth: depth)
    }

    /// Spec 3 §5 — "Section jumps (`item N section "chorus"`) fire the first
    /// cue whose `section` matches, case-insensitive; no match is `rejected`"
    /// at validation, and a `noop` here.
    mutating func fireSection(_ item: Int, _ section: String, command: Command, depth: Int) {
        let wanted = section.lowercased()
        guard let (playlist, list) = livePlaylistItem(item),
              let index = list.cues.firstIndex(where: { $0.section?.lowercased() == wanted }) else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: playlist, item: item, list: list, cueIndex: index), command: command, depth: depth)
    }

    /// Spec 2 §3 — `list N cue M`: "Fires that cue in a library master; the
    /// list becomes live with lookahead confined to it."
    mutating func fireList(_ list: Int, cue number: Int, command: Command, depth: Int) {
        guard let master = context.library.list(number: list), number >= 1, number <= master.cues.count else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: nil, item: nil, list: master, cueIndex: number - 1), command: command, depth: depth)
    }

    /// Spec 2 §3 — `playlist "TITLE" [DATE]`: "Makes a playlist live at its
    /// first cue without firing it." The pointer names the playlist and no
    /// cue, so the first `next` fires cue 1 as a boundary. Spec 1 §3: the
    /// pair of title and date is unique on a machine, case-insensitive.
    mutating func loadPlaylist(_ title: String, date: String?, command: Command) {
        let wanted = title.lowercased()
        guard let playlist = context.machine.playlists.first(where: {
            $0.title.lowercased() == wanted && (date == nil || $0.serviceDate == date)
        }) else {
            effects.append(.noop(command))
            return
        }
        let old = state.pointer
        let new = LivePointer(playlist: playlist.uuid)
        guard old != new || state.armed != nil else {
            effects.append(.noop(command))
            return
        }
        state.pointer = new
        state.armed = nil
        effects.append(.pointer(old: old, new: new, armed: nil))
    }
}
