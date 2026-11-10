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

    // MARK: - Linked items find their list by uuid

    /// "A linked item finds its list by `listUuid`, so it still finds the list
    /// after a renumber or a swap made on another machine, and the number in
    /// the file is corrected at the playlist's next save."
    func test_aLinkedItemFindsItsListByUuidAfterARenumberMadeElsewhere() throws {
        var (library, machine, _) = F.load()
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        library.lists[index].number = 57   // as a sync would deliver it, the playlist untouched
        let sunday = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        XCTAssertEqual(library.list(for: sunday.items[1].kind)?.uuid, F.listUuid(42))
        XCTAssertEqual(CueAddressing.list(forItem: 2, in: sunday, library: library, machine: machine)?.number, 57)

        let recorded = sunday.recordingLinks(in: library)
        XCTAssertEqual(recorded.items[1].kind, .linked(list: 57, listUuid: F.listUuid(42)))
        machine.replace(playlist: recorded)
        XCTAssertEqual(machine.playlist(uuid: F.playlistUuid)?.items[1].kind, .linked(list: 57, listUuid: F.listUuid(42)))
    }

    /// "When no list has that uuid, the item is missing, even if another list
    /// now has its number", and `next` skips it (choice Q-4).
    func test_aLinkedItemIsMissingWhenOnlyItsNumberSurvives() throws {
        var (library, machine, _) = F.load()
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        var stranger = library.lists[index]
        stranger.uuid = F.uuid("bad0", 42)
        library.lists[index] = stranger   // list 42 is now another list
        machine.settings.libraryMode = .writable
        let sunday = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        XCTAssertNil(library.list(for: sunday.items[1].kind))
        XCTAssertNil(CueAddressing.list(forItem: 2, in: sunday, library: library, machine: machine))

        // Every item that linked list 42: Sunday's, Sunday Night's two and the archived copy's.
        let report = Validator.validate(library: library, machine: machine)
        XCTAssertEqual(report.issues(.missingList).count, 4)
        XCTAssertTrue(report.issues(.missingList).map(\.subject).contains("playlist Sunday 2026-11-01 item 2"))

        // From the playlist loaded, `next` skips the missing item to the local copy.
        var state = ShowState.fresh(library: library, machine: machine)
        state.pointer = LivePointer(playlist: F.playlistUuid)
        let context = ProjectionContext(frame: 0, library: library, machine: machine, source: CommandSource(kind: .osc))
        let (after, _) = project(state, [.next], context: context)
        XCTAssertEqual(after.pointer?.listUuid, F.localCopyUuid)
    }

    /// "An item without a `listUuid`, from a hand-made file, finds its list
    /// by number and records that list's uuid at the next save."
    func test_anItemWithoutAListUuidFindsItsListByNumberAndRecordsIt() throws {
        let (library, _, _) = F.load()
        let (handMade, _) = try playlist(document(items: #"{ "kind": "linked", "list": 7, "uuid": "4d4d0000-0000-4000-8000-000000000007" }"#))
        XCTAssertEqual(library.list(for: handMade.items[0].kind)?.uuid, F.listUuid(7))
        let recorded = handMade.recordingLinks(in: library)
        XCTAssertEqual(recorded.items[0].kind, .linked(list: 7, listUuid: F.listUuid(7)))
        let saved = try JSONValue.parse(Writer.data(for: .playlist(recorded)))
        XCTAssertEqual(saved["items"]?[0]?["listUuid"]?.stringValue, F.listUuid(7).uuidString.lowercased())
        // One whose number names no list stays as it is.
        let (orphan, _) = try playlist(document(items: #"{ "kind": "linked", "list": 99, "uuid": "4d4d0000-0000-4000-8000-000000000099" }"#))
        XCTAssertEqual(orphan.recordingLinks(in: library), orphan)
    }

    // MARK: - Loading by title

    func load(_ title: String, _ machine: Machine, library: Library? = nil) -> ShowState {
        let library = library ?? F.load().library
        let context = ProjectionContext(frame: 0, library: library, machine: machine, source: CommandSource(kind: .osc))
        return project(ShowState.fresh(library: library, machine: machine), [.playlistLoad(title: title)], context: context).0
    }

    /// "A playlist's title is its identity on the machine: trimmed of spaces
    /// at either end, never empty, and unique without regard to case.
    /// `playlist "TITLE"` therefore names one playlist."
    func test_playlistTitleLoadsByTitleTrimmedAndIgnoringCase() throws {
        let (library, machine, _) = F.load()
        XCTAssertEqual(load("  sunday ", machine).pointer, LivePointer(playlist: F.playlistUuid))
        XCTAssertNil(load("Sunday Evening", machine).pointer)
        let validation = ValidationContext(library: library, machine: machine)
        XCTAssertNil(CommandValidator.validate(.playlistLoad(title: " SUNDAY"), context: validation))
        XCTAssertEqual(CommandValidator.validate(.playlistLoad(title: "Nope"), context: validation)?.reason, .noSuchTarget)
    }

    /// "A `playlist.load` stored with a `date`, from before this spec, loads
    /// by its title and ignores the date." The date stays in the stored
    /// command as an unknown key (Spec 1 §8).
    func test_aStoredLoadWithADateLoadsByTitleAndKeepsTheDate() throws {
        let stored = try JSONCoding.decode(GuardedCommand.self, from: JSONValue.parse(
            #"{ "cmd": "playlist.load", "date": "2025-01-01", "title": "Sunday" }"#))
        XCTAssertEqual(stored.command, .playlistLoad(title: "Sunday"))
        XCTAssertEqual(stored.extra["date"], .string("2025-01-01"))
        XCTAssertEqual(try JSONCoding.encode(stored)["date"], .string("2025-01-01"))
        let (_, machine, _) = F.load()
        XCTAssertEqual(load("Sunday", machine).pointer, LivePointer(playlist: F.playlistUuid))
    }

    /// "Two playlists with the same title both load. `playlist "TITLE"`
    /// loads the one whose file has the plain slug, or else the one whose
    /// path sorts first, which no save changes".
    func test_twoPlaylistsWithOneTitleLoadThePlainSlugElseThePathThatSortsFirst() throws {
        var (_, machine, _) = F.load()
        let other = F.uuid("2b2b", 1)
        var second = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        second.uuid = other
        second.title = "SUNDAY"
        machine.playlists.append(second)
        let key = { (uuid: UUID) in "playlist/" + uuid.uuidString.lowercased() }

        machine.documentPaths[key(F.playlistUuid)] = "playlists/2026-11-01-sunday.json"
        machine.documentPaths[key(other)] = "playlists/sunday.json"
        XCTAssertEqual(load("Sunday", machine).pointer?.playlist, other, "the plain slug")
        machine.playlists.reverse()
        XCTAssertEqual(load("Sunday", machine).pointer?.playlist, other, "whatever the order they loaded in")

        machine.documentPaths[key(other)] = "playlists/2026-11-08-sunday.json"
        XCTAssertEqual(load("sunday", machine).pointer?.playlist, F.playlistUuid, "else the path that sorts first")
        XCTAssertEqual(machine.playlist(titled: "Sunday")?.uuid, F.playlistUuid)
    }

    // MARK: - Files

    /// "A playlist's file name is a slug of its title, made the way list file
    /// names are (Spec 1 §5): `playlists/sunday.json`. A title with no letters
    /// or digits uses the playlist's uuid. When that name belongs to another
    /// playlist's file, the engine takes the first free one of `sunday-2.json`,
    /// `sunday-3.json` and so on".
    func test_aPlaylistFileIsNamedFromItsTitleWithTheFirstFreeSuffix() throws {
        let (_, machine, _) = F.load()
        var sunday = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        XCTAssertEqual(FileLayout.path(for: .playlist(sunday)), "playlists/sunday.json", "the date is never part of the name")
        XCTAssertEqual(FileLayout.playlistPath(for: sunday, taken: []), "playlists/sunday.json")
        XCTAssertEqual(FileLayout.playlistPath(for: sunday, taken: ["playlists/sunday.json"]), "playlists/sunday-2.json")
        XCTAssertEqual(FileLayout.playlistPath(for: sunday, taken: ["playlists/sunday.json", "playlists/sunday-2.json"]),
                       "playlists/sunday-3.json")
        sunday.title = "!!!"
        XCTAssertEqual(FileLayout.playlistPath(for: sunday, taken: []), "playlists/b1a70000-0000-4000-8000-000000000001.json")
    }

    /// "… and keeps it until the title changes": a save writes a playlist
    /// where its file is, whatever the name, so no save changes which of two
    /// playlists sharing a title loads (Spec 1 §5 as Spec 7 §3 corrects it).
    func test_aSaveKeepsAPlaylistsFileName() throws {
        let (_, machine, _) = F.load()
        let sunday = try XCTUnwrap(machine.playlist(uuid: F.playlistUuid))
        for current in ["playlists/sunday-2.json", "playlists/2026-11-01-sunday.json"] {
            let plan = Writer.save(.playlist(sunday), currentPath: current)
            XCTAssertEqual(plan.operations.count, 1)
            guard case .replace(let path, _) = plan.operations.first else { return XCTFail("\(plan)") }
            XCTAssertEqual(path, current)
        }
        guard case .replace(let path, _) = Writer.save(.playlist(sunday)).operations.first else { return XCTFail() }
        XCTAssertEqual(path, "playlists/sunday.json", "a new playlist takes its plain name")
    }

    /// Spec 7 §8 — "A second playlist, "Sunday Night", links list 42 twice,
    /// for the pointer tests, and an archived copy of "Sunday", "Sunday
    /// 2026-11-01", joins them."
    func test_theFixturePlaylistsLoadFromTheirTitlesFiles() throws {
        let (_, machine, report) = F.load()
        XCTAssertEqual(report.issues, [])
        let key = { (uuid: UUID) in machine.documentPaths[FileLayout.documentKey(playlist: uuid)] }
        XCTAssertEqual(key(F.playlistUuid), "playlists/sunday.json")
        XCTAssertEqual(machine.playlist(uuid: F.playlistUuid)?.serviceDate, "2026-11-01")

        let night = try XCTUnwrap(machine.playlist(titled: "Sunday Night"))
        XCTAssertEqual(key(night.uuid), "playlists/sunday-night.json")
        let links42 = night.items.filter { $0.kind == .linked(list: 42, listUuid: F.listUuid(42)) }
        XCTAssertEqual(links42.count, 2)
        XCTAssertEqual(Set(links42.map(\.uuid)).count, 2, "two items, two uuids")
        XCTAssertEqual(night.serviceTime, "18:00")
        XCTAssertNil(night.serviceDate)

        let archived = try XCTUnwrap(machine.playlist(titled: "Sunday 2026-11-01"))
        XCTAssertEqual(key(archived.uuid), "playlists/sunday-2026-11-01.json")
        XCTAssertTrue(archived.archived)
        XCTAssertEqual(archived.serviceDate, "2026-11-01")
        XCTAssertEqual(archived.items.map(\.kind), machine.playlist(uuid: F.playlistUuid)?.items.map(\.kind))
        XCTAssertTrue(Set(archived.items.map(\.uuid)).isDisjoint(with: sundayItems(machine)), "the copy has new uuids for its items")
    }

    func sundayItems(_ machine: Machine) -> Set<UUID> {
        Set(machine.playlist(uuid: F.playlistUuid)?.items.map(\.uuid) ?? [])
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
