import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §2 — the command log on disk: "`machine/logs/commands-YYYY-MM-DD.jsonl`
/// | Every executed command, and the notes below | By the machine's local day".
/// "The control thread hands each applied group's lines to a utility thread,
/// which appends them in order ... A group's lines go out in one write ending
/// in a newline, and each file is synced once a second. When the engine opens
/// a file whose last byte isn't a newline, as a crash or a power cut can leave
/// it, it ends that line first. Readers skip a line that doesn't parse".
/// Spec 9 §10, The logs and Captions.
final class CommandLogFileTests: XCTestCase {
    typealias E = EngineFixtures

    var disk: DiskFixture!

    override func setUpWithError() throws {
        disk = try DiskFixture(launch: true)
    }

    var memory: [LogLine] { disk.control.commandLog.lines }

    static func date(_ iso: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try XCTUnwrap(formatter.date(from: iso), iso)
    }

    // MARK: - Every executed command is one line

    /// Spec 9 §10 — "Every executed command is one line, in order, in the
    /// local day's command log, with Spec 2 §9's fields".
    func test_everyExecutedCommandIsOneLineInOrderInTheLocalDaysFile() throws {
        XCTAssertEqual(disk.day, "2026-10-30")
        disk.send("playlist \"Sunday\"", source: .ui)
        disk.engine.tick()
        disk.send("next", source: .key)
        disk.engine.tick()
        disk.send("edit list 42 title \"Faithfulness\"", source: .ui)
        disk.engine.tick()
        disk.send("timer 1 pause", source: .osc)
        disk.engine.tick()

        XCTAssertEqual(disk.logFiles.filter { $0.hasPrefix("commands-") }, ["commands-2026-10-30.jsonl"])
        let text = disk.commandLogText()
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.contains("\n\n"), "one line each, none empty")
        let lines = disk.commandLog()
        XCTAssertEqual(lines.count, text.split(separator: "\n").count, "every line reads back")
        XCTAssertEqual(lines, memory, "the file holds what the engine logged, in order")
        XCTAssertEqual(lines.map(\.seq), Array(1...lines.count))

        let entries = lines.compactMap(\.entry)
        XCTAssertEqual(entries.count, 6, "the load, the navigation, the cue's two writes, the edit and the timer command")
        guard entries.count == 6 else { return }
        XCTAssertEqual(Array(entries.map(\.text).prefix(2)), ["playlist \"Sunday\"", "next"])
        XCTAssertTrue(entries[2].text.hasPrefix("channel 1 write media \(E.dawn)"), entries[2].text)
        XCTAssertTrue(entries[3].text.hasPrefix("channel 2 write text"), entries[3].text)
        XCTAssertEqual(Array(entries.map(\.text).suffix(2)), ["edit list 42 title \"Faithfulness\"", "timer 1 pause"])
        XCTAssertEqual(entries.map(\.source.kind), [.ui, .key, .cue, .cue, .ui, .osc])
        XCTAssertEqual(entries.map(\.kind), [.runtime, .runtime, .runtime, .runtime, .edit, .runtime])
        XCTAssertEqual(entries.map(\.result), [.ok, .ok, .ok, .ok, .ok, .noop])
        // Spec 2 §9 — the first command of a cue group carries `fire`; an edit carries its inverse.
        XCTAssertEqual(entries[2].fire?.listTitle, "Great Is Thy Faithfulness")
        XCTAssertNil(entries[3].fire)
        XCTAssertEqual(entries[2].group, entries[3].group)
        XCTAssertNotEqual(entries[1].group, entries[2].group, "the navigation line, then the cue's own group")
        XCTAssertNotNil(entries[4].inverse)
        XCTAssertEqual(entries[4].undo, .edit)
        for entry in entries {
            XCTAssertTrue(entry.ts.hasPrefix("2026-10-30T10:00:00.000-04:00"), entry.ts)
            XCTAssertTrue(entry.group.rawValue.hasPrefix("g-"))
        }
    }

    /// Spec 9 §2 — "A group's lines go out in one write ending in a newline".
    func test_aGroupsLinesGoOutInOneWrite() throws {
        disk.send("playlist \"Sunday\"", source: .ui)
        disk.engine.tick()
        disk.engine.settleLogs()
        disk.disk.clear()

        disk.send("next", source: .key)
        disk.engine.tick()
        disk.engine.settleLogs()
        var writes = disk.disk.writes(to: "commands-2026-10-30.jsonl")
        XCTAssertEqual(writes.count, 1, "the navigation and its cue's lines, one write")
        XCTAssertEqual(writes.first?.text.split(separator: "\n").count, 3)
        XCTAssertEqual(writes.first?.text.hasSuffix("\n"), true)

        disk.disk.clear()
        disk.engine.send(group: ["channel 2 clear", "timer 1 set 5:00", "timer 1 start"], source: .osc)
        disk.engine.tick()
        disk.engine.settleLogs()
        writes = disk.disk.writes(to: "commands-2026-10-30.jsonl")
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(LogLine.reading(writes.first?.text ?? "").compactMap(\.entry).map(\.text),
                       ["channel 2 clear", "timer 1 set 5:00", "timer 1 start"])

        // A tick that runs nothing writes nothing.
        disk.disk.clear()
        disk.engine.tick(count: 5)
        disk.engine.settleLogs()
        XCTAssertEqual(disk.disk.writes(to: "commands-2026-10-30.jsonl").count, 0)
    }

    /// Spec 9 §10 — "Rejections aren't written; blocked, noop and steppedOn
    /// results are." Spec 9 §2 — "Not in it: rejected commands, which are
    /// answered at the API and the command bar only (Spec 2 §9)".
    func test_rejectionsAreNotWrittenButBlockedNoopAndSteppedOnAre() throws {
        // Rejected: no such channel.
        disk.send("channel 99 clear", source: .osc)
        disk.engine.tick()
        XCTAssertEqual(disk.control.rejections.count, 1)
        // Blocked: a cue's write to a locked channel (Spec 2 §8).
        disk.send("channel 2 lock", source: .ui)
        disk.send("playlist \"Sunday\"", source: .ui)
        disk.send("next", source: .key)
        disk.engine.tick()
        // Noop: a timer that isn't set.
        disk.send("timer 1 pause", source: .osc)
        disk.engine.tick()
        // SteppedOn: a third write while two decoders dissolve (Spec 3 §4).
        disk.send("channel 1 write media \(E.cross) transition 2 1.0 once", source: .osc)
        disk.engine.tick()
        disk.send("channel 1 write media \(E.dawn) transition 2 1.0 once", source: .osc)
        disk.engine.tick()

        let entries = disk.commandLog().compactMap(\.entry)
        XCTAssertEqual(entries.count, disk.control.commandLog.entries.count)
        XCTAssertFalse(entries.contains { $0.text == "channel 99 clear" })
        XCTAssertFalse(disk.commandLogText().contains("rejected"))
        XCTAssertEqual(entries.first { $0.text.hasPrefix("channel 2 write text") }?.result, .blocked)
        XCTAssertEqual(entries.first { $0.text == "timer 1 pause" }?.result, .noop)
        XCTAssertEqual(entries.last?.result, .steppedOn)
        XCTAssertTrue(disk.commandLogText().contains("\"result\": \"steppedOn\""))
    }

    // MARK: - Runs

    /// Spec 9 §2 — "`seq` counts from 1 at each launch. The engine's `start`
    /// note opens each run with the run's uuid, so a run and a `seq` name one
    /// line, whichever day's file it is in." Spec 9 §10 — "A run opens with
    /// `start`, `seq` counts from 1, and a clean stop ends with `stop`."
    func test_aRunOpensWithStartCountsFromOneAndACleanStopEndsWithStop() throws {
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()
        disk.engine.stop()

        let first = disk.commandLog()
        XCTAssertEqual(first.map(\.seq), [1, 2, 3])
        let start = try XCTUnwrap(first.first?.note)
        XCTAssertEqual(start.event, "start")
        XCTAssertEqual(start.source, CommandSource(kind: .engine))
        XCTAssertEqual(start.note["run"], .string(disk.engine.engine.run.uuidString.lowercased()))
        XCTAssertEqual(start.note["app"], .string(OCore.appVersion))
        XCTAssertEqual(start.note["machine"], .string("7a7a0000-0000-4000-8000-000000000001"))
        XCTAssertNotNil(start.note["previous"])
        XCTAssertFalse(start.text.isEmpty)
        let stop = try XCTUnwrap(first.last?.note)
        XCTAssertEqual(stop.event, "stop")
        XCTAssertEqual(stop.note["unsaved"], .array([]), "everything was written")
        XCTAssertEqual(stop.source, CommandSource(kind: .engine))

        // The next run on the same roots, the same day: its part of the file opens with its own start, at 1.
        let firstRun = disk.engine.engine.run
        let next = try DiskFixture(continuing: disk)
        next.send("channel 2 clear", source: .osc)
        next.engine.tick()
        let lines = next.commandLog()
        XCTAssertEqual(lines.map(\.seq), [1, 2, 3, 1, 2])
        XCTAssertEqual(lines[3].note?.event, "start")
        XCTAssertNotEqual(next.engine.engine.run, firstRun)
        XCTAssertEqual(lines[3].note?.note["run"], .string(next.engine.engine.run.uuidString.lowercased()))
    }

    // MARK: - Days

    /// Spec 9 §10 — "A line at 23:59:59.900 local and the next at
    /// 00:00:00.100 land in two files." Spec 9 §2, choice G-8 — "The machine's
    /// local day, so a Sunday's services are in Sunday's file".
    func test_linesEitherSideOfLocalMidnightLandInTwoFiles() throws {
        disk = try DiskFixture(wallClock: try Self.date("2026-11-08T23:59:50.000-05:00"), launch: true)
        disk.clock.now = try Self.date("2026-11-08T23:59:59.900-05:00")
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()
        disk.clock.now = try Self.date("2026-11-09T00:00:00.100-05:00")
        disk.send("channel 1 clear", source: .osc)
        disk.engine.tick()

        XCTAssertEqual(disk.logFiles.filter { $0.hasPrefix("commands-") }, ["commands-2026-11-08.jsonl", "commands-2026-11-09.jsonl"])
        let sunday = disk.commandLog(day: "2026-11-08")
        let monday = disk.commandLog(day: "2026-11-09")
        XCTAssertEqual(sunday.map(\.seq), [1, 2])
        XCTAssertEqual(sunday.last?.entry?.text, "channel 2 clear")
        XCTAssertEqual(sunday.last?.ts, "2026-11-08T23:59:59.900-05:00", "already the 9th in UTC")
        XCTAssertEqual(monday.map(\.seq), [3], "seq runs on across the day")
        XCTAssertEqual(monday.first?.entry?.text, "channel 1 clear")
        XCTAssertEqual(monday.first?.ts, "2026-11-09T00:00:00.100-05:00")
    }

    // MARK: - A file a crash left

    /// Spec 9 §10 — "A file left with a partial last line is ended before the
    /// next run writes, and the reader skips the fragment."
    func test_aPartialLastLineIsEndedBeforeTheNextRunWrites() throws {
        let whole = LogNote(ts: "2026-10-30T09:00:00.000-04:00", seq: 9, source: CommandSource(kind: .engine),
                            note: ["event": .string("start")], text: "Engine started").line
        let fragment = "{ \"kind\": \"runtime\", \"seq\": 10, \"text\": \"channel 1 wri"
        disk = try DiskFixture(prepare: { folder in
            let logs = folder.appendingPathComponent("machine/logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data((whole + "\n" + fragment).utf8).write(to: logs.appendingPathComponent("commands-2026-10-30.jsonl"))
        }, launch: true)
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()

        let text = disk.commandLogText()
        XCTAssertTrue(text.hasPrefix(whole + "\n" + fragment + "\n"), "the fragment is ended, nothing before it is touched")
        let lines = disk.commandLog()
        XCTAssertEqual(lines.map(\.seq), [9, 1, 2], "the fragment is skipped")
        XCTAssertEqual(lines[1].note?.event, "start")
        XCTAssertEqual(lines[2].entry?.text, "channel 2 clear")
    }

    /// A file that ends cleanly gets no stray newline.
    func test_aFileThatEndsWithANewlineIsAppendedToAsItIs() throws {
        disk.send("channel 2 clear", source: .osc)
        disk.engine.tick()
        let before = disk.commandLogText()
        let next = try DiskFixture(continuing: disk)
        XCTAssertTrue(next.commandLogText().hasPrefix(before))
        XCTAssertFalse(next.commandLogText().contains("\n\n"))
    }

    // MARK: - Synced each second

    /// Spec 9 §2 — "each file is synced once a second ... so a crash loses at
    /// most the last second." On engine time: at most one sync of a file in a
    /// second, and none of a file nothing was written to.
    func test_eachFileIsSyncedOnceASecondWhileItIsWrittenTo() throws {
        disk.engine.settleLogs()
        disk.disk.clear()
        let name = "commands-2026-10-30.jsonl"
        for k in 0..<150 {
            disk.send("popup 1 set \"line \(k)\"", source: .osc)
            disk.engine.tick()
        }
        disk.engine.settleLogs()
        XCTAssertEqual(disk.disk.syncs(of: name), 2, "two and a half seconds of lines, two syncs")
        disk.engine.tick(count: 120)
        disk.engine.settleLogs()
        XCTAssertEqual(disk.disk.syncs(of: name), 3, "the last half second's lines, then nothing more to sync")
        disk.engine.tick(count: 120)
        disk.engine.settleLogs()
        XCTAssertEqual(disk.disk.syncs(of: name), 3)
    }

    // MARK: - Captions

    /// Spec 9 §2 — "Captions. Spec 6 §7 leaves to this spec whether a
    /// captioning feed's popup lines are kept in full. They are". Spec 9 §10 —
    /// "A feed of three popup sets a second for an hour writes every line."
    func test_aCaptionFeedOfThreeSetsASecondForAnHourWritesEveryLine() throws {
        let start = try Self.date("2026-11-08T09:00:00.000-05:00")
        disk = try DiskFixture(wallClock: start, launch: true)
        let sets = 3 * 60 * 60
        for k in 0..<sets {
            disk.clock.now = start.addingTimeInterval(Double(k) / 3)
            disk.send("popup 1 set \"caption \(k)\"", source: .osc)
            disk.engine.tick()
        }
        XCTAssertEqual(disk.logFiles.filter { $0.hasPrefix("commands-") }, ["commands-2026-11-08.jsonl"])
        let entries = disk.commandLog().compactMap(\.entry)
        XCTAssertEqual(entries.count, sets, "more lines than the engine keeps in memory, and every one is in the file")
        XCTAssertGreaterThan(sets, CommandLog.defaultCapacity)
        XCTAssertEqual(entries.first?.text, "popup 1 set \"caption 0\"")
        XCTAssertEqual(entries.last?.text, "popup 1 set \"caption \(sets - 1)\"")
        XCTAssertEqual(entries.map(\.seq), Array(2...(sets + 1)), "in order, none missing")
        XCTAssertTrue(entries.allSatisfy { $0.result == .ok })
    }
}
