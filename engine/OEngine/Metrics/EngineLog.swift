// OEngine — Spec 4 §12, "the log sees the detail".

import Foundation
import os

/// The engine's log: unified logging for the machine, plus a bounded memory
/// of recent lines the tests and the watchdog read. Never used on the render
/// thread, which writes codes into the metrics ring instead (Spec 4 §3).
public final class EngineLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info, warning, error, severe }

    public struct Line: Equatable, Sendable {
        public var level: Level
        public var message: String
    }

    private let logger: Logger
    private let lock = NSLock()
    private var lines: [Line] = []
    private let keep: Int

    public init(category: String, keep: Int = 512) {
        logger = Logger(subsystem: "o.engine", category: category)
        self.keep = keep
    }

    public func info(_ message: String) { write(.info, message) }
    public func warning(_ message: String) { write(.warning, message) }
    public func error(_ message: String) { write(.error, message) }
    /// Spec 4 §12 — "log as a severe event".
    public func severe(_ message: String) { write(.severe, message) }

    private func write(_ level: Level, _ message: String) {
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .severe: logger.fault("\(message, privacy: .public)")
        }
        lock.lock()
        lines.append(Line(level: level, message: message))
        if lines.count > keep { lines.removeFirst(lines.count - keep) }
        lock.unlock()
    }

    /// The recent lines, oldest first.
    public var recent: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func contains(_ fragment: String) -> Bool {
        recent.contains { $0.message.contains(fragment) }
    }
}
