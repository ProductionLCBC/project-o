// OCore — dates and stamps as the files write them, read without a clock or a calendar.

import Foundation

/// The dates Spec 9 counts in: a stamp such as a line's `ts` or `last.json`'s
/// `writtenAt` ("2026-11-08T09:41:07.002-05:00", Spec 2 §9), and a day such
/// as a log file's or a snapshot id's ("2026-11-08", Spec 9 §2 and §3). The
/// engine prints them in the machine's time zone; here they are only read
/// back and counted, as plain arithmetic on the proleptic Gregorian calendar,
/// so the rules that use them (the two-hour limit of §4, the retention of
/// §7) stay pure: nothing reads a clock or a time zone.
public enum CivilTime {
    /// The number of days from 1970-01-01 to a civil date.
    public static func days(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The civil date a number of days from 1970-01-01.
    public static func date(days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// A day written `2026-11-08`, as days from 1970-01-01; nil unless it is
    /// written so and names a day that exists.
    public static func days(_ text: String) -> Int? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = number(parts[0]), let month = number(parts[1]), let day = number(parts[2]),
              month >= 1, month <= 12, day >= 1 else { return nil }
        let days = days(year: year, month: month, day: day)
        // A day that doesn't exist (February 30) comes back as another date.
        let back = date(days: days)
        return back.year == year && back.month == month && back.day == day ? days : nil
    }

    /// A day number written `2026-11-08`.
    public static func text(days: Int) -> String {
        let d = date(days: days)
        return pad(d.year, 4) + "-" + pad(d.month, 2) + "-" + pad(d.day, 2)
    }

    /// The day of the week of a day number, Monday 1 to Sunday 7 (Spec 9 §7:
    /// "the newest of each week, Monday to Sunday").
    public static func weekday(days: Int) -> Int {
        let shifted = (days + 3) % 7
        return (shifted < 0 ? shifted + 7 : shifted) + 1
    }

    /// The Monday that begins the week a day is in, as a day number.
    public static func weekStart(days: Int) -> Int {
        days - (weekday(days: days) - 1)
    }

    /// A stamp written `2026-11-08T09:41:07.002-05:00` (the fraction optional,
    /// the offset `Z` or `±HH:MM`), as milliseconds from 1970-01-01T00:00:00Z;
    /// nil unless it reads so.
    public static func milliseconds(_ stamp: String) -> Int64? {
        let halves = stamp.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2, let day = days(String(halves[0])) else { return nil }
        var clock = Substring(halves[1])
        var offsetMinutes = 0
        if clock.hasSuffix("Z") || clock.hasSuffix("z") {
            clock = clock.dropLast()
        } else {
            guard clock.count >= 6 else { return nil }
            let zone = clock.suffix(6)
            clock = clock.dropLast(6)
            let sign = zone.first
            let fields = zone.dropFirst().split(separator: ":", omittingEmptySubsequences: false)
            guard sign == "+" || sign == "-", fields.count == 2, fields[0].count == 2, fields[1].count == 2,
                  let hours = number(fields[0]), let minutes = number(fields[1]), hours <= 23, minutes <= 59 else { return nil }
            offsetMinutes = (hours * 60 + minutes) * (sign == "-" ? -1 : 1)
        }
        let whole = clock.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fields = whole[0].split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ $0.count == 2 }),
              let hour = number(fields[0]), let minute = number(fields[1]), let second = number(fields[2]),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        var fraction = 0
        if whole.count == 2 {
            // Milliseconds: the first three digits, short fractions padded.
            let digits = whole[1]
            guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
            let three = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            fraction = Int(three) ?? 0
        }
        let seconds = Int64(day) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetMinutes * 60)
        return seconds * 1000 + Int64(fraction)
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(isDigit) else { return nil }
        return Int(text)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
