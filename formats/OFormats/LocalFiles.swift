// OFormats — Spec 1 §5 at the file boundary.
//
// The one place that touches disk for the Spec 1 roots: it reads a root's
// documents into a `RootSnapshot` for the pure loader in OCore, executes the
// pure writer's `WritePlan` with the temporary file, fsync and rename of §5,
// and hashes media files for §4. Foundation and POSIX only, so it builds on
// Linux with the rest.

import Foundation
import OCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The crash the atomic-write test simulates (Spec 1 §10): thrown after the
/// temporary file is written and synced, before the rename.
public struct SimulatedCrash: Error, Sendable {
    public init() {}
}

/// A file operation that failed, with the system's reason.
public struct FileError: Error, Equatable, Sendable, CustomStringConvertible {
    public var operation: String
    public var path: String
    public var reason: String

    public init(operation: String, path: String, reason: String) {
        self.operation = operation
        self.path = path
        self.reason = reason
    }

    public var description: String { "\(operation) \(path): \(reason)" }

    static func last(_ operation: String, _ path: String) -> FileError {
        FileError(operation: operation, path: path, reason: String(cString: strerror(errno)))
    }
}

/// Spec 1 §5 — reading and writing a root folder.
public enum LocalFiles {
    // MARK: - Reading

    /// Folders at the top of a root that hold no documents the loader reads:
    /// the media root, the logs, snapshots, black box and thumbnails the
    /// engine writes, and Spec 5 §10's conflicts, which "the loader ignores".
    static let unreadFolders: Set<String> = ["media", "logs", "snapshots", "blackbox", "thumbnails", "conflicts"]

    /// Spec 1 §5 — every document under a root as the loader sees it: `.json`
    /// files by relative path, skipping the media root, logs and snapshots
    /// (written by the app, read by nothing it depends on), and "a sync tool's
    /// temporary and partial files (names beginning with a dot or ending in
    /// .tmp, anything in a folder whose name begins with a dot, ...)". Spec 7
    /// §2 — with every folder walked, empty ones too, the visible files that
    /// aren't documents, and each document's modification date; Spec 9 §6 —
    /// the kept versions by name and date, without their bytes.
    public static func snapshot(ofRoot root: URL) throws -> RootSnapshot {
        var snapshot = RootSnapshot()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            return snapshot
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if unreadFolders.contains(relative) || FileLayout.isIgnored(path: relative) {
                    enumerator.skipDescendants()
                } else {
                    snapshot.folders.insert(relative)
                }
                continue
            }
            guard values?.isRegularFile == true, !FileLayout.isIgnored(path: relative) else { continue }
            let modified = values?.contentModificationDate.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0
            guard url.pathExtension == "json" else {
                snapshot.otherFiles.insert(relative)
                continue
            }
            if relative.hasPrefix("versions/") {
                snapshot.versions[relative] = modified
                continue
            }
            snapshot.files[relative] = try Data(contentsOf: url)
            snapshot.modified[relative] = modified
        }
        return snapshot
    }

    /// Spec 1 §4 — the id of a file's bytes, streamed through OCore's SHA-256.
    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return MediaID.hashPrefix + SHA256.hex(hasher.finalize())
    }

    // MARK: - Writing

    /// Spec 1 §5 — execute a plan in order. A `replace` "writes to a temporary
    /// file in the same folder, fsyncs, and renames over the original, so a
    /// crash mid-write leaves the previous file intact." With
    /// `crashAfterTemporaryWriteOf` naming a path, its replace stops after the
    /// fsync and before the rename, as the §10 test requires.
    public static func execute(_ plan: WritePlan, in root: URL, crashAfterTemporaryWriteOf crashPath: String? = nil) throws {
        for operation in plan.operations {
            switch operation {
            case .replace(let path, let data):
                try replace(data, at: root.appendingPathComponent(path), crash: path == crashPath)
            case .move(let from, let to):
                try move(root.appendingPathComponent(from), to: root.appendingPathComponent(to))
            case .remove(let path):
                try remove(root.appendingPathComponent(path))
            case .copy(let from, let to):
                try copy(root.appendingPathComponent(from), to: root.appendingPathComponent(to))
            case .makeFolder(let path):
                try makeFolder(root.appendingPathComponent(path))
            case .renameFolder(let from, let to):
                try renameFolder(root.appendingPathComponent(from), to: root.appendingPathComponent(to))
            case .removeFolder(let path):
                try removeFolder(root.appendingPathComponent(path))
            }
        }
    }

    static func replace(_ data: Data, at url: URL, crash: Bool) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = try writeTemporary(data, beside: url)
        if crash { throw SimulatedCrash() }
        guard rename(temporary.path, url.path) == 0 else { throw FileError.last("rename", url.path) }
        syncFolder(folder)
        sweepTemporaries(for: url)
    }

    /// The bytes written and synced to a temporary file in `url`'s folder,
    /// with a name the loader ignores (Spec 1 §5): a leading dot and a .tmp suffix.
    static func writeTemporary(_ data: Data, beside url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent("." + url.lastPathComponent + "." + String(UUID().uuidString.prefix(8)) + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw FileError.last("create", temporary.path) }
        var failure: FileError?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = FileError.last("write", temporary.path)
                    return
                }
                offset += n
            }
        }
        if let failure {
            close(fd)
            throw failure
        }
        guard fsync(fd) == 0 else {
            let error = FileError.last("fsync", temporary.path)
            close(fd)
            throw error
        }
        close(fd)
        return temporary
    }

    /// A save that completed leaves no temporary of its own document behind:
    /// the leftovers of an earlier crash on the same file are removed.
    static func sweepTemporaries(for url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = "." + url.lastPathComponent + "."
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            unlink(folder.appendingPathComponent(name).path)
        }
    }

    /// Spec 7 §2 — "Other files are never replaced": a rename refused when
    /// the new name is taken, and no folder made on the way.
    static func move(_ from: URL, to: URL) throws {
        guard renameNoReplace(from.path, to.path) == 0 else { throw FileError.last("move", from.path) }
        syncFolder(from.deletingLastPathComponent())
        syncFolder(to.deletingLastPathComponent())
    }

    /// A rename that fails with `EEXIST` when the new name is taken.
    static func renameNoReplace(_ from: String, _ to: String) -> Int32 {
        #if canImport(Darwin)
        return renamex_np(from, to, UInt32(RENAME_EXCL))
        #else
        // A hard link fails when the name is taken; then the old name goes.
        guard link(from, to) == 0 else { return -1 }
        return unlink(from)
        #endif
    }

    /// Spec 9 §6 — keep a file's bytes at a new path, "never written over":
    /// when the path is taken, there is nothing to do. The copy is written
    /// whole and synced before it takes its name.
    static func copy(_ from: URL, to: URL) throws {
        if FileManager.default.fileExists(atPath: to.path) { return }
        let data: Data
        do {
            data = try Data(contentsOf: from)
        } catch {
            throw FileError(operation: "copy", path: from.path, reason: "\(error)")
        }
        let folder = to.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = try writeTemporary(data, beside: to)
        if renameNoReplace(temporary.path, to.path) != 0 {
            let failure = errno
            unlink(temporary.path)
            if failure == EEXIST { return }
            throw FileError(operation: "copy", path: to.path, reason: String(cString: strerror(failure)))
        }
        syncFolder(folder)
    }

    /// Spec 7 §2 — `edit folder "PATH" create`: "Its parent must exist".
    static func makeFolder(_ url: URL) throws {
        guard mkdir(url.path, 0o755) == 0 else { throw FileError.last("make folder", url.path) }
        syncFolder(url.deletingLastPathComponent())
    }

    /// Spec 7 §2 — a folder's rename or move "in one directory rename that
    /// carries everything in it", refused onto a path that exists unless only
    /// the case changes.
    static func renameFolder(_ from: URL, to: URL) throws {
        let result: Int32
        if from.path.lowercased() == to.path.lowercased() {
            result = rename(from.path, to.path)
        } else {
            #if canImport(Darwin)
            result = renamex_np(from.path, to.path, UInt32(RENAME_EXCL))
            #else
            if access(to.path, F_OK) == 0 {
                errno = EEXIST
                result = -1
            } else {
                result = rename(from.path, to.path)
            }
            #endif
        }
        guard result == 0 else { throw FileError.last("rename folder", from.path) }
        syncFolder(from.deletingLastPathComponent())
        syncFolder(to.deletingLastPathComponent())
    }

    /// Spec 7 §2 — "Deletes the folder when it is empty: no lists, no visible
    /// files and no folders other than hidden ones. Hidden files and folders
    /// go with it". A folder already gone is not an error.
    static func removeFolder(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let names = try fm.contentsOfDirectory(atPath: url.path)
        if names.contains(where: { !$0.hasPrefix(".") }) {
            throw FileError(operation: "remove folder", path: url.path, reason: "not empty")
        }
        for name in names { try fm.removeItem(at: url.appendingPathComponent(name)) }
        guard rmdir(url.path) == 0 else { throw FileError.last("remove folder", url.path) }
        syncFolder(url.deletingLastPathComponent())
    }

    static func remove(_ url: URL) throws {
        if unlink(url.path) != 0 {
            if errno == ENOENT { return }
            throw FileError.last("remove", url.path)
        }
        syncFolder(url.deletingLastPathComponent())
    }

    /// Make a rename durable: fsync the folder that holds the entry.
    static func syncFolder(_ folder: URL) {
        let fd = open(folder.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }
}
