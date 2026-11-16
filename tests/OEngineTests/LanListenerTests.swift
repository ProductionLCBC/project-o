import XCTest
import OCore
@testable import OEngine

/// Spec 10 §2, "The LAN API" — "At launch the engine reads its two Keychain
/// items ... on a background thread, and makes the token if there is none
/// ... Until it has the token, the LAN listener stays closed and the
/// `engine` topic says so (§3)"; "the engine retries a refused registration
/// or send every few seconds, and the `engine` topic shows the LAN as
/// waiting meanwhile". Spec 2 §9 — "the first message on a connection must
/// be `{"type": "auth", "token": "..."}` or the socket closes"; "advertises
/// over Bonjour as `_projecto._tcp` with the machine's campus name".
/// Spec 10 §18, Area 19, the LAN and the Keychain: "No auth closes a LAN
/// socket; the listener opens only once the token is read, and the `engine`
/// topic says so meanwhile; a Bonjour registration or OSC send refused while
/// the system asks is retried."
///
/// The wire and the Keychain are the harness's (Spec 4 §14): no network, no
/// real Keychain. `LanLoopbackTests` runs the same rules over the system's
/// own WebSocket on the loopback interface.
final class LanListenerTests: XCTestCase {
    var api: ApiFixture!
    var server: FakeLanServer!
    var store: MemorySecretStore!
    var listener: LanListener!
    var watcher: ApiTestClient!

    override func tearDown() {
        listener?.stop()
    }

    /// An engine, a listener on the fake wire and the in-memory Keychain, and a local client watching the `engine` topic.
    func make(retrySeconds: Double = 0.1, authSeconds: Double = 5, token: String? = nil) throws {
        api = try ApiFixture()
        server = FakeLanServer()
        let settings = api.engine.engine.machine.settings
        store = MemorySecretStore(token.map { [SecretAccount.token(machine: settings.uuid): Data($0.utf8)] } ?? [:])
        listener = LanListener(hub: api.hub, server: server, secrets: store, machine: settings.uuid, port: settings.network.apiPort,
                               campus: settings.campusName, log: api.engine.log, retrySeconds: retrySeconds, authSeconds: authSeconds)
        watcher = api.local()
        watcher.send("subscribe", ["topics": .array([.string("engine")])])
        api.tick()
        _ = watcher.next()
    }

    /// The LAN's state as the `engine` topic last said it, after a tick.
    func said() -> [String] {
        api.tick()
        return watcher.next().events("engine").compactMap { $0["lan"]?.objectValue?["state"]?.stringValue }
    }

    var standing: LanStanding { api.hub.lan }

    func test_theListenerStaysClosedUntilTheTokenIsReadAndTheEngineTopicSaysSo() throws {
        try make(token: "the-token")
        store.holdReads()   // the system's prompt is up, and nobody has answered
        listener.start()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(server.starts, [], "no listener while the Keychain read waits")
        XCTAssertEqual(standing.state, .closed)
        XCTAssertNil(server.connect(), "nothing to connect to")
        // The engine isn't held back: it ticks, and answers its own socket.
        let ping = watcher.send("ping")
        api.tick()
        XCTAssertEqual(watcher.answer(to: ping)?["type"], .string("pong"))

        store.answerPrompt()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
        XCTAssertEqual(server.starts, [FakeLanServer.Start(port: 8220, serviceName: "Manheim", serviceType: "_projecto._tcp")],
                       "on apiPort, advertised as _projecto._tcp with the campus name")
        XCTAssertEqual(said(), ["open"], "and the engine topic says so, once")
        XCTAssertEqual(store.writes, 0, "the token that was there is the token")
    }

    func test_theFirstLaunchMakesTheTokenAndAClientSignsInWithIt() throws {
        try make()
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
        let account = SecretAccount.token(machine: api.engine.engine.machine.settings.uuid)
        let token = try XCTUnwrap(store.item(account).flatMap { String(data: $0, encoding: .utf8) }, "made and written at the first launch")
        XCTAssertEqual(token.count, 43)

        let peer = try XCTUnwrap(server.connect(from: "192.0.2.44"))
        XCTAssertEqual(standing.clients, 0, "connected is not signed in")
        peer.send(.object(["id": .number(1), "type": .string("auth"), "token": .string(token)]))
        XCTAssertTrue(waitUntil(5) { peer.messages.count == 1 })
        XCTAssertEqual(peer.messages.first?["result"], .string("ok"))
        XCTAssertEqual(peer.messages.first?["api"], .number(1), "the envelope carries api 1 in the auth reply")
        XCTAssertEqual(standing.clients, 1, "the client count")

        // It is a LAN client: its commands are `api`, and what only the local socket takes is refused.
        peer.send(.object(["id": .number(2), "type": .string("command"), "source": .string("key"), "command": try api.command("channel 2 write text \"Amen\"")]))
        peer.send(.object(["id": .number(3), "type": .string("stop")]))
        api.tick(2)
        XCTAssertTrue(waitUntil(5) { peer.messages.count == 3 })
        XCTAssertEqual(api.entries.last?.source.kind, .api, "a LAN client's commands are always api")
        XCTAssertEqual(peer.messages.last?["reason"]?.stringValue?.hasPrefix("localOnly: "), true, "what only the local socket takes")

        let counts = watcher.next().events("engine").compactMap { $0["lan"]?.objectValue?["clients"] }
        XCTAssertEqual(counts.last, .number(1), "the engine topic carries the count")
        peer.leave()
        XCTAssertTrue(waitUntil(5) { self.standing.clients == 0 })
        api.tick()
        XCTAssertEqual(watcher.next().events("engine").last?["lan"]?.objectValue?["clients"], .number(0), "and its change")
    }

    /// "No auth closes a LAN socket."
    func test_noAuthClosesALanSocket() throws {
        // The time a silent client is given is long here, so what closes these is what they sent.
        try make(authSeconds: 60, token: "the-token")
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })

        let asks = try XCTUnwrap(server.connect())
        asks.send(.object(["id": .number(1), "type": .string("query"), "what": .string("state")]))
        XCTAssertTrue(waitUntil(5) { asks.isClosed }, "the first message isn't auth")
        XCTAssertTrue(asks.messages.isEmpty, "and it is told nothing")

        let wrong = try XCTUnwrap(server.connect())
        wrong.send(.object(["id": .number(1), "type": .string("auth"), "token": .string("not-the-token")]))
        XCTAssertTrue(waitUntil(5) { wrong.isClosed }, "a wrong token")

        let none = try XCTUnwrap(server.connect())
        none.send(.object(["id": .number(1), "type": .string("auth")]))
        XCTAssertTrue(waitUntil(5) { none.isClosed }, "an auth without one")

        let commands = try XCTUnwrap(server.connect())
        commands.send(.object(["id": .number(1), "type": .string("command"), "command": try api.command("channel 3 write text \"x\"")]))
        XCTAssertTrue(waitUntil(5) { commands.isClosed })
        let before = api.entries.count
        api.tick(2)
        XCTAssertEqual(api.entries.count, before, "and its command never ran")

        // One that signs in stays.
        let good = try XCTUnwrap(server.connect())
        good.send(.object(["id": .number(1), "type": .string("auth"), "token": .string("the-token")]))
        XCTAssertTrue(waitUntil(5) { good.messages.count == 1 })
        XCTAssertFalse(good.isClosed)
        XCTAssertEqual(standing.clients, 1)
    }

    /// Area 19 reading — a client that connects and says nothing is closed
    /// too, and one that has signed in is not.
    func test_aClientThatSaysNothingIsClosedAfterTheTimeAllowed() throws {
        try make(authSeconds: 0.3, token: "the-token")
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
        let silent = try XCTUnwrap(server.connect())
        let good = try XCTUnwrap(server.connect())
        good.send(.object(["id": .number(1), "type": .string("auth"), "token": .string("the-token")]))
        XCTAssertFalse(silent.isClosed)
        XCTAssertTrue(waitUntil(5) { silent.isClosed }, "no auth within the time allowed")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(good.isClosed, "signed in, it stays")
        XCTAssertEqual(standing.clients, 1)
    }

    /// Spec 10 §3 — the `keychain` badge: "an item can't be read".
    func test_aKeychainThatCannotBeReadKeepsTheListenerClosedAndShowsTheBadge() throws {
        try make()
        store.unreadable = "the user denied access"
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.keychainUnreadable })
        XCTAssertEqual(server.starts, [], "no token, no listener")
        XCTAssertEqual(standing.state, .closed)
        api.tick()
        let event = try XCTUnwrap(watcher.next().events("engine").last)
        XCTAssertEqual(event["badges"], .array([.object(["kind": .string("keychain")])]))
        XCTAssertEqual(event["lan"]?.objectValue?["state"], .string("closed"))
        XCTAssertTrue(api.engine.log.contains("the Keychain can't be read"))
        // Area 19 reading: it is read once; a refusal stands until the next launch.
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertEqual(store.reads, 1)
    }

    /// "a Bonjour registration ... refused while the system asks is retried",
    /// "and the `engine` topic shows the LAN as waiting meanwhile".
    func test_aRefusedRegistrationIsRetriedAndTheLanShowsWaitingMeanwhile() throws {
        // The time between tries is long enough here that a slow machine still sees the state in between.
        try make(retrySeconds: 0.8, token: "the-token")
        server.refuseNext(2)
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .waiting })
        XCTAssertEqual(said(), ["waiting"])
        XCTAssertNil(server.connect(), "nothing listens while it is refused")
        XCTAssertTrue(waitUntil(10) { self.standing.state == .open }, "someone answered, and the next try went through")
        XCTAssertEqual(server.starts.count, 3, "the first try and two more")
        XCTAssertEqual(said(), ["open"])
        XCTAssertEqual(api.engine.log.recent.filter { $0.message.contains("isn't open") }.count, 1, "said once, however often it is tried")
        // Open, it is left alone.
        Thread.sleep(forTimeInterval: 1.2)
        XCTAssertEqual(server.starts.count, 3)
    }

    /// Area 19 reading — the system doesn't always say it refused: a listener
    /// that opens and is never advertised counts as refused.
    func test_aListenerThatIsNeverAdvertisedCountsAsRefused() throws {
        try make(retrySeconds: 0.15, token: "the-token")
        server.advertises = false
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .waiting })
        XCTAssertTrue(waitUntil(5) { self.server.starts.count >= 3 }, "tried again, and again")
        XCTAssertEqual(standing.state, .waiting)
        server.advertises = true
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
    }

    /// Area 19 reading — a failure that isn't a refusal shows as closed and is retried the same way.
    func test_aPortSomethingElseHoldsShowsClosedAndIsRetried() throws {
        try make(retrySeconds: 0.8, token: "the-token")
        server.failNext(1)
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.server.starts.count == 1 })
        XCTAssertEqual(standing.state, .closed)
        XCTAssertTrue(waitUntil(10) { self.standing.state == .open }, "the port came free")
        XCTAssertEqual(server.starts.count, 2)
        XCTAssertTrue(api.engine.log.contains("the address is already in use"))
    }

    /// "an OSC send refused while the system asks": the LAN shows waiting while one is held back.
    func test_aRefusedOscSendShowsTheLanAsWaiting() throws {
        try make(token: "the-token")
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
        XCTAssertEqual(said(), ["open"])
        let refused = LockedFlag()
        let held: @Sendable () -> Bool = { refused.value }
        api.engine.engine.oscRefused = held
        refused.set(true)
        XCTAssertEqual(said(), ["waiting"])
        refused.set(false)
        XCTAssertEqual(said(), ["open"])
    }

    func test_stopClosesTheListener() throws {
        try make(token: "the-token")
        listener.start()
        XCTAssertTrue(waitUntil(5) { self.standing.state == .open })
        listener.stop()
        XCTAssertEqual(server.stops, 1)
        XCTAssertEqual(standing.state, .closed)
        XCTAssertNil(server.connect())
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(server.starts.count, 1, "and it isn't opened again")
    }
}
