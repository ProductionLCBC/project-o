import Foundation
import XCTest
@testable import OCore

/// `formats/schemas/` — one JSON Schema per document kind of Spec 1 §5. The
/// schemas are documentation for other tools; this test keeps them honest:
/// every fixture document validates against its kind's schema, the schema set
/// is complete, and a wrong document is caught. A small subset of JSON Schema
/// is enough for the shapes the format uses.
final class SchemaTests: XCTestCase {
    typealias F = FixtureLibrary

    private func schema(for kind: DocumentKind) throws -> JSONValue {
        let url = F.schemasRoot.appendingPathComponent("\(kind.fileStem).schema.json")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: url.path), "no schema for \(kind) at \(url.path)")
        return try JSONValue.parse(data)
    }

    func test_thereIsOneSchemaPerDocumentKind() throws {
        for kind in DocumentKind.allCases {
            let tree = try schema(for: kind)
            XCTAssertEqual(tree["$schema"], .string("https://json-schema.org/draft/2020-12/schema"), "\(kind)")
            XCTAssertEqual(tree["properties"]?["kind"]?["const"], .string(kind.rawValue), "\(kind)")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: F.schemasRoot.path).filter { $0.hasSuffix(".schema.json") }
        XCTAssertEqual(Set(files), Set(DocumentKind.allCases.map { "\($0.fileStem).schema.json" }))
    }

    func test_everyFixtureDocumentValidatesAgainstItsSchema() throws {
        let documents = F.documents(under: F.libraryRoot) + F.documents(under: F.machineRoot)
        for (path, data) in documents {
            let tree = try JSONValue.parse(data)
            let kind = try XCTUnwrap(tree["kind"]?.stringValue.flatMap(DocumentKind.init(rawValue:)), path)
            let errors = MiniSchema.validate(tree, against: try schema(for: kind))
            XCTAssertEqual(errors, [], path)
        }
    }

    func test_aWrongDocumentIsCaught() throws {
        let channels = try schema(for: .channels)
        var tree = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["channels.json"]))
        XCTAssertEqual(MiniSchema.validate(tree, against: channels), [])
        var list = tree["channels"]?.arrayValue ?? []
        list[0] = list[0].setting("number", to: .string("1"))
        tree = tree.setting("channels", to: .array(list))
        XCTAssertEqual(MiniSchema.validate(tree, against: channels).count, 1)
        tree = tree.setting("kind", to: .string("lists"))
        XCTAssertEqual(MiniSchema.validate(tree, against: channels).count, 2)
        var missing = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["channels.json"]))
        missing = .object(missing.objectValue?.filter { $0.key != "schema" } ?? [:])
        XCTAssertEqual(MiniSchema.validate(missing, against: channels).count, 1, "schema is required")
    }
}

/// Enough of JSON Schema 2020-12 for the format's schemas: type, enum, const,
/// properties, required, additionalProperties, patternProperties, items,
/// minimum, maximum, minLength, pattern, oneOf, anyOf, allOf and local $ref.
enum MiniSchema {
    static func validate(_ value: JSONValue, against schema: JSONValue) -> [String] {
        var errors: [String] = []
        check(value, schema, root: schema, path: "$", errors: &errors)
        return errors
    }

    private static func resolve(_ ref: String, in root: JSONValue) -> JSONValue? {
        guard ref.hasPrefix("#/") else { return nil }
        var node = root
        for part in ref.dropFirst(2).split(separator: "/") {
            guard let next = node[String(part)] else { return nil }
            node = next
        }
        return node
    }

    private static func typeMatches(_ value: JSONValue, _ type: String) -> Bool {
        switch (type, value) {
        case ("null", .null), ("boolean", .bool), ("string", .string), ("array", .array), ("object", .object), ("number", .number):
            return true
        case ("integer", .number(let n)):
            return n == n.rounded()
        default:
            return false
        }
    }

    private static func check(_ value: JSONValue, _ schema: JSONValue, root: JSONValue, path: String, errors: inout [String]) {
        if case .bool(let allowed) = schema {
            if !allowed { errors.append("\(path): not allowed") }
            return
        }
        if let ref = schema["$ref"]?.stringValue {
            guard let target = resolve(ref, in: root) else { return errors.append("\(path): unresolved $ref \(ref)") }
            check(value, target, root: root, path: path, errors: &errors)
        }
        if let type = schema["type"] {
            let types: [String] = type.stringValue.map { [$0] } ?? (type.arrayValue?.compactMap(\.stringValue) ?? [])
            if !types.isEmpty, !types.contains(where: { typeMatches(value, $0) }) {
                errors.append("\(path): expected \(types.joined(separator: "|")), got \(value.typeName)")
            }
        }
        if let options = schema["enum"]?.arrayValue, !options.contains(value) {
            errors.append("\(path): not one of the enum")
        }
        if let constant = schema["const"], constant != value {
            errors.append("\(path): expected const \(JSONCanonical.string(constant))")
        }
        if case .number(let n) = value {
            if let min = schema["minimum"]?.doubleValue, n < min { errors.append("\(path): below minimum \(min)") }
            if let max = schema["maximum"]?.doubleValue, n > max { errors.append("\(path): above maximum \(max)") }
        }
        if case .string(let s) = value {
            if let min = schema["minLength"]?.intValue, s.count < min { errors.append("\(path): shorter than \(min)") }
            if let pattern = schema["pattern"]?.stringValue {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(s.startIndex..., in: s)
                    if regex.firstMatch(in: s, range: range) == nil { errors.append("\(path): does not match \(pattern)") }
                } else {
                    errors.append("\(path): bad pattern \(pattern)")
                }
            }
        }
        if case .object(let members) = value {
            let properties = schema["properties"]?.objectValue ?? [:]
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where members[required] == nil {
                errors.append("\(path): missing \(required)")
            }
            let patterns = schema["patternProperties"]?.objectValue ?? [:]
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                if let property = properties[key] {
                    check(member, property, root: root, path: "\(path).\(key)", errors: &errors)
                    continue
                }
                if let (_, patternSchema) = patterns.first(where: { pattern, _ in
                    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
                    return regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
                }) {
                    check(member, patternSchema, root: root, path: "\(path).\(key)", errors: &errors)
                    continue
                }
                if let additional = schema["additionalProperties"] {
                    if additional == .bool(false) {
                        errors.append("\(path): unexpected key \(key)")
                    } else {
                        check(member, additional, root: root, path: "\(path).\(key)", errors: &errors)
                    }
                }
            }
        }
        if case .array(let items) = value, let itemSchema = schema["items"] {
            for (i, item) in items.enumerated() {
                check(item, itemSchema, root: root, path: "\(path)[\(i)]", errors: &errors)
            }
        }
        if let variants = schema["oneOf"]?.arrayValue {
            let matching = variants.filter { variant in
                var inner: [String] = []
                check(value, variant, root: root, path: path, errors: &inner)
                return inner.isEmpty
            }
            if matching.count != 1 { errors.append("\(path): \(matching.count) of oneOf matched") }
        }
        if let variants = schema["anyOf"]?.arrayValue {
            let any = variants.contains { variant in
                var inner: [String] = []
                check(value, variant, root: root, path: path, errors: &inner)
                return inner.isEmpty
            }
            if !any { errors.append("\(path): none of anyOf matched") }
        }
        if let all = schema["allOf"]?.arrayValue {
            for variant in all { check(value, variant, root: root, path: path, errors: &errors) }
        }
    }
}

private extension JSONValue {
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }
}
