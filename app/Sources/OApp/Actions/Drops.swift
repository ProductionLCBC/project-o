// OApp — Spec 10 §5, §6 and §7, what a drag carries, where it may land, and what landing there does.

import Foundation
import OCore

/// What a drag carries.
public enum DragPayload: Equatable, Sendable {
    /// A playlist's item, dragged to reorder it (Spec 10 §5, "Dragging").
    case item(playlist: String, item: String)
    /// A list from the Library window, by its uuid.
    case list(String)
    /// A library folder, by its path.
    case folder(String)
    /// A pool tile, by the media item's id.
    case media(String)
    /// Files or folders dragged from the Finder, by their paths.
    case files([String])

    /// The payload as one line of text, for the pasteboard; `init(text:)` reads it back.
    public var text: String {
        switch self {
        case .item(let playlist, let item): return "item\n" + playlist + "\n" + item
        case .list(let uuid): return "list\n" + uuid
        case .folder(let path): return "folder\n" + path
        case .media(let id): return "media\n" + id
        case .files(let paths): return (["files"] + paths).joined(separator: "\n")
        }
    }

    public init?(text: String) {
        let parts = text.components(separatedBy: "\n")
        switch (parts.first, parts.count) {
        case ("item", 3): self = .item(playlist: parts[1], item: parts[2])
        case ("list", 2): self = .list(parts[1])
        case ("folder", 2): self = .folder(parts[1])
        case ("media", 2): self = .media(parts[1])
        case ("files", 2...): self = .files(Array(parts.dropFirst()))
        default: return nil
        }
    }
}

/// Where a drag may land.
public enum DropTarget: Equatable, Sendable {
    /// A playlist's row in the Playlists window.
    case playlist(String)
    /// Beside an item's row: above it, or below it.
    case item(playlist: String, item: String, below: Bool)
    /// A list header in the grid, by its item; nil is the space past the last list.
    case listHeader(playlist: String, item: String?)
    /// A folder's row in the Library window.
    case folder(String)
    /// The Library tree's empty space: the top.
    case libraryTop
}

/// What was let go on a cue, waiting for its channel (Spec 10 §6, "Drops on
/// the grid"; §10): "opens a popover of channels with the item's drop
/// channel picked".
public struct CueDrop: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A pool tile, by the item's id.
        case media(String)
        /// A file from the Finder, by its path.
        case file(String)
    }

    public var source: Source
    /// The channel the popover opens on; nil when the drop channel is "Ask", or the file's type suggests none.
    public var picked: Int?

    public init(source: Source, picked: Int?) {
        self.source = source
        self.picked = picked
    }
}

/// What landing there does.
public enum DropPlan: Equatable, Sendable {
    /// Nothing: the target takes no such thing, or it is already where it would go.
    case none
    /// It can't be done now, with why; the target says so.
    case refused(CannotEdit)
    /// One edit.
    case edit(Sending, master: Bool)
    /// On a cue: the channel popover opens, and its answer writes the item into the cue, or imports the file first.
    case chooseChannel(CueDrop)
    /// On a strip cell: "A pool tile dropped on a cell goes live at once" (Spec 10 §7).
    case live(media: String, channel: Int)
    /// On a strip cell: "A file from the Finder is taken the same way ... and sends the live write when the job's `done` names the item".
    case importLive(path: String, channel: Int)
    /// On the pool: "Files dropped on the pool from outside ... are copied into the staging folder and imported".
    case importFiles([String])

    public var sending: Sending? {
        if case .edit(let sending, _) = self { return sending }
        return nil
    }

    /// Whether the target should show it would take the drop.
    public var isAccepted: Bool {
        switch self {
        case .none, .refused: return false
        default: return true
        }
    }
}

/// Spec 10 §5, "Dragging" — "Items drag to reorder (`… item I move K`). A
/// list dragged from the Library window, or onto a list header in the grid
/// (§6), is inserted where it lands"; "Dragging a list onto a folder moves
/// it (`edit list N folder "PATH"`), onto the tree's empty space moves it to
/// the top (`""`), and onto a playlist in the Playlists window inserts it
/// there. A folder dragged onto another moves into it (a rename with the
/// new parent)."
public enum Drops {
    public static func plan(_ payload: DragPayload, onto target: DropTarget, catalog: Catalog?, cannotEditMachine: Unavailable?,
                            cannotEditMasters: Unavailable?) -> DropPlan {
        guard let catalog else { return .none }
        switch target {
        case .playlist(let uuid):
            guard case .list(let list) = payload, let entry = catalog.playlist(uuid: uuid) else { return .none }
            return insert(list, in: entry, at: entry.playlist.items.count, catalog: catalog, cannot: cannotEditMachine)

        case .item(let uuid, let item, let below):
            guard let entry = catalog.playlist(uuid: uuid), let index = position(of: item, in: entry.playlist) else { return .none }
            let slot = index + (below ? 1 : 0)
            switch payload {
            case .list(let list):
                return insert(list, in: entry, at: slot, catalog: catalog, cannot: cannotEditMachine)
            case .item(let from, let moved):
                // An item moves within its own playlist (Area 13 reading: none is dragged into another).
                guard from == uuid, let old = position(of: moved, in: entry.playlist) else { return .none }
                // Where it ends once it is taken out of where it was.
                let landed = slot > old ? slot - 1 : slot
                guard landed != old else { return .none }
                if let refusal = refusal(entry, cannotEditMachine) { return .refused(refusal) }
                return .edit(Edits.move(item: entry.playlist.items[old].uuid, in: entry.playlist.uuid, to: landed), master: false)
            default:
                return .none
            }

        case .listHeader(let uuid, let item):
            // "A list dragged from the Library window onto a playlist's list header is inserted above it, and below the
            // last list when dropped past it."
            guard case .list(let list) = payload, let entry = catalog.playlist(uuid: uuid) else { return .none }
            let slot = item.flatMap { position(of: $0, in: entry.playlist) } ?? entry.playlist.items.count
            return insert(list, in: entry, at: slot, catalog: catalog, cannot: cannotEditMachine)

        case .folder(let path):
            return move(payload, into: path, catalog: catalog, cannot: cannotEditMasters)

        case .libraryTop:
            return move(payload, into: "", catalog: catalog, cannot: cannotEditMasters)
        }
    }

    // MARK: - Cues, strip cells and the pool (Spec 10 §6, §7; choice U-8)

    /// "The grid and the strip take one file at a time: several files, or a
    /// folder, are refused there, and the cell says to drop them on the pool."
    private static func oneFile(_ paths: [String], isFolder: (String) -> Bool) -> String? {
        guard paths.count == 1, let path = paths.first, !isFolder(path) else { return nil }
        return path
    }

    /// An item that can be put somewhere: one whose file is there (Area 13
    /// reading: a missing or deleted item is refused on a cue and a cell, as
    /// its Fire to is disabled).
    private static func usable(_ id: String, in media: [MediaItem]) -> (item: MediaItem, gone: CannotEdit?)? {
        guard let item = media.first(where: { $0.id == id }) else { return nil }
        return (item, item.isMissing || item.isDeleted ? .missing : nil)
    }

    /// "A pool tile dropped on a cue writes it into that cue (§10)"; "A file
    /// dragged from the Finder onto a cue is imported, then written into it
    /// ... The channel popover opens at the drop, with the drop channel for
    /// the kind the file's type suggests". `cannotEdit` is why the cue takes
    /// no edit now, the lock included (Spec 10 §12).
    public static func plan(_ payload: DragPayload, ontoCue cannotEdit: CannotEdit?, media: [MediaItem], settings: MachineSettings?,
                            isFolder: (String) -> Bool) -> DropPlan {
        switch payload {
        case .media(let id):
            guard let found = usable(id, in: media) else { return .none }
            if let cannot = cannotEdit ?? found.gone { return .refused(cannot) }
            return .chooseChannel(CueDrop(source: .media(id), picked: MediaPool.dropChannel(for: found.item.entry, settings: settings)))
        case .files(let paths):
            guard !paths.isEmpty else { return .none }
            if let cannotEdit { return .refused(cannotEdit) }
            guard let path = oneFile(paths, isFolder: isFolder) else { return .refused(.dropOnThePool) }
            return .chooseChannel(CueDrop(source: .file(path), picked: FileKind.dropChannel(forPath: path, settings: settings)))
        default:
            return .none
        }
    }

    /// Spec 10 §7, "Drops" — a pool tile "goes live at once, as a live write
    /// from the pool", which the lock leaves working (§12: "drops of pool
    /// tiles on the strip ... all work"); a file is imported first, which the
    /// lock refuses ("any file under the lock").
    public static func plan(_ payload: DragPayload, ontoChannel channel: Int, media: [MediaItem], cannotSend: Unavailable?, cannotImport: Unavailable?,
                            isFolder: (String) -> Bool) -> DropPlan {
        switch payload {
        case .media(let id):
            guard let found = usable(id, in: media) else { return .none }
            if let cannot = cannotSend.map(CannotEdit.unavailable) ?? found.gone { return .refused(cannot) }
            return .live(media: id, channel: channel)
        case .files(let paths):
            guard !paths.isEmpty else { return .none }
            if let cannotImport { return .refused(.unavailable(cannotImport)) }
            guard let path = oneFile(paths, isFolder: isFolder) else { return .refused(.dropOnThePool) }
            return .importLive(path: path, channel: channel)
        default:
            return .none
        }
    }

    /// Spec 10 §6, "Importing" — "Files dropped on the pool from outside":
    /// any number, folders too (Spec 8 §3).
    public static func planOnPool(_ payload: DragPayload, cannotImport: Unavailable?) -> DropPlan {
        guard case .files(let paths) = payload, !paths.isEmpty else { return .none }
        if let cannotImport { return .refused(.unavailable(cannotImport)) }
        return .importFiles(paths)
    }

    private static func position(of item: String, in playlist: Playlist) -> Int? {
        playlist.items.firstIndex { $0.uuid.uuidString.lowercased() == item }
    }

    private static func refusal(_ entry: CatalogPlaylist, _ cannot: Unavailable?) -> CannotEdit? {
        cannot.map(CannotEdit.unavailable) ?? (entry.playlist.archived ? .archived : nil)
    }

    private static func insert(_ list: String, in entry: CatalogPlaylist, at slot: Int, catalog: Catalog, cannot: Unavailable?) -> DropPlan {
        // A local copy isn't a library list, and can't be linked.
        guard let summary = catalog.list(uuid: list), !summary.local else { return .none }
        if let refusal = refusal(entry, cannot) { return .refused(refusal) }
        return .edit(Edits.insert(list: summary, in: entry.playlist.uuid, at: slot), master: false)
    }

    private static func move(_ payload: DragPayload, into folder: String, catalog: Catalog, cannot: Unavailable?) -> DropPlan {
        switch payload {
        case .list(let uuid):
            guard let list = catalog.list(uuid: uuid), !list.local, list.folder != folder else { return .none }
            if let refusal = Menus.cannotEdit(list: list, cannotEditMasters: cannot) { return .refused(refusal) }
            return .edit(Edits.move(list: list.number, toFolder: folder), master: true)
        case .folder(let path):
            // Not into itself or anything under it, and not into the folder it is already in.
            guard path != folder, !folder.hasPrefix(path + "/"), LibraryTree.parent(of: path) != folder else { return .none }
            if let cannot { return .refused(.unavailable(cannot)) }
            return .edit(Edits.move(folder: path, into: folder), master: true)
        default:
            return .none
        }
    }
}
