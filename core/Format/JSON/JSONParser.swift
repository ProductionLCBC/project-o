// OCore — Spec 1 §5 and §8, the format's own JSON parser.
//
// The format owns its parser so that "malformed JSON" (§8, the first hard
// failure) names a line and column, so hostile nesting cannot overflow the
// stack, and so every platform reads the same bytes the same way.

import Foundation

/// Spec 1 §8 — "Hard failures are only malformed JSON and a schema newer than
/// the app can read. Both ... surface a plain message naming the file." The
/// parser supplies the place; the loader adds the file.
public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var line: Int
    public var column: Int
    public var message: String

    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String { "line \(line), column \(column): \(message)" }
}

extension JSONValue {
    /// Spec 1 §5 — parse a UTF-8 document into a value tree. Throws
    /// `JSONParseError` for anything that is not JSON, including trailing
    /// content, leading zeros, raw control characters in strings, lone
    /// surrogates, non-finite numbers and nesting deeper than 512.
    public static func parse(_ data: Data) throws -> JSONValue {
        try parse(bytes: [UInt8](data))
    }

    /// Spec 1 §5 — the same parser over text.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(bytes: Array(text.utf8))
    }

    static func parse(bytes: [UInt8]) throws -> JSONValue {
        var parser = JSONParser(bytes: bytes)
        return try parser.parseDocument()
    }
}

/// A recursive-descent parser over UTF-8 bytes with line and column tracking.
struct JSONParser {
    static let maxDepth = 512

    let bytes: [UInt8]
    var index = 0
    var line = 1
    var column = 1

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    // MARK: - Cursor

    var atEnd: Bool { index >= bytes.count }

    func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func advance() {
        guard index < bytes.count else { return }
        let byte = bytes[index]
        index += 1
        if byte == 0x0A {
            line += 1
            column = 1
        } else if byte & 0xC0 != 0x80 {
            // A UTF-8 continuation byte does not start a character.
            column += 1
        }
    }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(line: line, column: column, message: message)
    }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            advance()
        }
    }

    mutating func expect(_ byte: UInt8, _ what: String) throws {
        guard peek() == byte else { throw error(atEnd ? "unexpected end of input, expected \(what)" : "expected \(what)") }
        advance()
    }

    // MARK: - Grammar

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        guard !atEnd else { throw error("unexpected end of input") }
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard atEnd else { throw error("unexpected content after the document") }
        return value
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= JSONParser.maxDepth else { throw error("nesting deeper than \(JSONParser.maxDepth)") }
        guard let byte = peek() else { throw error("unexpected end of input") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try parseLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try parseLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try parseLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        try expect(UInt8(ascii: "{"), "{")
        var members: [String: JSONValue] = [:]
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            advance()
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error(atEnd ? "unexpected end of input in object" : "expected a quoted key") }
            let key = try parseString()
            skipWhitespace()
            try expect(UInt8(ascii: ":"), ":")
            skipWhitespace()
            // Spec 1 §5 — duplicate keys are not canonical; the last value wins, as JSON readers usually do.
            members[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard let next = peek() else { throw error("unexpected end of input in object") }
            if next == UInt8(ascii: ",") {
                advance()
                continue
            }
            if next == UInt8(ascii: "}") {
                advance()
                return .object(members)
            }
            throw error("expected , or } in object")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        try expect(UInt8(ascii: "["), "[")
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            advance()
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard let next = peek() else { throw error("unexpected end of input in array") }
            if next == UInt8(ascii: ",") {
                advance()
                continue
            }
            if next == UInt8(ascii: "]") {
                advance()
                return .array(items)
            }
            throw error("expected , or ] in array")
        }
    }

    mutating func parseLiteral(_ literal: String) throws {
        for expected in literal.utf8 {
            guard peek() == expected else { throw error("unexpected character in literal") }
            advance()
        }
    }

    mutating func parseNumber() throws -> Double {
        let start = index
        if peek() == UInt8(ascii: "-") { advance() }
        guard let first = peek(), isDigit(first) else { throw error("expected a digit") }
        if first == UInt8(ascii: "0") {
            advance()
            if let next = peek(), isDigit(next) { throw error("leading zeros are not allowed") }
        } else {
            while let d = peek(), isDigit(d) { advance() }
        }
        if peek() == UInt8(ascii: ".") {
            advance()
            guard let d = peek(), isDigit(d) else { throw error("expected a digit after the decimal point") }
            while let d = peek(), isDigit(d) { advance() }
        }
        if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            advance()
            if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { advance() }
            guard let d = peek(), isDigit(d) else { throw error("expected a digit in the exponent") }
            while let d = peek(), isDigit(d) { advance() }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text), value.isFinite else { throw error("number out of range") }
        return value
    }

    func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    mutating func parseString() throws -> String {
        try expect(UInt8(ascii: "\""), "\"")
        var buffer: [UInt8] = []
        while true {
            guard let byte = peek() else { throw error("unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                advance()
                guard let string = String(bytes: buffer, encoding: .utf8) else { throw error("invalid UTF-8 in string") }
                return string
            case UInt8(ascii: "\\"):
                advance()
                try parseEscape(into: &buffer)
            case 0x00..<0x20:
                throw error("raw control character in string")
            default:
                buffer.append(byte)
                advance()
            }
        }
    }

    mutating func parseEscape(into buffer: inout [UInt8]) throws {
        guard let byte = peek() else { throw error("unterminated escape") }
        switch byte {
        case UInt8(ascii: "\""): buffer.append(0x22)
        case UInt8(ascii: "\\"): buffer.append(0x5C)
        case UInt8(ascii: "/"): buffer.append(0x2F)
        case UInt8(ascii: "b"): buffer.append(0x08)
        case UInt8(ascii: "f"): buffer.append(0x0C)
        case UInt8(ascii: "n"): buffer.append(0x0A)
        case UInt8(ascii: "r"): buffer.append(0x0D)
        case UInt8(ascii: "t"): buffer.append(0x09)
        case UInt8(ascii: "u"):
            advance()
            let unit = try parseHex4()
            var scalarValue = UInt32(unit)
            if unit >= 0xD800 && unit <= 0xDBFF {
                // A high surrogate must be followed by a low one.
                guard peek() == UInt8(ascii: "\\") else { throw error("lone high surrogate") }
                advance()
                guard peek() == UInt8(ascii: "u") else { throw error("lone high surrogate") }
                advance()
                let low = try parseHex4()
                guard low >= 0xDC00 && low <= 0xDFFF else { throw error("expected a low surrogate") }
                scalarValue = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
            } else if unit >= 0xDC00 && unit <= 0xDFFF {
                throw error("lone low surrogate")
            }
            guard let scalar = Unicode.Scalar(scalarValue) else { throw error("invalid unicode escape") }
            buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
            return
        default:
            throw error("invalid escape")
        }
        advance()
    }

    mutating func parseHex4() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let byte = peek() else { throw error("unterminated unicode escape") }
            let digit: UInt16
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit in unicode escape")
            }
            value = value * 16 + digit
            advance()
        }
        return value
    }
}
