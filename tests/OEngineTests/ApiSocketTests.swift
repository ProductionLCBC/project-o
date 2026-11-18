import Foundation
import XCTest
import OCore
@testable import OEngine
@testable import OMach

/// Spec 10 §2, "The local socket" (R2) — "A Unix domain socket that only its
/// owner can open (mode 0600), and the engine closes any connection whose
/// peer, by `getpeereid`, is another user. It carries Spec 2 §9's messages,
/// one JSON object per line. No token is sent: the engine's first message is
/// `hello`, naming its version, the API version, its process id, the machine,
/// the run and the Mach service". Spec 10 §18, Area 19, the socket — "A
/// connection from another user is closed; the first message is `hello` ...
/// a stale socket is replaced."
final class ApiSocketTests: XCTestCase {
    var folder: URL!
    var engine: HeadlessEngine!
    var socket: LocalSocket?
    let machine = UUID(uuidString: "7A7A0000-0000-4000-8000-000000000001") ?? UUID()
    let run = UUID(uuidString: "51E20000-0000-4000-8000-000000000002") ?? UUID()

    var path: String { folder.appendingPathComponent("engine.sock").path }

    override func setUpWithError() throws {
        folder = try ShortFolder.make()
        engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        engine.engine.api.identify(ApiHub.Identity(engine: "0.4.0", pid: 4182, machine: machine, run: run, mach: MachServiceName.engine(run: run)))
    }

    override func tearDownWithError() throws {
        socket?.stop()
        engine.engine.api.closeAll()
        try? FileManager.default.removeItem(at: folder)
    }

    /// The socket as the process opens it: every connection that passes the peer check joins the hub.
    @discardableResult
    func open(seams: LocalSocket.Seams = .live) throws -> LocalSocket {
        let hub = engine.engine.api
        let socket = LocalSocket(url: folder.appendingPathComponent("engine.sock"), seams: seams, log: EngineLog(category: "test-socket")) { transport in
            let connection = hub.accept(transport, origin: .local)
            transport.read(onLine: { [weak connection] line in
                if let connection { hub.receive(line, from: connection) }
            }, onClose: { [weak connection] in
                connection?.close()
            })
        }
        try socket.start()
        self.socket = socket
        return socket
    }

    func test_theSocketIsInTheMachineRootAndOnlyItsOwnerCanOpenIt() throws {
        XCTAssertEqual(LocalSocket.url(machineRoot: folder).lastPathComponent, "engine.sock")
        try open()
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFSOCK)
        XCTAssertEqual(status.st_mode & 0o777, 0o600, "mode 0600")
        XCTAssertEqual(status.st_uid, geteuid())
    }

    func test_theFirstMessageIsHelloAndItNamesTheEngine() throws {
        try open()
        let client = try SocketClient.connect(to: path).get()
        let hello = try XCTUnwrap(client.next())
        XCTAssertEqual(hello["type"], .string("hello"))
        XCTAssertEqual(hello["api"], .number(1))
        XCTAssertEqual(hello["engine"], .string("0.4.0"))
        XCTAssertEqual(hello["pid"], .number(4182))
        XCTAssertEqual(hello["machine"], .string("7a7a0000-0000-4000-8000-000000000001"))
        XCTAssertEqual(hello["run"], .string("51e20000-0000-4000-8000-000000000002"))
        XCTAssertEqual(hello["mach"], .string("org.lcbc.projecto.engine.51e20000-0000-4000-8000-000000000002"))
        XCTAssertNil(hello["token"], "no token is sent, either way")
    }

    /// "It carries Spec 2 §9's messages, one JSON object per line": a request
    /// over the real socket is answered with its id once a build has run.
    func test_aRequestOverTheSocketIsAnsweredWithItsId() throws {
        try open()
        let client = try SocketClient.connect(to: path).get()
        XCTAssertEqual(client.next()?["type"], .string("hello"))
        let ping = client.send("ping")
        let command = client.send("command", ["source": .string("key"),
                                              "command": .object(["cmd": .string("stack.blackout"), "stack": .number(1), "state": .string("on")])])
        // The requests are on their way through the socket; builds take them as they arrive.
        var pong: [String: JSONValue]?, result: [String: JSONValue]?
        let deadline = Date(timeIntervalSinceNow: 5)
        while pong == nil || result == nil, Date() < deadline {
            engine.tick()
            while let message = client.next(seconds: 0.05) {
                if message["id"] == .number(Double(ping)) { pong = message }
                if message["id"] == .number(Double(command)) { result = message }
            }
        }
        XCTAssertEqual(pong?["type"], .string("pong"))
        XCTAssertEqual(result?["type"], .string("result"))
        XCTAssertEqual(result?["result"], .string("ok"))
        XCTAssertNotNil(result?["seq"]?.intValue)
        XCTAssertEqual(engine.control.commandLog.entries.last?.source.kind, .key, "the source the app named, taken from this socket")
    }

    func test_aConnectionFromAnotherUserIsClosed() throws {
        let other = geteuid() + 1
        let socket = try open(seams: LocalSocket.Seams(peerUser: { _ in other }))
        let client = try SocketClient.connect(to: path).get()
        XCTAssertNil(client.next(seconds: 1), "no hello for another user")
        XCTAssertTrue(client.isClosedByPeer())
        XCTAssertEqual(socket.refusedConnections, 1)
        XCTAssertTrue(engine.engine.api.openConnections.isEmpty)
    }

    func test_aPeerThatCannotBeReadIsClosedToo() throws {
        try open(seams: LocalSocket.Seams(peerUser: { _ in nil }))
        let client = try SocketClient.connect(to: path).get()
        XCTAssertNil(client.next(seconds: 1))
        XCTAssertTrue(client.isClosedByPeer())
    }

    /// "A socket file left by a crash is removed by the next engine before it listens."
    func test_aSocketFileLeftByACrashIsReplaced() throws {
        // A bound socket nobody listens on, as a killed engine leaves it.
        let stale = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(stale)
        if case .success = SocketClient.connect(to: path) { XCTFail("nothing listens on the stale file") }

        try open()
        let client = try SocketClient.connect(to: path).get()
        XCTAssertEqual(client.next()?["type"], .string("hello"), "the new engine's socket, at the same path")
    }

    func test_aFileInTheWayThatIsNotASocketIsLeftAlone() throws {
        try Data("notes".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try open()) { error in
            XCTAssertEqual(error as? LocalSocket.Failure, .notASocket(path: path))
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "notes")
    }

    /// "The socket's path must fit macOS's limit of 103 bytes".
    func test_aPathLongerThanTheLimitIsRefused() throws {
        let fits = "/tmp/" + String(repeating: "m", count: 103 - 5 - "/engine.sock".count) + "/engine.sock"
        XCTAssertEqual(fits.utf8.count, 103)
        XCTAssertNil(LocalSocket.check(path: fits))
        let long = "/tmp/" + String(repeating: "m", count: 104 - 5 - "/engine.sock".count) + "/engine.sock"
        XCTAssertEqual(LocalSocket.check(path: long), .pathTooLong(path: long, bytes: 104))
        // Bytes, not characters: an accented folder name counts double.
        XCTAssertNotNil(LocalSocket.check(path: "/tmp/" + String(repeating: "é", count: 50) + "/engine.sock"))

        let deep = folder.appendingPathComponent(String(repeating: "x", count: 100)).appendingPathComponent("engine.sock")
        let socket = LocalSocket(url: deep, log: EngineLog(category: "test-socket")) { _ in }
        XCTAssertThrowsError(try socket.start()) { error in
            guard case LocalSocket.Failure.pathTooLong = error else { return XCTFail("\(error)") }
        }
    }

    func test_stoppingRemovesTheSocketAndRefusesNewConnections() throws {
        let socket = try open()
        socket.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        if case .success = SocketClient.connect(to: path) { XCTFail("a stopped socket takes no connection") }
    }

    /// `oengine run` on a machine root whose socket can't exist doesn't start.
    func test_runRefusesAMachineRootWhoseSocketPathIsTooLong() throws {
        let deep = folder.appendingPathComponent(String(repeating: "y", count: 100))
        let status = OEngineCommandLine.run(arguments: ["run", "--library", folder.appendingPathComponent("library").path, "--machine", deep.path])
        XCTAssertEqual(status, 1)
        let again = try EngineLock.acquire(machineRoot: deep).get()
        again.release()
    }
}
