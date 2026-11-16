// OEngine — Spec 10 §2, one engine per machine root.

import Darwin
import Foundation
import Synchronization

/// Spec 10 §2 — "One engine per machine root. The engine holds an exclusive
/// lock on `machine/.engine.lock` while it runs, with its process id in the
/// file. A second engine on the same root exits at once with status 3 and a
/// line saying which engine holds it."
///
/// The lock is the kernel's, on the open file, so it goes when the process
/// goes, however it ends: a crashed engine never leaves a root locked. The
/// file stays behind with the last engine's process id; only the lock on it
/// says an engine is running.
public final class EngineLock: @unchecked Sendable {
    public static let fileName = ".engine.lock"

    /// Spec 10 §2 — "status 3": what `oengine run` exits with when another
    /// engine holds the root, which the app doesn't count as an engine ending.
    public static let heldExitStatus: Int32 = 3

    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// Another engine holds the root; its process id when the file names one.
        case held(by: pid_t?)
        /// The lock file could not be made or opened.
        case unavailable(path: String, code: Int32)

        public var description: String {
            switch self {
            case .held(let pid?): return "engine \(pid) holds this machine root"
            case .held(nil): return "another engine holds this machine root"
            case .unavailable(let path, let code): return "the lock file \(path) could not be opened (\(String(cString: strerror(code))))"
            }
        }
    }

    public let url: URL
    private let descriptor: Int32
    private let released = Atomic<Bool>(false)
    /// What taking the lock made that wasn't there: the lock file, and the folders down to the machine root,
    /// deepest first. `withdraw` takes them away again.
    private let madeFile: Bool
    private let madeFolders: [URL]

    private init(url: URL, descriptor: Int32, madeFile: Bool, madeFolders: [URL]) {
        self.url = url
        self.descriptor = descriptor
        self.madeFile = madeFile
        self.madeFolders = madeFolders
    }

    deinit { release() }

    /// Spec 10 §2 — takes the root for this process, or says who has it. The
    /// machine root is made when it isn't there, since a new install's is the
    /// engine's to write (Spec 10 §13) and the lock comes first.
    public static func acquire(machineRoot: URL) -> Result<EngineLock, Failure> {
        let url = machineRoot.appendingPathComponent(fileName)
        // The folders this launch is about to make, deepest first, so a launch that gives up can leave nothing behind.
        var missing: [URL] = []
        var folder = machineRoot.standardizedFileURL
        while folder.path != "/", !FileManager.default.fileExists(atPath: folder.path) {
            missing.append(folder)
            folder = folder.deletingLastPathComponent()
        }
        let madeFile = !FileManager.default.fileExists(atPath: url.path)
        try? FileManager.default.createDirectory(at: machineRoot, withIntermediateDirectories: true)
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .failure(.unavailable(path: url.path, code: errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return .failure(.held(by: holder(machineRoot: machineRoot))) }
            return .failure(.unavailable(path: url.path, code: code))
        }
        // "with its process id in the file": written whole over whatever the last engine left.
        let text = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pwrite(descriptor, text, text.count, 0)
        _ = fsync(descriptor)
        return .success(EngineLock(url: url, descriptor: descriptor, madeFile: madeFile, madeFolders: missing))
    }

    /// Spec 10 §2 — "finding the engine by the process id in `.engine.lock`":
    /// the id the file names, or nil when there is no file or no id in it.
    public static func holder(machineRoot: URL) -> pid_t? {
        guard let data = try? Data(contentsOf: machineRoot.appendingPathComponent(fileName)),
              let text = String(data: data, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// Lets the root go, as a stop on request does before the process exits. Once.
    public func release() {
        guard !released.exchange(true, ordering: .acquiringAndReleasing) else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Spec 10 §13 (Adam's answer of 2026-11-15) — a launch that is refused
    /// "writes nothing": lets the root go and takes away the lock file and the
    /// folders that taking the lock made. A folder that holds anything, or
    /// was there before, stays.
    public func withdraw() {
        guard !released.exchange(true, ordering: .acquiringAndReleasing) else { return }
        // The file goes while the lock is still held, so no other engine can have taken it in between.
        if madeFile { unlink(url.path) }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        for folder in madeFolders where rmdir(folder.path) != 0 { break }
    }
}
