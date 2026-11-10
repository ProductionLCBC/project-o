// OCore — Spec 7 §2, list edits; Spec 5 §4, the verbs on lists and their cues.

import Foundation

extension Editor {
    // MARK: - Finding a list and its folder

    /// Spec 7 §2 — "Anything that names the number alone, such as `list 57
    /// cue 3` or an edit, gets the one that comes first".
    func list(_ number: Int) throws -> (index: Int, list: List) {
        guard let index = library.lists.firstIndex(where: { $0.number == number }) else {
            throw reject(.unknownObject, "list \(number) does not exist")
        }
        return (index, library.lists[index])
    }

    /// Spec 7 §2 — "Names compare without regard to case": the one folder a
    /// path names, `""` for the top of `lists/`. Two folders that differ only
    /// in case are refused "with `duplicate` until one is renamed".
    func resolveFolder(_ path: String) throws -> String {
        guard !path.isEmpty else { return "" }
        let matches = library.folders.filter { $0.lowercased() == path.lowercased() }
        if matches.count > 1 {
            throw reject(.duplicate, "folders \(matches.map { "\"\($0)\"" }.joined(separator: " and ")) differ only in case; rename one first")
        }
        guard let folder = matches.first else { throw reject(.unknownObject, "folder \"\(path)\" does not exist") }
        return folder
    }

    /// The paths other files under `lists/` hold, lowercased: "Other files
    /// are never replaced" (Spec 7 §2).
    func takenListPaths(except uuid: UUID? = nil) -> Set<String> {
        var taken = Set(library.otherFiles.map { $0.lowercased() })
        let own = uuid.map(FileLayout.documentKey(list:))
        for (key, path) in library.documentPaths where key.hasPrefix("list/") && key != own {
            taken.insert(path.lowercased())
        }
        return taken
    }

    /// Lists stay in number order, those sharing a number in the order they
    /// loaded in (Spec 7 §2); a new one goes after any with its number.
    mutating func insertInOrder(_ list: List) {
        let at = library.lists.firstIndex { $0.number > list.number } ?? library.lists.count
        library.lists.insert(list, at: at)
    }

    // MARK: - Lists

    mutating func editList(_ number: Int?, _ action: EditAction, makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if case .create(let body, let folder, let title) = action {
            return try createList(number, body: body, folder: folder, title: title, makeUUID: makeUUID)
        }
        guard let number else { throw reject(.unknownObject, "the edit names no list: edit list N ...") }
        let (index, list) = try self.list(number)
        switch action {
        case .set(let path, let value):
            return try setListField(index, list, path, value)
        case .unset(let path):
            try checkListPath(path)
            throw reject(.badValue, "a list writes every field; set \(path) instead of removing it")
        case .delete:
            return try deleteList(index, list)
        case .renumber(let to):
            return try renumberList(list, to: to)
        case .swap(let other):
            return try swapList(list, with: other)
        case .insert(let path, let at, let value):
            return try insertCue(index, list, path, at, value, makeUUID: makeUUID)
        case .duplicate(let to, let title, let picks):
            return try duplicateList(list, to: to, title: title, picks: picks, makeUUID: makeUUID)
        case .folder(let path):
            return try moveList(list, to: path)
        case .remove, .move:
            throw reject(.badValue, "a cue is named by its uuid: edit list \(number) cue <uuid> \(action.verb)")
        case .create, .archive, .section, .rename, .cueChannel:
            throw reject(.badValue, "\(action.verb) does not apply to a list")
        }
    }

    /// Spec 5 §6, check 3 — "It exists in the object's JSON Schema ... and is
    /// editable. `uuid`, `schema`, `app`, `kind`, `version`, `builtIn` and
    /// `number` never are; numbers change only through `renumber` and `swap`."
    /// Spec 7 §2 — "Metadata. `title`, `author`, `copyright`, `ccli` and
    /// `trackThrough` are set like any field"; cues have their own verbs.
    func checkListPath(_ path: String) throws {
        switch path {
        case "title", "author", "copyright", "ccli", "trackThrough":
            return
        case "uuid", "number", "version", "schema", "app", "kind", "builtIn":
            throw reject(.readOnlyField, "a list's \(path) is never edited" + (path == "number" ? "; renumber the list instead" : ""))
        case "cues":
            throw reject(.readOnlyField, "a list's cues are edited with insert, remove and move")
        case "timeline":
            throw reject(.notInV1, "timelines are v2")
        default:
            if path.hasPrefix("cues.") {
                throw reject(.readOnlyField, "a cue is named by its uuid: edit list N cue <uuid> ...")
            }
            throw reject(.unknownPath, "a list has no field \(path)")
        }
    }

    mutating func setListField(_ index: Int, _ list: List, _ path: String, _ value: JSONValue) throws -> (EditCommand, EditCommand?) {
        try checkListPath(path)
        var updated = list
        let previous: JSONValue
        switch path {
        case "title":
            previous = .string(list.title)
            updated.title = try string(value, path)
        case "author":
            previous = .string(list.author)
            updated.author = try string(value, path)
        case "copyright":
            previous = .string(list.copyright)
            updated.copyright = try string(value, path)
        case "ccli":
            previous = .string(list.ccli)
            updated.ccli = try string(value, path)
        default:
            previous = .bool(list.trackThrough)
            updated.trackThrough = try bool(value, path)
        }
        let logged = EditCommand(.list(list.number), .set(path: path, value: value))
        guard updated != list else { return (logged, nil) }
        library.lists[index] = updated
        changes.append(.list(updated, paths: [path]))
        return (logged, EditCommand(.list(list.number), .set(path: path, value: previous)))
    }

    /// Spec 7 §2 — "`edit list 57 create` makes list 57 at the top of
    /// `lists/`, or in the folder it names ... Without a body the list has no
    /// cues, `trackThrough` off and `version` 1; a body's fields win, its cues
    /// and `version` included, so a delete's inverse brings a list back whole.
    /// Without a number, `edit list create`, the engine picks one." The logged
    /// command records the number in its address and the uuid in its body.
    mutating func createList(_ number: Int?, body: JSONValue?, folder: String?, title: String?,
                             makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if title != nil { throw reject(.badValue, "a list's title goes in its body: {\"title\": ...}") }
        let n: Int
        if let number {
            guard number >= 1 else { throw reject(.badValue, "a list number is 1 or more") }
            if library.list(number: number) != nil {
                throw reject(.duplicate, "list \(number) exists; pick another number, or swap")
            }
            n = number
        } else {
            n = nextListNumber()
        }
        let resolved = try resolveFolder(folder ?? "")
        let given = body?.objectValue ?? [:]
        if let bodyNumber = given["number"], bodyNumber.intValue != n {
            throw reject(.badValue, "the body's number \(CommandPrinter.valueText(bodyNumber)) is not \(n)")
        }
        if given["provenance"] != nil { throw reject(.badValue, "a master has no provenance; local copies aren't made in v1") }
        let uuid: UUID
        if let text = given["uuid"] {
            guard let u = text.stringValue.flatMap(UUID.init(uuidString:)) else { throw reject(.badValue, "the body's uuid is not a uuid") }
            uuid = u
        } else {
            uuid = makeUUID()
        }
        var object = encode(List(uuid: uuid, number: n, cues: [])).objectValue ?? [:]
        for (key, value) in given { object[key] = value }
        object["uuid"] = .string(uuid.uuidString.lowercased())
        let list: List
        do {
            list = try JSONCoding.decode(List.self, from: .object(object))
        } catch {
            throw reject(.badValue, "the list did not read: \(JSONCoding.describe(error))")
        }
        guard list.version >= 0 else { throw reject(.badValue, "a list's version is 0 or more") }
        for cue in list.cues { try checkCue(cue, old: nil) }
        if library.list(uuid: uuid) != nil { throw reject(.duplicate, "a list with uuid \(uuid.uuidString.lowercased()) exists") }
        try checkCueUuidsUnique(list.cues)
        insertInOrder(list)
        let path = FileLayout.freeListPath(for: list, folder: resolved, taken: takenListPaths(except: uuid))
        library.documentPaths[FileLayout.documentKey(list: uuid)] = path
        changes.append(.list(list))
        var logged = given
        logged["uuid"] = .string(uuid.uuidString.lowercased())
        return (EditCommand(.list(n), .create(body: .object(logged), folder: resolved.isEmpty ? nil : resolved, title: nil)),
                EditCommand(.list(n), .delete))
    }

    /// Spec 7 §2 — "Delete removes the list's file. Linked items that name it
    /// stay, show as missing (choice Q-4) and are flagged by the reference
    /// report (Spec 5 §6's warning). The inverse puts the list back in its
    /// folder." Spec 5 §6 — "The live list is the exception. Deleting it is
    /// allowed, and the engine runs on from its kept copy".
    mutating func deleteList(_ index: Int, _ list: List) throws -> (EditCommand, EditCommand?) {
        let folder = library.folder(ofList: list.uuid) ?? ""
        let linking = machine.playlists.filter { playlist in
            playlist.items.contains { library.list(for: $0.kind)?.uuid == list.uuid }
        }
        if !linking.isEmpty {
            warnings.append("list \(list.number) is linked by " + linking.map { "\"\($0.title)\"" }.joined(separator: ", ")
                            + "; those items show as missing")
        }
        let othersWithNumber = library.lists.filter { $0.number == list.number }.count > 1
        let named = listNumbersReferenced(byNumberOnly: true).filter { $0 == list.number }.count
        if named > 0, !othersWithNumber {
            warnings.append("list \(list.number) is still named by \(named) reference\(named == 1 ? "" : "s"), which the reference report flags")
        }
        let key = FileLayout.documentKey(list: list.uuid)
        library.lists.remove(at: index)
        if let path = library.documentPaths.removeValue(forKey: key) {
            structure.append(.removeList(list.uuid, path: path))
        }
        changes.append(.list(list))
        return (EditCommand(.list(list.number), .delete),
                EditCommand(.list(list.number), .create(body: encode(list), folder: folder.isEmpty ? nil : folder, title: nil)))
    }

    /// Spec 1 §4, Spec 7 §2 — "Renumber and swap rewrite the links in every
    /// playlist, archived ones included, along with every other reference".
    /// Spec 5 §6 — "Moving to a number that is already taken offers a swap";
    /// "`renumber` and `swap` also refuse a number that broken references
    /// still name, so they never adopt references meant for a deleted object."
    mutating func renumberList(_ list: List, to: Int) throws -> (EditCommand, EditCommand?) {
        let logged = EditCommand(.list(list.number), .renumber(to: to))
        guard to >= 1 else { throw reject(.badValue, "a list number is 1 or more") }
        if to == list.number { return (logged, nil) }
        if library.list(number: to) != nil { throw reject(.duplicate, "list \(to) exists; swap the two lists instead") }
        if listNumbersReferenced(byNumberOnly: true).contains(to) {
            throw reject(.danglingReferences, "references still name list \(to), which doesn't exist; renumbering onto it would take them over")
        }
        _ = Identity.renumber(.list, from: list.number, to: to, library: &library, machine: &machine)
        var renumbered = list
        renumbered.number = to
        changes.append(.list(renumbered))
        return (logged, EditCommand(.list(to), .renumber(to: list.number)))
    }

    mutating func swapList(_ list: List, with other: Int) throws -> (EditCommand, EditCommand?) {
        let logged = EditCommand(.list(list.number), .swap(with: other))
        guard other >= 1 else { throw reject(.badValue, "a list number is 1 or more") }
        if other == list.number { return (logged, nil) }
        guard let second = library.list(number: other) else { throw reject(.unknownObject, "list \(other) does not exist") }
        _ = Identity.swap(.list, list.number, other, library: &library, machine: &machine)
        var a = list
        a.number = other
        var b = second
        b.number = list.number
        changes.append(.list(a))
        changes.append(.list(b))
        return (logged, EditCommand(.list(list.number), .swap(with: other)))
    }

    /// Spec 7 §2 — "`edit list 42 duplicate`, or `… duplicate 57`, copies the
    /// list into the same folder with a new uuid for the list and every cue,
    /// the same title and `version` 1."
    mutating func duplicateList(_ list: List, to: Int?, title: String?, picks: EditPicks,
                                makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        if title != nil { throw reject(.badValue, "a list's copy keeps its title; duplicate takes a number") }
        if picks.itemUuids != nil { throw reject(.badValue, "a list's copy has cues, not items") }
        let n: Int
        if let to {
            guard to >= 1 else { throw reject(.badValue, "a list number is 1 or more") }
            if library.list(number: to) != nil { throw reject(.duplicate, "list \(to) exists") }
            n = to
        } else {
            n = nextListNumber()
        }
        let uuid = picks.uuid ?? makeUUID()
        let cueUuids = picks.cueUuids ?? list.cues.map { _ in makeUUID() }
        guard cueUuids.count == list.cues.count else {
            throw reject(.badValue, "the copy needs \(list.cues.count) cue uuids, not \(cueUuids.count)")
        }
        if library.list(uuid: uuid) != nil { throw reject(.duplicate, "a list with uuid \(uuid.uuidString.lowercased()) exists") }
        var copy = list
        copy.uuid = uuid
        copy.number = n
        copy.version = 1
        copy.cues = zip(list.cues, cueUuids).map { cue, uuid in
            var c = cue
            c.uuid = uuid
            return c
        }
        try checkCueUuidsUnique(copy.cues)
        insertInOrder(copy)
        let folder = library.folder(ofList: list.uuid) ?? ""
        library.documentPaths[FileLayout.documentKey(list: uuid)] = FileLayout.freeListPath(for: copy, folder: folder, taken: takenListPaths(except: uuid))
        changes.append(.list(copy))
        return (EditCommand(.list(list.number), .duplicate(to: n, title: nil, picks: EditPicks(uuid: uuid, cueUuids: cueUuids))),
                EditCommand(.list(n), .delete))
    }

    /// Spec 7 §2 — "`edit list 42 folder "Worship/Hymns"` Moves the list's
    /// file into an existing folder; `""` moves it to the top"; "a move onto
    /// one [a name another file holds] is refused with `duplicate`"; "Moving a
    /// list or a folder is a rename on disk, not a save".
    mutating func moveList(_ list: List, to path: String) throws -> (EditCommand, EditCommand?) {
        let target = try resolveFolder(path)
        let current = library.folder(ofList: list.uuid) ?? ""
        let logged = EditCommand(.list(list.number), .folder(target))
        if target == current { return (logged, nil) }
        let key = FileLayout.documentKey(list: list.uuid)
        let from = library.documentPaths[key] ?? FileLayout.listPath(for: list, folder: current)
        let name = from.split(separator: "/").last.map(String.init) ?? ""
        let to = "lists/" + (target.isEmpty ? "" : target + "/") + name
        if takenListPaths(except: list.uuid).contains(to.lowercased()) {
            throw reject(.duplicate, "\(target.isEmpty ? "the top of the library" : "folder \"\(target)\"") already has a file named \(name)")
        }
        library.documentPaths[key] = to
        structure.append(.moveList(list.uuid, from: from, to: to))
        changes.append(.list(list))
        return (logged, EditCommand(.list(list.number), .folder(current)))
    }

    // MARK: - Cues

    /// Spec 1 §2 and §4 — a cue a list gains: its trigger and advance-after
    /// in range, and its commands (checks 4, 5 and 8).
    func checkCue(_ cue: Cue, old: Cue?) throws {
        try checkTrigger(cue.trigger)
        if let ms = cue.advanceAfterMs, ms < 0 { throw reject(.badValue, "advanceAfterMs is 0 or more") }
        try checkCueCommands(cue.commands, old: old?.commands ?? [])
    }

    /// Spec 1 §2 — `{type: "go"}`, `{type: "time", ms}`, or `{type: "timecode", tc}`.
    func checkTrigger(_ trigger: CueTrigger) throws {
        switch trigger.kind {
        case .go: break
        case .time(let ms):
            guard ms >= 0 else { throw reject(.badValue, "a Time trigger's ms is 0 or more") }
        case .timecode(let tc):
            let parts = tc.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, parts.allSatisfy({ $0.count == 2 && $0.allSatisfy(DurationText.isDigit) }) else {
                throw reject(.badValue, "a timecode is HH:MM:SS:FF, not \(tc)")
            }
        }
    }

    /// Spec 5 §6, check 6 — "a cue's uuid within its list" must be unique.
    func checkCueUuidsUnique(_ cues: [Cue]) throws {
        var seen: Set<UUID> = []
        for cue in cues where !seen.insert(cue.uuid).inserted {
            throw reject(.duplicate, "two cues share uuid \(cue.uuid.uuidString.lowercased())")
        }
    }

    /// Spec 5 §4 — `edit list 42 insert cues 2 {…}`: "Inserts a value into an
    /// array at a path and position"; the engine picks a missing uuid and the
    /// log records it. Spec 11 §4 — the app picks a new cue's uuid, "so a
    /// group can name the cue it inserts"; one its list has is `duplicate`.
    mutating func insertCue(_ index: Int, _ list: List, _ path: String, _ at: Int, _ value: JSONValue,
                            makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        guard path == "cues" else {
            try checkListPath(path)
            throw reject(.badValue, "insert puts a value into an array, and \(path) isn't one")
        }
        try position(at, upTo: list.cues.count, "the cue's")
        guard var object = value.objectValue else { throw reject(.badValue, "a cue is a JSON object") }
        let uuid: UUID
        if let text = object["uuid"] {
            guard let u = text.stringValue.flatMap(UUID.init(uuidString:)) else { throw reject(.badValue, "the cue's uuid is not a uuid") }
            uuid = u
        } else {
            uuid = makeUUID()
            object["uuid"] = .string(uuid.uuidString.lowercased())
        }
        let cue: Cue
        do {
            cue = try JSONCoding.decode(Cue.self, from: .object(object))
        } catch {
            throw reject(.badValue, "the cue did not read: \(JSONCoding.describe(error))")
        }
        try checkCue(cue, old: nil)
        if list.cues.contains(where: { $0.uuid == uuid }) {
            throw reject(.duplicate, "list \(list.number) already has a cue \(uuid.uuidString.lowercased())")
        }
        var updated = list
        updated.cues.insert(cue, at: at)
        library.lists[index] = updated
        changes.append(.list(updated, paths: ["cues"]))
        return (EditCommand(.list(list.number), .insert(path: "cues", at: at, value: .object(object))),
                EditCommand(.cue(list: list.number, cue: uuid), .remove(path: nil, at: nil)))
    }

    mutating func editCue(list number: Int, cue uuid: UUID, _ action: EditAction,
                          makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        let (listIndex, list) = try self.list(number)
        guard let cueIndex = list.cues.firstIndex(where: { $0.uuid == uuid }) else {
            throw reject(.unknownObject, "list \(number) has no cue \(uuid.uuidString.lowercased())")
        }
        let cue = list.cues[cueIndex]
        let address = EditAddress.cue(list: number, cue: uuid)
        var updated = list

        switch action {
        case .set(let path, let value):
            return try setCueField(listIndex, list, cueIndex, path, value)

        case .unset(let path):
            try checkCuePath(path)
            throw reject(.badValue, "a cue writes every field; set \(path) instead of removing it")

        case .insert(let path, let at, let value):
            guard path == "commands" else {
                try checkCuePath(path)
                throw reject(.badValue, "insert puts a value into an array, and \(path) isn't one")
            }
            try position(at, upTo: cue.commands.count, "the command's")
            let entry = try decodeCommand(value)
            try checkCueCommands([entry], old: [])
            updated.cues[cueIndex].commands.insert(entry, at: at)
            library.lists[listIndex] = updated
            changes.append(.cue(list, uuid, paths: ["commands"]))
            return (EditCommand(address, action), EditCommand(address, .remove(path: "commands", at: at)))

        case .remove(nil, nil):
            updated.cues.remove(at: cueIndex)
            library.lists[listIndex] = updated
            changes.append(.list(updated, paths: ["cues"]))
            return (EditCommand(address, action),
                    EditCommand(.list(number), .insert(path: "cues", at: cueIndex, value: encode(cue))))

        case .remove(let path?, let at?):
            guard path == "commands" else {
                try checkCuePath(path)
                throw reject(.badValue, "remove takes a child out of an array, and \(path) isn't one")
            }
            try position(at, upTo: cue.commands.count - 1, "the command's")
            let removed = updated.cues[cueIndex].commands.remove(at: at)
            library.lists[listIndex] = updated
            changes.append(.cue(list, uuid, paths: ["commands"]))
            return (EditCommand(address, action),
                    EditCommand(address, .insert(path: "commands", at: at, value: encode(removed))))

        case .move(nil, nil, let at):
            try position(at, upTo: list.cues.count - 1, "the cue's")
            if at == cueIndex { return (EditCommand(address, action), nil) }
            let moved = updated.cues.remove(at: cueIndex)
            updated.cues.insert(moved, at: at)
            library.lists[listIndex] = updated
            changes.append(.list(updated, paths: ["cues"]))
            return (EditCommand(address, action), EditCommand(address, .move(path: nil, from: nil, at: cueIndex)))

        case .move(let path?, let from?, let at):
            // Spec 5 §4 as Spec 11 corrected it — "a child without an address of
            // its own, such as a box or a cue's command, is named by its array's
            // path and its position".
            guard path == "commands" else {
                try checkCuePath(path)
                throw reject(.badValue, "move reorders an array, and \(path) isn't one")
            }
            try position(from, upTo: cue.commands.count - 1, "the command's")
            try position(at, upTo: cue.commands.count - 1, "the command's")
            if at == from { return (EditCommand(address, action), nil) }
            let moved = updated.cues[cueIndex].commands.remove(at: from)
            updated.cues[cueIndex].commands.insert(moved, at: at)
            library.lists[listIndex] = updated
            changes.append(.cue(list, uuid, paths: ["commands"]))
            return (EditCommand(address, action), EditCommand(address, .move(path: "commands", from: at, at: from)))

        case .duplicate(let to, let title, let picks):
            // Spec 5 §4 — "Copies a child to just after itself with new uuids".
            if to != nil || title != nil || picks.cueUuids != nil || picks.itemUuids != nil {
                throw reject(.badValue, "a cue's copy goes just after it; duplicate takes no number or title")
            }
            let copyUuid = picks.uuid ?? makeUUID()
            if list.cues.contains(where: { $0.uuid == copyUuid }) {
                throw reject(.duplicate, "list \(number) already has a cue \(copyUuid.uuidString.lowercased())")
            }
            var copy = cue
            copy.uuid = copyUuid
            updated.cues.insert(copy, at: cueIndex + 1)
            library.lists[listIndex] = updated
            changes.append(.list(updated, paths: ["cues"]))
            return (EditCommand(address, .duplicate(to: nil, title: nil, picks: EditPicks(uuid: copyUuid))),
                    EditCommand(.cue(list: number, cue: copyUuid), .remove(path: nil, at: nil)))

        case .cueChannel(let edit):
            return try cueChannel(listIndex, list, cueIndex, edit)

        case .remove, .move:
            throw reject(.badValue, "a remove or move by position names both the array's path and the position")
        case .section:
            throw reject(.badValue, "a section verb runs as the cue edits it makes")
        case .create, .delete, .renumber, .swap, .archive, .folder, .rename:
            throw reject(.badValue, "\(action.verb) does not apply to a cue" + (action.verb == "delete" ? "; remove it" : ""))
        }
    }

    /// Spec 7 §2 — cues "set `label`, `section`, `note`, `trigger` and
    /// `advanceAfterMs`"; Spec 5 §4 — "The raw command view can also set a
    /// cue's whole `commands` array as one value", and one command is set at
    /// `commands.N`. A path inside one command is not (Area 9's reading).
    func checkCuePath(_ path: String) throws {
        switch path {
        case "label", "section", "note", "trigger", "advanceAfterMs", "commands":
            return
        case "uuid":
            throw reject(.readOnlyField, "a cue's uuid is never edited")
        default:
            if path.hasPrefix("commands.") {
                if Int(path.dropFirst("commands.".count)) != nil { return }
                throw reject(.unknownPath, "set a whole command at commands.N, not a part of one")
            }
            throw reject(.unknownPath, "a cue has no field \(path)")
        }
    }

    func decodeCommand(_ value: JSONValue) throws -> GuardedCommand {
        guard value.objectValue != nil else { throw reject(.badValue, "a command is a JSON object") }
        do {
            return try JSONCoding.decode(GuardedCommand.self, from: value)
        } catch {
            throw reject(.badValue, "the command did not read: \(JSONCoding.describe(error))")
        }
    }

    mutating func setCueField(_ listIndex: Int, _ list: List, _ cueIndex: Int, _ path: String,
                              _ value: JSONValue) throws -> (EditCommand, EditCommand?) {
        try checkCuePath(path)
        let cue = list.cues[cueIndex]
        var updated = cue
        let previous: JSONValue
        switch path {
        case "label":
            previous = .string(cue.label)
            updated.label = try string(value, path)
        case "note":
            previous = .string(cue.note)
            updated.note = try string(value, path)
        case "section":
            previous = cue.section.map(JSONValue.string) ?? .null
            updated.section = try optionalString(value, path)
        case "trigger":
            previous = encode(cue.trigger)
            do {
                updated.trigger = try JSONCoding.decode(CueTrigger.self, from: value)
            } catch {
                throw reject(.badValue, "a trigger is {\"type\": \"go\"}, {\"type\": \"time\", \"ms\": N} or {\"type\": \"timecode\", \"tc\": \"HH:MM:SS:FF\"}")
            }
            try checkTrigger(updated.trigger)
        case "advanceAfterMs":
            previous = cue.advanceAfterMs.map { .number(Double($0)) } ?? .null
            if value.isNull {
                updated.advanceAfterMs = nil
            } else {
                guard let ms = value.intValue, ms >= 0 else { throw reject(.badValue, "advanceAfterMs is a whole number of ms, 0 or more, or null") }
                updated.advanceAfterMs = ms
            }
        case "commands":
            previous = .array(cue.commands.map { encode($0) })
            guard let items = value.arrayValue else { throw reject(.badValue, "commands is an array of command objects") }
            updated.commands = try items.map(decodeCommand)
            try checkCueCommands(updated.commands, old: cue.commands)
        default:
            let n = Int(path.dropFirst("commands.".count)) ?? -1
            guard n >= 0, n < cue.commands.count else { throw reject(.unknownPath, "the cue has no command at \(path)") }
            previous = encode(cue.commands[n])
            updated.commands[n] = try decodeCommand(value)
            try checkCueCommands([updated.commands[n]], old: [cue.commands[n]])
        }
        let address = EditAddress.cue(list: list.number, cue: cue.uuid)
        let logged = EditCommand(address, .set(path: path, value: value))
        guard updated != cue else { return (logged, nil) }
        var list = list
        list.cues[cueIndex] = updated
        library.lists[listIndex] = list
        changes.append(.cue(list, cue.uuid, paths: [path]))
        return (logged, EditCommand(address, .set(path: path, value: previous)))
    }

    // MARK: - Spec 5 §4, `edit.section`

    /// Spec 5 §4 — "Acts on the cue's section block, the run of consecutive
    /// cues that share its section label ... The engine runs it as one group
    /// of cue edits": `duplicate` inserts copies with new uuids after the
    /// block, `move` moves its cues one by one so the block's first cue ends at
    /// the position given, `remove` removes them. A cue without a section is a
    /// block of its own, and labels compare without regard to case, as section
    /// jumps do (Spec 3 §5). No edits for a move to where the block is.
    func expandSection(list number: Int, cue uuid: UUID, _ action: SectionAction,
                       makeUUID: () -> UUID) throws -> [EditCommand] {
        let (_, list) = try self.list(number)
        guard let index = list.cues.firstIndex(where: { $0.uuid == uuid }) else {
            throw reject(.unknownObject, "list \(number) has no cue \(uuid.uuidString.lowercased())")
        }
        let block = Editor.sectionBlock(list.cues, around: index)
        let uuids = block.map { list.cues[$0].uuid }
        switch action {
        case .duplicate:
            return block.enumerated().map { k, i in
                var copy = list.cues[i]
                copy.uuid = makeUUID()
                return EditCommand(.list(number), .insert(path: "cues", at: block.upperBound + k, value: encode(copy)))
            }
        case .move(let at):
            try position(at, upTo: list.cues.count - block.count, "the section's")
            if at == block.lowerBound { return [] }
            let moves = uuids.enumerated().map { k, u in EditCommand(.cue(list: number, cue: u), .move(path: nil, from: nil, at: at + k)) }
            return at > block.lowerBound ? moves.reversed() : moves
        case .remove:
            return uuids.map { EditCommand(.cue(list: number, cue: $0), .remove(path: nil, at: nil)) }
        }
    }

    static func sectionBlock(_ cues: [Cue], around index: Int) -> Range<Int> {
        guard let label = cues[index].section?.lowercased() else { return index..<(index + 1) }
        var low = index
        var high = index + 1
        while low > 0, cues[low - 1].section?.lowercased() == label { low -= 1 }
        while high < cues.count, cues[high].section?.lowercased() == label { high += 1 }
        return low..<high
    }

    // MARK: - Spec 5 §4, `edit.cueChannel`

    /// The commands of a cue that say something about one channel: its
    /// content (a write or a clear) and its standalone attribute writes.
    static func isChannelCommand(_ command: Command, channel: Int) -> Bool {
        switch command {
        case .channelWrite(let w): return w.channel == .number(channel)
        case .channelClear(.number(let n)): return n == channel
        default: return command.isStandaloneAttribute(channel: channel)
        }
    }

    /// Spec 5 §4 — "Sets everything a cue says about one channel. That is its
    /// content state (write with content and riders, clear, or hold ...) plus
    /// its standalone attribute writes ... Channel commands stay in
    /// channel-number order". The attribute writes go before the content
    /// command, where the channel's old commands were, or in channel-number
    /// order for a channel the cue didn't mention; the log records where
    /// (`at`). The inverse is the channel's previous state, or the cue's whole
    /// `commands` when that can't be put back by a channel edit.
    mutating func cueChannel(_ listIndex: Int, _ list: List, _ cueIndex: Int, _ edit: CueChannelEdit) throws -> (EditCommand, EditCommand?) {
        let cue = list.cues[cueIndex]
        let address = EditAddress.cue(list: list.number, cue: cue.uuid)
        let n = edit.channel
        guard edit.attributes.allSatisfy({ $0.isStandaloneAttribute(channel: n) }) else {
            throw reject(.badValue, "attributes holds channel \(n)'s grade, transition, audiotransition and gain writes")
        }
        var fresh = edit.attributes.map { GuardedCommand($0) }
        if case .write(let content, let riders) = edit.state {
            fresh.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(n), content: content, riders: riders))))
        } else if case .clear = edit.state {
            fresh.append(GuardedCommand(.channelClear(channel: .number(n))))
        }
        let oldIndices = cue.commands.indices.filter { Editor.isChannelCommand(cue.commands[$0].command, channel: n) }
        let old = oldIndices.map { cue.commands[$0] }
        try checkCueCommands(fresh, old: old)
        guard library.channel(n) != nil || context.restoring else {
            throw reject(.unknownReference, "channel \(n) does not exist")
        }
        let remaining = cue.commands.indices.filter { !oldIndices.contains($0) }.map { cue.commands[$0] }
        let at: Int
        if let given = edit.at {
            try position(given, upTo: remaining.count, "the channel's")
            at = given
        } else if let first = oldIndices.first {
            at = first
        } else {
            at = Editor.channelOrderPosition(remaining, channel: n)
        }
        var commands = remaining
        commands.insert(contentsOf: fresh, at: at)
        var logged = edit
        logged.at = at
        guard commands != cue.commands else { return (EditCommand(address, .cueChannel(logged)), nil) }
        var updated = list
        updated.cues[cueIndex].commands = commands
        library.lists[listIndex] = updated
        changes.append(.cue(list, cue.uuid, paths: ["commands"]))
        return (EditCommand(address, .cueChannel(logged)),
                Editor.previousChannelState(cue.commands, oldIndices: oldIndices, channel: n, address: address))
    }

    /// Where a channel the cue didn't mention goes: before the first command
    /// for a higher-numbered channel, else just after the last channel
    /// command, else at the end.
    static func channelOrderPosition(_ commands: [GuardedCommand], channel: Int) -> Int {
        var lastChannel: Int?
        for (i, entry) in commands.enumerated() {
            guard case .number(let c)? = entry.command.channelTarget else { continue }
            if c > channel { return i }
            lastChannel = i
        }
        return lastChannel.map { $0 + 1 } ?? commands.count
    }

    /// The inverse of a channel edit: a channel edit with the channel's old
    /// commands when they were together, the attribute writes before at most
    /// one content command, none with a guard or a key the vocabulary doesn't
    /// know; otherwise the cue's whole `commands` as they were.
    static func previousChannelState(_ commands: [GuardedCommand], oldIndices: [Int], channel: Int, address: EditAddress) -> EditCommand {
        let old = oldIndices.map { commands[$0] }
        let together = oldIndices.isEmpty || oldIndices == Array(oldIndices[0]..<(oldIndices[0] + oldIndices.count))
        let plain = old.allSatisfy { $0.when == nil && $0.extra.isEmpty }
        let attributes = old.prefix { $0.command.isStandaloneAttribute(channel: channel) }.map(\.command)
        let rest = old.dropFirst(attributes.count)
        var state: CueChannelState?
        switch rest.count {
        case 0:
            state = .hold
        case 1:
            switch rest.first?.command {
            case .channelWrite(let w)?: state = .write(w.content, w.riders)
            case .channelClear?: state = .clear
            default: state = nil
            }
        default:
            state = nil
        }
        if together, plain, let state {
            return EditCommand(address, .cueChannel(CueChannelEdit(channel: channel, state: state, attributes: attributes,
                                                                   at: oldIndices.first)))
        }
        return EditCommand(address, .set(path: "commands",
                                         value: .array(commands.map { (try? JSONCoding.encode($0)) ?? .null })))
    }
}
