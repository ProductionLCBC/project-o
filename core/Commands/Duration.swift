// OCore — Spec 2 §2, the duration token.

/// Spec 2 §2 — duration: "`MM:SS`, `H:MM:SS`, or a number of seconds; written
/// to the object as ms". Spec 2 §4 — "Durations are written in text as `MM:SS`
/// or seconds and stored as integer `ms`."
///
/// Reading of the spec (Area 3 plan, decision 1): the canonical spelling
/// depends on the field. Positions in media and timers print clock style
/// (`0:02`, `5:00`, `1:02:03`, `0:01.5`); transition, audio transition and
/// grade durations print as seconds with a decimal point (`1.0`, `0.5`,
/// `1.25`). Every spelling parses anywhere.
public enum DurationText {
    /// Which canonical spelling a field uses.
    public enum Style: Equatable, Sendable {
        case clock
        case seconds
    }

    /// The milliseconds a duration token names, or nil when the text is not
    /// a duration: a negative number, a seconds part of 60 or more, an
    /// exponent, or anything that is not digits, a point and colons.
    public static func ms(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return secondsMs(parts[0])
        case 2, 3:
            var minutes = 0
            for i in 0..<(parts.count - 1) {
                guard let n = digits(parts[i]) else { return nil }
                if parts.count == 3, i == 1, n >= 60 { return nil }
                minutes = minutes * 60 + n
            }
            guard let last = parts.last, let secondsMs = secondsMs(last), secondsMs < 60_000 else { return nil }
            return minutes * 60_000 + secondsMs
        default:
            return nil
        }
    }

    /// The canonical text of a duration in the given style.
    public static func text(ms: Int, style: Style) -> String {
        if ms < 0 { return "-" + text(ms: -ms, style: style) }
        let whole = ms / 1000
        let fraction = ms % 1000
        switch style {
        case .seconds:
            return "\(whole)." + (fraction == 0 ? "0" : trimmedFraction(fraction))
        case .clock:
            let hours = whole / 3600
            let minutes = (whole % 3600) / 60
            let seconds = whole % 60
            let base = hours > 0 ? "\(hours):\(pad2(minutes)):\(pad2(seconds))" : "\(minutes):\(pad2(seconds))"
            return fraction == 0 ? base : base + "." + trimmedFraction(fraction)
        }
    }

    // MARK: - Pieces

    static func isDigit(_ c: Character) -> Bool {
        c >= "0" && c <= "9"
    }

    /// A run of digits as a number; nil for anything else.
    static func digits(_ s: Substring) -> Int? {
        guard !s.isEmpty, s.allSatisfy(isDigit) else { return nil }
        return Int(s)
    }

    /// Seconds with an optional fraction, as milliseconds rounded to the
    /// nearest millisecond.
    static func secondsMs(_ s: Substring) -> Int? {
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, let whole = digits(pieces[0]) else { return nil }
        var ms = whole * 1000
        if pieces.count == 2 {
            let fraction = pieces[1]
            guard !fraction.isEmpty, fraction.allSatisfy(isDigit) else { return nil }
            var value = 0
            var count = 0
            for c in fraction.prefix(3) {
                value = value * 10 + Int(String(c), radix: 10)!
                count += 1
            }
            while count < 3 {
                value *= 10
                count += 1
            }
            if fraction.count > 3 {
                let fourth = fraction[fraction.index(fraction.startIndex, offsetBy: 3)]
                if fourth >= "5" { value += 1 }
            }
            ms += value
        }
        return ms
    }

    static func pad2(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }

    /// A millisecond fraction as one to three digits, trailing zeros removed.
    static func trimmedFraction(_ fraction: Int) -> String {
        var text = String(fraction)
        while text.count < 3 { text = "0" + text }
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }
}
