import Darwin
import Foundation
import XCTest
import OCore
import OAppScripted

/// Spec 10 §16 — "Area 13's tests drive the app's models against a scripted
/// engine on a local socket". Spec 10 §2 — "A Unix domain socket ... It
/// carries Spec 2 §9's messages, one JSON object per line ... the engine's
/// first message is `hello`". The scripted engine itself, read through a
/// plain socket of the test's own.
final class ScriptedEngineTests: XCTestCase {
    private var folder: URL!
    private var engine: ScriptedEngine!

    override func setUpWithError() throws {
        folder = try ShortSocketFolder.make()
        engine = ScriptedEngine(socketURL: folder.appendingPathComponent("engine.sock"))
    }

    override func tearDown() {
        engine.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func test_aNewConnectionIsSentHelloFirst() throws {
        engine.hello = .object(["type": .string("hello"), "api": .number(1)])
        try engine.start()
        let client = try PlainClient(path: engine.socketURL.path)
        XCTAssertEqual(try client.json(), .object(["type": .string("hello"), "api": .number(1)]))
    }

    func test_everyRequestIsKeptAndAnsweredAsTheTestSays() throws {
        engine.respond = { @Sendable request in
            guard request.objectValue?["type"]?.stringValue == "ping" else { return [] }
            return [.object(["id": request.objectValue?["id"] ?? .null, "type": .string("pong")])]
        }
        try engine.start()
        let client = try PlainClient(path: engine.socketURL.path)
        try client.send(#"{"id":1,"type":"ping"}"#)
        XCTAssertEqual(try client.json(), .object(["id": .number(1), "type": .string("pong")]))
        try client.send(#"{"id":2,"type":"note","text":"x"}"#)
        XCTAssertNotNil(engine.waitForRequest { $0.objectValue?["type"]?.stringValue == "note" })
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.requests(ofType: "ping").count, 1)
    }

    func test_itSendsEventsToEveryClientAndSeesThemLeave() throws {
        try engine.start()
        let first = try PlainClient(path: engine.socketURL.path)
        let second = try PlainClient(path: engine.socketURL.path)
        XCTAssertTrue(engine.waitForConnections(2))
        engine.send(.object(["type": .string("event"), "topic": .string("live")]))
        XCTAssertEqual(try first.json(), .object(["type": .string("event"), "topic": .string("live")]))
        XCTAssertEqual(try second.json(), .object(["type": .string("event"), "topic": .string("live")]))
        first.close()
        XCTAssertTrue(engine.waitForConnections(1))
    }

    func test_stoppingItClosesItsClientsAndRemovesTheSocket() throws {
        try engine.start()
        let client = try PlainClient(path: engine.socketURL.path)
        XCTAssertTrue(engine.waitForConnections(1))
        engine.stop()
        XCTAssertNil(try client.line(), "the client reads the end of the connection")
        XCTAssertFalse(FileManager.default.fileExists(atPath: engine.socketURL.path))
        XCTAssertThrowsError(try PlainClient(path: engine.socketURL.path), "and nothing answers at the path any more")
    }

    func test_droppingItsClientsLeavesItListening() throws {
        try engine.start()
        let client = try PlainClient(path: engine.socketURL.path)
        XCTAssertTrue(engine.waitForConnections(1))
        engine.closeConnections()
        XCTAssertNil(try client.line())
        XCTAssertNoThrow(try PlainClient(path: engine.socketURL.path), "a client that was dropped connects again")
    }

    func test_aPathTooLongForASocketIsRefused() {
        let long = folder.appendingPathComponent(String(repeating: "x", count: 120)).appendingPathComponent("engine.sock")
        XCTAssertThrowsError(try ScriptedEngine(socketURL: long).start())
    }
}

/// A blocking Unix-socket client of the test's own: lines out, lines in.
final class PlainClient {
    struct Failure: Error {
        var call: String
        var code: Int32
    }

    private let descriptor: Int32
    private var pending = Data()

    init(path: String) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure(call: "socket", code: errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw Failure(call: "connect", code: code)
        }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        Darwin.close(descriptor)
    }

    func send(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else { throw Failure(call: "write", code: errno) }
    }

    /// The next whole line, or nil when the other end has closed. It waits at most `seconds`.
    func line(seconds: Int32 = 5) throws -> String? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<newline)
                pending.removeSubrange(pending.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, seconds * 1000) > 0 else { throw Failure(call: "poll (no line in time)", code: ETIMEDOUT) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }
            pending.append(contentsOf: buffer[0..<count])
        }
    }

    /// The next line as the JSON value it holds, or nil when the other end has closed.
    func json(seconds: Int32 = 5) throws -> JSONValue? {
        guard let line = try line(seconds: seconds) else { return nil }
        return try JSONValue.parse(Data(line.utf8))
    }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
    }
}
