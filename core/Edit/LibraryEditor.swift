// OCore — Spec 5 §2–§7, the edit path's checks and changes, for the edits
// Area 9 builds: lists, cues, folders and playlists (Spec 7 §7).
//
// Pure, like the projection: the roots in, the roots out, nothing read from a
// clock or a disk. The engine runs it on the control thread and hands what it
// changed to the writer.

import Foundation

/// Spec 5 §6 — what an edit is checked and applied against besides the roots.
public struct EditContext: Sendable {
    /// The live state: "The live playlist can't be archived in place while it
    /// is live (Spec 7 §5)".
    public var state: ShowState?
    /// Spec 7 §5 — "the day it runs in the machine's time zone, written
    /// `2026-11-01`", for archive's dated title.
    public var today: String
    /// Spec 5 §6, check 5 — "an undo or redo puts back exactly what was
    /// there, broken references included": references are not checked, and an
    /// inverse may put back a local item (Spec 7 §3). Area 12's undo sets it.
    public var restoring: Bool
    /// Spec 5 §6, check 8 — a held edit "is validated when its holder is
    /// saved": checked without lock and library mode, and never applied.
    var dryRun: Bool

    public init(state: ShowState? = nil, today: String = "", restoring: Bool = false) {
        self.state = state
        self.today = today
        self.restoring = restoring
        self.dryRun = false
    }
}

/// Spec 5 §2 — one entry of the `library` event's `changed`: "The event
/// names what changed and carries no object bodies". The object, its address
/// and the paths that changed, none when the whole object did (created,
/// deleted, renumbered or moved).
public struct LibraryChange: Equatable, Sendable {
    public var object: String
    public var address: [String: JSONValue]
    public var paths: [String]

    public init(object: String, address: [String: JSONValue], paths: [String] = []) {
        self.object = object
        self.address = address
        self.paths = paths
    }

    /// `{ "object": "cue", "list": 42, "cue": "22bb…", "paths": ["commands"] }`.
    public var json: JSONValue {
        var members = address
        members["object"] = .string(object)
        members["paths"] = .array(paths.map { .string($0) })
        return .object(members)
    }

    static func list(_ list: List, paths: [String] = []) -> LibraryChange {
        LibraryChange(object: "list", address: ["list": .number(Double(list.number)), "listUuid": .string(list.uuid.uuidString.lowercased())],
                      paths: paths)
    }

    static func cue(_ list: List, _ cue: UUID, paths: [String] = []) -> LibraryChange {
        LibraryChange(object: "cue", address: ["list": .number(Double(list.number)), "listUuid": .string(list.uuid.uuidString.lowercased()),
                                               "cue": .string(cue.uuidString.lowercased())], paths: paths)
    }

    static func folder(_ path: String) -> LibraryChange {
        LibraryChange(object: "folder", address: ["folder": .string(path)])
    }

    static func playlist(_ uuid: UUID, paths: [String] = []) -> LibraryChange {
        LibraryChange(object: "playlist", address: ["playlist": .string(uuid.uuidString.lowercased())], paths: paths)
    }

    static func item(_ playlist: UUID, _ item: UUID, paths: [String] = []) -> LibraryChange {
        LibraryChange(object: "item", address: ["playlist": .string(playlist.uuidString.lowercased()),
                                                "item": .string(item.uuidString.lowercased())], paths: paths)
    }
}

/// Spec 5 §2 — "An edit that changes where a file lives does so in the same
/// write": the file operations that aren't a save of one document's content,
/// in the order they happen. Spec 7 §2 — "Moving a list or a folder is a
/// rename on disk, not a save". Paths are relative to their root: under
/// `lists/` for folders and lists, `playlists/` for playlists.
public enum StructureChange: Equatable, Sendable {
    case makeFolder(String)
    case renameFolder(from: String, to: String)
    case removeFolder(String)
    case moveList(UUID, from: String, to: String)
    case removeList(UUID, path: String)
    case removePlaylist(UUID, path: String)
}

/// Spec 5 §4 and §6 — one applied edit: the roots after it, the command as
/// the log records it ("the logged command records what it picked"), its
/// inverse (none for a `noop`), what changed for the `library` event, the
/// file operations it makes, and its result's `warnings`.
public struct EditOutcome: Equatable, Sendable {
    public var library: Library
    public var machine: Machine
    public var logged: EditCommand
    public var inverse: EditCommand?
    public var changes: [LibraryChange]
    public var structure: [StructureChange]
    public var warnings: [String]

    /// Spec 5 §4 — "a value equal to the current one is a `noop`".
    public var isNoop: Bool { inverse == nil }
}

/// Spec 5 §6 — "An edit is checked in this order. The first failure rejects
/// it, and nothing changes": lock and library mode, the object, the path,
/// the value, references, uniqueness, protected objects, structure.
public enum LibraryEditor {
    /// Spec 5 §6 — check one edit and apply it to the roots. A section verb
    /// gives one outcome per cue edit it runs ("The engine runs it as one
    /// group of cue edits", Spec 5 §4), all or none; every other edit one.
    /// `makeUUID` makes the uuids an edit picks; the log records them.
    public static func apply(_ edit: EditCommand, library: Library, machine: Machine, context: EditContext,
                             makeUUID: () -> UUID = { UUID() }) -> Result<[EditOutcome], Rejection> {
        var editor = Editor(library: library, machine: machine, context: context)
        do {
            try editor.checkLockAndMode(edit)
            if case .section(let action) = edit.action, case .cue(let list, let cue) = edit.address {
                let expanded = try editor.expandSection(list: list, cue: cue, action, makeUUID: makeUUID)
                guard !expanded.isEmpty else {
                    return .success([EditOutcome(library: library, machine: machine, logged: edit, inverse: nil,
                                                 changes: [], structure: [], warnings: [])])
                }
                var outcomes: [EditOutcome] = []
                var roots = (library, machine)
                for sub in expanded {
                    var step = Editor(library: roots.0, machine: roots.1, context: context)
                    let (logged, inverse) = try step.apply(sub, makeUUID: makeUUID)
                    outcomes.append(step.outcome(logged: logged, inverse: inverse))
                    roots = (step.library, step.machine)
                }
                return .success(outcomes)
            }
            let (logged, inverse) = try editor.apply(edit, makeUUID: makeUUID)
            return .success([editor.outcome(logged: logged, inverse: inverse)])
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(Rejection(reason: .badValue, message: "\(error)"))
        }
    }

    /// Spec 7 §2 — "A number the engine picks, for a list or any other type,
    /// is one more than the highest of that type in use or named by any
    /// reference, so a new object never takes over references meant for a
    /// deleted one."
    public static func nextListNumber(library: Library, machine: Machine) -> Int {
        let editor = Editor(library: library, machine: machine, context: EditContext())
        return editor.nextListNumber()
    }
}

/// The edit in progress: the roots it changes, and what it records.
struct Editor {
    var library: Library
    var machine: Machine
    let context: EditContext
    var changes: [LibraryChange] = []
    var structure: [StructureChange] = []
    var warnings: [String] = []

    init(library: Library, machine: Machine, context: EditContext) {
        self.library = library
        self.machine = machine
        self.context = context
    }

    func outcome(logged: EditCommand, inverse: EditCommand?) -> EditOutcome {
        EditOutcome(library: library, machine: machine, logged: logged, inverse: inverse,
                    changes: inverse == nil ? [] : changes, structure: inverse == nil ? [] : structure, warnings: warnings)
    }

    func reject(_ reason: RejectionReason, _ message: String) -> Rejection {
        Rejection(reason: reason, message: message)
    }

    // MARK: - The objects

    mutating func apply(_ edit: EditCommand, makeUUID: () -> UUID) throws -> (EditCommand, EditCommand?) {
        switch edit.address {
        case .list(let number): return try editList(number, edit.action, makeUUID: makeUUID)
        case .cue(let list, let cue): return try editCue(list: list, cue: cue, edit.action, makeUUID: makeUUID)
        case .folder(let path): return try editFolder(path, edit.action)
        case .playlist(let uuid): return try editPlaylist(uuid, edit.action, makeUUID: makeUUID)
        case .item(let playlist, let item): return try editItem(playlist: playlist, item: item, edit.action)
        case .numbered(let type, _):
            switch type {
            case .channel, .preset, .textStyle, .grade, .transition, .audioTransition, .macro, .stack:
                throw reject(.notInV1, "\(type.displayName) edits come with Area 14")
            case .output:
                throw reject(.notInV1, "output edits come with Areas 14 and 17")
            case .audioOutput:
                throw reject(.notInV1, "audio output edits come with Area 17")
            case .input:
                throw reject(.notInV1, "input edits come with live inputs, after v1")
            case .list:
                throw reject(.unknownObject, "a list is named list N")
            }
        case .slot: throw reject(.notInV1, "stack edits come with Area 14")
        case .key, .keys: throw reject(.notInV1, "key binding edits come with Area 17")
        case .machine: throw reject(.notInV1, "machine settings edits come with Area 17")
        case .media: throw reject(.notInV1, "media edits come with Area 8")
        }
    }

    // MARK: - Check 1, lock and library mode (Spec 5 §7)

    /// Spec 5 §7 — "While the lock is on, the engine refuses every `edit`
    /// ... with code `operatorLock`"; "On a `readOnlyMasters` machine it
    /// refuses edits of library objects with code `readOnlyLibrary`: lists and
    /// their cues, library folders, channels, presets, text styles, grades,
    /// transitions, audio transitions, portable macros and the defaults of
    /// library media ... Machine-level edits pass".
    func checkLockAndMode(_ edit: EditCommand) throws {
        guard !context.dryRun else { return }
        if machine.settings.operatorLock.enabled {
            throw reject(.operatorLock, "the station is locked: edits wait until it is unlocked")
        }
        if machine.settings.libraryMode == .readOnlyMasters, isLibraryObject(edit.address) {
            throw reject(.readOnlyLibrary, "this machine's masters are read-only (readOnlyMasters): \(edit.address.object) edits are made where the library is writable")
        }
    }

    func isLibraryObject(_ address: EditAddress) -> Bool {
        switch address {
        case .list, .cue, .folder: return true
        case .numbered(let type, let number):
            switch type {
            case .channel, .preset, .textStyle, .grade, .transition, .audioTransition, .list: return true
            case .macro: return number.map { library.macro($0) != nil || machine.macro($0) == nil } ?? true
            case .stack, .output, .audioOutput, .input: return false
            }
        case .media(let id): return library.mediaIndex.entries.contains { $0.id == id }
        case .playlist, .item, .slot, .key, .keys, .machine: return false
        }
    }

    // MARK: - Check 4, values

    func string(_ value: JSONValue, _ what: String) throws -> String {
        guard let s = value.stringValue else { throw reject(.badValue, "\(what) is a string, not \(CommandPrinter.valueText(value))") }
        return s
    }

    func optionalString(_ value: JSONValue, _ what: String) throws -> String? {
        if value.isNull { return nil }
        return try string(value, what)
    }

    func bool(_ value: JSONValue, _ what: String) throws -> Bool {
        guard let b = value.boolValue else { throw reject(.badValue, "\(what) is true or false, not \(CommandPrinter.valueText(value))") }
        return b
    }

    func encode<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONCoding.encode(value)) ?? .null
    }

    /// Spec 5 §3 — "Positions in paths and in `insert`, `remove` and `move`
    /// count from 0, as JSON arrays do." `upTo` is the last position allowed.
    func position(_ at: Int, upTo last: Int, _ what: String) throws {
        guard at >= 0, at <= last else {
            throw reject(.badValue, "\(what) position \(at) is outside 0…\(max(last, 0))")
        }
    }

    // MARK: - Checks 4, 5 and 8 for commands a cue holds

    /// Spec 5 §6, check 4 — "When an edit changes a cue's commands, commands
    /// kept verbatim because they are unknown (Spec 1 §6) pass through
    /// unchanged; only the commands the edit adds or changes are validated."
    func checkCueCommands(_ new: [GuardedCommand], old: [GuardedCommand]) throws {
        var unchanged = old
        for entry in new {
            if let i = unchanged.firstIndex(of: entry) {
                unchanged.remove(at: i)
                continue
            }
            try checkCueCommand(entry)
        }
    }

    /// One command a cue gains: in the vocabulary (check 4), with no guard
    /// (Spec 2 §7, "rejected by the v1 validator"), its numbers on this
    /// machine (check 5, a portable document's machine-level numbers
    /// excepted), its macros free of cycles (check 8), and an edit it holds
    /// "validated when its holder is saved, like any edit" (check 8).
    func checkCueCommand(_ entry: GuardedCommand) throws {
        if entry.command.isUnknown || entry.command.isInvalid {
            throw reject(.badValue, "\(entry.command.cmd): " + (entry.command.invalidReason ?? "not in the vocabulary"))
        }
        if case .edit(let held) = entry.command {
            if entry.when != nil { throw reject(.badValue, "a guard on a cue command is reserved in v1 and does not run") }
            var dry = context
            dry.dryRun = true
            if case .failure(var rejection) = LibraryEditor.apply(held, library: library, machine: machine, context: dry) {
                rejection.message = "the edit the cue holds: " + rejection.message
                if context.restoring, rejection.reason == .unknownObject || rejection.reason == .unknownReference { return }
                throw rejection
            }
            return
        }
        let validation = ValidationContext(library: library, machine: machine, state: nil,
                                           source: CommandSource(kind: .cue), portable: true)
        guard let rejection = CommandValidator.validate(entry.command, guard: entry.when, context: validation) else { return }
        let mapped = Editor.editCode(rejection.reason)
        if context.restoring, mapped == .unknownReference { return }
        throw reject(mapped, rejection.message)
    }

    /// Spec 5 §6 — the command validator's reasons as the edit path's codes.
    static func editCode(_ reason: RejectionReason) -> RejectionReason {
        switch reason {
        case .noSuchTarget, .noSuchReference, .unknownMedia: return .unknownReference
        case .macroCycle, .macroDepth: return .cycle
        default: return .badValue
        }
    }

    // MARK: - Numbers (Spec 7 §2, Spec 5 §4 and §6)

    /// Every list number something refers to: the commands of every cue,
    /// macro and key binding (a held edit among them), and every playlist link.
    /// With `byNumberOnly`, only what reaches a list by its number: a link that
    /// records its list's uuid follows the uuid (Spec 7 §3).
    func listNumbersReferenced(byNumberOnly: Bool = false) -> [Int] {
        var numbers: [Int] = []
        func visit(_ entries: [GuardedCommand]) {
            for entry in entries { entry.command.forEachReference(of: .list) { numbers.append($0) } }
        }
        for list in library.lists + machine.localLists { for cue in list.cues { visit(cue.commands) } }
        for macro in library.macros + machine.macros { visit(macro.commands) }
        for key in machine.keys { key.command.forEachReference(of: .list) { numbers.append($0) } }
        for playlist in machine.playlists {
            for item in playlist.items {
                guard case .linked(let n, let listUuid) = item.kind else { continue }
                if !byNumberOnly || listUuid == nil { numbers.append(n) }
            }
        }
        return numbers
    }

    func nextListNumber() -> Int {
        max(library.lists.map(\.number).max() ?? 0, listNumbersReferenced().max() ?? 0) + 1
    }
}
