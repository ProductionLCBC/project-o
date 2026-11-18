import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §2 and §9 — which engine the window drives, by where the app
/// stands with it: over the supervisor with a launcher, a connector and a
/// clock of the test's own, the show model, the keys and ⌃⌥⌘⎋'s releaser.
@MainActor
final class SessionWiringTests: XCTestCase {
    @MainActor
    final class Rig {
        let engine: EngineSupervisorTests.Rig
        let model: ShowModel
        let keys: KeysModel
        let source = MachLinkTests.FakeSource()
        let mach: MachLink
        let releaser: ScreenReleaser
        let wiring: SessionWiring
        var raised: [Bool] = []

        init() throws {
            engine = try EngineSupervisorTests.Rig()
            model = ShowModel(store: engine.store, clock: engine.clock)
            keys = KeysModel(model: model, clock: engine.clock)
            mach = MachLink(source: source, clock: engine.clock) { work, done in done(work()) }
            releaser = ScreenReleaser(clock: engine.clock)
            wiring = SessionWiring(model: model, mach: mach, releaser: releaser)
            // As the app's controller ties them.
            engine.supervisor.onPhase = { [unowned self] in self.wiring.phaseChanged($0) }
            engine.supervisor.onConnected = { [unowned self] in self.wiring.connected($0) }
            engine.supervisor.releasedScreens = { [unowned self] in self.releaser.released }
            releaser.onSilent = { [unowned self] in self.engine.supervisor.engineIsSilent() }
            releaser.onRaised = { [unowned self] in self.raised.append($0) }
        }

        /// The engine comes up and answers what a session asks first.
        @discardableResult
        func comeUp() throws -> FakeTransport {
            engine.engineComesUp()
            let transport = try XCTUnwrap(engine.connector.last)
            transport.engineAnswers(transport.id(of: "subscribe"), ["result": .string("ok")], type: "result")
            transport.engineAnswers(transport.id(of: "query", what: "state"), try RecordedAPI.load("state"))
            transport.engineAnswers(transport.id(of: "query", what: "catalog"), try RecordedAPI.load("catalog"))
            transport.engineAnswers(transport.id(of: "query", what: "media"), try RecordedAPI.load("media"))
            return transport
        }

        func press(_ key: String) {
            if let stroke = KeyStroke(key) { keys.press(stroke) }
        }
    }

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func rig() throws -> Rig {
        let rig = try Rig()
        addTeardownBlock { @MainActor in rig.engine.remove() }
        rig.engine.supervisor.start()
        return rig
    }

    func test_connectedAKeysCommandGoesToTheEngineWithSourceKey() throws {
        let rig = try rig()
        let transport = try rig.comeUp()
        rig.press("space")
        let commands = transport.sent("command")
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?["source"], .string("key"))
        XCTAssertEqual(commands.first?["command"]?.objectValue?["cmd"], .string("playlist.next"))
        XCTAssertEqual(rig.source.connects, ["org.lcbc.projecto.engine.51e2"], "the Mach channel `hello` named")
    }

    /// Area 13 reading — a press made while the engine is silent is dropped,
    /// never left to land in a burst when it wakes; and when the engine
    /// answers again the window drives it again.
    func test_whileTheEngineIsSilentPressesAreDroppedAndWhenItAnswersAgainTheyGo() throws {
        let rig = try rig()
        let transport = try rig.comeUp()
        rig.engine.clock.advance(by: 2)
        let ping = transport.id(of: "ping")
        rig.engine.clock.advance(by: 5.1)
        XCTAssertEqual(rig.engine.supervisor.phase, .notResponding)
        // Spec 10 §2 — "every control that sends something is disabled with the reason".
        XCTAssertEqual(rig.model.store.cannotSend, .engineSilent)
        XCTAssertEqual(rig.model.store.cannotEdit(master: false), .engineSilent)
        XCTAssertFalse(rig.model.nextRow.nextEnabled)
        XCTAssertEqual(ShowWording.unavailable(rig.model.nextRow.unavailable), "The engine isn’t responding.")
        XCTAssertEqual(rig.model.clearsTiles.filter(\.isEnabled).count, 0)
        for _ in 0..<5 { rig.press("space") }
        XCTAssertFalse(rig.model.send(Actions.clearAll()), "a press is dropped like a key")
        XCTAssertEqual(transport.sent("command").count, 0, "nothing waits in the socket for a stuck engine")
        XCTAssertFalse(rig.mach.isConnected)
        // The engine wakes: a pong, however late.
        transport.engineAnswers(ping, [:], type: "pong")
        XCTAssertEqual(rig.engine.supervisor.phase, .connected)
        XCTAssertNil(rig.model.store.cannotSend, "the controls come back")
        XCTAssertTrue(rig.model.nextRow.nextEnabled)
        XCTAssertEqual(transport.sent("command").count, 0, "and nothing pressed meanwhile goes now")
        rig.press("space")
        XCTAssertEqual(transport.sent("command").count, 1, "the window drives the engine again")
        XCTAssertEqual(rig.source.connects.count, 2, "and reads its pictures again")
    }

    /// Spec 10 §9 — "If the engine doesn't answer within two seconds, the
    /// window stays raised with the not-responding banner (§2), so the way
    /// back holds even with the engine stuck."
    func test_theReleaseKeyAsksASilentEngineAndTwoSecondsOfSilenceShowTheBanner() throws {
        let rig = try rig()
        let transport = try rig.comeUp()
        rig.releaser.release(screen: "display:FA21CBA0")
        XCTAssertEqual(rig.raised, [true], "at once")
        XCTAssertEqual(transport.sent("releaseScreen").first?["screen"], .string("display:FA21CBA0"))
        rig.engine.clock.advance(by: 1.9)
        XCTAssertEqual(rig.engine.supervisor.phase, .connected)
        rig.engine.clock.advance(by: 0.2)
        XCTAssertEqual(rig.engine.supervisor.phase, .notResponding, "the not-responding banner")
        XCTAssertTrue(rig.releaser.isRaised)
        // Pressed again over the silent engine, the request still goes: it is the one that must wait.
        rig.releaser.release(screen: "display:FA21CBA0")
        XCTAssertEqual(transport.sent("releaseScreen").count, 2)
        XCTAssertEqual(rig.engine.launcher.kills, [], "The app never ends the engine on its own")
        // The engine wakes and answers.
        transport.engineAnswers(transport.id(of: "releaseScreen"), ["result": .string("ok"), "outputs": .array([.number(1)])], type: "result")
        XCTAssertFalse(rig.releaser.isRaised)
        XCTAssertEqual(rig.raised, [true, false])
        // The next pong clears the banner, as after a missed ping, and the keys drive the engine again.
        rig.press("space")
        XCTAssertEqual(transport.sent("command").count, 0, "still silent, as far as its pings say")
        rig.engine.clock.advance(by: 2)
        transport.engineAnswers(transport.id(of: "ping"), [:], type: "pong")
        XCTAssertEqual(rig.engine.supervisor.phase, .connected)
        rig.press("space")
        XCTAssertEqual(transport.sent("command").count, 1)
    }

    /// Spec 10 §9 — "The app remembers the screens it released while it
    /// runs, names them with `--released` to each engine it starts (§2), and
    /// sends `releaseScreen` again to any engine it connects to."
    func test_aScreenReleasedIsNamedToTheNextEngineAndAskedOfItAgain() throws {
        let rig = try rig()
        let first = try rig.comeUp()
        rig.releaser.release(screen: "display:FA21CBA0")
        first.engineAnswers(first.id(of: "releaseScreen"), ["result": .string("ok"), "outputs": .array([.number(1)])], type: "result")
        XCTAssertFalse(rig.releaser.isRaised)
        rig.engine.engineDies()
        rig.press("space")
        XCTAssertEqual(first.sent("command").count, 0, "the engine is away: the key is dropped")
        // The app starts it again, at once.
        rig.engine.clock.advance(by: 0)
        let launch = try XCTUnwrap(rig.engine.launcher.launches.last)
        XCTAssertEqual(rig.engine.launcher.launches.count, 2)
        let index = try XCTUnwrap(launch.arguments.firstIndex(of: "--released"))
        XCTAssertEqual(launch.arguments[index + 1], "display:FA21CBA0")
        let second = try rig.comeUp()
        XCTAssertFalse(second === first)
        XCTAssertEqual(second.sent("releaseScreen").first?["screen"], .string("display:FA21CBA0"))
        XCTAssertFalse(rig.releaser.isRaised, "asking again doesn't raise the window")
        rig.press("space")
        XCTAssertEqual(second.sent("command").count, 1, "and the keys drive the new engine")
        XCTAssertEqual(first.sent("command").count, 0)
    }

    func test_pressedWithTheEngineGoneTheWindowStaysRaisedUntilTheNextEngineAnswers() throws {
        let rig = try rig()
        _ = try rig.comeUp()
        rig.engine.engineDies()
        rig.releaser.release(screen: "display:FA21CBA0")
        XCTAssertTrue(rig.releaser.isRaised)
        rig.engine.clock.advance(by: 0)
        let second = try rig.comeUp()
        XCTAssertTrue(rig.releaser.isRaised)
        second.engineAnswers(second.id(of: "releaseScreen"), ["result": .string("ok"), "outputs": .array([])], type: "result")
        XCTAssertFalse(rig.releaser.isRaised)
    }
}
