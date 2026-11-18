// OApp — Spec 10 §2, where the roots are and what the app reads in the machine root.

import Foundation

/// Spec 10 §2, "Where the roots are" — "The app keeps the paths of the
/// library root and the machine root in its own preferences, set at first
/// run (§13). Everything else lives in the roots."
public struct EngineRoots: Equatable, Sendable {
    public var library: URL
    public var machine: URL

    public init(library: URL, machine: URL) {
        self.library = library
        self.machine = machine
    }

    /// Spec 10 §2 — "`engine.sock` in the machine root".
    public var socket: URL { EngineSocketPath.url(machineRoot: machine) }

    /// Spec 10 §2 — "The app opens `machine/logs/engine-console.log` for
    /// appending as the engine's standard output and error".
    public var consoleLog: URL { machine.appendingPathComponent("logs/engine-console.log") }

    /// Spec 10 §2 — "The engine holds an exclusive lock on
    /// `machine/.engine.lock` while it runs, with its process id in the file."
    public var lockFile: URL { machine.appendingPathComponent(".engine.lock") }

    /// Spec 10 §13 — "When the machine root has no `machine.json`", the
    /// engine writes the first-run documents, and the app "starts the engine
    /// with `--campus`".
    public var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: machine.appendingPathComponent("machine.json").path)
    }

    /// The process id the lock file names, or nil. Spec 10 §2 (Area 13
    /// reading) — the file outlives its engine, so the id is a hint: the app
    /// never takes the lock itself (even to look, which would make a
    /// starting engine find the root held), and checks what the id runs
    /// before it ends anything.
    public func lockHolder() -> Int32? {
        guard let data = try? Data(contentsOf: lockFile), let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    /// Spec 10 §2 — "the app shows the console log's last lines": the last
    /// `count` lines of the console log, oldest first (Area 13 reading:
    /// twenty). Only the file's tail is read, since it may hold 10 MB.
    public func consoleTail(lines count: Int = 20) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: consoleLog) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let wanted: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > wanted ? size - wanted : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }

    /// Spec 10 §1 — "The app writes nothing in the roots but
    /// `machine/view.json` and the engine's console log, which it opens for
    /// the engine (§2)". The log's folder has to be there to open the log in
    /// (Area 13 reading: at first run the app makes `machine/` and
    /// `machine/logs/`, and nothing else).
    public func prepareConsoleLog() throws {
        try FileManager.default.createDirectory(at: consoleLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

/// Spec 10 §2 — where the roots' paths are kept: "in its own preferences".
/// A seam, since a test has no preferences of the app's.
@MainActor
public protocol RootsStore: AnyObject {
    var roots: EngineRoots? { get set }
    /// Spec 10 §13 — the campus name the first-run sheet asked for, given to the engine as `--campus`.
    var campus: String? { get set }
}

/// The live store: the app's own defaults.
@MainActor
public final class DefaultsRootsStore: RootsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var roots: EngineRoots? {
        get {
            guard let library = defaults.string(forKey: "libraryRoot"), let machine = defaults.string(forKey: "machineRoot"),
                  !library.isEmpty, !machine.isEmpty else { return nil }
            return EngineRoots(library: URL(fileURLWithPath: library), machine: URL(fileURLWithPath: machine))
        }
        set {
            defaults.set(newValue?.library.path, forKey: "libraryRoot")
            defaults.set(newValue?.machine.path, forKey: "machineRoot")
        }
    }

    public var campus: String? {
        get { defaults.string(forKey: "campus") }
        set { defaults.set(newValue, forKey: "campus") }
    }
}
