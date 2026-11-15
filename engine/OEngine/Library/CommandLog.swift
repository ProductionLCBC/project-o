// OEngine — Spec 2 §9, the command log in memory; Spec 5 §5, typing; Spec 9 §2, notes.

import Foundation
import OCore

/// Spec 2 §9 — "One JSON line per executed command or note"; Spec 9 §2 —
/// "`seq` counts from 1 at each launch". This run's lines in order, the last
/// `capacity` of them, in memory on the control side, and every one handed to
/// `sink` as it is logged, which is the day's file once the run has one
/// (`LogWriter`).
///
/// Spec 5 §5 — "Typing. Edits that set the same text, from the same client,
/// fold into one edit per second ... A run starts with the first such edit
/// and closes one second later. The engine then writes one log line and
/// pushes one undo step, whose inverse is the value from before the run. If
/// typing continues, the next edit starts a new run, and any other command
/// from that client closes the run early." Each edit of a run still applies
/// at once; the run's one line, written when it closes, carries the last
/// value, the inverse from before the run and the group of its first edit.
///
/// Spec 9 §2 — notes share the lines' `seq`: "the engine stamps `ts`, `seq`
/// and the client's source, writes the line, and answers `ok` with the `seq`".
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

    /// Spec 9 §2 — what became of a client's note.
    public enum NoteOutcome: Equatable, Sendable {
        /// Written, at this `seq`.
        case written(seq: Int)
        /// "beyond that a note is answered `noop` and not written".
        case capped
        /// "or the note is refused with `badValue`".
        case refused(Rejection)
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
    private var kept: [LogLine] = []
    private var seq = 0
    private var runs: [String: TypingRun] = [:]
    private var limiter = NoteLimiter()
    private var sink: (@Sendable ([LogLine]) -> Void)?
    /// The lines of the call in hand, handed to the sink in one batch.
    private var batch: [LogLine] = []

    public init(capacity: Int = CommandLog.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Spec 9 §2 — where every line goes as it is logged: one call for a
    /// group's lines, in order, made under the log's own lock so the calls
    /// arrive in `seq` order. The sink only hands the lines on (to the log
    /// thread's queue); it never waits for the disk.
    public func attach(sink: @escaping @Sendable ([LogLine]) -> Void) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    /// The commands' entries kept, oldest first; the notes are in `lines`.
    public var entries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return kept.suffix(capacity).compactMap(\.entry)
    }

    /// Every line kept, commands and notes, oldest first.
    public var lines: [LogLine] {
        lock.lock()
        defer { lock.unlock() }
        return Array(kept.suffix(capacity))
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
        defer { hand(); lock.unlock() }
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
            append(.entry(LogEntry(line, seq: seq + 1, ts: ts)))
            return Logged(executed: line, seq: seq, folded: false)
        }
    }

    /// Spec 9 §2 — a note of the engine's own, or one already admitted: the
    /// next `seq`, stamped `ts`. "A note changes nothing and is never undone."
    @discardableResult
    public func note(_ note: [String: JSONValue], text: String, source: CommandSource, ts: String, dropped: Int? = nil) -> Int {
        lock.lock()
        defer { hand(); lock.unlock() }
        append(.note(LogNote(ts: ts, seq: seq + 1, source: source, note: note, text: text, dropped: dropped)))
        return seq
    }

    /// Spec 9 §2 — a client's note: checked against the limits (`badValue`),
    /// then against the cap of ten a second for `client` at engine time `now`
    /// (nanoseconds), then written with the count dropped before it.
    public func clientNote(_ note: [String: JSONValue], text: String, source: CommandSource, client: String, now: Int64,
                           ts: String) -> NoteOutcome {
        if let rejection = LogNote.check(note: note, text: text) { return .refused(rejection) }
        lock.lock()
        defer { hand(); lock.unlock() }
        switch limiter.admit(client: client, now: now) {
        case .refused:
            return .capped
        case .written(let dropped):
            append(.note(LogNote(ts: ts, seq: seq + 1, source: source, note: note, text: text, dropped: dropped > 0 ? dropped : nil)))
            return .written(seq: seq)
        }
    }

    /// Spec 5 §5 — "any other command from that client closes the run early":
    /// one rejected at the boundary too.
    public func closeRun(of client: String) {
        lock.lock()
        closeRunLocked(client)
        hand()
        lock.unlock()
    }

    /// The runs a second old by `now` close, each its one line, in the order
    /// they close.
    public func closeRuns(now: MonotonicTime) {
        lock.lock()
        defer { hand(); lock.unlock() }
        let due = runs.filter { $0.value.closesAt <= now }.sorted { ($0.value.closesAt, $0.key) < ($1.value.closesAt, $1.key) }
        for (client, _) in due { closeRunLocked(client) }
    }

    /// Every open run closes: the engine stops, or a test reads the log.
    public func flush() {
        lock.lock()
        defer { hand(); lock.unlock() }
        for client in runs.keys.sorted() { closeRunLocked(client) }
    }

    /// A typing run's one line is a group of its own: its own batch, ahead of what follows.
    private func closeRunLocked(_ client: String) {
        guard let run = runs.removeValue(forKey: client) else { return }
        hand()
        let line = ExecutedCommand(group: run.group, source: run.source, command: run.command, result: run.result, effects: [],
                                   inverse: run.inverse)
        append(.entry(LogEntry(line, seq: seq + 1, ts: run.ts)))
        hand()
    }

    private func append(_ line: LogLine) {
        seq = line.seq
        kept.append(line)
        batch.append(line)
        // Trimmed a quarter at a time, so a long run doesn't shift the array on every line.
        if kept.count > capacity + capacity / 4 { kept.removeFirst(kept.count - capacity) }
    }

    /// Spec 9 §2 — "A group's lines go out in one write": the batch in hand, to the sink.
    private func hand() {
        guard !batch.isEmpty else { return }
        sink?(batch)
        batch.removeAll(keepingCapacity: true)
    }
}
