// OEngine — Spec 1 §5 and Spec 5 §2, the writes; Spec 5 §10, the conflicts
// folder. The background queue that carries out what the control thread plans.

import Foundation
import OCore
import OFormats

/// Spec 5 §2 — "The engine writes a changed document with Spec 1 §5's atomic
/// write". The control thread plans every write (the version a list gets, its
/// file name, what is kept in `versions/`) and hands the operations here; one
/// serial background queue carries them out in the order they came, so an
/// edit's file work and the saves around it never cross, and reports back
/// what happened. Nothing here runs on the render thread.
///
/// Spec 5 §10 — "Unwritten edits. The engine's edits win. It keeps the
/// arriving file in `machine/conflicts/`, named with the time and the file's
/// name, writes its own document, and logs both." The queue keeps, for every
/// file under `lists/`, `playlists/` and `lists-local/`, the digest of what it
/// last read or wrote there. Before it replaces, moves or removes one of them
/// it checks the file: one that changed since is kept in `conflicts/` first.
public final class DocumentWriter: @unchecked Sendable {
    public enum Root: String, Sendable {
        case library, machine
    }

    /// One piece of work for the queue.
    public enum Work: Sendable {
        /// A document's content, as the control thread planned it; `path` is
        /// where the document ends up.
        case save(DocumentRef, Root, [FileOperation], path: String)
        /// An edit's file work: a folder made, renamed or removed, a list
        /// moved, a document's file removed (Spec 7 §2).
        case structure(StructureChange, Root, [FileOperation])
        /// Spec 5 §10 — an arriving file the engine's edits beat, kept under
        /// its file name in `machine/conflicts/`.
        case keep(Data, name: String, about: String)
        /// Spec 5 §10 — look for what changed on disk since the queue last
        /// read or wrote the watched folders.
        case scan
    }

    /// What the queue did, in order, for the control thread.
    public enum Report: Equatable, Sendable {
        /// `skippedCopies` are kept-version copies not made because the file
        /// to keep had gone or had changed on disk.
        case saved(seq: Int, ref: DocumentRef, path: String, skippedCopies: [String])
        case saveFailed(seq: Int, ref: DocumentRef, reason: String)
        case structured(seq: Int, change: StructureChange)
        case structureFailed(seq: Int, change: StructureChange, reason: String)
        /// A file kept in `machine/conflicts/`, by its path in the machine root.
        case kept(path: String, about: String)
        case keepFailed(about: String, reason: String)
        /// What a scan found; never the queue's own writes.
        case scanned(DiskDelta)
    }

    /// What the queue knows a watched file holds: the digest of the bytes it
    /// last read or wrote, and the file's identity when it last looked.
    struct Known: Equatable, Sendable {
        var digest: String
        var stamp: Stamp?
    }

    /// A file's identity on disk, so an unchanged file isn't read again.
    struct Stamp: Equatable, Sendable {
        var inode: UInt64
        var size: Int64
        var modified: Int64

        static func of(_ path: String) -> Stamp? {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return Stamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                         modified: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec))
        }
    }

    struct FileKey: Hashable, Sendable {
        var root: Root
        var path: String
    }

    public let libraryRoot: URL
    public let machineRoot: URL
    private let fileStamp: @Sendable () -> String
    private let queue = DispatchQueue(label: "o.engine.writer", qos: .utility)
    private let lock = NSLock()
    private var nextSeq = 0
    private var reports: [Report] = []
    private var scanQueued = false
    // The queue's own: touched only on `queue`.
    var files: [FileKey: Known] = [:]
    var folders: Set<String> = []
    var others: Set<String> = []

    /// `librarySnapshot` and `machineSnapshot` are the snapshots the roots
    /// were loaded from: what the engine knows the watched files hold.
    /// `fileStamp` names a conflict's time, `2026-11-08-085959`.
    public init(libraryRoot: URL, machineRoot: URL, librarySnapshot: RootSnapshot, machineSnapshot: RootSnapshot,
                fileStamp: @escaping @Sendable () -> String) {
        self.libraryRoot = libraryRoot
        self.machineRoot = machineRoot
        self.fileStamp = fileStamp
        for (path, data) in librarySnapshot.files where Self.watched(.library, path) {
            files[FileKey(root: .library, path: path)] = Known(digest: Self.digest(data), stamp: nil)
        }
        for (path, data) in machineSnapshot.files where Self.watched(.machine, path) {
            files[FileKey(root: .machine, path: path)] = Known(digest: Self.digest(data), stamp: nil)
        }
        folders = Set(librarySnapshot.folders.filter { $0.hasPrefix("lists/") && !FileLayout.isIgnored(path: $0) })
        others = Set(librarySnapshot.otherFiles.filter { $0.hasPrefix("lists/") && !FileLayout.isIgnored(path: $0) })
    }

    /// Spec 7 §2, §3 and Spec 5 §10 — the folders whose files the engine
    /// watches: `lists/` in the library root, `playlists/` and `lists-local/`
    /// in the machine root.
    static func watched(_ root: Root, _ path: String) -> Bool {
        guard !FileLayout.isIgnored(path: path) else { return false }
        switch root {
        case .library: return path.hasPrefix("lists/") || path == DocumentKind.mediaIndex.fixedPath
        case .machine: return path.hasPrefix("playlists/") || path.hasPrefix("lists-local/") || path == DocumentKind.mediaLocal.fixedPath
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hex(SHA256.digest(data))
    }

    func url(_ root: Root) -> URL {
        root == .library ? libraryRoot : machineRoot
    }

    // MARK: - The control thread's side

    /// Queue one piece of work after everything queued before it; returns its
    /// sequence number.
    @discardableResult
    public func submit(_ work: Work) -> Int {
        lock.lock()
        nextSeq += 1
        let seq = nextSeq
        queue.async { [self] in run(work, seq: seq) }
        lock.unlock()
        return seq
    }

    /// Spec 5 §10 — a scan after everything queued so far. Any thread: the
    /// folder watcher asks from its own. One waiting scan covers every ask
    /// made before it starts.
    public func requestScan() {
        lock.lock()
        let queued = scanQueued
        scanQueued = true
        lock.unlock()
        if !queued { submit(.scan) }
    }

    /// Everything reported since the last call, in order.
    public func takeReports() -> [Report] {
        lock.lock()
        defer { lock.unlock() }
        let out = reports
        reports.removeAll()
        return out
    }

    /// Wait until the queue has done everything queued so far.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func report(_ report: Report) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    // MARK: - On the queue

    private func run(_ work: Work, seq: Int) {
        switch work {
        case .save(let ref, let root, let operations, let path):
            save(ref, root: root, operations: operations, path: path, seq: seq)
        case .structure(let change, let root, let operations):
            structure(change, root: root, operations: operations, seq: seq)
        case .keep(let data, let name, let about):
            keep(data, name: name, about: about)
        case .scan:
            lock.lock()
            scanQueued = false
            lock.unlock()
            let delta = scan()
            if !delta.isEmpty { report(.scanned(delta)) }
        }
    }

    // MARK: - Scanning (Spec 5 §10, Spec 1 §8)

    /// Spec 5 §10 — the watched folders compared with what the queue last
    /// read or wrote there: the documents that arrived or changed, read and
    /// parsed here, off the control thread; those that went; folders and
    /// other files under `lists/`. A file whose identity on disk is unchanged
    /// isn't read again. "The loader and the folder watcher ignore a sync
    /// tool's temporary and partial files" (Spec 1 §5). The queue then knows
    /// the disk as it is.
    func scan() -> DiskDelta {
        var delta = DiskDelta()
        delta.library = scan(.library, under: ["lists"], files: [DocumentKind.mediaIndex.fixedPath ?? "media-index.json"])
        delta.machine = scan(.machine, under: ["playlists", "lists-local"], files: [DocumentKind.mediaLocal.fixedPath ?? "media-local.json"])
        return delta
    }

    private func scan(_ root: Root, under tops: [String], files single: [String]) -> RootDelta {
        var delta = RootDelta()
        // Spec 8 §2 — the media indexes, at the top of their roots.
        for path in single {
            let full = url(root).appendingPathComponent(path).standardizedFileURL.path
            guard let stamp = Stamp.of(full) else { continue }
            delta.present[path] = stamp.modified / 1_000_000
            let key = FileKey(root: root, path: path)
            if let known = files[key], known.stamp == stamp { continue }
            guard let data = FileManager.default.contents(atPath: full) else { continue }
            let digest = Self.digest(data)
            if let known = files[key], known.digest == digest {
                files[key]?.stamp = stamp
                continue
            }
            files[key] = Known(digest: digest, stamp: stamp)
            delta.arrived.append(ArrivedFile.reading(path: path, data: data, digest: digest))
        }
        var seenFolders: Set<String> = []
        var seenOthers: Set<String> = []
        let base = url(root).standardizedFileURL.path + "/"
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        for top in tops {
            guard let walker = FileManager.default.enumerator(at: url(root).appendingPathComponent(top), includingPropertiesForKeys: keys) else { continue }
            for case let item as URL in walker {
                let full = item.standardizedFileURL.path
                guard full.hasPrefix(base) else { continue }
                let path = String(full.dropFirst(base.count))
                let values = try? item.resourceValues(forKeys: Set(keys))
                if FileLayout.isIgnored(path: path) {
                    if values?.isDirectory == true { walker.skipDescendants() }
                    continue
                }
                if values?.isDirectory == true {
                    if root == .library { seenFolders.insert(path) }
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                guard item.pathExtension == "json" else {
                    if root == .library { seenOthers.insert(path) }
                    continue
                }
                guard let stamp = Stamp.of(full) else { continue }
                delta.present[path] = stamp.modified / 1_000_000
                let key = FileKey(root: root, path: path)
                if let known = files[key], known.stamp == stamp { continue }
                guard let data = FileManager.default.contents(atPath: full) else { continue }
                let digest = Self.digest(data)
                if let known = files[key], known.digest == digest {
                    files[key]?.stamp = stamp
                    continue
                }
                files[key] = Known(digest: digest, stamp: stamp)
                delta.arrived.append(ArrivedFile.reading(path: path, data: data, digest: digest))
            }
        }
        for (key, known) in files where key.root == root && delta.present[key.path] == nil {
            delta.removed[key.path] = known.digest
            files.removeValue(forKey: key)
        }
        if root == .library {
            delta.foldersAdded = seenFolders.subtracting(folders)
            delta.foldersRemoved = folders.subtracting(seenFolders)
            delta.otherAdded = seenOthers.subtracting(others)
            delta.otherRemoved = others.subtracting(seenOthers)
            folders = seenFolders
            others = seenOthers
        }
        delta.arrived.sort { $0.path < $1.path }
        return delta
    }

    /// Spec 1 §5 — one document's write. A kept-version copy whose file has
    /// gone, or changed on disk, isn't made; a rename whose file has gone
    /// leaves the replace to write the document where it goes.
    private func save(_ ref: DocumentRef, root: Root, operations: [FileOperation], path: String, seq: Int) {
        let changed = keepArrivals(in: operations, root: root, about: ref.description)
        var skipped: [String] = []
        do {
            for operation in operations {
                switch operation {
                case .copy(let from, let to):
                    if changed.contains(from) || !exists(root, from) {
                        skipped.append(to)
                        continue
                    }
                case .move(let from, _):
                    if !exists(root, from) { continue }
                default:
                    break
                }
                try LocalFiles.execute(WritePlan(operations: [operation]), in: url(root))
                note(operation, root: root)
            }
            report(.saved(seq: seq, ref: ref, path: path, skippedCopies: skipped))
        } catch {
            report(.saveFailed(seq: seq, ref: ref, reason: "\(error)"))
        }
    }

    /// Spec 7 §2 — an edit's file work, in the order the edit made it.
    private func structure(_ change: StructureChange, root: Root, operations: [FileOperation], seq: Int) {
        _ = keepArrivals(in: operations, root: root, about: Self.describe(change))
        do {
            for operation in operations {
                try LocalFiles.execute(WritePlan(operations: [operation]), in: url(root))
                note(operation, root: root)
            }
            report(.structured(seq: seq, change: change))
        } catch {
            report(.structureFailed(seq: seq, change: change, reason: "\(error)"))
        }
    }

    static func describe(_ change: StructureChange) -> String {
        switch change {
        case .makeFolder(let path): return "folder \"\(path)\" create"
        case .renameFolder(let from, let to): return "folder \"\(from)\" rename \"\(to)\""
        case .removeFolder(let path): return "folder \"\(path)\" delete"
        case .moveList(let uuid, let from, let to): return "list \(uuid.uuidString.lowercased()) move \(from) to \(to)"
        case .removeList(let uuid, let path): return "list \(uuid.uuidString.lowercased()) delete \(path)"
        case .removePlaylist(let uuid, let path): return "playlist \(uuid.uuidString.lowercased()) delete \(path)"
        }
    }

    func exists(_ root: Root, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(root).appendingPathComponent(path).path)
    }

    /// Spec 5 §10 — before the queue replaces, moves or removes a watched
    /// file, a change that arrived since it last read or wrote the file is
    /// kept in `conflicts/`; the paths that had changed.
    private func keepArrivals(in operations: [FileOperation], root: Root, about: String) -> Set<String> {
        var paths: [String] = []
        for operation in operations {
            switch operation {
            case .replace(let path, _), .remove(let path): paths.append(path)
            case .move(let from, _), .copy(let from, _): paths.append(from)
            case .makeFolder, .renameFolder, .removeFolder: break
            }
        }
        var changed: Set<String> = []
        for path in paths where Self.watched(root, path) && !changed.contains(path) {
            guard let data = arrival(FileKey(root: root, path: path)) else { continue }
            keep(data, name: (path as NSString).lastPathComponent, about: about + " at " + path)
            files[FileKey(root: root, path: path)] = Known(digest: Self.digest(data), stamp: nil)
            changed.insert(path)
        }
        return changed
    }

    /// The bytes of a watched file that changed since the queue last read or
    /// wrote it, or that it never knew; nil when it is unchanged or absent.
    func arrival(_ key: FileKey) -> Data? {
        let path = url(key.root).appendingPathComponent(key.path).path
        guard let stamp = Stamp.of(path) else { return nil }
        if let known = files[key], known.stamp == stamp { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let known = files[key], known.digest == Self.digest(data) {
            files[key]?.stamp = stamp
            return nil
        }
        return data
    }

    /// Spec 5 §10 — "named with the time and the file's name", in the machine
    /// root, which is never synced; a second conflict in the same second takes
    /// `-2`, `-3` and so on.
    private func keep(_ data: Data, name: String, about: String) {
        let stamp = fileStamp()
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = "conflicts/\(stamp)-\(name)"
        var n = 2
        while exists(.machine, candidate) {
            candidate = "conflicts/\(stamp)-\(stem)-\(n)" + (ext.isEmpty ? "" : "." + ext)
            n += 1
        }
        do {
            try LocalFiles.execute(WritePlan(operations: [.replace(path: candidate, data: data)]), in: machineRoot)
            report(.kept(path: candidate, about: about))
        } catch {
            report(.keepFailed(about: about, reason: "\(error)"))
        }
    }

    /// What a done operation leaves on disk, for the watched files.
    func note(_ operation: FileOperation, root: Root) {
        switch operation {
        case .replace(let path, let data):
            if Self.watched(root, path) { files[FileKey(root: root, path: path)] = Known(digest: Self.digest(data), stamp: nil) }
        case .move(let from, let to):
            if let known = files.removeValue(forKey: FileKey(root: root, path: from)), Self.watched(root, to) {
                files[FileKey(root: root, path: to)] = known
            }
        case .remove(let path):
            files.removeValue(forKey: FileKey(root: root, path: path))
        case .copy:
            break
        case .makeFolder(let path):
            if root == .library, path.hasPrefix("lists/") { folders.insert(path) }
        case .renameFolder(let from, let to):
            guard root == .library else { return }
            func moved(_ path: String) -> String? {
                if path == from { return to }
                return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : nil
            }
            folders = Set(folders.map { moved($0) ?? $0 })
            others = Set(others.map { moved($0) ?? $0 })
            for (key, known) in files where key.root == .library {
                guard let path = moved(key.path) else { continue }
                files.removeValue(forKey: key)
                files[FileKey(root: .library, path: path)] = known
            }
        case .removeFolder(let path):
            guard root == .library else { return }
            folders = folders.filter { $0 != path && !$0.hasPrefix(path + "/") }
            others = others.filter { !$0.hasPrefix(path + "/") }
            for key in files.keys where key.root == .library && key.path.hasPrefix(path + "/") { files.removeValue(forKey: key) }
        }
    }
}
