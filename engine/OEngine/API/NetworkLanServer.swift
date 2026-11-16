// OEngine — Spec 2 §9, the LAN API's WebSocket over Network.framework.

import Foundation
import Network
import Synchronization

/// Spec 10 §2 — "The LAN API is Spec 2 §9's WebSocket on `apiPort`, with the
/// token and Bonjour." A TCP listener with the system's WebSocket protocol
/// on top, advertised over Bonjour. Each message is one JSON object in a
/// text frame, the same objects the local socket carries a line at a time.
///
/// Area 19 reading — "Nothing listens beyond the local network" (Spec 2 §9)
/// is read as: no relay and nothing published past this Mac's own network
/// interfaces. Connections aren't limited to the same link, since a campus
/// may route between the engine's network and a remote's; the token is what
/// admits a client.
public final class NetworkLanServer: LanServer, @unchecked Sendable {
    /// A message larger than this closes its connection: no request is.
    public static let maximumMessageBytes = 1024 * 1024

    private let queue = DispatchQueue(label: "o.engine.lan")
    private var listener: NWListener?
    private var generation = 0
    private let loopbackOnly: Bool

    /// `loopbackOnly` keeps the listener to this Mac's own loopback interface: the tests' listener, which nothing
    /// outside the Mac can reach and which asks the system for nothing.
    public init(loopbackOnly: Bool = false) {
        self.loopbackOnly = loopbackOnly
    }

    public func start(port: Int, serviceName: String?, serviceType: String, events: @escaping @Sendable (LanServerEvent) -> Void) {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            generation += 1
            let current = generation
            guard port == 0 || (1...65_535).contains(port), let endpointPort = port == 0 ? NWEndpoint.Port.any : NWEndpoint.Port(rawValue: UInt16(port)) else {
                events(.failed("\(port) is not a port"))
                return
            }
            let webSocket = NWProtocolWebSocket.Options()
            webSocket.autoReplyPing = true
            webSocket.maximumMessageSize = Self.maximumMessageBytes
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            if loopbackOnly { parameters.requiredInterfaceType = .loopback }
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
            let made: NWListener
            do {
                made = try NWListener(using: parameters, on: endpointPort)
            } catch {
                events(Self.event(for: error))
                return
            }
            if let serviceName { made.service = NWListener.Service(name: serviceName, type: serviceType) }
            made.stateUpdateHandler = { [weak self, weak made] state in
                // A listener this one has replaced says nothing more.
                guard let self, self.generation == current else { return }
                switch state {
                case .ready:
                    events(.listening(port: Int(made?.port?.rawValue ?? 0)))
                case .waiting(let error):
                    events(.refused("\(error)"))
                case .failed(let error):
                    events(Self.event(for: error))
                default:
                    break
                }
            }
            made.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, self.generation == current else { return }
                if case .add(let endpoint) = change, case .service(let name, _, _, _) = endpoint { events(.advertised(name: name)) }
            }
            made.newConnectionHandler = { connection in
                events(.connection(NetworkLanPeer(connection)))
            }
            listener = made
            made.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            generation += 1
            listener?.cancel()
            listener = nil
        }
    }

    /// A DNS-SD error is Bonjour's: the system refusing the registration, as
    /// it does until someone answers its local-network prompt. Anything else
    /// is the listener's own failure.
    static func event(for error: Error) -> LanServerEvent {
        if let error = error as? NWError, case .dns = error { return .refused("\(error)") }
        return .failed("\(error)")
    }
}

/// One LAN client over an `NWConnection`.
final class NetworkLanPeer: LanPeer, @unchecked Sendable {
    /// A client that takes nothing for this long is gone.
    static let writePatienceSeconds = 10.0

    private let connection: NWConnection
    private let queue: DispatchQueue
    let remote: String
    private let closed = Atomic<Bool>(false)
    private let lock = NSLock()
    private var onClose: (@Sendable () -> Void)?

    init(_ connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "o.engine.lan.peer")
        switch connection.endpoint {
        case .hostPort(let host, _): remote = "\(host)"
        default: remote = "\(connection.endpoint)"
        }
    }

    func read(onText: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.lock()
        self.onClose = onClose
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(onText)
    }

    private func receive(_ onText: @escaping @Sendable (Data) -> Void) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else {
                self?.finish()
                return
            }
            guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata else {
                // No frame and no error: the stream ended.
                self.finish()
                return
            }
            switch metadata.opcode {
            case .text:
                if let content { onText(content) }
            case .close, .binary:
                // A close, or a frame this API doesn't speak.
                self.finish()
                return
            default:
                break   // a ping the system answers, a pong, a continuation it has put together
            }
            self.receive(onText)
        }
    }

    /// One JSON object as one text frame. Returns when the system has taken
    /// it, so a slow client holds its own writer back and nothing else.
    func write(_ line: Data) -> Bool {
        guard !closed.load(ordering: .relaxed) else { return false }
        var text = line
        if text.last == UInt8(ascii: "\n") { text.removeLast() }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        connection.send(content: text, contentContext: context, isComplete: true, completion: .contentProcessed { error in
            outcome.set(error == nil)
            done.signal()
        })
        guard done.wait(timeout: .now() + Self.writePatienceSeconds) == .success else {
            close()
            return false
        }
        return outcome.sent
    }

    /// Whether one send went, handed from the connection's queue to the writer.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set(_ sent: Bool) {
            lock.lock()
            value = sent
            lock.unlock()
        }

        var sent: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func close() {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return }
        connection.cancel()
        finish()
    }

    private func finish() {
        closed.store(true, ordering: .releasing)
        lock.lock()
        let handler = onClose
        onClose = nil
        lock.unlock()
        connection.cancel()
        handler?()
    }
}
