import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §5, "Dragging", and §6, "Drops on the grid" — what a drag carries
/// and what landing it somewhere sends.
final class DropPlanTests: XCTestCase {
    private let sunday = Recorded.sunday

    private func plan(_ payload: DragPayload, onto target: DropTarget, machine: Unavailable? = nil, masters: Unavailable? = nil) throws -> DropPlan {
        Drops.plan(payload, onto: target, catalog: try Recorded.catalog(), cannotEditMachine: machine, cannotEditMasters: masters)
    }

    private func items() throws -> [String] {
        try XCTUnwrap(try Recorded.catalog().playlist(uuid: sunday)?.playlist.items).map { $0.uuid.uuidString.lowercased() }
    }

    func test_aPayloadGoesOnThePasteboardAsTextAndReadsBack() {
        let payloads: [DragPayload] = [.item(playlist: "b1a7", item: "ae3a"), .list("a9f0"), .folder("Worship/Hymns"), .folder(""), .media("sha256:9f2c"),
                                       .files(["/Users/x/Movies/Ocean loop.mov"]), .files(["/a b/c.mov", "/d.png"])]
        for payload in payloads { XCTAssertEqual(DragPayload(text: payload.text), payload, payload.text) }
        for text in ["", "list", "item\na", "nothing\nx", "files"] { XCTAssertNil(DragPayload(text: text), text) }
    }

    /// "Items drag to reorder (`… item I move K`)": K is where the item ends.
    func test_anItemDraggedWithinItsPlaylistMovesToWhereItLands() throws {
        let items = try items()
        // The first list (the second of five items) dropped below the last item: it ends last.
        let down = try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[4], below: true))
        XCTAssertEqual(down.sending?.text, ["edit playlist \(sunday) item \(items[1]) move 4"])
        // The last item dropped above the first: it ends first.
        let up = try plan(.item(playlist: sunday, item: items[4]), onto: .item(playlist: sunday, item: items[0], below: false))
        XCTAssertEqual(up.sending?.text, ["edit playlist \(sunday) item \(items[4]) move 0"])
        // Dropped above the item two places down, it ends one place down.
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[3], below: false)).sending?.text,
                       ["edit playlist \(sunday) item \(items[1]) move 2"])
        // Where it already is, on either side of itself or beside its neighbor: nothing.
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[1], below: false)), .none)
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[1], below: true)), .none)
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[2], below: false)), .none)
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[0], below: true)), .none)
        // Area 13 reading — an item isn't dragged into another playlist.
        let night = try XCTUnwrap(try Recorded.catalog().playlist(uuid: Recorded.sundayNight)?.playlist.items.first).uuid.uuidString.lowercased()
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: Recorded.sundayNight, item: night, below: false)), .none)
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .playlist(Recorded.sundayNight)), .none)
    }

    /// "A list dragged from the Library window ... is inserted where it
    /// lands (`edit playlist P insert items K {"kind": "linked", ...}`)";
    /// "onto a playlist in the Playlists window inserts it there".
    func test_aListDraggedIntoAPlaylistIsInsertedWhereItLands() throws {
        let items = try items()
        let linked = "{ \"kind\": \"linked\", \"list\": 7, \"listUuid\": \"\(Recorded.list7)\" }"
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .playlist(sunday)).sending?.text, ["edit playlist \(sunday) insert items 5 \(linked)"],
                       "onto the playlist's row: after its last item")
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .item(playlist: sunday, item: items[1], below: false)).sending?.text,
                       ["edit playlist \(sunday) insert items 1 \(linked)"])
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .item(playlist: sunday, item: items[1], below: true)).sending?.text,
                       ["edit playlist \(sunday) insert items 2 \(linked)"])
        // "onto a playlist's list header is inserted above it, and below the last list when dropped past it."
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .listHeader(playlist: sunday, item: items[4])).sending?.text,
                       ["edit playlist \(sunday) insert items 4 \(linked)"])
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .listHeader(playlist: sunday, item: nil)).sending?.text,
                       ["edit playlist \(sunday) insert items 5 \(linked)"])
        // A local copy isn't a library list.
        XCTAssertEqual(try plan(.list(Recorded.localCopy), onto: .playlist(sunday)), .none)
        XCTAssertEqual(try plan(.media("sha256:9f2c"), onto: .playlist(sunday)), .none)
    }

    func test_anArchivedPlaylistAndALockedStationRefuseWithTheReason() throws {
        let archived = try XCTUnwrap(try Recorded.catalog().playlists.first { $0.playlist.archived }).playlist.uuid.uuidString.lowercased()
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .playlist(archived)), .refused(.archived))
        XCTAssertEqual(try plan(.list(Recorded.list7), onto: .playlist(sunday), machine: .locked), .refused(.unavailable(.locked)))
        let items = try items()
        XCTAssertEqual(try plan(.item(playlist: sunday, item: items[1]), onto: .item(playlist: sunday, item: items[4], below: true), machine: .engineAway),
                       .refused(.unavailable(.engineAway)))
        // Masters read-only: a list still goes into a playlist, which is this Mac's; it isn't moved in the library.
        XCTAssertTrue(try plan(.list(Recorded.list7), onto: .playlist(sunday), masters: .readOnlyMasters).isAccepted)
        XCTAssertEqual(try plan(.list(Recorded.list42), onto: .folder("Christmas"), masters: .readOnlyMasters), .refused(.unavailable(.readOnlyMasters)))
    }

    /// "Dragging a list onto a folder moves it (`edit list N folder "PATH"`),
    /// onto the tree's empty space moves it to the top (`""`) ... A folder
    /// dragged onto another moves into it (a rename with the new parent)."
    func test_aListOrAFolderDraggedInTheLibraryMoves() throws {
        let catalog = try Recorded.catalog()
        let list42 = try XCTUnwrap(catalog.list(uuid: Recorded.list42))
        XCTAssertEqual(list42.folder, "Hymns")
        XCTAssertEqual(try plan(.list(Recorded.list42), onto: .folder("Christmas")).sending?.text, ["edit list 42 folder \"Christmas\""])
        XCTAssertEqual(try plan(.list(Recorded.list42), onto: .libraryTop).sending?.text, ["edit list 42 folder \"\""])
        XCTAssertEqual(try plan(.list(Recorded.list42), onto: .folder("Hymns")), .none, "it is there already")
        XCTAssertEqual(try plan(.folder("Hymns"), onto: .folder("Christmas")).sending?.text, ["edit folder \"Hymns\" rename \"Christmas/Hymns\""])
        XCTAssertEqual(try plan(.folder("Christmas/Carols"), onto: .libraryTop).sending?.text, ["edit folder \"Christmas/Carols\" rename \"Carols\""])
        XCTAssertEqual(try plan(.folder("Hymns"), onto: .libraryTop), .none, "it is at the top already")
        XCTAssertEqual(try plan(.folder("Hymns"), onto: .folder("Hymns")), .none, "not into itself")
        XCTAssertEqual(try plan(.folder("Hymns"), onto: .folder("Hymns/Old")), .none, "nor into a folder inside it")
        XCTAssertEqual(try plan(.folder("Christmas/Carols"), onto: .folder("Christmas")), .none, "it is in that folder already")
        XCTAssertEqual(try plan(.item(playlist: sunday, item: "x"), onto: .folder("Hymns")), .none)
        // Adam's answer to the plan — a list whose number another shares takes no edit: "Renumber to edit".
        var twins = catalog
        twins.lists = twins.lists.map { list in
            var list = list
            if list.uuid == Recorded.list42 { list.named = false }
            return list
        }
        XCTAssertEqual(Drops.plan(.list(Recorded.list42), onto: .folder("Christmas"), catalog: twins, cannotEditMachine: nil, cannotEditMasters: nil),
                       .refused(.renumberToEdit))
        XCTAssertTrue(Drops.plan(.list(Recorded.list42), onto: .playlist(sunday), catalog: twins, cannotEditMachine: nil, cannotEditMasters: nil).isAccepted,
                      "an insert names the list by its uuid")
    }
}
