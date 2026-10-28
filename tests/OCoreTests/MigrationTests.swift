import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Migration: "A schema-0 fixture (invented for the test) migrates
/// to schema 1 in memory and is not written until a save." Spec 1 §8:
/// "Migrations are forward-only functions from schema N to N+1, applied in order
/// on load... A document is migrated in memory and written back at the current
/// schema the next time it is saved, never on load alone."
final class MigrationTests: XCTestCase {
    typealias F = FixtureLibrary

    private var schemaZero: Data {
        FileManager.default.contents(atPath: F.schemaZeroList.path) ?? Data()
    }

    func test_aSchemaZeroListMigratesInMemory() throws {
        let loaded = try Loader.document(path: "lists/007-doxology.json", data: schemaZero)
        XCTAssertEqual(loaded.kind, .list)
        XCTAssertEqual(loaded.migratedFrom, 0)
        guard case .list(let list) = loaded.body else { return XCTFail("\(loaded.body)") }
        XCTAssertEqual(list.number, 7)
        XCTAssertEqual(list.trackThrough, false, "a field schema 0 did not have takes its default")
        XCTAssertEqual(list.cues.map(\.trigger), [.go, .time(ms: 4000), .timecode("01:00:30:00")])
        XCTAssertEqual(list.cues.map(\.uuid), F.list7Cues)
        XCTAssertEqual(list.cues[2].advanceAfterMs, 5000)
        XCTAssertEqual(list.cues[1].extra, [:], "the migration consumed the schema-0 keys; nothing leaks into the unknown-key bag")
    }

    /// The loader returns values only; the migrated document is written at the
    /// current schema when it is saved, in the canonical shape.
    func test_aMigratedDocumentIsWrittenAtTheCurrentSchemaOnSave() throws {
        let loaded = try Loader.document(path: "lists/007-doxology.json", data: schemaZero)
        let written = Writer.data(for: loaded)
        let tree = try JSONValue.parse(written)
        XCTAssertEqual(tree["schema"], .number(1))
        XCTAssertEqual(tree["app"], .string(OCore.appVersion))
        XCTAssertEqual(tree["cues"]?[1]?["trigger"], .object(["type": .string("time"), "ms": .number(4000)]))
        XCTAssertNil(tree["cues"]?[1]?["triggerMs"])
        XCTAssertEqual(tree["trackThrough"], .bool(false))
        XCTAssertNotEqual(written, schemaZero)

        let reloaded = try Loader.document(path: "lists/007-doxology.json", data: written)
        XCTAssertNil(reloaded.migratedFrom)
        XCTAssertEqual(reloaded.body, loaded.body)
    }

    func test_migrationsApplyOnlyBelowTheCurrentSchemaAndRefuseWhatTheyCannotRead() throws {
        let current = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["lists/007-doxology.json"]))
        let unchanged = try Migrations.apply(current, kind: .list, path: "lists/007-doxology.json")
        XCTAssertEqual(unchanged.document, current)
        XCTAssertNil(unchanged.migratedFrom)

        let zero = try JSONValue.parse(schemaZero)
        let migrated = try Migrations.apply(zero, kind: .list, path: "lists/007-doxology.json")
        XCTAssertEqual(migrated.migratedFrom, 0)
        XCTAssertEqual(migrated.document["schema"], .number(1))

        XCTAssertThrowsError(try Migrations.apply(current.setting("schema", to: .number(2)), kind: .list, path: "x.json")) { error in
            guard case DocumentFailure.schemaTooNew(_, let found, let supported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, 2)
            XCTAssertEqual(supported, 1)
        }
        // Only lists have a schema 0; every other kind starts at 1.
        let channelsZero = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["channels.json"])).setting("schema", to: .number(0))
        XCTAssertThrowsError(try Migrations.apply(channelsZero, kind: .channels, path: "channels.json")) { error in
            guard case DocumentFailure.schemaTooOld(_, let found, let lowest) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(found, 0)
            XCTAssertEqual(lowest, 1)
        }
        XCTAssertEqual(DocumentKind.list.lowestReadableSchema, 0)
        XCTAssertEqual(DocumentKind.channels.lowestReadableSchema, 1)
        for kind in DocumentKind.allCases {
            XCTAssertEqual(kind.currentSchema, OCore.schemaVersion)
        }
    }
}
