// OApp — Spec 10 §5, §6 and §10, when an edit may be made, and what each menu offers.

import Foundation
import OCore

/// Spec 10 §10 — why an edit can't be made now: "All of them are refused
/// under the lock (§12), and edits to masters on a `readOnlyMasters` machine
/// (Spec 5 §7); the app disables them in both cases with the reason. A local
/// copy isn't editable in v1 (Spec 5 §3)."
public enum CannotEdit: Equatable, Sendable {
    /// The engine is away or silent, the lock is on, or masters are read-only here.
    case unavailable(Unavailable)
    /// Spec 7 §5 — "An archived playlist takes only the edit that unarchives it and `delete`".
    case archived
    /// "A local copy isn't editable in v1".
    case localCopy
    /// Spec 10 §6 (Adam's answer to the Area 13 plan) — a list whose number
    /// another shares has its edits disabled too, with "Renumber to edit".
    case renumberToEdit
    /// "Archive (`… archived true`, disabled while it is live)".
    case liveNow
    /// Make Live on the playlist that is live and has fired a cue: the
    /// engine would put the pointer back before cue 1 (Area 13 reading).
    case alreadyLive
    /// "Delete Folder is enabled only for an empty folder".
    case folderNotEmpty
    /// The media item's file is missing, or the item was deleted; or the list is gone.
    case missing
    /// The list was removed from the playlist and is finishing (Spec 7 §4).
    case removed
    /// A fire the title or the number doesn't name (Spec 10 §6).
    case fire(FireRefusal)
    /// Spec 10 §6 — "several files, or a folder, are refused there, and the cell says to drop them on the pool."
    case dropOnThePool
    /// Another area builds it (Spec 10 §16).
    case later
}

/// Spec 10 §10, "Undo and redo" — "Their names come from the `history`
/// topic's top groups, made plain from the first command's verb: Undo
/// Rename, Undo Typing, Undo Add, Undo Remove, Undo Move, Undo Duplicate,
/// Undo Delete Media, Undo Restore, or Undo Change".
public enum HistoryKind: Equatable, Sendable, CaseIterable {
    case rename, typing, add, remove, move, duplicate, deleteMedia, restore, change

    public static func of(_ command: Command) -> HistoryKind {
        switch command {
        case .edit(let edit):
            switch edit.action {
            case .set(let path, _):
                // A title or a label is a name; any other field is a change.
                let field = path.split(separator: ".").last.map { String($0) } ?? path
                return field == "title" || field == "label" ? .rename : .change
            case .rename: return .rename
            case .create, .insert: return .add
            case .delete, .remove, .section(.remove): return .remove
            case .move, .folder, .section(.move): return .move
            case .duplicate, .archive, .section(.duplicate): return .duplicate
            case .cueChannel(let channel):
                if case .write(.text, _) = channel.state { return .typing }
                return .change
            case .unset, .renumber, .swap: return .change
            }
        case .media(.delete): return .deleteMedia
        case .systemRestoreList, .systemRestoreSnapshot: return .restore
        default: return .change
        }
    }

    /// From a step's text, "the group's first command in its canonical form" (Spec 9 §5); a text that doesn't read is a change.
    public static func of(text: String) -> HistoryKind {
        guard case .success(let parsed) = CommandText.parse(text) else { return .change }
        return of(parsed.command)
    }
}

/// What an undo or a redo acted on, for "the window says for three seconds what changed".
public enum EditedObject: Equatable, Sendable {
    case playlist(String)
    case item(playlist: String)
    case list(String)
    case cue(list: String)
    case folder(String)
    case media(String)
    /// A snapshot's restore, or something the app can't name.
    case library

    /// Reads the object a step's first command names, with the titles the catalog holds.
    public static func of(text: String, catalog: Catalog?, media: [MediaItem]) -> EditedObject {
        guard case .success(let parsed) = CommandText.parse(text) else { return .library }
        func listTitle(_ number: Int?) -> String {
            catalog?.lists.first { $0.number == number && !$0.local && $0.named }?.title ?? number.map { String($0) } ?? ""
        }
        func playlistTitle(_ uuid: UUID?) -> String {
            uuid.flatMap { catalog?.playlist(uuid: $0.uuidString.lowercased())?.playlist.title } ?? ""
        }
        switch parsed.command {
        case .edit(let edit):
            switch edit.address {
            // An insert, a removal or a move by position is of a child: an item of the playlist, a cue of the list.
            case .playlist(let uuid): return edit.action.isOfAChild ? .item(playlist: playlistTitle(uuid)) : .playlist(edit.action.createdTitle ?? playlistTitle(uuid))
            case .item(let playlist, _): return .item(playlist: playlistTitle(playlist))
            case .list(let number): return edit.action.isOfAChild ? .cue(list: listTitle(number)) : .list(listTitle(number))
            case .cue(let list, _): return .cue(list: listTitle(list))
            case .folder(let path): return .folder(path)
            case .media(let id): return .media(media.first { $0.id == id }.map { ($0.entry.path as NSString).lastPathComponent } ?? id)
            default: return .library
            }
        case .media(.delete(let id, _)):
            return .media(media.first { $0.id == id }.map { ($0.entry.path as NSString).lastPathComponent } ?? id)
        case .systemRestoreList(let list, _): return .list(listTitle(list))
        default: return .library
        }
    }
}

private extension EditAction {
    /// The title a create names, since the playlist isn't in the catalog under a uuid yet.
    var createdTitle: String? {
        if case .create(_, _, let title) = self { return title }
        return nil
    }

    /// Whether the action names a child by its array's path: `insert items 3 {…}`, `remove cues 2`.
    var isOfAChild: Bool {
        switch self {
        case .insert: return true
        case .remove(let path, _): return path != nil
        case .move(let path, _, _): return path != nil
        default: return false
        }
    }
}

/// One entry of a menu, as a value: what it is, whether it can be chosen
/// now and why not, so the menus are tested without a window and the views
/// only draw them (Spec 10 §1: "An action the app can't take now ... shows
/// disabled with the reason").
public struct MenuEntry: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case separator
        // A playlist (§5)
        case makeLive, renamePlaylist, dateAndTime, duplicatePlaylist, archiveCopy, archive, restoreFromArchive, deletePlaylist
        // An item (§5)
        case removeItem, addHeaderAbove, renameHeader, showInLibrary
        // A list in the library (§5)
        case addToPlaylistMenu, addToPlaylist(String), renameList, duplicateList, openInTextEditor, restoreVersion, deleteList, newListHere
        // A folder (§5)
        case renameFolder, newFolder, deleteFolder
        // A cue (§6)
        case fire, editText, editCue, note, triggerMenu, triggerGo, triggerTime, advanceAfter, duplicateSection, hold
        // A list header (§6)
        case gradeMenu(channel: Int), grade(channel: Int, grade: Int?)
        // A pool tile (§6)
        case fireTo(channel: Int), fireToMenu, defaults, replace, reveal, deleteMedia
    }

    public var kind: Kind
    public var isEnabled: Bool
    public var reason: CannotEdit?
    /// A tick beside it: the cue's trigger, the list's tracked grade.
    public var isOn: Bool
    /// What a menu names of the library: a playlist's title, a channel, a grade.
    public var name: String
    public var children: [MenuEntry]

    public init(_ kind: Kind, reason: CannotEdit? = nil, isOn: Bool = false, name: String = "", children: [MenuEntry] = []) {
        self.kind = kind
        self.isEnabled = reason == nil
        self.reason = reason
        self.isOn = isOn
        self.name = name
        self.children = children
    }

    public static let separator = MenuEntry(.separator)
}

/// Spec 10 §5 and §6 — the menus. "The menus show only what the engine would accept".
public enum Menus {
    private static func reason(_ unavailable: Unavailable?) -> CannotEdit? {
        unavailable.map(CannotEdit.unavailable)
    }

    /// "A playlist's menu: Make Live ...; Rename ...; Date and Time… ...;
    /// Duplicate… ...; Archive a Copy ...; Archive (... disabled while it
    /// is live) or, for an archived one, Restore from Archive ...; Delete…".
    /// "an archived playlist offers only Make Live, Duplicate, Archive a
    /// Copy, Restore from Archive and Delete (Spec 7 §5)."
    public static func playlist(_ entry: CatalogPlaylist, live: LiveStatus, cannotSend: Unavailable?, cannotEdit: Unavailable?) -> [MenuEntry] {
        let uuid = entry.playlist.uuid.uuidString.lowercased()
        let isLive = live.playlist == uuid
        // "A playlist whose title another shares can be ... made live only if its title loads it" (§6).
        let cannotLoad: CannotEdit? = entry.named ? reason(cannotSend) ?? (isLive && live.hasFired ? .alreadyLive : nil) : .fire(.renameToFire)
        let makeLive = MenuEntry(.makeLive, reason: cannotLoad)
        let edit = reason(cannotEdit)
        if entry.playlist.archived {
            return [makeLive, .separator, MenuEntry(.duplicatePlaylist, reason: edit), MenuEntry(.archiveCopy, reason: edit),
                    MenuEntry(.restoreFromArchive, reason: edit), .separator, MenuEntry(.deletePlaylist, reason: edit)]
        }
        return [makeLive, .separator, MenuEntry(.renamePlaylist, reason: edit), MenuEntry(.dateAndTime, reason: edit),
                MenuEntry(.duplicatePlaylist, reason: edit), MenuEntry(.archiveCopy, reason: edit),
                MenuEntry(.archive, reason: edit ?? (isLive ? .liveNow : nil)), .separator, MenuEntry(.deletePlaylist, reason: edit)]
    }

    /// "An item's menu: Remove from Playlist ...; Add Header Above ...;
    /// Rename, for a header ...; Show in Library, for a linked item."
    public static func item(_ item: PlaylistItem, in entry: CatalogPlaylist, cannotEdit: Unavailable?) -> [MenuEntry] {
        let edit = reason(cannotEdit) ?? (entry.playlist.archived ? .archived : nil)
        var entries = [MenuEntry(.removeItem, reason: edit), MenuEntry(.addHeaderAbove, reason: edit)]
        if case .header = item.kind { entries.append(MenuEntry(.renameHeader, reason: edit)) }
        if case .linked = item.kind { entries += [.separator, MenuEntry(.showInLibrary)] }
        return entries
    }

    /// Why a master list's own edits can't be made: the machine, or its number (Spec 10 §6).
    public static func cannotEdit(list: ListSummary, cannotEditMasters: Unavailable?) -> CannotEdit? {
        if list.local { return .localCopy }
        return reason(cannotEditMasters) ?? (list.named ? nil : .renumberToEdit)
    }

    /// "A list's menu: Add to Playlist ▸ ...; Rename ...; Duplicate ...;
    /// Open in Text Editor ...; Restore a Version… ...; Delete… ...; New
    /// List Here."
    public static func list(_ list: ListSummary, playlists: [CatalogPlaylist], cannotEditMasters: Unavailable?, cannotEditMachine: Unavailable?) -> [MenuEntry] {
        let edit = cannotEdit(list: list, cannotEditMasters: cannotEditMasters)
        let open = PlaylistTree.ordered(playlists, showArchived: false).map {
            MenuEntry(.addToPlaylist($0.playlist.uuid.uuidString.lowercased()), reason: reason(cannotEditMachine), name: $0.playlist.title)
        }
        var add = MenuEntry(.addToPlaylistMenu, children: open)
        // With no playlist to add it to, the submenu has nothing to offer.
        add.isEnabled = !open.isEmpty
        return [add, .separator,
                MenuEntry(.renameList, reason: edit), MenuEntry(.duplicateList, reason: edit), MenuEntry(.openInTextEditor, reason: .later),
                MenuEntry(.restoreVersion, reason: edit), .separator, MenuEntry(.deleteList, reason: edit), .separator,
                MenuEntry(.newListHere, reason: reason(cannotEditMasters))]
    }

    /// A folder's: rename it, a folder or a list inside it, and "Delete Folder is enabled only for an empty folder".
    public static func folder(isEmpty: Bool, cannotEditMasters: Unavailable?) -> [MenuEntry] {
        let edit = reason(cannotEditMasters)
        return [MenuEntry(.renameFolder, reason: edit), MenuEntry(.newFolder, reason: edit), MenuEntry(.newListHere, reason: edit), .separator,
                MenuEntry(.deleteFolder, reason: edit ?? (isEmpty ? nil : .folderNotEmpty))]
    }

    /// The Library tree's empty space: a folder or a list at the top.
    public static func libraryTop(cannotEditMasters: Unavailable?) -> [MenuEntry] {
        [MenuEntry(.newFolder, reason: reason(cannotEditMasters)), MenuEntry(.newListHere, reason: reason(cannotEditMasters))]
    }

    /// What a cue's menu needs to know of the cue and where it is.
    public struct CueContext: Equatable, Sendable {
        /// Whether a press would fire it, and why not.
        public var fire: CannotEdit?
        /// Why the cue can't be edited: its list is a local copy, shares its number, is gone, or the machine may not.
        public var edit: CannotEdit?
        /// Whether it writes text on the text channel (§6, "Double-click").
        public var hasText: Bool
        public var trigger: CueTrigger.Kind
        public var advanceAfterMs: Int?
        /// "Hold, on the armed cue".
        public var isArmed: Bool
        public var cannotSend: Unavailable?
        /// Why Edit Cue can't open edit mode: Spec 11 §2 — "While operator lock is on ... every entry above [is] disabled with the reason".
        public var editCue: CannotEdit?

        public init(fire: CannotEdit? = nil, edit: CannotEdit? = nil, hasText: Bool = false, trigger: CueTrigger.Kind = .go, advanceAfterMs: Int? = nil,
                    isArmed: Bool = false, cannotSend: Unavailable? = nil, editCue: CannotEdit? = nil) {
            self.editCue = editCue
            self.fire = fire
            self.edit = edit
            self.hasText = hasText
            self.trigger = trigger
            self.advanceAfterMs = advanceAfterMs
            self.isArmed = isArmed
            self.cannotSend = cannotSend
        }
    }

    /// "A cue's menu: Fire; Edit Text (for a text cue, without firing it);
    /// Edit Cue ...; Note… ...; Trigger ▸ Go, Time after Previous…
    /// (seconds), Advance After… (seconds or none); Duplicate Section ...;
    /// and Hold, on the armed cue (`disarm`)."
    public static func cue(_ context: CueContext) -> [MenuEntry] {
        var entries = [MenuEntry(.fire, reason: context.fire)]
        if context.hasText { entries.append(MenuEntry(.editText, reason: context.edit)) }
        var isTime = false
        if case .time = context.trigger { isTime = true }
        let trigger = [MenuEntry(.triggerGo, reason: context.edit, isOn: context.trigger == .go),
                       MenuEntry(.triggerTime, reason: context.edit, isOn: isTime),
                       .separator,
                       MenuEntry(.advanceAfter, reason: context.edit, isOn: context.advanceAfterMs != nil)]
        entries += [MenuEntry(.editCue, reason: context.editCue), .separator, MenuEntry(.note, reason: context.edit),
                    MenuEntry(.triggerMenu, children: trigger), MenuEntry(.duplicateSection, reason: context.edit)]
        if context.isArmed { entries += [.separator, MenuEntry(.hold, reason: reason(context.cannotSend))] }
        return entries
    }

    /// One channel a list header offers a grade for, with the grade its first write tracks now.
    public struct GradeChoice: Equatable, Sendable {
        public var channel: Int
        public var label: String
        public var tracked: Int?

        public init(channel: Int, label: String, tracked: Int?) {
            self.channel = channel
            self.label = label
            self.tracked = tracked
        }
    }

    /// "Its menu: Remove from Playlist; Show in Library; Open in Text Editor
    /// ...; Grade for Channel N ▸ (§10, one submenu per channel the list
    /// writes content to); Restore a Version… (§14)."
    public static func listHeader(inPlaylist: Bool, isLinked: Bool, removeItem: CannotEdit?, edit: CannotEdit?, channels: [GradeChoice], grades: [Grade]) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if inPlaylist { entries.append(MenuEntry(.removeItem, reason: removeItem)) }
        if isLinked { entries.append(MenuEntry(.showInLibrary)) }
        entries.append(MenuEntry(.openInTextEditor, reason: .later))
        if !channels.isEmpty { entries.append(.separator) }
        for choice in channels {
            var children = [MenuEntry(.grade(channel: choice.channel, grade: nil), reason: edit, isOn: choice.tracked == nil)]
            children += grades.sorted { $0.number < $1.number }.map {
                MenuEntry(.grade(channel: choice.channel, grade: $0.number), reason: edit, isOn: choice.tracked == $0.number, name: $0.label)
            }
            entries.append(MenuEntry(.gradeMenu(channel: choice.channel), name: choice.label, children: children))
        }
        entries += [.separator, MenuEntry(.restoreVersion, reason: edit)]
        return entries
    }

    /// "A tile's menu: Fire to Channel N (its drop channel); Fire to… (a
    /// channel); Defaults… ...; Replace with… ...; Reveal in Finder;
    /// Delete… (§10)." Replace and delete are for "Machine-index items;
    /// library items are refused with `readOnlyLibrary`" on a machine whose
    /// masters are read-only (Spec 8 §2).
    public static func tile(_ item: MediaItem, dropChannel: Int?, channels: [Channel], cannotSend: Unavailable?, cannotEditMasters: Unavailable?,
                            cannotEditMachine: Unavailable?) -> [MenuEntry] {
        let gone: CannotEdit? = item.isMissing || item.isDeleted ? .missing : nil
        let live = reason(cannotSend) ?? gone
        let edit = reason(item.index == "library" ? cannotEditMasters : cannotEditMachine)
        var entries: [MenuEntry] = []
        if let dropChannel {
            entries.append(MenuEntry(.fireTo(channel: dropChannel), reason: live, name: channels.first { $0.number == dropChannel }?.label ?? ""))
        }
        entries.append(MenuEntry(.fireToMenu, reason: live, children: channels.sorted { $0.number < $1.number }.map {
            MenuEntry(.fireTo(channel: $0.number), reason: live, name: $0.label)
        }))
        // A deleted item has nothing left to set, replace, show or delete; a missing one can still be replaced or deleted.
        let deleted: CannotEdit? = item.isDeleted ? .missing : nil
        entries += [.separator, MenuEntry(.defaults, reason: deleted ?? edit), MenuEntry(.replace, reason: deleted ?? edit),
                    MenuEntry(.reveal, reason: gone), .separator, MenuEntry(.deleteMedia, reason: deleted ?? edit)]
        return entries
    }
}

/// Spec 10 §5, §10 and §14 — a confirmation, as what it asks: the app's
/// sheets ask before a delete or a restore, and "A button that deletes,
/// restores or quits is never a sheet's default" (§9).
public enum Confirmation: Equatable, Sendable {
    /// "Delete… (`… delete`, after a confirmation, which says the service
    /// keeps running from the engine's copy when it is live, Spec 7 §4)".
    case deletePlaylist(title: String, isLive: Bool)
    /// "Remove from Playlist (... on the live item it says the song finishes first, Spec 7 §4)".
    case removeLiveItem(title: String)
    /// "Delete… (`edit list N delete`, after a confirmation naming the playlists that link it, from `listUse`)".
    case deleteList(title: String, playlists: [String])
    /// "Delete "Ocean loop"? It's used by 12 cues, 1 macro and 2 keys; they'll show it missing."
    case deleteMedia(name: String, use: MediaUseCount)
    /// Spec 10 §14 — "Restore version 16 of "Great Is Thy Faithfulness", kept Nov 1 at 09:12, with 14 cues? ..."
    case restoreVersion(version: Int, title: String, keptAt: String, cues: Int, onAir: Bool)
    /// Spec 10 §14 — "Replace the library, and this machine's playlists, key bindings and macros, with the copies from ...?"
    case restoreSnapshot(takenAt: String, mastersReadOnly: Bool)
    /// Spec 11 §4 — "Deleting cues asks first only when the cues hold edits,
    /// or include the live cue or the armed one (choice A-11)": how many
    /// cues, and which of those reasons apply.
    case deleteCues(count: Int, live: Bool, armed: Bool, edits: Bool)
    /// Spec 11 §6 — "On a stack an output shows, adding or removing a slot
    /// asks first, since it changes the picture at once": "Channel 3's content
    /// and its static boxes will show on output 1 now" or "Channel 2 is on air
    /// on output 1; removing its slot takes it off."
    case slotOnAir(channel: Int, label: String, outputs: [Int], adding: Bool)
    /// Spec 11 §6, §7, §8 — Delete of a stack, channel or preset, "asking
    /// first ..., with the counts from `uses`": "12 cues in 3 lists write
    /// channel 5. They stay in the lists, and the reference report flags them
    /// until they're edited." `uses` is the answer's non-zero counts by kind.
    case deleteNumbered(name: String, uses: [String: Int])
    /// Spec 11 §8 — "A stack's own layout offers Remove This Stack's Layout
    /// (`edit preset P unset layouts.S`), asking first."
    case removeLayout(preset: Int, stack: Int)
    /// Spec 11 §9 — "Re-apply to Boxes copies the style's value into every one of them ..., after saying how many."
    case reapplyStyle(name: String, boxes: Int)
    /// Spec 11 §9 — "Run on Air ... at once while nothing is live, and after asking while something is. A macro that
    /// holds an edit says first "This also changes the library.""
    case runMacro(name: String, live: Bool, edits: Bool)
}
