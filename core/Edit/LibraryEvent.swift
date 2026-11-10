// OCore — Spec 5 §2, the revision and the `library` event; Spec 5 §5, groups
// and typing. Pure: the engine numbers the revisions and the log lines.

import Foundation

/// Spec 5 §2 — "After each applied group or reload, subscribed clients get one
/// event on the `library` topic":
///
/// ```json
/// { "type": "event", "topic": "library", "rev": 214, "cause": "edit", "group": "g-7f1a2b3c",
///   "source": { "kind": "ui" },
///   "changed": [ { "object": "cue", "list": 42, "cue": "22bb…", "paths": ["commands"] } ] }
/// ```
///
/// "The event names what changed and carries no object bodies". Spec 2 §9 —
/// "an event carries the `seq` of the log line that caused it, or of the last
/// line logged before it". A reload has no group and no source.
public struct LibraryEvent: Equatable, Sendable {
    /// "`cause` is `edit`, `undo`, `redo`, `file`, `media`, `restore` or `lock`".
    public enum Cause: String, Sendable {
        case edit, undo, redo, file, media, restore, lock
    }

    public var rev: Int
    public var cause: Cause
    public var group: GroupID?
    public var source: CommandSource?
    public var changed: [LibraryChange]
    public var seq: Int

    public init(rev: Int, cause: Cause, group: GroupID? = nil, source: CommandSource? = nil, changed: [LibraryChange], seq: Int) {
        self.rev = rev
        self.cause = cause
        self.group = group
        self.source = source
        self.changed = changed
        self.seq = seq
    }

    /// The event as the API carries it (Spec 2 §9's envelope).
    public var json: JSONValue {
        var members: [String: JSONValue] = [
            "type": .string("event"), "topic": .string("library"), "rev": .number(Double(rev)),
            "cause": .string(cause.rawValue), "changed": .array(changed.map(\.json)), "seq": .number(Double(seq)),
        ]
        if let group { members["group"] = .string(group.rawValue) }
        if let source, let encoded = try? JSONCoding.encode(source) { members["source"] = encoded }
        return .object(members)
    }
}

/// Spec 5 §5 — "The edits in a group share one log group id, one `library`
/// event and one undo step": the edits a run applied, by their log group, in
/// the order the groups first applied one, each with the source of its edits
/// and what they changed.
public struct AppliedEdits: Equatable, Sendable {
    public var group: GroupID
    public var source: CommandSource
    public var changed: [LibraryChange]

    public init(group: GroupID, source: CommandSource, changed: [LibraryChange]) {
        self.group = group
        self.source = source
        self.changed = changed
    }

    /// The applied edits of `executed` (result `ok`; a `noop` or a `blocked`
    /// edit applied nothing), one entry per log group.
    public static func groups(in executed: [ExecutedCommand]) -> [AppliedEdits] {
        var out: [AppliedEdits] = []
        for line in executed where line.result == .ok {
            guard case .edit = line.command else { continue }
            if let index = out.firstIndex(where: { $0.group == line.group }) {
                out[index].changed += line.changes
            } else {
                out.append(AppliedEdits(group: line.group, source: line.source, changed: line.changes))
            }
        }
        return out.map { AppliedEdits(group: $0.group, source: $0.source, changed: LibraryChange.merged($0.changed)) }
    }
}

extension LibraryChange {
    /// Spec 5 §2 — `changed` names each object once, with the paths that
    /// changed in order, or none when the whole object did (created, deleted,
    /// renumbered or moved), in the order the objects first changed.
    public static func merged(_ changes: [LibraryChange]) -> [LibraryChange] {
        var out: [LibraryChange] = []
        for change in changes {
            guard let index = out.firstIndex(where: { $0.object == change.object && $0.address == change.address }) else {
                out.append(change)
                continue
            }
            if out[index].paths.isEmpty { continue }
            if change.paths.isEmpty {
                out[index].paths = []
                continue
            }
            for path in change.paths where !out[index].paths.contains(path) { out[index].paths.append(path) }
        }
        return out
    }
}

/// Spec 5 §5 — "Typing. Edits that set the same text, from the same client,
/// fold into one edit per second ... 'The same text' means one `edit.set`
/// path holding a string, or one cue's text write on one channel."
public enum TypingKey: Hashable, Sendable {
    case field(EditAddress, path: String)
    case cueText(list: Int, cue: UUID, channel: Int)
}

extension EditCommand {
    /// The text this edit sets, when it is one that typing folds.
    public var typingKey: TypingKey? {
        switch action {
        case .set(let path, .string):
            return .field(address, path: path)
        case .cueChannel(let edit):
            guard case .cue(let list, let cue) = address, case .write(.text, _) = edit.state else { return nil }
            return .cueText(list: list, cue: cue, channel: edit.channel)
        default:
            return nil
        }
    }
}
