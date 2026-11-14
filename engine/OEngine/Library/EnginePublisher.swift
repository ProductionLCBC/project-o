// OEngine — Spec 2 §9, the engine's own publisher until the API exists.

import Foundation
import OCore

/// Spec 2 §9 — "Until the API server exists (Area 19), the engine's areas
/// publish their events and answer their queries and requests through the
/// engine's own publisher, which their tests read in-process." Events go to
/// every subscriber of their `topic`, in the order they were published, on
/// the publishing thread: the control side, after a build, never the render
/// thread. A subscriber hands the event on and returns at once.
public final class EnginePublisher: @unchecked Sendable {
    public struct Subscription: Hashable, Sendable {
        let id: Int
    }

    private struct Subscriber {
        var topics: Set<String>
        var deliver: @Sendable (JSONValue) -> Void
    }

    /// Spec 2 §9 — what answers one query: the request's fields in, the
    /// answer's fields or the refusal out.
    public typealias Answerer = @Sendable ([String: JSONValue]) -> Result<[String: JSONValue], Rejection>

    /// Spec 2 §9 as Spec 9 §9 corrected it — what carries out one request
    /// that is neither a command nor a query (Spec 9 §2's `note`): the
    /// request's fields, the source of the client that sent it and the
    /// client's name in; the result's name (`ok`, `noop`) with its fields, or
    /// the refusal, out.
    public typealias Handler = @Sendable ([String: JSONValue], CommandSource, String) -> Result<(result: String, fields: [String: JSONValue]), Rejection>

    private let lock = NSLock()
    private var subscribers: [Int: Subscriber] = [:]
    private var answerers: [String: Answerer] = [:]
    private var handlers: [String: Handler] = [:]
    private var nextID = 0

    public init() {}

    /// Spec 2 §9 — an area's handler for the requests of this `type`.
    public func handle(_ type: String, with handler: @escaping Handler) {
        lock.lock()
        handlers[type] = handler
        lock.unlock()
    }

    /// Spec 9 §2 — a request such as `{ "id": 31, "type": "note", … }`,
    /// answered with its `id`: `{ "id": 31, "type": "result", "result": "ok",
    /// "seq": … }`, or the rejected result. `source` is the sender's (Spec 10
    /// §2: the app names it on the local socket, and a LAN client's is `api`);
    /// `client` names the connection.
    public func request(_ request: JSONValue, source: CommandSource, client: String) -> JSONValue {
        let members = request.objectValue ?? [:]
        let id = members["id"] ?? .null
        let type = members["type"]?.stringValue ?? ""
        lock.lock()
        let handler = handlers[type]
        lock.unlock()
        guard let handler else { return Self.rejected(id, Rejection(reason: .badValue, message: "there is no \(type) request")) }
        switch handler(members, source, client) {
        case .success(let outcome):
            var fields = outcome.fields
            fields["id"] = id
            fields["type"] = .string("result")
            fields["result"] = .string(outcome.result)
            return .object(fields)
        case .failure(let rejection):
            return Self.rejected(id, rejection)
        }
    }

    /// Spec 2 §9 — an area's answer to the query of this `what`.
    public func answer(_ what: String, with answerer: @escaping Answerer) {
        lock.lock()
        answerers[what] = answerer
        lock.unlock()
    }

    /// Spec 2 §9 — "A query is answered with its request's `id` as `{"id": …,
    /// "type": "answer", …}` and the fields its definition gives, and refused
    /// with the rejected result Spec 10 §3 shows": `{"id": …, "type":
    /// "result", "result": "rejected", "reason": "code: message"}`.
    public func query(_ request: JSONValue) -> JSONValue {
        let members = request.objectValue ?? [:]
        let id = members["id"] ?? .null
        let what = members["what"]?.stringValue ?? ""
        lock.lock()
        let answerer = answerers[what]
        lock.unlock()
        guard let answerer else { return Self.rejected(id, Rejection(reason: .badValue, message: "there is no \(what) query")) }
        switch answerer(members) {
        case .success(var fields):
            fields["id"] = id
            fields["type"] = .string("answer")
            return .object(fields)
        case .failure(let rejection):
            return Self.rejected(id, rejection)
        }
    }

    static func rejected(_ id: JSONValue, _ rejection: Rejection) -> JSONValue {
        .object(["id": id, "type": .string("result"), "result": .string("rejected"),
                 "reason": .string("\(rejection.reason.rawValue): \(rejection.message)")])
    }

    /// Spec 2 §9 — `subscribe` to one or more topics.
    @discardableResult
    public func subscribe(_ topics: Set<String>, _ deliver: @escaping @Sendable (JSONValue) -> Void) -> Subscription {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        subscribers[nextID] = Subscriber(topics: topics, deliver: deliver)
        return Subscription(id: nextID)
    }

    /// Spec 2 §9 — a subscriber stops receiving its topics.
    public func unsubscribe(_ subscription: Subscription) {
        lock.lock()
        subscribers.removeValue(forKey: subscription.id)
        lock.unlock()
    }

    /// One event, `{ "type": "event", "topic": …, … }`, to its topic's subscribers.
    public func publish(_ event: JSONValue) {
        guard case .object(let members) = event, case .string(let topic)? = members["topic"] else { return }
        lock.lock()
        let targets = subscribers.sorted { $0.key < $1.key }.filter { $0.value.topics.contains(topic) }.map(\.value.deliver)
        lock.unlock()
        for deliver in targets { deliver(event) }
    }
}
