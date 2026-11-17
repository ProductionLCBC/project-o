import Foundation
import XCTest
import OCore
import OAppScripted
@testable import OApp

/// Spec 10 §2 and §3, end to end — the supervisor, the session and the store
/// as the app wires them: a real local socket, the connection's own threads,
/// the main queue as the hop and the system's clock, against the scripted
/// engine playing the engine's recorded answers. One test of the wiring; the
/// rules themselves are tested without threads or time elsewhere.
@MainActor
final class EngineEndToEndTests: XCTestCase {
    /// Runs the main run loop until `condition` holds; false when it doesn't within `seconds`.
    private func spin(_ seconds: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return true
    }

    func test_theAppFindsAnEngineReadsItFollowsItAndStartsAnotherWhenItEnds() throws {
        let folder = try ShortSocketFolder.make()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("machine.json"))
        let stock = try StockEngine.recorded(in: RecordedAPI.folder)
        let engine = ScriptedEngine(socketURL: roots.socket)
        engine.hello = StockEngine.hello(pid: 4182)
        engine.respond = { @Sendable in stock.respond($0) }
        try engine.start()
        addTeardownBlock { engine.stop() }

        let launcher = FakeLauncher()
        launcher.running(pid: 4182, path: "/Applications/Project O.app/Contents/Helpers/oengine")
        let store = ShowStore()
        let supervisor = EngineSupervisor(roots: roots, store: store, launcher: launcher, connector: UnixEngineConnector(), clock: SystemAppClock(),
                                          settings: .init(executable: URL(fileURLWithPath: "/Applications/Project O.app/Contents/Helpers/oengine")))
        supervisor.operatorScreen = { "display:37D8832A" }
        supervisor.start()

        // It finds the engine, and reads what it reports.
        XCTAssertTrue(spin { supervisor.phase == .connected && store.hasState && store.catalog != nil && store.hasMedia }, "\(supervisor.phase)")
        XCTAssertEqual(launcher.launches, [], "an engine answered: none was started")
        XCTAssertEqual(store.catalog?.playlists.count, 3)
        XCTAssertEqual(store.live.listTitle, "Great Is Thy Faithfulness")
        XCTAssertEqual(store.saving.disk, "ok", "the topics that keep a value sent it on subscribe")
        XCTAssertNil(store.cannotSend)

        // It follows it: an event the engine sends shows in the store.
        var cleared = try RecordedAPI.event("popups.cleared")
        cleared["seq"] = .number(200)
        engine.send(.object(cleared))
        XCTAssertTrue(spin { store.popups[1]?.text == "" })

        // A command goes out with its source and its result comes back.
        var outcome: CommandOutcome?
        supervisor.session?.send(.command(.next, source: .key)) { outcome = $0?.outcome }
        XCTAssertTrue(spin { outcome != nil })
        XCTAssertEqual(outcome?.kind, .ok)
        XCTAssertEqual(engine.requests(ofType: "command").first?.objectValue?["source"], .string("key"))

        // The engine ends: the banner, and another is started, as a relaunch.
        engine.stop()
        launcher.exit(4182, .gone)
        XCTAssertTrue(spin { launcher.launches.count == 1 }, "\(supervisor.phase)")
        XCTAssertFalse(store.isConnected)
        XCTAssertEqual(store.catalog?.playlists.count, 3, "the library stays browsable as the app last read it")
        XCTAssertEqual(launcher.arguments().last, "--relaunch")

        // The engine it started comes up, and is told the last one ended.
        let next = ScriptedEngine(socketURL: roots.socket)
        next.hello = StockEngine.hello(pid: launcher.pids[0], run: "0000aaaa-0000-4000-8000-000000000003")
        next.respond = { @Sendable in stock.respond($0) }
        try next.start()
        addTeardownBlock { next.stop() }
        XCTAssertTrue(spin { supervisor.phase == .connected && store.hasState }, "\(supervisor.phase)")
        XCTAssertNotNil(next.waitForRequest { $0.objectValue?["note"]?.objectValue?["event"] == .string("engineEnded") })
        let notes = next.requests(ofType: "note").compactMap { $0.objectValue?["note"]?.objectValue?["event"]?.stringValue }
        XCTAssertEqual(notes, ["appStarted", "engineEnded"])
        supervisor.leaveEngineRunning()
    }
}
