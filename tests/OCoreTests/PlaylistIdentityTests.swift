import Foundation
import XCTest
@testable import OCore

/// Spec 7 §3 — a playlist's identity, its items and their uuids, and its
/// files. Items gain a `uuid`, unique within the playlist; a linked item also
/// records its list's uuid; a playlist gains `serviceTime` (Spec 6 §5).
final class PlaylistIdentityTests: XCTestCase {
    typealias F = FixtureLibrary

    /// One playlist document from JSON text, the way the loader reads it.
    func playlist(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> (Playlist, LoadedDocument) {
        let loaded = try Loader.document(path: "playlists/test.json", data: Data(json.utf8))
        guard case .playlist(let playlist) = loaded.body else {
            XCTFail("not a playlist", file: file, line: line)
            throw DocumentFailure.unreadable(path: "playlists/test.json", message: "not a playlist")
        }
        return (playlist, loaded)
    }

    func document(items: String, uuid: String = "b1a70000-0000-4000-8000-000000000001", extra: String = "") -> String {
        """
        { "app": "0.1.0", "archived": false, "items": [\(items)], "kind": "playlist", "schema": 1,
          "serviceDate": null, "title": "Hand made", "uuid": "\(uuid)"\(extra) }
        """
    }

    func derived(_ name: String) -> UUID { UUID.v5(namespace: F.playlistUuid, name: name) }

    // MARK: - Item uuids

    /// "a UUIDv5 with the playlist's uuid as its namespace and, as its name,
    /// the UTF-8 text `KIND:KEY:N`. KIND is header, linked or local; KEY is
    /// the label as written, the list number in decimal, or the local uuid in
    /// lowercase; N counts the earlier items with the same kind and key."
    func test_anItemWithoutAUuidIsNamedByKindKeyAndCount() throws {
        let local = "10CA1000-0000-4000-8000-00000000002A"
        let (playlist, _) = try playlist(document(items: """
            { "kind": "header", "label": "Welcome" },
            { "kind": "linked", "list": 42 },
            { "kind": "linked", "list": 42 },
            { "kind": "local", "localUuid": "\(local)" },
            { "kind": "header", "label": "Welcome" }
            """))
        XCTAssertEqual(playlist.items.map(\.uuid), [
            derived("header:Welcome:0"),
            derived("linked:42:0"),
            derived("linked:42:1"),
            derived("local:\(local.lowercased()):0"),
            derived("header:Welcome:1"),
        ])
    }

    /// "The same file always gets the same uuids ... and they are written at
    /// the playlist's next save, never on load alone (Spec 1 §8)."
    func test_derivedUuidsAreTheSameAtEveryLoadAndWrittenAtTheNextSave() throws {
        let json = document(items: #"{ "kind": "linked", "list": 7 }, { "kind": "header", "label": "Response" }"#)
        let (first, _) = try playlist(json)
        let (second, _) = try playlist(json)
        XCTAssertEqual(first, second)
        let saved = try JSONValue.parse(Writer.data(for: .playlist(first)))
        let written = saved["items"]?.arrayValue?.compactMap { $0["uuid"]?.stringValue } ?? []
        XCTAssertEqual(written, first.items.map { $0.uuid.uuidString.lowercased() })
    }

    /// "N ... counts on while the result is already in the playlist."
    func test_theCountGoesOnPastAUuidThePlaylistAlreadyHas() throws {
        let taken = derived("linked:42:0").uuidString.lowercased()
        let (playlist, _) = try playlist(document(items: """
            { "kind": "linked", "list": 42 },
            { "kind": "linked", "list": 7, "uuid": "\(taken)" }
            """))
        XCTAssertEqual(playlist.items.map(\.uuid), [derived("linked:42:1"), derived("linked:42:0")])
    }

    /// "An item whose uuid repeats an earlier item's is treated as having
    /// none, and is reported."
    func test_aRepeatedUuidIsTreatedAsNoneAndReported() throws {
        let repeated = "5e5e0000-0000-4000-8000-000000000001"
        let (playlist, loaded) = try playlist(document(items: """
            { "kind": "header", "label": "A", "uuid": "\(repeated)" },
            { "kind": "header", "label": "B", "uuid": "\(repeated)" }
            """))
        XCTAssertEqual(playlist.items.map(\.uuid), [UUID(uuidString: repeated), derived("header:B:0")])
        XCTAssertEqual(loaded.issues.map(\.code), [.repeatedItemUuid])
        XCTAssertEqual(loaded.issues.first?.subject, "playlist Hand made item 2")
    }

    /// "a linked item also records its list's uuid" and `serviceTime` is
    /// "an optional `HH:MM`" (Spec 6 §5); a hand-made item without one is
    /// written without it until its list is known.
    func test_listUuidAndServiceTimeSurviveARoundTrip() throws {
        let (playlist, _) = try playlist(document(items: """
            { "kind": "linked", "list": 42, "listUuid": "a9f00000-0000-4000-8000-00000000002a", "uuid": "4d4d0000-0000-4000-8000-000000000001" },
            { "kind": "linked", "list": 7, "uuid": "4d4d0000-0000-4000-8000-000000000002" }
            """, extra: #", "serviceTime": "10:30""#))
        XCTAssertEqual(playlist.serviceTime, "10:30")
        XCTAssertEqual(playlist.items[0].kind, .linked(list: 42, listUuid: F.listUuid(42)))
        XCTAssertEqual(playlist.items[1].kind, .linked(list: 7, listUuid: nil))
        let saved = try JSONValue.parse(Writer.data(for: .playlist(playlist)))
        XCTAssertEqual(saved["serviceTime"]?.stringValue, "10:30")
        XCTAssertEqual(saved["items"]?[0]?["listUuid"]?.stringValue, "a9f00000-0000-4000-8000-00000000002a")
        XCTAssertNil(saved["items"]?[1]?["listUuid"])
        XCTAssertNil(try self.playlist(document(items: "")).0.serviceTime)
    }

    /// Spec 7 §8 — the fixture's playlist has "a `uuid` on every item and a
    /// `listUuid` on every linked one", and they are the uuids the rule
    /// gives, so the same file made by hand loads with the same ones.
    func test_theFixturePlaylistCarriesTheUuidsTheRuleGives() throws {
        let (_, machine, _) = F.load()
        let sunday = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        XCTAssertEqual(sunday.items.map(\.uuid), [
            derived("header:Welcome:0"),
            derived("linked:42:0"),
            derived("local:\(F.localCopyUuid.uuidString.lowercased()):0"),
            derived("header:Response:0"),
            derived("linked:7:0"),
        ])
        XCTAssertEqual(sunday.items[1].kind, .linked(list: 42, listUuid: F.listUuid(42)))
        XCTAssertEqual(sunday.items[4].kind, .linked(list: 7, listUuid: F.listUuid(7)))
        XCTAssertNil(sunday.serviceTime)

        // The same document with every item's uuid taken out.
        let path = try XCTUnwrap(machine.documentPaths["playlist/" + F.playlistUuid.uuidString.lowercased()])
        let data = try XCTUnwrap(F.machineSnapshot.files[path])
        var tree = try JSONValue.parse(data)
        let stripped = (tree["items"]?.arrayValue ?? []).map { $0.removing("uuid") }
        tree = tree.setting("items", to: .array(stripped))
        let (handMade, _) = try playlist(JSONCanonical.string(tree))
        XCTAssertEqual(handMade.items.map(\.uuid), sunday.items.map(\.uuid))
    }
}
