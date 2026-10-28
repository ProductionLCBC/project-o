// OCore — Spec 2 §2, tokens of the canonical text grammar.

/// Spec 2 §2 — "Words are separated by spaces; case is ignored for keywords
/// and significant inside quoted strings." A token is a word (a keyword, a
/// ref, a clock duration, a date), a number (integer or decimal, as written),
/// a string (double-quoted, JSON escapes, already unescaped) or a bracketed
/// value name for guards (`[Timer 1]`, Spec 2 §7).
public enum CommandToken: Equatable, Sendable {
    case word(String)
    case number(String)
    case string(String)
    case bracket(String)

    /// How the token reads in a rejection message.
    var described: String {
        switch self {
        case .word(let w): return w
        case .number(let n): return n
        case .string(let s):
            var out = ""
            JSONCanonical.writeString(s, into: &out)
            return out
        case .bracket(let b): return "[\(b)]"
        }
    }
}

/// A token with where it sits in the line, so the reserved `edit` form can
/// take the rest of the line verbatim.
struct TokenSpan: Equatable, Sendable {
    let token: CommandToken
    let start: String.Index
    let end: String.Index
}

/// Spec 2 §2 — the tokenizer. Strings are parsed by the format's own JSON
/// string rules (Spec 1 §5), so the escapes are exactly JSON's.
enum CommandTokenizer {
    static func tokenize(_ text: String) throws -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                i = text.index(after: i)
                continue
            }
            let start = i
            if c == "\"" {
                var j = text.index(after: i)
                var closed = false
                while j < text.endIndex {
                    let d = text[j]
                    if d == "\\" {
                        j = text.index(after: j)
                        if j < text.endIndex { j = text.index(after: j) }
                        continue
                    }
                    if d == "\"" {
                        closed = true
                        j = text.index(after: j)
                        break
                    }
                    j = text.index(after: j)
                }
                guard closed else {
                    throw Rejection(reason: .malformed, message: "unterminated string: \(text[start...])")
                }
                let raw = String(text[start..<j])
                let value: JSONValue
                do {
                    value = try JSONValue.parse(raw)
                } catch let error as JSONParseError {
                    throw Rejection(reason: .malformed, message: "bad string \(raw): \(error.message)")
                }
                guard case .string(let s) = value else {
                    throw Rejection(reason: .malformed, message: "bad string \(raw)")
                }
                spans.append(TokenSpan(token: .string(s), start: start, end: j))
                i = j
                continue
            }
            if c == "[" {
                guard let close = text[i...].firstIndex(of: "]") else {
                    throw Rejection(reason: .malformed, message: "unterminated [ ]: \(text[start...])")
                }
                let inner = text[text.index(after: i)..<close]
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                let end = text.index(after: close)
                spans.append(TokenSpan(token: .bracket(inner), start: start, end: end))
                i = end
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace {
                j = text.index(after: j)
            }
            let lexeme = String(text[i..<j])
            spans.append(TokenSpan(token: isNumber(lexeme) ? .number(lexeme) : .word(lexeme), start: i, end: j))
            i = j
        }
        return spans
    }

    /// Spec 2 §2 — integer: "digits, optional sign"; decimal: "digits with a point".
    static func isNumber(_ lexeme: String) -> Bool {
        var rest = Substring(lexeme)
        if rest.first == "-" || rest.first == "+" { rest = rest.dropFirst() }
        let pieces = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return false }
        return pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(DurationText.isDigit) }
    }
}
