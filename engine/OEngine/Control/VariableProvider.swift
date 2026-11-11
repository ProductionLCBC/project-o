// OEngine — Spec 6 §5 and Spec 4 §2, the wall clock the variables read, and
// the variables resolved for a box.

import Foundation
import OCore

/// Spec 4 §2 — "All engine time is monotonic (mach absolute time); the wall
/// clock is read only to stamp log lines and resolve [Time], [Date] and
/// [Service In]". Spec 6 §5 — the variables of a box's text, resolved by
/// OCore's `VariableResolver` in the state being drawn, with the readings
/// that "read the same in every state": the wall clock in the machine's time
/// zone, read once a wall-clock second, `[Service In]` from the live
/// playlist's `serviceTime`, and the timers.
///
/// The wall clock is injected so the harness can fix it. The control thread
/// resolves the live plan's boxes and publishes the live playlist and the
/// timers for the thumbnail job, which resolves on its own queue.
public final class VariableProvider: @unchecked Sendable {
    public let timeZone: TimeZone
    /// Spec 1 §3 — the machine's `timeFormat`, `timers` and `popups`, fixed
    /// for the run (settings edits come with Area 17).
    public let timeFormat: String
    public let timerSlots: Int
    public let popupSlots: Int
    private let calendar: Calendar
    private let stampFormatter: DateFormatter
    private let wallClock: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedSecond: Int64 = .min
    private var cachedReading = WallClockReading(year: 1970, month: 1, day: 1, weekday: 5, hour: 0, minute: 0, second: 0)
    private var cachedToday = ""
    private var serviceCache: (key: String, second: Int64, seconds: Int?)?
    private var published: (playlist: Playlist?, timers: [Int: TimerReading]) = (nil, [:])
    private var logged: Set<String> = []

    public init(timeFormat: String, timeZone: String, timers: Int = 4, popups: Int = 4,
                wallClock: @escaping @Sendable () -> Date = { Date() }) {
        let zone = TimeZone(identifier: timeZone) ?? TimeZone.current
        self.timeZone = zone
        self.timeFormat = timeFormat
        self.timerSlots = timers
        self.popupSlots = popups
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.calendar = calendar
        stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.timeZone = zone
        stampFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxxxx"
        self.wallClock = wallClock
    }

    public convenience init(settings: MachineSettings, wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(timeFormat: settings.timeFormat, timeZone: settings.timeZone, timers: settings.timers, popups: settings.popups,
                  wallClock: wallClock)
    }

    // MARK: - Stamps (Spec 2 §9, Spec 5 §10, Spec 1 §4)

    /// Spec 2 §9 — a log line's `ts`, "2026-11-01T09:14:03.117-05:00": the
    /// machine's local time with milliseconds and its offset.
    public func timestamp() -> String {
        let now = wallClock()
        lock.lock()
        defer { lock.unlock() }
        return stampFormatter.string(from: now)
    }

    /// Spec 5 §10 — a conflict file is "named with the time and the file's
    /// name": the machine's local time, `2026-11-08-085959`, as Spec 9 names
    /// its snapshots.
    public func fileStamp() -> String {
        let now = wallClock()
        lock.lock()
        defer { lock.unlock() }
        let format = stampFormatter.dateFormat
        stampFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let out = stampFormatter.string(from: now)
        stampFormatter.dateFormat = format
        return out
    }

    /// The wall clock in milliseconds since 1970: Spec 1 §4's ten-minute rule
    /// compares it with the dates of the kept versions' files.
    public var wallMilliseconds: Int64 {
        Int64((wallClock().timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Spec 7 §5 — archive's dated title is "the day it runs in the machine's
    /// time zone, written `2026-11-01`". Not `[Date]`, whose default is
    /// `MMMM d` (Spec 6 §5).
    public func today() -> String {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedToday
    }

    // MARK: - The wall clock, once a second (Spec 4 §8, Spec 6 §5)

    /// Spec 4 §8 — "at most once a wall-clock second for the clock, timers and
    /// `[Service In]`": the wall-clock second the provider is on, which the
    /// variable boxes' adoption counts by.
    public var currentSecond: Int64 {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedSecond
    }

    /// Spec 6 §5 — the wall clock in the machine's time zone, as of the
    /// current wall-clock second.
    public func reading() -> WallClockReading {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedReading
    }

    private func refresh() {
        let now = wallClock()
        let second = Int64(now.timeIntervalSinceReferenceDate.rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard second != cachedSecond else { return }
        cachedSecond = second
        let at = Date(timeIntervalSinceReferenceDate: Double(second))
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: at)
        cachedReading = WallClockReading(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1, weekday: c.weekday ?? 1,
                                         hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
        cachedToday = VariableFormat.date(cachedReading, format: "yyyy-MM-dd")
    }

    // MARK: - [Service In] (Spec 6 §5)

    /// Spec 6 §5 — "`[Service In]` (P6, R4) counts down to the live
    /// playlist's service time: the playlist's new `serviceTime`, an optional
    /// `HH:MM` in the machine's time zone. On a dated playlist it counts to
    /// that time on its `serviceDate`; on an undated one, to that time today.
    /// Once the time arrives it shows `0:00`, and an undated playlist starts
    /// counting again at midnight, toward the next day's time (choice T-3).
    /// ... It is empty when no playlist is live or the live one has no
    /// `serviceTime`." Whole seconds to the service, counted from the current
    /// wall-clock second, which is a countdown rounded up; nil when empty, and
    /// when the time or the date does not read.
    public func serviceInSeconds(for playlist: Playlist?) -> Int? {
        guard let playlist, let time = playlist.serviceTime else { return nil }
        refresh()
        lock.lock()
        defer { lock.unlock() }
        let key = (playlist.serviceDate ?? "") + "|" + time
        if let cached = serviceCache, cached.key == key, cached.second == cachedSecond { return cached.seconds }
        let seconds = serviceIn(date: playlist.serviceDate, time: time)
        serviceCache = (key, cachedSecond, seconds)
        return seconds
    }

    /// Called with the lock held.
    private func serviceIn(date: String?, time: String) -> Int? {
        guard let clock = Playlist.serviceClock(time) else { return nil }
        let day: (year: Int, month: Int, day: Int)
        if let date {
            guard let dated = Playlist.serviceDay(date) else { return nil }
            day = dated
        } else {
            day = (cachedReading.year, cachedReading.month, cachedReading.day)
        }
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: clock.hour, minute: clock.minute)
        guard let target = calendar.date(from: components) else { return nil }
        let now = Date(timeIntervalSinceReferenceDate: Double(cachedSecond))
        return max(0, Int(target.timeIntervalSince(now).rounded()))
    }

    // MARK: - Resolving (Spec 6 §5)

    /// Spec 6 §5 — the readings that "read the same in every state" for one
    /// build: the wall clock, `[Service In]` from `livePlaylist`, and the
    /// timers.
    public func clock(livePlaylist: Playlist?, timers: [Int: TimerReading]) -> VariableClock {
        VariableClock(wall: reading(), timeFormat: timeFormat, serviceInSeconds: serviceInSeconds(for: livePlaylist), timers: timers,
                      timerSlots: timerSlots, popupSlots: popupSlots)
    }

    /// Spec 6 §5 — `text` with its variables resolved in `state`, read in
    /// `scope`, over `roots`, with `clock`'s readings.
    public func resolve(_ text: String, state: ShowState, scope: VariableScope, roots: VariableRoots, clock: VariableClock) -> ResolvedText {
        VariableResolver.resolve(text, state: state, scope: scope, roots: roots, clock: clock)
    }

    /// Spec 6 §5 — the live playlist and the timers as the last build left
    /// them, for the thumbnail job: "A thumbnail shows them as they were when
    /// it rendered".
    public func publish(livePlaylist: Playlist?, timers: [Int: TimerReading]) {
        lock.lock()
        published = (livePlaylist, timers)
        lock.unlock()
    }

    /// The readings for a thumbnail: the wall clock now, with what the last
    /// build published.
    public func publishedClock() -> VariableClock {
        lock.lock()
        let (playlist, timers) = published
        lock.unlock()
        return clock(livePlaylist: playlist, timers: timers)
    }

    /// Spec 6 §5 — "A format outside the set, or `overrun` on anything but a
    /// timer, renders with the default and is logged once per box": true the
    /// first time `issue` is seen for `box`, once for the run.
    public func firstTime(_ issue: VariableIssue, box: BoxKey) -> Bool {
        let key = "\(box.stack).\(box.slot).\(box.box)|\(issue.token)|\(issue.message)"
        lock.lock()
        defer { lock.unlock() }
        return logged.insert(key).inserted
    }

    /// Log each of `issues` once for `box` (Spec 6 §5), naming the box.
    public func log(_ issues: [VariableIssue], box: BoxKey, to log: EngineLog) {
        for issue in issues where firstTime(issue, box: box) {
            log.warning("stack \(box.stack) slot \(box.slot + 1) box \(box.box + 1): \(issue.message)")
        }
    }

    // MARK: - Guards (Spec 2 §7)

    /// Spec 2 §7 — the value of a variable named without brackets, for
    /// guards, which are v1.5's: `Time` in the machine's format, `Date` as
    /// `yyyy-MM-dd` as guards compare it, `Popup N` as set.
    public func value(_ name: String, state: ShowState) -> String? {
        let words = name.split(separator: " ").map(String.init)
        guard let head = words.first?.lowercased() else { return nil }
        switch head {
        case "time":
            let format = VariableFormat.times.contains(timeFormat) ? timeFormat : VariableFormat.times[0]
            return VariableFormat.time(reading(), format: format)
        case "date":
            return today()
        case "popup":
            guard words.count >= 2, let n = Int(words[1]) else { return nil }
            return state.popups[n]
        default:
            return nil
        }
    }
}
