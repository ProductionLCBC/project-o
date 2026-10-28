// OCore — Spec 2 §2 and §4, the canonical text grammar: parsing.

import Foundation

/// Spec 2 §2 and §4 — what the parser needs besides the text: the media ids
/// it may expand an abbreviated hash against ("Hashes may be abbreviated to
/// their first 12 hex characters in the command bar and are expanded on
/// parse; stored and logged forms are always full").
public struct ParseOptions: Sendable {
    public var mediaIDs: Set<String>

    public init(mediaIDs: Set<String> = []) {
        self.mediaIDs = mediaIDs
    }
}

/// Spec 2 §4 — "One function each way, and `parse(print(x)) == x` for every
/// object." `parse` reads one line of the canonical grammar (Spec 2 §2), with
/// an optional `when` guard in front (Spec 2 §7); `print` is in
/// `CommandPrinter.swift`.
public enum CommandText {
    /// Spec 2 §2 — parse one line. "Any accepted spelling parses": keywords
    /// in any case, the short forms of §4, both duration spellings.
    public static func parse(_ text: String, options: ParseOptions = ParseOptions()) -> Result<GuardedCommand, Rejection> {
        do {
            var parser = CommandParser(text: text, options: options)
            return .success(try parser.parseLine())
        } catch let rejection as Rejection {
            return .failure(rejection)
        } catch {
            return .failure(Rejection(reason: .malformed, message: "\(error)"))
        }
    }
}

/// A recursive-descent parser over the tokens of one line.
struct CommandParser {
    let text: String
    let options: ParseOptions
    var tokens: [TokenSpan] = []
    var index = 0

    init(text: String, options: ParseOptions) {
        self.text = text
        self.options = options
    }

    // MARK: - Cursor

    func token(at offset: Int = 0) -> CommandToken? {
        let i = index + offset
        return i >= 0 && i < tokens.count ? tokens[i].token : nil
    }

    func peek() -> CommandToken? { token(at: 0) }

    func peekWordLower() -> String? {
        if case .word(let w)? = peek() { return w.lowercased() }
        return nil
    }

    mutating func advance() { index += 1 }

    mutating func next() -> CommandToken? {
        guard let t = peek() else { return nil }
        index += 1
        return t
    }

    func reject(_ reason: RejectionReason, _ message: String) -> Rejection {
        Rejection(reason: reason, message: message)
    }

    // MARK: - Spec 2 §2, the line

    mutating func parseLine() throws -> GuardedCommand {
        tokens = try CommandTokenizer.tokenize(text)
        guard !tokens.isEmpty else { throw reject(.malformed, "nothing to parse") }
        var condition: Guard?
        if peekWordLower() == "when" {
            advance()
            condition = try parseGuard()
            guard peek() != nil else { throw reject(.missingArgument, "a guard needs a command after it") }
        }
        let command = try parseCommand()
        if let extra = peek() {
            throw reject(.unexpectedToken, "unexpected \(extra.described) after the command")
        }
        return GuardedCommand(command, when: condition)
    }

    // MARK: - Spec 2 §7, guards

    /// `guard := when VALUE OPERATOR CONSTANT | when VALUE is empty | when VALUE is not empty`.
    mutating func parseGuard() throws -> Guard {
        guard let first = next() else { throw reject(.missingArgument, "when needs a [value] to read") }
        guard case .bracket(let variable) = first, !variable.isEmpty else {
            throw reject(.badArgument, "when needs a [value] in brackets, not \(first.described)")
        }
        guard let operatorToken = next() else { throw reject(.missingArgument, "the guard needs an operator: is, is not, greater than, less than") }
        guard case .word(let w) = operatorToken else {
            throw reject(.badArgument, "\(operatorToken.described) is not a guard operator (is, is not, greater than, less than)")
        }
        let op: GuardOperator
        var value: String?
        switch w.lowercased() {
        case "is":
            if peekWordLower() == "not" {
                advance()
                if peekWordLower() == "empty" {
                    advance()
                    op = .isNotEmpty
                } else {
                    op = .isNot
                    value = try guardConstant()
                }
            } else if peekWordLower() == "empty" {
                advance()
                op = .isEmpty
            } else {
                op = .is
                value = try guardConstant()
            }
        case "greater":
            try expectWord("than", after: "greater")
            op = .greaterThan
            value = try guardConstant()
        case "less":
            try expectWord("than", after: "less")
            op = .lessThan
            value = try guardConstant()
        default:
            throw reject(.badArgument, "\(w) is not a guard operator (is, is not, greater than, less than)")
        }
        return Guard(variable: variable, op: op, value: value)
    }

    mutating func expectWord(_ word: String, after previous: String) throws {
        guard let t = next() else { throw reject(.missingArgument, "expected \(word) after \(previous)") }
        guard case .word(let w) = t, w.lowercased() == word else {
            throw reject(.badArgument, "expected \(word) after \(previous), not \(t.described)")
        }
    }

    /// The constant a guard compares with: one token, as written.
    mutating func guardConstant() throws -> String {
        guard let t = next() else { throw reject(.missingArgument, "the guard needs a value to compare with") }
        switch t {
        case .string(let s): return s
        case .number(let n): return n
        case .word(let w): return w
        case .bracket(let b): return "[\(b)]"
        }
    }

    // MARK: - Spec 2 §2, `command := target [number] verb [argument...] [rider...]`

    mutating func parseCommand() throws -> Command {
        guard let first = next() else { throw reject(.malformed, "nothing to parse") }
        switch first {
        case .number(let lexeme):
            // Spec 2 §4 — "a bare cue number in the live list (`7` for `cue 7`)".
            guard let n = Int(lexeme), n >= 1 else {
                throw reject(.badArgument, "a bare number is a cue number and must be 1 or more, not \(lexeme)")
            }
            return .cue(n)
        case .word(let w):
            let target = Vocabulary.canonicalTarget(w.lowercased())
            guard Vocabulary.targets.contains(target) else {
                throw reject(.unknownTarget, "\(w) is not a target")
            }
            return try parseTarget(target)
        default:
            throw reject(.unknownTarget, "\(first.described) is not a target")
        }
    }

    mutating func parseTarget(_ target: String) throws -> Command {
        let rows = Vocabulary.rows(target: target)
        guard let sample = rows.first else { throw reject(.unknownTarget, "\(target) is not a target") }
        var object: [String: JSONValue] = [:]

        // Spec 2 §3 — "`N` is a channel number or the word `all`."
        switch sample.number {
        case .none:
            break
        case .int(let key), .target(let key):
            guard let t = next() else { throw reject(.missingArgument, "\(target) needs a number") }
            switch t {
            case .number(let lexeme):
                guard let n = Int(lexeme), n >= 1 else {
                    throw reject(.badArgument, "a \(target) number must be 1 or more, not \(lexeme)")
                }
                object[key] = .number(Double(n))
            case .word(let w) where w.lowercased() == "all":
                guard case .target = sample.number else {
                    throw reject(.badArgument, "\(target) takes a number, not all")
                }
                object[key] = .string("all")
            default:
                throw reject(.badArgument, "expected a \(target) number, not \(t.described)")
            }
        }

        // The verb.
        let row: VocabularyRow
        if rows.contains(where: \.hasVerb) {
            guard let t = next() else { throw reject(.missingArgument, "\(target) needs a verb") }
            guard case .word(let w) = t else { throw reject(.unknownVerb, "\(t.described) is not a \(target) verb") }
            let verb = Vocabulary.canonicalVerb(w.lowercased(), target: target)
            guard let found = Vocabulary.row(target: target, verb: verb) else {
                throw reject(.unknownVerb, "\(w) is not a \(target) verb")
            }
            row = found
            switch row.verb {
            case .fromKey(let key, _): object[key] = .string(verb)
            case .lock(let key): object[key] = .bool(verb == "lock")
            case .word, .none: break
            }
        } else {
            row = sample
        }
        object["cmd"] = .string(row.cmd)

        // The arguments.
        switch row.args.first?.kind {
        case .write?:
            try parseWrite(into: &object)
        case .edit?:
            try parseEdit(into: &object)
        default:
            for arg in row.args {
                try parseArgument(arg, into: &object)
            }
        }

        // Spec 3 §3 rule 2 — a standalone attribute write is always tracked.
        if row.standaloneAttribute, let w = peekWordLower() {
            if w == "track" {
                advance()
            } else if w == "once" {
                throw reject(.badArgument, "a standalone attribute write is always tracked (Spec 3 §3); for once, put the rider on a write")
            }
        }
        return try decode(object)
    }

    /// The object form, decoded by the same decoder a file goes through.
    func decode(_ object: [String: JSONValue]) throws -> Command {
        let command: Command
        do {
            command = try JSONCoding.decode(Command.self, from: .object(object))
        } catch {
            throw reject(.malformed, JSONCoding.describe(error))
        }
        if command.isUnknown || command.isInvalid {
            throw reject(.malformed, command.invalidReason ?? "the parameters did not decode")
        }
        return command
    }

    // MARK: - Arguments by kind

    mutating func parseArgument(_ arg: VocabularyRow.Arg, into object: inout [String: JSONValue]) throws {
        switch arg.kind {
        case .int:
            object[arg.key] = .number(Double(try intToken(what: "\(arg.key) needs a whole number")))
        case .decimal:
            object[arg.key] = .number(try decimalToken(what: "\(arg.key) needs a number"))
        case .duration(let style):
            guard let t = next() else {
                throw reject(.missingArgument, "expected a duration (\(DurationText.text(ms: 90_000, style: style)) or seconds)")
            }
            guard let ms = durationMs(t) else {
                throw reject(.badArgument, "\(t.described) is not a duration; write MM:SS, H:MM:SS or seconds")
            }
            object[arg.key] = .number(Double(ms))
        case .optionalDuration:
            if let t = peek(), !isScopeWord(t), let ms = durationMs(t) {
                advance()
                object[arg.key] = .number(Double(ms))
            }
        case .string:
            guard let t = next() else { throw reject(.missingArgument, "\(arg.key) needs a quoted string") }
            guard case .string(let s) = t else { throw reject(.badArgument, "\(arg.key) must be a quoted string, not \(t.described)") }
            object[arg.key] = .string(s)
        case .optionalString:
            switch peek() {
            case .word(let w)?:
                advance()
                object[arg.key] = .string(w)
            case .string(let s)?:
                advance()
                object[arg.key] = .string(s)
            default:
                break
            }
        case .keyword(let values):
            let choices = values.joined(separator: ", ")
            guard let t = next() else { throw reject(.missingArgument, "expected one of \(choices)") }
            guard case .word(let w) = t, values.contains(w.lowercased()) else {
                throw reject(.badArgument, "expected one of \(choices), not \(t.described)")
            }
            object[arg.key] = .string(w.lowercased())
        case .optionalKeywordSeconds(let word):
            guard peekWordLower() == word else { return }
            advance()
            guard let t = next() else { throw reject(.missingArgument, "\(word) needs a number of seconds") }
            guard case .number(let lexeme) = t, let seconds = Double(lexeme) else {
                throw reject(.badArgument, "\(word) needs a number of seconds, not \(t.described)")
            }
            object[arg.key] = .number((seconds * 1000).rounded())
        case .write, .edit:
            break
        }
    }

    mutating func intToken(what: String) throws -> Int {
        guard let t = next() else { throw reject(.missingArgument, what) }
        guard case .number(let lexeme) = t, let n = Int(lexeme) else {
            throw reject(.badArgument, "\(what), not \(t.described)")
        }
        return n
    }

    mutating func decimalToken(what: String) throws -> Double {
        guard let t = next() else { throw reject(.missingArgument, what) }
        guard case .number(let lexeme) = t, let d = Double(lexeme) else {
            throw reject(.badArgument, "\(what), not \(t.described)")
        }
        return d
    }

    /// Spec 2 §2 — a duration is a number (seconds) or a clock word.
    func durationMs(_ token: CommandToken) -> Int? {
        switch token {
        case .number(let lexeme), .word(let lexeme): return DurationText.ms(lexeme)
        default: return nil
        }
    }

    func isScopeWord(_ token: CommandToken) -> Bool {
        if case .word(let w) = token { return w.lowercased() == "once" || w.lowercased() == "track" }
        return false
    }

    // MARK: - Spec 2 §2, content expressions

    /// `media sha256:... [in DURATION] [out DURATION] [loop] [gain DECIBELS]
    /// [sync MS]`, `text "..."`, `text body "..." title "..."`,
    /// `slide:<uuid> [build N]`, `input N`, or `empty`.
    mutating func parseWrite(into object: inout [String: JSONValue]) throws {
        guard let t = next() else { throw reject(.missingArgument, "write needs content: media, text, slide:, input or empty") }
        guard case .word(let w) = t else {
            throw reject(.badArgument, "expected content (media, text, slide:, input or empty), not \(t.described)")
        }
        let lower = w.lowercased()
        let content: [String: JSONValue]
        if lower == "media" {
            content = try parseMediaContent()
        } else if lower == "text" {
            content = try parseTextContent()
        } else if lower.hasPrefix(MediaID.slidePrefix) {
            content = try parseSlideContent(w)
        } else if lower == "input" {
            content = ["kind": .string("input"), "input": .number(Double(try intToken(what: "input needs a number")))]
        } else if lower == "empty" {
            content = ["kind": .string("empty")]
        } else {
            throw reject(.badArgument, "\(w) is not content; expected media, text, slide:, input or empty")
        }
        object["content"] = .object(content)
        try parseRiders(into: &object)
    }

    mutating func parseMediaContent() throws -> [String: JSONValue] {
        guard let t = next() else { throw reject(.missingArgument, "media needs an id (sha256:...)") }
        guard case .word(let w) = t else { throw reject(.badArgument, "media needs an id (sha256:...), not \(t.described)") }
        var content: [String: JSONValue] = ["kind": .string("media"), "ref": .string(try mediaRef(w))]
        loop: while let option = peekWordLower() {
            switch option {
            case "in", "out":
                guard content[option] == nil else { throw reject(.duplicateOption, "\(option) given twice") }
                advance()
                guard let d = next() else { throw reject(.missingArgument, "\(option) needs a duration") }
                guard let ms = durationMs(d) else { throw reject(.badArgument, "\(option) needs a duration, not \(d.described)") }
                content[option] = .number(Double(ms))
            case "loop":
                guard content["loop"] == nil else { throw reject(.duplicateOption, "loop given twice") }
                advance()
                content["loop"] = .bool(true)
            case "gain":
                // Area 3 plan, decision 3: `gain DB` followed by a scope is the rider.
                guard case .number(let lexeme)? = token(at: 1) else { break loop }
                if let after = token(at: 2), isScopeWord(after) { break loop }
                guard content["gain"] == nil else { throw reject(.duplicateOption, "gain given twice") }
                guard let db = Double(lexeme) else { throw reject(.badArgument, "gain needs a number in decibels, not \(lexeme)") }
                advance()
                advance()
                content["gain"] = .number(db)
            case "sync":
                guard content["syncOffsetMs"] == nil else { throw reject(.duplicateOption, "sync given twice") }
                advance()
                content["syncOffsetMs"] = .number(Double(try intToken(what: "sync needs a number of milliseconds")))
            default:
                break loop
            }
        }
        return content
    }

    /// Spec 1 §4 — a media id is `sha256:` and 64 lowercase hex characters;
    /// Spec 2 §2 — "Hashes may be abbreviated to their first 12 hex characters".
    func mediaRef(_ word: String) throws -> String {
        let lower = word.lowercased()
        guard lower.hasPrefix(MediaID.hashPrefix) else {
            throw reject(.badArgument, "\(word) is not a media id (sha256:<hex>)")
        }
        let hex = String(lower.dropFirst(MediaID.hashPrefix.count))
        guard !hex.isEmpty, hex.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }) else {
            throw reject(.badArgument, "\(word) is not a media id: the hash is not hex")
        }
        if hex.count == 64 { return MediaID.hashPrefix + hex }
        guard hex.count >= 12, hex.count < 64 else {
            throw reject(.badArgument, "\(word) is not a media id: a hash is 64 hex characters, or at least 12 to abbreviate")
        }
        let matches = options.mediaIDs.filter { $0.hasPrefix(MediaID.hashPrefix + hex) }.sorted()
        if matches.count == 1, let only = matches.first { return only }
        if matches.isEmpty {
            throw reject(.unknownMedia, "abbreviated id \(word) matches no media id the parser was given")
        }
        throw reject(.ambiguousMedia, "abbreviated id \(word) matches \(matches.count) media ids; give more characters")
    }

    /// `text "..."` for a body-only write, `text KEY "..." KEY "..."` for
    /// several fields, `text` alone for none. A key is a word, or a string
    /// when it is not one word.
    mutating func parseTextContent() throws -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if case .string(let body)? = peek() {
            if case .string? = token(at: 1) {
                // A string key: pairs below.
            } else {
                advance()
                return ["kind": .string("text"), "fields": .object(["body": .string(body)])]
            }
        }
        loop: while let t = peek() {
            let key: String
            switch t {
            case .word(let w): key = w
            case .string(let s): key = s
            default: break loop
            }
            guard case .string(let value)? = token(at: 1) else {
                if case .string = t { throw reject(.unexpectedToken, "unexpected string \(t.described) after the text fields") }
                break loop
            }
            guard fields[key] == nil else { throw reject(.duplicateOption, "text field \(key) given twice") }
            advance()
            advance()
            fields[key] = .string(value)
        }
        return ["kind": .string("text"), "fields": .object(fields)]
    }

    /// `slide:<uuid> [build N]`; the id is lowercased (Spec 1 §4).
    mutating func parseSlideContent(_ word: String) throws -> [String: JSONValue] {
        let rest = String(word.dropFirst(MediaID.slidePrefix.count))
        guard let uuid = UUID(uuidString: rest) else {
            throw reject(.badArgument, "\(word) is not a slide id (slide:<uuid>)")
        }
        var content: [String: JSONValue] = ["kind": .string("slide"), "ref": .string(MediaID.slide(uuid))]
        if peekWordLower() == "build" {
            advance()
            content["build"] = .number(Double(try intToken(what: "build needs a number")))
        }
        return content
    }

    // MARK: - Spec 2 §2, riders

    /// "Riders sit at the end of a write in any order, each ending in its
    /// scope ... A rider without a scope is an error, not a default."
    mutating func parseRiders(into object: inout [String: JSONValue]) throws {
        while let t = peek() {
            guard case .word(let w) = t else {
                throw reject(.unexpectedToken, "unexpected \(t.described) after the content")
            }
            let name = Vocabulary.canonicalVerb(w.lowercased(), target: "channel")
            switch name {
            case "transition", "audiotransition", "grade":
                let key = name == "audiotransition" ? "audioTransition" : name
                guard object[key] == nil else { throw reject(.duplicateRider, "the \(name) rider is given twice") }
                advance()
                var rider: [String: JSONValue] = ["ref": .number(Double(try intToken(what: "\(name) needs a number")))]
                if let d = peek(), !isScopeWord(d), let ms = durationMs(d) {
                    advance()
                    rider["ms"] = .number(Double(ms))
                }
                rider["scope"] = try scope(for: name)
                object[key] = .object(rider)
            case "gain":
                guard object["gain"] == nil else { throw reject(.duplicateRider, "the gain rider is given twice") }
                advance()
                let db = try decimalToken(what: "gain needs a number in decibels")
                object["gain"] = .object(["db": .number(db), "scope": try scope(for: "gain")])
            case "chase":
                guard object["chase"] == nil else { throw reject(.duplicateRider, "the chase rider is given twice") }
                advance()
                object["chase"] = .object(["scope": try scope(for: "chase")])
            case "build":
                guard object["build"] == nil else { throw reject(.duplicateRider, "the build rider is given twice") }
                advance()
                object["build"] = .number(Double(try intToken(what: "build needs a number")))
            default:
                throw reject(.unexpectedToken, "unexpected \(w) after the content; riders are transition, audiotransition, grade, gain, chase and build")
            }
        }
    }

    mutating func scope(for rider: String) throws -> JSONValue {
        guard let t = next() else {
            throw reject(.missingRiderScope, "the \(rider) rider has no scope; end it with once or track")
        }
        guard case .word(let w) = t, w.lowercased() == "once" || w.lowercased() == "track" else {
            throw reject(.missingRiderScope, "the \(rider) rider needs a scope (once or track), not \(t.described)")
        }
        return .string(w.lowercased())
    }

    // MARK: - Spec 2 §3, the reserved edit form

    /// `edit TARGET N FIELD VALUE`; the value is the rest of the line, read
    /// as JSON when it looks like JSON, else as one word.
    mutating func parseEdit(into object: inout [String: JSONValue]) throws {
        guard let t = next() else { throw reject(.missingArgument, "edit needs a target (channel, stack, ...)") }
        guard case .word(let target) = t else { throw reject(.badArgument, "edit needs a target word, not \(t.described)") }
        let number = try intToken(what: "edit needs the object's number")
        guard let f = next() else { throw reject(.missingArgument, "edit needs a field name") }
        guard case .word(let field) = f else { throw reject(.badArgument, "the edit field must be a word, not \(f.described)") }
        guard index < tokens.count else { throw reject(.missingArgument, "edit needs a value") }
        var raw = Substring(text[tokens[index].start...])
        while let last = raw.last, last.isWhitespace { raw = raw.dropLast() }
        index = tokens.count
        let value: JSONValue
        let first = raw.first
        if first == "\"" || first == "[" || first == "{" || first == "-" || first.map(DurationText.isDigit) == true
            || raw == "true" || raw == "false" || raw == "null" {
            do {
                value = try JSONValue.parse(String(raw))
            } catch let error as JSONParseError {
                throw reject(.malformed, "the edit value is not valid JSON: \(error.message)")
            }
        } else if !raw.contains(where: \.isWhitespace) {
            value = .string(String(raw))
        } else {
            throw reject(.malformed, "quote the edit value: \(raw)")
        }
        object["target"] = .string(target.lowercased())
        object["number"] = .number(Double(number))
        object["field"] = .string(field)
        if value != .null { object["value"] = value }
    }
}
