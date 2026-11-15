// OEngine — Spec 2 §9 and Spec 10 §3, one client's connection to the API.

import Foundation
import OCore

/// The wire under one connection: the local socket's, the LAN's WebSocket,
/// or the harness's in memory. A transport carries whole lines, each one JSON
/// object (Spec 10 §2, "one JSON object per line"), and nothing else; the
/// order of what goes out is the connection's business, not the wire's.
public protocol ApiTransport: AnyObject, Sendable {
    /// Writes one line to the client and returns when it has gone; false when
    /// the client is gone. Called from the connection's writer thread only.
    func write(_ line: Data) -> Bool
    /// Closes the wire, from any thread; a write waiting on it gives up.
    func close()
}

/// Spec 10 §3 — "A connection carries answers and events in the order the
/// engine produces them, so an answer reflects every event sent before it".
///
/// The order is fixed when a message is *placed*, on the control side at a
/// build boundary, not when its bytes are ready. An event or a result is
/// placed with its bytes. An answer that takes work (a catalog, a list) is
/// placed as an empty place, in order, and a worker fills it; the writer
/// sends strictly from the front and waits for an empty place to be filled,
/// so nothing placed after an answer can overtake it. The control thread
/// only ever appends; it never waits for the client or for the worker.
public final class ApiConnection: @unchecked Sendable {
    /// Spec 10 §2 — where the connection came from: the local socket, which
    /// only the engine's own user can open, or the LAN's listener.
    public enum Origin: String, Sendable {
        case local
        case lan
    }

    /// Spec 10 §3 (Area 19 reading) — a client that falls this far behind is
    /// closed; it connects again and asks again, as after any reconnect.
    public static let limitBytes = 4 * 1024 * 1024

    public let id: Int
    public let origin: Origin
    /// Names the connection for the notes' cap and for typing runs (Spec 9
    /// §2, Spec 5 §5); never logged.
    public let client: String
    private let transport: any ApiTransport
    private let log: EngineLog
    private let onClose: @Sendable (ApiConnection) -> Void

    private struct Place {
        var number: Int
        var line: Data?
    }

    private let condition = NSCondition()
    private var places: [Place] = []
    private var nextPlace = 0
    private var waitingBytes = 0
    private var writing = false
    private var closed = false

    // The hub's own record of the connection, read and written under the hub's lock.
    var topics: Set<String> = []
    var previewStacks: Set<Int> = []
    var authorized: Bool

    init(id: Int, origin: Origin, client: String, transport: any ApiTransport, log: EngineLog, onClose: @escaping @Sendable (ApiConnection) -> Void) {
        self.id = id
        self.origin = origin
        self.client = client
        self.transport = transport
        self.log = log
        self.onClose = onClose
        authorized = origin == .local
        let writer = Thread { [self] in writeLoop() }
        writer.name = "o.engine.api.writer.\(id)"
        writer.qualityOfService = .userInitiated
        writer.start()
    }

    /// Places one message, with its bytes, after everything placed before it.
    public func send(_ message: JSONValue) {
        send(line: Data(JSONCanonical.line(message).utf8))
    }

    /// Places one line, already printed: an event goes to every subscriber as the same bytes.
    func send(line: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !closed else { return }
        places.append(Place(number: nextPlace, line: line))
        nextPlace += 1
        waitingBytes += line.count
        condition.broadcast()
    }

    /// Places an answer that isn't ready: an empty place, in order, for `fill`.
    func reserve() -> Int {
        condition.lock()
        defer { condition.unlock() }
        let number = nextPlace
        nextPlace += 1
        guard !closed else { return number }
        places.append(Place(number: number, line: nil))
        return number
    }

    /// Fills the place `reserve` returned; the writer sends it when everything before it has gone.
    func fill(_ place: Int, with message: JSONValue) {
        let line = Data(JSONCanonical.line(message).utf8)
        condition.lock()
        defer { condition.unlock() }
        guard !closed, let index = places.firstIndex(where: { $0.number == place }) else { return }
        places[index].line = line
        waitingBytes += line.count
        condition.broadcast()
    }

    /// Waits until everything placed has been written, or the connection
    /// closed; false when `seconds` pass first. The `stop` request's answer
    /// goes out this way before the process exits (Spec 10 §3).
    @discardableResult
    public func drain(seconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: seconds)
        condition.lock()
        defer { condition.unlock() }
        while !closed, !places.isEmpty || writing {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    public var isClosed: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed
    }

    /// Closes the connection, from any thread. Once.
    public func close() {
        condition.lock()
        let already = closed
        closed = true
        places = []
        waitingBytes = 0
        condition.broadcast()
        condition.unlock()
        guard !already else { return }
        transport.close()
        onClose(self)
    }

    private func writeLoop() {
        while true {
            condition.lock()
            while !closed, places.first?.line == nil { condition.wait() }
            guard !closed, let line = places.first?.line else {
                condition.unlock()
                return
            }
            places.removeFirst()
            waitingBytes -= line.count
            let behind = waitingBytes
            writing = true
            condition.unlock()

            let written = behind <= Self.limitBytes && transport.write(line)

            condition.lock()
            writing = false
            condition.broadcast()
            condition.unlock()
            if !written {
                if behind > Self.limitBytes { log.warning("api client \(client) fell \(behind) bytes behind and was closed") }
                close()
                return
            }
        }
    }
}
