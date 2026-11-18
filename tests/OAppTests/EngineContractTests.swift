import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §3 — "What the app reads and sends". The app's own client against
/// the real API hub on the headless engine (no GPU, no engine process), over
/// a real local socket: every query the app asks and every topic it uses,
/// recorded in `tests/fixtures/api-v1/` and compared with the record on every
/// run. So when the engine's answers move, this fails here, and the scripted
/// engine, which plays the recorded answers back, can't drift from the engine
/// (Spec 10 §16: "so no test needs the engine or a GPU").
///
/// Record again with `O_RECORD_API=1 swift test --filter EngineContractTests`.
final class EngineContractTests: XCTestCase {
    private var engine: RealEngine!
    private var client: LinkedClient!

    override func setUpWithError() throws {
        engine = try RealEngine()
        client = try LinkedClient(socket: engine.socketURL)
    }

    override func tearDown() {
        client.link.close()
        engine.stop()
    }

    @discardableResult
    private func run(_ text: String, source: AppSource = .ui, file: StaticString = #filePath, line: UInt = #line) throws -> CommandOutcome {
        let command = try parse(text)
        let outcome = try XCTUnwrap(client.ask(.command(command, source: source)).outcome, file: file, line: line)
        XCTAssertTrue(outcome.succeeded, "\(text): \(outcome.kind.rawValue) \(outcome.rejection?.message ?? "")", file: file, line: line)
        return outcome
    }

    private func parse(_ text: String) throws -> Command {
        let library = engine.headless.engine.library, machine = engine.headless.engine.machine
        let ids = MediaResolver.knownIds(library: library.mediaIndex, machine: machine.mediaLocal)
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: ids, library: library, machine: machine)) {
        case .success(let guarded): return guarded.command
        case .failure(let rejection): throw rejection
        }
    }

    private func answer(_ what: String, _ fields: [String: JSONValue] = [:], file: StaticString = #filePath, line: UInt = #line) throws -> [String: JSONValue] {
        let reply = try client.ask(.query(what, fields))
        return try XCTUnwrap(reply.answer, "\(what) was refused: \(reply.outcome?.rejection?.message ?? "")", file: file, line: line)
    }

    /// The topics the app uses (Spec 10 §3's table), with `commands`, which
    /// gives a live change its source (Area 13 reading of §15).
    static let topics = ["live", "channels", "outputs", "audio", "popups", "timers", "library", "media", "history", "saving",
                         "thumbnails", "engine", "devices", "commands"]

    func test_helloNamesTheEngineAndItsMachService() throws {
        let hello = try XCTUnwrap(client.waitForHello())
        XCTAssertEqual(hello.api, Hello.api)
        XCTAssertTrue(hello.isDrivable)
        XCTAssertEqual(hello.engine, OCore.appVersion, "an app and an engine from one commit name one version")
        XCTAssertEqual(hello.pid, getpid(), "the hub runs in this process")
        XCTAssertEqual(hello.machine, engine.machineUUID.uuidString.lowercased())
        XCTAssertEqual(hello.run, engine.run.uuidString.lowercased())
        XCTAssertEqual(hello.mach, "org.lcbc.projecto.engine." + hello.run)
    }

    func test_theQueriesAnswerAsRecorded() throws {
        XCTAssertEqual(try client.ask(.subscribe(Self.topics)).outcome?.kind, .ok)
        // A stage with something on it, so the answers hold every kind of value: a playlist live on a cue, media
        // and text on channels, a popup, a timer running, a stack blacked out, an audio output muted.
        try run(#"playlist "Sunday""#)
        try run("item 2 cue 1")
        try run(#"popup 1 set "Nursery 14" clearafter 30"#)
        try run("timer 1 set 5:00")
        try run("stack 2 blackout on")
        try run("audio 1 mute on")

        try RecordedAPI.check("state", try answer("state"))
        try RecordedAPI.check("catalog", try answer("catalog"))
        try RecordedAPI.check("media", try answer("media"))
        try RecordedAPI.check("list-42", try answer("list", ["list": .number(42)]))
        try RecordedAPI.check("list-7", try answer("list", ["list": .number(7)]))
        let catalog = try answer("catalog")
        let local = try XCTUnwrap(catalog["lists"]?.arrayValue?.first { $0.objectValue?["local"] == .bool(true) }?.objectValue?["uuid"])
        try RecordedAPI.check("list-local", try answer("list", ["local": local]))
        let media = try answer("media")
        let first = try XCTUnwrap(media["media"]?.arrayValue?.first?.objectValue?["id"])
        try RecordedAPI.check("mediaUse", try answer("mediaUse", ["media": first]))
        try RecordedAPI.check("listUse-42", try answer("listUse", ["list": .number(42)]))
        try RecordedAPI.check("versions-42", try answer("versions", ["list": .number(42)]))
        try RecordedAPI.check("snapshots", try answer("snapshots"))
        try RecordedAPI.check("thumbnails-42", try answer("thumbnails", ["list": .number(42)]))
    }

    func test_theTopicsSendAsRecorded() throws {
        XCTAssertEqual(try client.ask(.subscribe(Self.topics)).outcome?.kind, .ok)
        var events: [String: JSONValue] = [:]
        func keep(_ name: String, _ topic: String, file: StaticString = #filePath, line: UInt = #line, where matches: @escaping ([String: JSONValue]) -> Bool = { _ in true }) throws {
            events[name] = .object(try XCTUnwrap(client.event(topic, where: matches), "no \(topic) event for \(name)", file: file, line: line))
        }
        // "On subscribe": the topics that keep a current value send it at once.
        try keep("history.empty", "history")
        try keep("saving", "saving")
        try keep("engine", "engine") { $0["run"] != nil }

        try run(#"playlist "Sunday""#)
        try keep("live.loaded", "live") { $0["playlist"] != .null && $0["cue"] == .null }
        try run("item 2 cue 1")
        try keep("live.fired", "live") { $0["cue"] != .null }
        try keep("channels.text", "channels") { $0["content"]?.objectValue?["kind"] == .string("text") }
        try keep("channels.media", "channels") { $0["content"]?.objectValue?["kind"] == .string("media") }
        try keep("commands.navigation", "commands") { $0["command"]?.objectValue?["cmd"] == .string("playlist.goto") }
        try run("item 2 cue 3")
        try keep("live.armed", "live") { $0["armed"] != .null && $0["armed"] != nil }
        try run("disarm")
        try run("channel 2 clear")
        try keep("channels.empty", "channels") { $0["channel"] == .number(2) && $0["content"] == .null }
        try run("channel 1 lock")
        try keep("channels.locked", "channels") { $0["channel"] == .number(1) && $0["lock"] == .bool(true) }

        try run(#"popup 1 set "Nursery 14" clearafter 30"#)
        try keep("popups.set", "popups") { $0["text"] == .string("Nursery 14") }
        try run("popup 1 clear")
        try keep("popups.cleared", "popups") { $0["popup"] == .number(1) && $0["text"] == .string("") }

        try run("timer 1 set 5:00")
        try keep("timers.set", "timers") { $0["timer"] == .number(1) && $0["state"] == .string("stopped") }
        try run("timer 2 set 0:30 up")
        try keep("timers.up", "timers") { $0["timer"] == .number(2) && $0["direction"] == .string("up") }

        try run("stack 2 blackout on")
        try keep("outputs.stack", "outputs") { $0["stack"] == .number(2) && $0["blackout"] == .bool(true) }
        try run("stack 1 mute 2 on")
        try keep("outputs.muted", "outputs") { $0["stack"] == .number(1) && $0["muted"] == .array([.number(2)]) }
        try run("output 1 stack 2")
        try keep("outputs.output", "outputs") { $0["output"] == .number(1) && $0["stack"] == .number(2) }
        try run("audio 1 mute on")
        try keep("audio.muted", "audio") { $0["muted"] == .bool(true) }

        let edit = try run(#"edit list 42 title "Great Is Thy Faithfulness (Runyan)""#)
        XCTAssertNotNil(edit.group, "an applied edit's result carries its group")
        XCTAssertEqual(edit.applied.count, 1)
        XCTAssertEqual(edit.applied.first?.inverse?.objectValue?["value"], .string("Great Is Thy Faithfulness"), "and its inverse, to revert exactly what was sent")
        try keep("library.edit", "library") { $0["cause"] == .string("edit") }
        try keep("history.undo", "history") { $0["undo"] != .null && $0["undo"] != nil }
        try run("undo")
        try keep("library.undo", "library") { $0["cause"] == .string("undo") }
        try keep("history.redo", "history") { $0["redo"] != .null && $0["redo"] != nil }

        try RecordedAPI.check("events", events)
    }

    func test_aRefusedCommandAndARefusedQueryComeBackAsRejectedResults() throws {
        let rejected = try XCTUnwrap(client.ask(.command(.cue(99), source: .ui)).outcome)
        XCTAssertEqual(rejected.kind, .rejected)
        XCTAssertNotNil(rejected.rejection?.reason, "a code OCore knows: \(rejected.rejection?.code ?? "")")
        let query = try XCTUnwrap(client.ask(.query("list", ["list": .number(999)])).outcome)
        XCTAssertEqual(query.rejection?.reason, .unknownObject)
        let later = try XCTUnwrap(client.ask(EngineRequest(type: "unlock", fields: ["passcode": .string("1234")])).outcome)
        XCTAssertEqual(later.rejection?.reason, .notInV1, "the lock's requests are Area 18's")
        let noop = try XCTUnwrap(client.ask(.command(.next, source: .key)).outcome)
        XCTAssertEqual(noop.kind, .noop, "Spec 10 §7: with nothing live, next does nothing")
    }

    func test_theRequestsOfSpec10Section3() throws {
        XCTAssertEqual(try client.ask(.ping), .pong)
        let note = try XCTUnwrap(client.ask(.note(["event": .string("appStarted"), "app": .string(OCore.appVersion), "launched": .bool(false)],
                                                  text: "Project O connected")).outcome)
        XCTAssertEqual(note.kind, .ok)
        XCTAssertNotNil(note.seq, "a note is a line of the command log")
        let group = try XCTUnwrap(client.ask(.group([.playlistLoad(title: "Sunday"), .itemCue(item: 2, cue: 1)], source: .ui)).outcome)
        XCTAssertEqual(group.kind, .ok, "Spec 10 §6: a playlist that isn't loaded is loaded and fired as one group")
        XCTAssertEqual(group.each.count, 2)
        let state = try XCTUnwrap(client.ask(.query("state")).answer)
        XCTAssertNotEqual(state["state"]?.objectValue?["pointer"]?.objectValue?["cueUuid"] ?? .null, .null, "the group's cue is live")
    }
}
