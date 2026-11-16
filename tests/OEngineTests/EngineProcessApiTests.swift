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
}
