// OEngine — the harness's API client: a connection in memory.

import Foundation
import OCore

/// Spec 10 §16 — the engine's API tests run "against the fixture roots" with
/// no socket: a transport that keeps every line the engine sends, in order,
/// and a client over it that sends requests as the app or a LAN client would
/// and reads what came back.
public final class MemoryTransport: ApiTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var written: [Data] = []
    private var shut = false
    /// Set to make the next writes fail, as a client that went away would.
    public var failing = false

    public init() {}

    public func write(_ line: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shut, !failing else { return false }
        written.append(line)
        return true
    }

    public func close() {
        lock.lock()
        shut = true
        lock.unlock()
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return shut
    }

    /// Every line written so far, in order.
    public var lines: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return written
    }
}

/// A client of the engine's API in the same process: the local socket's
/// messages, or a LAN client's, over a `MemoryTransport`.
public final class ApiTestClient: @unchecked Sendable {
    public let transport = MemoryTransport()
    public let connection: ApiConnection
    private let hub: ApiHub
    private var nextID = 0
    private var read = 0

    public init(hub: ApiHub, origin: ApiConnection.Origin = .local) {
        self.hub = hub
        connection = hub.accept(transport, origin: origin)
    }

    /// Sends one request, with the next `id` unless it names one, and returns that id.
    @discardableResult
    public func send(_ type: String, _ fields: [String: JSONValue] = [:]) -> Int {
        nextID += 1
        var members = fields
        members["type"] = .string(type)
        if members["id"] == nil { members["id"] = .number(Double(nextID)) }
        hub.receive(Data(JSONCanonical.line(.object(members)).utf8), from: connection)
        return nextID
    }

    /// Sends a line as it is, whatever it holds.
    public func send(raw text: String) {
        hub.receive(Data(text.utf8), from: connection)
    }

    /// Waits for everything placed for this client to be written, then
    /// returns every message so far, in the order the engine sent them.
    public func messages(wait seconds: TimeInterval = 5) -> [[String: JSONValue]] {
        hub.workers.sync {}
        connection.drain(seconds: seconds)
        return transport.lines.compactMap { (try? JSONValue.parse($0))?.objectValue }
    }

    /// The messages that arrived since the last call to `next()`.
    public func next(wait seconds: TimeInterval = 5) -> [[String: JSONValue]] {
        let all = messages(wait: seconds)
        defer { read = all.count }
        return Array(all.dropFirst(read))
    }

    /// The message that answers the request with this id: its result or its answer.
    public func answer(to id: Int, wait seconds: TimeInterval = 5) -> [String: JSONValue]? {
        messages(wait: seconds).first { $0["id"] == .number(Double(id)) && $0["type"] != .string("event") }
    }
}
