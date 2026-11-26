// OCore — Spec 5 §4 and §6 for the numbered objects edit mode edits (Spec 7
// §7, Spec 11 §11): what every one of them shares. A part is set, unset,
// inserted, removed or moved at a path; an object is created, duplicated,
// deleted, renumbered or swapped. The rules of each type are beside its shelf.

import Foundation

/// Spec 1 §2 — "Every one has `number` (integer, unique within its type,
/// gaps allowed), `label` (display string, never used for lookup) and `uuid`
/// (stable through renumbering ...)"; Spec 1 §3 — "The same `number`,
/// `label`, `uuid` rule applies."
protocol NumberedObject: Codable, Equatable, Sendable {
    var number: Int { get set }
    var label: String { get set }
    var uuid: UUID { get set }
}

extension Channel: NumberedObject {}
extension Stack: NumberedObject {}
extension Preset: NumberedObject {}
extension TextStyle: NumberedObject {}
extension Grade: NumberedObject {}
extension Transition: NumberedObject {}
extension AudioTransition: NumberedObject {}
extension Macro: NumberedObject {}
extension Output: NumberedObject {}

/// What one type adds to the shared edits.
struct ObjectRules<T: NumberedObject> {
    /// Spec 5 §6, check 7 — why the object can't be deleted or renumbered now
    /// (`protected`, `onAir`), or nil. `verb` is "deleted" or "renumbered".
    var held: (Editor, T, String) -> Rejection? = { _, _, _ in nil }
    /// The same for a swap, "a swap checking both objects".
    var heldPair: (Editor, T, T) -> Rejection? = { _, _, _ in nil }
    /// Parts that are named another way, refused before the path is read.
    var part: (Editor, T, EditAction) throws -> Void = { _, _, _ in }
    /// Checks 6 and 8 and the warnings, once the changed object reads; `old`
    /// is nil for a new one. It may adjust the object (a copy's `builtIn`).
    var settled: (inout Editor, T?, inout T) throws -> Void = { _, _, _ in }
    /// Whether the type's objects can be made and copied; every type's can since Spec 11 §9 was corrected on
    /// 2026-11-25 to let transitions be made (G-38).
    var makes = true
    /// Spec 1 §5 — the key of a per-file document's path (`preset`), nil for a catalog's objects.
    var document: String?
}

/// Where one type's objects are kept, its field table, and what a new one starts as.
struct Shelf<T: NumberedObject> {
    var type: NumberedType
    var table: EditField
    var read: (Editor) -> [T]
    var write: (inout Editor, [T]) -> Void
    /// Spec 5 §4 — "Without a body it takes the type's defaults and a fresh uuid".
    var fresh: (Int, UUID) -> T
    var rules = ObjectRules<T>()
}

extension Editor {
    // MARK: - The shelves

    /// Spec 11 §7 — "New Channel (`edit channel create`, with the first-run
    /// channels' defaults, Spec 6 §9, and an empty label". What the three
    /// first-run channels share: decoder cap 2, Preset 1, audio output 1,
    /// `largest`; `usualContent` is theirs alone, so a new one takes `any`.
    static var channels: Shelf<Channel> {
        var rules = ObjectRules<Channel>()
        rules.held = { editor, channel, verb in
            guard let state = editor.live else { return nil }
            if OnAir.showing(channel.number, state: state, machine: editor.machine) {
                return Rejection(reason: .onAir, message: "channel \(channel.number) has content in a stack an output shows; clear it before it is \(verb)")
            }
            if OnAir.sounding(channel.number, state: state, library: editor.library, machine: editor.machine) {
                return Rejection(reason: .onAir, message: "channel \(channel.number) is sounding on an audio output; clear it before it is \(verb)")
            }
            return nil
        }
        rules.heldPair = { editor, a, b in
            guard let state = editor.live else { return nil }
            // Spec 11 §7 — "Swap while either channel has content and either is in a stack an output shows".
            let content = OnAir.hasContent(a.number, state: state) || OnAir.hasContent(b.number, state: state)
            let shown = OnAir.inShownStack(a.number, state: state, machine: editor.machine)
                || OnAir.inShownStack(b.number, state: state, machine: editor.machine)
            if content, shown {
                return Rejection(reason: .onAir, message: "channels \(a.number) and \(b.number) can't swap while one holds content and one is in a stack an output shows")
            }
            for channel in [a, b] where OnAir.sounding(channel.number, state: state, library: editor.library, machine: editor.machine) {
                return Rejection(reason: .onAir, message: "channel \(channel.number) is sounding on an audio output; clear it before the swap")
            }
            return nil
        }
        return Shelf(type: .channel, table: EditFields.channel, read: { $0.library.channels }, write: { $0.library.channels = $1 },
                     fresh: { Channel(number: $0, label: "", decoderCap: 2, uuid: $1, defaultPreset: 1, audioOutputs: [1], renderSize: .largest,
                                      usualContent: .any) },
                     rules: rules)
    }

    static var textStyles: Shelf<TextStyle> {
        Shelf(type: .textStyle, table: EditFields.textStyle, read: { $0.library.textStyles }, write: { $0.library.textStyles = $1 },
              fresh: { TextStyle(number: $0, label: "", uuid: $1, values: TextStyleValues()) })
    }

    static var grades: Shelf<Grade> {
        Shelf(type: .grade, table: EditFields.grade, read: { $0.library.grades }, write: { $0.library.grades = $1 },
              fresh: { Grade(number: $0, label: "", uuid: $1) })
    }

    /// Spec 5 §6, check 7 — "Preset 1 and Transitions 1–3 can't be deleted,
    /// renumbered or swapped, though both stay editable". Spec 11 §9 as
    /// corrected 2026-11-25 — "New (a 500 ms dissolve), Duplicate, Renumber…
    /// and Delete as for grades, but for transitions 1–3, which ship built in
    /// and stay protected ... 1–3 keep their [type] (`protected`)".
    static var transitions: Shelf<Transition> {
        var rules = ObjectRules<Transition>()
        rules.held = { _, transition, verb in
            (1...3).contains(transition.number)
                ? Rejection(reason: .protected, message: "transition \(transition.number) is built in: it can be edited, not \(verb)") : nil
        }
        rules.heldPair = { _, a, b in
            [a, b].first { (1...3).contains($0.number) }.map {
                Rejection(reason: .protected, message: "transition \($0.number) is built in: it can be edited, not swapped")
            }
        }
        rules.settled = { editor, old, transition in
            // A new one or a copy is never built in.
            if old == nil { transition.builtIn = false }
            if let old, (1...3).contains(old.number), old.type != transition.type {
                throw editor.reject(.protected, "transition \(old.number) is built in: it keeps its type, \(old.type.rawValue)")
            }
        }
        return Shelf(type: .transition, table: EditFields.transition, read: { $0.library.transitions }, write: { $0.library.transitions = $1 },
                     fresh: { Transition(number: $0, type: .dissolve, ms: 500, uuid: $1) }, rules: rules)
    }

    /// Spec 11 §9 — "New, Duplicate and Delete as for grades, the type picked
    /// from cut, crossfade and fade through silence."
    static var audioTransitions: Shelf<AudioTransition> {
        Shelf(type: .audioTransition, table: EditFields.audioTransition, read: { $0.library.audioTransitions },
              write: { $0.library.audioTransitions = $1 },
              fresh: { AudioTransition(number: $0, type: .cut, ms: 0, offsetMs: 0, label: "", uuid: $1, easing: .linear) })
    }

    // MARK: - Dispatch

    /// Spec 7 §7 — "Area 14 for what edit mode edits (channels, stacks,
    /// presets, text styles, grades, transitions, audio transitions, macros,
    /// and an output's default stack and transitions, Spec 11 §11), Area 17
    /// for settings (the rest of outputs, audio outputs, keys and the machine)".
    mutating func editNumbered(_ type: NumberedType, _ number: Int?, _ action: EditAction,
                               makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        switch type {
        case .channel: return try edit(Editor.channels, number, action, makeUUID: makeUUID)
        case .textStyle: return try edit(Editor.textStyles, number, action, makeUUID: makeUUID)
        case .grade: return try edit(Editor.grades, number, action, makeUUID: makeUUID)
        case .transition: return try edit(Editor.transitions, number, action, makeUUID: makeUUID)
        case .audioTransition: return try edit(Editor.audioTransitions, number, action, makeUUID: makeUUID)
        case .stack: return try edit(Editor.stacks, number, action, makeUUID: makeUUID)
        case .preset: return try edit(Editor.presets, number, action, makeUUID: makeUUID)
        case .macro: return try editMacro(number, action, makeUUID: makeUUID)
        case .output: return try editOutput(number, action)
        case .audioOutput: throw reject(.notInV1, "audio output edits come with Area 17")
        case .input: throw reject(.notInV1, "input edits come with live inputs, after v1")
        case .list: throw reject(.unknownObject, "a list is named list N")
        }
    }

    // MARK: - One object

    mutating func edit<T: NumberedObject>(_ shelf: Shelf<T>, _ number: Int?, _ action: EditAction,
                                         makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        let type = shelf.type
        if case .create(let body, let folder, let title) = action {
            if folder != nil || title != nil { throw reject(.badValue, "a \(type.displayName) has no folder or title") }
            return try create(shelf, number, body: body, makeUUID: makeUUID)
        }
        guard let number else { throw reject(.badValue, "name the \(type.displayName) by its number") }
        var all = shelf.read(self)
        guard let index = all.firstIndex(where: { $0.number == number }) else {
            throw reject(.unknownObject, "\(type.displayName) \(number) does not exist")
        }
        let object = all[index]
        let address = EditAddress.numbered(type, number)
        let logged = EditCommand(address, action)

        switch action {
        case .set, .unset, .insert, .remove(_?, _?), .move(_?, _?, _):
            try shelf.rules.part(self, object, action)
            let part = try editPart(action, table: shelf.table, tree: encode(object), of: "\(type.displayName) \(number)", owner: type)
            guard let inverse = part.inverse else { return (logged, nil) }
            var updated: T = try read(part.tree, "\(type.displayName) \(number)")
            try shelf.rules.settled(&self, object, &updated)
            guard updated != object else { return (logged, nil) }
            all[index] = updated
            shelf.write(&self, all)
            changes.append(Editor.changed(type, number, [part.path]))
            return (logged, EditCommand(address, inverse))

        case .delete:
            if let rejection = shelf.rules.held(self, object, "deleted") { throw rejection }
            warnOfReferences(to: type, number)
            all.remove(at: index)
            shelf.write(&self, all)
            if let key = shelf.rules.document, let path = library.documentPaths.removeValue(forKey: "\(key)/\(number)"), type == .preset {
                structure.append(.removeDocument(.preset(number), path: path))
            }
            changes.append(Editor.changed(type, number))
            return (logged, EditCommand(address, .create(body: encode(object), folder: nil, title: nil)))

        case .renumber(let to):
            guard to >= 1 else { throw reject(.badValue, "a \(type.displayName) number is 1 or more") }
            if to == number { return (logged, nil) }
            if Identity.exists(type, to, library, machine) {
                throw reject(.duplicate, "\(type.displayName) \(to) exists; swap the two instead")
            }
            if let rejection = shelf.rules.held(self, object, "renumbered") { throw rejection }
            try refuseAdopting(type, to)
            let before = (library: library, machine: machine)
            _ = Identity.renumber(type, from: number, to: to, library: &library, machine: &machine)
            moveDocumentPaths(shelf.rules.document, [number: to])
            warnOfPortableReferences(to: type, [number, to])
            changes.append(Editor.changed(type, to))
            changes += rewritten(since: before, besides: type)
            return (logged, EditCommand(.numbered(type, to), .renumber(to: number)))

        case .swap(let other):
            guard other >= 1 else { throw reject(.badValue, "a \(type.displayName) number is 1 or more") }
            if other == number { return (logged, nil) }
            guard let second = all.first(where: { $0.number == other }) else {
                throw reject(.unknownObject, "\(type.displayName) \(other) does not exist")
            }
            if let rejection = shelf.rules.heldPair(self, object, second) { throw rejection }
            let before = (library: library, machine: machine)
            _ = Identity.swap(type, number, other, library: &library, machine: &machine)
            moveDocumentPaths(shelf.rules.document, [number: other, other: number])
            warnOfPortableReferences(to: type, [number, other])
            changes.append(Editor.changed(type, other))
            changes.append(Editor.changed(type, number))
            changes += rewritten(since: before, besides: type)
            return (logged, EditCommand(address, .swap(with: other)))

        case .duplicate(let to, let title, let picks):
            guard shelf.rules.makes else { throw reject(.notInV1, "new \(type.displayName)s wait for the transition editor, after v1") }
            if title != nil || picks.cueUuids != nil || picks.itemUuids != nil {
                throw reject(.badValue, "a \(type.displayName)'s copy takes a number and nothing else")
            }
            let n = try freeNumber(type, to)
            let uuid = picks.uuid ?? makeUUID()
            if all.contains(where: { $0.uuid == uuid }) {
                throw reject(.duplicate, "a \(type.displayName) with uuid \(uuid.uuidString.lowercased()) exists")
            }
            var copy = object
            copy.number = n
            copy.uuid = uuid
            try shelf.rules.settled(&self, nil, &copy)
            all.insert(copy, at: all.firstIndex { $0.number > n } ?? all.count)
            shelf.write(&self, all)
            changes.append(Editor.changed(type, n))
            return (EditCommand(address, .duplicate(to: n, title: nil, picks: EditPicks(uuid: uuid))),
                    EditCommand(.numbered(type, n), .delete))

        case .remove, .move:
            throw reject(.badValue, "a remove or move by position names both the array's path and the position")
        case .create, .archive, .section, .folder, .rename, .cueChannel:
            throw reject(.badValue, "\(action.verb) does not apply to a \(type.displayName)")
        }
    }

    /// Spec 5 §4 — create: "Creates a numbered object at a free number ...
    /// Without a body it takes the type's defaults and a fresh uuid"; a
    /// body's fields win, so a delete's inverse brings an object back whole.
    /// "`create` keeps its picks where they live": the number in the address,
    /// the uuid in the body.
    mutating func create<T: NumberedObject>(_ shelf: Shelf<T>, _ number: Int?, body: JSONValue?,
                                           makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        let type = shelf.type
        guard shelf.rules.makes else { throw reject(.notInV1, "new \(type.displayName)s wait for the transition editor, after v1") }
        let n = try freeNumber(type, number)
        let (tree, logged) = try newObject(type, n, body: body, fresh: { encode(shelf.fresh(n, $0)) }, makeUUID: makeUUID)
        if let problem = shelf.table.problem(with: tree) { throw reject(.badValue, "the \(type.displayName) \(problem)") }
        var object: T = try read(tree, "the \(type.displayName)")
        var all = shelf.read(self)
        if all.contains(where: { $0.uuid == object.uuid }) {
            throw reject(.duplicate, "a \(type.displayName) with uuid \(object.uuid.uuidString.lowercased()) exists")
        }
        try checkReferences(shelf.table.references(in: tree), in: type, at: "the \(type.displayName)")
        try shelf.rules.settled(&self, nil, &object)
        all.insert(object, at: all.firstIndex { $0.number > n } ?? all.count)
        shelf.write(&self, all)
        changes.append(Editor.changed(type, n))
        return (EditCommand(.numbered(type, n), .create(body: logged, folder: nil, title: nil)), EditCommand(.numbered(type, n), .delete))
    }

    // MARK: - The pieces the objects share

    /// Spec 5 §2 — one entry of the event's `changed` for a numbered object:
    /// `{ "object": "channel", "channel": 2, "paths": ["label"] }`.
    static func changed(_ type: NumberedType, _ number: Int, _ paths: [String] = []) -> LibraryChange {
        LibraryChange(object: type.editWord, address: [type.editWord: .number(Double(number))], paths: paths)
    }

    func read<T: Decodable>(_ tree: JSONValue, _ what: String) throws -> T {
        do {
            return try JSONCoding.decode(T.self, from: tree)
        } catch {
            throw reject(.badValue, "\(what) did not read: \(JSONCoding.describe(error))")
        }
    }

    /// Spec 5 §6, check 6 — "a number within its type": the number given, if
    /// it is free, or the one the engine picks, "one more than the highest of
    /// that type in use or named by any reference" (Spec 5 §4).
    func freeNumber(_ type: NumberedType, _ given: Int?) throws -> Int {
        if let given {
            guard given >= 1 else { throw reject(.badValue, "a \(type.displayName) number is 1 or more") }
            if Identity.exists(type, given, library, machine) {
                throw reject(.duplicate, "\(type.displayName) \(given) exists; pick another number")
            }
            return given
        }
        var highest = References.numbers(of: type, library: library, machine: machine).max() ?? 0
        for number in numbers(of: type) { highest = max(highest, number) }
        return highest + 1
    }

    func numbers(of type: NumberedType) -> [Int] {
        switch type {
        case .channel: return library.channels.map(\.number)
        case .preset: return library.presets.map(\.number)
        case .textStyle: return library.textStyles.map(\.number)
        case .grade: return library.grades.map(\.number)
        case .transition: return library.transitions.map(\.number)
        case .audioTransition: return library.audioTransitions.map(\.number)
        case .macro: return library.macros.map(\.number) + machine.macros.map(\.number)
        case .list: return library.lists.map(\.number)
        case .stack: return machine.stacks.map(\.number)
        case .output: return machine.outputs.map(\.number)
        case .audioOutput: return machine.audioOutputs.map(\.number)
        case .input: return machine.inputs.map(\.number)
        }
    }

    /// A new object's JSON form and the body the log records: the type's
    /// defaults under the body's fields, with the number and the uuid.
    func newObject(_ type: NumberedType, _ n: Int, body: JSONValue?, fresh: (UUID) -> JSONValue,
                   makeUUID: () -> UUID) throws -> (tree: JSONValue, logged: JSONValue) {
        if let body, body.objectValue == nil { throw reject(.badValue, "a \(type.displayName)'s body is a JSON object") }
        let given = body?.objectValue ?? [:]
        if let bodyNumber = given["number"], bodyNumber.intValue != n {
            throw reject(.badValue, "the body's number \(CommandPrinter.valueText(bodyNumber)) is not \(n)")
        }
        let uuid: UUID
        if let text = given["uuid"] {
            guard let u = text.stringValue.flatMap(UUID.init(uuidString:)) else { throw reject(.badValue, "the body's uuid is not a uuid") }
            uuid = u
        } else {
            uuid = makeUUID()
        }
        var members = fresh(uuid).objectValue ?? [:]
        for (key, value) in given { members[key] = value }
        members["number"] = .number(Double(n))
        members["uuid"] = .string(uuid.uuidString.lowercased())
        var logged = given
        logged["uuid"] = .string(uuid.uuidString.lowercased())
        return (.object(members), .object(logged))
    }

    /// Spec 5 §6, check 5 — "Every number the value names exists on this
    /// machine ... An edit never creates one [a broken reference]", with its
    /// exceptions: "an undo or redo puts back exactly what was there", and "a
    /// portable document may name a stack, output, audio output or input this
    /// machine lacks, since it meets those numbers at other campuses".
    func checkReferences(_ named: [(type: NumberedType, number: Int)], in owner: NumberedType, at what: String) throws {
        guard !context.restoring else { return }
        for reference in named {
            if !owner.isMachineLevel, reference.type.isMachineLevel { continue }
            guard Identity.exists(reference.type, reference.number, library, machine) else {
                throw reject(.unknownReference, "\(what) names \(reference.type.displayName) \(reference.number), which doesn't exist")
            }
        }
    }

    /// The references in `new` that `old` didn't have: what the edit adds.
    func added(_ field: EditField, new: JSONValue, old: JSONValue?) -> [(type: NumberedType, number: Int)] {
        var before = old.map { field.references(in: $0) } ?? []
        var out: [(type: NumberedType, number: Int)] = []
        for reference in field.references(in: new) {
            if let index = before.firstIndex(where: { $0.type == reference.type && $0.number == reference.number }) {
                before.remove(at: index)
            } else {
                out.append(reference)
            }
        }
        return out
    }

    /// Spec 5 §6 — the result warns of "an object deleted while still referenced".
    mutating func warnOfReferences(to type: NumberedType, _ number: Int) {
        let named = References.to(type, number, library: library, machine: machine).count
        if named > 0 {
            warnings.append("\(type.displayName) \(number) is still named by \(named) reference\(named == 1 ? "" : "s"), which the reference report flags")
        }
    }

    /// Spec 5 §6, check 6 — "`renumber` and `swap` also refuse a number that
    /// broken references still name". For a machine-level object, the
    /// portable references to that number aren't broken: they meet it by
    /// number, here as at every campus (Spec 5 §4).
    func refuseAdopting(_ type: NumberedType, _ number: Int) throws {
        let named = References.to(type, number, library: library, machine: machine).filter { !(type.isMachineLevel && $0.site.isPortable) }
        if !named.isEmpty {
            throw reject(.danglingReferences,
                         "references still name \(type.displayName) \(number), which doesn't exist; renumbering onto it would take them over")
        }
    }

    /// Spec 5 §4 — a machine-level renumber "returns a warning listing the
    /// portable references that now name something else on this machine".
    mutating func warnOfPortableReferences(to type: NumberedType, _ numbers: [Int]) {
        guard type.isMachineLevel else { return }
        for number in numbers {
            let named = References.to(type, number, library: library, machine: machine).filter(\.site.isPortable)
            guard !named.isEmpty else { continue }
            let places = named.prefix(6).map(\.site.words).joined(separator: ", ") + (named.count > 6 ? " and \(named.count - 6) more" : "")
            warnings.append("\(named.count) reference\(named.count == 1 ? "" : "s") in the library still name\(named.count == 1 ? "s" : "") \(type.displayName) \(number), which is another \(type.displayName) on this machine now, or none: \(places)")
        }
    }

    /// Spec 1 §5 — "the loader ... renames the file to match on save": a
    /// per-file document's path follows its number, so the writer renames it.
    mutating func moveDocumentPaths(_ key: String?, _ map: [Int: Int]) {
        guard let key else { return }
        func moved(_ paths: [String: String]) -> [String: String] {
            var out = paths
            for from in map.keys { out["\(key)/\(from)"] = nil }
            for (from, to) in map {
                if let path = paths["\(key)/\(from)"] { out["\(key)/\(to)"] = path }
            }
            return out
        }
        library.documentPaths = moved(library.documentPaths)
        machine.documentPaths = moved(machine.documentPaths)
    }

    /// Spec 5 §2 — "The event names what changed": the documents whose
    /// references a renumber or swap rewrote, besides the object itself, so a
    /// client asks again for a list whose cues now name another number.
    func rewritten(since before: (library: Library, machine: Machine), besides type: NumberedType) -> [LibraryChange] {
        var out: [LibraryChange] = []
        func objects<T: NumberedObject>(_ kind: NumberedType, _ old: [T], _ new: [T]) {
            guard kind != type else { return }
            let was = Dictionary(old.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
            for object in new where was[object.uuid] != object {
                let then = was[object.uuid].map { encode($0).objectValue ?? [:] } ?? [:]
                let now = encode(object).objectValue ?? [:]
                out.append(Editor.changed(kind, object.number, now.keys.filter { now[$0] != then[$0] }.sorted()))
            }
        }
        objects(.channel, before.library.channels, library.channels)
        objects(.preset, before.library.presets, library.presets)
        objects(.textStyle, before.library.textStyles, library.textStyles)
        objects(.macro, before.library.macros + before.machine.macros, library.macros + machine.macros)
        let masters = Dictionary(before.library.lists.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for list in library.lists where masters[list.uuid] != list { out.append(.list(list, paths: ["cues"])) }
        objects(.stack, before.machine.stacks, machine.stacks)
        objects(.output, before.machine.outputs, machine.outputs)
        let locals = Dictionary(before.machine.localLists.map { ($0.uuid, $0) }, uniquingKeysWith: { first, _ in first })
        for list in machine.localLists where locals[list.uuid] != list {
            out.append(LibraryChange(object: "list", address: ["local": .string(list.uuid.uuidString.lowercased())], paths: ["cues"]))
        }
        if before.machine.audioOutputs != machine.audioOutputs {
            for audio in machine.audioOutputs where before.machine.audioOutput(audio.number) != audio {
                out.append(Editor.changed(.audioOutput, audio.number, ["device"]))
            }
        }
        if before.machine.keys != machine.keys { out.append(LibraryChange(object: "keys", address: [:])) }
        if before.library.mediaIndex != library.mediaIndex || before.machine.mediaLocal != machine.mediaLocal {
            let old = Dictionary((before.library.mediaIndex.entries + before.machine.mediaLocal.entries).map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
            for entry in library.mediaIndex.entries + machine.mediaLocal.entries where old[entry.id] != entry {
                out.append(LibraryChange(object: "media", address: ["media": .string(entry.id)], paths: ["defaults"]))
            }
        }
        if before.machine.settings != machine.settings { out.append(LibraryChange(object: "machine", address: [:])) }
        return out
    }

    // MARK: - A part, at a path (Spec 5 §4: set, unset, insert, remove, move)

    /// One edit of a part of an object, on the object's JSON form: the form
    /// after it, its inverse (nil for a `noop`) and the path that changed.
    func editPart(_ action: EditAction, table: EditField, tree: JSONValue, of what: String,
                  owner: NumberedType) throws -> (tree: JSONValue, inverse: EditAction?, path: String) {
        func located(_ text: String) throws -> (EditPath, EditPlace) {
            guard let path = EditPath(text) else { throw reject(.unknownPath, "\(text) isn't a path: field names joined by dots") }
            // Spec 5 §6, check 3 — "`uuid`, `schema`, `app`, `kind`, `version`, `builtIn` and `number` never are; numbers
            // change only through `renumber` and `swap`."
            if let first = path.components.first, EditFields.neverEdited.contains(first) {
                throw reject(.readOnlyField, "\(what)'s \(first) is never edited" + (first == "number" ? "; renumber it instead" : ""))
            }
            do {
                let place = try table.place(path, in: tree)
                if place.readOnly { throw reject(.readOnlyField, "\(what)'s \(text) is never edited") }
                return (path, place)
            } catch EditPathError.unknown(let component) {
                throw reject(.unknownPath, "\(what) has no \(text)" + (component == text ? "" : " (at \(component))"))
            }
        }
        func items(_ text: String, _ verb: String) throws -> (EditPath, EditField, [JSONValue]) {
            let (path, place) = try located(text)
            guard case .list(let element) = place.field.shape(of: place.value), let items = place.value?.arrayValue else {
                throw reject(.badValue, "\(verb), and \(text) isn't an array")
            }
            return (path, element, items)
        }

        switch action {
        case .set(let text, let value):
            let (path, place) = try located(text)
            if let problem = place.field.problem(with: value) {
                throw reject(.badValue, "\(text) \(problem), not \(CommandPrinter.valueText(value))")
            }
            if place.value == value { return (tree, nil, text) }
            try checkReferences(added(place.field, new: value, old: place.value), in: owner, at: "\(what)'s \(text)")
            let inverse: EditAction = place.value.map { .set(path: text, value: $0) } ?? .unset(path: text)
            return (tree.replacing(path.components[...], with: value), inverse, text)

        case .unset(let text):
            let (path, place) = try located(text)
            switch place.parent {
            case .map, .record(optionalKey: true): break
            case .root, .record, .list: throw reject(.badValue, "\(what) writes \(text); set it instead of removing it")
            }
            guard let old = place.value else { return (tree, nil, text) }
            return (tree.removing(path.components[...]), .set(path: text, value: old), text)

        case .insert(let text, let at, let value):
            let (path, element, list) = try items(text, "insert puts a value into an array")
            try position(at, upTo: list.count, "\(text)'s")
            if let problem = element.problem(with: value) { throw reject(.badValue, "what goes into \(text) \(problem)") }
            try checkReferences(element.references(in: value), in: owner, at: "\(what)'s \(text)")
            var updated = list
            updated.insert(value, at: at)
            return (tree.replacing(path.components[...], with: .array(updated)), .remove(path: text, at: at), text)

        case .remove(let text?, let at?):
            let (path, _, list) = try items(text, "remove takes a child out of an array")
            try position(at, upTo: list.count - 1, "\(text)'s")
            var updated = list
            let removed = updated.remove(at: at)
            return (tree.replacing(path.components[...], with: .array(updated)), .insert(path: text, at: at, value: removed), text)

        case .move(let text?, let from?, let at):
            let (path, _, list) = try items(text, "move reorders an array")
            try position(from, upTo: list.count - 1, "\(text)'s")
            try position(at, upTo: list.count - 1, "\(text)'s")
            if from == at { return (tree, nil, text) }
            var updated = list
            updated.insert(updated.remove(at: from), at: at)
            return (tree.replacing(path.components[...], with: .array(updated)), .move(path: text, from: at, at: from), text)

        default:
            throw reject(.badValue, "\(action.verb) does not name a part of \(what)")
        }
    }
}

extension Reference.Site {
    /// The place in a few words, for a warning.
    var words: String {
        switch self {
        case .channel(let n, let field): return "channel \(n)'s \(field)"
        case .stack(let n, let field): return "stack \(n)'s \(field)"
        case .slot(let stack, let channel, let field): return "stack \(stack) slot \(channel)'s \(field)"
        case .layout(let preset, let layout): return "preset \(preset)'s layout for stack \(layout.string)"
        case .box(let preset, let layout, let box, let field): return "preset \(preset) layout \(layout.string) box \(box)'s \(field)"
        case .output(let n, let field): return "output \(n)'s \(field)"
        case .audioOutput(let n, let field): return "audio output \(n)'s \(field)"
        case .cue(let place, _): return "\(place.local ? "local copy" : "list") \(place.list) cue \(place.number)"
        case .macro(let n, _, _): return "macro \(n)"
        case .key(let device, let key, _): return key.map { "the \(device) key \($0)" } ?? "a \(device) entry"
        case .media(let id, _, let field): return "\(id.prefix(15))…'s \(field)"
        case .machine(let field): return "the machine's \(field)"
        }
    }
}
