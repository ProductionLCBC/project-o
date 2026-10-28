// OCore — Spec 2 §7, guards.

/// Spec 2 §7 — `operator := is | is not | greater than | less than`, plus the
/// `is empty` and `is not empty` forms.
public enum GuardOperator: String, Codable, Equatable, Sendable {
    case `is` = "is"
    case isNot = "is not"
    case greaterThan = "greater than"
    case lessThan = "less than"
    case isEmpty = "is empty"
    case isNotEmpty = "is not empty"
}

/// Spec 2 §7 — "In the object form a guard is a `when` field:
/// `{"var": "Timer 1", "op": "is", "value": "0:00"}`." `var` is the readable
/// value's name without its brackets.
public struct Guard: Codable, Equatable, Sendable {
    public var variable: String
    public var op: GuardOperator
    public var value: String?
    public var extra: [String: JSONValue]

    public init(variable: String, op: GuardOperator, value: String? = nil, extra: [String: JSONValue] = [:]) {
        self.variable = variable
        self.op = op
        self.value = value
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case variable = "var"
        case op
        case value
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variable = try c.decode(String.self, forKey: .variable)
        op = try c.decode(GuardOperator.self, forKey: .op)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(variable, forKey: .variable)
        try c.encode(op, forKey: .op)
        try c.encodeIfPresent(value, forKey: .value)
    }

    /// Spec 2 §7 — "Values compare as durations when both sides parse as
    /// durations, as numbers when both parse as numbers, otherwise as
    /// case-insensitive strings." `actual` is nil when the value is unset,
    /// which is what `is empty` tests.
    public func holds(actual: String?) -> Bool {
        let actualText = actual ?? ""
        switch op {
        case .isEmpty:
            return actualText.isEmpty
        case .isNotEmpty:
            return !actualText.isEmpty
        case .is:
            return Guard.compare(actualText, value ?? "") == 0
        case .isNot:
            return Guard.compare(actualText, value ?? "") != 0
        case .greaterThan:
            return Guard.compare(actualText, value ?? "") > 0
        case .lessThan:
            return Guard.compare(actualText, value ?? "") < 0
        }
    }

    /// Three-way comparison following the Spec 2 §7 rules.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        if let l = Guard.durationMs(lhs), let r = Guard.durationMs(rhs) {
            return l == r ? 0 : (l < r ? -1 : 1)
        }
        if let l = Double(lhs), let r = Double(rhs) {
            return l == r ? 0 : (l < r ? -1 : 1)
        }
        let l = lhs.lowercased(), r = rhs.lowercased()
        return l == r ? 0 : (l < r ? -1 : 1)
    }

    /// Spec 2 §2 — a duration is `MM:SS`, `H:MM:SS`, or a number of seconds.
    /// Returns milliseconds, or nil when the text is not a duration.
    public static func durationMs(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.count <= 3 else {
            guard let seconds = Double(text) else { return nil }
            return Int((seconds * 1000).rounded())
        }
        var total = 0.0
        for part in parts {
            guard let n = Double(part), n >= 0 else { return nil }
            total = total * 60 + n
        }
        return Int((total * 1000).rounded())
    }

    // MARK: - Spec 1 §4, the numbers a guard's value names

    /// Spec 2 §7 — `[Channel N ...]`, `[Output N Stack]` and `[Stack N
    /// Blackout]` name objects by number, so renumbering rewrites them (Spec 1
    /// §4). Timers and popups are slots, not objects.
    public func mapReferences(_ transform: (NumberedType, Int) -> Int) -> Guard {
        let words = variable.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count >= 3, let number = Int(words[1]) else { return self }
        let type: NumberedType?
        switch words[0].lowercased() {
        case "channel": type = .channel
        case "output": type = .output
        case "stack": type = .stack
        default: type = nil
        }
        guard let type else { return self }
        var copy = self
        var rewritten = words
        rewritten[1] = String(transform(type, number))
        copy.variable = rewritten.joined(separator: " ")
        return copy
    }

    public func forEachReference(of type: NumberedType, _ body: (Int) -> Void) {
        _ = mapReferences { found, number in
            if found == type { body(number) }
            return number
        }
    }
}
