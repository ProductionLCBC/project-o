// OCore — Spec 1 §8, migrations.

import Foundation

/// Spec 1 §8 — "Migrations are forward-only functions from schema N to N+1,
/// applied in order on load, each one small and tested against a fixture from
/// before the change." A migration rewrites the parsed tree of one kind.
public struct Migration: Sendable {
    public let kind: DocumentKind
    public let from: Int
    public let apply: @Sendable (JSONValue) -> JSONValue

    public init(kind: DocumentKind, from: Int, apply: @escaping @Sendable (JSONValue) -> JSONValue) {
        self.kind = kind
        self.from = from
        self.apply = apply
    }
}

/// Spec 1 §8 — the migration table and its application.
public enum Migrations {
    /// Every migration the app knows, by kind and starting schema.
    public static let all: [Migration] = [
        Migration(kind: .list, from: 0, apply: listZeroToOne),
    ]

    /// Spec 1 §8 — bring a parsed document to the current schema in memory.
    /// Returns the migrated tree (with its `schema` updated) and the schema it
    /// came from, or the tree unchanged and nil when it is already current.
    /// Throws the §8 hard failure for a schema newer than the app reads, and
    /// the matching failure for one older than it can migrate.
    public static func apply(_ document: JSONValue, kind: DocumentKind, path: String) throws -> (document: JSONValue, migratedFrom: Int?) {
        guard let schema = document["schema"]?.intValue else {
            throw DocumentFailure.notADocument(path: path, message: "no schema field")
        }
        let current = kind.currentSchema
        if schema > current { throw DocumentFailure.schemaTooNew(path: path, found: schema, supported: current) }
        if schema < kind.lowestReadableSchema { throw DocumentFailure.schemaTooOld(path: path, found: schema, lowest: kind.lowestReadableSchema) }
        if schema == current { return (document, nil) }
        var tree = document
        for step in schema..<current {
            guard let migration = all.first(where: { $0.kind == kind && $0.from == step }) else {
                throw DocumentFailure.schemaTooOld(path: path, found: schema, lowest: step + 1)
            }
            tree = migration.apply(tree).setting("schema", to: .number(Double(step + 1)))
        }
        return (tree, schema)
    }

    /// Spec 1 §10 — "A schema-0 fixture (invented for the test)". Schema 0 is
    /// invented: a cue's `trigger` was a bare word with its value beside it
    /// (`triggerMs`, `triggerTc`), and `trackThrough` did not exist. Anything
    /// the migration does not recognise is left for the unknown-key bag.
    @Sendable
    static func listZeroToOne(_ tree: JSONValue) -> JSONValue {
        guard let cues = tree["cues"]?.arrayValue else { return tree.setting("trackThrough", to: tree["trackThrough"] ?? .bool(false)) }
        let migrated: [JSONValue] = cues.map { cue in
            guard case .string(let word) = cue["trigger"] ?? .null else { return cue }
            var out = cue
            switch word {
            case "time":
                out = out.setting("trigger", to: .object(["type": .string("time"), "ms": cue["triggerMs"] ?? .number(0)]))
            case "timecode":
                out = out.setting("trigger", to: .object(["type": .string("timecode"), "tc": cue["triggerTc"] ?? .string("00:00:00:00")]))
            default:
                out = out.setting("trigger", to: .object(["type": .string("go")]))
            }
            return out.removing("triggerMs").removing("triggerTc")
        }
        var out = tree.setting("cues", to: .array(migrated))
        if out["trackThrough"] == nil { out = out.setting("trackThrough", to: .bool(false)) }
        return out
    }
}
