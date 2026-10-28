// OCore — Spec 1 §5, the canonical JSON form.

import Foundation

/// Spec 1 §5 — JSON rules: "UTF-8, LF line endings, two-space indentation,
/// keys sorted, one object per line in arrays of objects. The point is diffs
/// that read."
///
/// Reading of the spec (Area 2 plan, reading 1): a container whose members are
/// all scalars or empty containers prints on one line, as the §9 examples
/// show for slots, frames and colours; anything holding a non-empty container
/// prints one member per line. Keys sort by UTF-8 byte order. Integral numbers
/// print without a decimal point; the rest print in Swift's shortest
/// round-trip form. Strings escape only what JSON requires: never `/`, never
/// non-ASCII. Every document ends with one line feed.
public enum JSONCanonical {
    /// The canonical text of a value, without the trailing line feed.
    public static func string(_ value: JSONValue) -> String {
        var out = ""
        write(value, indent: 0, into: &out)
        return out
    }

    /// The canonical bytes of a document: the text plus one line feed.
    public static func data(_ value: JSONValue) -> Data {
        Data((string(value) + "\n").utf8)
    }

    /// A member that keeps its container on one line.
    static func isFlat(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool, .number, .string: return true
        case .array(let items): return items.isEmpty
        case .object(let members): return members.isEmpty
        }
    }

    static func sortedKeys(_ members: [String: JSONValue]) -> [String] {
        members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    static func write(_ value: JSONValue, indent: Int, into out: inout String) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): writeNumber(n, into: &out)
        case .string(let s): writeString(s, into: &out)
        case .array(let items):
            if items.isEmpty {
                out += "[]"
            } else if items.allSatisfy(isFlat) {
                out += "["
                for (i, item) in items.enumerated() {
                    if i > 0 { out += ", " }
                    write(item, indent: indent, into: &out)
                }
                out += "]"
            } else {
                let pad = String(repeating: " ", count: indent + 2)
                out += "[\n"
                for (i, item) in items.enumerated() {
                    if i > 0 { out += ",\n" }
                    out += pad
                    write(item, indent: indent + 2, into: &out)
                }
                out += "\n" + String(repeating: " ", count: indent) + "]"
            }
        case .object(let members):
            let keys = sortedKeys(members)
            if keys.isEmpty {
                out += "{}"
            } else if members.values.allSatisfy(isFlat) {
                out += "{ "
                for (i, key) in keys.enumerated() {
                    if i > 0 { out += ", " }
                    writeString(key, into: &out)
                    out += ": "
                    if let member = members[key] { write(member, indent: indent, into: &out) }
                }
                out += " }"
            } else {
                let pad = String(repeating: " ", count: indent + 2)
                out += "{\n"
                for (i, key) in keys.enumerated() {
                    if i > 0 { out += ",\n" }
                    out += pad
                    writeString(key, into: &out)
                    out += ": "
                    if let member = members[key] { write(member, indent: indent + 2, into: &out) }
                }
                out += "\n" + String(repeating: " ", count: indent) + "}"
            }
        }
    }

    static func writeNumber(_ n: Double, into out: inout String) {
        guard n.isFinite else {
            out += "null"
            return
        }
        if n == n.rounded(), abs(n) < 9_007_199_254_740_992 {
            out += String(Int64(n))
        } else {
            out += n.description
        }
    }

    static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case Unicode.Scalar(0x00)...Unicode.Scalar(0x1F):
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
