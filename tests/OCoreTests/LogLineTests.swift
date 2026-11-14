import Foundation
import XCTest
@testable import OCore

/// Spec 9 §2 — "A note line carries `ts`, `seq`, `source`, `kind`, `note`
/// and `text`, and `dropped` when notes were dropped before it; it has no
/// `group`, `command`, `undo` or `result`". Spec 2 §9 as Spec 9 §9 corrected
/// it — "One JSON line per executed command or note", and "`kind` is
/// `runtime`, `edit` or `note`". Spec 9 §10, Notes.
final class LogLineTests: XCTestCase {
    /// Spec 9 §2's example note, as the page gives it.
    static let exampleLine = "{ \"kind\": \"note\", \"note\": { \"event\": \"browse\", \"list\": 42 }, \"seq\": 312, "
        + "\"source\": { \"kind\": \"ui\" }, \"text\": \"Browsed Great Is Thy Faithfulness\", \"ts\": \"2026-11-08T09:02:11.540-05:00\" }"

    var example: LogNote {
        LogNote(ts: "2026-11-08T09:02:11.540-05:00", seq: 312, source: CommandSource(kind: .ui),
                note: ["event": .string("browse"), "list": .number(42)], text: "Browsed Great Is Thy Faithfulness")
    }

    func test_theSpecExampleIsOneLineWithSortedKeysAndNoCommandFields() throws {
        XCTAssertEqual(example.line, Self.exampleLine)
        XCTAssertEqual(try LogNote(line: Self.exampleLine), example)
        for absent in ["group", "command", "undo", "result", "dropped"] {
            XCTAssertFalse(example.line.contains("\"\(absent)\""), absent)
        }
        XCTAssertEqual(example.event, "browse")
    }

    /// Spec 9 §2 — "the next note written carries `dropped` with the count".
    func test_droppedIsWrittenOnlyWhenNotesWereDropped() throws {
        var note = example
        note.dropped = 3
        XCTAssertTrue(note.line.contains("\"dropped\": 3"), note.line)
        XCTAssertEqual(try LogNote(line: note.line), note)
        note.dropped = nil
        XCTAssertFalse(note.line.contains("dropped"))
    }

    /// Spec 1 §8 — unknown keys survive a round trip.
    func test_unknownKeysSurvive() throws {
        let line = Self.exampleLine.replacingOccurrences(of: "\"ts\":", with: "\"toLater\": true, \"ts\":")
        let note = try LogNote(line: line)
        XCTAssertEqual(note.extra, ["toLater": .bool(true)])
        XCTAssertEqual(note.line, line)
    }

    /// Spec 2 §9 — one file holds both kinds; a reader takes each line by its `kind`.
    func test_aLineReadsAsAnEntryOrANoteByItsKind() throws {
        let entry = LogEntry(ts: "2026-11-08T09:02:12.000-05:00", seq: 313, group: GroupID("g-7f1a2b3c"),
                             source: CommandSource(kind: .osc), kind: .runtime, undo: .runtime, result: .ok,
                             command: .channelClear(channel: .number(2)), text: "channel 2 clear")
        XCTAssertEqual(try LogLine(line: entry.line), .entry(entry))
        XCTAssertEqual(try LogLine(line: Self.exampleLine), .note(example))
        XCTAssertEqual(LogLine.entry(entry).line, entry.line)
        XCTAssertEqual(LogLine.note(example).line, Self.exampleLine)
        XCTAssertEqual(LogLine.entry(entry).seq, 313)
        XCTAssertEqual(LogLine.note(example).seq, 312)
        XCTAssertEqual(LogLine.note(example).ts, "2026-11-08T09:02:11.540-05:00")
        XCTAssertEqual(try JSONCoding.encode(LogKind.note), .string("note"))
    }

    /// Spec 9 §2 — "By the machine's local day, in Spec 1 §3's `timeZone`":
    /// the stamp is written in that zone, so its date is the file's day.
    func test_aLinesDayIsTheDateOfItsStamp() {
        XCTAssertEqual(LogLine.note(example).day, "2026-11-08")
        var late = example
        late.ts = "2026-11-08T23:59:59.900-05:00"
        XCTAssertEqual(LogLine.note(late).day, "2026-11-08", "not the UTC day, which is already the 9th")
    }

    /// Spec 9 §2 — "Readers skip a line that doesn't parse, so a crash loses
    /// at most the last second."
    func test_aReaderSkipsWhatDoesNotParse() {
        let text = Self.exampleLine + "\n" + "{ \"kind\": \"note\", \"seq\": 31" + "\n" + "\n" + "not json\n"
            + Self.exampleLine.replacingOccurrences(of: "312", with: "313") + "\n"
        let lines = LogLine.reading(text)
        XCTAssertEqual(lines.map(\.seq), [312, 313])
        XCTAssertThrowsError(try LogLine(line: "{ \"kind\": \"mystery\", \"seq\": 1, \"ts\": \"x\" }"))
        XCTAssertThrowsError(try LogLine(line: "[]"))
    }

    // MARK: - The limits of a client's note

    /// Spec 9 §2 — "`text` holds at most 1,000 characters and `note` at most
    /// 4 KB, or the note is refused with `badValue`."
    func test_anOversizedNoteIsBadValue() {
        XCTAssertNil(LogNote.check(note: ["event": .string("browse")], text: String(repeating: "é", count: 1000)))
        XCTAssertEqual(LogNote.check(note: ["event": .string("browse")], text: String(repeating: "é", count: 1001))?.reason, .badValue)
        // 4 KB of the note's one-line JSON, in UTF-8.
        let overhead = JSONCanonical.line(.object(["pad": .string("")])).utf8.count
        let fits: [String: JSONValue] = ["pad": .string(String(repeating: "x", count: 4096 - overhead))]
        XCTAssertEqual(JSONCanonical.line(.object(fits)).utf8.count, 4096)
        XCTAssertNil(LogNote.check(note: fits, text: ""))
        let over: [String: JSONValue] = ["pad": .string(String(repeating: "x", count: 4097 - overhead))]
        XCTAssertEqual(LogNote.check(note: over, text: "")?.reason, .badValue)
    }

    // MARK: - The cap

    /// Spec 9 §2 — "One client's notes are capped at ten a second (choice
    /// G-9): beyond that a note is answered `noop` and not written, and the
    /// next note written carries `dropped` with the count." A sliding second
    /// of engine time, per client (the plan's reading).
    func test_theEleventhNoteInASecondIsRefusedAndTheNextWrittenCarriesTheCount() {
        var limiter = NoteLimiter()
        let second: Int64 = 1_000_000_000
        for k in 0..<10 {
            XCTAssertEqual(limiter.admit(client: "app", now: Int64(k) * 50_000_000), .written(dropped: 0), "note \(k + 1)")
        }
        XCTAssertEqual(limiter.admit(client: "app", now: 600_000_000), .refused, "the eleventh")
        // Another client has its own ten.
        XCTAssertEqual(limiter.admit(client: "remote", now: 600_000_000), .written(dropped: 0))
        // Still inside the second that began with the first note.
        XCTAssertEqual(limiter.admit(client: "app", now: second - 1), .refused)
        // The first note is now a second old: one slot is free, and the note written carries what was dropped.
        XCTAssertEqual(limiter.admit(client: "app", now: second), .written(dropped: 2))
        XCTAssertEqual(limiter.admit(client: "app", now: second + 50_000_000), .written(dropped: 0))
    }

    func test_tenASecondForeverNeverDrops() {
        var limiter = NoteLimiter()
        for k in 0..<1000 {
            XCTAssertEqual(limiter.admit(client: "app", now: Int64(k) * 100_000_000), .written(dropped: 0), "note \(k + 1)")
        }
    }
}
