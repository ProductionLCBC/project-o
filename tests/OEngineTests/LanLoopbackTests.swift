import XCTest
import Network
import OCore
@testable import OEngine

/// Spec 10 §2 — "The LAN API is Spec 2 §9's WebSocket on `apiPort`". The
/// listener's rules once more, over the system's own WebSocket this time: a
/// real listener on this Mac's loopback interface, on a port the system
/// picks, and a real WebSocket client. Nothing here leaves the Mac, nothing
/// is advertised, and the Keychain is the harness's.
final class LanLoopbackTests: XCTestCase {
    /// The real server without Bonjour: it listens, and says it is advertised so the listener opens.
    final class QuietServer: LanServer, @unchecked Sendable {
        let real = NetworkLanServer(loopbackOnly: true)

        func start(port: Int, serviceName: String?, serviceType: String, events: @escaping @Sendable (LanServerEvent) -> Void) {
            real.start(port: 0, serviceName: nil, serviceType: serviceType) { event in
                events(event)
                if case .listening = event { events(.advertised(name: serviceName ?? "")) }
            }
        }

        func stop() { real.stop() }
    }

    /// A WebSocket client, as a remote would be one.
    final class Client: @unchecked Sendable {
        let connection: NWConnection
        private let lock = NSLock()
        private var texts: [String] = []
        private var ended = false

        init(port: Int) {
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
            // A WebSocket client names its server as a URL: the handshake's request is made from it.
            let url = URL(string: "ws://127.0.0.1:\(port)/") ?? URL(fileURLWithPath: "/")
            connection = NWConnection(to: .url(url), using: parameters)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.end()
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "test.lan.client"))
            receive()
        }

        private func end() {
            lock.lock()
            ended = true
            lock.unlock()
        }

        private func receive() {
            connection.receiveMessage { [weak self] content, context, _, error in
                guard let self else { return }
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                guard error == nil, let metadata, metadata.opcode != .close else {
                    self.end()
                    return
                }
                if metadata.opcode == .text, let content, let text = String(data: content, encoding: .utf8) {
                    self.lock.lock()
                    self.texts.append(text)
                    self.lock.unlock()
                }
                self.receive()
            }
        }

        func send(_ message: JSONValue, opcode: NWProtocolWebSocket.Opcode = .text) {
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "send", metadata: [metadata])
            connection.send(content: Data(JSONCanonical.line(message).utf8), contentContext: context, isComplete: true, completion: .idempotent)
        }

        var messages: [[String: JSONValue]] {
            lock.lock()
            defer { lock.unlock() }
            return texts.compactMap { (try? JSONValue.parse(Data($0.utf8)))?.objectValue }
        }

        var raw: [String] { lock.lock(); defer { lock.unlock() }; return texts }
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return ended }
        func close() { connection.cancel() }
    }

    func test_aWebSocketClientSignsInAndDrivesTheEngine() throws {
        let api = try ApiFixture()
        let settings = api.engine.engine.machine.settings
        let store = MemorySecretStore([SecretAccount.token(machine: settings.uuid): Data("loopback-token".utf8)])
        let listener = LanListener(hub: api.hub, server: QuietServer(), secrets: store, machine: settings.uuid, port: settings.network.apiPort,
                                   campus: settings.campusName, log: api.engine.log)
        listener.start()
        defer { listener.stop() }
        XCTAssertTrue(waitUntil(10) { api.hub.lan.state == .open }, "the listener opened: \(api.engine.log.recent.suffix(3).map(\.message))")
        let port = listener.openPort
        XCTAssertGreaterThan(port, 0)

        // No auth closes the socket.
        let stranger = Client(port: port)
        defer { stranger.close() }
        stranger.send(.object(["id": .number(1), "type": .string("query"), "what": .string("state")]))
        XCTAssertTrue(waitUntil(10) { stranger.isClosed }, "closed without a word")
        XCTAssertEqual(stranger.raw, [])

        // A client that signs in.
        let remote = Client(port: port)
        defer { remote.close() }
        remote.send(.object(["id": .number(1), "type": .string("auth"), "token": .string("loopback-token")]))
        XCTAssertTrue(waitUntil(10) { remote.messages.count == 1 })
        XCTAssertEqual(remote.messages.first?["result"], .string("ok"))
        XCTAssertEqual(remote.messages.first?["api"], .number(1))
        XCTAssertFalse(try XCTUnwrap(remote.raw.first).hasSuffix("\n"), "one JSON object a frame, with no line end")
        XCTAssertEqual(api.hub.lan.clients, 1)

        remote.send(.object(["id": .number(2), "type": .string("subscribe"), "topics": .array([.string("channels")])]))
        remote.send(.object(["id": .number(3), "type": .string("command"), "command": try api.command("channel 2 write text \"Amen\"")]))
        remote.send(.object(["id": .number(4), "type": .string("query"), "what": .string("state")]))
        XCTAssertTrue(waitUntil(10) {
            api.tick()
            return remote.messages.contains { $0["id"] == .number(4) }
        }, "the answers came back over the socket")
        let messages = remote.messages
        XCTAssertEqual(messages.first { $0["id"] == .number(3) }?["result"], .string("ok"))
        XCTAssertEqual(messages.first { $0["id"] == .number(4) }?["type"], .string("answer"))
        XCTAssertEqual(api.entries.last?.source.kind, .api, "a LAN client's command")
        if case .text(let text)? = api.engine.state.channels[2]?.content {
            XCTAssertEqual(text.fields["body"], "Amen")
        } else {
            XCTFail("channel 2 holds the text the remote wrote")
        }
        XCTAssertTrue(waitUntil(10) {
            api.tick()
            return !remote.messages.events("channels").isEmpty
        }, "and its events")

        // A frame that isn't text closes the connection.
        remote.send(.object(["id": .number(5), "type": .string("ping")]), opcode: .binary)
        XCTAssertTrue(waitUntil(10) { remote.isClosed })
        XCTAssertTrue(waitUntil(10) { api.hub.lan.clients == 0 })
    }
}
