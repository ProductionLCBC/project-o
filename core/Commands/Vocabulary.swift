// OCore — Spec 2 §3, the v1 vocabulary table as data.

/// Spec 2 §3 — the Lock column: "*blocked* means the command is refused when
/// its source is a cue or a timeline and runs from any other source; *passes*
/// means lock never applies." A macro passes; its inner commands are judged
/// on their own.
public enum LockClass: String, Equatable, Sendable {
    case blocked
    case passes
}

/// Spec 2 §3 — the Undo column: "*runtime* commands snapshot channel state
/// before they run (undo restores it, from v1.5), *none* are logged but not
/// undoable." Spec 2 §9 — edit entries are the editing spec's; a macro's own
/// line is `none`, its inner commands carry their own class.
public enum UndoClass: String, Codable, Equatable, Sendable {
    case runtime
    case none
    case edit
}

/// Spec 2 §9 — "`kind` is `runtime` or `edit`".
public enum LogKind: String, Codable, Equatable, Sendable {
    case runtime
    case edit
}

/// One row of the Spec 2 §3 table: the text skeleton (target word, number,
/// verb, arguments in order), the object name, the lock and undo classes.
/// The parser, the printer and the OSC mapping all read it, so the three
/// cannot disagree.
struct VocabularyRow: Sendable {
    /// Spec 2 §2 — `target [number]`: none, a positive integer, or a channel
    /// or audio-output number that may be the word `all` (Spec 2 §3).
    enum Number: Sendable {
        case none
        case int(String)
        case target(String)

        var key: String? {
            switch self {
            case .none: return nil
            case .int(let key), .target(let key): return key
            }
        }
    }

    /// The verb word: fixed, the value of a keyword field (`play`, `skip`),
    /// or `lock`/`unlock` from a boolean field.
    enum Verb: Sendable {
        case none
        case word(String)
        case fromKey(String, [String])
        case lock(String)

        var isNone: Bool {
            if case .none = self { return true }
            return false
        }
    }

    /// Spec 2 §2 — `argument := integer | decimal | duration | string | ref | keyword`.
    enum Kind: Sendable {
        case int
        case decimal
        case duration(DurationText.Style)
        case optionalDuration(DurationText.Style)
        case string
        case optionalString
        case keyword([String])
        /// `[clearafter SECONDS]`: a keyword then whole or decimal seconds, stored as ms.
        case optionalKeywordSeconds(String)
        /// Spec 2 §2 — `write CONTENT [riders]`, parsed and printed by hand.
        case write
        /// Spec 2 §3 — `edit TARGET N FIELD VALUE`, reserved.
        case edit
    }

    struct Arg: Sendable {
        let key: String
        let kind: Kind

        init(_ key: String, _ kind: Kind) {
            self.key = key
            self.kind = kind
        }
    }

    let cmd: String
    let target: String
    let number: Number
    let verb: Verb
    let args: [Arg]
    let lock: LockClass
    let undo: UndoClass
    /// Spec 3 §3 rule 2 — a standalone attribute command is always tracked;
    /// the §2 examples' trailing `track` is accepted and never printed.
    let standaloneAttribute: Bool

    init(_ cmd: String, target: String, number: Number = .none, verb: Verb = .none, args: [Arg] = [],
         lock: LockClass, undo: UndoClass, standaloneAttribute: Bool = false) {
        self.cmd = cmd
        self.target = target
        self.number = number
        self.verb = verb
        self.args = args
        self.lock = lock
        self.undo = undo
        self.standaloneAttribute = standaloneAttribute
    }

    var hasNumber: Bool { number.key != nil }
    var hasVerb: Bool { !verb.isNone }

    /// The write and edit forms have their own parser and printer.
    var isSpecial: Bool {
        switch args.first?.kind {
        case .write?, .edit?: return true
        default: return false
        }
    }

    /// How many words of the text form make the OSC address (Spec 2 §6).
    var addressWordCount: Int {
        1 + (hasNumber ? 1 : 0) + (hasVerb ? 1 : 0)
    }
}

/// Spec 2 §3 — the complete runtime vocabulary for v1, one row per object.
enum Vocabulary {
    typealias Arg = VocabularyRow.Arg

    static let onOffToggle = ["on", "off", "toggle"]

    static let rows: [VocabularyRow] = [
        // Channels
        VocabularyRow("channel.write", target: "channel", number: .target("channel"), verb: .word("write"),
                      args: [Arg("content", .write)], lock: .blocked, undo: .runtime),
        VocabularyRow("channel.clear", target: "channel", number: .target("channel"), verb: .word("clear"), lock: .blocked, undo: .runtime),
        VocabularyRow("channel.reset", target: "channel", number: .target("channel"), verb: .word("reset"), lock: .passes, undo: .runtime),
        VocabularyRow("channel.transition", target: "channel", number: .target("channel"), verb: .word("transition"),
                      args: [Arg("ref", .int), Arg("ms", .optionalDuration(.seconds))], lock: .blocked, undo: .runtime, standaloneAttribute: true),
        VocabularyRow("channel.audioTransition", target: "channel", number: .target("channel"), verb: .word("audiotransition"),
                      args: [Arg("ref", .int), Arg("ms", .optionalDuration(.seconds))], lock: .blocked, undo: .runtime, standaloneAttribute: true),
        VocabularyRow("channel.grade", target: "channel", number: .target("channel"), verb: .word("grade"),
                      args: [Arg("ref", .int), Arg("ms", .optionalDuration(.seconds))], lock: .blocked, undo: .runtime, standaloneAttribute: true),
        VocabularyRow("channel.gain", target: "channel", number: .target("channel"), verb: .word("gain"),
                      args: [Arg("db", .decimal)], lock: .blocked, undo: .runtime, standaloneAttribute: true),
        VocabularyRow("channel.transport", target: "channel", number: .target("channel"),
                      verb: .fromKey("mode", ["play", "pause", "stop"]), lock: .passes, undo: .runtime),
        VocabularyRow("channel.endBehavior", target: "channel", number: .target("channel"), verb: .word("end"),
                      args: [Arg("mode", .keyword(["loop", "hold", "clear"]))], lock: .passes, undo: .runtime),
        VocabularyRow("channel.lock", target: "channel", number: .target("channel"), verb: .lock("locked"), lock: .passes, undo: .none),
        VocabularyRow("channel.freeze", target: "channel", number: .target("channel"), verb: .word("freeze"),
                      args: [Arg("state", .keyword(onOffToggle))], lock: .passes, undo: .runtime),
        VocabularyRow("channel.track", target: "channel", number: .target("channel"),
                      verb: .fromKey("direction", ["skip", "back"]), lock: .passes, undo: .runtime),
        VocabularyRow("channel.build", target: "channel", number: .target("channel"), verb: .word("build"),
                      args: [Arg("build", .int)], lock: .passes, undo: .runtime),
        // Stacks and outputs
        VocabularyRow("output.stack", target: "output", number: .int("output"), verb: .word("stack"),
                      args: [Arg("stack", .int)], lock: .passes, undo: .runtime),
        VocabularyRow("stack.blackout", target: "stack", number: .int("stack"), verb: .word("blackout"),
                      args: [Arg("state", .keyword(onOffToggle))], lock: .passes, undo: .runtime),
        VocabularyRow("stack.mute", target: "stack", number: .int("stack"), verb: .word("mute"),
                      args: [Arg("channel", .int), Arg("state", .keyword(onOffToggle))], lock: .passes, undo: .runtime),
        // Playlist and library navigation
        VocabularyRow("playlist.next", target: "next", lock: .passes, undo: .runtime),
        VocabularyRow("playlist.previous", target: "previous", lock: .passes, undo: .runtime),
        // Spec 2 §6 — `cue 7` is `/o/cue` `i:7`: the number is an argument, not an address part.
        VocabularyRow("playlist.cue", target: "cue", args: [Arg("cue", .int)], lock: .passes, undo: .runtime),
        VocabularyRow("playlist.goto", target: "item", number: .int("item"), verb: .word("cue"),
                      args: [Arg("cue", .int)], lock: .passes, undo: .runtime),
        VocabularyRow("playlist.section", target: "item", number: .int("item"), verb: .word("section"),
                      args: [Arg("section", .string)], lock: .passes, undo: .runtime),
        VocabularyRow("list.goto", target: "list", number: .int("list"), verb: .word("cue"),
                      args: [Arg("cue", .int)], lock: .passes, undo: .runtime),
        VocabularyRow("playlist.load", target: "playlist",
                      args: [Arg("title", .string), Arg("date", .optionalString)], lock: .passes, undo: .none),
        // Timers, popups and audio
        VocabularyRow("timer.set", target: "timer", number: .int("timer"), verb: .word("set"),
                      args: [Arg("ms", .duration(.clock))], lock: .passes, undo: .none),
        VocabularyRow("timer.start", target: "timer", number: .int("timer"), verb: .word("start"), lock: .passes, undo: .none),
        VocabularyRow("timer.pause", target: "timer", number: .int("timer"), verb: .word("pause"), lock: .passes, undo: .none),
        VocabularyRow("timer.reset", target: "timer", number: .int("timer"), verb: .word("reset"), lock: .passes, undo: .none),
        VocabularyRow("popup.set", target: "popup", number: .int("popup"), verb: .word("set"),
                      args: [Arg("text", .string), Arg("clearAfterMs", .optionalKeywordSeconds("clearafter"))], lock: .passes, undo: .runtime),
        VocabularyRow("popup.clear", target: "popup", number: .int("popup"), verb: .word("clear"), lock: .passes, undo: .runtime),
        VocabularyRow("audio.mute", target: "audio", number: .target("audio"), verb: .word("mute"),
                      args: [Arg("state", .keyword(onOffToggle))], lock: .passes, undo: .runtime),
        // Macros, history and system
        VocabularyRow("macro.run", target: "macro", number: .int("macro"), lock: .passes, undo: .none),
        VocabularyRow("history.undo", target: "undo", lock: .passes, undo: .none),
        VocabularyRow("history.redo", target: "redo", lock: .passes, undo: .none),
        VocabularyRow("history.jump", target: "history", verb: .word("jump"), args: [Arg("position", .int)], lock: .passes, undo: .none),
        VocabularyRow("system.clearAll", target: "system", verb: .word("clearall"), lock: .passes, undo: .runtime),
        VocabularyRow("system.preflight", target: "system", verb: .word("preflight"), lock: .passes, undo: .none),
        VocabularyRow("system.snapshot", target: "system", verb: .word("snapshot"), lock: .passes, undo: .none),
        // The reserved edit shape
        VocabularyRow("edit", target: "edit", args: [Arg("", .edit)], lock: .passes, undo: .edit),
    ]

    static let byCmd: [String: VocabularyRow] = Dictionary(uniqueKeysWithValues: rows.map { ($0.cmd, $0) })
    static let byTarget: [String: [VocabularyRow]] = Dictionary(grouping: rows, by: \.target)
    static let targets: Set<String> = Set(rows.map(\.target))

    static func row(cmd: String) -> VocabularyRow? {
        byCmd[cmd]
    }

    static func rows(target: String) -> [VocabularyRow] {
        byTarget[target] ?? []
    }

    /// Spec 2 §4 — short forms: "`ch` for `channel`".
    static func canonicalTarget(_ word: String) -> String {
        word == "ch" ? "channel" : word
    }

    /// Spec 2 §4 — short forms: "`tr` for `transition`".
    static func canonicalVerb(_ word: String, target: String) -> String {
        target == "channel" && word == "tr" ? "transition" : word
    }

    /// The row a target and a verb word name; `verb` is nil for the targets
    /// that take none (`next`, `cue N`, `macro N`, `playlist "TITLE"`).
    static func row(target: String, verb: String?) -> VocabularyRow? {
        let candidates = rows(target: target)
        guard let verb else { return candidates.first { $0.verb.isNone } }
        return candidates.first { row in
            switch row.verb {
            case .none: return false
            case .word(let w): return w == verb
            case .fromKey(_, let values): return values.contains(verb)
            case .lock: return verb == "lock" || verb == "unlock"
            }
        }
    }
}

extension Command {
    /// Spec 2 §3 — the Lock column of this command's row.
    public var lockClass: LockClass {
        Vocabulary.row(cmd: cmd)?.lock ?? .passes
    }

    /// Spec 2 §3 — the Undo column of this command's row; `none` for a
    /// command the vocabulary does not know.
    public var undoClass: UndoClass {
        Vocabulary.row(cmd: cmd)?.undo ?? .none
    }

    /// Spec 2 §9 — "`kind` is `runtime` or `edit`".
    public var logKind: LogKind {
        if case .edit = self { return .edit }
        return .runtime
    }
}
