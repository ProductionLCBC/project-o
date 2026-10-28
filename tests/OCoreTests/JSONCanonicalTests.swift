import Foundation
import XCTest
@testable import OCore

/// Spec 1 §5 — JSON rules: "UTF-8, LF line endings, two-space indentation, keys
/// sorted, one object per line in arrays of objects", and §8's hard failure for
/// malformed JSON, which must name where. The printer and parser are the
/// format's own, so every platform writes the same bytes.
final class JSONCanonicalTests: XCTestCase {
    private func printed(_ value: JSONValue) -> String { JSONCanonical.string(value) }

    // MARK: - Printing

    func test_keysAreSortedByCodePointAndFlatContainersStayOnOneLine() {
        let value: JSONValue = .object([
            "b": .number(1), "a": .string("x"), "Z": .bool(true), "*": .null, "2": .number(2.5),
        ])
        XCTAssertEqual(printed(value), #"{ "*": null, "2": 2.5, "Z": true, "a": "x", "b": 1 }"#)
        XCTAssertEqual(printed(.array([.number(1), .number(2), .string("three")])), #"[1, 2, "three"]"#)
    }

    func test_nestedContainersPrintOneMemberPerLineWithTwoSpaceIndent() {
        let value: JSONValue = .object([
            "cues": .array([
                .object(["label": .string("Verse 1"), "commands": .array([.object(["cmd": .string("playlist.next")])])]),
                .object(["label": .string("Chorus"), "commands": .array([])]),
            ]),
            "kind": .string("list"),
        ])
        let expected = """
        {
          "cues": [
            {
              "commands": [
                { "cmd": "playlist.next" }
              ],
              "label": "Verse 1"
            },
            { "commands": [], "label": "Chorus" }
          ],
          "kind": "list"
        }
        """
        XCTAssertEqual(printed(value), expected)
    }

    func test_emptyContainersCountAsFlat() {
        XCTAssertEqual(printed(.object([:])), "{}")
        XCTAssertEqual(printed(.array([])), "[]")
        XCTAssertEqual(printed(.object(["a": .array([]), "b": .object([:])])), #"{ "a": [], "b": {} }"#)
    }

    func test_documentsEndWithOneLineFeedAndNoCarriageReturns() {
        let data = JSONCanonical.data(.object(["a": .object(["b": .array([.object([:])])])]))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("\r"))
        XCTAssertFalse(text.contains("\t"))
    }

    func test_numbersPrintIntegersWithoutADecimalPoint() {
        XCTAssertEqual(printed(.number(1)), "1")
        XCTAssertEqual(printed(.number(0)), "0")
        XCTAssertEqual(printed(.number(-6)), "-6")
        XCTAssertEqual(printed(.number(48_213_774)), "48213774")
        XCTAssertEqual(printed(.number(1.5)), "1.5")
        XCTAssertEqual(printed(.number(-0.05)), "-0.05")
        XCTAssertEqual(printed(.number(1.1)), "1.1")
        XCTAssertEqual(printed(.number(0.8)), "0.8")
        XCTAssertEqual(printed(.number(4.5)), "4.5")
        XCTAssertEqual(printed(.number(-0.0)), "0")
    }

    func test_stringsEscapeOnlyWhatJSONRequires() {
        XCTAssertEqual(printed(.string("Great is Thy faithfulness,\nO God my Father")), #""Great is Thy faithfulness,\nO God my Father""#)
        XCTAssertEqual(printed(.string("quote \" backslash \\ tab \t")), #""quote \" backslash \\ tab \t""#)
        XCTAssertEqual(printed(.string("control \u{01} bell \u{07} cr \r")), #""control \u0001 bell \u0007 cr \r""#)
        XCTAssertEqual(printed(.string("backgrounds/dawn.mp4")), #""backgrounds/dawn.mp4""#, "slashes are not escaped")
        XCTAssertEqual(printed(.string("Ünïcode ✓ 🎵")), #""Ünïcode ✓ 🎵""#, "non-ASCII passes through as UTF-8")
    }

    // MARK: - Parsing

    func test_parsePrintRoundTripsAValueTree() throws {
        let value: JSONValue = .object([
            "a": .array([.number(1), .number(2.25), .string("x\ny"), .bool(false), .null, .object(["k": .array([])])]),
            "é": .string("accent"),
            "n": .number(-1e-7),
        ])
        let text = printed(value)
        XCTAssertEqual(try JSONValue.parse(text), value)
        XCTAssertEqual(try JSONValue.parse(JSONCanonical.data(value)), value)
    }

    func test_parserAcceptsAnyWhitespaceAndEscapes() throws {
        let text = "\n\t{ \"a\" :\t[ 1 ,\n 2 ] , \"s\": \"\\u00e9\\ud83c\\udfb5 \\/ \\b\\f\" }\n"
        XCTAssertEqual(try JSONValue.parse(text), .object(["a": .array([.number(1), .number(2)]), "s": .string("é🎵 / \u{08}\u{0C}")]))
        XCTAssertEqual(try JSONValue.parse("[-0, 1e2, 1.5E-1, 0.5]"), .array([.number(0), .number(100), .number(0.15), .number(0.5)]))
    }

    func test_malformedJSONFailsWithLineAndColumn() {
        func failure(_ text: String) -> JSONParseError? {
            do {
                _ = try JSONValue.parse(text)
                return nil
            } catch let error as JSONParseError {
                return error
            } catch {
                return nil
            }
        }
        let trailingComma = failure("{\n  \"a\": 1,\n}")
        XCTAssertEqual(trailingComma?.line, 3)
        XCTAssertEqual(trailingComma?.column, 1)
        XCTAssertNotNil(failure("{\"a\": 1"), "truncated")
        XCTAssertNotNil(failure("{\"a\": 1} x"), "trailing garbage")
        XCTAssertNotNil(failure("[01]"), "leading zero")
        XCTAssertNotNil(failure("[1.]"), "dangling point")
        XCTAssertNotNil(failure("{a: 1}"), "unquoted key")
        XCTAssertNotNil(failure("[\"unterminated]"), "unterminated string")
        XCTAssertNotNil(failure("[\"bad \\x escape\"]"), "bad escape")
        XCTAssertNotNil(failure("[\"raw \u{01} control\"]"), "raw control character")
        XCTAssertNotNil(failure(""), "empty")
        XCTAssertNotNil(failure("nul"), "bad literal")
        let deep = String(repeating: "[", count: 2000) + String(repeating: "]", count: 2000)
        XCTAssertNotNil(failure(deep), "nesting is bounded, so a hostile file cannot overflow the stack")
    }

    func test_duplicateKeysKeepTheLastValue() throws {
        XCTAssertEqual(try JSONValue.parse(#"{"a": 1, "a": 2}"#), .object(["a": .number(2)]))
    }

    // MARK: - Codable bridge

    private struct Probe: Codable, Equatable {
        var number: Int
        var label: String
        var ratio: Double
        var tags: [String]
        var child: Child?
        struct Child: Codable, Equatable { var ok: Bool }
    }

    func test_codableValuesEncodeToTheTreeAndBack() throws {
        let probe = Probe(number: 42, label: "Great Is Thy Faithfulness", ratio: 0.8, tags: ["a", "b"], child: .init(ok: true))
        let tree = try JSONCoding.encode(probe)
        XCTAssertEqual(tree, .object([
            "number": .number(42), "label": .string("Great Is Thy Faithfulness"), "ratio": .number(0.8),
            "tags": .array([.string("a"), .string("b")]), "child": .object(["ok": .bool(true)]),
        ]))
        XCTAssertEqual(try JSONCoding.decode(Probe.self, from: tree), probe)
        XCTAssertEqual(JSONCanonical.string(tree), """
        {
          "child": { "ok": true },
          "label": "Great Is Thy Faithfulness",
          "number": 42,
          "ratio": 0.8,
          "tags": ["a", "b"]
        }
        """)
    }

    func test_treeAccessors() throws {
        let tree = try JSONValue.parse(#"{"a": {"b": [10, 20]}, "s": "x", "n": 3, "t": true}"#)
        XCTAssertEqual(tree["a"]?["b"]?[1], .number(20))
        XCTAssertEqual(tree["a"]?["b"]?[2], nil)
        XCTAssertEqual(tree["missing"], nil)
        XCTAssertEqual(tree["s"]?.stringValue, "x")
        XCTAssertEqual(tree["n"]?.intValue, 3)
        XCTAssertEqual(tree["t"]?.boolValue, true)
        XCTAssertEqual(tree["a"]?.objectValue?.count, 1)
        XCTAssertEqual(tree["a"]?["b"]?.arrayValue?.count, 2)
        XCTAssertNil(tree["s"]?.intValue)
    }
}
