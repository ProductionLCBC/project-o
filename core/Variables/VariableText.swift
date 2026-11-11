// OCore — Spec 6 §5, the variable language.

/// Spec 6 §5 — the v1 set: "`[Time]`, `[Date]`, `[Timer N]`, `[Popup N]`,
/// `[Live Title]`, `[Next Title]`, `[Section]`, `[Cue Note]`, `[Copyright]`,
/// `[CCLI]`, `[Service In]`". `[Timecode]` is v2.
public enum VariableName: Hashable, Sendable {
    case time
    case date
    /// "Timer N's value (§6); empty while unset". A number above the
    /// machine's count is still the name, and resolves empty.
    case timer(Int)
    /// "Popup slot N's text (§7); empty while clear".
    case popup(Int)
    case liveTitle
    case nextTitle
    case section
    case cueNote
    case copyright
    case ccli
    case serviceIn
}

/// Spec 6 §5 — "When a box adopts a new value ... How soon depends on what
/// changed".
public enum VariablePacing: Hashable, Sendable {
    /// "A context value changed by a fire shows at once (choice T-5)."
    case context
    /// "A popup also shows at once, but at most ten times a second."
    case popup
    /// "The clock, a timer or `[Service In]` alone changes the box at most
    /// once per wall-clock second". `[Date]` is the clock's.
    case clocked
}

extension VariableName {
    /// Spec 6 §5 — how soon a box shows a change of this value.
    public var pacing: VariablePacing {
        switch self {
        case .time, .date, .timer, .serviceIn: return .clocked
        case .popup: return .popup
        case .liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli: return .context
        }
    }

    /// Spec 6 §4 — "A box whose text names `[Time]`, `[Timer N]` or `[Service
    /// In]` ... lays out its digits with the font's tabular figures".
    public var asksForTabularDigits: Bool {
        switch self {
        case .time, .timer, .serviceIn: return true
        default: return false
        }
    }

    /// Spec 6 §5 — "Formats (P7) are a fixed set": the formats this name
    /// takes, the default first, or nil for a name that takes none.
    public var formats: [String]? {
        switch self {
        case .time: return VariableFormat.times
        case .date: return VariableFormat.dates
        case .timer, .serviceIn: return VariableFormat.durations
        case .popup, .liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli: return nil
        }
    }

    /// The name as the table writes it, for the log.
    public var label: String {
        switch self {
        case .time: return "[Time]"
        case .date: return "[Date]"
        case .timer(let n): return "[Timer \(n)]"
        case .popup(let n): return "[Popup \(n)]"
        case .liveTitle: return "[Live Title]"
        case .nextTitle: return "[Next Title]"
        case .section: return "[Section]"
        case .cueNote: return "[Cue Note]"
        case .copyright: return "[Copyright]"
        case .ccli: return "[CCLI]"
        case .serviceIn: return "[Service In]"
        }
    }
}

/// Spec 6 §5 — "A variable is a name in square brackets, then optionally a
/// format, then, for a timer, optionally the word `overrun`".
public struct VariableToken: Hashable, Sendable {
    public var name: VariableName
    /// The format as written, matched exactly when it resolves; nil when
    /// none was given.
    public var format: String?
    /// The word `overrun`, last in the brackets, in any case.
    public var overrun: Bool
    /// The whole variable as written, brackets included.
    public var written: String

    public init(name: VariableName, format: String? = nil, overrun: Bool = false, written: String) {
        self.name = name
        self.format = format
        self.overrun = overrun
        self.written = written
    }
}

/// A run of text as it prints, or a variable.
public enum VariableSegment: Hashable, Sendable {
    case text(String)
    case variable(VariableToken)
}

/// Spec 6 §5 — a text with its variables found: "Names match in any case,
/// but formats must match exactly. Doubled brackets print one bracket, so
/// `[[Time]]` prints `[Time]` (UX spec). Brackets around anything that isn't
/// a v1 name print as written, so a lyric's `[Chorus]` or `[x2]` shows
/// unchanged ... (choice T-1). A timer or popup number above the machine's
/// count is still a v1 name."
///
/// The reading, left to right: `[[` prints `[` and `]]` prints `]`; a `[`,
/// then text with no bracket in it, then `]` is a variable when that text is
/// a v1 name, and prints as written when it isn't; an unclosed `[` prints as
/// written. A v1 name is the table's words in any case, single-spaced, with
/// `N` one or more digits and at least 1; after it come nothing, or a space
/// and the format, matched exactly when it resolves; a final `overrun` is
/// taken off first.
public struct VariableText: Hashable, Sendable {
    public var segments: [VariableSegment]

    public init(segments: [VariableSegment]) {
        self.segments = segments
    }

    /// Spec 6 §5 — the variables of `text`, in order, and the text around them.
    public static func parse(_ text: String) -> VariableText {
        // Text with no bracket is all text, the usual case for a lyric.
        guard text.contains(where: { $0 == "[" || $0 == "]" }) else {
            return VariableText(segments: text.isEmpty ? [] : [.text(text)])
        }
        let chars = Array(text)
        var segments: [VariableSegment] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { segments.append(.text(literal)) }
            literal = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "[" {
                if i + 1 < chars.count, chars[i + 1] == "[" {
                    literal.append("[")
                    i += 2
                    continue
                }
                var j = i + 1
                var inner = ""
                var closed = false
                while j < chars.count {
                    if chars[j] == "]" { closed = true; break }
                    if chars[j] == "[" { break }
                    inner.append(chars[j])
                    j += 1
                }
                guard closed else {
                    literal.append("[")
                    i += 1
                    continue
                }
                let written = "[" + inner + "]"
                if let token = token(inner, written: written) {
                    flush()
                    segments.append(.variable(token))
                } else {
                    literal += written
                }
                i = j + 1
                continue
            }
            if c == "]", i + 1 < chars.count, chars[i + 1] == "]" {
                literal.append("]")
                i += 2
                continue
            }
            literal.append(c)
            i += 1
        }
        flush()
        return VariableText(segments: segments)
    }

    /// The variables, in order.
    public var tokens: [VariableToken] {
        segments.compactMap { if case .variable(let token) = $0 { return token } else { return nil } }
    }

    /// Whether the text names any v1 variable.
    public var hasVariables: Bool {
        segments.contains { if case .variable = $0 { return true } else { return false } }
    }

    /// Spec 6 §4 — whether the text itself names `[Time]`, `[Timer N]` or
    /// `[Service In]` (a popup it shows is the resolver's to look into).
    public var asksForTabularDigits: Bool {
        tokens.contains { $0.name.asksForTabularDigits }
    }

    /// One v1 variable from the text between its brackets, or nil when that
    /// text is not a v1 name.
    static func token(_ inner: String, written: String) -> VariableToken? {
        let words = inner.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        func second(_ word: String) -> Bool { words.count >= 2 && words[1].lowercased() == word }
        let name: VariableName
        let used: Int
        switch first {
        case "time": name = .time; used = 1
        case "date": name = .date; used = 1
        case "timer", "popup":
            guard words.count >= 2, let n = slotNumber(words[1]) else { return nil }
            name = first == "timer" ? .timer(n) : .popup(n)
            used = 2
        case "live": guard second("title") else { return nil }; name = .liveTitle; used = 2
        case "next": guard second("title") else { return nil }; name = .nextTitle; used = 2
        case "section": name = .section; used = 1
        case "cue": guard second("note") else { return nil }; name = .cueNote; used = 2
        case "copyright": name = .copyright; used = 1
        case "ccli": name = .ccli; used = 1
        case "service": guard second("in") else { return nil }; name = .serviceIn; used = 2
        default: return nil
        }
        var rest = Array(words[used...])
        var overrun = false
        if let last = rest.last, last.lowercased() == "overrun" {
            overrun = true
            rest.removeLast()
        }
        let format: String? = rest.isEmpty ? nil : rest.joined(separator: " ")
        return VariableToken(name: name, format: format, overrun: overrun, written: written)
    }

    /// A slot number: one or more ASCII digits worth 1 or more. A number too
    /// large to hold is above every count.
    static func slotNumber(_ word: String) -> Int? {
        guard !word.isEmpty, word.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        var value = 0
        for c in word {
            guard let digit = c.wholeNumberValue else { return nil }
            let (times, o1) = value.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times.addingReportingOverflow(digit)
            if o1 || o2 { return Int.max }
            value = sum
        }
        return value >= 1 ? value : nil
    }
}
