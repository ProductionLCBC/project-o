import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §7 — retention in the engine: "The retention pass runs at launch,
/// after each snapshot, and when a day's or an hour's file starts." Spec 9
/// §10, Retention: "Given snapshots over 400 days, exactly §7's set survives,
/// plus any an undo or redo step still names; logs past their age or size go
/// oldest first and today's never goes; the black box stays within its cap
/// through a day of running; versions and conflicts are untouched." The rule
/// itself is `RetentionTests`; these prove the passes run when they should
/// and remove only what the rule names. On temporary copies of the fixture.
final class RetentionEngineTests: XCTestCase {
    static let start = Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-30T10:00:00-04:00, a Friday
    static let launch = "2026-10-30-100000"

    func plant(_ folder: URL, _ path: String, _ bytes: String = "x") throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
    }

    @discardableResult
    func run(_ disk: DiskFixture, _ text: String) -> Rejection? {
        let before = disk.control.rejections.count
        disk.send(text)
        disk.settleSaving()
        return disk.control.rejections.count > before ? disk.control.rejections.last : nil
    }

    // MARK: - Snapshots

    /// "The retention pass runs at launch" (Spec 9 §4, step 6): what §7 no longer keeps goes, oldest first.
    func test_atLaunchTheSnapshotsTheRuleNoLongerKeepsAreRemoved() throws {
        let planted = [
            "2026-10-27-090000", "2026-10-27-180000",                           // 3 days old: every one
            "2026-10-20-090000", "2026-10-20-180000",                           // 10 days: the newest of the day
            "2026-09-18-180000", "2026-09-19-180000", "2026-09-20-180000",      // 40 to 42 days, one week: its newest
            "2025-09-01-090000",                                                // over a year: none
        ]
        let disk = try DiskFixture(wallClock: Self.start, prepare: { folder in
            for id in planted { try self.plant(folder, "machine/snapshots/\(id).zip") }
            try self.plant(folder, "machine/snapshots/notes.txt")
            try self.plant(folder, "machine/snapshots/.2026-01-01-000000.zip.1a2b3c4d.tmp")
        }, launch: true)
        disk.settleSaving()

        XCTAssertEqual(disk.snapshotIDs, ["2026-09-20-180000", "2026-10-20-180000", "2026-10-27-090000", "2026-10-27-180000", Self.launch])
        XCTAssertTrue(disk.exists(.machine, "snapshots/notes.txt"), "a file the engine didn't name is never touched")
        XCTAssertTrue(disk.exists(.machine, "snapshots/.2026-01-01-000000.zip.1a2b3c4d.tmp"))
        XCTAssertTrue(disk.log.contains("retention: removed 4 snapshot(s)"))
    }

    /// "after each snapshot", and "A snapshot an undo or redo step names is kept until the run ends".
    func test_aSnapshotAStepNamesIsKeptUntilTheRunEnds() throws {
        let disk = try DiskFixture(wallClock: Self.start, launch: true)
        disk.settleSaving()
        disk.clock.now = Self.start.addingTimeInterval(60)
        XCTAssertNil(run(disk, "edit list 7 title \"Praise God\""))
        XCTAssertNil(run(disk, "system snapshot"))
        disk.clock.now = Self.start.addingTimeInterval(120)
        XCTAssertNil(run(disk, "system restore snapshot \"\(Self.launch)\""))
        disk.nextSecond()
        let command = "2026-10-30-100100"
        let before = "2026-10-30-100200"
        XCTAssertEqual(disk.snapshotIDs, [Self.launch, command, before])
        XCTAssertEqual(disk.control.history.snapshotIDs, [Self.launch, before])

        // Forty days on, another snapshot: the pass that follows it keeps the newest of that old week (the
        // one taken before the restore) and the one the step names, and removes the third.
        disk.clock.now = Self.start.addingTimeInterval(40 * 86_400)
        XCTAssertNil(run(disk, "system snapshot"))
        XCTAssertEqual(disk.snapshotIDs, [Self.launch, before, "2026-12-09-090000"])

        // "until the run ends": the next run's stack is empty, so its launch keeps only the week's newest.
        disk.engine.stop()
        let next = try DiskFixture(continuing: disk)
        next.settleSaving()
        XCTAssertEqual(next.snapshotIDs, [before, "2026-12-09-090000"])
    }

    // MARK: - Logs

    /// "Command logs | 90 days ...; past either, the oldest go first. Today's file is never removed", and
    /// the engine logs "the same way": at launch, when this run's day begins in each.
    func test_atLaunchLogsOlderThanNinetyDaysGoAndOtherFilesStay() throws {
        let disk = try DiskFixture(wallClock: Self.start, prepare: { folder in
            for name in ["commands-2026-07-01.jsonl", "commands-2026-08-01.jsonl", "commands-notes.jsonl", "engine-2026-07-01.jsonl",
                         "engine-2026-10-29.jsonl", "engine-console.log"] {
                try self.plant(folder, "machine/logs/\(name)", "{}\n")
            }
        }, launch: true)
        disk.send("channel 1 clear")
        disk.settle()
        XCTAssertEqual(disk.logFiles, ["commands-2026-08-01.jsonl", "commands-2026-10-30.jsonl", "commands-notes.jsonl",
                                       "engine-2026-10-29.jsonl", "engine-2026-10-30.jsonl", "engine-console.log"],
                       "121 days old went; 90 days old, today's, and the files the engine didn't name stayed")
    }

    /// "and when a day's ... file starts": a run that crosses into a new day checks again.
    func test_whenADaysFileStartsTheLogsAreCheckedAgain() throws {
        let disk = try DiskFixture(wallClock: Self.start, launch: true)
        disk.send("channel 1 clear")
        disk.settle()
        XCTAssertTrue(disk.logFiles.contains("commands-2026-10-30.jsonl"))

        disk.clock.now = Self.start.addingTimeInterval(95 * 86_400)
        disk.send("channel 2 clear")
        disk.engine.log.info("a line for the engine log's new day")
        disk.settle()
        XCTAssertEqual(disk.logFiles, ["commands-2027-02-02.jsonl", "engine-2027-02-02.jsonl"], "the day the run began is 95 days old now")
    }

    // MARK: - Versions and conflicts

    /// "Versions and conflicts | Kept; nothing removes them in v1".
    func test_versionsAndConflictsAreUntouched() throws {
        let versions = "library/versions/a9f00000-0000-4000-8000-00000000002a"
        let disk = try DiskFixture(wallClock: Self.start, prepare: { folder in
            try self.plant(folder, "\(versions)/v0001.json", "{}\n")
            try self.plant(folder, "machine/conflicts/2020-01-01-000000-007-doxology.json", "{}\n")
            try self.plant(folder, "machine/snapshots/2020-01-01-000000.zip")
        }, launch: true)
        disk.settleSaving()
        disk.clock.now = Self.start.addingTimeInterval(400 * 86_400)
        XCTAssertNil(run(disk, "system snapshot"))
        XCTAssertEqual(disk.snapshotIDs, ["2027-12-04-090000"], "every older snapshot went")
        XCTAssertTrue(disk.exists(.library, "versions/a9f00000-0000-4000-8000-00000000002a/v0001.json"))
        XCTAssertTrue(disk.exists(.library, "versions/a9f00000-0000-4000-8000-00000000002a/v0016.json"))
        XCTAssertTrue(disk.exists(.machine, "conflicts/2020-01-01-000000-007-doxology.json"))
    }

    // MARK: - The black box

    /// "The black box | 512 MB in all, oldest first; only the current hour's file is spared, so the cap
    /// holds within a day": "the black box stays within its cap through a day of running".
    func test_theBlackBoxStaysWithinItsCapThroughADayOfRunning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-box-day-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var record = TickRecord()
        let line = BlackBox.line(for: record).utf8.count
        // Room for three hours of twenty lines each.
        let cap = line * 60 + 20
        let box = BlackBox(folder: folder, maximumBytes: cap, disk: TestDisk().disk)
        let midnight = Date(timeIntervalSince1970: 1_793_491_200)   // an hour boundary in UTC
        for hour in 0..<24 {
            for k in 0..<20 {
                record.frame = Int64(hour * 20 + k)
                try box.append(record, at: midnight.addingTimeInterval(Double(hour) * 3600 + Double(k)))
                let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                let total = try names.reduce(0) { $0 + (try Data(contentsOf: folder.appendingPathComponent($1))).count }
                XCTAssertLessThanOrEqual(total, cap, "hour \(hour), line \(k)")
            }
        }
        // Only the last hours are left (later lines are a little longer, so two or three fit), the current one among them.
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertTrue((2...3).contains(left.count), "\(left)")
        XCTAssertTrue(left.last?.hasSuffix("-23.jsonl") ?? false, "\(left)")
    }
}
