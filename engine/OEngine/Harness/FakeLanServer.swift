// OEngine — the harness's LAN wire (Spec 4 §14).

import Foundation
import OCore

/// The LAN's wire in memory: what the listener asked for, and a way to make
/// the wire answer as the system would — open, advertise, refuse — and to
/// connect a client.
public final class FakeLanServer: LanServer, @unchecked Sendable {
    public struct Start: Equatable, Sendable {
        public var port: Int
        public var serviceName: String?
        public var serviceType: String
    }

    private let lock = NSLock()
    private var startList: [Start] = []
    private var stopCount = 0
    private var events: (@Sendable (LanServerEvent) -> Void)?
    private var refusals = 0
    private var failures = 0
    private var quiet = false

    public init() {}

    /// When false a start opens the port and Bonjour never says the name is registered, as the system does when it
    /// holds a registration back without an error.
    public var advertises: Bool {
        get { lock.lock(); defer { lock.unlock() }; return !quiet }
        set { lock.lock(); quiet = !newValue; lock.unlock() }
    }

    /// Every start so far, in order: the first, and each retry.
    public var starts: [Start] { lock.lock(); defer { lock.unlock() }; return startList }
    public var stops: Int { lock.lock(); defer { lock.unlock() }; return stopCount }
    public var isListening: Bool { lock.lock(); defer { lock.unlock() }; return events != nil }

    /// The next `count` starts are refused, as while the system's local-network prompt waits for an answer.
    public func refuseNext(_ count: Int) {
        lock.lock()
        refusals = count
        lock.unlock()
    }

    /// The next `count` starts fail, as on a port something else holds.
    public func failNext(_ count: Int) {
        lock.lock()
        failures = count
        lock.unlock()
    }

    public func start(port: Int, serviceName: String?, serviceType: String, events: @escaping @Sendable (LanServerEvent) -> Void) {
        lock.lock()
        startList.append(Start(port: port, serviceName: serviceName, serviceType: serviceType))
        let refused = refusals > 0
        if refused { refusals -= 1 }
        let failed = !refused && failures > 0
        if failed { failures -= 1 }
        self.events = refused || failed ? nil : events
        let advertise = !quiet
        lock.unlock()
        if refused {
            events(.refused("the system refused the registration (-65570)"))
        } else if failed {
            events(.failed("the address is already in use"))
        } else {
            events(.listening(port: port))
            if advertise, let serviceName { events(.advertised(name: serviceName)) }
        }
    }

    public func stop() {
        lock.lock()
        stopCount += 1
        events = nil
        lock.unlock()
    }

    /// A client connects; nil while the listener isn't open.
    public func connect(from remote: String = "192.0.2.10") -> FakeLanPeer? {
        lock.lock()
        let events = self.events
        lock.unlock()
        guard let events else { return nil }
        let peer = FakeLanPeer(remote: remote)
        events(.connection(peer))
        return peer
    }
}

/// A LAN client in memory: what the engine sent it, and what it sends.
public final class FakeLanPeer: LanPeer, @unchecked Sendable {
    public let remote: String
    private let lock = NSLock()
    private var written: [Data] = []
    private var shut = false
    private var onText: (@Sendable (Data) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var unread: [Data] = []
    /// What the client sends reaches the engine one message at a time, in the order sent, as on a socket.
    private let delivery = DispatchQueue(label: "o.harness.lan.peer")

    init(remote: String) {
        self.remote = remote
    }

    public func read(onText: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        delivery.sync {
            lock.lock()
            self.onText = onText
            self.onClose = onClose
            // What the client sent before anyone read waits in the socket, as it does on a real one.
            let waiting = unread
            unread = []
            lock.unlock()
            waiting.forEach(onText)
        }
    }

    public func write(_ line: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !shut else { return false }
        written.append(line)
        return true
    }

    public func close() {
        lock.lock()
        let already = shut
        shut = true
        let handler = onClose
        onClose = nil
        lock.unlock()
        if !already { handler?() }
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return shut }

    /// The client sends one message.
    public func send(_ message: JSONValue) {
        let text = Data(JSONCanonical.line(message).utf8)
        delivery.sync {
            lock.lock()
            let handler = shut ? nil : onText
            if !shut, handler == nil { unread.append(text) }
            lock.unlock()
            handler?(text)
        }
    }

    /// The client goes away.
    public func leave() {
        close()
    }

    /// Everything the engine has sent this client, in order.
    public var messages: [[String: JSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        return written.compactMap { (try? JSONValue.parse($0))?.objectValue }
    }
}
