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

    /// Spec 7 §3 — the uuid of the item at `item`, the pointer's handle on it.
    var itemUuid: UUID? {
        guard let playlist, let item, item >= 1, item <= playlist.items.count else { return nil }
        return playlist.items[item - 1].uuid
    }

    var pointer: LivePointer {
        LivePointer(playlist: playlist?.uuid, itemUuid: itemUuid, listUuid: list.uuid, cueUuid: cue.uuid)
    }
}

extension Fold {
    // MARK: - Resolving lists and positions

    /// Spec 1 §3, Spec 7 §3 — a playlist item is a header, a linked master
    /// (by its list's uuid, or by number when it has none) or a local copy
    /// (by uuid, in the machine root).
    func list(for item: PlaylistItem) -> List? {
        CueAddressing.list(for: item.kind, library: context.library, machine: context.machine)
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
            // Spec 7 §4 — the pointer follows its item by uuid, wherever it now is.
            if let itemUuid = pointer.itemUuid, let index = p.items.firstIndex(where: { $0.uuid == itemUuid }),
               let l = self.list(for: p.items[index]), l.uuid == listUuid {
                item = index + 1
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
    /// `nesting` is the cue's commands' own (Spec 2 §5, "Macro depth").
    mutating func fire(_ position: CuePosition, nesting: Nesting) {
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
        // Spec 1 §6 — a `when` guard on a cue command is reserved: "the field
        // exists without the behaviour" (Spec 2 §7), so the command runs unguarded.
        for entry in cue.commands {
            apply(entry.command, source: source, nesting: nesting)
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
        switch nextCue.trigger.kind {
        case .time(let t): ms = t
        case .timecode: return nil
        case .go: break
        }
        if let advance = position.cue.advanceAfterMs {
            ms = ms.map { min($0, advance) } ?? advance
        }
        guard let delay = ms else { return nil }
        return ArmedTrigger(itemUuid: next.itemUuid, cueUuid: nextCue.uuid, atFrame: frame + context.rate.frames(forMs: max(0, delay)))
    }

    /// Fires a position if there is one and a level is left for it (Spec 2
    /// §5: the group's own navigation uses none, any other uses one);
    /// otherwise `noop`.
    mutating func fire(_ position: CuePosition?, command: Command, nesting: Nesting) {
        guard let position, let cueNesting = nesting.firingCue else {
            effects.append(.noop(command))
            return
        }
        fire(position, nesting: cueNesting)
    }

    // MARK: - Navigation commands

    /// Spec 2 §3 — `next`: "Fires the next or previous cue; crosses item
    /// boundaries; nothing past the end." From a loaded playlist with no cue
    /// fired yet, `next` fires its first cue.
    mutating func fireFollowing(command: Command, nesting: Nesting) {
        if let position = position(of: state.pointer) {
            fire(following(position), command: command, nesting: nesting)
        } else if let pointer = state.pointer, pointer.cueUuid == nil, let playlistUuid = pointer.playlist,
                  let playlist = context.machine.playlist(uuid: playlistUuid) {
            fire(firstPosition(in: playlist, from: 1), command: command, nesting: nesting)
        } else {
            effects.append(.noop(command))
        }
    }

    mutating func firePreceding(command: Command, nesting: Nesting) {
        fire(position(of: state.pointer).flatMap { preceding($0) }, command: command, nesting: nesting)
    }

    /// Spec 2 §3 — `cue N`: "Fires cue N of the live list."
    mutating func fireCue(_ number: Int, command: Command, nesting: Nesting) {
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
        fire(target, command: command, nesting: nesting)
    }

    /// The list at playlist item `item` of the live playlist, if any.
    func livePlaylistItem(_ item: Int) -> (Playlist, List)? {
        guard let playlistUuid = state.pointer?.playlist, let playlist = context.machine.playlist(uuid: playlistUuid),
              item >= 1, item <= playlist.items.count, let list = list(for: playlist.items[item - 1]) else { return nil }
        return (playlist, list)
    }

    /// Spec 2 §3 — `item N cue M`: "Fires that cue and makes its item live."
    mutating func fireItem(_ item: Int, cue number: Int, command: Command, nesting: Nesting) {
        guard let (playlist, list) = livePlaylistItem(item), number >= 1, number <= list.cues.count else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: playlist, item: item, list: list, cueIndex: number - 1), command: command, nesting: nesting)
    }

    /// Spec 3 §5 — "Section jumps (`item N section "chorus"`) fire the first
    /// cue whose `section` matches, case-insensitive; no match is `rejected`"
    /// at validation, and a `noop` here.
    mutating func fireSection(_ item: Int, _ section: String, command: Command, nesting: Nesting) {
        let wanted = section.lowercased()
        guard let (playlist, list) = livePlaylistItem(item),
              let index = list.cues.firstIndex(where: { $0.section?.lowercased() == wanted }) else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: playlist, item: item, list: list, cueIndex: index), command: command, nesting: nesting)
    }

    /// Spec 2 §3 — `list N cue M`: "Fires that cue in a library master; the
    /// list becomes live with lookahead confined to it."
    mutating func fireList(_ list: Int, cue number: Int, command: Command, nesting: Nesting) {
        guard let master = context.library.list(number: list), number >= 1, number <= master.cues.count else {
            effects.append(.noop(command))
            return
        }
        fire(CuePosition(playlist: nil, item: nil, list: master, cueIndex: number - 1), command: command, nesting: nesting)
    }

    /// Spec 7 §4 — "`disarm` is a new runtime command (Spec 2 §3, corrected in
    /// §9). It clears the armed trigger with a `pointer` effect whose `armed`
    /// is empty, so nothing fires on its own; with nothing armed it is a
    /// `noop`." The pointer stays where it is.
    mutating func disarm(command: Command) {
        guard state.armed != nil else {
            effects.append(.noop(command))
            return
        }
        state.armed = nil
        effects.append(.pointer(old: state.pointer, new: state.pointer, armed: nil))
    }

    /// Spec 2 §3 — `playlist "TITLE"`: "Makes a playlist live with no cue
    /// fired; the first `next` fires its first cue (Spec 7 §3–§4)." The
    /// pointer names the playlist and no cue, so the first `next` is a
    /// boundary. Spec 7 §3 — by title alone, as `Machine.playlist(titled:)`
    /// finds it.
    mutating func loadPlaylist(_ title: String, command: Command) {
        guard let playlist = context.machine.playlist(titled: title) else {
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
