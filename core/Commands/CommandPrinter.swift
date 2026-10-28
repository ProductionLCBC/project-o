// OCore — Spec 2 §4, the canonical text grammar: printing.

import Foundation

extension CommandText {
    /// Spec 2 §4 — "Printing is canonical: lowercase keywords, one space
    /// between tokens, full hashes, riders in the fixed order transition,
    /// audiotransition, grade, gain, chase, build." Nil for a command the
    /// vocabulary does not know (Spec 1 §6 keeps those verbatim as objects).
    public static func print(_ command: Command) -> String? {
        CommandPrinter.print(command)
    }

    /// Spec 2 §7 — a guarded command: the `when` clause, then the command.
    public static func print(_ entry: GuardedCommand) -> String? {
        guard let command = print(entry.command) else { return nil }
        guard let condition = entry.when else { return command }
        return print(condition) + " " + command
    }

    /// Spec 2 §7 — `when VALUE OPERATOR CONSTANT | when VALUE is empty | when
    /// VALUE is not empty`.
    public static func print(_ condition: Guard) -> String {
        var out = "when [\(condition.variable)] \(condition.op.rawValue)"
        if let value = condition.value, condition.op != .isEmpty, condition.op != .isNotEmpty {
            out += " " + CommandPrinter.guardValueText(value)
        }
        return out
    }
}

enum CommandPrinter {
    static func print(_ command: Command) -> String? {
        switch command {
        case .unknown, .invalid:
            return nil
        case .channelWrite(let write):
            return printWrite(write)
        case .edit(let edit):
            return printEdit(edit)
        default:
            break
        }
        guard let row = Vocabulary.row(cmd: command.cmd),
              let object = (try? JSONCoding.encode(command))?.objectValue else { return nil }
        var words = head(row, object)
        for arg in row.args {
            words.append(contentsOf: argumentWords(arg, object))
        }
        return words.joined(separator: " ")
    }

    /// The target, its number and the verb: the words that become the OSC
    /// address (Spec 2 §6).
    static func head(_ row: VocabularyRow, _ object: [String: JSONValue]) -> [String] {
        var words = [row.target]
        if let key = row.number.key, let value = object[key] {
            words.append(numberText(value))
        }
        switch row.verb {
        case .word(let verb): words.append(verb)
        case .fromKey(let key, _): words.append(object[key]?.stringValue ?? "")
        case .lock(let key): words.append(object[key]?.boolValue == true ? "lock" : "unlock")
        case .none: break
        }
        return words
    }

    static func numberText(_ value: JSONValue) -> String {
        if let n = value.intValue { return String(n) }
        return value.stringValue ?? ""
    }

    static func argumentWords(_ arg: VocabularyRow.Arg, _ object: [String: JSONValue]) -> [String] {
        guard let value = object[arg.key] else { return [] }
        switch arg.kind {
        case .int:
            return [numberText(value)]
        case .decimal:
            return [decimalText(value.doubleValue ?? 0)]
        case .duration(let style), .optionalDuration(let style):
            return [DurationText.text(ms: value.intValue ?? 0, style: style)]
        case .string:
            return [quoted(value.stringValue ?? "")]
        case .optionalString:
            let s = value.stringValue ?? ""
            return [isBareWord(s) ? s : quoted(s)]
        case .keyword:
            return [value.stringValue ?? ""]
        case .optionalKeywordSeconds(let word):
            return [word, secondsText(ms: value.intValue ?? 0)]
        case .write, .edit:
            return []
        }
    }

    // MARK: - Spec 2 §2, the write form

    static func printWrite(_ write: ChannelWrite) -> String {
        var words = ["channel", targetText(write.channel), "write"]
        var riders = write.riders
        switch write.content {
        case .media(let m):
            words += ["media", m.ref]
            if let v = m.inMs { words += ["in", DurationText.text(ms: v, style: .clock)] }
            if let v = m.outMs { words += ["out", DurationText.text(ms: v, style: .clock)] }
            if m.loop { words.append("loop") }
            if let g = m.gain { words += ["gain", decimalText(g)] }
            if let s = m.syncOffsetMs { words += ["sync", String(s)] }
        case .text(let fields):
            words.append("text")
            if fields.count == 1, let body = fields["body"] {
                words.append(quoted(body))
            } else {
                for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                    words.append(isBareWord(key) ? key : quoted(key))
                    words.append(quoted(value))
                }
            }
        case .slide(let ref, let build):
            // Area 3 plan, decision 4: a slide's build belongs to the content.
            words.append(ref)
            if let b = build ?? riders.build { words += ["build", String(b)] }
            if build == nil { riders.build = nil }
        case .input(let n):
            words += ["input", String(n)]
        case .empty:
            words.append("empty")
        }
        if let t = riders.transition {
            words += ["transition", String(t.ref)]
            if let ms = t.ms { words.append(DurationText.text(ms: ms, style: .seconds)) }
            words.append(t.scope.rawValue)
        }
        if let t = riders.audioTransition {
            words += ["audiotransition", String(t.ref)]
            if let ms = t.ms { words.append(DurationText.text(ms: ms, style: .seconds)) }
            words.append(t.scope.rawValue)
        }
        if let g = riders.grade {
            words += ["grade", String(g.ref)]
            if let ms = g.ms { words.append(DurationText.text(ms: ms, style: .seconds)) }
            words.append(g.scope.rawValue)
        }
        if let g = riders.gain {
            words += ["gain", decimalText(g.db), g.scope.rawValue]
        }
        if let c = riders.chase {
            words += ["chase", c.scope.rawValue]
        }
        if let b = riders.build {
            words += ["build", String(b)]
        }
        return words.joined(separator: " ")
    }

    static func targetText(_ target: Target) -> String {
        switch target {
        case .number(let n): return String(n)
        case .all: return "all"
        }
    }

    // MARK: - Spec 2 §3, the reserved edit form

    static func printEdit(_ edit: EditCommand) -> String {
        let value: String
        switch edit.value {
        case nil, .null?: value = "null"
        case .string(let s)?: value = quoted(s)
        case .number(let n)?: value = decimalText(n)
        case .bool(let b)?: value = b ? "true" : "false"
        case .array?, .object?: value = JSONCanonical.line(edit.value ?? .null)
        }
        return ["edit", edit.target, String(edit.number), edit.field, value].joined(separator: " ")
    }

    // MARK: - Pieces

    /// Spec 2 §4 — "Strings are JSON strings in both forms; the text form
    /// escapes them the same way JSON does."
    static func quoted(_ s: String) -> String {
        var out = ""
        JSONCanonical.writeString(s, into: &out)
        return out
    }

    /// A word that reads back as the same single word token.
    static func isBareWord(_ s: String) -> Bool {
        !s.isEmpty && !CommandTokenizer.isNumber(s) && s.allSatisfy {
            $0.isLetter || DurationText.isDigit($0) || $0 == "_" || $0 == "-" || $0 == "." || $0 == ":"
        }
    }

    /// Spec 2 §2 — decimal: integral values print without a point.
    static func decimalText(_ x: Double) -> String {
        guard x.isFinite else { return "0" }
        if x == x.rounded(), abs(x) < 9_007_199_254_740_992 {
            return String(Int64(x))
        }
        let shortest = x.description
        if !shortest.contains("e") && !shortest.contains("E") { return shortest }
        var fixed = String(format: "%.9f", x)
        while fixed.hasSuffix("0") { fixed.removeLast() }
        if fixed.hasSuffix(".") { fixed.removeLast() }
        return fixed
    }

    /// `clearafter SECONDS`: whole seconds, or decimal seconds when not whole.
    static func secondsText(ms: Int) -> String {
        ms % 1000 == 0 ? String(ms / 1000) : decimalText(Double(ms) / 1000)
    }

    /// Spec 2 §7 — a guard's constant prints bare when it reads back as one
    /// token and is not a keyword of the guard grammar; otherwise quoted.
    static func guardValueText(_ value: String) -> String {
        let lower = value.lowercased()
        let plain = !value.isEmpty && lower != "empty" && lower != "not"
            && !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "[" || $0 == "]" || $0 == "\\" })
        return plain ? value : quoted(value)
    }
}
