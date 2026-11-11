// OCore — Spec 6 §5, the fixed formats.

/// Spec 6 §5 — the wall clock as the engine reads it in the machine's time
/// zone (Spec 4 §2: "the wall clock is read only to stamp log lines and
/// resolve [Time], [Date] and [Service In]"). OCore reads no clock and keeps
/// no calendar (Spec 3 §10), so the engine hands over the reading.
public struct WallClockReading: Equatable, Sendable {
    public var year: Int
    /// 1 to 12.
    public var month: Int
    public var day: Int
    /// 1 for Sunday to 7 for Saturday.
    public var weekday: Int
    /// 0 to 23.
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(year: Int, month: Int, day: Int, weekday: Int, hour: Int, minute: Int, second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.weekday = weekday
        self.hour = hour
        self.minute = minute
        self.second = second
    }
}

/// Spec 6 §5 — "Formats (P7) are a fixed set, so every campus renders alike":
///
/// | Kind | Formats | Examples |
/// | --- | --- | --- |
/// | Durations: `[Timer N]`, `[Service In]` | `m:ss`, the default (Spec 2 §4's clock style, with hours from an hour); `mm:ss`; `h:mm:ss` | `4:59` and `1:02:03`; `04:59` and `75:00`; `0:04:59` |
/// | `[Time]` | `h:mm a`, `HH:mm`, `h:mm:ss a` | `10:30 AM`, `10:30`, `10:30:15 AM` |
/// | `[Date]` | `MMMM d`, `EEEE, MMMM d`, `yyyy-MM-dd` | `November 8`, `Sunday, November 8`, `2026-11-08` |
///
/// "Month and day names are English in v1."
public enum VariableFormat {
    /// Durations, the default first.
    public static let durations = ["m:ss", "mm:ss", "h:mm:ss"]
    /// `[Time]`'s; its default is the machine's `timeFormat`, "`h:mm a` on first run".
    public static let times = ["h:mm a", "HH:mm", "h:mm:ss a"]
    /// `[Date]`'s, the default first: "`MMMM d` (choice T-9)".
    public static let dates = ["MMMM d", "EEEE, MMMM d", "yyyy-MM-dd"]

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                             "October", "November", "December"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Spec 6 §5 — whole seconds in a duration format: `m:ss` with hours from
    /// an hour, `mm:ss` with the minutes counting on past an hour, `h:mm:ss`
    /// always with hours. A format outside the set prints as `m:ss`.
    public static func duration(seconds: Int, format: String) -> String {
        let s = max(0, seconds)
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        let secs = s % 60
        switch format {
        case "mm:ss":
            return pad2(s / 60) + ":" + pad2(secs)
        case "h:mm:ss":
            return "\(hours):" + pad2(minutes) + ":" + pad2(secs)
        default:
            return hours > 0 ? "\(hours):" + pad2(minutes) + ":" + pad2(secs) : "\(minutes):" + pad2(secs)
        }
    }

    /// Spec 6 §5 — "A countdown shows whole seconds rounded up ... so a
    /// countdown reads `0:00` exactly when it reaches zero"; Spec 6 §6 — "at
    /// `0:00` its display holds"; "`overrun` makes a countdown show the time
    /// past zero after a minus sign, in whole seconds rounded down: `0:00`
    /// for the first second past zero, then `-0:01`, `-0:02`". `ms` is the
    /// time left, negative past zero.
    public static func countdown(ms: Int, format: String, overrun: Bool) -> String {
        if ms > 0 { return duration(seconds: (ms + 999) / 1000, format: format) }
        guard overrun else { return duration(seconds: 0, format: format) }
        let past = (-ms) / 1000
        return past == 0 ? duration(seconds: 0, format: format) : "-" + duration(seconds: past, format: format)
    }

    /// Spec 6 §5 — "a count-up shows them rounded down".
    public static func countUp(ms: Int, format: String) -> String {
        duration(seconds: max(0, ms) / 1000, format: format)
    }

    /// Spec 6 §5 — `[Time]` in `h:mm a`, `HH:mm` or `h:mm:ss a`; a format
    /// outside the set prints as `h:mm a`.
    public static func time(_ reading: WallClockReading, format: String) -> String {
        let hour12 = reading.hour % 12 == 0 ? 12 : reading.hour % 12
        let marker = reading.hour < 12 ? "AM" : "PM"
        switch format {
        case "HH:mm": return pad2(reading.hour) + ":" + pad2(reading.minute)
        case "h:mm:ss a": return "\(hour12):" + pad2(reading.minute) + ":" + pad2(reading.second) + " " + marker
        default: return "\(hour12):" + pad2(reading.minute) + " " + marker
        }
    }

    /// Spec 6 §5 — `[Date]` in `MMMM d`, `EEEE, MMMM d` or `yyyy-MM-dd`; a
    /// format outside the set prints as `MMMM d`.
    public static func date(_ reading: WallClockReading, format: String) -> String {
        let month = monthNames.indices.contains(reading.month - 1) ? monthNames[reading.month - 1] : ""
        let weekday = weekdayNames.indices.contains(reading.weekday - 1) ? weekdayNames[reading.weekday - 1] : ""
        switch format {
        case "EEEE, MMMM d": return weekday + ", " + month + " \(reading.day)"
        case "yyyy-MM-dd": return pad(reading.year, 4) + "-" + pad2(reading.month) + "-" + pad2(reading.day)
        default: return month + " \(reading.day)"
        }
    }

    static func pad2(_ n: Int) -> String { pad(n, 2) }

    static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
