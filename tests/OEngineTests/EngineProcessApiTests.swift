import Foundation
import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 10 §2, "When the engine is ready" — "It ... opens its local socket
/// and its LAN listener at that list's step 5, when it takes commands, so
/// `hello` means it is ready." Spec 10 §18, Area 19 — "the first message is
/// `hello`, sent only once the engine takes commands"; "`stop` runs the
/// shutdown macro, writes `last.json` clean and answers before the process
/// exits".
///
/// The engine process itself, assembled as `oengine run` assembles it, on a
/// temporary copy of the fixture roots: the real backend, clocks and threads,
/// the real socket. Its outputs name screens no Mac has, so they are absent
/// and nothing opens on a screen; its audio is off. It needs a GPU, so it
/// runs where the Metal tests run.
final class EngineProcessApiTests: XCTestCase {
    @MainActor
    func test_theProcessOpensItsSocketOnceItTakesCommandsAndStopsOnRequest() throws {
        try MetalHarness.skipOnHostedRunner("the engine process")
        guard MetalBackend.isAvailable else { throw XCTSkip("no Metal device on this machine") }
        let folder = try ShortFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: EngineFixtures.libraryRoot, to: folder.appendingPathComponent("library"))
        try FileManager.default.copyItem(at: EngineFixtures.machineRoot, to: folder.appendingPathComponent("machine"))
        var roots = try LoadedRoots.load(libraryRoot: folder.appendingPathComponent("library"), machineRoot: folder.appendingPathComponent("machine"))
        // Outputs on screens that aren't there (`display:main`, `display:confidence`): absent, so no window opens.
        roots.machine.outputs = try EngineFixtures.spikeMachine().outputs
        roots.machine.settings.network.oscOutTargets = []
        roots.machine.settings.startupMacro = nil
        var options = EngineProcess.Options()
        options.audio = false
        options.oscPort = 0

        let socketPath = folder.appendingPathComponent("machine/engine.sock").path
        let process = try EngineProcess(roots: roots, options: options, log: EngineLog(category: "test-process"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "no socket before the engine takes commands")
        process.start()
        defer { process.stop() }
        XCTAssertNil(process.lan, "a run given no LAN opens no listener and reads no Keychain")
        XCTAssertEqual(process.displaySinks.map(\.standing), [.absent, .absent], "its screens aren't there: absent, never on another screen")
        XCTAssertEqual(process.engine.scheduler?.activeClock.name, "timer", "with no output on a screen it runs on its timer")

        // The app's side, on a thread of its own: the main thread stays free for the engine's own work on it.
        let outcome = LockedList()
        let done = expectation(description: "the client has its answers")
        let run = process.engine.run
        Thread.detachNewThread {
            defer { done.fulfill() }
            guard case .success(let client) = SocketClient.connect(to: socketPath) else { return outcome.append("no connection") }
            guard let hello = client.next(), hello["type"] == .string("hello") else { return outcome.append("no hello") }
            outcome.append("hello mach=\(hello["mach"]?.stringValue ?? "")")
            let ping = client.send("ping")
            outcome.append("ping -> \(client.answer(to: ping)?["type"]?.stringValue ?? "nothing")")
            let state = client.send("query", ["what": .string("state")])
            outcome.append("state -> \(client.answer(to: state)?["type"]?.stringValue ?? "nothing")")
            let stop = client.send("stop")
            let answer = client.answer(to: stop, seconds: 10)
            outcome.append("stop -> \(answer?["result"]?.stringValue ?? "nothing") unsaved=\(answer?["unsaved"]?.arrayValue?.count ?? -1)")
        }
        wait(for: [done], timeout: 30)
        XCTAssertEqual(outcome.values, ["hello mach=\(MachServiceName.engine(run: run))", "ping -> pong", "state -> answer", "stop -> ok unsaved=0"])
        XCTAssertFalse(process.engine.isRunning, "the engine stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath), "and took its socket with it")
        let last = try JSONValue.parse(try Data(contentsOf: folder.appendingPathComponent("machine/state/last.json"))).objectValue
        XCTAssertEqual(last?["clean"], .bool(true), "a stop on request is a clean end (Spec 9 §4)")
    }

    /// Spec 10 §2 — "The LAN API is Spec 2 §9's WebSocket on `apiPort`, with
    /// the token and Bonjour": the process opens its listener on the
    /// machine's port under its campus name once the token is there, and a
    /// client that signs in reaches the running engine. The wire and the
    /// Keychain are the harness's.
    @MainActor
    func test_theProcessOpensItsLanListenerOnceTheTokenIsReadAndClosesItAtStop() throws {
        try MetalHarness.skipOnHostedRunner("the engine process")
        guard MetalBackend.isAvailable else { throw XCTSkip("no Metal device on this machine") }
        let folder = try ShortFolder.make()
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: EngineFixtures.libraryRoot, to: folder.appendingPathComponent("library"))
        try FileManager.default.copyItem(at: EngineFixtures.machineRoot, to: folder.appendingPathComponent("machine"))
        var roots = try LoadedRoots.load(libraryRoot: folder.appendingPathComponent("library"), machineRoot: folder.appendingPathComponent("machine"))
        roots.machine.outputs = try EngineFixtures.spikeMachine().outputs
        roots.machine.settings.network.oscOutTargets = []
        roots.machine.settings.startupMacro = nil
        let server = FakeLanServer()
        let store = MemorySecretStore()
        var options = EngineProcess.Options()
        options.audio = false
        options.oscPort = 0
        options.lan = EngineProcess.LanOptions(server: server, secrets: store)

        let process = try EngineProcess(roots: roots, options: options, log: EngineLog(category: "test-process"))
        XCTAssertEqual(server.starts, [], "nothing listens before the engine takes commands")
        XCTAssertEqual(store.reads, 0)
        process.start()
        var stopped = false
        defer { if !stopped { process.stop() } }
        XCTAssertTrue(waitUntil(10) { process.engine.api.lan.state == .open })
        let settings = roots.machine.settings
        XCTAssertEqual(server.starts, [FakeLanServer.Start(port: settings.network.apiPort, serviceName: settings.campusName, serviceType: "_projecto._tcp")])
        let token = try XCTUnwrap(store.item(SecretAccount.token(machine: settings.uuid)).flatMap { String(data: $0, encoding: .utf8) }, "made at this first launch")

        let remote = try XCTUnwrap(server.connect())
        remote.send(.object(["id": .number(1), "type": .string("auth"), "token": .string(token)]))
        remote.send(.object(["id": .number(2), "type": .string("query"), "what": .string("state")]))
        XCTAssertTrue(waitUntil(10) { remote.messages.contains { $0["id"] == .number(2) } }, "the running engine answers a LAN client")
        XCTAssertEqual(remote.messages.first { $0["id"] == .number(2) }?["type"], .string("answer"))

        process.stop()
        stopped = true
        XCTAssertEqual(server.stops, 1, "the listener closes with the engine")
        XCTAssertEqual(process.engine.api.lan.state, .closed)
    }
}
