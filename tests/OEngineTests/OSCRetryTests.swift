import XCTest
import OCore
@testable import OEngine

/// Spec 10 §2 — "macOS asks on behalf of the app that started the engine, may
/// refuse Bonjour and OSC sends until someone answers, and may ask again
/// after an update (ADR 0007), so the engine retries a refused registration
/// or send every few seconds". Spec 10 §18, Area 19: "a Bonjour registration
/// or OSC send refused while the system asks is retried."
///
/// Area 19 reading — what is sent again is the newest message per address for
/// that target: feedback mirrors state (Spec 2 §6), so an address's older
/// values are of no use once a newer one exists.
final class OSCRetryTests: XCTestCase {
    /// What the socket would have been asked to send, and whether the system lets it.
    final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [(address: String, peer: OSCPeer)] = []
        private var code: Int32 = 0

        var refusing: Int32 {
            get { lock.lock(); defer { lock.unlock() }; return code }
            set { lock.lock(); code = newValue; lock.unlock() }
        }

        func transmit(_ data: Data, _ peer: OSCPeer) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            guard code == 0 else { return code }
            // An OSC message starts with its address, zero-terminated.
            let address = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            sent.append((address, peer))
            return 0
        }

        var addresses: [String] { lock.lock(); defer { lock.unlock() }; return sent.map(\.address) }
        var datagrams: Int { lock.lock(); defer { lock.unlock() }; return sent.count }
    }

    let target = OSCTarget(host: "192.0.2.20", port: 9000)

    func make(_ wire: Wire, log: EngineLog = EngineLog(category: "test-osc")) -> OSCServer {
        let server = OSCServer(port: 0, targets: [target], mediaIDs: [], log: log) { _ in }
        server.transmit = { data, peer in wire.transmit(data, peer) }
        return server
    }

    func message(_ address: String, _ value: Int32) -> OSCMessage {
        OSCMessage(address, [.int32(value)])
    }

    func test_aRefusedSendIsKeptAndSentAgainWhenTheSystemAllowsIt() {
        let wire = Wire()
        let log = EngineLog(category: "test-osc")
        let server = make(wire, log: log)
        XCTAssertFalse(server.sendsRefused)

        wire.refusing = EHOSTUNREACH   // what a send gets while the local-network prompt waits
        server.feedback([message("/o/channel/1/state", 1)])
        XCTAssertTrue(server.sendsRefused, "held back, and known to be")
        XCTAssertEqual(server.sent, 0)
        XCTAssertEqual(log.recent.filter { $0.message.contains("was refused") }.count, 1)

        server.retryRefused()
        XCTAssertTrue(server.sendsRefused, "still refused: still kept")
        XCTAssertEqual(wire.datagrams, 0)

        wire.refusing = 0              // someone answered the prompt
        server.retryRefused()
        XCTAssertEqual(wire.addresses, ["/o/channel/1/state"], "sent again")
        XCTAssertFalse(server.sendsRefused)
        XCTAssertEqual(server.sent, 1)
        XCTAssertTrue(log.contains("OSC sends are going out again"))
        server.retryRefused()
        XCTAssertEqual(wire.datagrams, 1, "and only once")
        XCTAssertEqual(log.recent.filter { $0.message.contains("was refused") }.count, 1, "the refusal was said once")
    }

    func test_onlyTheNewestMessagePerAddressIsSentAgain() {
        let wire = Wire()
        let server = make(wire)
        wire.refusing = EHOSTUNREACH
        server.feedback([message("/o/channel/1/state", 1), message("/o/stack/1/blackout", 0)])
        server.feedback([message("/o/channel/1/state", 2)])
        server.feedback([message("/o/channel/1/state", 3)])
        wire.refusing = 0
        server.retryRefused()
        XCTAssertEqual(wire.addresses.sorted(), ["/o/channel/1/state", "/o/stack/1/blackout"], "one datagram an address, not one a change")
        XCTAssertFalse(server.sendsRefused)
    }

    /// A newer value that went out must not be followed by an older one kept from before.
    func test_aValueThatHasGoneSinceIsNotFollowedByAnOlderOne() {
        let wire = Wire()
        let server = make(wire)
        wire.refusing = EHOSTUNREACH
        server.feedback([message("/o/channel/1/state", 1)])
        wire.refusing = 0
        server.feedback([message("/o/channel/1/state", 2)])   // goes straight out
        XCTAssertEqual(wire.datagrams, 1)
        XCTAssertFalse(server.sendsRefused, "the older value has nothing left to say")
        server.retryRefused()
        XCTAssertEqual(wire.datagrams, 1)
    }

    func test_anErrorThatIsNotARefusalIsNotKept() {
        let wire = Wire()
        let server = make(wire)
        wire.refusing = EMSGSIZE
        server.feedback([message("/o/channel/1/state", 1)])
        XCTAssertFalse(server.sendsRefused, "a message the socket can't carry would never go")
    }

    func test_theKeptMessagesAreBounded() {
        let wire = Wire()
        let server = make(wire)
        wire.refusing = EPERM
        for index in 0..<(OSCServer.refusedAddressLimit + 50) { server.feedback([message("/o/test/\(index)", Int32(index))]) }
        wire.refusing = 0
        server.retryRefused()
        XCTAssertEqual(wire.datagrams, OSCServer.refusedAddressLimit, "no more than the limit is kept for one target")
    }
}
