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

    private let lock = NSLock()
    private var subscribers: [Int: Subscriber] = [:]
    private var answerers: [String: Answerer] = [:]
    private var nextID = 0

    public init() {}

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
