import Foundation
import XCTest
@testable import OCore

/// Spec 7 §10 — "Playlists. Titles are trimmed, unique ignoring case, never
/// empty, and can change case. File names come from titles, with the first
/// free suffix, kept until the title changes ... Inserting a local item is
/// `notInV1`. Duplicate keeps the items and `serviceTime`, with new uuids and
/// no date." And "Archive. `archive` leaves the playlist unchanged, also while
/// it is live, and files a read-only copy titled with its date, or today's,
/// with `(2)` after a space on a clash and never the date twice; its inverse
/// deletes the copy. `archived true` on the live playlist is refused with
/// `onAir`. Other edits to an archived playlist are refused with `archived`,
/// apart from restoring, deleting, duplicating and archiving, and a list
/// renumber still rewrites its links. An archived playlist loads by its title."
final class EditPlaylistTests: XCTestCase {
    typealias F = FixtureLibrary

    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
    static var p: String { u(F.playlistUuid) }
    static var n: String { u(F.sundayNightUuid) }
    static var a: String { u(F.archivedSundayUuid) }

    func path(_ edits: Edits, _ uuid: UUID) -> String? {
        edits.machine.documentPaths[FileLayout.documentKey(playlist: uuid)]
    }

    // MARK: - Titles and files

    func test_titlesAreTrimmedUniqueIgnoringCaseNeverEmptyAndMayChangeCase() throws {
        var edits = Edits()
        let made = edits.apply("edit playlist create \"  Easter  \"")
        let easter = try XCTUnwrap(edits.machine.playlist(uuid: Edits.pick(1)))
        XCTAssertEqual(easter.title, "Easter")
        XCTAssertEqual(easter.items, [])
        XCTAssertNil(easter.serviceDate)
        XCTAssertNil(easter.serviceTime)
        XCTAssertFalse(easter.archived)
        XCTAssertEqual(made.first?.logged, EditCommand(.playlist(Edits.pick(1)), .create(body: nil, folder: nil, title: "Easter")),
                       "the uuid the engine picked is in the address")
        XCTAssertEqual(path(edits, easter.uuid), "playlists/easter.json")

        XCTAssertEqual(edits.refuse("edit playlist create \"SUNDAY\"")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit playlist create \"   \"")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) title \"sunday night\"")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) title \"\"")?.reason, .badValue)
        edits.apply("edit playlist \(Self.p) title \"SUNDAY\"")
        XCTAssertEqual(edits.sunday.title, "SUNDAY", "a change of case alone is allowed")
        XCTAssertEqual(path(edits, F.playlistUuid), "playlists/sunday.json", "and keeps the file's name")
    }

    /// "A playlist's file name is a slug of its title ... When that name
    /// belongs to another playlist's file, the engine takes the first free one
    /// of `sunday-2.json`, `sunday-3.json` and so on, and keeps it until the
    /// title changes."
    func test_fileNamesComeFromTitlesWithTheFirstFreeSuffixKeptUntilTheTitleChanges() throws {
        var edits = Edits()
        edits.apply("edit playlist create \"Sunday-Night!\"")
        let second = Edits.pick(1)
        XCTAssertEqual(path(edits, second), "playlists/sunday-night-2.json")
        edits.apply("edit playlist \(Self.u(second)) serviceTime \"19:00\"")
        XCTAssertEqual(path(edits, second), "playlists/sunday-night-2.json", "kept: the title didn't change")
        edits.apply("edit playlist \(Self.u(second)) title \"Late Service\"")
        XCTAssertEqual(path(edits, second), "playlists/late-service.json")
        edits.apply("edit playlist create \"???\"")
        XCTAssertEqual(path(edits, Edits.pick(2)), "playlists/\(Self.u(Edits.pick(2))).json", "no letter or digit: the uuid")
    }

    func test_datesAndTimes() throws {
        var edits = Edits()
        edits.apply("edit playlist \(Self.n) serviceDate \"2026-12-24\"")
        XCTAssertEqual(edits.night.serviceDate, "2026-12-24")
        edits.apply("edit playlist \(Self.n) serviceTime null")
        XCTAssertNil(edits.night.serviceTime)
        for bad in ["\"2026-13-01\"", "\"2026-02-30\"", "\"26-11-08\"", "\"2026-11-8\"", "8"] {
            XCTAssertEqual(edits.refuse("edit playlist \(Self.n) serviceDate \(bad)")?.reason, .badValue, bad)
        }
        for bad in ["\"24:00\"", "\"9:30\"", "\"10:60\"", "\"+1:00\""] {
            XCTAssertEqual(edits.refuse("edit playlist \(Self.n) serviceTime \(bad)")?.reason, .badValue, bad)
        }
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) items []")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) uuid \"x\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) colour \"red\"")?.reason, .unknownPath)
    }

    // MARK: - Items

    /// "Inserts an item; the engine adds its `uuid` and `listUuid` and logs
    /// them ... An item inserted with a uuid already in the playlist is
    /// `duplicate`"; "Local items ... v1 creates none and edits none".
    func test_insertingItems() throws {
        var edits = Edits()
        let linked = edits.apply("edit playlist \(Self.n) insert items 1 { \"kind\": \"linked\", \"list\": 7 }")
        let item = edits.night.items[1]
        XCTAssertEqual(item.uuid, Edits.pick(1))
        XCTAssertEqual(item.kind, .linked(list: 7, listUuid: F.listUuid(7)))
        XCTAssertEqual(linked.first?.logged.action, .insert(path: "items", at: 1, value: .object([
            "kind": .string("linked"), "list": .number(7), "listUuid": .string(Self.u(F.listUuid(7))), "uuid": .string(Self.u(Edits.pick(1)))])))
        XCTAssertEqual(linked.first?.inverse, EditCommand(.item(playlist: F.sundayNightUuid, item: Edits.pick(1)), .remove(path: nil, at: nil)))
        // By the list's uuid, which corrects the number.
        edits.apply("edit playlist \(Self.n) insert items 0 { \"kind\": \"linked\", \"list\": 99, \"listUuid\": \"\(Self.u(F.listUuid(42)))\" }")
        XCTAssertEqual(edits.night.items[0].kind, .linked(list: 42, listUuid: F.listUuid(42)))
        edits.apply("edit playlist \(Self.n) insert items 0 { \"kind\": \"header\", \"label\": \"Prelude\" }")
        XCTAssertEqual(edits.night.items[0].kind, .header(label: "Prelude"))

        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) insert items 0 { \"kind\": \"linked\", \"list\": 99 }")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) insert items 0 { \"kind\": \"local\", \"localUuid\": \"\(Self.u(F.localCopyUuid))\" }")?.reason,
                       .notInV1)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) insert items 0 { \"kind\": \"header\", \"label\": \"x\", \"uuid\": \"\(Self.u(Edits.pick(1)))\" }")?.reason,
                       .duplicate)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.n) insert items 99 { \"kind\": \"header\", \"label\": \"x\" }")?.reason, .badValue)
    }

    func test_removingMovingAndRelabellingItems() throws {
        var edits = Edits()
        let items = edits.sunday.items
        edits.apply("edit playlist \(Self.p) item \(Self.u(items[1].uuid)) remove")
        XCTAssertFalse(edits.sunday.items.contains { $0.uuid == items[1].uuid })
        edits.apply("edit playlist \(Self.p) item \(Self.u(items[2].uuid)) remove")
        XCTAssertEqual(edits.sunday.items.count, 3, "a local item is removed from a playlist like any other")
        edits.apply("edit playlist \(Self.p) item \(Self.u(items[0].uuid)) move 2")
        XCTAssertEqual(edits.sunday.items.map(\.uuid), [items[3].uuid, items[4].uuid, items[0].uuid])
        edits.apply("edit playlist \(Self.p) item \(Self.u(items[0].uuid)) label \"Gathering\"")
        XCTAssertEqual(edits.sunday.items[2].kind, .header(label: "Gathering"))
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) item \(Self.u(items[4].uuid)) label \"x\"")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) item \(Self.u(items[4].uuid)) listUuid \"x\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) item \(Self.u(items[1].uuid)) remove")?.reason, .unknownObject)

        var local = Edits()
        XCTAssertEqual(local.refuse("edit playlist \(Self.p) item \(Self.u(items[2].uuid)) label \"x\"")?.reason, .notInV1)
    }

    /// "Copies it under a new title, with new uuids for the playlist and every
    /// item: the same items and `serviceTime`, no `serviceDate`, not archived
    /// (choice Q-2). A local item in the copy points at the same local list".
    func test_duplicateKeepsItemsAndServiceTimeWithNewUuidsAndNoDate() throws {
        var edits = Edits()
        edits.apply("edit playlist \(Self.p) serviceTime \"10:30\"")
        let made = edits.apply("edit playlist \(Self.p) duplicate \"Sunday Evening\"")
        let copy = try XCTUnwrap(edits.machine.playlist(uuid: Edits.pick(1)))
        XCTAssertEqual(copy.title, "Sunday Evening")
        XCTAssertEqual(copy.items.map(\.kind), edits.sunday.items.map(\.kind), "a local item points at the same local list")
        XCTAssertEqual(copy.items.map(\.uuid), (2...6).map(Edits.pick))
        XCTAssertEqual(copy.serviceTime, "10:30")
        XCTAssertNil(copy.serviceDate)
        XCTAssertFalse(copy.archived)
        XCTAssertEqual(made.first?.inverse, EditCommand(.playlist(Edits.pick(1)), .delete))
        XCTAssertEqual(path(edits, copy.uuid), "playlists/sunday-evening.json")
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) duplicate \"sunday evening\"")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) duplicate")?.reason, .badValue, "a copy needs a title")
        // An archived playlist is read, not changed.
        edits.apply("edit playlist \(Self.a) duplicate \"Sunday Again\"")
        XCTAssertFalse(try XCTUnwrap(edits.machine.playlist(titled: "Sunday Again")).archived)
    }

    // MARK: - Spec 7 §5, archive

    func live(_ edits: inout Edits, on playlist: UUID) {
        var state = ShowState()
        state.pointer = LivePointer(playlist: playlist, itemUuid: F.sundayItems[1], listUuid: F.listUuid(42), cueUuid: F.list42Cues[0])
        edits.context.state = state
    }

    func test_archiveFilesADatedReadOnlyCopyAndLeavesThePlaylistAsItWas() throws {
        var edits = Edits()
        live(&edits, on: F.playlistUuid)
        let sunday = edits.sunday
        let filed = edits.apply("edit playlist \(Self.p) archive")
        XCTAssertEqual(edits.sunday, sunday, "P stays exactly as it was, also while it is live")
        let copy = try XCTUnwrap(edits.machine.playlist(uuid: Edits.pick(1)))
        XCTAssertEqual(copy.title, "Sunday 2026-11-01 (2)", "its date, and (2) since the fixture's archive holds the plain name")
        XCTAssertTrue(copy.archived)
        XCTAssertEqual(copy.serviceDate, "2026-11-01")
        XCTAssertEqual(copy.items.map(\.kind), sunday.items.map(\.kind))
        XCTAssertTrue(Set(copy.items.map(\.uuid)).isDisjoint(with: sunday.items.map(\.uuid)))
        XCTAssertEqual(filed.first?.logged, EditCommand(.playlist(F.playlistUuid), .archive(title: "Sunday 2026-11-01 (2)",
            picks: EditPicks(uuid: Edits.pick(1), itemUuids: (2...6).map(Edits.pick)))), "the logged command records the title it made")
        XCTAssertEqual(filed.first?.inverse, EditCommand(.playlist(Edits.pick(1)), .delete))
        XCTAssertEqual(path(edits, copy.uuid), "playlists/sunday-2026-11-01-2.json")

        // An undated playlist takes the day it runs.
        edits.apply("edit playlist \(Self.n) archive")
        XCTAssertNotNil(edits.machine.playlist(titled: "Sunday Night 2026-11-08"))
        // A title that already ends with that date doesn't get it twice.
        edits.apply("edit playlist \(Self.a) archive")
        XCTAssertNotNil(edits.machine.playlist(titled: "Sunday 2026-11-01 (3)"))
        // A title given is used, unique.
        edits.apply("edit playlist \(Self.p) archive \"Sunday (Advent 1)\"")
        XCTAssertTrue(try XCTUnwrap(edits.machine.playlist(titled: "Sunday (Advent 1)")).archived)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) archive \"sunday night\"")?.reason, .duplicate)
    }

    /// "`archived true` archives in place ... It is refused with `onAir` while
    /// that playlist is live ... `archived false` restores either kind."
    func test_archivedInPlaceIsRefusedWhileLiveAndRestoresWithFalse() throws {
        var edits = Edits()
        live(&edits, on: F.playlistUuid)
        XCTAssertEqual(edits.refuse("edit playlist \(Self.p) archived true")?.reason, .onAir)
        edits.apply("edit playlist \(Self.n) archived true")
        XCTAssertTrue(edits.night.archived)
        edits.apply("edit playlist \(Self.n) archived false")
        XCTAssertFalse(edits.night.archived)
        edits.apply("edit playlist \(Self.a) archived false")
        XCTAssertFalse(edits.archived.archived)
    }

    /// "Every edit to an archived playlist is refused with `archived` (Spec 5
    /// §6), except `archived false` and `delete` ... `duplicate` and `archive`
    /// read it and change only their copies, and renumbering or swapping a list
    /// rewrites its links like any reference".
    func test_anArchivedPlaylistIsReadOnly() throws {
        var edits = Edits()
        let item = Self.u(edits.archived.items[0].uuid)
        for text in ["edit playlist \(Self.a) title \"x\"", "edit playlist \(Self.a) serviceDate null",
                     "edit playlist \(Self.a) insert items 0 { \"kind\": \"header\", \"label\": \"x\" }",
                     "edit playlist \(Self.a) item \(item) remove", "edit playlist \(Self.a) item \(item) move 1",
                     "edit playlist \(Self.a) item \(item) label \"x\""] {
            XCTAssertEqual(edits.refuse(text)?.reason, .archived, text)
        }
        edits.apply("edit list 42 renumber 43")
        XCTAssertEqual(edits.archived.items[1].kind, .linked(list: 43, listUuid: F.listUuid(42)))
        edits.apply("edit playlist \(Self.a) delete")
        XCTAssertNil(edits.machine.playlist(uuid: F.archivedSundayUuid))
    }

    /// "An archived playlist can still be loaded by its title and run as it
    /// is, since loading is not an edit (choice Q-6)."
    func test_anArchivedPlaylistLoadsByItsTitle() throws {
        let edits = Edits()
        let context = ProjectionContext(frame: 0, library: edits.library, machine: edits.machine, source: CommandSource(kind: .osc))
        var state = ShowState.fresh(library: edits.library, machine: edits.machine)
        state = project(state, [.playlistLoad(title: "sunday 2026-11-01"), .next], context: context).0
        XCTAssertEqual(state.pointer?.playlist, F.archivedSundayUuid)
        XCTAssertEqual(state.pointer?.cueUuid, F.list42Cues[0])
    }
}
