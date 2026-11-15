// OCore — Spec 9 §6, the restore commands' rules.
//
// Pure: the roots, what the engine's worker read (a kept version, a
// snapshot) and what the engine knows of the versions kept, in; the roots
// after the restore, its log line and inverse, what changed and the file
// work, out. The engine reads the files and writes the result.

import Foundation

/// Spec 9 §6 — what a restore needs read before it can apply: "the reading,
/// checking and writing happen on a worker".
public enum RestoreKey: Hashable, Sendable {
    /// `library/versions/<list uuid>/vNNNN.json`.
    case version(list: UUID, version: Int)
    /// `machine/snapshots/<id>.zip`.
    case snapshot(String)
}

/// Spec 9 §6 — what the worker read for a restore.
public enum RestoreMaterial: Equatable, Sendable {
    /// A kept version's document, and every version kept for that list on
    /// disk when it was read.
    case version(List, kept: Set<Int>)
    /// A snapshot's contents, and the id of the snapshot taken "Before it
    /// replaces anything ... with reason `restore`", which "the inverse restores".
    case snapshot(Snapshot, before: String)
}

/// Spec 9 §6 — what the engine brings to a restore from outside the roots.
public struct RestoreInputs: Sendable {
    /// What the worker read, by what was asked of it; nil before it has
    /// been asked, when only the first checks can run.
    public var materials: [RestoreKey: Result<RestoreMaterial, Rejection>]?
    /// The versions kept for every list, as the engine knows them.
    public var kept: KeptVersions
    /// The lists whose edits aren't on disk yet.
    public var unwritten: Set<UUID>
    /// Spec 9 §7 — "`system snapshot` and the restore commands are refused with `diskFull`".
    public var diskFull: Bool

    public init(materials: [RestoreKey: Result<RestoreMaterial, Rejection>]? = nil, kept: KeptVersions = KeptVersions(),
                unwritten: Set<UUID> = [], diskFull: Bool = false) {
        self.materials = materials
        self.kept = kept
        self.unwritten = unwritten
        self.diskFull = diskFull
    }
}

/// Spec 9 §6 — "Two commands (G6), both run through the edit path as Spec 5
/// §9 says ... Each command is an edit group, logged with kind `edit` and its
/// inverse, undone and redone like any edit, and refused under operator lock".
public enum Restores {
    /// One applied restore: the roots after it, its line and inverse (none
    /// when it changed nothing), what changed for the `library` event, the
    /// file work, and its result's warnings.
    public struct Outcome: Equatable, Sendable {
        public var library: Library
        public var machine: Machine
        public var logged: Command
        public var inverse: Command?
        public var changes: [LibraryChange]
        public var structure: [StructureChange]
        public var warnings: [String]

        public var isNoop: Bool { inverse == nil }
    }

    // MARK: - First checks

    /// Spec 9 §6 — the checks that need nothing read: operator lock (Spec 5
    /// §7), the full disk (§7), and for a list its library mode and the list
    /// itself. What must be read for the rest, when they pass.
    public static func check(_ command: Command, library: Library, machine: Machine, inputs: RestoreInputs) -> Result<RestoreKey, Rejection> {
        if machine.settings.operatorLock.enabled {
            return .failure(Rejection(reason: .operatorLock, message: "the station is locked: restores wait until it is unlocked"))
        }
        switch command {
        case .systemRestoreList(let number, let version):
            // "Refused with ... `readOnlyLibrary` on a `readOnlyMasters` machine (Spec 5 §7)."
            if machine.settings.libraryMode == .readOnlyMasters {
                return .failure(Rejection(reason: .readOnlyLibrary,
                                          message: "this machine's masters are read-only (readOnlyMasters): a list is restored where the library is writable"))
            }
            if inputs.diskFull { return .failure(diskFull) }
            guard let list = library.list(number: number) else {
                // "Refused with `notInV1` for a local copy (Spec 5 §3)"; "Only lists that exist can be restored (choice G-11)".
                if machine.localLists.contains(where: { $0.number == number }) {
                    return .failure(Rejection(reason: .notInV1, message: "list \(number) is a local copy: restoring one comes with library mode, after v1"))
                }
                return .failure(Rejection(reason: .unknownObject,
                                          message: "list \(number) does not exist: a deleted list comes back by undo or a snapshot restore"))
            }
            guard version >= 0 else {
                return .failure(Rejection(reason: .unknownObject, message: "list \(number) has no version \(version)"))
            }
            return .success(.version(list: list.uuid, version: version))
        case .systemRestoreSnapshot(let id):
            if inputs.diskFull { return .failure(diskFull) }
            // The id names a file: nothing that could name another folder is one.
            guard SnapshotID.isPlausible(id) else {
                return .failure(Rejection(reason: .unknownObject, message: "there is no snapshot \"\(id)\""))
            }
            return .success(.snapshot(id))
        default:
            return .failure(Rejection(reason: .badValue, message: "\(command.cmd) is not a restore"))
        }
    }

    static var diskFull: Rejection {
        Rejection(reason: .diskFull, message: "the disk is full: nothing can be restored until there is space")
    }

    // MARK: - Applying

    /// Spec 9 §6 — one restore applied to the roots, with what the worker
    /// read for it. `state` is the live state, for `onAir`.
    public static func apply(_ command: Command, material: RestoreMaterial, library: Library, machine: Machine, state: ShowState?,
                             inputs: RestoreInputs) -> Result<Outcome, Rejection> {
        switch (command, material) {
        case (.systemRestoreList(let number, let version), .version(let kept, let onDisk)):
            return list(number: number, version: version, kept: kept, onDisk: onDisk, library: library, machine: machine, inputs: inputs)
        case (.systemRestoreSnapshot(let id), .snapshot(let snapshot, let before)):
            return self.snapshot(snapshot, id: id, before: before, library: library, machine: machine, state: state)
        default:
            return .failure(Rejection(reason: .conflict, message: "what was read is not what \(command.cmd) restores"))
        }
    }

    // MARK: - A list version

    /// Spec 9 §6, "A list version" — "Everything in the version comes back
    /// but the list's number, uuid and folder, which stay as they are now,
    /// and its `version`, which goes above every kept one ... The current
    /// document is kept as a version first, whatever E-3's ten minutes say
    /// (Spec 1 §4), in the same write as the restored list and ahead of it.
    /// The inverse restores that version."
    ///
    /// The current document is kept under its own `version` when its file
    /// holds it (no unwritten edits) and that number isn't kept already;
    /// otherwise under the next number above every kept one, so no kept
    /// file is ever written over. The restored list keeps a `version` at or
    /// above every kept one in memory, and its save takes the next (Spec 1
    /// §4, `SavePlanner`).
    static func list(number: Int, version: Int, kept: List, onDisk: Set<Int>, library: Library, machine: Machine,
                     inputs: RestoreInputs) -> Result<Outcome, Rejection> {
        guard let index = library.lists.firstIndex(where: { $0.number == number }) else {
            return .failure(Rejection(reason: .unknownObject, message: "list \(number) does not exist"))
        }
        let current = library.lists[index]
        // "The version is the file with that list's uuid and `version` V".
        guard kept.uuid == current.uuid, !kept.isLocalCopy else {
            return .failure(Rejection(reason: .unknownObject, message: "list \(number) has no version \(version)"))
        }
        let known = onDisk.union(inputs.kept.lists[current.uuid]?.keys.map { $0 } ?? [])
        let highest = known.max() ?? 0
        let ownNumber = !inputs.unwritten.contains(current.uuid) && !known.contains(current.version)
        let keepAs = ownNumber ? current.version : max(highest, current.version) + 1

        var restored = kept
        restored.number = current.number
        restored.uuid = current.uuid
        restored.version = max(current.version, keepAs, highest)
        var before = current
        before.version = keepAs

        var out = library
        out.lists[index] = restored
        return .success(Outcome(library: out, machine: machine, logged: .systemRestoreList(list: number, version: version),
                                inverse: .systemRestoreList(list: number, version: keepAs), changes: [.list(restored)],
                                structure: [.keepVersion(list: current.uuid, version: keepAs, data: Writer.data(for: .list(before)))],
                                warnings: []))
    }

    // MARK: - A snapshot

    /// Spec 9 §6, "A snapshot" — "It replaces the documents people author
    /// with the snapshot's copies. It leaves alone the machine's setup, so a
    /// restore during a service never moves an output, and the media
    /// indexes, which the walk keeps true to the files (choice G-5)":
    ///
    /// | Replaced | Left as they are |
    /// | --- | --- |
    /// | `library.json`, channels, text styles, grades, transitions, audio transitions, presets, portable macros, the lists and their folders | `machine.json`, stacks, outputs, audio outputs, inputs and clocks |
    /// | Key bindings and the scheduler, machine macros, playlists (archived ones too) and local copies | Both media indexes |
    ///
    /// Checked in this order: the snapshot is of this library and every
    /// document in it reads (`badValue`); no numbered object was renumbered
    /// since (`conflict`); no channel that would go is on air (`onAir`); the
    /// channel list is the same (`notInV1` until Area 14, Adam's answer of
    /// 2026-11-14). "On a `readOnlyMasters` machine only the machine
    /// documents are replaced, and the result warns that the library was
    /// left as it was (choice G-7)."
    static func snapshot(_ snapshot: Snapshot, id: String, before: String, library: Library, machine: Machine,
                         state: ShowState?) -> Result<Outcome, Rejection> {
        // "A snapshot of another library is refused with `badValue`."
        let mine = library.info.uuid.uuidString.lowercased()
        guard snapshot.documents["library/" + FileLayout.path(for: .library(library.info))] != nil else {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\" holds no library.json: it isn't a snapshot of this library"))
        }
        // "Each document is read as the loader reads it, migrations included (Spec 1 §8); one the app
        // can't read refuses the restore with `badValue`, naming it."
        let theirLibrary = Loader.library(from: snapshot.root("library"))
        let theirMachine = Loader.machine(from: snapshot.root("machine"))
        let unreadable: Set<IssueCode> = [.malformedJSON, .schemaTooNew, .schemaTooOld, .unreadableDocument]
        if let issue = theirLibrary.report.issues.first(where: { unreadable.contains($0.code) }) {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\": library/\(issue.file ?? issue.subject) can't be read: \(issue.message)"))
        }
        if let issue = theirMachine.report.issues.first(where: { unreadable.contains($0.code) }) {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\": machine/\(issue.file ?? issue.subject) can't be read: \(issue.message)"))
        }
        let theirs = (library: theirLibrary.library, machine: theirMachine.machine)
        let named = snapshot.manifest.library ?? mine
        guard named == mine, theirs.library.info.uuid == library.info.uuid else {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\" is of another library"))
        }

        // "Every numbered object that both the snapshot and the two roots now hold, matched by uuid,
        // must have the same number in both ... a renumber or a swap since the snapshot refuses the
        // restore with `conflict`, naming the objects".
        let moved = renumbered(theirs: theirs, library: library, machine: machine)
        guard moved.isEmpty else {
            return .failure(Rejection(reason: .conflict,
                                      message: "renumbered since snapshot \"\(id)\": \(moved.joined(separator: ", ")); renumber them back, or restore a later snapshot"))
        }

        let libraryStays = machine.settings.libraryMode == .readOnlyMasters
        if !libraryStays {
            let now = Dictionary(library.channels.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
            let then = Dictionary(theirs.library.channels.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
            let removed = now.keys.filter { then[$0] == nil }.sorted()
            // "A restore that would delete a channel with content in a stack an output shows is refused
            // with `onAir`, as Spec 5 §6 refuses that delete".
            if let state, let live = removed.first(where: { onAir($0, state: state, machine: machine) }) {
                return .failure(Rejection(reason: .onAir, message: "channel \(live) has content in a stack an output shows, and snapshot \"\(id)\" doesn't have it"))
            }
            // Adam's answer of 2026-11-14 — a snapshot that adds, removes or resizes a channel is
            // refused until Area 14 rebuilds the channels between ticks.
            var differs = removed.map { "channel \($0) removed" }
            differs += then.keys.filter { now[$0] == nil }.sorted().map { "channel \($0) added" }
            differs += now.keys.filter { then[$0].map { $0.renderSize != now[$0.number]?.renderSize } ?? false }.sorted().map { "channel \($0) resized" }
            guard differs.isEmpty else {
                return .failure(Rejection(reason: .notInV1,
                                          message: "snapshot \"\(id)\" has other channels (\(differs.joined(separator: ", "))): a restore that changes the channel list comes with Area 14"))
            }
        }

        var structure: [StructureChange] = []
        var changes: [LibraryChange] = []
        var warnings: [String] = []
        var newLibrary = library
        if libraryStays {
            warnings.append("the library was left as it was: this machine's masters are read-only (readOnlyMasters)")
        } else {
            newLibrary = restoredLibrary(theirs.library, over: library, structure: &structure, changes: &changes)
        }
        let newMachine = restoredMachine(theirs.machine, over: machine, structure: &structure, changes: &changes)

        // A snapshot that holds what the roots hold changes nothing.
        guard newLibrary != library || newMachine != machine || !structure.isEmpty else {
            return .success(Outcome(library: library, machine: machine, logged: .systemRestoreSnapshot(id: id), inverse: nil, changes: [],
                                    structure: [], warnings: warnings))
        }
        return .success(Outcome(library: newLibrary, machine: newMachine, logged: .systemRestoreSnapshot(id: id),
                                inverse: .systemRestoreSnapshot(id: before), changes: LibraryChange.merged(changes), structure: structure,
                                warnings: warnings))
    }

    /// Whether a channel has content in a stack an output shows.
    static func onAir(_ channel: Int, state: ShowState, machine: Machine) -> Bool {
        guard let content = state.channels[channel]?.content, content != .empty else { return false }
        return machine.outputs.contains { output in
            let stack = state.outputs[output.number] ?? output.defaultStack
            return machine.stack(stack)?.slots.contains { $0.channel == channel } ?? false
        }
    }

    /// The numbered objects both hold, by uuid, whose numbers differ: `channel 3 (2 in the snapshot)`.
    static func renumbered(theirs: (library: Library, machine: Machine), library: Library, machine: Machine) -> [String] {
        var out: [String] = []
        func compare(_ name: String, _ then: [(UUID, Int)], _ now: [(UUID, Int)]) {
            let numbers = Dictionary(then, uniquingKeysWith: { first, _ in first })
            for (uuid, number) in now.sorted(by: { $0.1 < $1.1 }) {
                if let was = numbers[uuid], was != number { out.append("\(name) \(number) (\(was) in the snapshot)") }
            }
        }
        compare("channel", theirs.library.channels.map { ($0.uuid, $0.number) }, library.channels.map { ($0.uuid, $0.number) })
        compare("preset", theirs.library.presets.map { ($0.uuid, $0.number) }, library.presets.map { ($0.uuid, $0.number) })
        compare("text style", theirs.library.textStyles.map { ($0.uuid, $0.number) }, library.textStyles.map { ($0.uuid, $0.number) })
        compare("grade", theirs.library.grades.map { ($0.uuid, $0.number) }, library.grades.map { ($0.uuid, $0.number) })
        compare("transition", theirs.library.transitions.map { ($0.uuid, $0.number) }, library.transitions.map { ($0.uuid, $0.number) })
        compare("audio transition", theirs.library.audioTransitions.map { ($0.uuid, $0.number) },
                library.audioTransitions.map { ($0.uuid, $0.number) })
        compare("macro", (theirs.library.macros + theirs.machine.macros).map { ($0.uuid, $0.number) },
                (library.macros + machine.macros).map { ($0.uuid, $0.number) })
        compare("list", theirs.library.lists.map { ($0.uuid, $0.number) }, library.lists.map { ($0.uuid, $0.number) })
        compare("local copy", theirs.machine.localLists.map { ($0.uuid, $0.number) }, machine.localLists.map { ($0.uuid, $0.number) })
        compare("stack", theirs.machine.stacks.map { ($0.uuid, $0.number) }, machine.stacks.map { ($0.uuid, $0.number) })
        compare("output", theirs.machine.outputs.map { ($0.uuid, $0.number) }, machine.outputs.map { ($0.uuid, $0.number) })
        compare("audio output", theirs.machine.audioOutputs.map { ($0.uuid, $0.number) }, machine.audioOutputs.map { ($0.uuid, $0.number) })
        compare("input", theirs.machine.inputs.map { ($0.uuid, $0.number) }, machine.inputs.map { ($0.uuid, $0.number) })
        return out
    }

    // MARK: - The library's documents

    /// The library after the restore: the snapshot's `library.json`,
    /// catalogs, presets, portable macros, lists and folders; this
    /// library's media index, and the files under `lists/` that aren't
    /// lists, which stay where they are with the folders that hold them.
    static func restoredLibrary(_ theirs: Library, over library: Library, structure: inout [StructureChange],
                                changes: inout [LibraryChange]) -> Library {
        var out = theirs
        out.mediaIndex = library.mediaIndex
        out.documentExtras[.mediaIndex] = library.documentExtras[.mediaIndex]
        out.otherFiles = library.otherFiles
        out.documentPaths = [:]

        // Folders: the snapshot's, and any that still holds a file that isn't a list
        // ("Removed only when nothing visible is left in it", the plan's reading).
        var folders = Set(theirs.folders)
        for file in library.otherFiles {
            var path = ""
            for part in FileLayout.folder(ofListPath: file).split(separator: "/") {
                path += (path.isEmpty ? "" : "/") + part
                folders.insert(path)
            }
        }
        out.folders = folders.sorted()
        let had = Set(library.folders)
        for folder in out.folders where !had.contains(folder) {
            structure.append(.makeFolder(folder))
            changes.append(.folder(folder))
        }

        // The single documents and the catalogs, object by object.
        if theirs.info != library.info { changes.append(LibraryChange(object: "library", address: [:])) }
        numbered("channel", library.channels.map { ($0.number, $0) }, theirs.channels.map { ($0.number, $0) }, &changes)
        numbered("textstyle", library.textStyles.map { ($0.number, $0) }, theirs.textStyles.map { ($0.number, $0) }, &changes)
        numbered("grade", library.grades.map { ($0.number, $0) }, theirs.grades.map { ($0.number, $0) }, &changes)
        numbered("transition", library.transitions.map { ($0.number, $0) }, theirs.transitions.map { ($0.number, $0) }, &changes)
        numbered("audiotransition", library.audioTransitions.map { ($0.number, $0) }, theirs.audioTransitions.map { ($0.number, $0) }, &changes)
        numbered("preset", library.presets.map { ($0.number, $0) }, theirs.presets.map { ($0.number, $0) }, &changes)
        numbered("macro", library.macros.map { ($0.number, $0) }, theirs.macros.map { ($0.number, $0) }, &changes)

        // Presets and portable macros: one file each, by number.
        for preset in theirs.presets { out.documentPaths["preset/\(preset.number)"] = library.documentPaths["preset/\(preset.number)"] }
        for preset in library.presets where theirs.preset(preset.number) == nil {
            if let path = library.documentPaths["preset/\(preset.number)"] { structure.append(.removeDocument(.preset(preset.number), path: path)) }
        }
        for macro in theirs.macros { out.documentPaths["macro/\(macro.number)"] = library.documentPaths["macro/\(macro.number)"] }
        for macro in library.macros where theirs.macro(macro.number) == nil {
            if let path = library.documentPaths["macro/\(macro.number)"] { structure.append(.removeDocument(.libraryMacro(macro.number), path: path)) }
        }

        // Lists: "a list made since ... is deleted" first, so the names they held are free.
        var taken = library.otherFiles
        for list in library.lists {
            let key = FileLayout.documentKey(list: list.uuid)
            guard theirs.list(uuid: list.uuid) == nil else {
                if let path = library.documentPaths[key] { taken.insert(path) }
                continue
            }
            if let path = library.documentPaths[key] { structure.append(.removeList(list.uuid, path: path)) }
            changes.append(.list(list))
        }
        for (index, list) in theirs.lists.enumerated() {
            let key = FileLayout.documentKey(list: list.uuid)
            let folder = theirs.documentPaths[key].map(FileLayout.folder(ofListPath:)) ?? ""
            guard let current = library.list(uuid: list.uuid) else {
                // "or comes back with its uuid": a new file, in the folder the snapshot had it in.
                let path = FileLayout.freeListPath(for: list, folder: folder, taken: taken)
                out.documentPaths[key] = path
                taken.insert(path)
                changes.append(.list(list))
                continue
            }
            // Its `version` never goes down: the save takes the next above every kept one.
            out.lists[index].version = max(list.version, current.version)
            let here = library.documentPaths[key]
            if let here, FileLayout.folder(ofListPath: here) != folder {
                taken.remove(here)
                let path = FileLayout.freeListPath(for: list, folder: folder, taken: taken)
                out.documentPaths[key] = path
                taken.insert(path)
                structure.append(.moveList(list.uuid, from: here, to: path))
                changes.append(.list(out.lists[index]))
            } else {
                out.documentPaths[key] = here ?? FileLayout.freeListPath(for: list, folder: folder, taken: taken)
                if out.lists[index] != current { changes.append(.list(out.lists[index])) }
            }
        }
        // Folders the snapshot doesn't list, the deepest first, once their lists have gone.
        for folder in library.folders.sorted(by: >) where !folders.contains(folder) {
            structure.append(.removeFolder(folder))
            changes.append(.folder(folder))
        }
        return out
    }

    // MARK: - The machine's documents

    /// The machine after the restore: the snapshot's key bindings and
    /// scheduler, machine macros, playlists and local copies; everything
    /// else of this machine as it is.
    static func restoredMachine(_ theirs: Machine, over machine: Machine, structure: inout [StructureChange],
                                changes: inout [LibraryChange]) -> Machine {
        var out = machine
        out.keys = theirs.keys
        out.documentExtras[.keys] = theirs.documentExtras[.keys]
        if out.keys != machine.keys || out.documentExtras[.keys] != machine.documentExtras[.keys] {
            changes.append(LibraryChange(object: "keys", address: [:]))
        }

        out.macros = theirs.macros
        numbered("macro", machine.macros.map { ($0.number, $0) }, theirs.macros.map { ($0.number, $0) }, &changes)
        for macro in machine.macros where theirs.macro(macro.number) == nil {
            if let path = out.documentPaths.removeValue(forKey: "macro/\(macro.number)") {
                structure.append(.removeDocument(.machineMacro(macro.number), path: path))
            }
        }

        // Playlists, "archived ones too": whole documents, by uuid.
        out.playlists = theirs.playlists
        for playlist in machine.playlists where theirs.playlist(uuid: playlist.uuid) == nil {
            let key = FileLayout.documentKey(playlist: playlist.uuid)
            let path = out.documentPaths.removeValue(forKey: key) ?? FileLayout.plainPath(forPlaylist: playlist)
            structure.append(.removePlaylist(playlist.uuid, path: path))
            changes.append(.playlist(playlist.uuid))
        }
        for playlist in theirs.playlists {
            let key = FileLayout.documentKey(playlist: playlist.uuid)
            guard let current = machine.playlist(uuid: playlist.uuid) else {
                changes.append(.playlist(playlist.uuid))
                continue
            }
            guard current != playlist else { continue }
            changes.append(.playlist(playlist.uuid))
            // Spec 7 §3 — a file "keeps [its name] until the title changes": a title that came back names its file again.
            if FileLayout.plainPath(forPlaylist: current) != FileLayout.plainPath(forPlaylist: playlist) { out.documentPaths.removeValue(forKey: key) }
        }

        // Local copies, by uuid.
        out.localLists = theirs.localLists
        for list in machine.localLists where theirs.localList(uuid: list.uuid) == nil {
            let key = "local/" + list.uuid.uuidString.lowercased()
            if let path = out.documentPaths.removeValue(forKey: key) { structure.append(.removeDocument(.localList(list.uuid), path: path)) }
            changes.append(LibraryChange(object: "list", address: ["local": .string(list.uuid.uuidString.lowercased())]))
        }
        for list in theirs.localLists where machine.localList(uuid: list.uuid) != list {
            changes.append(LibraryChange(object: "list", address: ["local": .string(list.uuid.uuidString.lowercased())]))
        }
        return out
    }

    /// One `changed` entry per numbered object that differs, came or went.
    static func numbered<T: Equatable>(_ name: String, _ now: [(Int, T)], _ then: [(Int, T)], _ changes: inout [LibraryChange]) {
        let before = Dictionary(now, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(then, uniquingKeysWith: { first, _ in first })
        for number in Set(before.keys).union(after.keys).sorted() where before[number] != after[number] {
            changes.append(LibraryChange(object: name, address: [name: .number(Double(number))]))
        }
    }
}

/// Spec 9 §3 — "The id is the local date and time to the second,
/// `2026-11-08-085959`, with `-2` and on added for a second snapshot in the
/// same second."
public enum SnapshotID {
    /// Whether a string could be a snapshot's id: a file's name and nothing
    /// that names another folder. Ids come from commands and file listings.
    public static func isPlausible(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 100, !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A)
                || value == 0x2D || value == 0x5F || value == 0x2E
        } && !id.contains("..")
    }

    /// The id for a snapshot stamped `stamp`, given the ids taken: the stamp,
    /// or the first free of `-2`, `-3` and on.
    public static func free(_ stamp: String, taken: Set<String>) -> String {
        guard taken.contains(stamp) else { return stamp }
        var n = 2
        while taken.contains(stamp + "-\(n)") { n += 1 }
        return stamp + "-\(n)"
    }

    /// An id as its stamp and the number after it: `2026-11-08-085959-2` is
    /// the second of its second. Ids sort by these, newest last.
    public static func order(_ id: String) -> (stamp: String, number: Int) {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 5, let number = Int(parts[4]) else { return (id, 1) }
        return (parts[0...3].joined(separator: "-"), number)
    }

    /// Ids oldest first.
    public static func sorted(_ ids: [String]) -> [String] {
        ids.sorted { order($0) < order($1) }
    }
}
