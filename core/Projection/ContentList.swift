// OCore — Spec 6 §3 and §5, "the list" a channel's content reads its metadata
// from, and the list fields a field box falls back to.

import Foundation

extension ShowState {
    /// Spec 6 §3 — "'The list' is the one §5 names for the content: the list
    /// whose cue wrote it, or the state's pointer for content no cue wrote."
    /// Spec 6 §5 — "In text content, a value reads the content's provenance:
    /// the cue that wrote it and the list that cue was fired from. A write by
    /// a macro that a cue ran records that cue and its list, and a restored
    /// channel keeps the cue and list it had ... Content no cue wrote, from
    /// the UI, a key, OSC, the API or the scheduler, reads the state's pointer
    /// instead."
    ///
    /// The uuid is looked up in the library's masters, then the machine's
    /// local copies, then the kept copy of the live list, which stands in for
    /// a list an edit or a sync removed (Spec 7 §4). A cue provenance written
    /// before lists were recorded reads the pointer's list, as content no cue
    /// wrote does. Nil when there is no such list, or nothing to name one.
    public func contentList(channel: Int, library: Library, machine: Machine, kept: KeptCopies = KeptCopies()) -> List? {
        guard let uuid = channels[channel]?.provenance?.list ?? pointer?.listUuid else { return nil }
        return ShowState.list(uuid: uuid, library: library, machine: machine, kept: kept)
    }

    /// Spec 6 §5 and Spec 7 §4 — a list by uuid, from the library, the local
    /// copies, or the kept copy of the live list.
    public static func list(uuid: UUID, library: Library, machine: Machine, kept: KeptCopies = KeptCopies()) -> List? {
        if let master = library.list(uuid: uuid) { return master }
        if let local = machine.localList(uuid: uuid) { return local }
        if let copy = kept.list, copy.uuid == uuid { return copy }
        return nil
    }
}

extension List {
    /// Spec 6 §3 — "If the write has no such field, a box named `title`,
    /// `author`, `copyright` or `ccli` falls back to the list's metadata of
    /// the same name (P12)."
    public static let metadataFields: [String] = ["title", "author", "copyright", "ccli"]

    /// Spec 6 §3 — the list's `title`, `author`, `copyright` or `ccli` for a
    /// field box of that name; nil for any other name.
    public func metadata(_ name: String) -> String? {
        switch name {
        case "title": return title
        case "author": return author
        case "copyright": return copyright
        case "ccli": return ccli
        default: return nil
        }
    }
}
