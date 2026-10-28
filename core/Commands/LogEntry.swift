// OCore — Spec 2 §9, the log entry.

import Foundation

/// Spec 2 §9 — "One JSON line per executed command, appended to the day's
/// log file in the machine root." The fields of the example: `ts`, `seq`,
/// `group`, `source`, `kind`, `undo`, `result`, `command`, `text`,
/// `snapshot`, and `fire` on the first command of a cue group; edit entries
/// carry `inverse`. A rejected result carries its `reason`. Unknown keys
/// survive (Spec 1 §8). The timestamp and the sequence number are the
/// engine's: nothing here reads a clock.
public struct LogEntry: Codable, Equatable, Sendable {
    public var ts: String
    public var seq: Int
    public var group: GroupID
    public var source: CommandSource
    public var kind: LogKind
    public var undo: UndoClass
    public var result: CommandResult
    public var command: Command
    public var text: String
    public var snapshot: String?
    public var fire: FireRecord?
    public var inverse: Command?
    public var extra: [String: JSONValue]

    public init(ts: String, seq: Int, group: GroupID, source: CommandSource, kind: LogKind, undo: UndoClass,
                result: CommandResult, command: Command, text: String, snapshot: String? = nil, fire: FireRecord? = nil,
                inverse: Command? = nil, extra: [String: JSONValue] = [:]) {
        self.ts = ts
        self.seq = seq
        self.group = group
        self.source = source
        self.kind = kind
        self.undo = undo
        self.result = result
        self.command = command
        self.text = text
        self.snapshot = snapshot
        self.fire = fire
        self.inverse = inverse
        self.extra = extra
    }

    /// Spec 2 §9 — the entries of a run, one per executed command, `seq`
    /// counting up from `firstSeq`, `kind` and `undo` from the command's
    /// vocabulary row. `snapshot` is left for the engine (runtime undo, v1.5).
    public static func entries(for outcome: RunOutcome, firstSeq: Int, ts: String) -> [LogEntry] {
        outcome.executed.enumerated().map { offset, executed in
            LogEntry(ts: ts, seq: firstSeq + offset, group: executed.group, source: executed.source,
                     kind: executed.command.logKind, undo: executed.command.undoClass, result: executed.result,
                     command: executed.command, text: CommandText.print(executed.command) ?? "", fire: executed.fire)
        }
    }

    /// Spec 2 §9 — the entry as one JSON line with sorted keys.
    public var line: String {
        (try? JSONCoding.encode(self)).map(JSONCanonical.line) ?? "{}"
    }

    /// Spec 2 §9 — an entry read back from its line.
    public init(line: String) throws {
        self = try JSONCoding.decode(LogEntry.self, from: try JSONValue.parse(line))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ts, seq, group, source, kind, undo, result, reason, command, text, snapshot, fire, inverse
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decode(String.self, forKey: .ts)
        seq = try c.decode(Int.self, forKey: .seq)
        group = try c.decode(GroupID.self, forKey: .group)
        source = try c.decode(CommandSource.self, forKey: .source)
        kind = try c.decode(LogKind.self, forKey: .kind)
        undo = try c.decode(UndoClass.self, forKey: .undo)
        let name = try c.decode(String.self, forKey: .result)
        switch name {
        case "ok": result = .ok
        case "blocked": result = .blocked
        case "noop": result = .noop
        case "steppedOn": result = .steppedOn
        case "rejected":
            let reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            result = .rejected(LogEntry.rejection(from: reason))
        default:
            throw DecodingError.dataCorruptedError(forKey: .result, in: c, debugDescription: "unknown result \(name)")
        }
        command = try c.decode(Command.self, forKey: .command)
        text = try c.decode(String.self, forKey: .text)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
        fire = try c.decodeIfPresent(FireRecord.self, forKey: .fire)
        inverse = try c.decodeIfPresent(Command.self, forKey: .inverse)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(seq, forKey: .seq)
        try c.encode(group, forKey: .group)
        try c.encode(source, forKey: .source)
        try c.encode(kind, forKey: .kind)
        try c.encode(undo, forKey: .undo)
        try c.encode(result.name, forKey: .result)
        if case .rejected(let rejection) = result {
            try c.encode(rejection.reason.rawValue + ": " + rejection.message, forKey: .reason)
        }
        try c.encode(command, forKey: .command)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(snapshot, forKey: .snapshot)
        try c.encodeIfPresent(fire, forKey: .fire)
        try c.encodeIfPresent(inverse, forKey: .inverse)
    }

    /// `reason` is written as `code: message`.
    static func rejection(from text: String) -> Rejection {
        guard let separator = text.range(of: ": ") else {
            return Rejection(reason: RejectionReason(rawValue: text) ?? .malformed, message: "")
        }
        let code = String(text[..<separator.lowerBound])
        let message = String(text[separator.upperBound...])
        return Rejection(reason: RejectionReason(rawValue: code) ?? .malformed, message: message)
    }
}
