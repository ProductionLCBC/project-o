// OEngine — Spec 9 §8, the seam every file the engine writes goes through.

import Darwin
import Foundation
import OCore
import OFormats

/// Spec 9 §8 — "The clock, the time zone, free space and the file system's
/// failures are seams, so tests need no real disk to fill and no waiting."
/// The documents (Spec 5 §2), the logs and the black box (Spec 9 §2),
/// `state/last.json` (§4) and snapshots (§3) all write through one `Disk`, so
/// one switch makes every writer see the same full or low volume (§7).
/// Nothing here runs on the render or control threads: each writer calls it
/// from its own queue.
public final class Disk: Sendable {
    /// Why a write failed. Spec 9 §7 — "When a write fails for want of space"
    /// is `full`; anything else keeps the writer's ordinary retry.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case full(String)
        case other(String)

        public var isFull: Bool {
            if case .full = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .full(let reason), .other(let reason): return reason
            }
        }

        /// The failure a thrown error stands for.
        public init(_ error: Error) {
            if let failure = error as? Failure {
                self = failure
            } else if let file = error as? FileError {
                self = file.isOutOfSpace ? .full(file.description) : .other(file.description)
            } else {
                self = .other("\(error)")
            }
        }
    }

    public struct Seams: Sendable {
        /// A write to this file that must fail, before anything is written; nil lets it through.
        public var refuse: (@Sendable (URL) -> Failure?)?
        /// The free bytes of the volume holding a folder; nil when it can't be read.
        public var freeBytes: @Sendable (URL) -> Int64?
        /// Every append and replace that was carried out, with its bytes.
        public var wrote: (@Sendable (URL, Data) -> Void)?
        /// Every file synced.
        public var synced: (@Sendable (URL) -> Void)?

        public init(refuse: (@Sendable (URL) -> Failure?)? = nil,
                    freeBytes: @escaping @Sendable (URL) -> Int64? = Disk.volumeFreeBytes,
                    wrote: (@Sendable (URL, Data) -> Void)? = nil, synced: (@Sendable (URL) -> Void)? = nil) {
            self.refuse = refuse
            self.freeBytes = freeBytes
            self.wrote = wrote
            self.synced = synced
        }
    }

    public let seams: Seams

    public init(seams: Seams = Seams()) {
        self.seams = seams
    }

    /// The real disk, with nothing watching.
    public static let live = Disk()

    /// Spec 8 §3's line, which Spec 9 §7 shares — the free space the volume
    /// offers for files that matter.
    public static func volumeFreeBytes(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// The free bytes of the volume holding `folder`.
    public func freeBytes(at folder: URL) -> Int64? {
        seams.freeBytes(folder)
    }

    // MARK: - Atomic writes (Spec 1 §5)

    /// Spec 1 §5 — a write plan carried out in order, each replace through "a
    /// temporary file in the same folder", an fsync and a rename. Throws the
    /// `Failure` of the first operation that fails.
    public func execute(_ plan: WritePlan, in root: URL) throws {
        for operation in plan.operations {
            var written: (URL, Data)?
            switch operation {
            case .replace(let path, let data):
                written = (root.appendingPathComponent(path), data)
            case .copy(_, let to):
                if let refusal = seams.refuse?(root.appendingPathComponent(to)) { throw refusal }
            case .move, .remove, .makeFolder, .renameFolder, .removeFolder:
                break
            }
            if let (url, _) = written, let refusal = seams.refuse?(url) { throw refusal }
            do {
                try LocalFiles.execute(WritePlan(operations: [operation]), in: root)
            } catch {
                throw Failure(error)
            }
            if let (url, data) = written { seams.wrote?(url, data) }
        }
    }

    /// One file written whole and atomically, its folder made when it isn't there.
    public func replace(_ data: Data, at url: URL) throws {
        try execute(WritePlan(operations: [.replace(path: url.lastPathComponent, data: data)]), in: url.deletingLastPathComponent())
    }

    /// A file removed; one already gone is not an error. Removing frees space
    /// and needs none (Spec 9 §7), so the seam never refuses it.
    public func remove(_ url: URL) throws {
        if unlink(url.path) != 0, errno != ENOENT {
            let code = errno
            throw Failure.other("remove \(url.path): \(String(cString: strerror(code)))")
        }
    }

    // MARK: - Appending (Spec 9 §2)

    /// A file open for appending: a log's or the black box's. Confined to the
    /// thread or queue that opened it.
    public final class Appender {
        public let url: URL
        private let disk: Disk
        private var descriptor: Int32
        /// Whether bytes were appended since the last sync.
        public private(set) var isDirty = false
        /// The file's size, as this appender left it.
        public private(set) var size: Int64

        /// Spec 9 §2 — "When the engine opens a file whose last byte isn't a
        /// newline, as a crash or a power cut can leave it, it ends that line
        /// first."
        fileprivate init(url: URL, disk: Disk) throws {
            self.url = url
            self.disk = disk
            if let refusal = disk.seams.refuse?(url) { throw refusal }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw Failure(Self.cocoa(error, "make folder", url.deletingLastPathComponent().path))
            }
            descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
            guard descriptor >= 0 else { throw Failure(FileError.system("open", url.path, errno)) }
            let end = lseek(descriptor, 0, SEEK_END)
            size = Int64(max(0, end))
            if end > 0 {
                var last: UInt8 = 0
                if pread(descriptor, &last, 1, end - 1) == 1, last != UInt8(ascii: "\n") {
                    try write(Data([UInt8(ascii: "\n")]))
                }
            }
        }

        deinit {
            if descriptor >= 0 { Darwin.close(descriptor) }
        }

        /// Spec 9 §2 — "A group's lines go out in one write": `data` in one
        /// `write` call, repeated only when the system took part of it.
        public func append(_ data: Data) throws {
            if let refusal = disk.seams.refuse?(url) { throw refusal }
            try write(data)
            disk.seams.wrote?(url, data)
        }

        private func write(_ data: Data) throws {
            guard descriptor >= 0 else { throw Failure.other("append \(url.path): the file is closed") }
            var failure: Failure?
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(descriptor, base + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        failure = Failure(FileError.system("append", url.path, errno))
                        return
                    }
                    offset += n
                }
            }
            if let failure { throw failure }
            size += Int64(data.count)
            isDirty = true
        }

        /// Spec 9 §2 — "each file is synced once a second": the bytes
        /// appended so far reach the disk. Nothing to do when none were.
        public func sync() {
            guard isDirty, descriptor >= 0 else { return }
            _ = fsync(descriptor)
            isDirty = false
            disk.seams.synced?(url)
        }

        public func close() {
            guard descriptor >= 0 else { return }
            sync()
            Darwin.close(descriptor)
            descriptor = -1
        }

        /// A Foundation error as a file error, keeping the system's error number when it has one.
        static func cocoa(_ error: Error, _ operation: String, _ path: String) -> FileError {
            let outer = error as NSError
            let inner = outer.userInfo[NSUnderlyingErrorKey] as? NSError
            var code: Int32 = 0
            if outer.domain == NSCocoaErrorDomain, outer.code == NSFileWriteOutOfSpaceError {
                code = ENOSPC
            } else if let inner, inner.domain == NSPOSIXErrorDomain {
                code = Int32(clamping: inner.code)
            }
            return FileError(operation: operation, path: path, reason: error.localizedDescription, code: code)
        }
    }

    /// Opens `url` for appending, making it and its folder when they aren't there.
    public func appender(at url: URL) throws -> Appender {
        try Appender(url: url, disk: self)
    }
}

extension FileError {
    /// A system call's failure, by its error number.
    static func system(_ operation: String, _ path: String, _ code: Int32) -> FileError {
        FileError(operation: operation, path: path, reason: String(cString: strerror(code)), code: code)
    }
}
