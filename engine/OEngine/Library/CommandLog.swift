// OEngine — Spec 2 §9, the command log in memory; Spec 5 §5, typing.

import Foundation
import OCore

/// Spec 2 §9 — "One JSON line per executed command"; Spec 9 §2 — "`seq`
/// counts from 1 at each launch". This run's lines in order, the last
/// `capacity` of them, in memory on the control side; Area 12 writes them to
/// the day's file.
///
/// Spec 5 §5 — "Typing. Edits that set the same text, from the same client,
/// fold into one edit per second ... A run starts with the first such edit
/// and closes one second later. The engine then writes one log line and
/// pushes one undo step, whose inverse is the value from before the run. If
/// typing continues, the next edit starts a new run, and any other command
/// from that client closes the run early." Each edit of a run still applies
/// at once; the run's one line, written when it closes, carries the last
/// value, the inverse from before the run and the group of its first edit.
public final class CommandLog: @unchecked Sendable {
    public static let defaultCapacity = 10_000
    /// Spec 5 §5 — "closes one second later", on engine time.
    public static let typingRunNanoseconds: Int64 = 1_000_000_000

    /// One executed command as the log took it: the group it is logged under
    /// (a typing run's, when folded) and its line's `seq`, or, folded into a
    /// run that has not closed, the `seq` of the last line logged before it
    /// (Spec 2 §9, the `seq` an event carries).
    public struct Logged: Sendable {
        public var executed: ExecutedCommand
        public var seq: Int
        public var folded: Bool
    }

    private struct TypingRun {
        var key: TypingKey
        var group: GroupID
        var source: CommandSource
        var command: Command
        var inverse: Command?
        var result: CommandResult
        var ts: String
        var closesAt: MonotonicTime
    }

    public let capacity: Int
    private let lock = NSLock()
    private var lines: [LogEntry] = []
    private var seq = 0
    private var runs: [String: TypingRun] = [:]

    public init(capacity: Int = CommandLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// The lines kept, oldest first.
    public var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(lines.suffix(capacity))
    }

    /// The `seq` of the last line logged; 0 before the first.
    public var lastSeq: Int {
        lock.lock()
        defer { lock.unlock() }
        return seq
    }

    /// The clients with a typing run open.
    public var openRuns: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(runs.keys)
    }

    /// The lines of one group's run, from `client` (nil: nobody's typing), at
    /// engine time `now`, stamped `ts`. A group of one edit that sets text
    /// folds into its client's run; anything else from the client closes the
    /// run first, so the lines stay in the order they happened.
    public func record(_ executed: [ExecutedCommand], client: String?, now: MonotonicTime, ts: String) -> [Logged] {
        lock.lock()
        defer { lock.unlock() }
        if let client, executed.count == 1, let line = executed.first, line.result == .ok || line.result == .noop,
           case .edit(let edit) = line.command, let key = edit.typingKey {
            if var run = runs[client], run.key == key, now < run.closesAt {
                run.command = line.command
                run.inverse = run.inverse ?? line.inverse
                if line.result == .ok { run.result = .ok }
                run.ts = ts
                runs[client] = run
                var folded = line
                folded.group = run.group
                return [Logged(executed: folded, seq: seq, folded: true)]
            }
            closeRunLocked(client)
            runs[client] = TypingRun(key: key, group: line.group, source: line.source, command: line.command, inverse: line.inverse,
                                     result: line.result, ts: ts, closesAt: now.advanced(by: Self.typingRunNanoseconds))
            return [Logged(executed: line, seq: seq, folded: true)]
        }
        if let client { closeRunLocked(client) }
        return executed.map { line in
            append(LogEntry(line, seq: seq + 1, ts: ts))
            return Logged(executed: line, seq: seq, folded: false)
        }
    }

    /// Spec 5 §5 — "any other command from that client closes the run early":
    /// one rejected at the boundary too.
    public func closeRun(of client: String) {
        lock.lock()
        closeRunLocked(client)
        lock.unlock()
    }

    /// The runs a second old by `now` close, each its one line, in the order
    /// they close.
    public func closeRuns(now: MonotonicTime) {
        lock.lock()
        defer { lock.unlock() }
        let due = runs.filter { $0.value.closesAt <= now }.sorted { ($0.value.closesAt, $0.key) < ($1.value.closesAt, $1.key) }
        for (client, _) in due { closeRunLocked(client) }
    }

    /// Every open run closes: the engine stops, or a test reads the log.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        for client in runs.keys.sorted() { closeRunLocked(client) }
    }

    private func closeRunLocked(_ client: String) {
        guard let run = runs.removeValue(forKey: client) else { return }
        let line = ExecutedCommand(group: run.group, source: run.source, command: run.command, result: run.result, effects: [],
                                   inverse: run.inverse)
        append(LogEntry(line, seq: seq + 1, ts: run.ts))
    }

    private func append(_ entry: LogEntry) {
        seq = entry.seq
        lines.append(entry)
        // Trimmed a quarter at a time, so a long run doesn't shift the array on every line.
        if lines.count > capacity + capacity / 4 { lines.removeFirst(lines.count - capacity) }
    }
}
