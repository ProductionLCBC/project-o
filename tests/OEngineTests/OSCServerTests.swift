import XCTest
import Darwin
import OCore
@testable import OEngine

/// Spec 2 §6 and Spec 4 §15 — the engine "driven by the Spec 2 vocabulary
/// over OSC": commands land on the next tick, bundles are one group, errors go
/// back to the sender, feedback reaches targets and registered clients.
final class OSCServerTests: XCTestCase {
    var engine: HeadlessEngine!
    var server: OSCServer!
    var client: UDPTestClient!

    override func setUpWithError() throws {
        engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        let ids = Set(engine.engine.library.mediaIndex.entries.map(\.id))
        let enqueue: @Sendable (CommandGroup) -> Void = { [weak engine] group in engine?.send(group) }
        server = OSCServer(port: 0, targets: [], mediaIDs: ids, log: engine.log, enqueue: enqueue)
        try server.start()
        client = try UDPTestClient()
    }

    override func tearDown() {
        server.stop()
        client.close()
    }

    func test_aMessageLandsOnTheNextTick() throws {
        try client.send(OSCMessage("/o/channel/2/write", [.string("text \"Verse one\"")]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertEqual(engine.state.channels[2]?.content.kind, "text")
        XCTAssertEqual(engine.lastExecuted.first?.source.kind, .osc)
        XCTAssertEqual(server.received, 1)
    }

    func test_typedArgumentsAndTheShortForms() throws {
        try client.send(OSCMessage("/o/ch/1/grade", [.int32(1)]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertEqual(engine.state.channels[1]?.attributes.grade.value, 1)
    }

    func test_aBundleIsOneGroupInOrder() throws {
        let bundle = OSCBundle(elements: [
            .message(OSCMessage("/o/channel/1/write", [.string("media \(EngineFixtures.dawn)")])),
            .message(OSCMessage("/o/channel/2/write", [.string("text \"x\"")])),
        ])
        try client.send(bundle.encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { engine.control.queuedGroups == 1 })
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.count, 2)
        XCTAssertEqual(engine.lastExecuted[0].group, engine.lastExecuted[1].group, "one group")
        XCTAssertEqual(engine.state.channels[1]?.content.media?.startedAtFrame, Int(engine.frame))
    }

    func test_aBadCommandIsRejectedWithAnErrorToTheSender() throws {
        try client.send(OSCMessage("/o/channel/2/nonsense").encoded(), to: server.boundPort)
        let reply = try XCTUnwrap(client.receive(timeout: 5))
        guard case .success(.message(let message)) = OSCPacket.decode(reply) else { return XCTFail("an OSC reply") }
        XCTAssertEqual(message.address, "/o/error")
        XCTAssertEqual(message.arguments.first, .string("/o/channel/2/nonsense"))
        XCTAssertEqual(server.rejected, 1)
        engine.tick()
        XCTAssertTrue(engine.lastExecuted.isEmpty, "nothing ran")
    }

    func test_registeredClientsGetFeedbackUntilTheyExpire() throws {
        try client.send(OSCMessage("/o/register", [.string("127.0.0.1"), .int32(Int32(client.port))]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { server.liveRegistrations.count == 1 })
        engine.send("list 42 cue 1")
        engine.tick()
        let messages = OSCFeedbackDeriver.messages(for: engine.lastExecuted, state: engine.state, library: engine.engine.library, machine: engine.engine.machine)
        XCTAssertTrue(messages.contains(OSCFeedback.liveCue(1)), "\(messages.map(\.address))")
        XCTAssertTrue(messages.contains(OSCFeedback.liveLabel("Verse 1")))
        XCTAssertTrue(messages.contains(OSCFeedback.channelState(1, .playing)))
        XCTAssertTrue(messages.contains { $0.address == "/o/channel/2/content" })
        server.feedback(messages)
        var received: [String] = []
        while let data = client.receive(timeout: 1), received.count < messages.count {
            if case .success(.message(let m)) = OSCPacket.decode(data) { received.append(m.address) }
        }
        XCTAssertEqual(received.count, messages.count, "every message reached the registered client")
        XCTAssertTrue(received.contains("/o/live/cue"))
    }

    func test_registrationExpiresAfterSixtySeconds() throws {
        let clock = FakeMonotonic()
        let server = OSCServer(port: 0, targets: [], mediaIDs: [], log: engine.log, now: { clock.now }) { _ in }
        try server.start()
        defer { server.stop() }
        server.handle(OSCMessage("/o/register", [.string("127.0.0.1"), .int32(9000)]).encoded(), from: OSCPeer(host: "127.0.0.1", port: 1))
        XCTAssertEqual(server.liveRegistrations, [OSCPeer(host: "127.0.0.1", port: 9000)])
        clock.advance(seconds: 59)
        XCTAssertEqual(server.liveRegistrations.count, 1)
        clock.advance(seconds: 2)
        XCTAssertEqual(server.liveRegistrations.count, 0, "gone after sixty seconds unless renewed")
    }

    func test_queryAnswersWithTheCurrentValue() throws {
        server.queryHandler = { @Sendable address in address == "/o/output/1/stack" ? OSCFeedback.outputStack(1, stack: 1) : nil }
        try client.send(OSCMessage("/o/query", [.string("/o/output/1/stack")]).encoded(), to: server.boundPort)
        let reply = try XCTUnwrap(client.receive(timeout: 5))
        guard case .success(.message(let message)) = OSCPacket.decode(reply) else { return XCTFail() }
        XCTAssertEqual(message, OSCFeedback.outputStack(1, stack: 1))
    }

    func test_highRateFeedbackNeedsASubscription() throws {
        try client.send(OSCMessage("/o/register", [.string("127.0.0.1"), .int32(Int32(client.port))]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { server.liveRegistrations.count == 1 })
        server.feedback([OSCFeedback.channelRemaining(1, ms: 5000)])
        XCTAssertNil(client.receive(timeout: 0.3), "not subscribed: nothing")
        try client.send(OSCMessage("/o/subscribe", [.string("/o/channel/1/remaining")]).encoded(), to: server.boundPort)
        Thread.sleep(forTimeInterval: 0.1)
        server.feedback([OSCFeedback.channelRemaining(1, ms: 5000)])
        XCTAssertNotNil(client.receive(timeout: 2), "subscribed: delivered")
    }
}

/// A plain UDP socket for the tests: send to the server, receive replies.
final class UDPTestClient {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw OSCServerError.socket("client") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw OSCServerError.bind(0, "client") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: actual.sin_port)
    }

    func send(_ data: Data, to port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, data.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard sent == data.count else { throw OSCServerError.socket("send") }
    }

    func receive(timeout: TimeInterval) -> Data? {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = recv(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    func close() {
        Darwin.close(fd)
    }
}

/// A monotonic clock the test moves by hand.
final class FakeMonotonic: @unchecked Sendable {
    private var nanoseconds: Int64 = 1_000_000_000
    var now: MonotonicTime { MonotonicTime(nanoseconds: nanoseconds) }
    func advance(seconds: Int64) { nanoseconds += seconds * 1_000_000_000 }
}
