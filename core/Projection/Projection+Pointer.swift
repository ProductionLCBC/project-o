// OCore — Spec 3 §5, the live pointer and triggers, read from its place
// (Spec 7 §4).

import Foundation

extension Fold {
    // MARK: - Resolving lists and positions

    /// Spec 7 §4 — the place, over the roots and the kept copies the context
    /// carries (Spec 3 §6).
    var placer: Placer {
        Placer(library: context.library, machine: context.machine, kept: context.kept)
    }

    /// The position of a cue the pointer names, or nil when there is no
    /// pointer, the pointer names no cue (a loaded playlist), or its cue
    /// can't be found in its list or the list's kept copy. The runner reads
    /// the cue a navigation fired this way.
    func position(of pointer: LivePointer?) -> CuePosition? {
        guard case .placed(let place) = placer.placement(of: pointer), case .at(let index) = place.cue else { return nil }
        return CuePosition(playlist: place.playlist, item: place.itemPosition, itemUuid: place.itemUuid, list: place.list, cueIndex: index)
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
        // Spec 7 §4 — "A list boundary still compares the fired cue's list
        // with the pointer's `listUuid`, which only a fire changes".
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
        state.armed = arm(after: new, fired: position)
        effects.append(.pointer(old: old, new: new, armed: state.armed))
    }

    /// Spec 3 §5 — triggers "arm after the fire": a Time trigger on the
    /// following cue, or the fired cue's advance-after; "when both ... are
    /// set, the shorter wins". A manual fire of any cue disarms whatever was
    /// armed, which this does by replacing `armed` wholesale. A following cue
    /// with a Timecode trigger "ignores Time and advance-after aimed at it".
    /// Spec 7 §4 — the following cue is the one `next` fires from the new
    /// pointer's place, and the trigger names its item.
    func arm(after pointer: LivePointer, fired: CuePosition) -> ArmedTrigger? {
        guard let next = placer.next(from: pointer) else { return nil }
        let nextCue = next.cue
        var ms: Int?
        switch nextCue.trigger.kind {
        case .time(let t): ms = t
        case .timecode: return nil
        case .go: break
        }
        if let advance = fired.cue.advanceAfterMs {
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
    /// boundaries; nothing past the end." Spec 7 §4 — from a loaded playlist
    /// "The first cue of the first item with cues", from a fired cue "The
    /// first cue after the place"; nothing when the pointer can't be placed.
    mutating func fireFollowing(command: Command, nesting: Nesting) {
        fire(placer.next(from: state.pointer), command: command, nesting: nesting)
    }

    /// Spec 7 §4 — `previous`: "The last cue before the place"; nothing
    /// before a cue fires or when the pointer can't be placed.
    mutating func firePreceding(command: Command, nesting: Nesting) {
        guard case .placed(let place) = placer.placement(of: state.pointer) else {
            effects.append(.noop(command))
            return
        }
        fire(placer.preceding(place), command: command, nesting: nesting)
    }

    /// Spec 2 §3 — `cue N`: "Fires cue N of the live list." Spec 7 §4 — the
    /// live list as it is now, or its kept copy once it is gone; the pointer
    /// keeps its item.
    mutating func fireCue(_ number: Int, command: Command, nesting: Nesting) {
        let placement = placer.placement(of: state.pointer)
        guard let list = placement.liveList, number >= 1, number <= list.cues.count else {
            effects.append(.noop(command))
            return
        }
        var item: Int?
        if case .placed(let place) = placement { item = place.itemPosition }
        fire(CuePosition(playlist: placement.livePlaylist, item: item, itemUuid: state.pointer?.itemUuid, list: list, cueIndex: number - 1),
             command: command, nesting: nesting)
    }

    /// The list at item `item` of the live playlist, as it is now or its kept
    /// copy once it is gone (Spec 7 §4); the item's list as the library has it.
    func livePlaylistItem(_ item: Int) -> (Playlist, List)? {
        guard let playlist = placer.placement(of: state.pointer).livePlaylist, item >= 1, item <= playlist.items.count,
              let list = placer.list(for: playlist.items[item - 1]) else { return nil }
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
