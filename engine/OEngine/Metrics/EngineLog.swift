// OEngine — Spec 4 §12, "the log sees the detail".

import Foundation
import OCore
import os

/// The engine's log: unified logging for the machine, plus a bounded memory
/// of recent lines the tests and the watchdog read. Never used on the render
/// thread, which writes codes into the metrics ring instead (Spec 4 §3).
///
/// Spec 9 §8 — "`EngineLog` also writes its lines to the engine log": once a
/// run's log file is open, each line is handed on to it as it is logged, the
/// lines from before it opened first (Spec 9 §2, `kind: log`, "with `level`,
/// `category` and `message`, as the engine's log has them").
public final class EngineLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info, warning, error, severe }

    public struct Line: Equatable, Sendable {
        public var level: Level
        public var message: String
    }

    /// One line as it was logged: when, at what level, in which category, and
    /// its words. `record`, when the line stands for something the engine log
    /// writes with a kind of its own (Spec 9 §2, `media`), is that kind and
    /// its fields; the file then gets the record and not the words.
    public struct Entry: Sendable {
        public var at: Date
        public var level: Level
        public var category: String
        public var message: String
        public var record: (kind: String, fields: [String: JSONValue])?
    }

    public let category: String
    private let logger: Logger
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let keep: Int
    private var clock: @Sendable () -> Date = { Date() }
    private var tee: (@Sendable (Entry) -> Void)?

    public init(category: String, keep: Int = 512) {
        self.category = category
        logger = Logger(subsystem: "o.engine", category: category)
        self.keep = keep
    }

    public func info(_ message: String) { write(.info, message) }
    public func warning(_ message: String) { write(.warning, message) }
    public func error(_ message: String) { write(.error, message) }
    /// Spec 4 §12 — "log as a severe event".
    public func severe(_ message: String) { write(.severe, message) }

    /// Spec 9 §2 — a line the engine log's file writes with a kind of its
    /// own: the words go to unified logging and the memory as any line's do.
    public func info(_ message: String, record kind: String, _ fields: [String: JSONValue]) {
        write(.info, message, record: (kind, fields))
    }

    /// Spec 4 §2 — "the wall clock is read only to stamp log lines": the
    /// clock the lines are stamped by, the engine's own once it is built, so
    /// a test's clock stamps them too.
    public func setClock(_ clock: @escaping @Sendable () -> Date) {
        lock.lock()
        self.clock = clock
        lock.unlock()
    }

    /// Spec 9 §8 — hand every line to `tee` from now on, the kept lines
    /// first, in the order they were logged. One tee at a time: the run's.
    public func attach(_ tee: @escaping @Sendable (Entry) -> Void) {
        lock.lock()
        let earlier = entries
        self.tee = tee
        // Under the lock, so a line logged meanwhile follows the earlier ones.
        for entry in earlier { tee(entry) }
        lock.unlock()
    }

    private func write(_ level: Level, _ message: String, record: (kind: String, fields: [String: JSONValue])? = nil) {
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .severe: logger.fault("\(message, privacy: .public)")
        }
        lock.lock()
        let entry = Entry(at: clock(), level: level, category: category, message: message, record: record)
        entries.append(entry)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        // The tee only hands the line to the log's queue (`LogWriter`), so it is called in order, under the lock.
        tee?(entry)
        lock.unlock()
    }

    /// The recent lines, oldest first.
    public var recent: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { Line(level: $0.level, message: $0.message) }
    }

    public func contains(_ fragment: String) -> Bool {
        recent.contains { $0.message.contains(fragment) }
    }
}
