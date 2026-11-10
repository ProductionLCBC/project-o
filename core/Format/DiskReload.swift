// OCore — Spec 5 §10, Spec 1 §8 and Spec 7 §2–§3: changes that arrive on disk.
//
// Pure, like the editor: what the scan found and the roots in, the roots out.
// The engine's writer queue scans and reads the files; the control thread
// applies what they hold here.

import Foundation

/// Spec 5 §10 — one document file the scan found new or changed: its bytes,
/// their digest, and the document as the loader reads it, or why it doesn't
/// read yet.
public struct ArrivedFile: Equatable, Sendable {
    public var path: String
    public var data: Data
    public var digest: String
    public var document: Result<LoadedDocument, DocumentFailure>

    public init(path: String, data: Data, digest: String, document: Result<LoadedDocument, DocumentFailure>) {
        self.path = path
        self.data = data
        self.digest = digest
        self.document = document
    }

    /// The file read as the loader reads it (Spec 1 §5, §8).
    public static func reading(path: String, data: Data, digest: String) -> ArrivedFile {
        let document: Result<LoadedDocument, DocumentFailure>
        do {
            document = .success(try Loader.document(path: path, data: data))
        } catch let failure as DocumentFailure {
            document = .failure(failure)
        } catch {
            document = .failure(.unreadable(path: path, message: "\(error)"))
        }
        return ArrivedFile(path: path, data: data, digest: digest, document: document)
    }

    var reason: String {
        switch document {
        case .failure(let failure): return failure.message
        case .success(let loaded): return "\(path) holds a \(loaded.kind.rawValue) document"
        }
    }
}

/// Spec 5 §10 — what changed on disk in one root's watched folders since
/// the engine last read or wrote them; never the engine's own writes.
public struct RootDelta: Equatable, Sendable {
    public var arrived: [ArrivedFile] = []
    /// Document files that went, with the digest of what each last held.
    public var removed: [String: String] = [:]
    /// Spec 7 §2 — folders under `lists/` made or removed (`lists/Hymns`).
    public var foldersAdded: Set<String> = []
    public var foldersRemoved: Set<String> = []
    /// Spec 7 §2 — visible files under `lists/` that aren't documents.
    public var otherAdded: Set<String> = []
    public var otherRemoved: Set<String> = []
    /// Every document file there now, with its modification date in
    /// milliseconds since 1970, for the tie-breaks.
    public var present: [String: Int64] = [:]

    public init() {}

    public var isEmpty: Bool {
        arrived.isEmpty && removed.isEmpty && foldersAdded.isEmpty && foldersRemoved.isEmpty && otherAdded.isEmpty && otherRemoved.isEmpty
    }
}

/// Spec 5 §10 — one scan's findings: `lists/` in the library root,
/// `playlists/` and `lists-local/` in the machine root.
public struct DiskDelta: Equatable, Sendable {
    public var library = RootDelta()
    public var machine = RootDelta()

    public init() {}

    public var isEmpty: Bool { library.isEmpty && machine.isEmpty }
}

/// Spec 5 §10 — an arriving file the engine's edits beat, to keep in
/// `machine/conflicts/` under its file name.
public struct KeptConflict: Equatable, Sendable {
    public var name: String
    public var data: Data
    public var about: String
}

/// What the engine remembers between reloads.
public struct ReloadState: Equatable, Sendable {
    /// Spec 7 §2 — "If the new file arrives before the old one goes, the two
    /// files hold one list for a moment, and the next rule keeps one until the
    /// other goes": the files that hold a list but aren't loaded, by path, so
    /// one takes over when the loaded file goes.
    public var spareLists: [String: List] = [:]
    /// Spec 7 §3 — the same for playlists, and for local copies.
    public var sparePlaylists: [String: Playlist] = [:]
    public var spareLocals: [String: List] = [:]
    /// Spec 7 §2 — "a list file that disappears stays loaded for three
    /// seconds": the lists whose file went, by uuid.
    public var pending: [UUID: PendingRemoval] = [:]

    public struct PendingRemoval: Equatable, Sendable {
        public var path: String
        /// Engine time, in nanoseconds.
        public var since: Int64
        /// What the file last held.
        public var digest: String
    }

    public init() {}

    /// The spare files of roots as they loaded from their snapshots: the
    /// other of two files holding one list or playlist (Spec 7 §2, §3).
    public static func loaded(library: Library, machine: Machine, librarySnapshot: RootSnapshot, machineSnapshot: RootSnapshot) -> ReloadState {
        var state = ReloadState()
        for path in library.otherFiles where path.hasPrefix("lists/") && path.hasSuffix(".json") {
            guard let data = librarySnapshot.files[path], let loaded = try? Loader.document(path: path, data: data),
                  case .list(let list) = loaded.body, !list.isLocalCopy else { continue }
            state.spareLists[path] = list
        }
        for path in machine.otherFiles where path.hasPrefix("playlists/") {
            guard let data = machineSnapshot.files[path], let loaded = try? Loader.document(path: path, data: data),
                  case .playlist(let playlist) = loaded.body else { continue }
            state.sparePlaylists[path] = playlist
        }
        return state
    }
}

/// What a reload did: the roots after it, what changed for the `library`
/// event, the arriving files to keep in `conflicts/`, the documents the
/// engine's edits win for and must write again, where documents' files are
/// now and which have none, and lines for the engine log.
public struct ReloadOutcome: Equatable, Sendable {
    public var library: Library
    public var machine: Machine
    public var state: ReloadState
    public var changes: [LibraryChange] = []
    public var conflicts: [KeptConflict] = []
    public var rewrite: [DocumentRef] = []
    public var located: [DocumentRef: String] = [:]
    public var gone: [DocumentRef] = []
    public var notes: [String] = []
    public var warnings: [String] = []
}

/// Spec 5 §10 — "Changes that arrive on disk". Spec 1 §8 — the engine
/// "reloads it on the control thread and applies the nothing-edits-live
/// rule"; this changes the roots only, never ShowState or the pointer.
///
/// - **No unwritten edits.** "The engine loads the arriving document ... and
///   sends a `library` event with cause `file`."
/// - **Unwritten edits.** "The engine's edits win. It keeps the arriving file
///   in `machine/conflicts/` ... writes its own document, and logs both." An
///   edit still being written counts as unwritten, and so does a delete.
/// - **Moves.** "A list file that turns up in another folder with the same
///   uuid is the same list, moved"; "a list file that disappears stays
///   loaded for three seconds and counts as deleted only if no file with its
///   uuid appears under `lists/` in that time" (Spec 7 §2). "When a list with
///   unwritten edits has moved on disk, the engine writes them at the new
///   path."
/// - **Two files, one list** or one playlist: ranked as the loader ranks
///   them; the other is reported, "never written over" (Spec 7 §2, §3).
/// - **Folders**: "an empty folder survives a reload", and a folder made or
///   removed on disk is made or removed in the tree.
/// - A file that doesn't read yet is ignored until it does (Spec 1 §5): a
///   document loaded from it stays as it loaded.
/// - A playlist or local copy whose file goes is deleted at once: the window
///   is for list files, which a sync delivers; the machine root is never
///   synced.
public enum DiskReload {
    /// Spec 7 §2 — "stays loaded for three seconds".
    public static let window: Int64 = 3_000_000_000

    /// One scan's findings applied to the roots. `unwritten` are the
    /// documents with edits not yet on disk, `deleting` those an edit deleted
    /// whose files aren't gone yet; `now` is engine time in nanoseconds.
    public static func apply(_ delta: DiskDelta, library: Library, machine: Machine, state: ReloadState,
                             unwritten: Set<DocumentRef>, deleting: Set<DocumentRef>, now: Int64) -> ReloadOutcome {
        var reload = Reload(outcome: ReloadOutcome(library: library, machine: machine, state: state),
                            unwritten: unwritten, deleting: deleting, now: now)
        reload.applyLibrary(delta.library)
        reload.applyMachine(delta.machine)
        return reload.outcome
    }

    /// Spec 7 §2 — the lists whose files have been gone three seconds: each
    /// is deleted, unless it holds unwritten edits, which win, so it is
    /// written again.
    public static func expire(library: Library, machine: Machine, state: ReloadState, unwritten: Set<DocumentRef>, now: Int64) -> ReloadOutcome {
        var reload = Reload(outcome: ReloadOutcome(library: library, machine: machine, state: state),
                            unwritten: unwritten, deleting: [], now: now)
        reload.expire()
        return reload.outcome
    }
}

/// A reload in progress.
struct Reload {
    var outcome: ReloadOutcome
    let unwritten: Set<DocumentRef>
    let deleting: Set<DocumentRef>
    let now: Int64

    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    static func uuidText(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    // MARK: - The library root: lists/

    mutating func applyLibrary(_ delta: RootDelta) {
        for path in delta.foldersAdded.sorted() where path.hasPrefix("lists/") {
            addFolder(String(path.dropFirst("lists/".count)))
        }
        for path in delta.foldersRemoved.sorted() where path.hasPrefix("lists/") {
            let name = String(path.dropFirst("lists/".count))
            guard let index = outcome.library.folders.firstIndex(of: name) else { continue }
            outcome.library.folders.remove(at: index)
            outcome.changes.append(.folder(name))
        }
        outcome.library.otherFiles.formUnion(delta.otherAdded)
        outcome.library.otherFiles.subtract(delta.otherRemoved)
        var removed = delta.removed
        for file in delta.arrived.sorted(by: { $0.path < $1.path }) where file.path.hasPrefix("lists/") {
            arriveInLibrary(file, removed: &removed, present: delta.present)
        }
        for (path, digest) in removed.sorted(by: { $0.key < $1.key }) where path.hasPrefix("lists/") {
            goneFromLibrary(path, digest: digest)
        }
    }

    /// Spec 7 §2 — a folder in the tree, in the case it has on disk.
    mutating func addFolder(_ name: String) {
        guard !name.isEmpty, !outcome.library.folders.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        outcome.library.folders.append(name)
        outcome.library.folders.sort()
        outcome.changes.append(.folder(name))
    }

    /// The folders a list file sits in are in the tree.
    mutating func addFolders(of path: String) {
        let folder = FileLayout.folder(ofListPath: path)
        guard !folder.isEmpty else { return }
        var chain = ""
        for part in folder.split(separator: "/") {
            chain = chain.isEmpty ? String(part) : chain + "/" + part
            addFolder(chain)
        }
    }

    func loadedList(at path: String) -> Int? {
        outcome.library.lists.firstIndex { outcome.library.documentPaths[FileLayout.documentKey(list: $0.uuid)] == path }
    }

    /// Lists stay in number order; a new one goes after any with its number
    /// (Spec 7 §2: "lists sharing a number keep that order").
    mutating func insertInOrder(_ list: List) {
        let at = outcome.library.lists.firstIndex { $0.number > list.number } ?? outcome.library.lists.count
        outcome.library.lists.insert(list, at: at)
    }

    mutating func arriveInLibrary(_ file: ArrivedFile, removed: inout [String: String], present: [String: Int64]) {
        let path = file.path
        outcome.state.spareLists.removeValue(forKey: path)
        guard case .success(let loaded) = file.document, case .list(let list) = loaded.body, !list.isLocalCopy else {
            // Spec 1 §5 — "any file whose JSON does not parse yet" is read once it is complete.
            if let index = loadedList(at: path) {
                outcome.warnings.append("\(path) does not read yet (\(file.reason)); list \(outcome.library.lists[index].number) stays as it loaded")
            } else {
                outcome.library.otherFiles.insert(path)
                outcome.warnings.append("\(path) does not read (\(file.reason)); it is not loaded")
            }
            return
        }
        outcome.library.otherFiles.remove(path)
        let ref = DocumentRef.list(list.uuid)
        let key = FileLayout.documentKey(list: list.uuid)
        let about = "list \(list.number) at \(path)"
        if deleting.contains(ref) {
            outcome.conflicts.append(KeptConflict(name: Self.name(path), data: file.data, about: about + ", which an edit deleted,"))
            return
        }
        guard let index = outcome.library.lists.firstIndex(where: { $0.uuid == list.uuid }) else {
            // Spec 1 §8 — a master arriving by sync.
            insertInOrder(list)
            outcome.library.documentPaths[key] = path
            addFolders(of: path)
            outcome.located[ref] = path
            outcome.changes.append(.list(list))
            outcome.notes.append("list \(list.number) arrived at \(path)")
            return
        }
        let current = outcome.library.documentPaths[key]
        if current == path {
            outcome.state.pending.removeValue(forKey: list.uuid)
            if unwritten.contains(ref) {
                winOver(file, about: about, ref: ref, index: index, arriving: list)
            } else {
                outcome.library.lists[index] = list
                outcome.changes.append(.list(list))
                outcome.notes.append("reloaded list \(list.number) from \(path)")
            }
            return
        }
        let currentGone = current.map { removed[$0] != nil || present[$0] == nil } ?? true
        if currentGone {
            // Spec 7 §2 — "the same list, moved"; no version goes up.
            let before = current.flatMap { removed.removeValue(forKey: $0) } ?? outcome.state.pending[list.uuid]?.digest
            outcome.state.pending.removeValue(forKey: list.uuid)
            outcome.library.documentPaths[key] = path
            addFolders(of: path)
            outcome.located[ref] = path
            if unwritten.contains(ref) {
                // Spec 5 §10 — "When a list with unwritten edits has moved on disk, the engine writes them at the new path."
                if let before, before != file.digest {
                    winOver(file, about: about, ref: ref, index: index, arriving: list)
                } else {
                    outcome.rewrite.append(ref)
                }
            } else {
                outcome.library.lists[index] = list
            }
            outcome.changes.append(.list(outcome.library.lists[index]))
            outcome.notes.append("list \(list.number) moved on disk: \(current ?? "?") to \(path)")
            return
        }
        // Spec 7 §2 — "Two files, one list ... The other file is reported", and never written over.
        let held = outcome.library.lists[index]
        let heldPath = current ?? ""
        let arrivingFirst = Loader.rank(list: list, path: path, modified: present[path] ?? 0)
            < Loader.rank(list: held, path: heldPath, modified: present[heldPath] ?? 0)
        let uuid = Self.uuidText(list.uuid)
        if arrivingFirst, !unwritten.contains(ref) {
            outcome.state.spareLists[heldPath] = held
            outcome.library.otherFiles.insert(heldPath)
            outcome.library.lists[index] = list
            outcome.library.documentPaths[key] = path
            outcome.located[ref] = path
            outcome.changes.append(.list(list))
            outcome.warnings.append("\(path) and \(heldPath) both hold list \(list.number) (\(uuid)): \(path) is loaded, and \(heldPath) is never written over")
        } else {
            outcome.state.spareLists[path] = list
            outcome.library.otherFiles.insert(path)
            outcome.warnings.append("\(path) holds list \(list.number) (\(uuid)), which \(heldPath) holds: it is not loaded, and never written over")
        }
    }

    /// Spec 5 §10 — "The engine's edits win. It keeps the arriving file in
    /// `machine/conflicts/` ... writes its own document". Its next write goes
    /// above the arriving file's version.
    mutating func winOver(_ file: ArrivedFile, about: String, ref: DocumentRef, index: Int, arriving: List) {
        outcome.conflicts.append(KeptConflict(name: Self.name(file.path), data: file.data, about: about))
        outcome.rewrite.append(ref)
        if arriving.version > outcome.library.lists[index].version { outcome.library.lists[index].version = arriving.version }
    }

    mutating func goneFromLibrary(_ path: String, digest: String) {
        if outcome.state.spareLists.removeValue(forKey: path) != nil {
            outcome.library.otherFiles.remove(path)
            return
        }
        if outcome.library.otherFiles.remove(path) != nil { return }
        guard let index = loadedList(at: path) else { return }
        let list = outcome.library.lists[index]
        let ref = DocumentRef.list(list.uuid)
        let key = FileLayout.documentKey(list: list.uuid)
        // Spec 7 §2 — another file holding the list takes over: a move.
        let spares = outcome.state.spareLists.filter { $0.value.uuid == list.uuid }
        if let spare = spares.min(by: { Loader.rank(list: $0.value, path: $0.key, modified: 0) < Loader.rank(list: $1.value, path: $1.key, modified: 0) }) {
            outcome.state.spareLists.removeValue(forKey: spare.key)
            outcome.library.otherFiles.remove(spare.key)
            outcome.library.documentPaths[key] = spare.key
            outcome.located[ref] = spare.key
            if unwritten.contains(ref) {
                outcome.rewrite.append(ref)
            } else {
                outcome.library.lists[index] = spare.value
            }
            outcome.changes.append(.list(outcome.library.lists[index]))
            outcome.notes.append("list \(list.number) moved on disk: \(path) to \(spare.key)")
            return
        }
        // Spec 7 §2 — "stays loaded for three seconds and counts as deleted only if no file with its uuid appears".
        outcome.state.pending[list.uuid] = ReloadState.PendingRemoval(path: path, since: now, digest: digest)
        outcome.gone.append(ref)
        outcome.notes.append("list \(list.number)'s file \(path) is gone; the list stays loaded for three seconds in case it moved")
    }

    mutating func expire() {
        let due = outcome.state.pending.filter { now - $0.value.since >= DiskReload.window }
        for (uuid, pending) in due.sorted(by: { $0.value.path < $1.value.path }) {
            outcome.state.pending.removeValue(forKey: uuid)
            guard let index = outcome.library.lists.firstIndex(where: { $0.uuid == uuid }) else { continue }
            let list = outcome.library.lists[index]
            let ref = DocumentRef.list(uuid)
            if unwritten.contains(ref) {
                outcome.rewrite.append(ref)
                outcome.warnings.append("list \(list.number)'s file \(pending.path) was deleted on disk while the engine held unwritten edits: the engine's edits win, and the list is written again")
            } else {
                outcome.library.lists.remove(at: index)
                outcome.library.documentPaths.removeValue(forKey: FileLayout.documentKey(list: uuid))
                outcome.changes.append(.list(list))
                outcome.notes.append("list \(list.number) was deleted on disk (\(pending.path))")
            }
        }
    }

    // MARK: - The machine root: playlists/ and lists-local/

    mutating func applyMachine(_ delta: RootDelta) {
        var removed = delta.removed
        for file in delta.arrived.sorted(by: { $0.path < $1.path }) {
            if file.path.hasPrefix("playlists/") {
                arrivePlaylist(file, removed: &removed, present: delta.present)
            } else if file.path.hasPrefix("lists-local/") {
                arriveLocal(file, removed: &removed, present: delta.present)
            }
        }
        for (path, _) in removed.sorted(by: { $0.key < $1.key }) {
            goneFromMachine(path)
        }
    }

    func loadedPlaylist(at path: String) -> Int? {
        outcome.machine.playlists.firstIndex { outcome.machine.documentPaths[FileLayout.documentKey(playlist: $0.uuid)] == path }
    }

    func loadedLocal(at path: String) -> Int? {
        outcome.machine.localLists.firstIndex { outcome.machine.documentPaths[Self.localKey($0.uuid)] == path }
    }

    static func localKey(_ uuid: UUID) -> String { "local/" + uuidText(uuid) }

    static func localChange(_ uuid: UUID) -> LibraryChange {
        LibraryChange(object: "list", address: ["local": .string(uuidText(uuid))])
    }

    /// Spec 1 §3 — "The tree sorts dated playlists by date and lists undated
    /// ones by name", the order the loader keeps them in.
    mutating func insertInOrder(_ playlist: Playlist) {
        let key = { (p: Playlist) in (p.serviceDate ?? "", p.title.lowercased()) }
        let at = outcome.machine.playlists.firstIndex { key($0) > key(playlist) } ?? outcome.machine.playlists.count
        outcome.machine.playlists.insert(playlist, at: at)
    }

    mutating func arrivePlaylist(_ file: ArrivedFile, removed: inout [String: String], present: [String: Int64]) {
        let path = file.path
        outcome.state.sparePlaylists.removeValue(forKey: path)
        outcome.machine.otherFiles.remove(path)
        guard case .success(let loaded) = file.document, case .playlist(let playlist) = loaded.body else {
            let held = loadedPlaylist(at: path).map { "playlist \"\(outcome.machine.playlists[$0].title)\" stays as it loaded" } ?? "it is not loaded"
            outcome.warnings.append("\(path) does not read yet (\(file.reason)); \(held)")
            return
        }
        let ref = DocumentRef.playlist(playlist.uuid)
        let key = FileLayout.documentKey(playlist: playlist.uuid)
        let about = "playlist \"\(playlist.title)\" at \(path)"
        if deleting.contains(ref) {
            outcome.conflicts.append(KeptConflict(name: Self.name(path), data: file.data, about: about + ", which an edit deleted,"))
            return
        }
        guard let index = outcome.machine.playlists.firstIndex(where: { $0.uuid == playlist.uuid }) else {
            insertInOrder(playlist)
            outcome.machine.documentPaths[key] = path
            outcome.located[ref] = path
            outcome.changes.append(.playlist(playlist.uuid))
            outcome.notes.append("playlist \"\(playlist.title)\" arrived at \(path)")
            return
        }
        if unwritten.contains(ref) {
            outcome.conflicts.append(KeptConflict(name: Self.name(path), data: file.data, about: about))
            outcome.rewrite.append(ref)
            return
        }
        let current = outcome.machine.documentPaths[key]
        let currentGone = current.map { $0 != path && (removed[$0] != nil || present[$0] == nil) } ?? true
        if current == path || currentGone {
            if let current, current != path {
                removed.removeValue(forKey: current)
                outcome.notes.append("playlist \"\(playlist.title)\" moved on disk: \(current) to \(path)")
            } else {
                outcome.notes.append("reloaded playlist \"\(playlist.title)\" from \(path)")
            }
            outcome.machine.playlists.remove(at: index)
            insertInOrder(playlist)
            outcome.machine.documentPaths[key] = path
            outcome.located[ref] = path
            outcome.changes.append(.playlist(playlist.uuid))
            return
        }
        // Spec 7 §3 — "Two files with the same playlist uuid load as one ... the other is reported."
        let held = outcome.machine.playlists[index]
        let heldPath = current ?? ""
        if Loader.rank(playlist: playlist, path: path, modified: present[path] ?? 0)
            < Loader.rank(playlist: held, path: heldPath, modified: present[heldPath] ?? 0) {
            outcome.state.sparePlaylists[heldPath] = held
            outcome.machine.otherFiles.insert(heldPath)
            outcome.machine.playlists.remove(at: index)
            insertInOrder(playlist)
            outcome.machine.documentPaths[key] = path
            outcome.located[ref] = path
            outcome.changes.append(.playlist(playlist.uuid))
            outcome.warnings.append("\(path) and \(heldPath) both hold playlist \"\(playlist.title)\": \(path) is loaded")
        } else {
            outcome.state.sparePlaylists[path] = playlist
            outcome.machine.otherFiles.insert(path)
            outcome.warnings.append("\(path) holds playlist \"\(playlist.title)\", which \(heldPath) holds: it is not loaded")
        }
    }

    mutating func arriveLocal(_ file: ArrivedFile, removed: inout [String: String], present: [String: Int64]) {
        let path = file.path
        outcome.state.spareLocals.removeValue(forKey: path)
        guard case .success(let loaded) = file.document, case .list(let list) = loaded.body, list.isLocalCopy else {
            outcome.warnings.append("\(path) does not read yet (\(file.reason)); \(loadedLocal(at: path) == nil ? "it is not loaded" : "the local copy stays as it loaded")")
            return
        }
        let ref = DocumentRef.localList(list.uuid)
        let key = Self.localKey(list.uuid)
        guard let index = outcome.machine.localLists.firstIndex(where: { $0.uuid == list.uuid }) else {
            let at = outcome.machine.localLists.firstIndex { $0.number > list.number } ?? outcome.machine.localLists.count
            outcome.machine.localLists.insert(list, at: at)
            outcome.machine.documentPaths[key] = path
            outcome.located[ref] = path
            outcome.changes.append(Self.localChange(list.uuid))
            outcome.notes.append("local copy of list \(list.number) arrived at \(path)")
            return
        }
        if unwritten.contains(ref) {
            outcome.conflicts.append(KeptConflict(name: Self.name(path), data: file.data, about: "local copy of list \(list.number) at \(path)"))
            outcome.rewrite.append(ref)
            return
        }
        let current = outcome.machine.documentPaths[key]
        let currentGone = current.map { $0 != path && (removed[$0] != nil || present[$0] == nil) } ?? true
        guard current == path || currentGone else {
            outcome.state.spareLocals[path] = list
            outcome.warnings.append("\(path) holds the local copy \(Self.uuidText(list.uuid)), which \(current ?? "") holds: it is not loaded")
            return
        }
        if let current, current != path { removed.removeValue(forKey: current) }
        outcome.machine.localLists[index] = list
        outcome.machine.documentPaths[key] = path
        outcome.located[ref] = path
        outcome.changes.append(Self.localChange(list.uuid))
        outcome.notes.append("reloaded the local copy of list \(list.number) from \(path)")
    }

    /// A playlist or local copy whose file goes is deleted at once, unless
    /// another file holds it or the engine holds unwritten edits to it.
    mutating func goneFromMachine(_ path: String) {
        if outcome.state.sparePlaylists.removeValue(forKey: path) != nil || outcome.state.spareLocals.removeValue(forKey: path) != nil {
            outcome.machine.otherFiles.remove(path)
            return
        }
        if let index = loadedPlaylist(at: path) {
            let playlist = outcome.machine.playlists[index]
            let ref = DocumentRef.playlist(playlist.uuid)
            let key = FileLayout.documentKey(playlist: playlist.uuid)
            if let spare = outcome.state.sparePlaylists.first(where: { $0.value.uuid == playlist.uuid }) {
                outcome.state.sparePlaylists.removeValue(forKey: spare.key)
                outcome.machine.otherFiles.remove(spare.key)
                outcome.machine.documentPaths[key] = spare.key
                outcome.located[ref] = spare.key
                if unwritten.contains(ref) {
                    outcome.rewrite.append(ref)
                } else {
                    outcome.machine.playlists.remove(at: index)
                    insertInOrder(spare.value)
                }
                outcome.changes.append(.playlist(playlist.uuid))
                outcome.notes.append("playlist \"\(playlist.title)\" moved on disk: \(path) to \(spare.key)")
                return
            }
            outcome.gone.append(ref)
            if unwritten.contains(ref) {
                outcome.rewrite.append(ref)
                outcome.warnings.append("playlist \"\(playlist.title)\"'s file \(path) was deleted on disk while the engine held unwritten edits: the engine's edits win, and it is written again")
                return
            }
            outcome.machine.playlists.remove(at: index)
            outcome.machine.documentPaths.removeValue(forKey: key)
            outcome.changes.append(.playlist(playlist.uuid))
            outcome.notes.append("playlist \"\(playlist.title)\" was deleted on disk (\(path))")
            return
        }
        if let index = loadedLocal(at: path) {
            let list = outcome.machine.localLists[index]
            let ref = DocumentRef.localList(list.uuid)
            outcome.gone.append(ref)
            if unwritten.contains(ref) {
                outcome.rewrite.append(ref)
                return
            }
            outcome.machine.localLists.remove(at: index)
            outcome.machine.documentPaths.removeValue(forKey: Self.localKey(list.uuid))
            outcome.changes.append(Self.localChange(list.uuid))
            outcome.notes.append("the local copy of list \(list.number) was deleted on disk (\(path))")
        }
    }
}
