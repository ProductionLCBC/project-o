import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §2 — "the engine's first message is `hello`, naming its version,
/// the API version, its process id, the machine, the run and the Mach
/// service". Spec 2 §9 and Spec 10 §3 — the result that answers a command,
/// the answer to a query, the events. Each read from the line as the spec
/// prints it.
final class WireTests: XCTestCase {
    private func read(_ line: String) -> Incoming {
        Incoming.read(Data(line.utf8))
    }

    func test_helloIsReadAsTheSpecShowsIt() {
        let message = read(#"{ "type": "hello", "api": 1, "engine": "0.4.0", "pid": 4182, "machine": "7a7a", "run": "51e2", "mach": "org.lcbc.projecto.engine.51e2" }"#)
        XCTAssertEqual(message, .hello(Hello(api: 1, engine: "0.4.0", pid: 4182, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2")))
    }

    func test_anEngineOfAnotherApiCannotBeDriven() {
        XCTAssertTrue(Hello(api: 1, engine: "0.9.0", pid: 1, machine: "", run: "", mach: "").isDrivable, "versions may differ while api matches")
        XCTAssertFalse(Hello(api: 2, engine: "0.1.0", pid: 1, machine: "", run: "", mach: "").isDrivable)
    }

    func test_aPlainResultCarriesItsKindAndSeq() {
        guard case .reply(let id, .result(let outcome)) = read(#"{ "id": 17, "type": "result", "result": "ok", "seq": 4822 }"#) else { return XCTFail() }
        XCTAssertEqual(id, 17)
        XCTAssertEqual(outcome, CommandOutcome(kind: .ok, seq: 4822))
        XCTAssertTrue(outcome.succeeded)
    }

    func test_anAppliedEditsResultCarriesItsGroupAndWhatWasAppliedWithTheInverses() {
        let line = #"{ "id": 52, "type": "result", "result": "ok", "seq": 5120, "group": "g-1c2d3e4f", "applied": [ { "command": { "cmd": "edit.create", "object": "list", "list": 57 }, "inverse": { "cmd": "edit.delete", "object": "list", "list": 57 } } ] }"#
        guard case .reply(52, .result(let outcome)) = read(line) else { return XCTFail() }
        XCTAssertEqual(outcome.group, "g-1c2d3e4f")
        XCTAssertEqual(outcome.applied.count, 1)
        XCTAssertEqual(outcome.applied.first?.command.objectValue?["list"], .number(57), "the number the engine picked is in what it applied")
        XCTAssertEqual(outcome.applied.first?.inverse?.objectValue?["cmd"], .string("edit.delete"))
    }

    func test_aRejectionIsSplitIntoItsCodeAndTheEnginesSentence() {
        guard case .reply(53, .result(let outcome)) = read(#"{ "id": 53, "type": "result", "result": "rejected", "reason": "badPasscode: the passcode is wrong" }"#) else { return XCTFail() }
        XCTAssertEqual(outcome.kind, .rejected)
        XCTAssertEqual(outcome.rejection, EngineRejection(code: "badPasscode", message: "the passcode is wrong"))
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(EngineRejection(reason: "onAir: channel 2 is on air: clear it first").reason, .onAir)
        XCTAssertNil(EngineRejection(reason: "somethingNew: later").reason, "a code this build doesn't know is kept as text")
        XCTAssertEqual(EngineRejection(reason: "notInV1"), EngineRejection(code: "notInV1", message: ""))
    }

    func test_theOtherThingsAResultCanCarry() {
        guard case .reply(_, .result(let job)) = read(#"{ "id": 1, "type": "result", "result": "ok", "seq": 9, "job": "j-3c1d9a20", "warnings": ["a list is still linked"] }"#) else { return XCTFail() }
        XCTAssertEqual(job.job, "j-3c1d9a20")
        XCTAssertEqual(job.warnings, ["a list is still linked"])
        guard case .reply(_, .result(let stop)) = read(#"{ "id": 2, "type": "result", "result": "ok", "unsaved": ["lists/042.json"] }"#) else { return XCTFail() }
        XCTAssertEqual(stop.unsaved, ["lists/042.json"])
        guard case .reply(_, .result(let released)) = read(#"{ "id": 3, "type": "result", "result": "ok", "outputs": [2, 3] }"#) else { return XCTFail() }
        XCTAssertEqual(released.outputs, [2, 3])
        guard case .reply(_, .result(let many)) = read(#"{ "id": 4, "type": "result", "result": "ok", "seq": 12, "results": [ { "result": "ok", "seq": 11 }, { "result": "noop", "seq": 12 } ] }"#) else { return XCTFail() }
        XCTAssertEqual(many.each, [.init(kind: .ok, seq: 11), .init(kind: .noop, seq: 12)])
        guard case .reply(_, .result(let snapshot)) = read(#"{ "id": 5, "type": "result", "result": "ok", "seq": 13, "snapshot": "2026-11-08-085959" }"#) else { return XCTFail() }
        XCTAssertEqual(snapshot.snapshot, "2026-11-08-085959")
    }

    func test_anAnswerAPongAndAnEventAreToldApart() {
        guard case .reply(63, .answer(let fields)) = read(#"{ "id": 63, "type": "answer", "cues": 12, "macros": 1, "presets": 0, "keys": 2 }"#) else { return XCTFail() }
        XCTAssertEqual(fields["cues"], .number(12))
        XCTAssertEqual(read(#"{ "id": 7, "type": "pong" }"#), .reply(id: 7, .pong))
        guard case .event(let topic, let event) = read(#"{ "type": "event", "topic": "channels", "channel": 2, "state": "empty", "content": null, "seq": 4822 }"#) else { return XCTFail() }
        XCTAssertEqual(topic, "channels")
        XCTAssertEqual(event["channel"], .number(2))
    }

    func test_whatItCannotReadIsKeptAsUnknownAndNeverTraps() {
        for line in ["", "not json", "[1, 2]", #"{ "type": "result", "result": "ok" }"#, #"{ "id": 1, "type": "result" }"#,
                     #"{ "type": "event" }"#, #"{ "type": "hello" }"#, #"{ "type": "somethingNew", "id": 1 }"#, #"{ "id": "x", "type": "pong" }"#] {
            guard case .unknown = read(line) else { return XCTFail("\(line) should be unknown") }
        }
    }

    func test_aRequestIsOneLineWithItsIdTypeAndFields() throws {
        let line = EngineRequest.command(.next, source: .key).line(id: 41)
        let sent = try XCTUnwrap(JSONValue.parse(line).objectValue)
        XCTAssertEqual(sent["id"], .number(41))
        XCTAssertEqual(sent["type"], .string("command"))
        XCTAssertEqual(sent["source"], .string("key"))
        XCTAssertEqual(sent["command"], .object(["cmd": .string("playlist.next")]), "Spec 10 §2's example, as it is printed there")
        XCTAssertFalse(line.contains(0x0A), "one line: the transport adds the newline")
    }

    func test_aGroupNamesItsCommandsInOrderAndThatTheyAreOne() throws {
        let request = EngineRequest.group([.channelClear(channel: .number(2)), .channelClear(channel: .number(5))], source: .ui)
        XCTAssertEqual(request.type, "commands")
        XCTAssertEqual(request.fields["group"], .bool(true))
        XCTAssertEqual(request.fields["source"], .string("ui"))
        let commands = try XCTUnwrap(request.fields["commands"]?.arrayValue)
        XCTAssertEqual(commands.map { $0.objectValue?["channel"] }, [.number(2), .number(5)])
    }

    func test_theOtherRequests() {
        XCTAssertEqual(EngineRequest.subscribe(["live", "channels"]).fields["topics"], .array([.string("live"), .string("channels")]))
        XCTAssertEqual(EngineRequest.query("list", ["listUuid": .string("a9f0")]).fields, ["what": .string("list"), "listUuid": .string("a9f0")])
        let note = EngineRequest.note(["event": .string("browse"), "list": .number(42)], text: "Browsed Great Is Thy Faithfulness")
        XCTAssertEqual(note.fields["note"], .object(["event": .string("browse"), "list": .number(42)]))
        XCTAssertEqual(note.fields["text"], .string("Browsed Great Is Thy Faithfulness"))
        XCTAssertEqual(EngineRequest.ping.type, "ping")
        XCTAssertEqual(EngineRequest.stop.type, "stop")
        XCTAssertEqual(EngineRequest.releaseScreen("display:37D8832A").fields, ["screen": .string("display:37D8832A")])
    }
}
