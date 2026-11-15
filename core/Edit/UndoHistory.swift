// OCore — Spec 5 §8 and Spec 9 §5, the edit undo and redo stacks.
//
// Pure: a value the command runner updates as it runs a group, so an `undo`
// inside a macro or a cue behaves as one sent alone. The engine keeps it
// between runs, drops the steps a reload or the media walk asks it to, and
// publishes the `history` topic from it.

import Foundation

/// Spec 5 §5 — "The edits in a group share one log group id, one `library`
/// event and one undo step": one applied edit group, as undo and redo need it.
public struct UndoStep: Equatable, Sendable {
    /// The log group that applied these edits last: the group that made
    /// them, or the redo that ran them again. An undo's `undoes` and a
    /// redo's `redoes` name it (Spec 5 §8).
    public var group: GroupID
    /// Spec 9 §5 — "`source` where it came from (Spec 10 §10)": the source of
    /// the edits as they were first made.
    public var source: CommandSource
    /// The logged commands, in the order they applied. Redo "runs an undone
    /// group's logged commands again ... so the numbers and uuids the engine
    /// picked the first time come back the same".
    public var commands: [Command]
    /// Their inverses, in the same order. Undo "runs its inverses, last first".
    public var inverses: [Command]
    /// The documents the edits changed, for "A reload drops steps".
    public var documents: Set<DocumentRef>

    public init(group: GroupID, source: CommandSource, commands: [Command] = [], inverses: [Command] = [],
                documents: Set<DocumentRef> = []) {
        self.group = group
        self.source = source
        self.commands = commands
        self.inverses = inverses
        self.documents = documents
    }

    /// Spec 5 §8 — the media index entries the step names: "The media walk
    /// drops the steps that name an entry it maps to another file or brings
    /// back (Spec 8 §4)".
    public var mediaIDs: Set<String> {
        var ids: Set<String> = []
        for command in commands + inverses {
            switch command {
            case .media(let media): ids.formUnion(media.ids)
            case .edit(let edit):
                if case .media(let id) = edit.address { ids.insert(id) }
            default: break
            }
        }
        return ids
    }

    /// Spec 9 §7 — "A snapshot an undo or redo step names is kept until the run ends".
    public var snapshotIDs: Set<String> {
        var ids: Set<String> = []
        for command in commands + inverses {
            if case .systemRestoreSnapshot(let id) = command { ids.insert(id) }
        }
        return ids
    }

    /// Spec 9 §5 — the step as the `history` topic names it: "`text` is the
    /// group's first command in its canonical form, `commands` how many it
    /// has, and `source` where it came from".
    public var json: JSONValue {
        var members: [String: JSONValue] = ["group": .string(group.rawValue), "commands": .number(Double(commands.count))]
        if let encoded = try? JSONCoding.encode(source) { members["source"] = encoded }
        if let first = commands.first { members["text"] = .string(CommandText.print(first) ?? first.cmd) }
        return .object(members)
    }
}

/// Spec 5 §8 — "One linear stack per run. The engine keeps the applied edit
/// groups of this run, newest on top, up to the last 500 (choice E-4) ... The
/// stack starts empty at launch and is cleared at quit." Spec 9 §5 — "`undo`
/// runs the top group's logged inverses ... `redo` runs an undone group's
/// commands again ...; a new edit clears the redo stack."
public struct UndoHistory: Equatable, Sendable {
    /// Spec 5 §12, choice E-4 — "up to the last 500".
    public static let depth = 500

    /// The applied groups, oldest first: the top is the last.
    public private(set) var undo: [UndoStep] = []
    /// The undone groups, the one to redo next last.
    public private(set) var redo: [UndoStep] = []

    public init() {}

    public var undoTop: UndoStep? { undo.last }
    public var redoTop: UndoStep? { redo.last }

    // MARK: - Recording

    /// One applied edit, with its inverse and the documents it changed. It
    /// joins the step on top when that step is its group's, so "The edits in
    /// a group share ... one undo step"; otherwise it starts one. "Any new
    /// edit clears the redo stack, so history stays linear".
    public mutating func record(group: GroupID, source: CommandSource, command: Command, inverse: Command, documents: Set<DocumentRef>) {
        redo.removeAll()
        if let top = undo.indices.last, undo[top].group == group {
            undo[top].commands.append(command)
            undo[top].inverses.append(inverse)
            undo[top].documents.formUnion(documents)
            return
        }
        undo.append(UndoStep(group: group, source: source, commands: [command], inverses: [inverse], documents: documents))
        if undo.count > Self.depth { undo.removeFirst(undo.count - Self.depth) }
    }

    /// Spec 5 §5 — "Typing ... The engine then writes one log line and pushes
    /// one undo step, whose inverse is the value from before the run." The
    /// edit just recorded, the step on top, belongs to the typing run that
    /// `group` opened: it folds into that run's step when the two are
    /// adjacent, keeping the run's inverse and taking the newest value; with
    /// another step between them it stays a step and takes the run's group.
    public mutating func foldTop(intoRun group: GroupID) {
        guard let top = undo.indices.last, undo[top].group != group else { return }
        let below = top - 1
        guard below >= 0, undo[below].group == group, undo[top].commands.count == 1, undo[below].commands.count == 1 else {
            undo[top].group = group
            return
        }
        let newest = undo.removeLast()
        undo[below].commands = newest.commands
        undo[below].documents.formUnion(newest.documents)
    }

    // MARK: - Undo and redo

    /// Spec 5 §8 — an undo applied: "The undone group moves to the redo stack."
    public mutating func undone() {
        guard let step = undo.popLast() else { return }
        redo.append(step)
    }

    /// Spec 5 §8 — a redo applied: the group is back on the undo stack as
    /// `step`, the group that ran it again with the inverses that run made,
    /// and the redo stack below it is as it was.
    public mutating func redone(as step: UndoStep) {
        guard redo.popLast() != nil else { return }
        undo.append(step)
        if undo.count > Self.depth { undo.removeFirst(undo.count - Self.depth) }
    }

    // MARK: - Dropping steps

    /// Spec 5 §8 — "A reload drops steps. When a document is reloaded from
    /// disk (§10), every undo and redo step that touches it is dropped ... An
    /// undo therefore never overwrites a change that arrived by sync." The
    /// groups dropped, undo's first then redo's, each oldest first.
    @discardableResult
    public mutating func drop(touching documents: Set<DocumentRef>) -> [GroupID] {
        guard !documents.isEmpty else { return [] }
        return drop { !$0.documents.isDisjoint(with: documents) }
    }

    /// Spec 5 §8 — "The media walk drops the steps that name an entry it
    /// maps to another file or brings back (Spec 8 §4)."
    @discardableResult
    public mutating func drop(naming media: Set<String>) -> [GroupID] {
        guard !media.isEmpty else { return [] }
        return drop { !$0.mediaIDs.isDisjoint(with: media) }
    }

    private mutating func drop(where matches: (UndoStep) -> Bool) -> [GroupID] {
        let dropped = undo.filter(matches).map(\.group) + redo.filter(matches).map(\.group)
        guard !dropped.isEmpty else { return [] }
        undo.removeAll(where: matches)
        redo.removeAll(where: matches)
        return dropped
    }

    // MARK: - What it names

    /// Spec 9 §7 — every snapshot a step of either stack names.
    public var snapshotIDs: Set<String> {
        (undo + redo).reduce(into: Set<String>()) { $0.formUnion($1.snapshotIDs) }
    }

    /// Spec 9 §5 — "The `history` topic. So the app can enable Undo and Redo
    /// and name them, the engine sends an event when a client subscribes and
    /// whenever either stack changes":
    ///
    /// ```json
    /// { "type": "event", "topic": "history",
    ///   "undo": { "group": "g-7f1a2b3c", "commands": 1, "source": { "kind": "ui" }, "text": "edit list 42 title \"…\"" },
    ///   "redo": null, "seq": 5230 }
    /// ```
    public func event(seq: Int) -> JSONValue {
        .object(["type": .string("event"), "topic": .string("history"), "undo": undoTop?.json ?? .null, "redo": redoTop?.json ?? .null,
                 "seq": .number(Double(seq))])
    }
}
