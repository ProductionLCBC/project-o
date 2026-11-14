import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §2 — notes. "A client sends `{ "id": 31, "type": "note", "note":
/// { … }, "text": "…" }`; the engine stamps `ts`, `seq` and the client's
/// source, writes the line, and answers `ok` with the `seq` ... A note
/// changes nothing and is never undone ... `text` holds at most 1,000
/// characters and `note` at most 4 KB, or the note is refused with
/// `badValue`. One client's notes are capped at ten a second (choice G-9)".
/// Spec 9 §10, Notes. Until the API exists (Area 19) the request goes through
/// the engine's own publisher (Spec 2 §9).
final class NoteTests: XCTestCase {
    var disk: DiskFixture!

    override func setUpWithError() throws {
        disk = try DiskFixture(launch: true)
    }

    func request(_ id: Int, note: [String: JSONValue] = ["event": .string("browse"), "list": .number(42)],
                 text: String = "Browsed Great Is Thy Faithfulness", source: SourceKind = .ui, client: String = "app") -> [String: JSONValue] {
        let request: JSONValue = .object(["id": .number(Double(id)), "type": .string("note"), "note": .object(note), "text": .string(text)])
        return disk.engine.engine.publisher.request(request, source: CommandSource(kind: source), client: client).objectValue ?? [:]
    }

    /// Spec 9 §10 — "A client's note is written with the engine's `ts`, `seq`
    /// and the client's source and no group, command, undo or result,
    /// answered `ok` with its `seq`, and changes nothing".
    func test_aClientsNoteIsStampedWrittenAndAnsweredWithItsSeq() throws {
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()
        let state = disk.engine.state
        let revision = disk.control.revision

        let answer = request(31)
        XCTAssertEqual(answer, ["id": .number(31), "type": .string("result"), "result": .string("ok"), "seq": .number(3)])

        let line = try XCTUnwrap(disk.commandLog().last?.note)
        XCTAssertEqual(line.seq, 3)
        XCTAssertEqual(line.ts, "2026-10-30T10:00:00.000-04:00", "the engine's stamp, in the machine's zone")
        XCTAssertEqual(line.source, CommandSource(kind: .ui))
        XCTAssertEqual(line.note, ["event": .string("browse"), "list": .number(42)])
        XCTAssertEqual(line.text, "Browsed Great Is Thy Faithfulness")
        XCTAssertNil(line.dropped)
        let written = try XCTUnwrap(disk.commandLogText().split(separator: "\n").last.map(String.init))
        for absent in ["\"group\"", "\"command\"", "\"undo\"", "\"result\""] { XCTAssertFalse(written.contains(absent), absent) }

        // It changes nothing.
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state, state)
        XCTAssertEqual(disk.control.revision, revision)
        XCTAssertTrue(disk.events.all.isEmpty)
        XCTAssertEqual(disk.control.commandLog.lastSeq, 3)
    }

    /// The source is the client's: a LAN client's notes are `api` (Spec 10 §2).
    func test_aNoteCarriesItsClientsSource() throws {
        XCTAssertEqual(request(1, source: .api, client: "remote 10.20.0.31")["result"], .string("ok"))
        XCTAssertEqual(disk.commandLog().last?.note?.source, CommandSource(kind: .api))
    }

    /// Spec 9 §10 — "an oversized one is `badValue`".
    func test_anOversizedNoteIsRefusedWithBadValueAndNotWritten() throws {
        let before = disk.control.commandLog.lastSeq
        let long = request(7, text: String(repeating: "a", count: 1001))
        XCTAssertEqual(long["id"], .number(7))
        XCTAssertEqual(long["result"], .string("rejected"))
        XCTAssertEqual(long["reason"]?.stringValue?.hasPrefix("badValue: "), true)
        let big = request(8, note: ["event": .string("browse"), "pad": .string(String(repeating: "x", count: 4096))])
        XCTAssertEqual(big["reason"]?.stringValue?.hasPrefix("badValue: "), true)
        // A request that isn't a note's shape is refused the same way.
        let shapeless = disk.engine.engine.publisher.request(.object(["id": .number(9), "type": .string("note"), "text": .string("no note")]),
                                                             source: CommandSource(kind: .ui), client: "app").objectValue ?? [:]
        XCTAssertEqual(shapeless["reason"]?.stringValue?.hasPrefix("badValue: "), true)
        XCTAssertEqual(disk.control.commandLog.lastSeq, before, "no seq is spent on a refused note")
        XCTAssertEqual(disk.commandLog().count, 1, "only the start note")
    }

    /// Spec 9 §10 — "the eleventh in a second is answered `noop` and not
    /// written, and the next one written carries `dropped: 1`."
    func test_theEleventhNoteInASecondIsNoopAndTheNextWrittenCarriesDropped() throws {
        for k in 1...10 { XCTAssertEqual(request(k)["result"], .string("ok"), "note \(k)") }
        let eleventh = request(11)
        XCTAssertEqual(eleventh, ["id": .number(11), "type": .string("result"), "result": .string("noop")])
        XCTAssertEqual(disk.commandLog().count, 11, "the start note and ten")
        // Another client has its own ten.
        XCTAssertEqual(request(12, client: "tablet")["result"], .string("ok"))

        // A second of engine time later the cap has passed (the harness's 61st tick ends a hair short of one).
        disk.engine.tick(count: 62)
        XCTAssertEqual(request(13)["result"], .string("ok"))
        let last = try XCTUnwrap(disk.commandLog().last?.note)
        XCTAssertEqual(last.dropped, 1)
        XCTAssertEqual(request(14)["result"], .string("ok"))
        XCTAssertNil(disk.commandLog().last?.note?.dropped)
    }

    /// Spec 9 §2 — the engine's own notes "have source `engine` (Spec 2 §5)".
    /// `conflict`: "When a file arriving on disk loses to unwritten edits
    /// (Spec 5 §10)", with `document` and `kept`, "where the arriving file was kept".
    func test_aLostArrivalIsNotedWithWhereItWasKept() throws {
        disk.send("edit list 7 title \"A\"")
        disk.settle()
        disk.send("edit list 7 title \"B\"")
        disk.engine.tick()
        let arriving = try disk.edited(.library, "lists/007-a.json", "author", .string("Someone Else"))
        try disk.write(.library, "lists/007-a.json", arriving)
        disk.engine.scanDisk()
        disk.engine.waitForWrites()
        disk.engine.tick()

        let notes = disk.commandLog().compactMap(\.note).filter { $0.event == "conflict" }
        XCTAssertEqual(notes.count, 1)
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.source, CommandSource(kind: .engine))
        // Both named from their roots, as a snapshot names its documents (Spec 9 §3).
        XCTAssertEqual(note.note["document"], .string("library/lists/007-a.json"))
        XCTAssertEqual(note.note["kept"], .string("machine/conflicts/2026-10-30-100000-007-a.json"))
        XCTAssertTrue(disk.exists(.machine, "conflicts/2026-10-30-100000-007-a.json"))
    }

    /// A note written before the launch, when no file is open yet, still has
    /// its place in the run's log: a harness without files keeps it in memory.
    func test_withoutFilesNotesStayInTheEnginesMemory() throws {
        let engine = try HeadlessEngine(library: try EngineFixtures.library(), machine: try EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        let request: JSONValue = .object(["id": .number(1), "type": .string("note"), "note": .object(["event": .string("backToLive")]),
                                          "text": .string("Back to live")])
        let answer = engine.engine.publisher.request(request, source: CommandSource(kind: .ui), client: "app").objectValue ?? [:]
        XCTAssertEqual(answer["seq"], .number(1))
        XCTAssertEqual(engine.control.commandLog.lines.compactMap(\.note).map(\.event), ["backToLive"])
        XCTAssertTrue(engine.control.commandLog.entries.isEmpty, "a note is not a command's entry")
    }
}
