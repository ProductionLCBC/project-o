// OApp — Spec 10 §2 and §3, what arrives on the engine's local socket, read into values.

import Foundation
import OCore

/// Spec 10 §2 — "the engine's first message is `hello`, naming its version,
/// the API version, its process id, the machine, the run and the Mach
/// service".
public struct Hello: Equatable, Sendable {
    /// Spec 2 §9 — "The envelope carries `"api": 1`"; the app drives only an engine whose `api` is its own.
    public static let api = 1

    public var api: Int
    public var engine: String
    public var pid: Int32
    public var machine: String
    public var run: String
    public var mach: String

    public init(api: Int, engine: String, pid: Int32, machine: String, run: String, mach: String) {
        self.api = api
        self.engine = engine
        self.pid = pid
        self.machine = machine
        self.run = run
        self.mach = mach
    }

    /// Reads a `hello`; nil when the message isn't one or lacks its `api` or `pid`.
    public init?(_ message: JSONValue) {
        guard let members = message.objectValue, members["type"]?.stringValue == "hello",
              let api = members["api"]?.intValue, let pid = members["pid"]?.intValue else { return nil }
        self.init(api: api, engine: members["engine"]?.stringValue ?? "", pid: Int32(truncatingIfNeeded: pid),
                  machine: members["machine"]?.stringValue ?? "", run: members["run"]?.stringValue ?? "",
                  mach: members["mach"]?.stringValue ?? "")
    }

    /// Spec 10 §2, "Versions" — "An app and an engine of different versions
    /// work together while `api` matches ... When `api` differs, the app
    /// can't drive the engine and asks to restart it".
    public var isDrivable: Bool { api == Self.api }
}

/// Spec 10 §3 — a refusal as the engine words it: `"reason": "badPasscode:
/// the passcode is wrong"`, a code, a colon and a message.
public struct EngineRejection: Equatable, Sendable {
    /// The code as it arrived, such as `onAir`.
    public var code: String
    /// The engine's own sentence, in English; shown as it came only in the
    /// command bar and a snapshot's refusal (Area 13 reading), since every
    /// other place has a sentence of the app's for the code (Spec 10 §10).
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Splits `code: message`; a reason with no colon is all code.
    public init(reason: String) {
        if let colon = reason.range(of: ": ") {
            self.init(code: String(reason[..<colon.lowerBound]), message: String(reason[colon.upperBound...]))
        } else {
            self.init(code: reason, message: "")
        }
    }

    /// The code as OCore names it, or nil for one this build doesn't know.
    public var reason: RejectionReason? { RejectionReason(rawValue: code) }
}

/// Spec 2 §8 — "Every executed command yields one of `ok`, `blocked`,
/// `noop` or `steppedOn`; a rejected command yields `rejected` with a
/// reason".
public enum ResultKind: String, Equatable, Sendable {
    case ok
    case blocked
    case noop
    case steppedOn
    case rejected
}

/// Spec 10 §3, "Results" — one applied edit "as the log keeps it, with what
/// the engine picked, and its inverse, so the app can find a new object, or
/// revert exactly what it sent without reaching for `undo`".
public struct AppliedEdit: Equatable, Sendable {
    public var command: JSONValue
    public var inverse: JSONValue?

    public init(command: JSONValue, inverse: JSONValue?) {
        self.command = command
        self.inverse = inverse
    }
}

/// Spec 2 §9 — the result that answers a request: `{ "id": 17, "type":
/// "result", "result": "ok", "seq": 4822 }`, with what Spec 10 §3 adds for an
/// applied edit (`group`, `applied`), Spec 5 §6's `warnings`, Spec 8 §7's
/// `job`, Spec 9 §3's `snapshot`, and the answers of `stop` (`unsaved`) and
/// `releaseScreen` (`outputs`).
public struct CommandOutcome: Equatable, Sendable {
    public var kind: ResultKind
    public var seq: Int?
    /// Why, when the result is `rejected`, or `blocked` for an edit a key's binding held.
    public var rejection: EngineRejection?
    public var group: String?
    public var applied: [AppliedEdit]
    public var warnings: [String]
    public var job: String?
    public var snapshot: String?
    /// Spec 2 §9 (Area 19 reading) — the result of each command of a `commands` request, in order.
    public var each: [Each]
    /// Spec 10 §3, `stop` — "`ok` with `unsaved`, the documents it couldn't write".
    public var unsaved: [String]?
    /// Spec 10 §3, `releaseScreen` — "`ok` with the outputs released".
    public var outputs: [Int]?

    public struct Each: Equatable, Sendable {
        public var kind: ResultKind
        public var seq: Int?

        public init(kind: ResultKind, seq: Int?) {
            self.kind = kind
            self.seq = seq
        }
    }

    public init(kind: ResultKind, seq: Int? = nil, rejection: EngineRejection? = nil, group: String? = nil, applied: [AppliedEdit] = [],
                warnings: [String] = [], job: String? = nil, snapshot: String? = nil, each: [Each] = [], unsaved: [String]? = nil,
                outputs: [Int]? = nil) {
        self.kind = kind
        self.seq = seq
        self.rejection = rejection
        self.group = group
        self.applied = applied
        self.warnings = warnings
        self.job = job
        self.snapshot = snapshot
        self.each = each
        self.unsaved = unsaved
        self.outputs = outputs
    }

    /// Reads the fields of a `result` message; nil when it names no result this build knows.
    public init?(_ members: [String: JSONValue]) {
        guard let kind = members["result"]?.stringValue.flatMap(ResultKind.init(rawValue:)) else { return nil }
        self.init(kind: kind, seq: members["seq"]?.intValue,
                  rejection: members["reason"]?.stringValue.map(EngineRejection.init(reason:)),
                  group: members["group"]?.stringValue,
                  applied: (members["applied"]?.arrayValue ?? []).compactMap { entry in
                      guard let fields = entry.objectValue, let command = fields["command"] else { return nil }
                      let inverse = fields["inverse"]
                      return AppliedEdit(command: command, inverse: inverse == .null ? nil : inverse)
                  },
                  warnings: (members["warnings"]?.arrayValue ?? []).compactMap(\.stringValue),
                  job: members["job"]?.stringValue, snapshot: members["snapshot"]?.stringValue,
                  each: (members["results"]?.arrayValue ?? []).compactMap { entry in
                      guard let fields = entry.objectValue, let kind = fields["result"]?.stringValue.flatMap(ResultKind.init(rawValue:)) else { return nil }
                      return Each(kind: kind, seq: fields["seq"]?.intValue)
                  },
                  unsaved: members["unsaved"]?.arrayValue.map { $0.compactMap(\.stringValue) },
                  outputs: members["outputs"]?.arrayValue.map { $0.compactMap(\.intValue) })
    }

    /// Whether the request did what it asked: `ok`, or `steppedOn`, which ran and cut older content out.
    public var succeeded: Bool { kind == .ok || kind == .steppedOn }
}

/// What answers a request, by the message's `type`.
public enum Reply: Equatable, Sendable {
    /// Spec 2 §9 — `"type": "result"`.
    case result(CommandOutcome)
    /// Spec 2 §9 — "A query is answered ... as `{"id": …, "type": "answer", …}` and the fields its definition gives".
    case answer([String: JSONValue])
    /// Spec 10 §3 — `ping`'s answer.
    case pong

    /// The outcome of a `result`; a refused query arrives as one too.
    public var outcome: CommandOutcome? {
        if case .result(let outcome) = self { return outcome }
        return nil
    }

    /// The fields of an `answer`.
    public var answer: [String: JSONValue]? {
        if case .answer(let fields) = self { return fields }
        return nil
    }
}

/// One message from the engine, in the order it arrived. Spec 10 §3 — "A
/// connection carries answers and events in the order the engine produces
/// them, so an answer reflects every event sent before it": the order is
/// kept from the socket to whoever applies it, which is why replies and
/// events come through one door.
public enum Incoming: Equatable, Sendable {
    case hello(Hello)
    /// The reply to the request the app sent with this id.
    case reply(id: Int, Reply)
    /// An event, whole, with its `topic`.
    case event(topic: String, [String: JSONValue])
    /// A line that isn't JSON, or a message this build has no place for; kept for the log, never trusted.
    case unknown(String)
    /// The connection has gone: the engine closed it or ended.
    case closed

    /// Reads one line off the socket. Unknown input is never fatal (CLAUDE.md, hard rules).
    public static func read(_ line: Data) -> Incoming {
        guard let value = try? JSONValue.parse(line), let members = value.objectValue, let type = members["type"]?.stringValue else {
            return .unknown(String(decoding: line.prefix(200), as: UTF8.self))
        }
        switch type {
        case "hello":
            guard let hello = Hello(value) else { return .unknown("a hello without its api or pid") }
            return .hello(hello)
        case "event":
            guard let topic = members["topic"]?.stringValue else { return .unknown("an event without a topic") }
            return .event(topic: topic, members)
        case "result":
            guard let id = members["id"]?.intValue, let outcome = CommandOutcome(members) else { return .unknown("a result without an id or a result") }
            return .reply(id: id, .result(outcome))
        case "answer":
            guard let id = members["id"]?.intValue else { return .unknown("an answer without an id") }
            return .reply(id: id, .answer(members))
        case "pong":
            guard let id = members["id"]?.intValue else { return .unknown("a pong without an id") }
            return .reply(id: id, .pong)
        default:
            return .unknown("a message of type \(type)")
        }
    }
}
