import Foundation
import XCTest
@testable import OCore

/// The dates Spec 9 counts in (the two-hour limit of §4, the days and weeks
/// of §7), read back from what the engine printed, without a clock or a
/// calendar. Checked here against Foundation's own.
final class CivilTimeTests: XCTestCase {
    static let utc = TimeZone(identifier: "UTC")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }

    func test_dayNumbersAgreeWithTheCalendarAndRoundTrip() {
        let calendar = Self.calendar
        XCTAssertEqual(CivilTime.days(year: 1970, month: 1, day: 1), 0)
        XCTAssertEqual(CivilTime.days("1970-01-01"), 0)
        XCTAssertEqual(CivilTime.days("1969-12-31"), -1)
        // Every day from 1999 to 2031, leap days and the century's among them.
        let start = calendar.date(from: DateComponents(year: 1999, month: 1, day: 1))!
        for offset in 0..<(33 * 366) {
            let date = start.addingTimeInterval(Double(offset) * 86_400)
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let expected = Int((date.timeIntervalSince1970 / 86_400).rounded())
            let days = CivilTime.days(year: c.year!, month: c.month!, day: c.day!)
            XCTAssertEqual(days, expected)
            let back = CivilTime.date(days: days)
            XCTAssertEqual([back.year, back.month, back.day], [c.year!, c.month!, c.day!])
            // Foundation's weekday: Sunday 1 ... Saturday 7; ours: Monday 1 ... Sunday 7.
            XCTAssertEqual(CivilTime.weekday(days: days), c.weekday! == 1 ? 7 : c.weekday! - 1)
            XCTAssertEqual(CivilTime.days(CivilTime.text(days: days)), days)
        }
    }

    /// Spec 9 §7 — "the newest of each week, Monday to Sunday".
    func test_weeksRunMondayToSunday() throws {
        let sunday = try XCTUnwrap(CivilTime.days("2026-11-08"))
        XCTAssertEqual(CivilTime.weekday(days: sunday), 7)
        XCTAssertEqual(CivilTime.weekday(days: sunday + 1), 1)
        XCTAssertEqual(CivilTime.text(days: CivilTime.weekStart(days: sunday)), "2026-11-02")
        XCTAssertEqual(CivilTime.text(days: CivilTime.weekStart(days: sunday + 1)), "2026-11-09")
        XCTAssertEqual(CivilTime.text(days: CivilTime.weekStart(days: sunday - 6)), "2026-11-02")
        XCTAssertEqual(CivilTime.weekday(days: -1), 3, "1969-12-31 was a Wednesday")
    }

    func test_daysThatAreNotWrittenSoOrDoNotExistAreNil() {
        for bad in ["", "2026-11", "2026-11-8", "26-11-08", "2026-13-01", "2026-00-10", "2026-02-30", "2025-02-29", "2026-11-31",
                    "2026/11/08", "2026-11-08T00:00:00Z", "abcd-ef-gh", "2026-11--8"] {
            XCTAssertNil(CivilTime.days(bad), bad)
        }
        XCTAssertNotNil(CivilTime.days("2024-02-29"))
    }

    /// Spec 2 §9 — a stamp, "2026-11-01T09:14:03.117-05:00": the machine's
    /// local time with milliseconds and its offset.
    func test_stampsReadAsMillisecondsWhateverTheirOffset() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for stamp in ["2026-11-08T09:41:07.002-05:00", "2026-11-01T09:14:03.117-05:00", "2026-03-08T01:59:59.999-05:00",
                      "2026-03-08T03:00:00.000-04:00", "2026-11-08T23:59:59.900-05:00", "2026-07-04T12:00:00.000+05:30",
                      "1970-01-01T00:00:00.000Z", "2026-12-31T23:59:59.999Z"] {
            let expected = try XCTUnwrap(formatter.date(from: stamp), stamp)
            XCTAssertEqual(CivilTime.milliseconds(stamp), Int64((expected.timeIntervalSince1970 * 1000).rounded()), stamp)
        }
        // Without a fraction, and with a short or a long one.
        XCTAssertEqual(CivilTime.milliseconds("1970-01-01T00:00:01Z"), 1000)
        XCTAssertEqual(CivilTime.milliseconds("1970-01-01T00:00:01.5Z"), 1500)
        XCTAssertEqual(CivilTime.milliseconds("1970-01-01T00:00:01.123456Z"), 1123)
        XCTAssertEqual(CivilTime.milliseconds("1970-01-01T01:00:00+01:00"), 0)
    }

    func test_stampsThatDoNotReadAreNil() {
        for bad in ["", "2026-11-08", "2026-11-08 09:41:07-05:00", "2026-11-08T09:41-05:00", "2026-11-08T09:41:07", "2026-11-08T25:00:00Z",
                    "2026-11-08T09:61:00Z", "2026-11-08T09:41:07.-05:00", "2026-11-08T09:41:07.00x-05:00", "2026-11-08T09:41:07-5:00",
                    "2026-11-08T09:41:07*05:00", "2026-02-30T09:41:07Z", "yesterday"] {
            XCTAssertNil(CivilTime.milliseconds(bad), bad)
        }
    }
}
