import Foundation
import XCTest
import OCore
import OFormats
import OEngine
import OAppScripted
@testable import OApp

/// The real engine's API, with no GPU and no engine process: the headless
/// engine (Area 19's harness) on a temporary copy of the fixture roots (Spec
/// 1 §10), launched as the process launches it, its API hub listening on a
/// real local socket, and a thread that ticks it. The app's own client
/// connects to it, so the app's decoders are held to what the engine sends
/// (Spec 10 §16: the scripted engine is for everything else).
final class RealEngine: @unchecked Sendable {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Support
        .deletingLastPathComponent()   // OAppTests
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // root
    static let fixtureRoot = repoRoot.appendingPathComponent("tests/fixtures/library-v1")

    let folder: URL
    let socketFolder: URL
    let headless: HeadlessEngine
    let machineUUID = UUID(uuidString: "7a7a7a7a-0000-4000-8000-000000000001") ?? UUID()
    let run = UUID(uuidString: "51e251e2-0000-4000-8000-000000000002") ?? UUID()
    private let socket: LocalSocket
    private let lock = NSLock()
    private var ticking = true

    var socketURL: URL { socketFolder.appendingPathComponent(EngineSocketPath.fileName) }
    var machineRoot: URL { folder.appendingPathComponent("machine") }
    var hub: ApiHub { headless.engine.api }

    /// `configure` changes the machine before the engine is built; it is `writable` with no startup macro, as the
    /// engine's own tests have it, and keeps its display outputs alone (the fixture pairs a 60p display with a 29.97
    /// SDI output, two rate families no engine runs together).
    init(configure: (inout Machine) -> Void = { _ in }) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-real-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.fixtureRoot, to: folder)
        socketFolder = try ShortSocketFolder.make()
        let roots = try LoadedRoots.load(libraryRoot: folder.appendingPathComponent("library"), machineRoot: folder.appendingPathComponent("machine"))
        var machine = roots.machine
        machine.outputs = machine.outputs.filter { $0.kind == .display }
        machine.settings.libraryMode = .writable
        machine.settings.startupMacro = nil
        configure(&machine)
        headless = try HeadlessEngine(library: roots.library, machine: machine, media: roots.media)
        headless.attachDocuments(roots)
        headless.launch(machineRoot: folder.appendingPathComponent("machine"))
        headless.waitForSnapshots()
        let hub = headless.engine.api
        hub.identify(ApiHub.Identity(machine: machineUUID, run: run, mach: MachServiceNameForTests.name(run: run)))
        socket = LocalSocket(url: socketFolder.appendingPathComponent(EngineSocketPath.fileName), log: EngineLog(category: "oapp-tests")) { transport in
            let connection = hub.accept(transport, origin: .local)
            transport.read(onLine: { [weak connection] line in
                if let connection { hub.receive(line, from: connection) }
            }, onClose: { [weak connection] in
                connection?.close()
            })
        }
        try socket.start()
        // The engine's control side runs on a tick; here a thread stands in for the clock, so a request is answered
        // within a few milliseconds without the test counting ticks.
        let thread = Thread { [weak self] in
            while let self, self.isTicking {
                self.headless.tick()
                usleep(2_000)
            }
        }
        thread.name = "oapp.tests.tick"
        thread.start()
    }

    private var isTicking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticking
    }

    func stop() {
        lock.lock()
        ticking = false
        lock.unlock()
        socket.stop()
        hub.closeAll()
        // The tick thread reads `ticking` between ticks; give its last tick the time to end before the roots go.
        usleep(20_000)
        headless.stop()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: socketFolder)
    }
}

/// The Mach service name `hello` gives, written out here so the app's tests
/// don't need the engine's Mach module for it.
enum MachServiceNameForTests {
    static func name(run: UUID) -> String {
        "org.lcbc.projecto.engine." + run.uuidString.lowercased()
    }
}

/// The app's link to an engine, with what has arrived and waits on it.
final class LinkedClient {
    let link: EngineLink
    let incoming = Recorder<Incoming>()

    init(socket: URL) throws {
        link = EngineLink(transport: try UnixEngineConnector().connect(to: socket).get())
        link.start { [incoming] in incoming.add($0) }
    }

    /// Sends a request and waits for its reply.
    func ask(_ request: EngineRequest, seconds: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) throws -> Reply {
        let id = link.send(request)
        let all = incoming.wait(seconds: seconds) { messages in
            messages.contains { if case .reply(id, _) = $0 { return true } else { return false } }
        }
        for message in all ?? [] {
            if case .reply(id, let reply) = message { return reply }
        }
        XCTFail("no reply to the \(request.type) request within \(seconds) seconds", file: file, line: line)
        throw ConnectFailure.system(call: "reply", code: ETIMEDOUT)
    }

    /// Waits for the first event of `topic` that satisfies `matches`, among those that have arrived or arrive.
    func event(_ topic: String, seconds: TimeInterval = 10, where matches: @escaping ([String: JSONValue]) -> Bool = { _ in true }) -> [String: JSONValue]? {
        func find(_ messages: [Incoming]) -> [String: JSONValue]? {
            for message in messages {
                if case .event(topic, let fields) = message, matches(fields) { return fields }
            }
            return nil
        }
        return incoming.wait(seconds: seconds) { find($0) != nil }.flatMap(find)
    }

    /// Every event of `topic` so far, in order.
    func events(_ topic: String) -> [[String: JSONValue]] {
        incoming.values.compactMap { message in
            if case .event(topic, let fields) = message { return fields }
            return nil
        }
    }

    /// Waits for the engine's `hello`, its first message. The wait's own
    /// closure reads only what it is handed: the recorder's lock is held
    /// around it and isn't one a thread can take twice.
    func waitForHello(seconds: TimeInterval = 10) -> Hello? {
        func find(_ messages: [Incoming]) -> Hello? {
            for message in messages {
                if case .hello(let hello) = message { return hello }
            }
            return nil
        }
        return incoming.wait(seconds: seconds) { find($0) != nil }.flatMap(find)
    }
}
