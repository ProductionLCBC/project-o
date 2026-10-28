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
