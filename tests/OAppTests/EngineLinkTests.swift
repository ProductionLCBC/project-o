import Darwin
import Foundation
import XCTest
import OCore
import OAppScripted
@testable import OApp

/// Spec 10 §2, "The local socket" — "A Unix domain socket ... It carries
/// Spec 2 §9's messages, one JSON object per line." Spec 10 §3,
/// "Connecting" — "A connection carries answers and events in the order the
/// engine produces them". The app's end of the socket against the scripted
/// engine: what connects, what is read and in which order, what is sent.
final class EngineLinkTests: XCTestCase {
    private var folder: URL!
    private var engine: ScriptedEngine!
    private var socket: URL { folder.appendingPathComponent(EngineSocketPath.fileName) }

    override func setUpWithError() throws {
        folder = try ShortSocketFolder.make()
        engine = ScriptedEngine(socketURL: socket)
    }

    override func tearDown() {
        engine.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func connect() throws -> (EngineLink, Recorder<Incoming>) {
        let transport = try UnixEngineConnector().connect(to: socket).get()
        let link = EngineLink(transport: transport)
        let recorder = Recorder<Incoming>()
        link.start { recorder.add($0) }
        return (link, recorder)
    }

    func test_nothingAtThePathIsNoSocket() {
        guard case .failure(let failure) = UnixEngineConnector().connect(to: socket) else { return XCTFail("nothing listens yet") }
        XCTAssertEqual(failure, .noSocket)
    }

    func test_aSocketFileNothingListensOnIsRefused() throws {
        // What a crash leaves: the file a bind made, with no listener behind it.
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = socket.path
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        Darwin.close(descriptor)
        guard case .failure(let failure) = UnixEngineConnector().connect(to: socket) else { return XCTFail("nothing listens") }
        XCTAssertEqual(failure, .refused)
    }

    func test_aPathOverTheLimitIsRefusedBeforeAnythingIsTried() {
        let long = folder.appendingPathComponent(String(repeating: "x", count: 100)).appendingPathComponent(EngineSocketPath.fileName)
        XCTAssertFalse(EngineSocketPath.fits(long))
        guard case .failure(let failure) = UnixEngineConnector().connect(to: long) else { return XCTFail() }
        XCTAssertEqual(failure, .pathTooLong)
        XCTAssertTrue(EngineSocketPath.fits(socket))
    }

    func test_messagesArriveInTheOrderTheEngineSentThemAndClosedIsTheLast() throws {
        engine.hello = .object(["type": .string("hello"), "api": .number(1), "engine": .string("0.1.0"), "pid": .number(4182),
                                "machine": .string("7a7a"), "run": .string("51e2"), "mach": .string("org.lcbc.projecto.engine.51e2")])
        try engine.start()
        let (_, recorder) = try connect()
        XCTAssertTrue(engine.waitForConnections(1))
        engine.send(.object(["type": .string("event"), "topic": .string("live"), "seq": .number(1)]))
        engine.send(.object(["id": .number(1), "type": .string("answer"), "rev": .number(3)]))
        engine.send(.object(["type": .string("event"), "topic": .string("channels"), "channel": .number(2), "seq": .number(2)]))
        engine.send(rawLine: "this is not JSON")
        engine.stop()
        let all = try XCTUnwrap(recorder.wait { $0.last == .closed })
        XCTAssertEqual(all.count, 6)
        guard case .hello(let hello) = all[0] else { return XCTFail("hello is first") }
        XCTAssertEqual(hello.pid, 4182)
        guard case .event("live", _) = all[1], case .reply(1, .answer) = all[2], case .event("channels", _) = all[3],
              case .unknown = all[4] else { return XCTFail("\(all)") }
        XCTAssertEqual(all[5], .closed)
    }

    func test_eachRequestCarriesTheNextIdAndReachesTheEngineAsOneLine() throws {
        try engine.start()
        let (link, _) = try connect()
        let first = link.send(.ping)
        let second = link.send(.command(.next, source: .key))
        let third = link.send(.query("state"))
        XCTAssertEqual([first, second, third], [1, 2, 3])
        XCTAssertNotNil(engine.waitForRequest { $0.objectValue?["id"]?.intValue == 3 })
        let requests = engine.requests
        XCTAssertEqual(requests.map { $0.objectValue?["type"]?.stringValue }, ["ping", "command", "query"])
        XCTAssertEqual(requests[1].objectValue?["source"], .string("key"))
        XCTAssertEqual(requests[1].objectValue?["command"], .object(["cmd": .string("playlist.next")]))
    }

    func test_aReplyFindsItsRequestByItsId() throws {
        engine.respond = { @Sendable request in
            guard let members = request.objectValue, members["type"]?.stringValue == "ping" else { return [] }
            return [.object(["id": members["id"] ?? .null, "type": .string("pong")])]
        }
        try engine.start()
        let (link, recorder) = try connect()
        let id = link.send(.ping)
        let all = try XCTUnwrap(recorder.wait { $0.contains(.reply(id: id, .pong)) })
        XCTAssertEqual(all, [.reply(id: id, .pong)])
    }

    func test_whatIsSentAfterTheConnectionClosedGoesNowhere() throws {
        try engine.start()
        let (link, recorder) = try connect()
        XCTAssertTrue(engine.waitForConnections(1))
        link.close()
        XCTAssertNotNil(recorder.wait { $0.last == .closed })
        XCTAssertTrue(engine.waitForConnections(0))
        link.send(.command(.next, source: .key))
        link.send(.ping)
        // The engine is still there and listening; a new connection's ping is the only request it ever sees.
        let (again, _) = try connect()
        again.send(.ping)
        XCTAssertNotNil(engine.waitForRequest { $0.objectValue?["type"]?.stringValue == "ping" })
        XCTAssertEqual(engine.requests.count, 1, "Spec 10 §1: nothing is queued to send later")
    }
}

/// What a callback on another thread was given, in order, with a wait on a condition over it.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var held: [Value] = []

    func add(_ value: Value) {
        condition.lock()
        held.append(value)
        condition.broadcast()
        condition.unlock()
    }

    var values: [Value] {
        condition.lock()
        defer { condition.unlock() }
        return held
    }

    /// Waits until what has been recorded satisfies `satisfied`, and returns it; nil when it doesn't within `seconds`.
    func wait(seconds: TimeInterval = 5, until satisfied: ([Value]) -> Bool) -> [Value]? {
        let deadline = Date().addingTimeInterval(seconds)
        condition.lock()
        defer { condition.unlock() }
        while !satisfied(held) {
            guard condition.wait(until: deadline) else { return satisfied(held) ? held : nil }
        }
        return held
    }
}
