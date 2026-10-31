// OEngine — Spec 2 §7 and Spec 4 §8, variables: [Time], [Date], [Popup N].

import Foundation
import OCore

/// Spec 4 §8 — "A box whose text contains variables is re-laid-out only when
/// its resolved text changes, and no more than once a second". Spec 4 §2 —
/// "the wall clock is read only to stamp log lines and resolve [Time]".
/// Spec 3 §6 — the projection's `variables` closure resolves guard values.
///
/// v1 of the spike resolves `[Time]`, `[Date]` and `[Popup N]`; `[Timer N]`
/// and the live-position variables arrive with Area 11 and resolve to nothing
/// until then. The wall clock is injected so the harness can fix it.
public final class VariableProvider: @unchecked Sendable {
    private let formatter: DateFormatter
    private let dateFormatter: DateFormatter
    private let wallClock: @Sendable () -> Date
    private let lock = NSLock()
    private var cachedSecond: Int64 = .min
    private var cachedTime = ""
    private var cachedDate = ""

    public init(timeFormat: String, timeZone: String, wallClock: @escaping @Sendable () -> Date = { Date() }) {
        let zone = TimeZone(identifier: timeZone) ?? TimeZone.current
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = timeFormat
        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = zone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        self.wallClock = wallClock
    }

    public convenience init(settings: MachineSettings, wallClock: @escaping @Sendable () -> Date = { Date() }) {
        self.init(timeFormat: settings.timeFormat, timeZone: settings.timeZone, wallClock: wallClock)
    }

    /// The formatted time, refreshed at most once a second.
    public func time() -> String {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedTime
    }

    public func date() -> String {
        refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedDate
    }

    private func refresh() {
        let now = wallClock()
        let second = Int64(now.timeIntervalSinceReferenceDate.rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard second != cachedSecond else { return }
        cachedSecond = second
        cachedTime = formatter.string(from: now)
        cachedDate = dateFormatter.string(from: now)
    }

    /// Spec 2 §7 — the value of a variable named without brackets, for guards.
    public func value(_ name: String, state: ShowState) -> String? {
        let words = name.split(separator: " ").map(String.init)
        guard let head = words.first?.lowercased() else { return nil }
        switch head {
        case "time": return time()
        case "date": return date()
        case "popup":
            guard words.count >= 2, let n = Int(words[1]) else { return nil }
            return state.popups[n]
        default:
            return nil
        }
    }

    /// Spec 1 §2 — "static text may contain variables": every `[Name]` token
    /// replaced by its value, or by nothing when it has none.
    public func resolve(_ text: String, state: ShowState) -> String {
        guard text.contains("[") else { return text }
        var out = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "[") {
            out += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "]") else {
                out += rest[open...]
                return out
            }
            let name = String(rest[afterOpen..<close])
            out += value(name, state: state) ?? ""
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return out
    }

    /// Whether the text names any variable.
    public static func containsVariables(_ text: String) -> Bool {
        guard let open = text.firstIndex(of: "[") else { return false }
        return text[open...].contains("]")
    }
}
