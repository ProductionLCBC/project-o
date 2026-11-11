// OCore — Spec 6 §5, the v1 set resolved against the state being drawn.

import Foundation

/// Spec 6 §6 and §8 — what a timer reads: "`state` is `unset`, `stopped`,
/// `running` or `paused`, and `direction` is `down` or `up`. An unset timer
/// has `null` for `direction`, `setMs` and `valueMs`". `valueMs` is signed:
/// "On a countdown, `i` goes negative past zero; on a count-up, it includes
/// the starting value."
public struct TimerReading: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case unset, stopped, running, paused
    }

    public enum Direction: String, Equatable, Sendable {
        case down, up
    }

    public var state: State
    public var direction: Direction?
    public var setMs: Int?
    public var valueMs: Int?

    public init(state: State, direction: Direction?, setMs: Int?, valueMs: Int?) {
        self.state = state
        self.direction = direction
        self.setMs = setMs
        self.valueMs = valueMs
    }

    /// Spec 6 §6 — "after a relaunch every timer is unset".
    public static let unset = TimerReading(state: .unset, direction: nil, setMs: nil, valueMs: nil)

    /// Spec 6 §5 — `[Timer N]`: "Timer N's value (§6); empty while unset", in
    /// a duration format; a countdown "holds" `0:00` unless `overrun` asks for
    /// the time past zero, and "`overrun` means nothing on a count-up".
    public func text(format: String, overrun: Bool) -> String {
        guard state != .unset, let direction, let valueMs else { return "" }
        switch direction {
        case .down: return VariableFormat.countdown(ms: valueMs, format: format, overrun: overrun)
        case .up: return VariableFormat.countUp(ms: valueMs, format: format)
        }
    }
}

/// Spec 6 §5 — "Which state a value reads": "In text content, a value reads
/// the content's provenance ... In a static box, a value reads the state's
/// pointer".
public enum VariableScope: Hashable, Sendable {
    /// Text content on this channel: its provenance's cue and list, or the
    /// pointer's for content no cue wrote.
    case content(channel: Int)
    /// A static box: the state's pointer.
    case pointer
}

/// Where a context value finds its list and cue: the library, the machine's
/// local copies, and the kept copies of the live list and playlist (Spec 7 §4).
public struct VariableRoots: Sendable {
    public var library: Library
    public var machine: Machine
    public var kept: KeptCopies

    public init(library: Library, machine: Machine, kept: KeptCopies = KeptCopies()) {
        self.library = library
        self.machine = machine
        self.kept = kept
    }
}

/// Spec 6 §5 — "`[Time]`, `[Date]`, `[Timer N]` and `[Service In]` read the
/// same in every state, and lookahead never runs a timer": the engine's
/// readings for one build, with the machine's settings they need.
public struct VariableClock: Equatable, Sendable {
    /// The wall clock in the machine's time zone.
    public var wall: WallClockReading
    /// The machine's `timeFormat`, `[Time]`'s default.
    public var timeFormat: String
    /// Spec 6 §5 — `[Service In]`: the whole seconds to the live playlist's
    /// service, 0 once it arrives; nil when it is empty.
    public var serviceInSeconds: Int?
    /// Spec 6 §6 — the timers by slot; a slot not here is unset.
    public var timers: [Int: TimerReading]
    /// Spec 1 §3 — the machine's `timers` and `popups` counts.
    public var timerSlots: Int
    public var popupSlots: Int

    public init(wall: WallClockReading, timeFormat: String, serviceInSeconds: Int? = nil, timers: [Int: TimerReading] = [:],
                timerSlots: Int, popupSlots: Int) {
        self.wall = wall
        self.timeFormat = timeFormat
        self.serviceInSeconds = serviceInSeconds
        self.timers = timers
        self.timerSlots = timerSlots
        self.popupSlots = popupSlots
    }
}

/// One variable's value in a resolution, with how soon a change to it shows
/// (Spec 6 §5). A popup's value is its text as set, and the variables of
/// that text follow it, one level deep.
public struct ResolvedValue: Equatable, Sendable {
    public var written: String
    public var pacing: VariablePacing
    public var value: String

    public init(written: String, pacing: VariablePacing, value: String) {
        self.written = written
        self.pacing = pacing
        self.value = value
    }
}

/// Spec 6 §5 — "A format outside the set, or `overrun` on anything but a
/// timer, renders with the default and is logged once per box. So does a
/// machine `timeFormat` outside the `[Time]` set." The variable as written,
/// and the line to log.
public struct VariableIssue: Equatable, Sendable {
    public var token: String
    public var message: String

    public init(token: String, message: String) {
        self.token = token
        self.message = message
    }
}

/// A text with its variables resolved: what a box draws, whether its digits
/// are tabular (Spec 6 §4), each value for its adoption (Spec 6 §5), and what
/// to log.
public struct ResolvedText: Equatable, Sendable {
    public var text: String
    public var tabular: Bool
    public var values: [ResolvedValue]
    public var issues: [VariableIssue]

    public init(text: String, tabular: Bool = false, values: [ResolvedValue] = [], issues: [VariableIssue] = []) {
        self.text = text
        self.tabular = tabular
        self.values = values
        self.issues = issues
    }

    /// Whether the text names any v1 variable.
    public var hasVariables: Bool { !values.isEmpty }
}

/// Spec 6 §5 — the variables of a text resolved in the state being drawn.
public enum VariableResolver {
    /// Spec 6 §5 — "Where variables resolve. In static box text and in text
    /// content, wherever text is rendered (UX spec), and in a popup's text,
    /// one level deep (choice T-2). A variable inside a popup's text resolves
    /// when a box shows the popup ... It reads the same state as that box. A
    /// `[Popup N]` inside a popup's text prints as written". "Empty values
    /// ... A variable with no value renders nothing". Values go in as they
    /// are and are never read for variables again, a popup's text aside.
    public static func resolve(_ text: String, state: ShowState, scope: VariableScope, roots: VariableRoots,
                               clock: VariableClock) -> ResolvedText {
        let parsed = VariableText.parse(text)
        var out = ResolvedText(text: "")
        for segment in parsed.segments {
            switch segment {
            case .text(let literal):
                out.text += literal
            case .variable(let token):
                if token.name.asksForTabularDigits { out.tabular = true }
                guard case .popup(let n) = token.name else {
                    let value = self.value(token, state: state, scope: scope, roots: roots, clock: clock, issues: &out.issues)
                    out.values.append(ResolvedValue(written: token.written, pacing: token.name.pacing, value: value))
                    out.text += value
                    continue
                }
                if token.format != nil || token.overrun { out.issues.append(noFormat(token)) }
                // "A timer or popup number above the machine's count ... resolves empty."
                let raw = n <= clock.popupSlots ? (state.popups[n] ?? "") : ""
                out.values.append(ResolvedValue(written: token.written, pacing: .popup, value: raw))
                for inner in VariableText.parse(raw).segments {
                    switch inner {
                    case .text(let literal):
                        out.text += literal
                    case .variable(let token):
                        if case .popup = token.name {
                            out.text += token.written
                            continue
                        }
                        if token.name.asksForTabularDigits { out.tabular = true }
                        let value = self.value(token, state: state, scope: scope, roots: roots, clock: clock, issues: &out.issues)
                        out.values.append(ResolvedValue(written: token.written, pacing: token.name.pacing, value: value))
                        out.text += value
                    }
                }
            }
        }
        return out
    }

    /// Spec 6 §4 — "A box whose text names `[Time]`, `[Timer N]` or `[Service
    /// In]`, itself or inside a popup it shows, lays out its digits with the
    /// font's tabular figures": `popups` are the popup texts of the state
    /// being drawn, read one level deep as Spec 6 §5 resolves them.
    public static func asksForTabularDigits(_ text: String, popups: [Int: String]) -> Bool {
        let parsed = VariableText.parse(text)
        if parsed.asksForTabularDigits { return true }
        for token in parsed.tokens {
            guard case .popup(let n) = token.name, let popup = popups[n] else { continue }
            if VariableText.parse(popup).asksForTabularDigits { return true }
        }
        return false
    }

    /// Spec 6 §5 — one variable other than a popup.
    static func value(_ token: VariableToken, state: ShowState, scope: VariableScope, roots: VariableRoots, clock: VariableClock,
                      issues: inout [VariableIssue]) -> String {
        switch token.name {
        case .time:
            let format: String
            if let given = token.format {
                format = checked(given, token: token, default: VariableFormat.times[0], issues: &issues)
            } else if VariableFormat.times.contains(clock.timeFormat) {
                format = clock.timeFormat
            } else {
                // "So does a machine `timeFormat` outside the `[Time]` set."
                issues.append(VariableIssue(token: token.written, message: "\(token.written): the machine's timeFormat \"\(clock.timeFormat)\" is not one of [Time]'s formats (\(VariableFormat.times.joined(separator: ", "))); it renders as \(VariableFormat.times[0])"))
                format = VariableFormat.times[0]
            }
            if token.overrun { issues.append(overrunOutsideATimer(token, renders: format)) }
            return VariableFormat.time(clock.wall, format: format)
        case .date:
            let format = token.format.map { checked($0, token: token, default: VariableFormat.dates[0], issues: &issues) } ?? VariableFormat.dates[0]
            if token.overrun { issues.append(overrunOutsideATimer(token, renders: format)) }
            return VariableFormat.date(clock.wall, format: format)
        case .timer(let n):
            let format = token.format.map { checked($0, token: token, default: VariableFormat.durations[0], issues: &issues) } ?? VariableFormat.durations[0]
            // "A timer or popup number above the machine's count is still a v1 name. It resolves empty".
            let reading = n <= clock.timerSlots ? (clock.timers[n] ?? .unset) : .unset
            return reading.text(format: format, overrun: token.overrun)
        case .serviceIn:
            let format = token.format.map { checked($0, token: token, default: VariableFormat.durations[0], issues: &issues) } ?? VariableFormat.durations[0]
            if token.overrun { issues.append(overrunOutsideATimer(token, renders: format)) }
            guard let seconds = clock.serviceInSeconds else { return "" }
            return VariableFormat.duration(seconds: seconds, format: format)
        case .liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli:
            if token.format != nil || token.overrun { issues.append(noFormat(token)) }
            return contextValue(token.name, state: state, scope: scope, roots: roots)
        case .popup:
            return ""
        }
    }

    /// Spec 6 §5 — "formats must match exactly"; "A format outside the set
    /// ... renders with the default".
    static func checked(_ format: String, token: VariableToken, default fallback: String, issues: inout [VariableIssue]) -> String {
        let formats = token.name.formats ?? []
        guard !formats.contains(format) else { return format }
        issues.append(VariableIssue(token: token.written, message: "\(token.written): \"\(format)\" is not one of \(token.name.label)'s formats (\(formats.joined(separator: ", "))); it renders as \(fallback)"))
        return fallback
    }

    static func overrunOutsideATimer(_ token: VariableToken, renders format: String) -> VariableIssue {
        VariableIssue(token: token.written, message: "\(token.written): overrun applies only to a timer; it renders as \(format)")
    }

    static func noFormat(_ token: VariableToken) -> VariableIssue {
        VariableIssue(token: token.written, message: "\(token.written): \(token.name.label) takes no format; it renders its value")
    }

    /// Spec 6 §5 — the six context values, from the state being drawn:
    /// "`[Live Title]` The list's `title`"; "`[Next Title]` The title of the
    /// next list in the live playlist"; "`[Section]` The cue's `section`";
    /// "`[Cue Note]` The cue's `note`"; "`[Copyright]` The list's
    /// `copyright`"; "`[CCLI]` The list's `ccli`". "The cue" and "the list"
    /// are the provenance's in content and the pointer's in a static box;
    /// "`[Next Title]` reads the state's pointer in both cases, since only the
    /// pointer knows the playlist position. A projected state has no
    /// playlist, so in a thumbnail it is empty." Spec 7 §4 — from the kept
    /// copies when the list or the cue is gone. Empty for any other name.
    public static func contextValue(_ name: VariableName, state: ShowState, scope: VariableScope, roots: VariableRoots) -> String {
        if case .nextTitle = name {
            return Placer(library: roots.library, machine: roots.machine, kept: roots.kept).nextTitle(from: state.pointer) ?? ""
        }
        let (listUuid, cueUuid) = place(state: state, scope: scope)
        guard let listUuid, let list = ShowState.list(uuid: listUuid, library: roots.library, machine: roots.machine, kept: roots.kept) else {
            return ""
        }
        switch name {
        case .liveTitle: return list.title
        case .copyright: return list.copyright
        case .ccli: return list.ccli
        case .section, .cueNote:
            guard let cueUuid else { return "" }
            let kept = roots.kept.list?.uuid == listUuid ? roots.kept.list : nil
            guard let cue = list.cues.first(where: { $0.uuid == cueUuid }) ?? kept?.cues.first(where: { $0.uuid == cueUuid }) else { return "" }
            return name == .section ? (cue.section ?? "") : cue.note
        default:
            return ""
        }
    }

    /// Spec 6 §5 — "In text content, a value reads the content's provenance:
    /// the cue that wrote it and the list that cue was fired from ... Content
    /// no cue wrote ... reads the state's pointer instead"; "In a static box,
    /// a value reads the state's pointer: its cue and its list." A provenance
    /// with no list, from a `last.json` written before Area 6, reads the
    /// pointer's, as Area 6 read it for field boxes.
    static func place(state: ShowState, scope: VariableScope) -> (list: UUID?, cue: UUID?) {
        if case .content(let channel) = scope, let provenance = state.channels[channel]?.provenance, let list = provenance.list {
            return (list, provenance.cue)
        }
        return (state.pointer?.listUuid, state.pointer?.cueUuid)
    }
}
