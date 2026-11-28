// OApp — Spec 10 §2 and §3, requests out and messages in, over one connection.

import Foundation
import OCore
import Synchronization

/// Spec 2 §5 — the three sources the app's commands carry: "The app names
/// each command's source, `ui`, `key` or `commandbar` (Spec 2 §5), and the
/// engine takes it from this socket only" (Spec 10 §2).
public enum AppSource: String, Equatable, Sendable {
    case ui
    case key
    case commandbar
}

/// Spec 2 §9 and Spec 10 §3 — one request to the engine: its `type` and the
/// fields that go with it. The id is the link's to give.
public struct EngineRequest: Equatable, Sendable {
    public var type: String
    public var fields: [String: JSONValue]

    public init(type: String, fields: [String: JSONValue] = [:]) {
        self.type = type
        self.fields = fields
    }

    /// Spec 2 §9 — `{ "id": 17, "type": "command", "command": { … } }`, with
    /// the source Spec 10 §2 adds on the local socket.
    public static func command(_ command: Command, source: AppSource) -> EngineRequest {
        EngineRequest(type: "command", fields: ["command": encoded(command), "source": .string(source.rawValue)])
    }

    /// A command as the command bar's parser read it (Spec 10 §9), with its
    /// `when` guard when it has one: the object form is the command's own
    /// keys with `when` beside them (Spec 2 §7), and the engine judges it.
    public static func command(_ command: GuardedCommand, source: AppSource) -> EngineRequest {
        EngineRequest(type: "command", fields: ["command": (try? JSONCoding.encode(command)) ?? .null, "source": .string(source.rawValue)])
    }

    /// Spec 2 §9 — `{ "id": 18, "type": "commands", "commands": [ ... ],
    /// "group": true }`: several commands as one group, which "validates as
    /// a whole" and lands on one frame (Spec 2 §8).
    public static func group(_ commands: [Command], source: AppSource) -> EngineRequest {
        EngineRequest(type: "commands", fields: ["commands": .array(commands.map(encoded)), "group": .bool(true), "source": .string(source.rawValue)])
    }

    /// Spec 2 §9 — `{ "id": 19, "type": "subscribe", "topics": [...] }`.
    public static func subscribe(_ topics: [String]) -> EngineRequest {
        EngineRequest(type: "subscribe", fields: ["topics": .array(topics.map(JSONValue.string))])
    }

    /// Spec 2 §9 — `{ "id": 20, "type": "query", "what": "state" }`, with whatever the query names beside.
    public static func query(_ what: String, _ fields: [String: JSONValue] = [:]) -> EngineRequest {
        var all = fields
        all["what"] = .string(what)
        return EngineRequest(type: "query", fields: all)
    }

    /// Spec 9 §2 — `{ "id": 31, "type": "note", "note": { … }, "text": "…" }`.
    public static func note(_ note: [String: JSONValue], text: String) -> EngineRequest {
        EngineRequest(type: "note", fields: ["note": .object(note), "text": .string(text), "source": .string(AppSource.ui.rawValue)])
    }

    /// Spec 10 §3 — `ping`: "Nothing", answered `pong`.
    public static let ping = EngineRequest(type: "ping")

    /// Spec 10 §3 — `stop`: "Stops the engine on request (Spec 9 §4)".
    public static let stop = EngineRequest(type: "stop")

    /// Spec 10 §3 — `releaseScreen`: "Takes every output off the named
    /// screen until `retakeScreen` puts them back, or for the rest of the run
    /// (§9)"; the screen as `display:<uuid>`.
    public static func releaseScreen(_ screen: String) -> EngineRequest {
        EngineRequest(type: "releaseScreen", fields: ["screen": .string(screen)])
    }

    /// Spec 10 §3 — `retakeScreen`: "Puts back on the named screen every
    /// output released from it in this run" (corrected 2026-11-24).
    public static func retakeScreen(_ screen: String) -> EngineRequest {
        EngineRequest(type: "retakeScreen", fields: ["screen": .string(screen)])
    }

    private static func encoded(_ command: Command) -> JSONValue {
        // A command is plain data and always encodes; null would be refused by the engine as malformed, never run.
        (try? JSONCoding.encode(command)) ?? .null
    }

    /// The request as the line the engine reads, carrying `id`.
    public func line(id: Int) -> Data {
        var members = fields
        members["id"] = .number(Double(id))
        members["type"] = .string(type)
        return Data(JSONCanonical.line(.object(members)).utf8)
    }
}

/// Spec 10 §3, "Connecting" — one connection's requests and messages. It
/// gives each request its id and hands every message that arrives, in the
/// order it arrived, to one receiver: "A connection carries answers and
/// events in the order the engine produces them".
public final class EngineLink: @unchecked Sendable {
    private let transport: any EngineTransport
    private let nextID = Atomic<Int>(0)

    public init(transport: any EngineTransport) {
        self.transport = transport
    }

    /// Starts reading. `deliver` is called on the connection's own thread,
    /// once per message and in order; `.closed` is the last it is given.
    public func start(deliver: @escaping @Sendable (Incoming) -> Void) {
        transport.start(onLine: { line in deliver(Incoming.read(line)) }, onClose: { deliver(.closed) })
    }

    /// Sends a request and returns the id its reply will carry. Spec 10 §1 —
    /// "Nothing is queued to send later": a request to a connection that has
    /// closed goes nowhere, and its id is never answered.
    @discardableResult
    public func send(_ request: EngineRequest) -> Int {
        let id = nextID.add(1, ordering: .relaxed).newValue
        transport.send(request.line(id: id))
        return id
    }

    public func close() {
        transport.close()
    }
}
