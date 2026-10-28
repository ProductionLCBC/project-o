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

    /// Spec 1 §5 — every document under a root as the loader sees it: `.json`
    /// files by relative path, skipping the media root, logs and snapshots
    /// (written by the app, read by nothing it depends on), and "a sync tool's
    /// temporary and partial files (names beginning with a dot or ending in
    /// .tmp)".
    public static func snapshot(ofRoot root: URL) throws -> RootSnapshot {
        var files: [String: Data] = [:]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: []) else {
            return RootSnapshot()
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ["media", "logs", "snapshots"].contains(relative) || FileLayout.isIgnored(path: relative) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true, url.pathExtension == "json", !FileLayout.isIgnored(path: relative) else { continue }
            files[relative] = try Data(contentsOf: url)
        }
        return RootSnapshot(files: files)
    }

    /// Spec 1 §7 — the relative paths of every file under the media root, for
    /// the missing state. Hidden files are not media.
    public static func existingMediaPaths(mediaRoot: URL) throws -> Set<String> {
        var paths: Set<String> = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: mediaRoot, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return paths
        }
        let prefix = mediaRoot.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.path
            if path.hasPrefix(prefix) { paths.insert(String(path.dropFirst(prefix.count))) }
        }
        return paths
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
            }
        }
    }

    static func replace(_ data: Data, at url: URL, crash: Bool) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A name the loader ignores (Spec 1 §5): a leading dot and a .tmp suffix.
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
        if crash { throw SimulatedCrash() }
        guard rename(temporary.path, url.path) == 0 else { throw FileError.last("rename", url.path) }
        syncFolder(folder)
        sweepTemporaries(for: url)
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

    static func move(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard rename(from.path, to.path) == 0 else { throw FileError.last("move", from.path) }
        syncFolder(from.deletingLastPathComponent())
        syncFolder(to.deletingLastPathComponent())
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
