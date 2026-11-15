// OCore — Spec 9 §2, the note line, and a line of the command log of either kind.

import Foundation

/// Spec 9 §2 — "Some things worth a line aren't commands: a client's UI-only
/// actions, which Spec 2 §9 calls browsing, and the engine's own events ...
/// A note line carries `ts`, `seq`, `source`, `kind`, `note` and `text`, and
/// `dropped` when notes were dropped before it; it has no `group`, `command`,
/// `undo` or `result`". "A note changes nothing and is never undone."
/// Unknown keys survive (Spec 1 §8). The stamp and the sequence number are
/// the engine's: nothing here reads a clock.
public struct LogNote: Codable, Equatable, Sendable {
    /// Spec 9 §2 — "`text` holds at most 1,000 characters".
    public static let maximumTextCharacters = 1000
    /// Spec 9 §2 — "and `note` at most 4 KB".
    public static let maximumNoteBytes = 4096

    public var ts: String
    public var seq: Int
    public var source: CommandSource
    /// What happened, as an object: its `event`, and the fields Spec 9 §2 and
    /// Spec 10 §3 give each event.
    public var note: [String: JSONValue]
    public var text: String
    /// Spec 9 §2 — how many of this client's notes were refused before this one.
    public var dropped: Int?
    public var extra: [String: JSONValue]

    public init(ts: String, seq: Int, source: CommandSource, note: [String: JSONValue], text: String, dropped: Int? = nil,
                extra: [String: JSONValue] = [:]) {
        self.ts = ts
        self.seq = seq
        self.source = source
        self.note = note
        self.text = text
        self.dropped = dropped
        self.extra = extra
    }

    /// Spec 9 §2 — the note's `event`, such as `start` or `browse`.
    public var event: String? { note["event"]?.stringValue }

    /// Spec 9 §2 — "`text` holds at most 1,000 characters and `note` at most
    /// 4 KB, or the note is refused with `badValue`." The note is measured as
    /// its one-line JSON in UTF-8, the text in characters as a reader counts
    /// them. Nil when both fit.
    public static func check(note: [String: JSONValue], text: String) -> Rejection? {
        if text.count > maximumTextCharacters {
            return Rejection(reason: .badValue, message: "a note's text holds at most \(maximumTextCharacters) characters, not \(text.count)")
        }
        let bytes = JSONCanonical.line(.object(note)).utf8.count
        if bytes > maximumNoteBytes {
            return Rejection(reason: .badValue, message: "a note holds at most \(maximumNoteBytes) bytes, not \(bytes)")
        }
        return nil
    }

    /// Spec 2 §9 — the note as one JSON line with sorted keys.
    public var line: String {
        (try? JSONCoding.encode(self)).map(JSONCanonical.line) ?? "{}"
    }

    /// Spec 9 §2 — a note read back from its line.
    public init(line: String) throws {
        self = try JSONCoding.decode(LogNote.self, from: try JSONValue.parse(line))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ts, seq, source, kind, note, text, dropped
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        guard kind == LogKind.note.rawValue else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "a note line has kind note, not \(kind)")
        }
        ts = try c.decode(String.self, forKey: .ts)
        seq = try c.decode(Int.self, forKey: .seq)
        source = try c.decode(CommandSource.self, forKey: .source)
        note = try c.decode([String: JSONValue].self, forKey: .note)
        text = try c.decode(String.self, forKey: .text)
        dropped = try c.decodeIfPresent(Int.self, forKey: .dropped)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(seq, forKey: .seq)
        try c.encode(source, forKey: .source)
        try c.encode(LogKind.note, forKey: .kind)
        try c.encode(note, forKey: .note)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(dropped, forKey: .dropped)
    }
}

/// Spec 2 §9 as Spec 9 §9 corrected it — "One JSON line per executed command
/// or note (Spec 9 §2), appended to the day's log file,
/// `machine/logs/commands-YYYY-MM-DD.jsonl`": a line of either kind, told
/// apart by its `kind`.
public enum LogLine: Equatable, Sendable {
    case entry(LogEntry)
    case note(LogNote)

    public var seq: Int {
        switch self {
        case .entry(let entry): return entry.seq
        case .note(let note): return note.seq
        }
    }

    public var ts: String {
        switch self {
        case .entry(let entry): return entry.ts
        case .note(let note): return note.ts
        }
    }

    /// Spec 9 §2 — the logs split "By the machine's local day, in Spec 1 §3's
    /// `timeZone`". The engine stamps `ts` in that zone, so the day is the
    /// date the stamp begins with: `2026-11-08`.
    public var day: String { String(ts.prefix(10)) }

    public var entry: LogEntry? {
        if case .entry(let entry) = self { return entry }
        return nil
    }

    public var note: LogNote? {
        if case .note(let note) = self { return note }
        return nil
    }

    /// Spec 2 §9 — the line as JSON with sorted keys, without its newline.
    public var line: String {
        switch self {
        case .entry(let entry): return entry.line
        case .note(let note): return note.line
        }
    }

    /// One line read back: a note when its `kind` is `note`, else a command's entry.
    public init(line: String) throws {
        let tree = try JSONValue.parse(line)
        if tree["kind"]?.stringValue == LogKind.note.rawValue {
            self = .note(try JSONCoding.decode(LogNote.self, from: tree))
        } else {
            self = .entry(try JSONCoding.decode(LogEntry.self, from: tree))
        }
    }

    /// Spec 9 §2 — "Readers skip a line that doesn't parse, so a crash loses
    /// at most the last second": the lines of a log file's text, in order,
    /// without the ones that don't read.
    public static func reading(_ text: String) -> [LogLine] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { try? LogLine(line: String($0)) }
    }
}

/// Spec 9 §2 — "One client's notes are capped at ten a second (choice G-9):
/// beyond that a note is answered `noop` and not written, and the next note
/// written carries `dropped` with the count." The second is a sliding one of
/// engine time, per client; the caller gives the time, in nanoseconds.
public struct NoteLimiter: Equatable, Sendable {
    /// Spec 9 §2 — "ten a second".
    public static let perSecond = 10
    static let window: Int64 = 1_000_000_000

    public enum Verdict: Equatable, Sendable {
        /// The note is written; `dropped` is how many were refused since the last one written (0: none).
        case written(dropped: Int)
        /// Past the cap: answered `noop`, not written.
        case refused
    }

    /// Each client's notes written within the last second, oldest first.
    private var written: [String: [Int64]] = [:]
    private var dropped: [String: Int] = [:]

    public init() {}

    /// Whether `client`'s note at engine time `now` is written.
    public mutating func admit(client: String, now: Int64) -> Verdict {
        var recent = (written[client] ?? []).filter { now - $0 < Self.window }
        guard recent.count < Self.perSecond else {
            written[client] = recent
            dropped[client, default: 0] += 1
            return .refused
        }
        recent.append(now)
        written[client] = recent
        let count = dropped.removeValue(forKey: client) ?? 0
        return .written(dropped: count)
    }
}
