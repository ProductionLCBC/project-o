// OCore — Spec 9 §7, which files are kept.
//
// Pure: names, sizes and today's date in, the names to remove out. The
// engine lists the folders and removes the files, off the control thread.

import Foundation

/// Spec 9 §7 — "Retention (G3)":
///
/// | Files | Kept |
/// | --- | --- |
/// | Snapshots | Every one for 7 days; then the newest of each day until 30 days old; then the newest of each week, Monday to Sunday, until a year old; none older. A snapshot an undo or redo step names is kept until the run ends |
/// | Command logs | 90 days and 2 GB in all; past either, the oldest go first. Today's file is never removed |
/// | Engine logs | 90 days and 1 GB in all, the same way |
///
/// "Days and weeks are local ones": ages are whole calendar days between the
/// day in a file's name, which the engine wrote in the machine's time zone,
/// and today's date there (the plan's reading). A year is 365 days. A file
/// whose name the engine didn't write is never removed and never counted.
public enum Retention {
    /// "Every one for 7 days".
    public static let everyDays = 7
    /// "then the newest of each day until 30 days old".
    public static let dailyDays = 30
    /// "then the newest of each week ... until a year old".
    public static let weeklyDays = 365
    /// "90 days".
    public static let logDays = 90
    /// "Command logs | 90 days and 2 GB in all".
    public static let commandLogBytes: Int64 = 2 << 30
    /// "Engine logs | 90 days and 1 GB in all".
    public static let engineLogBytes: Int64 = 1 << 30

    // MARK: - Snapshots

    /// The local day in a snapshot's id, `2026-11-08-085959` or
    /// `2026-11-08-085959-2`, as a day number; nil for a name that isn't one.
    public static func day(ofSnapshot id: String) -> Int? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 5, parts[3].count == 6, parts[3].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if parts.count == 5, Int(parts[4]) == nil { return nil }
        return CivilTime.days(parts[0...2].joined(separator: "-"))
    }

    /// Spec 9 §7 — the snapshots to remove, oldest first: none up to 7 days
    /// old; from then to 30 days all but the newest of each day; from then to
    /// a year all but the newest of each week, Monday to Sunday; and every
    /// one older. `named` are the ids an undo or redo step names, which stay
    /// "until the run ends". `today` is the machine's local date.
    public static func snapshotsToRemove(_ ids: [String], today: String, named: Set<String> = []) -> [String] {
        guard let now = CivilTime.days(today) else { return [] }
        var remove: [String] = []
        // The newest kept of each day and of each week, walking newest first.
        var daysKept: Set<Int> = []
        var weeksKept: Set<Int> = []
        for id in SnapshotID.sorted(ids).reversed() {
            guard let day = day(ofSnapshot: id) else { continue }
            let age = now - day
            if age <= everyDays { continue }
            if age <= dailyDays {
                if daysKept.insert(day).inserted { continue }
            } else if age <= weeklyDays {
                if weeksKept.insert(CivilTime.weekStart(days: day)).inserted { continue }
            }
            if !named.contains(id) { remove.append(id) }
        }
        return remove.reversed()
    }

    // MARK: - Logs

    /// The local day in a log file's name, `commands-2026-11-08.jsonl`; nil
    /// for any other name.
    public static func day(ofLog name: String, prefix: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(".jsonl") else { return nil }
        return CivilTime.days(String(name.dropFirst(prefix.count).dropLast(".jsonl".count)))
    }

    /// Spec 9 §7 — the files of one log to remove, oldest first: those more
    /// than `days` old, then the oldest of the rest while they add up to more
    /// than `bytes`. "Today's file is never removed", and a later one (the
    /// clock stepped back) isn't either.
    public static func logsToRemove(_ files: [(name: String, bytes: Int64)], prefix: String, today: String, days: Int = logDays,
                                    bytes: Int64) -> [String] {
        guard let now = CivilTime.days(today) else { return [] }
        var dated: [(name: String, bytes: Int64, day: Int)] = []
        for file in files {
            if let day = day(ofLog: file.name, prefix: prefix) { dated.append((file.name, file.bytes, day)) }
        }
        dated.sort { ($0.day, $0.name) < ($1.day, $1.name) }
        var remove: [String] = []
        var kept: [(name: String, bytes: Int64, day: Int)] = []
        for file in dated {
            if now - file.day > days {
                remove.append(file.name)
            } else {
                kept.append(file)
            }
        }
        var total = kept.reduce(Int64(0)) { $0 + $1.bytes }
        for file in kept where total > bytes && file.day < now {
            remove.append(file.name)
            total -= file.bytes
        }
        return remove
    }
}
