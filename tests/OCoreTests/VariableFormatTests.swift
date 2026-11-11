import XCTest
@testable import OCore

/// Spec 6 §5 — "Formats (P7) are a fixed set, so every campus renders alike":
///
/// | Kind | Formats | Examples |
/// | --- | --- | --- |
/// | Durations: `[Timer N]`, `[Service In]` | `m:ss`, the default (Spec 2 §4's clock style, with hours from an hour); `mm:ss`; `h:mm:ss` | `4:59` and `1:02:03`; `04:59` and `75:00`; `0:04:59` |
/// | `[Time]` | `h:mm a`, `HH:mm`, `h:mm:ss a` | `10:30 AM`, `10:30`, `10:30:15 AM` |
/// | `[Date]` | `MMMM d`, `EEEE, MMMM d`, `yyyy-MM-dd` | `November 8`, `Sunday, November 8`, `2026-11-08` |
///
/// "Month and day names are English in v1. A countdown shows whole seconds
/// rounded up, and a count-up shows them rounded down, so a countdown reads
/// `0:00` exactly when it reaches zero. `overrun` makes a countdown show the
/// time past zero after a minus sign, in whole seconds rounded down: `0:00`
/// for the first second past zero, then `-0:01`, `-0:02` (§6)."
final class VariableFormatTests: XCTestCase {
    func test_durationsInEachFormat() {
        let table: [(Int, String, String)] = [
            (299, "m:ss", "4:59"), (3723, "m:ss", "1:02:03"), (0, "m:ss", "0:00"), (59, "m:ss", "0:59"), (600, "m:ss", "10:00"),
            (3599, "m:ss", "59:59"), (3600, "m:ss", "1:00:00"), (36_000 + 15 * 60, "m:ss", "10:15:00"),
            (299, "mm:ss", "04:59"), (4500, "mm:ss", "75:00"), (0, "mm:ss", "00:00"), (6000, "mm:ss", "100:00"),
            (299, "h:mm:ss", "0:04:59"), (3723, "h:mm:ss", "1:02:03"), (0, "h:mm:ss", "0:00:00"),
        ]
        for (seconds, format, text) in table {
            XCTAssertEqual(VariableFormat.duration(seconds: seconds, format: format), text, "\(seconds) \(format)")
        }
        XCTAssertEqual(VariableFormat.durations, ["m:ss", "mm:ss", "h:mm:ss"])
    }

    /// "A countdown shows whole seconds rounded up ... so a countdown reads
    /// `0:00` exactly when it reaches zero"; Spec 6 §6 — "at `0:00` its
    /// display holds".
    func test_aCountdownRoundsUpAndHoldsAtZero() {
        XCTAssertEqual(VariableFormat.countdown(ms: 300_000, format: "m:ss", overrun: false), "5:00")
        XCTAssertEqual(VariableFormat.countdown(ms: 299_500, format: "m:ss", overrun: false), "5:00")
        XCTAssertEqual(VariableFormat.countdown(ms: 299_000, format: "m:ss", overrun: false), "4:59")
        XCTAssertEqual(VariableFormat.countdown(ms: 1, format: "m:ss", overrun: false), "0:01")
        XCTAssertEqual(VariableFormat.countdown(ms: 0, format: "m:ss", overrun: false), "0:00")
        XCTAssertEqual(VariableFormat.countdown(ms: -500, format: "m:ss", overrun: false), "0:00")
        XCTAssertEqual(VariableFormat.countdown(ms: -61_000, format: "mm:ss", overrun: false), "00:00")
        XCTAssertEqual(VariableFormat.countdown(ms: 3_600_000, format: "m:ss", overrun: false), "1:00:00")
    }

    /// "`overrun` makes a countdown show the time past zero after a minus
    /// sign, in whole seconds rounded down: `0:00` for the first second past
    /// zero, then `-0:01`, `-0:02`".
    func test_overrunCountsPastZero() {
        XCTAssertEqual(VariableFormat.countdown(ms: 500, format: "m:ss", overrun: true), "0:01")
        XCTAssertEqual(VariableFormat.countdown(ms: 0, format: "m:ss", overrun: true), "0:00")
        XCTAssertEqual(VariableFormat.countdown(ms: -500, format: "m:ss", overrun: true), "0:00")
        XCTAssertEqual(VariableFormat.countdown(ms: -999, format: "m:ss", overrun: true), "0:00")
        XCTAssertEqual(VariableFormat.countdown(ms: -1000, format: "m:ss", overrun: true), "-0:01")
        XCTAssertEqual(VariableFormat.countdown(ms: -2500, format: "m:ss", overrun: true), "-0:02")
        XCTAssertEqual(VariableFormat.countdown(ms: -61_000, format: "mm:ss", overrun: true), "-01:01")
        XCTAssertEqual(VariableFormat.countdown(ms: -3_723_000, format: "m:ss", overrun: true), "-1:02:03")
        XCTAssertEqual(VariableFormat.countdown(ms: -1000, format: "h:mm:ss", overrun: true), "-0:00:01")
    }

    /// "a count-up shows them rounded down".
    func test_aCountUpRoundsDown() {
        XCTAssertEqual(VariableFormat.countUp(ms: 0, format: "m:ss"), "0:00")
        XCTAssertEqual(VariableFormat.countUp(ms: 999, format: "m:ss"), "0:00")
        XCTAssertEqual(VariableFormat.countUp(ms: 1000, format: "m:ss"), "0:01")
        XCTAssertEqual(VariableFormat.countUp(ms: 59_999, format: "m:ss"), "0:59")
        XCTAssertEqual(VariableFormat.countUp(ms: 3_600_000, format: "m:ss"), "1:00:00")
        XCTAssertEqual(VariableFormat.countUp(ms: 4_500_000, format: "mm:ss"), "75:00")
    }

    func test_timeInEachFormat() {
        let morning = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 10, minute: 30, second: 15)
        XCTAssertEqual(VariableFormat.time(morning, format: "h:mm a"), "10:30 AM")
        XCTAssertEqual(VariableFormat.time(morning, format: "HH:mm"), "10:30")
        XCTAssertEqual(VariableFormat.time(morning, format: "h:mm:ss a"), "10:30:15 AM")
        let midnight = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 0, minute: 5, second: 9)
        XCTAssertEqual(VariableFormat.time(midnight, format: "h:mm a"), "12:05 AM")
        XCTAssertEqual(VariableFormat.time(midnight, format: "HH:mm"), "00:05")
        XCTAssertEqual(VariableFormat.time(midnight, format: "h:mm:ss a"), "12:05:09 AM")
        let noon = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 12, minute: 0, second: 0)
        XCTAssertEqual(VariableFormat.time(noon, format: "h:mm a"), "12:00 PM")
        let evening = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 23, minute: 59, second: 59)
        XCTAssertEqual(VariableFormat.time(evening, format: "h:mm a"), "11:59 PM")
        XCTAssertEqual(VariableFormat.time(evening, format: "HH:mm"), "23:59")
        let early = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 9, minute: 5, second: 0)
        XCTAssertEqual(VariableFormat.time(early, format: "HH:mm"), "09:05")
        XCTAssertEqual(VariableFormat.time(early, format: "h:mm a"), "9:05 AM")
        XCTAssertEqual(VariableFormat.times, ["h:mm a", "HH:mm", "h:mm:ss a"])
    }

    /// "Month and day names are English in v1."
    func test_dateInEachFormat() {
        let sunday = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 10, minute: 30, second: 0)
        XCTAssertEqual(VariableFormat.date(sunday, format: "MMMM d"), "November 8")
        XCTAssertEqual(VariableFormat.date(sunday, format: "EEEE, MMMM d"), "Sunday, November 8")
        XCTAssertEqual(VariableFormat.date(sunday, format: "yyyy-MM-dd"), "2026-11-08")
        let newYear = WallClockReading(year: 2027, month: 1, day: 1, weekday: 6, hour: 0, minute: 0, second: 0)
        XCTAssertEqual(VariableFormat.date(newYear, format: "MMMM d"), "January 1")
        XCTAssertEqual(VariableFormat.date(newYear, format: "EEEE, MMMM d"), "Friday, January 1")
        XCTAssertEqual(VariableFormat.date(newYear, format: "yyyy-MM-dd"), "2027-01-01")
        let names = (1...12).map { VariableFormat.date(WallClockReading(year: 2026, month: $0, day: 1, weekday: 1, hour: 0, minute: 0, second: 0), format: "MMMM d") }
        XCTAssertEqual(names, ["January 1", "February 1", "March 1", "April 1", "May 1", "June 1", "July 1", "August 1",
                               "September 1", "October 1", "November 1", "December 1"])
        let days = (1...7).map { VariableFormat.date(WallClockReading(year: 2026, month: 11, day: 8, weekday: $0, hour: 0, minute: 0, second: 0), format: "EEEE, MMMM d") }
        XCTAssertEqual(days.map { String($0.prefix { $0 != "," }) }, ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"])
        XCTAssertEqual(VariableFormat.dates, ["MMMM d", "EEEE, MMMM d", "yyyy-MM-dd"])
    }
}
