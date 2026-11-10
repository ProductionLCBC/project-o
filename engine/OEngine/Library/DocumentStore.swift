// OEngine — Spec 5 §2, writing: the control thread's side of the writer.

import Foundation
import OCore

/// Spec 5 §2 — "The engine writes a changed document with Spec 1 §5's atomic
/// write within one second of each change, and at most once a second ...
/// Typing therefore writes at most once a second, and the last keystroke
/// always lands." The control thread's bookkeeping: which documents have
/// unwritten edits, when each may be written next, and the plan of each
/// write, Spec 1 §4's version cadence included (`SavePlanner`), so "A list's
/// version rises in memory, on the control thread, and the background queue
/// only carries out the plans". An edit's file work (folders, moves, deletes)
/// is queued at once, in the order the edit made it (Spec 7 §2).
///
/// Only the control thread touches it.
final class DocumentStore {
    /// Spec 5 §2 — "at most once a second".
    static let interval: Int64 = 1_000_000_000

    let writer: DocumentWriter
    let log: EngineLog
    private let wallMilliseconds: @Sendable () -> Int64
    /// Spec 9 §6 — the kept versions of every list.
    private(set) var kept: KeptVersions
    /// Documents with unwritten edits, and when the first of them was made.
    private(set) var dirty: [DocumentRef: MonotonicTime] = [:]
    private var lastIssued: [DocumentRef: MonotonicTime] = [:]
    /// The sequence number of the last piece of work queued for each document.
    private(set) var issuedSeq: [DocumentRef: Int] = [:]
    /// Documents with a file on disk: loaded, or written since.
    private var onDisk: Set<DocumentRef>
    /// Spec 7 §3 — where each playlist's file is. A retitled playlist's
    /// `documentPaths` names its new file before the save renames it.
    private var playlistFiles: [UUID: String]
    private var reverts: [Int: Revert] = [:]
    private var failing: Set<DocumentRef> = []

    /// What a planned save changed in memory, put back if it fails.
    private struct Revert {
        var ref: DocumentRef
        var recorded: String?
        var planned: String
        var wasOnDisk: Bool
    }

    init(writer: DocumentWriter, library: Library, machine: Machine, kept: KeptVersions, log: EngineLog,
         wallMilliseconds: @escaping @Sendable () -> Int64) {
        self.writer = writer
        self.kept = kept
        self.log = log
        self.wallMilliseconds = wallMilliseconds
        var onDisk: Set<DocumentRef> = [.keys]
        for list in library.lists where library.documentPaths[FileLayout.documentKey(list: list.uuid)] != nil { onDisk.insert(.list(list.uuid)) }
        for macro in library.macros where library.documentPaths["macro/\(macro.number)"] != nil { onDisk.insert(.libraryMacro(macro.number)) }
        for macro in machine.macros where machine.documentPaths["macro/\(macro.number)"] != nil { onDisk.insert(.machineMacro(macro.number)) }
        var playlistFiles: [UUID: String] = [:]
        for playlist in machine.playlists {
            guard let path = machine.documentPaths[FileLayout.documentKey(playlist: playlist.uuid)] else { continue }
            onDisk.insert(.playlist(playlist.uuid))
            playlistFiles[playlist.uuid] = path
        }
        for list in machine.localLists where machine.documentPaths[Self.localKey(list.uuid)] != nil { onDisk.insert(.localList(list.uuid)) }
        self.onDisk = onDisk
        self.playlistFiles = playlistFiles
    }

    static func localKey(_ uuid: UUID) -> String {
        "local/" + uuid.uuidString.lowercased()
    }

    // MARK: - After an applied group

    /// Spec 5 §2 — the documents an applied group changed have unwritten
    /// edits from now; its file work goes to the queue at once, in order. A
    /// document whose file the group removed and then made again is written
    /// as a new file.
    func noteEdits(before: (library: Library, machine: Machine), library: Library, machine: Machine,
                   executed: [ExecutedCommand], now: MonotonicTime) {
        for ref in DocumentChanges.between(before, (library, machine)) where dirty[ref] == nil {
            dirty[ref] = now
        }
        var removed: [DocumentRef] = []
        for line in executed where line.result == .ok {
            for change in line.structure {
                if let ref = queue(change) { removed.append(ref) }
            }
        }
        for ref in removed where DocumentChanges.exists(ref, library: library, machine: machine) && dirty[ref] == nil {
            dirty[ref] = now
        }
    }

    /// Spec 7 §2 — one structure change as file operations; the document
    /// whose file it removed, if any. A list or playlist never written yet
    /// has no file to move or remove.
    private func queue(_ change: StructureChange) -> DocumentRef? {
        switch change {
        case .makeFolder(let path):
            submit(change, .library, [.makeFolder(path: "lists/" + path)])
        case .renameFolder(let from, let to):
            submit(change, .library, [.renameFolder(from: "lists/" + from, to: "lists/" + to)])
        case .removeFolder(let path):
            submit(change, .library, [.removeFolder(path: "lists/" + path)])
        case .moveList(let uuid, let from, let to):
            if onDisk.contains(.list(uuid)) { submit(change, .library, [.move(from: from, to: to)]) }
        case .removeList(let uuid, let path):
            dirty.removeValue(forKey: .list(uuid))
            guard onDisk.remove(.list(uuid)) != nil else { return nil }
            submit(change, .library, [.remove(path: path)])
            return .list(uuid)
        case .removePlaylist(let uuid, let path):
            dirty.removeValue(forKey: .playlist(uuid))
            let file = playlistFiles.removeValue(forKey: uuid) ?? path
            guard onDisk.remove(.playlist(uuid)) != nil else { return nil }
            submit(change, .machine, [.remove(path: file)])
            return .playlist(uuid)
        }
        return nil
    }

    private func submit(_ change: StructureChange, _ root: DocumentWriter.Root, _ operations: [FileOperation]) {
        writer.submit(.structure(change, root, operations))
    }

    // MARK: - Writing what is due

    /// Spec 5 §2 — write every document whose unwritten edits are due: at
    /// once when it hasn't been written for a second, else a second after its
    /// last write. `everything` writes them all now (the engine stops).
    /// Returns whether the roots changed: a list's version, a file's name.
    @discardableResult
    func writeDue(library: inout Library, machine: inout Machine, now: MonotonicTime, everything: Bool = false) -> Bool {
        let due = dirty.filter { ref, _ in
            everything || lastIssued[ref].map { now - $0 >= Self.interval } ?? true
        }
        guard !due.isEmpty else { return false }
        var changed = false
        for (ref, _) in due.sorted(by: { ($0.value, $0.key.description) < ($1.value, $1.key.description) }) {
            dirty.removeValue(forKey: ref)
            guard DocumentChanges.exists(ref, library: library, machine: machine) else { continue }
            write(ref, library: &library, machine: &machine)
            lastIssued[ref] = now
            changed = true
        }
        return changed
    }

    private func write(_ ref: DocumentRef, library: inout Library, machine: inout Machine) {
        switch ref {
        case .list(let uuid):
            guard let index = library.lists.firstIndex(where: { $0.uuid == uuid }) else { return }
            let key = FileLayout.documentKey(list: uuid)
            let recorded = library.documentPaths[key]
            let current = onDisk.contains(ref) ? recorded : nil
            // Spec 1 §4 — the version rises here, before the write happens.
            let save = SavePlanner.saveList(library.lists[index], currentPath: current,
                                            folder: recorded.map(FileLayout.folder(ofListPath:)) ?? "",
                                            kept: kept, now: wallMilliseconds(), taken: Self.takenListPaths(library, except: uuid))
            library.lists[index] = save.list
            library.documentPaths[key] = save.path
            kept = save.kept
            issue(ref, .library, save.plan.operations, path: save.path, recorded: recorded, wasOnDisk: current != nil)
        case .playlist(let uuid):
            guard let playlist = machine.playlist(uuid: uuid) else { return }
            let key = FileLayout.documentKey(playlist: uuid)
            let target = machine.documentPaths[key] ?? FileLayout.playlistPath(for: playlist, taken: Self.takenPlaylistPaths(machine, except: uuid))
            machine.documentPaths[key] = target
            // Spec 7 §3 — the file keeps its name until the title changes; then the save renames it.
            let file = onDisk.contains(ref) ? playlistFiles[uuid] : nil
            var operations: [FileOperation] = []
            if let file, file != target { operations.append(.move(from: file, to: target)) }
            operations.append(.replace(path: target, data: Writer.data(for: .playlist(playlist))))
            issue(ref, .machine, operations, path: target, recorded: file, wasOnDisk: file != nil)
            playlistFiles[uuid] = target
        case .localList(let uuid):
            // A local copy is never edited in v1; a renumber's rewritten reference saves it where its file is.
            guard let list = machine.localList(uuid: uuid) else { return }
            let path = machine.documentPaths[Self.localKey(uuid)] ?? FileLayout.path(for: .list(list))
            machine.documentPaths[Self.localKey(uuid)] = path
            let data = Writer.data(for: .list(list), extras: machine.documentExtras[.list] ?? [:])
            issue(ref, .machine, [.replace(path: path, data: data)], path: path, recorded: path, wasOnDisk: onDisk.contains(ref))
        case .libraryMacro(let number):
            guard let macro = library.macro(number) else { return }
            let recorded = library.documentPaths["macro/\(number)"]
            let plan = Writer.save(.macro(macro), extras: library.documentExtras[.macro] ?? [:],
                                   currentPath: onDisk.contains(ref) ? recorded : nil)
            let path = FileLayout.path(for: .macro(macro))
            library.documentPaths["macro/\(number)"] = path
            issue(ref, .library, plan.operations, path: path, recorded: recorded, wasOnDisk: onDisk.contains(ref))
        case .machineMacro(let number):
            guard let macro = machine.macro(number) else { return }
            let recorded = machine.documentPaths["macro/\(number)"]
            let plan = Writer.save(.macro(macro), extras: machine.documentExtras[.macro] ?? [:],
                                   currentPath: onDisk.contains(ref) ? recorded : nil)
            let path = FileLayout.path(for: .macro(macro))
            machine.documentPaths["macro/\(number)"] = path
            issue(ref, .machine, plan.operations, path: path, recorded: recorded, wasOnDisk: onDisk.contains(ref))
        case .keys:
            let plan = Writer.save(.keys(machine.keys), extras: machine.documentExtras[.keys] ?? [:])
            issue(ref, .machine, plan.operations, path: FileLayout.path(for: .keys(machine.keys)), recorded: nil, wasOnDisk: true)
        }
    }

    private func issue(_ ref: DocumentRef, _ root: DocumentWriter.Root, _ operations: [FileOperation], path: String,
                       recorded: String?, wasOnDisk: Bool) {
        let seq = writer.submit(.save(ref, root, operations, path: path))
        reverts[seq] = Revert(ref: ref, recorded: recorded, planned: path, wasOnDisk: wasOnDisk)
        issuedSeq[ref] = seq
        onDisk.insert(ref)
    }

    /// Spec 7 §2 — "Other files are never replaced": the paths other files
    /// under `lists/` hold.
    static func takenListPaths(_ library: Library, except uuid: UUID) -> Set<String> {
        var taken = Set(library.otherFiles.filter { $0.hasPrefix("lists/") })
        let own = FileLayout.documentKey(list: uuid)
        for (key, path) in library.documentPaths where key.hasPrefix("list/") && key != own { taken.insert(path) }
        return taken
    }

    static func takenPlaylistPaths(_ machine: Machine, except uuid: UUID) -> Set<String> {
        var taken = Set(machine.otherFiles.filter { $0.hasPrefix("playlists/") })
        let own = FileLayout.documentKey(playlist: uuid)
        for (key, path) in machine.documentPaths where key.hasPrefix("playlist/") && key != own { taken.insert(path) }
        return taken
    }

    // MARK: - What the writer reported

    /// The queue's reports since the last build. A failed write is logged
    /// once and tried again a second later, the document named where its file
    /// still is; a list move that failed leaves the list where it was (Spec 7
    /// §2: "a move onto one is refused"), and is returned for a `library`
    /// event. Kept-version copies not made are forgotten.
    func absorbReports(library: inout Library, machine: inout Machine, now: MonotonicTime) -> [LibraryChange] {
        var changes: [LibraryChange] = []
        for report in writer.takeReports() {
            switch report {
            case .saved(let seq, let ref, _, let skipped):
                reverts.removeValue(forKey: seq)
                for path in skipped {
                    for (uuid, versions) in KeptVersions.reading([path: 0]).lists {
                        for version in versions.keys { kept.lists[uuid]?[version] = nil }
                    }
                }
                if failing.remove(ref) != nil { log.info("wrote \(ref) again") }
            case .saveFailed(let seq, let ref, let reason):
                if failing.insert(ref).inserted { log.error("could not write \(ref): \(reason); trying again every second") }
                if let revert = reverts.removeValue(forKey: seq) { putBack(revert, library: &library, machine: &machine) }
                if dirty[ref] == nil, DocumentChanges.exists(ref, library: library, machine: machine) { dirty[ref] = now }
            case .structured:
                break
            case .structureFailed(_, let change, let reason):
                log.error("\(DocumentWriter.describe(change)) failed on disk: \(reason)")
                if case .moveList(let uuid, let from, _) = change, let list = library.list(uuid: uuid) {
                    library.documentPaths[FileLayout.documentKey(list: uuid)] = from
                    changes.append(LibraryChange(object: "list", address: ["list": .number(Double(list.number)),
                                                                           "listUuid": .string(uuid.uuidString.lowercased())]))
                }
            case .kept(let path, let about):
                log.warning("\(about) changed on disk while the engine held unwritten edits: the arriving file is kept as \(path), and the engine's document is written")
            case .keepFailed(let about, let reason):
                log.error("\(about) changed on disk while the engine held unwritten edits, and the arriving file could not be kept: \(reason)")
            }
        }
        return LibraryChange.merged(changes)
    }

    /// A failed save's document is named where its file still is.
    private func putBack(_ revert: Revert, library: inout Library, machine: inout Machine) {
        if !revert.wasOnDisk { onDisk.remove(revert.ref) }
        switch revert.ref {
        case .list(let uuid):
            let key = FileLayout.documentKey(list: uuid)
            if let recorded = revert.recorded, library.documentPaths[key] == revert.planned { library.documentPaths[key] = recorded }
        case .playlist(let uuid):
            if playlistFiles[uuid] == revert.planned { playlistFiles[uuid] = revert.recorded }
        case .libraryMacro(let number):
            if let recorded = revert.recorded, library.documentPaths["macro/\(number)"] == revert.planned { library.documentPaths["macro/\(number)"] = recorded }
        case .machineMacro(let number):
            if let recorded = revert.recorded, machine.documentPaths["macro/\(number)"] == revert.planned { machine.documentPaths["macro/\(number)"] = recorded }
        case .localList, .keys:
            break
        }
    }
}
