import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §3, "Requests" — "Beside Spec 2 §9's `command`, `commands`,
/// `subscribe`, `query` and `auth` and Spec 9's `note`, the local socket
/// takes these. On the LAN they are rejected with `localOnly`": `ping`,
/// `stop`, `releaseScreen`, and §12's `passcode`, `unlock`, `resetPasscode`,
/// `token` and `newToken`, which are Area 18's. Spec 2 §9 — "the first
/// message on a connection must be `{"type": "auth", "token": "..."}` or the
/// socket closes." Spec 10 §18, Area 19 — "every request of §3 on the LAN is
/// `localOnly`"; "No auth closes a LAN socket"; "`stop` runs the shutdown
/// macro, writes `last.json` clean and answers before the process exits";
/// "`releaseScreen` closes only that screen's outputs and reports them
/// `released`".
final class ApiRequestTests: XCTestCase {
    func reason(_ message: [String: JSONValue]?) -> String { message?["reason"]?.stringValue ?? "" }

    // MARK: - the LAN

    func test_everyLocalRequestOnTheLanIsLocalOnly() throws {
        let api = try ApiFixture()
        let client = api.lan()
        let local = ["ping", "stop", "releaseScreen", "passcode", "unlock", "resetPasscode", "token", "newToken"]
        let ids = local.map { client.send($0, ["screen": .string("display:AAAAAAAA-0000-4000-8000-000000000001")]) }
        let render = client.send("query", ["what": .string("render")])
        api.tick()
        for (type, id) in zip(local, ids) {
            let answer = try XCTUnwrap(client.answer(to: id), type)
            XCTAssertEqual(answer["result"], .string("rejected"), type)
            XCTAssertTrue(reason(answer).hasPrefix("localOnly: "), "\(type): \(reason(answer))")
        }
        XCTAssertTrue(reason(client.answer(to: render)).hasPrefix("localOnly: "), "`render` answers with a file on this Mac")
        XCTAssertFalse(client.connection.isClosed)
        XCTAssertTrue(api.engine.engine.isRunning || !api.disk.notes("stop").contains { _ in true }, "and the engine did not stop")
        XCTAssertEqual(api.disk.notes("stop").count, 0)
    }

    func test_aLanClientCanStillCommandSubscribeQueryAndNote() throws {
        let api = try ApiFixture()
        let client = api.lan()
        let subscribe = client.send("subscribe", ["topics": .array([.string("channels")])])
        let query = client.send("query", ["what": .string("state")])
        let note = client.send("note", ["note": .object(["event": .string("remoteOpened")]), "text": .string("A remote connected"), "source": .string("ui")])
        api.tick()
        XCTAssertEqual(client.answer(to: subscribe)?["result"], .string("ok"))
        XCTAssertEqual(client.answer(to: query)?["type"], .string("answer"))
        XCTAssertEqual(client.answer(to: note)?["result"], .string("ok"))
        api.engine.settleLogs()
        XCTAssertEqual(api.disk.notes("remoteOpened").last?.source.kind, .api, "a LAN client's note is `api`, whatever it says")
    }

    func test_noAuthClosesALanSocket() throws {
        let api = try ApiFixture()
        api.hub.setToken(ApiFixture.token)

        let silent = ApiTestClient(hub: api.hub, origin: .lan)
        silent.send("ping")
        api.tick()
        XCTAssertTrue(silent.connection.isClosed, "the first message must be auth")
        XCTAssertEqual(silent.messages().count, 0, "and nothing is said, not even hello")

        let wrong = ApiTestClient(hub: api.hub, origin: .lan)
        wrong.send("auth", ["token": .string("not-the-token")])
        api.tick()
        XCTAssertTrue(wrong.connection.isClosed)
        XCTAssertEqual(wrong.messages().count, 0)

        let right = ApiTestClient(hub: api.hub, origin: .lan)
        let id = right.send("auth", ["token": .string(ApiFixture.token)])
        api.tick()
        let reply = try XCTUnwrap(right.answer(to: id))
        XCTAssertEqual(reply["result"], .string("ok"))
        XCTAssertEqual(reply["api"], .number(1), "the envelope carries api 1 in the auth reply")
        XCTAssertFalse(right.connection.isClosed)

        // Until the token is read there is nothing to compare with: nobody gets in.
        api.hub.setToken(nil)
        let early = ApiTestClient(hub: api.hub, origin: .lan)
        early.send("auth", ["token": .string(ApiFixture.token)])
        api.tick()
        XCTAssertTrue(early.connection.isClosed)
    }

    func test_aCommandBeforeAuthClosesTheSocketAndNeverRuns() throws {
        let api = try ApiFixture()
        api.hub.setToken(ApiFixture.token)
        let client = ApiTestClient(hub: api.hub, origin: .lan)
        let before = api.entries.count
        client.send("command", ["command": try api.command("stack 1 blackout on")])
        api.tick(2)
        XCTAssertTrue(client.connection.isClosed)
        XCTAssertEqual(api.entries.count, before, "nothing ran")
        XCTAssertNotEqual(api.engine.state.stacks[1]?.blackout, true)
    }

    func test_tokensAreComparedWhole() {
        XCTAssertTrue(ApiHub.same("abc123", "abc123"))
        XCTAssertFalse(ApiHub.same("abc123", "abc124"))
        XCTAssertFalse(ApiHub.same("abc123", "abc12"))
        XCTAssertFalse(ApiHub.same("", "abc123"))
        XCTAssertTrue(ApiHub.same("", ""))
    }

    // MARK: - the local socket

    func test_theLocalSocketTakesNoTokenAndRefusesWhatComesLater() throws {
        let api = try ApiFixture()
        let client = api.local()
        XCTAssertEqual(client.messages().first?["type"], .string("hello"), "no auth: the first message is hello")
        let auth = client.send("auth", ["token": .string("anything")])
        let later = ["passcode", "unlock", "resetPasscode", "token", "newToken"].map { ($0, client.send($0)) }
        let unknown = client.send("frobnicate")
        api.tick()
        XCTAssertTrue(reason(client.answer(to: auth)).hasPrefix("badValue: "))
        for (type, id) in later {
            XCTAssertTrue(reason(client.answer(to: id)).hasPrefix("notInV1: "), "\(type) is Area 18's: \(reason(client.answer(to: id)))")
        }
        XCTAssertTrue(reason(client.answer(to: unknown)).hasPrefix("badValue: "))
        XCTAssertFalse(client.connection.isClosed)
    }

    /// Spec 9 §2 — "the engine stamps `ts`, `seq` and the client's source".
    func test_aNoteIsWrittenWithTheSourceTheAppNames() throws {
        let api = try ApiFixture()
        let client = api.local()
        let browse = client.send("note", ["note": .object(["event": .string("browse"), "list": .number(42)]), "text": .string("Browsed Great Is Thy Faithfulness")])
        let key = client.send("note", ["note": .object(["event": .string("backToLive")]), "text": .string("Back to live"), "source": .string("key")])
        let bad = client.send("note", ["text": .string("no note")])
        api.tick()
        let answer = try XCTUnwrap(client.answer(to: browse))
        XCTAssertEqual(answer["result"], .string("ok"))
        api.engine.settleLogs()
        let written = try XCTUnwrap(api.disk.notes("browse").last)
        XCTAssertEqual(answer["seq"]?.intValue, written.seq, "answered ok with the seq")
        XCTAssertEqual(written.source.kind, .ui)
        XCTAssertEqual(api.disk.notes("backToLive").last?.source.kind, .key)
        XCTAssertEqual(client.answer(to: key)?["result"], .string("ok"))
        XCTAssertTrue(reason(client.answer(to: bad)).hasPrefix("badValue: "))
    }

    // MARK: - stop

    /// Spec 10 §3 — `stop`: "Stops the engine on request (Spec 9 §4)",
    /// answered "`ok` with `unsaved`, the documents it couldn't write (Spec 9
    /// §7), before it exits".
    func test_stopRunsTheShutdownMacroWritesLastJsonCleanAndAnswersBeforeTheExit() throws {
        let api = try ApiFixture(configure: { $0.settings.shutdownMacro = 2 })
        let client = api.local()
        try api.engine.send("stack 1 blackout on", source: .ui).map { throw $0 }
        api.tick()
        let exited = expectation(description: "the process would exit now")
        let answeredFirst = LockedFlag()
        api.hub.afterStop = {
            // What the process does last: by now the answer has been written to the client.
            answeredFirst.set(client.transport.lines.contains { String(decoding: $0, as: UTF8.self).contains("\"unsaved\"") })
            exited.fulfill()
        }
        let id = client.send("stop")
        api.tick()
        wait(for: [exited], timeout: 10)
        XCTAssertTrue(answeredFirst.value, "answered before it exits")
        let answer = try XCTUnwrap(client.answer(to: id))
        XCTAssertEqual(answer["type"], .string("result"))
        XCTAssertEqual(answer["result"], .string("ok"))
        XCTAssertEqual(answer["unsaved"], .array([]), "everything was written")

        api.engine.settleLogs()
        XCTAssertTrue(api.entries.contains { $0.source.kind == .shutdown }, "the shutdown macro ran")
        XCTAssertEqual(api.disk.notes("stop").count, 1)
        let written = try Data(contentsOf: api.disk.machineRoot.appendingPathComponent("state/last.json"))
        XCTAssertEqual(try JSONValue.parse(written).objectValue?["clean"], .bool(true))
    }

    func test_stopNamesTheDocumentsItCouldNotWrite() throws {
        let api = try ApiFixture()
        let client = api.local()
        api.disk.fillDisk()
        try api.engine.send("edit playlist create \"Easter\"", source: .ui).map { throw $0 }
        api.tick()
        let exited = expectation(description: "stopped")
        api.hub.afterStop = { exited.fulfill() }
        let id = client.send("stop")
        api.tick()
        wait(for: [exited], timeout: 10)
        let unsaved = try XCTUnwrap(client.answer(to: id)?["unsaved"]?.arrayValue?.compactMap(\.stringValue))
        XCTAssertFalse(unsaved.isEmpty, "the documents it couldn't write, each by its root and path")
        XCTAssertTrue(unsaved.allSatisfy { $0.hasPrefix("machine/") || $0.hasPrefix("library/") }, "\(unsaved)")
    }

    // MARK: - releaseScreen

    /// Spec 10 §9 — "the engine closes those outputs' windows, reports them
    /// `released` (§3) and logs a `screenReleased` note". The windows are the
    /// process's; here it is stood in for, and the request, its answer and
    /// its note are the engine's.
    func test_releaseScreenAnswersWithTheOutputsAndWritesItsNote() throws {
        let api = try ApiFixture()
        let client = api.local()
        let asked = LockedList()
        api.hub.releaseScreen = { uuid, done in
            asked.append(uuid)
            DispatchQueue.global().async { done([2, 3]) }
        }
        let id = client.send("releaseScreen", ["screen": .string("display:37d8832a-2d66-02ca-b9f7-8f30a301b230"), "source": .string("key")])
        let ping = client.send("ping")
        api.tick()
        let messages = client.next(wait: 5).filter { $0["type"] != .string("hello") }
        // Its place was kept: it is answered before the ping that followed it, though its work finished later.
        let deadline = Date(timeIntervalSinceNow: 5)
        var answer = client.answer(to: id)
        while answer == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            answer = client.answer(to: id)
        }
        XCTAssertEqual(answer?["result"], .string("ok"))
        XCTAssertEqual(answer?["outputs"], .array([.number(2), .number(3)]), "the outputs released")
        XCTAssertEqual(asked.values, ["37D8832A-2D66-02CA-B9F7-8F30A301B230"])
        let all = client.messages().filter { $0["type"] != .string("hello") }
        XCTAssertEqual(all.map { $0["id"] }, [.number(Double(id)), .number(Double(ping))], "in the order asked: \(messages.shape)")

        api.engine.settleLogs()
        let note = try XCTUnwrap(api.disk.notes("screenReleased").last)
        XCTAssertEqual(note.source.kind, .key, "with the requester's source")
        XCTAssertEqual(note.note["screen"], .string("display:37D8832A-2D66-02CA-B9F7-8F30A301B230"))
        XCTAssertEqual(note.note["outputs"], .array([.number(2), .number(3)]))

        let bad = client.send("releaseScreen", ["screen": .string("the big one")])
        api.tick()
        XCTAssertTrue(reason(client.answer(to: bad)).hasPrefix("badValue: "))
    }
}

/// A flag two threads share in a test.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// A list two threads share in a test.
final class LockedList: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
