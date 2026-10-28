import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — Log: "Every executed command produces one line with the
/// fields in section 9; the first command of a cue group carries `fire`."
/// Spec 2 §9 — "One JSON line per executed command".
final class LogEntryTests: XCTestCase {
    typealias F = FixtureLibrary

    static let listUuid = F.listUuid(42)
    static let cueUuid = F.list42Cues[0]
    static let playlistUuid = F.playlistUuid

    /// Spec 2 §9's example entry, with the fixture's identities.
    var example: LogEntry {
        LogEntry(ts: "2026-11-01T09:14:03.117-05:00", seq: 4821, group: GroupID("g-7f1a"),
                 source: CommandSource(kind: .cue, list: Self.listUuid, cue: Self.cueUuid, playlist: Self.playlistUuid),
                 kind: .runtime, undo: .runtime, result: .ok,
                 command: .channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: F.mountains)))),
                 text: "channel 1 write media \(F.mountains)",
                 snapshot: "s-4821",
                 fire: FireRecord(listTitle: "Great Is Thy Faithfulness", ccli: "18723"))
    }

    var exampleLine: String {
        "{ \"command\": { \"channel\": 1, \"cmd\": \"channel.write\", \"content\": { \"kind\": \"media\", \"ref\": \"\(F.mountains)\" } }, "
        + "\"fire\": { \"ccli\": \"18723\", \"listTitle\": \"Great Is Thy Faithfulness\" }, "
        + "\"group\": \"g-7f1a\", \"kind\": \"runtime\", \"result\": \"ok\", \"seq\": 4821, \"snapshot\": \"s-4821\", "
        + "\"source\": { \"cue\": \"\(Self.cueUuid.uuidString.lowercased())\", \"kind\": \"cue\", "
        + "\"list\": \"\(Self.listUuid.uuidString.lowercased())\", \"playlist\": \"\(Self.playlistUuid.uuidString.lowercased())\" }, "
        + "\"text\": \"channel 1 write media \(F.mountains)\", \"ts\": \"2026-11-01T09:14:03.117-05:00\", \"undo\": \"runtime\" }"
    }

    func test_theSpecExampleIsOneLineWithSortedKeys() throws {
        XCTAssertEqual(example.line, exampleLine)
        XCTAssertFalse(example.line.contains("\n"))
        XCTAssertEqual(try LogEntry(line: exampleLine), example)
        XCTAssertEqual(try LogEntry(line: example.line), example)
    }

    func test_absentFieldsAreOmittedAndUnknownKeysSurvive() throws {
        var entry = example
        entry.snapshot = nil
        entry.fire = nil
        XCTAssertFalse(entry.line.contains("snapshot"))
        XCTAssertFalse(entry.line.contains("fire"))
        XCTAssertEqual(try LogEntry(line: entry.line), entry)

        let withExtra = try LogEntry(line: exampleLine.replacingOccurrences(of: "\"undo\": \"runtime\" }", with: "\"undo\": \"runtime\", \"zz\": 1 }"))
        XCTAssertEqual(withExtra.extra, ["zz": .number(1)])
        XCTAssertEqual(withExtra.line, exampleLine.replacingOccurrences(of: "\"undo\": \"runtime\" }", with: "\"undo\": \"runtime\", \"zz\": 1 }"))

        // An edit entry carries its inverse; a rejected result its reason.
        var edit = example
        edit.command = .edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Lyrics")))
        edit.text = "edit channel 2 label \"Lyrics\""
        edit.kind = .edit
        edit.undo = .edit
        edit.inverse = .edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Words")))
        XCTAssertTrue(edit.line.contains("\"inverse\": { \"cmd\": \"edit\""), edit.line)
        XCTAssertEqual(try LogEntry(line: edit.line), edit)

        var rejected = example
        rejected.result = .rejected(Rejection(reason: .noSuchTarget, message: "channel 9 does not exist"))
        XCTAssertTrue(rejected.line.contains("\"reason\": \"noSuchTarget: channel 9 does not exist\""), rejected.line)
        XCTAssertTrue(rejected.line.contains("\"result\": \"rejected\""), rejected.line)
        XCTAssertEqual(try LogEntry(line: rejected.line), rejected)
    }

    func test_badLinesAreErrors() {
        XCTAssertThrowsError(try LogEntry(line: "not json"))
        XCTAssertThrowsError(try LogEntry(line: "{ \"seq\": 1 }"))
        XCTAssertThrowsError(try LogEntry(line: "[]"))
    }

    /// Spec 2 §9 — the entries of a run: one per executed command, `seq`
    /// counting up, `kind` and `undo` from the vocabulary row.
    func test_entriesForARun() throws {
        typealias X = Fixtures
        var loaded = X.fresh()
        loaded.pointer = LivePointer(playlist: X.playlistUuid)
        let group = CommandGroup(id: GroupID("g-1"), source: CommandSource(kind: .key), commands: [
            .channelLock(channel: .number(3), locked: true), .next, .timerStart(timer: 1), .macro(2),
        ])
        var counter = 1
        let outcome = try CommandRunner.run(group, state: loaded, context: X.context(frame: 100), makeGroupID: {
            counter += 1
            return GroupID("g-\(counter)")
        }).get()
        let entries = LogEntry.entries(for: outcome, firstSeq: 4821, ts: "2026-11-01T09:14:03.117-05:00")
        XCTAssertEqual(entries.map(\.seq), Array(4821..<(4821 + entries.count)))
        XCTAssertEqual(entries.map(\.text), [
            "channel 3 lock", "next", "channel 1 write media A", "channel 2 write text \"verse 1\"", "timer 1 start",
            "macro 2", "channel 2 write text \"from macro\"",
        ])
        XCTAssertEqual(entries.map(\.undo), [.none, .runtime, .runtime, .runtime, .none, .none, .runtime])
        XCTAssertTrue(entries.allSatisfy { $0.kind == .runtime && $0.ts == "2026-11-01T09:14:03.117-05:00" && $0.snapshot == nil })
        XCTAssertEqual(entries.map(\.result), [.ok, .ok, .ok, .ok, .ok, .ok, .ok])
        XCTAssertEqual(entries.map(\.group.rawValue), ["g-1", "g-1", "g-2", "g-2", "g-1", "g-1", "g-1"])
        XCTAssertEqual(entries.map(\.fire), [nil, nil, FireRecord(listTitle: "Hymn one", ccli: ""), nil, nil, nil, nil])
        XCTAssertEqual(entries[2].source, CommandSource(kind: .cue, list: X.listUuid(1), cue: X.cueUuid(list: 1, cue: 1), playlist: X.playlistUuid))
        XCTAssertEqual(entries[6].source, CommandSource(kind: .macro, macro: 2))
        for entry in entries {
            XCTAssertEqual(try LogEntry(line: entry.line), entry, entry.text)
            XCTAssertEqual(entry.command, try CommandText.parse(entry.text).get().command, entry.text)
        }
    }

    /// Spec 2 §3 — the Lock and Undo columns, as properties of a command.
    func test_lockAndUndoClassesFollowTheVocabularyTable() {
        let write = Command.channelWrite(ChannelWrite(channel: .number(1), content: .empty))
        XCTAssertEqual(write.lockClass, .blocked)
        XCTAssertEqual(Command.channelClear(channel: .number(1)).lockClass, .blocked)
        XCTAssertEqual(Command.channelTransition(channel: .number(1), ref: 1, ms: nil).lockClass, .blocked)
        XCTAssertEqual(Command.channelAudioTransition(channel: .number(1), ref: 1, ms: nil).lockClass, .blocked)
        XCTAssertEqual(Command.channelGrade(channel: .number(1), ref: 1, ms: nil).lockClass, .blocked)
        XCTAssertEqual(Command.channelGain(channel: .number(1), db: 0).lockClass, .blocked)
        for passing: Command in [.channelReset(channel: .number(1)), .channelTransport(channel: .number(1), mode: .play),
                                 .channelLock(channel: .number(1), locked: true), .outputStack(output: 1, stack: 1),
                                 .next, .macro(1), .systemClearAll, .timerSet(timer: 1, ms: 0), .undo] {
            XCTAssertEqual(passing.lockClass, .passes, "\(passing)")
        }
        for runtime: Command in [write, .channelClear(channel: .number(1)), .channelReset(channel: .number(1)),
                                 .channelGrade(channel: .number(1), ref: 1, ms: nil), .channelTransport(channel: .number(1), mode: .play),
                                 .channelEndBehavior(channel: .number(1), mode: .hold), .channelFreeze(channel: .number(1), state: .on),
                                 .channelTrack(channel: .number(1), direction: .skip), .channelBuild(channel: .number(1), build: 1),
                                 .outputStack(output: 1, stack: 1), .stackBlackout(stack: 1, state: .on), .stackMute(stack: 1, channel: 1, state: .on),
                                 .next, .previous, .cue(1), .itemCue(item: 1, cue: 1), .itemSection(item: 1, section: "a"),
                                 .listCue(list: 1, cue: 1), .popupSet(popup: 1, text: "", clearAfterMs: nil), .popupClear(popup: 1),
                                 .audioMute(audio: .all, state: .on), .systemClearAll] {
            XCTAssertEqual(runtime.undoClass, .runtime, "\(runtime)")
        }
        for none: Command in [.channelLock(channel: .number(1), locked: true), .playlistLoad(title: "", date: nil),
                              .timerSet(timer: 1, ms: 0), .timerStart(timer: 1), .timerPause(timer: 1), .timerReset(timer: 1),
                              .macro(1), .undo, .redo, .historyJump(1), .systemPreflight, .systemSnapshot, .unknown(cmd: "x")] {
            XCTAssertEqual(none.undoClass, .none, "\(none)")
        }
        let edit = Command.edit(EditCommand(target: "channel", number: 1, field: "label"))
        XCTAssertEqual(edit.undoClass, .edit)
        XCTAssertEqual(edit.logKind, .edit)
        XCTAssertEqual(write.logKind, .runtime)
    }

    /// Spec 1 §9 — UUIDs are written lowercase; absent fields are omitted.
    func test_sourceEncodesLowercaseUuidsAndOmitsAbsentFields() throws {
        let source = CommandSource(kind: .cue, list: Self.listUuid, cue: Self.cueUuid, playlist: Self.playlistUuid)
        XCTAssertEqual(try JSONCoding.encode(source), .object([
            "kind": .string("cue"), "list": .string(Self.listUuid.uuidString.lowercased()),
            "cue": .string(Self.cueUuid.uuidString.lowercased()), "playlist": .string(Self.playlistUuid.uuidString.lowercased()),
        ]))
        XCTAssertEqual(try JSONCoding.encode(CommandSource(kind: .macro, macro: 2)), .object(["kind": .string("macro"), "macro": .number(2)]))
        XCTAssertEqual(try JSONCoding.encode(CommandSource(kind: .ui)), .object(["kind": .string("ui")]))
        XCTAssertEqual(try JSONCoding.decode(CommandSource.self, from: .object(["kind": .string("macro"), "macro": .number(2)])),
                       CommandSource(kind: .macro, macro: 2))
        XCTAssertEqual(try JSONCoding.decode(CommandSource.self, from: try JSONCoding.encode(source)), source)
    }

    func test_oneLineJSON() {
        let value: JSONValue = .object(["b": .array([.number(1), .object(["x": .null])]), "a": .string("s\"q"), "c": .object([:]), "d": .array([])])
        XCTAssertEqual(JSONCanonical.line(value), "{ \"a\": \"s\\\"q\", \"b\": [1, { \"x\": null }], \"c\": {}, \"d\": [] }")
        XCTAssertEqual(JSONCanonical.line(.array([.number(1.5), .bool(true)])), "[1.5, true]")
    }
}
