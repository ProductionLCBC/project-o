// OCore — Spec 7 §3, playlist edits; Spec 7 §5, archive.

import Foundation

extension Editor {
    // MARK: - Finding a playlist

    func playlist(_ uuid: UUID) throws -> (index: Int, playlist: Playlist) {
        guard let index = machine.playlists.firstIndex(where: { $0.uuid == uuid }) else {
            throw reject(.unknownObject, "playlist \(uuid.uuidString.lowercased()) does not exist")
        }
        return (index, machine.playlists[index])
    }

    /// Spec 7 §3 — titles are "unique without regard to case".
    func titleTaken(_ title: String, except uuid: UUID?) -> Bool {
        let key = Playlist.titleKey(title)
        return machine.playlists.contains { $0.uuid != uuid && Playlist.titleKey($0.title) == key }
    }

    /// The paths other files under `playlists/` hold.
    func takenPlaylistPaths(except uuid: UUID?) -> Set<String> {
        var taken = Set(machine.otherFiles.filter { $0.hasPrefix("playlists/") })
        let own = uuid.map(FileLayout.documentKey(playlist:))
        for (key, path) in machine.documentPaths where key.hasPrefix("playlist/") && key != own { taken.insert(path) }
        return taken
    }

    /// Spec 1 §3 — "The tree sorts dated playlists by date and lists undated
    /// ones by name", the order the loader keeps them in.
    mutating func insertInOrder(_ playlist: Playlist) {
        let key = { (p: Playlist) in (p.serviceDate ?? "", p.title.lowercased()) }
        let at = machine.playlists.firstIndex { key($0) > key(playlist) } ?? machine.playlists.count
        machine.playlists.insert(playlist, at: at)
    }

    /// Spec 7 §3 — a new or retitled playlist's file: "a slug of its title
    /// ... When that name belongs to another playlist's file, the engine takes
    /// the first free one of `sunday-2.json`, `sunday-3.json` and so on".
    mutating func nameFile(_ playlist: Playlist) {
        machine.documentPaths[FileLayout.documentKey(playlist: playlist.uuid)] =
            FileLayout.playlistPath(for: playlist, taken: takenPlaylistPaths(except: playlist.uuid))
    }

    /// Spec 1 §3 — `serviceDate`, "ISO date or null".
    static func isServiceDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(DurationText.isDigit) }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...12).contains(m), d >= 1 else { return false }
        let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return d <= days[m - 1]
    }

    /// Spec 1 §3 — `serviceTime`, "`HH:MM` or null, in the machine's time zone".
    static func isServiceTime(_ s: String) -> Bool {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(DurationText.isDigit) }),
              let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    // MARK: - Playlists

    mutating func editPlaylist(_ uuid: UUID?, _ action: EditAction, makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if case .create(let body, let folder, let title) = action {
            return try createPlaylist(uuid, body: body, folder: folder, title: title, makeUUID: makeUUID)
        }
        guard let uuid else { throw reject(.unknownObject, "the edit names no playlist: edit playlist <uuid> ...") }
        let (index, playlist) = try self.playlist(uuid)
        // Spec 5 §6, check 2 — "An archived playlist takes only the edit that
        // unarchives it and `delete` ...; `duplicate` and `archive` read it
        // without changing it" (Spec 7 §5).
        if playlist.archived {
            switch action {
            case .delete, .duplicate, .archive: break
            case .set("archived", _): break
            default: throw reject(.archived, "\"\(playlist.title)\" is archived and read-only; restore it with archived false")
            }
        }
        switch action {
        case .set(let path, let value):
            return try setPlaylistField(index, playlist, path, value)
        case .unset(let path):
            try checkPlaylistPath(path)
            throw reject(.badValue, "a playlist writes every field; set \(path) to null instead of removing it")
        case .delete:
            return try deletePlaylist(index, playlist)
        case .insert(let path, let at, let value):
            return try insertItem(index, playlist, path, at, value, makeUUID: makeUUID)
        case .duplicate(let to, let title, let picks):
            return try duplicatePlaylist(playlist, to: to, title: title, picks: picks, makeUUID: makeUUID)
        case .archive(let title, let picks):
            return try archivePlaylist(playlist, title: title, picks: picks, makeUUID: makeUUID)
        case .remove, .move:
            throw reject(.badValue, "an item is named by its uuid: edit playlist <uuid> item <uuid> \(action.verb)")
        case .create, .renumber, .swap, .section, .folder, .rename, .cueChannel:
            throw reject(.badValue, "\(action.verb) does not apply to a playlist")
        }
    }

    /// Spec 7 §3 — what a playlist edit sets: `title`, `serviceDate`,
    /// `serviceTime` and `archived`; items have their own verbs.
    func checkPlaylistPath(_ path: String) throws {
        switch path {
        case "title", "serviceDate", "serviceTime", "archived": return
        case "uuid", "schema", "app", "kind": throw reject(.readOnlyField, "a playlist's \(path) is never edited")
        case "items": throw reject(.readOnlyField, "a playlist's items are edited with insert, remove and move")
        default:
            if path.hasPrefix("items.") { throw reject(.readOnlyField, "an item is named by its uuid: edit playlist <uuid> item <uuid> ...") }
            throw reject(.unknownPath, "a playlist has no field \(path)")
        }
    }

    /// Spec 7 §3 — "`edit playlist P title "Sunday Night"` Renames it, and
    /// its file. An empty title is `badValue` and one in use is `duplicate`; a
    /// change of case alone is allowed"; "`serviceDate` ..., `serviceTime`
    /// ... `null` clears either". Spec 7 §5 — "`archived true` ... is refused
    /// with `onAir` while that playlist is live ... `archived false` restores
    /// either kind."
    mutating func setPlaylistField(_ index: Int, _ playlist: Playlist, _ path: String, _ value: JSONValue) throws -> (EditCommand, EditCommand?) {
        try checkPlaylistPath(path)
        let address = EditAddress.playlist(playlist.uuid)
        var updated = playlist
        let previous: JSONValue
        switch path {
        case "title":
            previous = .string(playlist.title)
            let title = Playlist.trimmedTitle(try string(value, path))
            guard !title.isEmpty else { throw reject(.badValue, "a playlist's title is never empty") }
            if titleTaken(title, except: playlist.uuid) { throw reject(.duplicate, "another playlist is titled \"\(title)\"") }
            updated.title = title
        case "serviceDate":
            previous = playlist.serviceDate.map(JSONValue.string) ?? .null
            let date = try optionalString(value, path)
            if let date, !Editor.isServiceDate(date) { throw reject(.badValue, "a service date is YYYY-MM-DD, not \(date)") }
            updated.serviceDate = date
        case "serviceTime":
            previous = playlist.serviceTime.map(JSONValue.string) ?? .null
            let time = try optionalString(value, path)
            if let time, !Editor.isServiceTime(time) { throw reject(.badValue, "a service time is HH:MM, 00:00 to 23:59, not \(time)") }
            updated.serviceTime = time
        default:
            previous = .bool(playlist.archived)
            updated.archived = try bool(value, path)
            if updated.archived, !playlist.archived, context.state?.pointer?.playlist == playlist.uuid {
                throw reject(.onAir, "\"\(playlist.title)\" is live; load another playlist first, or archive a copy")
            }
        }
        let logged = EditCommand(address, .set(path: path, value: value))
        guard updated != playlist else { return (logged, nil) }
        machine.playlists[index] = updated
        if updated.title != playlist.title {
            // "keeps it until the title changes".
            nameFile(updated)
        }
        changes.append(.playlist(playlist.uuid, paths: [path]))
        return (logged, EditCommand(address, .set(path: path, value: previous)))
    }

    /// Spec 7 §3 — "`edit playlist create "Sunday"` A new playlist with no
    /// items, no date or service time, not archived". A JSON body's fields
    /// win, so a delete's inverse brings a playlist back whole; the engine
    /// picks the uuids that are missing and the log records them.
    mutating func createPlaylist(_ given: UUID?, body: JSONValue?, folder: String?, title: String?,
                                 makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if folder != nil { throw reject(.badValue, "a playlist isn't in a folder") }
        let trimmed = Playlist.trimmedTitle(title ?? "")
        guard !trimmed.isEmpty else { throw reject(.badValue, "a playlist needs a title, never empty") }
        if titleTaken(trimmed, except: nil) { throw reject(.duplicate, "another playlist is titled \"\(trimmed)\"") }
        var object = body?.objectValue ?? [:]
        if let bodyTitle = object["title"], bodyTitle != .string(trimmed) {
            throw reject(.badValue, "the body's title is not \"\(trimmed)\"")
        }
        let uuid: UUID
        if let text = object["uuid"] {
            guard let u = text.stringValue.flatMap(UUID.init(uuidString:)), given == nil || given == u else {
                throw reject(.badValue, "the body's uuid is not the playlist's")
            }
            uuid = u
        } else {
            uuid = given ?? makeUUID()
        }
        if machine.playlist(uuid: uuid) != nil { throw reject(.duplicate, "a playlist with uuid \(uuid.uuidString.lowercased()) exists") }
        // Every item keeps its uuid; one without gets one the log records.
        if let raw = object["items"] {
            guard let items = raw.arrayValue else { throw reject(.badValue, "items is an array") }
            var seen: Set<String> = []
            object["items"] = .array(try items.map { item in
                guard var member = item.objectValue else { throw reject(.badValue, "an item is a JSON object") }
                if member["uuid"] == nil { member["uuid"] = .string(makeUUID().uuidString.lowercased()) }
                let text = member["uuid"]?.stringValue?.lowercased() ?? ""
                if !seen.insert(text).inserted { throw reject(.duplicate, "two items share uuid \(text)") }
                return .object(member)
            })
        }
        var tree = encode(Playlist(uuid: uuid, title: trimmed, items: [])).objectValue ?? [:]
        for (key, value) in object { tree[key] = value }
        tree["uuid"] = .string(uuid.uuidString.lowercased())
        tree["title"] = .string(trimmed)
        let playlist: Playlist
        do {
            playlist = try JSONCoding.decode(Playlist.self, from: .object(tree))
        } catch {
            throw reject(.badValue, "the playlist did not read: \(JSONCoding.describe(error))")
        }
        if let date = playlist.serviceDate, !Editor.isServiceDate(date) { throw reject(.badValue, "a service date is YYYY-MM-DD") }
        if let time = playlist.serviceTime, !Editor.isServiceTime(time) { throw reject(.badValue, "a service time is HH:MM") }
        for item in playlist.items { _ = try checkItemKind(item.kind) }
        insertInOrder(playlist)
        nameFile(playlist)
        changes.append(.playlist(uuid))
        let logged = EditCommand(.playlist(uuid), .create(body: body == nil ? nil : .object(object), folder: nil, title: trimmed))
        return (logged, EditCommand(.playlist(uuid), .delete))
    }

    /// Spec 7 §3 — "Deletes it, archived or not. The live playlist can be
    /// deleted: the engine's copy of it runs on until the pointer leaves it".
    mutating func deletePlaylist(_ index: Int, _ playlist: Playlist) throws -> (EditCommand, EditCommand?) {
        machine.playlists.remove(at: index)
        if let path = machine.documentPaths.removeValue(forKey: FileLayout.documentKey(playlist: playlist.uuid)) {
            structure.append(.removePlaylist(playlist.uuid, path: path))
        }
        changes.append(.playlist(playlist.uuid))
        return (EditCommand(.playlist(playlist.uuid), .delete),
                EditCommand(.playlist(playlist.uuid), .create(body: encode(playlist), folder: nil, title: playlist.title)))
    }

    /// Spec 7 §3 — what an item may be: a header, or a linked item whose list
    /// exists, its number and uuid as the list has them now ("the engine adds
    /// its `uuid` and `listUuid`"). "Local items ... v1 creates none ...:
    /// inserting one ... is `notInV1`", except to put one back (an inverse).
    func checkItemKind(_ kind: PlaylistItem.Kind) throws -> PlaylistItem.Kind {
        switch kind {
        case .header:
            return kind
        case .linked(let number, let listUuid):
            let found = listUuid.map { library.list(uuid: $0) } ?? library.list(number: number)
            guard let list = found else {
                if context.restoring { return kind }
                throw reject(.unknownReference, "list \(listUuid?.uuidString.lowercased() ?? String(number)) does not exist")
            }
            return .linked(list: list.number, listUuid: list.uuid)
        case .local:
            guard context.restoring else { throw reject(.notInV1, "local items are made with library mode, after v1") }
            return kind
        }
    }

    /// Spec 7 §3 — "`edit playlist P insert items 3 {"kind": "linked", "list":
    /// 42}` Inserts an item; the engine adds its `uuid` and `listUuid` and
    /// logs them ... An item inserted with a uuid already in the playlist is
    /// `duplicate`."
    mutating func insertItem(_ index: Int, _ playlist: Playlist, _ path: String, _ at: Int, _ value: JSONValue,
                             makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        guard path == "items" else {
            try checkPlaylistPath(path)
            throw reject(.badValue, "insert puts a value into an array, and \(path) isn't one")
        }
        try position(at, upTo: playlist.items.count, "the item's")
        guard value.objectValue != nil else { throw reject(.badValue, "an item is a JSON object") }
        let draft: PlaylistItem.Draft
        do {
            draft = try JSONCoding.decode(PlaylistItem.Draft.self, from: value)
        } catch {
            throw reject(.badValue, "the item did not read: \(JSONCoding.describe(error))")
        }
        let kind = try checkItemKind(draft.kind)
        let uuid = draft.uuid ?? makeUUID()
        if playlist.items.contains(where: { $0.uuid == uuid }) {
            throw reject(.duplicate, "the playlist already has an item \(uuid.uuidString.lowercased())")
        }
        let item = PlaylistItem(uuid: uuid, kind: kind, extra: draft.extra)
        var updated = playlist
        updated.items.insert(item, at: at)
        machine.playlists[index] = updated
        changes.append(.playlist(playlist.uuid, paths: ["items"]))
        return (EditCommand(.playlist(playlist.uuid), .insert(path: "items", at: at, value: encode(item))),
                EditCommand(.item(playlist: playlist.uuid, item: uuid), .remove(path: nil, at: nil)))
    }

    /// The new uuids of a copy: the playlist's and its items', as picked or given.
    func copyUuids(_ playlist: Playlist, _ picks: EditPicks, makeUUID: () -> UUID) throws -> (UUID, [UUID]) {
        if picks.cueUuids != nil { throw reject(.badValue, "a playlist's copy has items, not cues") }
        let uuid = picks.uuid ?? makeUUID()
        let items = picks.itemUuids ?? playlist.items.map { _ in makeUUID() }
        guard items.count == playlist.items.count else {
            throw reject(.badValue, "the copy needs \(playlist.items.count) item uuids, not \(items.count)")
        }
        if machine.playlist(uuid: uuid) != nil { throw reject(.duplicate, "a playlist with uuid \(uuid.uuidString.lowercased()) exists") }
        guard Set(items).count == items.count else { throw reject(.duplicate, "two items share a uuid") }
        return (uuid, items)
    }

    /// Spec 7 §3 — "`edit playlist P duplicate "Sunday Night"` Copies it
    /// under a new title, with new uuids for the playlist and every item: the
    /// same items and `serviceTime`, no `serviceDate`, not archived (choice
    /// Q-2). A local item in the copy points at the same local list".
    mutating func duplicatePlaylist(_ playlist: Playlist, to: Int?, title: String?, picks: EditPicks,
                                    makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if to != nil { throw reject(.badValue, "a playlist's copy takes a title, not a number") }
        let trimmed = Playlist.trimmedTitle(title ?? "")
        guard !trimmed.isEmpty else { throw reject(.badValue, "the copy needs a title, never empty") }
        if titleTaken(trimmed, except: nil) { throw reject(.duplicate, "another playlist is titled \"\(trimmed)\"") }
        let (uuid, itemUuids) = try copyUuids(playlist, picks, makeUUID: makeUUID)
        let items = zip(playlist.items, itemUuids).map { PlaylistItem(uuid: $1, kind: $0.kind, extra: $0.extra) }
        let copy = Playlist(uuid: uuid, title: trimmed, serviceDate: nil, serviceTime: playlist.serviceTime, items: items,
                            archived: false, extra: playlist.extra)
        insertInOrder(copy)
        nameFile(copy)
        changes.append(.playlist(uuid))
        return (EditCommand(.playlist(playlist.uuid), .duplicate(to: nil, title: trimmed, picks: EditPicks(uuid: uuid, itemUuids: itemUuids))),
                EditCommand(.playlist(uuid), .delete))
    }

    /// Spec 7 §5 — "`edit playlist P archive` makes a read-only copy of P
    /// under a dated title and leaves P exactly as it was. The copy has new
    /// uuids for itself and its items, and keeps everything else,
    /// `serviceDate` and `serviceTime` included." The dated title: "P's
    /// title, a space, and its `serviceDate`, or the day it runs in the
    /// machine's time zone when P has none ... A title that already ends with
    /// that date doesn't get it twice. If the result is taken, a space and
    /// `(2)`, `(3)` and so on follow it."
    mutating func archivePlaylist(_ playlist: Playlist, title: String?, picks: EditPicks,
                                  makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        let dated: String
        if let title {
            dated = Playlist.trimmedTitle(title)
            guard !dated.isEmpty else { throw reject(.badValue, "the archive's title is never empty") }
            if titleTaken(dated, except: nil) { throw reject(.duplicate, "another playlist is titled \"\(dated)\"") }
        } else {
            let date = playlist.serviceDate ?? context.today
            let base = playlist.title.hasSuffix(date) ? playlist.title : playlist.title + " " + date
            var candidate = base
            var n = 2
            while titleTaken(candidate, except: nil) {
                candidate = base + " (\(n))"
                n += 1
            }
            dated = candidate
        }
        let (uuid, itemUuids) = try copyUuids(playlist, picks, makeUUID: makeUUID)
        let items = zip(playlist.items, itemUuids).map { PlaylistItem(uuid: $1, kind: $0.kind, extra: $0.extra) }
        let copy = Playlist(uuid: uuid, title: dated, serviceDate: playlist.serviceDate, serviceTime: playlist.serviceTime,
                            items: items, archived: true, extra: playlist.extra)
        insertInOrder(copy)
        nameFile(copy)
        changes.append(.playlist(uuid))
        return (EditCommand(.playlist(playlist.uuid), .archive(title: dated, picks: EditPicks(uuid: uuid, itemUuids: itemUuids))),
                EditCommand(.playlist(uuid), .delete))
    }

    // MARK: - Items

    /// Spec 7 §3 — "`edit playlist P item I remove`, `… item I move 0`
    /// Removes or moves an item"; "`edit playlist P item I label "Worship"`
    /// Renames a header". Local items are loaded, never edited in v1.
    mutating func editItem(playlist uuid: UUID, item itemUuid: UUID, _ action: EditAction) throws -> (EditCommand, EditCommand?) {
        let (index, playlist) = try self.playlist(uuid)
        guard let itemIndex = playlist.items.firstIndex(where: { $0.uuid == itemUuid }) else {
            throw reject(.unknownObject, "the playlist has no item \(itemUuid.uuidString.lowercased())")
        }
        if playlist.archived { throw reject(.archived, "\"\(playlist.title)\" is archived and read-only; restore it with archived false") }
        let item = playlist.items[itemIndex]
        let address = EditAddress.item(playlist: uuid, item: itemUuid)
        var updated = playlist
        switch action {
        case .remove(nil, nil):
            updated.items.remove(at: itemIndex)
            machine.playlists[index] = updated
            changes.append(.playlist(uuid, paths: ["items"]))
            return (EditCommand(address, action),
                    EditCommand(.playlist(uuid), .insert(path: "items", at: itemIndex, value: encode(item))))
        case .move(nil, nil, let at):
            try position(at, upTo: playlist.items.count - 1, "the item's")
            if at == itemIndex { return (EditCommand(address, action), nil) }
            let moved = updated.items.remove(at: itemIndex)
            updated.items.insert(moved, at: at)
            machine.playlists[index] = updated
            changes.append(.playlist(uuid, paths: ["items"]))
            return (EditCommand(address, action), EditCommand(address, .move(path: nil, from: nil, at: itemIndex)))
        case .unset("label"):
            switch item.kind {
            case .header: throw reject(.badValue, "a header writes its label; set it instead of removing it")
            case .linked: throw reject(.unknownPath, "a linked item has no label; its list's title shows")
            case .local: throw reject(.notInV1, "local items are edited with library mode, after v1")
            }
        case .set("label", let value):
            switch item.kind {
            case .header(let label):
                let text = try string(value, "a header's label")
                let logged = EditCommand(address, .set(path: "label", value: value))
                if text == label { return (logged, nil) }
                updated.items[itemIndex].kind = .header(label: text)
                machine.playlists[index] = updated
                changes.append(.item(uuid, itemUuid, paths: ["label"]))
                return (logged, EditCommand(address, .set(path: "label", value: .string(label))))
            case .linked:
                throw reject(.unknownPath, "a linked item has no label; its list's title shows")
            case .local:
                throw reject(.notInV1, "local items are edited with library mode, after v1")
            }
        case .set(let path, _), .unset(let path):
            switch path {
            case "uuid", "kind", "list", "listUuid", "localUuid":
                throw reject(.readOnlyField, "an item's \(path) is never edited")
            default:
                throw reject(.unknownPath, "an item has no field \(path)")
            }
        default:
            throw reject(.badValue, "\(action.verb) does not apply to an item")
        }
    }
}
