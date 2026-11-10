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

    private let lock = NSLock()
    private var subscribers: [Int: Subscriber] = [:]
    private var nextID = 0

    public init() {}

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
