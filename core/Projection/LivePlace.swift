// OCore — Spec 7 §4, the live pointer's place and the kept copies.

import Foundation

/// Spec 7 §4 — "The engine keeps that promise with kept copies of the live
/// list and the live playlist. Whenever the pointer moves, and after every
/// applied edit group, reload or library restore, the engine copies from the
/// library the list and the playlist the pointer names, but only a version
/// that still holds what the pointer names: the list its cue, the playlist
/// its item. Otherwise it keeps the copy it has, so each copy is the last
/// version that held the pointer's cue or item." Engine memory, never
/// ShowState: "`state/last.json` doesn't carry them". Spec 3 §6 — the engine
/// passes them to the projection and the validator alongside the library.
public struct KeptCopies: Equatable, Sendable {
    public var list: List?
    public var playlist: Playlist?

    public init(list: List? = nil, playlist: Playlist? = nil) {
        self.list = list
        self.playlist = playlist
    }

    /// Spec 7 §4 — the copies for `pointer` from these roots: a version that
    /// still holds what the pointer names replaces the copy; otherwise the
    /// copy of the same list or playlist stays. A copy of anything the
    /// pointer no longer names goes.
    public func refreshed(for pointer: LivePointer?, library: Library, machine: Machine) -> KeptCopies {
        guard let pointer else { return KeptCopies() }
        var out = self
        if let listUuid = pointer.listUuid, let cueUuid = pointer.cueUuid {
            if let now = library.list(uuid: listUuid) ?? machine.localList(uuid: listUuid), now.cues.contains(where: { $0.uuid == cueUuid }) {
                out.list = now
            } else if out.list?.uuid != listUuid {
                out.list = nil
            }
        } else {
            out.list = nil
        }
        if let playlistUuid = pointer.playlist {
            let holds = { (playlist: Playlist) in pointer.itemUuid.map { item in playlist.items.contains { $0.uuid == item } } ?? true }
            if let now = machine.playlist(uuid: playlistUuid), holds(now) {
                out.playlist = now
            } else if out.playlist?.uuid != playlistUuid {
                out.playlist = nil
            }
        } else {
            out.playlist = nil
        }
        return out
    }
}

/// Spec 7 §6 — `gone` "lists what has been removed, of `cue`, `item`,
/// `list` and `playlist`".
public struct GoneParts: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let cue = GoneParts(rawValue: 1)
    public static let item = GoneParts(rawValue: 2)
    public static let list = GoneParts(rawValue: 4)
    public static let playlist = GoneParts(rawValue: 8)

    /// The names, in the spec's order.
    public var names: [String] {
        var out: [String] = []
        if contains(.cue) { out.append("cue") }
        if contains(.item) { out.append("item") }
        if contains(.list) { out.append("list") }
        if contains(.playlist) { out.append("playlist") }
        return out
    }
}

/// Spec 7 §4 — "Its place is where its cue is now: its item in the playlist
/// and its position in its list". When what the pointer names is gone, the
/// place is where it stood, worked out from the kept copies:
///
/// | Gone | Where the place is |
/// | --- | --- |
/// | The cue | Just after the nearest cue before it, in the kept copy of its list, that the list still has; at the top of the list if there is none |
/// | The item | The song finishes first ... the item's place in the playlist is just after the nearest item before it, in the kept copy, that the playlist still has, or at the top of the playlist |
/// | The list | Its kept copy stands in for it |
/// | The playlist | Its kept copy stands in for it until the pointer leaves it |
struct LivePlace: Equatable {
    /// An item in the playlist: at a 1-based position, or gone, just after
    /// the position given (0: the top of the playlist).
    enum ItemSpot: Equatable {
        case at(Int)
        case after(Int)
    }

    /// A cue in the list: at a 0-based index, or gone, just after the index
    /// given (-1: the top of the list).
    enum CueSpot: Equatable {
        case at(Int)
        case after(Int)
    }

    /// The live playlist as it is now, or its kept copy once it is gone.
    var playlist: Playlist?
    var item: ItemSpot?
    /// The pointer's handle on its item, gone or not.
    var itemUuid: UUID?
    /// The live list as it is now, or its kept copy once it is gone.
    var list: List
    var cue: CueSpot
    var gone: GoneParts

    /// The item's position now, or nil when it is gone or there's no playlist.
    var itemPosition: Int? {
        if case .at(let position)? = item { return position }
        return nil
    }
}

/// What the pointer reads as now (Spec 7 §4, "What reads the pointer").
enum Placement: Equatable {
    /// Nothing loaded.
    case nothing
    /// A playlist loaded, no cue fired: the playlist now, or its kept copy;
    /// nil when it is gone and nothing holds it.
    case loaded(Playlist?)
    case placed(LivePlace)
    /// "When the copies were taken after what the pointer names had already
    /// gone, at a launch or a state restore ... the engine can't tell where
    /// the pointer stood": the live list and playlist where they can still be
    /// found, for `cue N` and `item N`.
    case unplaceable(list: List?, playlist: Playlist?)

    /// The live list, for `cue N` (Spec 2 §3, "Fires cue N of the live list").
    var liveList: List? {
        switch self {
        case .placed(let place): return place.list
        case .unplaceable(let list, _): return list
        case .nothing, .loaded: return nil
        }
    }

    /// The live playlist, for `item N` (Spec 2 §3).
    var livePlaylist: Playlist? {
        switch self {
        case .loaded(let playlist): return playlist
        case .placed(let place): return place.playlist
        case .unplaceable(_, let playlist): return playlist
        case .nothing: return nil
        }
    }
}

/// A resolved place to fire: the list, the cue's 0-based index in it, and,
/// when reached through a playlist, the playlist, the item's 1-based position
/// now (nil when the item is gone) and the pointer's handle on the item.
struct CuePosition {
    var playlist: Playlist?
    var item: Int?
    var itemUuid: UUID?
    var list: List
    var cueIndex: Int

    var cue: Cue { list.cues[cueIndex] }

    var pointer: LivePointer {
        LivePointer(playlist: playlist?.uuid, itemUuid: itemUuid, listUuid: list.uuid, cueUuid: cue.uuid)
    }

    /// A position at item `item` (1-based) of `playlist`, or of a library list.
    init(playlist: Playlist?, item: Int?, list: List, cueIndex: Int) {
        self.playlist = playlist
        self.item = item
        if let playlist, let item, item >= 1, item <= playlist.items.count {
            itemUuid = playlist.items[item - 1].uuid
        }
        self.list = list
        self.cueIndex = cueIndex
    }

    init(playlist: Playlist?, item: Int?, itemUuid: UUID?, list: List, cueIndex: Int) {
        self.playlist = playlist
        self.item = item
        self.itemUuid = itemUuid
        self.list = list
        self.cueIndex = cueIndex
    }
}

/// Spec 7 §4 — the place of the pointer over the roots and the kept copies,
/// and the cues `next` and `previous` fire from it: "`next` fires the first
/// cue after the place and `previous` the last cue before it. Both cross
/// items and skip headers and items with no cues, as Spec 3 §5 says. Through
/// a gone item, `next` runs to the end of the song's list and then goes on
/// from the item's place."
struct Placer {
    let library: Library
    let machine: Machine
    let kept: KeptCopies

    /// Spec 1 §3, Spec 7 §3 — the list an item names, as the library has it
    /// now: "the item that linked it shows as missing" once it is deleted.
    func list(for item: PlaylistItem) -> List? {
        CueAddressing.list(for: item.kind, library: library, machine: machine)
    }

    func list(uuid: UUID) -> List? {
        library.list(uuid: uuid) ?? machine.localList(uuid: uuid)
    }

    func placement(of pointer: LivePointer?) -> Placement {
        guard let pointer else { return .nothing }
        var gone: GoneParts = []
        var playlist: Playlist?
        if let uuid = pointer.playlist {
            if let now = machine.playlist(uuid: uuid) {
                playlist = now
            } else if let copy = kept.playlist, copy.uuid == uuid {
                playlist = copy
                gone.insert(.playlist)
            }
        }
        guard let listUuid = pointer.listUuid, let cueUuid = pointer.cueUuid else {
            return pointer.playlist == nil ? .nothing : .loaded(playlist)
        }
        let list: List
        if let now = self.list(uuid: listUuid) {
            list = now
        } else if let copy = kept.list, copy.uuid == listUuid {
            list = copy
            gone.insert(.list)
        } else {
            return .unplaceable(list: nil, playlist: playlist)
        }
        if pointer.playlist != nil, playlist == nil { return .unplaceable(list: list, playlist: nil) }

        let cue: LivePlace.CueSpot
        if let index = list.cues.firstIndex(where: { $0.uuid == cueUuid }) {
            cue = .at(index)
        } else {
            guard let copy = kept.list, copy.uuid == listUuid, let held = copy.cues.firstIndex(where: { $0.uuid == cueUuid }) else {
                return .unplaceable(list: list, playlist: playlist)
            }
            var spot = LivePlace.CueSpot.after(-1)
            for earlier in stride(from: held - 1, through: 0, by: -1) {
                if let index = list.cues.firstIndex(where: { $0.uuid == copy.cues[earlier].uuid }) {
                    spot = .after(index)
                    break
                }
            }
            cue = spot
            gone.insert(.cue)
        }

        var item: LivePlace.ItemSpot?
        if let playlist {
            guard let itemUuid = pointer.itemUuid else { return .unplaceable(list: list, playlist: playlist) }
            if let index = playlist.items.firstIndex(where: { $0.uuid == itemUuid }) {
                item = .at(index + 1)
            } else {
                guard let copy = kept.playlist, copy.uuid == playlist.uuid,
                      let held = copy.items.firstIndex(where: { $0.uuid == itemUuid }) else {
                    return .unplaceable(list: list, playlist: playlist)
                }
                var spot = LivePlace.ItemSpot.after(0)
                for earlier in stride(from: held - 1, through: 0, by: -1) {
                    if let index = playlist.items.firstIndex(where: { $0.uuid == copy.items[earlier].uuid }) {
                        spot = .after(index + 1)
                        break
                    }
                }
                item = spot
                gone.insert(.item)
            }
        }
        return .placed(LivePlace(playlist: playlist, item: item, itemUuid: pointer.itemUuid, list: list, cue: cue, gone: gone))
    }

    /// The first cue of the first item at or after `from` (1-based) whose list
    /// has cues, skipping headers and missing lists.
    func firstPosition(in playlist: Playlist, from: Int) -> CuePosition? {
        guard from >= 1, from <= playlist.items.count else { return nil }
        for i in from...playlist.items.count {
            if let list = list(for: playlist.items[i - 1]), !list.cues.isEmpty {
                return CuePosition(playlist: playlist, item: i, list: list, cueIndex: 0)
            }
        }
        return nil
    }

    /// The last cue of the last item at or before `from` (1-based) whose list
    /// has cues, skipping headers and missing lists.
    func lastPosition(in playlist: Playlist, upTo from: Int) -> CuePosition? {
        guard from >= 1, from <= playlist.items.count else { return nil }
        for i in stride(from: from, through: 1, by: -1) {
            if let list = list(for: playlist.items[i - 1]), !list.cues.isEmpty {
                return CuePosition(playlist: playlist, item: i, list: list, cueIndex: list.cues.count - 1)
            }
        }
        return nil
    }

    /// "`next` fires the first cue after the place"; "Through a gone item,
    /// `next` runs to the end of the song's list and then goes on from the
    /// item's place."
    func following(_ place: LivePlace) -> CuePosition? {
        let start: Int
        switch place.cue {
        case .at(let index): start = index + 1
        case .after(let index): start = index + 1
        }
        if start < place.list.cues.count {
            return CuePosition(playlist: place.playlist, item: place.itemPosition, itemUuid: place.itemUuid, list: place.list, cueIndex: start)
        }
        guard let playlist = place.playlist, let item = place.item else { return nil }
        switch item {
        case .at(let position): return firstPosition(in: playlist, from: position + 1)
        case .after(let position): return firstPosition(in: playlist, from: position + 1)
        }
    }

    /// "`previous` [fires] the last cue before it".
    func preceding(_ place: LivePlace) -> CuePosition? {
        let last: Int
        switch place.cue {
        case .at(let index): last = index - 1
        case .after(let index): last = index
        }
        if last >= 0 {
            return CuePosition(playlist: place.playlist, item: place.itemPosition, itemUuid: place.itemUuid, list: place.list, cueIndex: last)
        }
        guard let playlist = place.playlist, let item = place.item else { return nil }
        switch item {
        case .at(let position): return lastPosition(in: playlist, upTo: position - 1)
        case .after(let position): return lastPosition(in: playlist, upTo: position)
        }
    }

    /// Spec 7 §4 — what `next` fires from the pointer: from a loaded playlist
    /// "The first cue of the first item with cues", from a fired cue "The
    /// first cue after the place"; nothing when nothing is loaded or the
    /// pointer can't be placed.
    func next(from pointer: LivePointer?) -> CuePosition? {
        switch placement(of: pointer) {
        case .loaded(let playlist?): return firstPosition(in: playlist, from: 1)
        case .placed(let place): return following(place)
        case .nothing, .loaded(nil), .unplaceable: return nil
        }
    }

    /// Spec 6 §5 — `[Next Title]`: "The title of the next list in the live
    /// playlist. It skips headers and items whose list is missing or has no
    /// cues, as `next` does, and is empty after the last list or with no
    /// playlist"; Spec 7 §4 — from a loaded playlist "The first list's
    /// title", from a fired cue "The next list after the item's place".
    func nextTitle(from pointer: LivePointer?) -> String? {
        switch placement(of: pointer) {
        case .loaded(let playlist?):
            return firstPosition(in: playlist, from: 1)?.list.title
        case .placed(let place):
            guard let playlist = place.playlist, let item = place.item else { return nil }
            switch item {
            case .at(let position), .after(let position): return firstPosition(in: playlist, from: position + 1)?.list.title
            }
        case .nothing, .loaded(nil), .unplaceable:
            return nil
        }
    }

    /// Spec 7 §4 — "The trigger is live while its cue is still the one
    /// `next` would fire."
    func isLive(_ armed: ArmedTrigger, pointer: LivePointer?) -> Bool {
        guard let next = next(from: pointer) else { return false }
        return next.cue.uuid == armed.cueUuid && next.itemUuid == armed.itemUuid
    }
}

extension ShowState {
    /// Spec 7 §4 — the armed trigger while it is live: "The trigger is live
    /// while its cue is still the one `next` would fire." An edit that puts
    /// a cue between the live one and the armed one lapses it; one that makes
    /// it next again brings it back. Every reader of `armed` asks this.
    public func liveArmed(library: Library, machine: Machine, kept: KeptCopies) -> ArmedTrigger? {
        guard let armed else { return nil }
        return Placer(library: library, machine: machine, kept: kept).isLive(armed, pointer: pointer) ? armed : nil
    }
}
