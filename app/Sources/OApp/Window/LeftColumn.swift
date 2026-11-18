// OApp — Spec 10 §5, the left column: the Playlists tree and the Library tree.

import Foundation
import OCore

/// How titles and names are put in order: as the Finder does, with case
/// ignored and numbers by their value (Area 13 reading; Spec 1 §3 says "by
/// title" and no more).
func finderOrder(_ a: String, _ b: String) -> Bool {
    a.localizedStandardCompare(b) == .orderedAscending
}

/// Spec 10 §5 — one row of the Playlists tree.
public struct PlaylistRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case playlist
        /// "headers in small capitals".
        case header
        /// "linked items with their list's title".
        case item
    }

    public var kind: Kind
    /// The playlist's uuid, and for a row inside it the item's uuid and its number from 1.
    public var playlist: String
    public var itemUuid: String?
    public var item: Int?
    public var listUuid: String?
    public var title: String
    /// A playlist's `serviceDate`, as stored.
    public var date: String?
    /// "greyed with an "archived" tag".
    public var isArchived = false
    /// "The live playlist and its live item carry the red live dot".
    public var isLive = false
    public var isExpanded = false
    /// The grid shows this playlist.
    public var isBrowsed = false
    /// "an item whose list is missing in red".
    public var isMissing = false
    /// "a local item with its "local" tag (Spec 7 §3)".
    public var isLocal = false
    /// Why Make Live is disabled, for a playlist row (Spec 10 §6).
    public var refusal: FireRefusal?
}

/// Spec 10 §5, "The Playlists window".
public enum PlaylistTree {
    /// "undated ones first, by title, then dated ones, newest date first
    /// (Spec 1 §3). Archived playlists are hidden unless View ▸ Show
    /// Archived Playlists is on". Playlists of one date go by their time,
    /// then their title (Area 13 reading).
    public static func ordered(_ playlists: [CatalogPlaylist], showArchived: Bool) -> [CatalogPlaylist] {
        let shown = playlists.filter { showArchived || !$0.playlist.archived }
        let undated = shown.filter { $0.playlist.serviceDate == nil }.sorted { finderOrder($0.playlist.title, $1.playlist.title) }
        let dated = shown.filter { $0.playlist.serviceDate != nil }.sorted { a, b in
            let (x, y) = (a.playlist, b.playlist)
            if x.serviceDate != y.serviceDate { return (x.serviceDate ?? "") > (y.serviceDate ?? "") }
            if x.serviceTime != y.serviceTime { return (x.serviceTime ?? "") < (y.serviceTime ?? "") }
            return finderOrder(x.title, y.title)
        }
        return undated + dated
    }

    /// The tree's rows, top to bottom: each playlist, and under an expanded one its items.
    public static func rows(catalog: Catalog, live: LiveStatus, expanded: Set<String>, shown: GridContext?, showArchived: Bool) -> [PlaylistRow] {
        var rows: [PlaylistRow] = []
        for entry in ordered(catalog.playlists, showArchived: showArchived) {
            let playlist = entry.playlist
            let uuid = playlist.uuid.uuidString.lowercased()
            let isLive = live.playlist == uuid
            var row = PlaylistRow(kind: .playlist, playlist: uuid, title: playlist.title, date: playlist.serviceDate)
            row.isArchived = playlist.archived
            row.isLive = isLive
            row.isExpanded = expanded.contains(uuid)
            row.isBrowsed = shown == .playlist(uuid)
            if case .failure(let refusal) = GridFire.makeLive(entry) { row.refusal = refusal }
            rows.append(row)
            guard row.isExpanded else { continue }
            for (index, item) in playlist.items.enumerated() {
                let itemUuid = item.uuid.uuidString.lowercased()
                switch item.kind {
                case .header(let label):
                    rows.append(PlaylistRow(kind: .header, playlist: uuid, itemUuid: itemUuid, item: index + 1, title: label, isArchived: playlist.archived))
                case .linked, .local:
                    let listUuid = GridModel.listUuid(of: item, catalog: catalog)
                    let summary = listUuid.flatMap { catalog.list(uuid: $0) }
                    var row = PlaylistRow(kind: .item, playlist: uuid, itemUuid: itemUuid, item: index + 1, listUuid: listUuid, title: summary?.title ?? "")
                    row.isArchived = playlist.archived
                    row.isLive = isLive && live.item == itemUuid
                    row.isMissing = summary == nil
                    if case .local = item.kind { row.isLocal = true }
                    rows.append(row)
                }
            }
        }
        return rows
    }

    /// "One playlist is expanded at a time; ⌥-click expands another as
    /// well." A plain click opens that playlist alone; ⌥-click opens it
    /// beside the others, or closes it when it is open.
    public static func expanding(_ uuid: String, in expanded: Set<String>, option: Bool) -> Set<String> {
        guard option else { return [uuid] }
        var next = expanded
        if next.contains(uuid) { next.remove(uuid) } else { next.insert(uuid) }
        return next
    }
}

/// Spec 10 §5 — one row of the Library tree.
public struct LibraryRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case folder
        case list
    }

    public var kind: Kind
    /// A folder's path under `lists/`, or the path of the folder a list is in ("" at the top).
    public var path: String
    public var depth: Int
    /// A folder's name, or a list's title.
    public var title: String
    /// "dimmed at the right, its number".
    public var number: Int?
    public var uuid: String?
    public var isOpen = false
    /// Why the list can't be fired from here (Spec 10 §6: "Renumber to fire").
    public var refusal: FireRefusal?
}

/// Spec 10 §5, "The Library window" — "one tab, Lists, in v1".
public enum LibraryTree {
    /// The tree's rows, top to bottom: in each folder its folders first,
    /// then its lists, each as the Finder sorts them. With a search, "the
    /// matches as a flat list with their folders". A local copy isn't a
    /// library list and isn't shown (Spec 7 §3).
    public static func rows(catalog: Catalog, open: Set<String>, search: String) -> [LibraryRow] {
        let lists = catalog.lists.filter { !$0.local }
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return lists.filter { matches($0, needle) }
                .sorted { $0.folder != $1.folder ? finderOrder($0.folder, $1.folder) : finderOrder($0.title, $1.title) }
                .map { row(for: $0, depth: 0) }
        }
        // Every folder the library has, and every one a list or a deeper folder implies.
        var folders: Set<String> = []
        for path in catalog.folders + lists.map(\.folder) where !path.isEmpty {
            var parts: [String] = []
            for part in path.split(separator: "/") {
                parts.append(String(part))
                folders.insert(parts.joined(separator: "/"))
            }
        }
        var rows: [LibraryRow] = []
        func walk(_ parent: String, depth: Int) {
            let children = folders.filter { Self.parent(of: $0) == parent }.sorted { finderOrder(name(of: $0), name(of: $1)) }
            for folder in children {
                let isOpen = open.contains(folder)
                rows.append(LibraryRow(kind: .folder, path: folder, depth: depth, title: name(of: folder), isOpen: isOpen))
                if isOpen { walk(folder, depth: depth + 1) }
            }
            for list in lists.filter({ $0.folder == parent }).sorted(by: { finderOrder($0.title, $1.title) }) {
                rows.append(row(for: list, depth: depth))
            }
        }
        walk("", depth: 0)
        return rows
    }

    private static func row(for list: ListSummary, depth: Int) -> LibraryRow {
        var row = LibraryRow(kind: .list, path: list.folder, depth: depth, title: list.title, number: list.number, uuid: list.uuid)
        if case .failure(let refusal) = GridFire.libraryCue(list, cue: 1) { row.refusal = refusal }
        return row
    }

    /// The folder a folder is in ("" at the top).
    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// A folder's own name, the last part of its path.
    public static func name(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    /// Area 13 reading — a title or an author matches anywhere in it, case
    /// and accents ignored; a CCLI number matches from its first digit.
    static func matches(_ list: ListSummary, _ needle: String) -> Bool {
        if GridModel.matches(list.title, needle) || GridModel.matches(list.author, needle) { return true }
        return needle.allSatisfy(\.isNumber) && list.ccli.hasPrefix(needle)
    }
}
