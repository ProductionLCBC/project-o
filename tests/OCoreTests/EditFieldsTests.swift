import Foundation
import XCTest
@testable import OCore

/// Spec 5 §6, check 3 — "The path. It exists in the object's JSON Schema
/// (`formats/schemas` ...) and is editable"; check 4 — "The value. It has the
/// field's type and enum, and it is in range." The edit path's field tables
/// are held to the schemas here, then tried against the fixture objects.
final class EditFieldsTests: XCTestCase {
    typealias F = FixtureLibrary

    // MARK: - The tables are the schemas

    private func schema(_ file: String) throws -> JSONValue {
        let url = F.schemasRoot.appendingPathComponent(file)
        return try JSONValue.parse(try XCTUnwrap(FileManager.default.contents(atPath: url.path), file))
    }

    private func number(_ n: Double) -> String { n == n.rounded() ? String(Int(n)) : String(n) }

    private func range(_ min: Double?, _ max: Double?, whole: Bool) -> String {
        // A whole number of 1 or more is how every number and count is written; it is left unsaid on both sides.
        if whole, min == 1, max == nil { return "" }
        if min == nil, max == nil { return "" }
        return "[" + (min.map(number) ?? "") + "," + (max.map(number) ?? "") + "]"
    }

    /// A schema node in one line.
    private func describe(_ node: JSONValue, in root: JSONValue) -> String {
        if let ref = node["$ref"]?.stringValue, let name = ref.split(separator: "/").last.map(String.init) {
            if name == "uuid" { return "string" }
            return describe(root["$defs"]?[name] ?? .null, in: root)
        }
        if let alternatives = node["oneOf"]?.arrayValue {
            let parts = alternatives.map { describe($0, in: root) }
            let rest = parts.filter { $0 != "null" }.sorted()
            let body = rest.count == 1 ? rest[0] : "(" + rest.joined(separator: " | ") + ")"
            return parts.contains("null") ? body + "|null" : body
        }
        if let word = node["const"]?.stringValue { return "\"\(word)\"" }
        if let values = node["enum"]?.arrayValue {
            let rest = values.filter { !$0.isNull }
            let words: [String] = rest.compactMap(\.stringValue)
            let numbers: [String] = rest.compactMap(\.intValue).map { String($0) }
            let body: String = words.count == rest.count ? "enum(" + words.joined(separator: ",") + ")" : "ints(" + numbers.joined(separator: ",") + ")"
            return values.contains(.null) ? body + "|null" : body
        }
        var types = node["type"]?.arrayValue?.compactMap(\.stringValue) ?? node["type"]?.stringValue.map { [$0] } ?? []
        let nullable = types.contains("null")
        types.removeAll { $0 == "null" }
        guard let type = types.first else { return nullable ? "null" : "any" }
        let body: String
        switch type {
        case "string": body = "string"
        case "boolean": body = "bool"
        case "integer": body = "int" + range(node["minimum"]?.doubleValue, node["maximum"]?.doubleValue, whole: true)
        case "number": body = "num" + range(node["minimum"]?.doubleValue, node["maximum"]?.doubleValue, whole: false)
        case "array": body = "[" + describe(node["items"] ?? .null, in: root) + "]"
        default:
            if let properties = node["properties"]?.objectValue {
                let required = Set(node["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                body = "{" + properties.keys.sorted().map { key in
                    key + (required.contains(key) ? "" : "?") + ": " + describe(properties[key] ?? .null, in: root)
                }.joined(separator: ", ") + "}"
            } else if let only = node["patternProperties"]?.objectValue?.values.first {
                body = "{*: " + describe(only, in: root) + "}"
            } else if let extra = node["additionalProperties"], extra.objectValue != nil {
                body = "{*: " + describe(extra, in: root) + "}"
            } else {
                body = "object"
            }
        }
        return nullable ? body + "|null" : body
    }

    /// A table's field in the same line.
    private func describe(_ field: EditField) -> String {
        switch field {
        case .text: return "string"
        case .flag: return "bool"
        case .whole(let min, let max): return "int" + range(min.map(Double.init), max.map(Double.init), whole: true)
        case .number(let min, let max): return "num" + range(min, max, whole: false)
        case .choice(let words): return "enum(" + words.joined(separator: ",") + ")"
        case .wholeChoice(let numbers): return "ints(" + numbers.map(String.init).joined(separator: ",") + ")"
        case .reference: return "int"
        case .optional(let inner): return describe(inner) + "|null"
        case .record(let fields, let optional):
            return "{" + fields.keys.sorted().map { key in
                key + (optional.contains(key) ? "?" : "") + ": " + (fields[key].map(describe) ?? "")
            }.joined(separator: ", ") + "}"
        case .map(let inner, _): return "{*: " + describe(inner) + "}"
        case .list(let inner): return "[" + describe(inner) + "]"
        case .either(let fields):
            return "(" + fields.map(describe).sorted().joined(separator: " | ") + ")"
        case .literal(let word): return "\"\(word)\""
        case .commands: return "[command]"
        case .anything: return "object"
        case .readOnly(let inner): return describe(inner)
        }
    }

    /// An object's schema, without the keys every document carries (Spec 1 §5).
    private func object(_ node: JSONValue, in root: JSONValue, only keys: Set<String>? = nil) -> String {
        var trimmed = node.objectValue ?? [:]
        var properties = trimmed["properties"]?.objectValue ?? [:]
        for key in ["schema", "app", "kind"] { properties[key] = nil }
        if let keys { properties = properties.filter { keys.contains($0.key) } }
        trimmed["properties"] = .object(properties)
        return describe(.object(trimmed), in: root)
    }

    func test_eachTableIsItsSchema() throws {
        let catalogs: [(String, String, EditField)] = [
            ("channels.schema.json", "channel", EditFields.channel),
            ("stacks.schema.json", "stack", EditFields.stack),
            ("text-styles.schema.json", "textStyle", EditFields.textStyle),
            ("grades.schema.json", "grade", EditFields.grade),
            ("transitions.schema.json", "transition", EditFields.transition),
            ("audio-transitions.schema.json", "audioTransition", EditFields.audioTransition),
        ]
        for (file, name, table) in catalogs {
            let root = try schema(file)
            let expected = object(try XCTUnwrap(root["$defs"]?[name], name), in: root)
            // Spec 5 §6, check 4 — "gain within ±60 dB" is Spec 2 §8's range, which the schema doesn't carry.
            let ours = describe(table).replacingOccurrences(of: "gain: num[-60,60]", with: "gain: num")
            XCTAssertEqual(ours, expected, name)
        }

        // A preset is its own document. Spec 5 §6 — "box frames 0–1" is Spec 1's range, said in the schema's words only.
        let preset = try schema("preset.schema.json")
        let frame = "frame: {h: num[0,1], w: num[0,1], x: num[0,1], y: num[0,1]}"
        XCTAssertTrue(describe(EditFields.preset).contains(frame))
        XCTAssertEqual(describe(EditFields.preset).replacingOccurrences(of: frame, with: "frame: {h: num, w: num, x: num, y: num}"),
                       object(preset, in: preset), "preset")

        // A macro too; its commands are command objects, checked as a cue's are.
        let macro = try schema("macro.schema.json")
        XCTAssertEqual(macro["properties"]?["commands"]?["type"], .string("array"))
        var withoutCommands = macro.objectValue ?? [:]
        var properties = withoutCommands["properties"]?.objectValue ?? [:]
        properties["commands"] = .object(["type": .string("array"), "items": .object(["const": .string("command")])])
        withoutCommands["properties"] = .object(properties)
        XCTAssertEqual(describe(EditFields.macro).replacingOccurrences(of: "[command]", with: "[\"command\"]"),
                       object(.object(withoutCommands), in: macro), "macro")

        // Spec 11 §11 — of an output, only its default stack and transitions; the rest is named for Area 17.
        let outputs = try schema("outputs.schema.json")
        let output = try XCTUnwrap(outputs["$defs"]?["output"])
        XCTAssertEqual(describe(EditFields.output), object(output, in: outputs, only: ["defaultStack", "transitions"]), "output")
        let all = Set(output["properties"]?.objectValue?.keys.map { $0 } ?? [])
        XCTAssertEqual(all, EditFields.outputLater.union(["defaultStack", "transitions", "number", "uuid"]),
                       "every field of an output is Area 14's, Area 17's or never edited")
    }

    // MARK: - Paths

    private func json<T: Encodable>(_ value: T) throws -> JSONValue { try JSONCoding.encode(value) }

    private func place(_ table: EditField, _ path: String, in object: JSONValue) throws -> EditPlace {
        try table.place(try XCTUnwrap(EditPath(path), path), in: object)
    }

    func test_aPathNamesAPartByFieldsPositionsAndKeys() throws {
        let library = F.load().library
        let lowerThird = try json(try XCTUnwrap(library.preset(3)))

        let x = try place(EditFields.preset, "layouts.2.boxes.0.frame.x", in: lowerThird)
        XCTAssertEqual(x.value, .number(0.03))
        XCTAssertNil(x.field.problem(with: .number(0.5)))
        XCTAssertNotNil(x.field.problem(with: .number(1.5)), "box frames 0–1")
        XCTAssertFalse(x.readOnly)

        XCTAssertEqual(try place(EditFields.preset, "layouts.*.boxes.0.binding.name", in: lowerThird).value, .string("title"))
        XCTAssertEqual(try place(EditFields.preset, "layouts.*.boxes.0.textStyle.size.unit", in: lowerThird).value, .string("percent"))
        XCTAssertEqual(try place(EditFields.preset, "layouts.*.boxes.0.textStyle.variations.wght", in: lowerThird).value, .number(500))
        XCTAssertEqual(try place(EditFields.preset, "layouts.*.boxes.0.grade", in: lowerThird).value, .number(1))

        // A map's entry that isn't there yet: a place with nothing in it, so a set can make it.
        let unmade = try place(EditFields.preset, "layouts.7", in: lowerThird)
        XCTAssertNil(unmade.value)
        if case .map = unmade.parent {} else { XCTFail("layouts is a map") }

        for bad in ["layouts.x", "layouts.2.boxes.5", "layouts.2.boxes.0.colour", "layouts.7.boxes", "nothing", "label.more",
                    "layouts.*.boxes.0.binding.text"] {
            XCTAssertThrowsError(try place(EditFields.preset, bad, in: lowerThird), bad) { error in
                guard case EditPathError.unknown = error else { return XCTFail("\(bad): \(error)") }
            }
        }
        XCTAssertNil(EditPath("layouts..boxes"))
        XCTAssertNil(EditPath(""))
    }

    func test_aShapeDecidesWhatLiesUnderIt() throws {
        let library = F.load().library
        // Channel 2's render size is a width and a height; channel 1's is "largest", with nothing under it.
        let sized = try json(try XCTUnwrap(library.channel(2)))
        XCTAssertEqual(try place(EditFields.channel, "renderSize.width", in: sized).value, .number(1920))
        let largest = try json(try XCTUnwrap(library.channel(1)))
        XCTAssertThrowsError(try place(EditFields.channel, "renderSize.width", in: largest))
        let whole = try place(EditFields.channel, "renderSize", in: largest)
        XCTAssertNil(whole.field.problem(with: .string("largest")))
        XCTAssertNil(whole.field.problem(with: .object(["width": .number(1280), "height": .number(720)])))
        XCTAssertNotNil(whole.field.problem(with: .string("smallest")))
        XCTAssertNotNil(whole.field.problem(with: .object(["width": .number(1280)])))

        // A pixel box has no text style, so nothing under it.
        let preset1 = try json(try XCTUnwrap(library.preset(1)))
        XCTAssertThrowsError(try place(EditFields.preset, "layouts.*.boxes.0.textStyle.font", in: preset1))
        XCTAssertNoThrow(try place(EditFields.preset, "layouts.*.boxes.1.textStyle.font", in: preset1))
        XCTAssertNoThrow(try place(EditFields.preset, "layouts.*.boxes.0.textStyle", in: preset1), "the style itself can be set")
    }

    func test_whatIsNeverEditedSaysSo() throws {
        let (library, machine, _) = F.load()
        XCTAssertTrue(try place(EditFields.channel, "uuid", in: try json(try XCTUnwrap(library.channel(1)))).readOnly)
        XCTAssertTrue(try place(EditFields.channel, "number", in: try json(try XCTUnwrap(library.channel(1)))).readOnly)
        XCTAssertTrue(try place(EditFields.preset, "builtIn", in: try json(try XCTUnwrap(library.preset(1)))).readOnly)
        let dissolve = try json(try XCTUnwrap(library.transition(2)))
        XCTAssertTrue(try place(EditFields.transition, "type", in: dissolve).readOnly, "their type and colour stay as built")
        XCTAssertTrue(try place(EditFields.transition, "color", in: dissolve).readOnly)
        XCTAssertFalse(try place(EditFields.transition, "ms", in: dissolve).readOnly)
        XCTAssertFalse(try place(EditFields.transition, "easing", in: dissolve).readOnly)
        XCTAssertFalse(try place(EditFields.stack, "gammaBlend", in: try json(try XCTUnwrap(machine.stack(1)))).readOnly)
        XCTAssertEqual(EditFields.neverEdited, ["uuid", "schema", "app", "kind", "version", "builtIn", "number"])
    }

    // MARK: - Values

    func test_aValueHasItsFieldsTypeEnumAndRange() throws {
        func problem(_ table: EditField, _ path: String, _ value: JSONValue, in object: JSONValue) throws -> String? {
            try place(table, path, in: object).field.problem(with: value)
        }
        let (library, machine, _) = F.load()
        let channel = try json(try XCTUnwrap(library.channel(1)))
        XCTAssertNil(try problem(EditFields.channel, "decoderCap", .number(3), in: channel))
        XCTAssertNil(try problem(EditFields.channel, "decoderCap", .null, in: channel), "null clears a nullable field")
        XCTAssertNotNil(try problem(EditFields.channel, "decoderCap", .number(4), in: channel), "a decoder cap of 2 or 3")
        XCTAssertNotNil(try problem(EditFields.channel, "defaults.gain", .number(61), in: channel), "gain within ±60 dB")
        XCTAssertNil(try problem(EditFields.channel, "defaults.gain", .number(-60), in: channel))
        XCTAssertNotNil(try problem(EditFields.channel, "usualContent", .string("video"), in: channel))
        XCTAssertNotNil(try problem(EditFields.channel, "label", .number(1), in: channel))
        XCTAssertNotNil(try problem(EditFields.channel, "audioOutputs", .array([.number(1), .number(0)]), in: channel))
        XCTAssertNil(try problem(EditFields.channel, "audioOutputs", .array([.number(1), .number(9)]), in: channel),
                     "a number this machine lacks is a reference question, not a value's")

        let stack = try json(try XCTUnwrap(machine.stack(1)))
        XCTAssertNotNil(try problem(EditFields.stack, "slots.0.opacity", .number(1.2), in: stack), "opacity 0–1")
        XCTAssertNil(try problem(EditFields.stack, "slots.0.preset", .null, in: stack))
        XCTAssertNotNil(try problem(EditFields.stack, "base", .string("white"), in: stack))

        let preset = try json(try XCTUnwrap(library.preset(3)))
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0.offset", .number(4), in: preset), "−2 to +3")
        XCTAssertNil(try problem(EditFields.preset, "layouts.*.boxes.0.offset", .number(-2), in: preset))
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0.offset", .number(0.5), in: preset))
        XCTAssertNil(try problem(EditFields.preset, "layouts.*.boxes.0.fit", .string("fill"), in: preset),
                     "a fit is either kind; which suits the binding is the box's own check")
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0.fit", .string("cover"), in: preset))
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0.textStyle.alignment", .string("middle"), in: preset))
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0.textStyle.color", .object(["r": .number(2)]), in: preset))
        // A whole box, as a binding change sets it (Spec 11 §8).
        let box = try XCTUnwrap(preset.value(at: ["layouts", "*", "boxes", "0"]))
        XCTAssertNil(try problem(EditFields.preset, "layouts.*.boxes.0", box, in: preset))
        XCTAssertNotNil(try problem(EditFields.preset, "layouts.*.boxes.0", box.removing("frame"), in: preset), "a box needs its frame")
        XCTAssertNil(try problem(EditFields.preset, "layouts.*.boxes.0", box.removing("transitionOnVariableChange"), in: preset),
                     "a key the document may leave out")

        let audio = try json(try XCTUnwrap(library.audioTransition(1)))
        XCTAssertNotNil(try problem(EditFields.audioTransition, "offsetMs", .number(1001), in: audio), "offsets within ±1000 ms")
        XCTAssertNil(try problem(EditFields.audioTransition, "offsetMs", .number(-1000), in: audio))
        XCTAssertNil(try problem(EditFields.audioTransition, "type", .string("fadeThroughSilence"), in: audio))
    }

    // MARK: - References in a value

    func test_theNumbersAValueNames() throws {
        let library = F.load().library
        let preset = try json(try XCTUnwrap(library.preset(3)))
        let box = try XCTUnwrap(preset.value(at: ["layouts", "*", "boxes", "0"]))
        let named = EditFields.box.references(in: box).map { "\($0.type.rawValue) \($0.number)" }.sorted()
        XCTAssertEqual(named, ["grade 1", "textStyle 2", "transition 2"])

        // A preset's layouts name the stacks they are for.
        let layouts = try XCTUnwrap(preset["layouts"])
        let field = try place(EditFields.preset, "layouts", in: preset).field
        XCTAssertTrue(field.references(in: layouts).contains { $0.type == .stack && $0.number == 2 })
        let moved = field.mappingReferences(in: layouts) { type, n in type == .stack && n == 2 ? 6 : n }
        XCTAssertEqual(Set(moved.objectValue?.keys.map { $0 } ?? []), ["*", "6"])

        let slot = JSONValue.object(["channel": .number(3), "preset": .number(4), "opacity": .number(1), "mute": .bool(false)])
        XCTAssertEqual(EditFields.slot.references(in: slot).map { "\($0.type.rawValue) \($0.number)" }.sorted(), ["channel 3", "preset 4"])
        let renumbered = EditFields.slot.mappingReferences(in: slot) { type, n in type == .preset ? 9 : n }
        XCTAssertEqual(renumbered["preset"], .number(9))
        XCTAssertEqual(renumbered["channel"], .number(3))

        // A macro's commands name what its commands name.
        let commands = try json([GuardedCommand(.macro(2)), GuardedCommand(.outputStack(output: 1, stack: 2))])
        XCTAssertEqual(EditField.commands.references(in: commands).map { "\($0.type.rawValue) \($0.number)" }.sorted(),
                       ["macro 2", "output 1", "stack 2"])
    }
}
