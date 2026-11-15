import Foundation
import XCTest
@testable import OCore

/// Spec 9 §7 — "Retention (G3)": which snapshots and which log files are
/// kept. Spec 9 §10, Retention: "Given snapshots over 400 days, exactly §7's
/// set survives, plus any an undo or redo step still names; logs past their
/// age or size go oldest first and today's never goes". The rules as plain
/// functions of names, sizes and today's date.
final class RetentionTests: XCTestCase {
    /// A Sunday, so the weeks in the table below end the day before a Monday.
    let today = "2026-11-08"
    var now: Int { CivilTime.days(today) ?? 0 }

    func id(daysAgo: Int, _ time: String) -> String {
        CivilTime.text(days: now - daysAgo) + "-" + time
    }

    // MARK: - Snapshots

    /// Two a day for 400 days: the morning's and the evening's.
    func test_overFourHundredDaysExactlyTheSetOfSection7Survives() {
        var ids: [String] = []
        for age in 0..<400 {
            ids.append(id(daysAgo: age, "090000"))
            ids.append(id(daysAgo: age, "180000"))
        }
        let removed = Set(Retention.snapshotsToRemove(ids, today: today))
        let survivors = Set(ids).subtracting(removed)

        var expected: Set<String> = []
        // "Every one for 7 days".
        for age in 0...7 {
            expected.insert(id(daysAgo: age, "090000"))
            expected.insert(id(daysAgo: age, "180000"))
        }
        // "then the newest of each day until 30 days old".
        for age in 8...30 { expected.insert(id(daysAgo: age, "180000")) }
        // "then the newest of each week, Monday to Sunday, until a year old": of the days in that span, the last of each week.
        var newestOfWeek: [Int: Int] = [:]
        for age in 31...365 {
            let week = CivilTime.weekStart(days: now - age)
            newestOfWeek[week] = min(newestOfWeek[week] ?? age, age)
        }
        for age in newestOfWeek.values { expected.insert(id(daysAgo: age, "180000")) }
        // "none older."
        XCTAssertEqual(survivors, expected)
        XCTAssertEqual(survivors.count, 16 + 23 + newestOfWeek.count)
        XCTAssertEqual(newestOfWeek.count, 49, "from Thursday 2026-10-08 back to Saturday 2025-11-08: 49 weeks, the first and last of them part weeks")
        XCTAssertTrue(removed.allSatisfy { $0 < self.id(daysAgo: 7, "000000") })
        XCTAssertFalse(survivors.contains { (Retention.day(ofSnapshot: $0) ?? 0) < now - 365 }, "none older than a year")
    }

    /// Weeks run Monday to Sunday: of a whole week a month back, the Sunday's snapshot is the one kept.
    func test_theNewestOfAWeekIsItsLastDaysNewest() {
        // 2026-09-14 is a Monday; 2026-09-20 the Sunday that ends its week.
        let week = (14...20).flatMap { ["2026-09-\($0)-090000", "2026-09-\($0)-180000"] }
        let next = ["2026-09-21-090000"]      // the Monday after: another week
        let removed = Retention.snapshotsToRemove(week + next, today: today)
        XCTAssertEqual(Set(week + next).subtracting(removed), ["2026-09-20-180000", "2026-09-21-090000"])
        XCTAssertEqual(removed, removed.sorted(), "oldest first")
    }

    /// Two in one second: `-2` is the newer.
    func test_theSecondOfASecondIsTheNewerOne() {
        let ids = [id(daysAgo: 10, "090000"), id(daysAgo: 10, "090000-2"), id(daysAgo: 10, "090000-10")]
        XCTAssertEqual(Set(ids).subtracting(Retention.snapshotsToRemove(ids, today: today)), [id(daysAgo: 10, "090000-10")])
    }

    /// "A snapshot an undo or redo step names is kept until the run ends".
    func test_aSnapshotAStepNamesIsKept() {
        let ids = [id(daysAgo: 10, "090000"), id(daysAgo: 10, "180000"), id(daysAgo: 400, "090000")]
        XCTAssertEqual(Retention.snapshotsToRemove(ids, today: today), [ids[2], ids[0]])
        XCTAssertEqual(Retention.snapshotsToRemove(ids, today: today, named: [ids[0], ids[2]]), [])
        // A named one doesn't take the day's place from the newest.
        XCTAssertEqual(Retention.snapshotsToRemove(ids, today: today, named: [ids[0]]), [ids[2]])
    }

    /// A file the engine didn't name is never touched; nor is one dated after today, and with no date for
    /// today nothing is removed at all.
    func test_whatIsNotASnapshotIdOrIsDatedAheadIsLeft() {
        let ids = ["notes", "2026-13-45-090000", "2026-11-08", id(daysAgo: -3, "090000"), id(daysAgo: 500, "090000")]
        XCTAssertEqual(Retention.snapshotsToRemove(ids, today: today), [id(daysAgo: 500, "090000")])
        XCTAssertEqual(Retention.snapshotsToRemove(ids, today: "today"), [])
        XCTAssertNil(Retention.day(ofSnapshot: "2026-11-08-0859"))
        XCTAssertNil(Retention.day(ofSnapshot: "2026-11-08-085959-x"))
        XCTAssertEqual(Retention.day(ofSnapshot: "2026-11-08-085959-2"), now)
    }

    // MARK: - Logs

    func log(_ daysAgo: Int, _ megabytes: Int64, prefix: String = "commands-") -> (name: String, bytes: Int64) {
        (prefix + CivilTime.text(days: now - daysAgo) + ".jsonl", megabytes << 20)
    }

    /// "90 days ...; past either, the oldest go first."
    func test_logsOlderThanNinetyDaysGo() {
        let files = [log(0, 4), log(1, 4), log(90, 4), log(91, 4), log(200, 4)]
        XCTAssertEqual(Retention.logsToRemove(files, prefix: "commands-", today: today, bytes: Retention.commandLogBytes),
                       [log(200, 4).name, log(91, 4).name])
    }

    /// "2 GB in all; past either, the oldest go first. Today's file is never removed".
    func test_logsPastTheirSizeGoOldestFirstAndTodaysNeverGoes() {
        let files = [log(0, 900), log(1, 600), log(2, 600), log(3, 600), log(4, 600)]
        // 3,300 MB against 2,048: the two oldest go, leaving 2,100; then the next, leaving 1,500.
        XCTAssertEqual(Retention.logsToRemove(files, prefix: "commands-", today: today, bytes: Retention.commandLogBytes),
                       [log(4, 600).name, log(3, 600).name, log(2, 600).name])
        // Today's alone is over the cap: it stays.
        XCTAssertEqual(Retention.logsToRemove([log(0, 3000), log(1, 10)], prefix: "commands-", today: today, bytes: Retention.commandLogBytes),
                       [log(1, 10).name])
        XCTAssertEqual(Retention.commandLogBytes, 2 * 1024 * 1024 * 1024)
        XCTAssertEqual(Retention.engineLogBytes, 1024 * 1024 * 1024, "Engine logs: 90 days and 1 GB in all, the same way")
    }

    /// Each log is counted on its own, and a file the engine didn't name is neither counted nor removed.
    func test_onlyTheLogsOwnFilesAreCountedAndRemoved() {
        let files = [log(0, 10), log(120, 10), log(120, 10, prefix: "engine-"), ("engine-console.log", Int64(5) << 30),
                     ("commands-notes.jsonl", Int64(5) << 30)]
        XCTAssertEqual(Retention.logsToRemove(files, prefix: "commands-", today: today, bytes: Retention.commandLogBytes), [log(120, 10).name])
        XCTAssertEqual(Retention.logsToRemove(files, prefix: "engine-", today: today, bytes: Retention.engineLogBytes),
                       [log(120, 10, prefix: "engine-").name])
    }
}
