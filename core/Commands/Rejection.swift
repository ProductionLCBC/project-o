// OCore — Spec 2 §8, rejections and results.

/// Spec 2 §8 — "a rejected command yields `rejected` with a reason". Spec 2
/// §10 names the documented reasons: unknown target, missing rider scope,
/// out-of-range gain, unknown media id, macro cycle, guard on a cue command.
public enum RejectionReason: String, Codable, Equatable, Sendable {
    /// Spec 2 §2 — the line is not a command at all: empty, an unterminated
    /// string, a bad escape, a bracket never closed.
    case malformed
    /// Spec 2 §2 — the first word is not a target.
    case unknownTarget
    /// Spec 2 §3 — the target has no such verb.
    case unknownVerb
    /// Spec 2 §3 — the line ends before an argument the form needs.
    case missingArgument
    /// Spec 2 §2 — a token of the wrong kind where an argument was expected.
    case badArgument
    /// Spec 2 §2 — tokens after the command's last argument.
    case unexpectedToken
    /// Spec 2 §2 — "A rider without a scope is an error, not a default."
    case missingRiderScope
    /// Spec 2 §2 — the same rider twice on one write.
    case duplicateRider
    /// Spec 2 §2 — the same content option twice on one write.
    case duplicateOption
    /// Spec 2 §8 — "an unknown id is rejected"; also an abbreviated hash that
    /// matches none of the ids the parser was given.
    case unknownMedia
    /// Spec 2 §2 — an abbreviated hash that matches more than one id.
    case ambiguousMedia
    /// Spec 2 §8 — "the target number exists (or is `all`)" failed.
    case noSuchTarget
    /// Spec 2 §8 — "referenced objects exist (a preset, a transition, a macro)" failed.
    case noSuchReference
    /// Spec 2 §8 — "arguments are in range" failed.
    case outOfRange
    /// Spec 2 §5 — "cycles are rejected".
    case macroCycle
    /// Spec 2 §5 — "depth is capped at 8".
    case macroDepth
    /// Spec 2 §7 — "Guards on cue commands are reserved in the schema and
    /// rejected by the v1 validator."
    case guardOnCue
    /// Spec 2 §7 — the guard names no readable value.
    case badGuard
    /// Spec 1 §6 — a command object the vocabulary does not know, or one
    /// whose parameters did not decode; kept in a file, refused at run time.
    case unknownCommand

    // Spec 5 §6 — "Rejection codes" of the edit path, in its order.
    /// The object an edit names does not exist.
    case unknownObject
    /// The path is not in the object's schema, or not there in the object.
    case unknownPath
    /// "`uuid`, `schema`, `app`, `kind`, `version`, `builtIn` and `number` never are" editable.
    case readOnlyField
    /// The value has the wrong type or enum, or is out of range.
    case badValue
    /// "Every number the value names exists on this machine" failed.
    case unknownReference
    /// A number, title, uuid, file or folder that must be unique is taken.
    case duplicate
    /// "`renumber` and `swap` also refuse a number that broken references still name".
    case danglingReferences
    /// "Preset 1 and Transitions 1–3 can't be deleted, renumbered or swapped".
    case protected
    /// "An object on air can't be deleted, renumbered or swapped until it is off air".
    case onAir
    /// "An archived playlist takes only the edit that unarchives it and `delete`".
    case archived
    /// "A folder is deleted only when it's empty."
    case notEmpty
    /// "A macro edit passes Spec 2 §5's cycle and depth checks."
    case cycle
    /// Spec 5 §7 — "While the lock is on, the engine refuses every `edit`".
    case operatorLock
    /// Spec 5 §7 — library edits on a `readOnlyMasters` machine.
    case readOnlyLibrary
    /// Spec 5 §8 — an undo whose inverse would now break a rule (Area 12).
    case conflict
    /// Spec 5 §3 — what v1 doesn't edit: local copies, local items, and the
    /// objects whose edits come with later areas.
    case notInV1
    /// Spec 8 §6 — `media delete` with no Trash to move the files to.
    case noTrash
    /// Spec 9 §6 — refused while the disk is full.
    case diskFull
    /// Spec 10 §12 — the lock can't be turned on before a passcode is set.
    case noPasscode
    /// Spec 10 §12 — the Keychain can't be read.
    case keychain
}

/// Spec 2 §8 — "A command either runs or is rejected with a reason before
/// anything changes." In a group, "the rejection names the command and the
/// reason": `index` is the command's 0-based place in its group or bundle and
/// `text` its canonical form, when known.
public struct Rejection: Error, Equatable, Sendable {
    public var reason: RejectionReason
    public var message: String
    public var index: Int?
    public var text: String?

    public init(reason: RejectionReason, message: String, index: Int? = nil, text: String? = nil) {
        self.reason = reason
        self.message = message
        self.index = index
        self.text = text
    }
}

/// Spec 2 §8 — Results: "Every executed command yields one of `ok`,
/// `blocked`, `noop` or `steppedOn`; a rejected command yields `rejected`
/// with a reason and is logged only at the API and command-bar boundary,
/// never in the runtime log."
public enum CommandResult: Equatable, Sendable {
    case ok
    case blocked
    case noop
    case steppedOn
    case rejected(Rejection)

    /// The result's name as the log entry writes it (Spec 2 §9).
    public var name: String {
        switch self {
        case .ok: return "ok"
        case .blocked: return "blocked"
        case .noop: return "noop"
        case .steppedOn: return "steppedOn"
        case .rejected: return "rejected"
        }
    }
}
