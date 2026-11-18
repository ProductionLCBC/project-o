import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 10 §5, "Dragging", and §6, "Drops on the grid" — the drags as the
/// rows and headers carry and take them. A drag itself needs a screen and a
/// pointer; what each row puts on the pasteboard, what a target would do
/// with it and what letting go there sends are tested here.
@MainActor
final class DragsViewTests: XCTestCase {
    typealias Rig = EditsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private let upper = NSPoint(x: 20, y: 4)
    private let lower = NSPoint(x: 20, y: RowView.height - 4)

    func test_aDragGoesOnThePasteboardAndReadsBackAndTheFindersFilesReadAsFiles() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("o-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        for payload in [DragPayload.item(playlist: "b1a7", item: "ae3a"), .list("a9f0"), .folder("Worship/Hymns"), .media("sha256:9f2c")] {
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.writeObjects([Dragging.item(for: payload)]))
            XCTAssertEqual(Dragging.payload(from: pasteboard), payload)
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(fileURLWithPath: "/Users/x/Movies/Ocean loop.mov"), NSURL(fileURLWithPath: "/Users/x/Pictures/cross.png")])
        XCTAssertEqual(Dragging.payload(from: pasteboard), .files(["/Users/x/Movies/Ocean loop.mov", "/Users/x/Pictures/cross.png"]))
        pasteboard.clearContents()
        pasteboard.setString("just words", forType: .string)
        XCTAssertNil(Dragging.payload(from: pasteboard), "anything else is nothing the app takes")
    }

    /// "Items drag to reorder (`… item I move K`)."
    func test_anItemsRowIsDraggedAndDroppedBetweenItemsToReorder() throws {
        let rig = try Rig()
        rig.expand(EditsViewTests.sundayNight)
        let items = try XCTUnwrap(rig.model.store.catalog?.playlist(uuid: EditsViewTests.sundayNight)?.playlist.items).map { $0.uuid.uuidString.lowercased() }
        let rows = rig.view.left.playlists.rows.filter { $0.dragPayload != nil }
        XCTAssertEqual(rows.map(\.dragPayload), items.map { .item(playlist: EditsViewTests.sundayNight, item: $0) }, "each item's row, the header's too")
        XCTAssertTrue(rows.allSatisfy(\.dropsBetween))
        let first = try XCTUnwrap(rows.first?.dragPayload)
        // The header, dropped below the last item: it ends last.
        XCTAssertEqual(rows[3].plan(for: first, at: lower).sending?.text, ["edit playlist \(EditsViewTests.sundayNight) item \(items[0]) move 3"])
        XCTAssertEqual(rows[0].plan(for: first, at: lower), .none, "beside itself: nothing")
        XCTAssertTrue(rows[3].accept(first, at: lower))
        XCTAssertEqual(rig.commands, [["edit playlist \(EditsViewTests.sundayNight) item \(items[0]) move 3"]])
        XCTAssertFalse(rows[0].accept(first, at: upper))
        XCTAssertEqual(rig.sent.count, 1)
    }

    /// "A list dragged from the Library window ... is inserted where it
    /// lands"; "Dragging a list onto a folder moves it ..., onto the tree's
    /// empty space moves it to the top ..., and onto a playlist in the
    /// Playlists window inserts it there. A folder dragged onto another
    /// moves into it".
    func test_aListAndAFolderAreDraggedFromTheLibrary() throws {
        let rig = try Rig()
        rig.model.toggle(folder: "Hymns")
        rig.expand(EditsViewTests.sundayNight)
        let list = try XCTUnwrap(try rig.libraryRow("Great Is Thy Faithfulness").dragPayload)
        XCTAssertEqual(list, .list(EditsViewTests.list42))
        let linked = "{ \"kind\": \"linked\", \"list\": 42, \"listUuid\": \"\(EditsViewTests.list42)\" }"
        // Onto a playlist's row: after its last item.
        XCTAssertTrue(try rig.playlistRow("Sunday").accept(list, at: upper))
        // Between two items of the open playlist.
        let song = try XCTUnwrap(rig.view.left.playlists.rows.first { $0.title.stringValue == "Doxology" })
        XCTAssertTrue(song.accept(list, at: upper))
        // Onto another folder, and onto the tree's empty space.
        XCTAssertTrue(try rig.libraryRow("Christmas").accept(list, at: upper))
        XCTAssertEqual(rig.view.left.library.planDrop?(list).sending?.text, ["edit list 42 folder \"\""])
        // A folder into a folder; and not onto a list, which takes nothing.
        let hymns = try XCTUnwrap(try rig.libraryRow("Hymns").dragPayload)
        XCTAssertEqual(hymns, .folder("Hymns"))
        XCTAssertTrue(try rig.libraryRow("Christmas").accept(hymns, at: upper))
        XCTAssertFalse(try rig.libraryRow("Great Is Thy Faithfulness").accept(hymns, at: upper))
        XCTAssertEqual(rig.commands, [
            ["edit playlist \(EditsViewTests.sunday) insert items 5 \(linked)"],
            ["edit playlist \(EditsViewTests.sundayNight) insert items 2 \(linked)"],
            ["edit list 42 folder \"Christmas\""],
            ["edit folder \"Hymns\" rename \"Christmas/Hymns\""],
        ])
    }

    func test_aDropThatCannotBeDoneSaysWhyBesideIt() throws {
        let rig = try Rig()
        try rig.lock()
        XCTAssertTrue(try rig.playlistRow("Sunday").accept(.list(EditsViewTests.list42), at: upper), "it may be let go there")
        XCTAssertEqual(rig.sent.count, 0)
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.left.notice.stringValue, "Not sent. The station is locked.")
        // An archived playlist takes nothing.
        try rig.lock(false)
        rig.model.change { $0.showsArchivedPlaylists = true }
        rig.view.layoutSubtreeIfNeeded()
        let archived = try XCTUnwrap(rig.view.left.playlists.rows.first { $0.shownTags.contains("archived") })
        XCTAssertEqual(archived.plan(for: .list(EditsViewTests.list42), at: upper), .refused(.archived))
    }

    /// "A list dragged from the Library window onto a playlist's list header
    /// is inserted above it, and below the last list when dropped past it."
    func test_aListDroppedOnAListHeaderInTheGridIsInsertedAboveItAndPastTheLastBelowIt() throws {
        let rig = try Rig()
        let headers = rig.view.grid.document.headers.compactMap { $0.view as? ListHeaderView }
        let items = try XCTUnwrap(rig.model.store.catalog?.playlist(uuid: EditsViewTests.sunday)?.playlist.items).map { $0.uuid.uuidString.lowercased() }
        let last = try XCTUnwrap(headers.last)
        XCTAssertEqual(last.section.itemUuid, items[4])
        let doxology = DragPayload.list("a9f00000-0000-4000-8000-000000000007")
        let linked = "{ \"kind\": \"linked\", \"list\": 7, \"listUuid\": \"a9f00000-0000-4000-8000-000000000007\" }"
        XCTAssertTrue(last.accept(doxology))
        XCTAssertTrue(rig.view.grid.document.acceptPastEnd(doxology))
        XCTAssertEqual(rig.commands, [["edit playlist \(EditsViewTests.sunday) insert items 4 \(linked)"], ["edit playlist \(EditsViewTests.sunday) insert items 5 \(linked)"]])
        XCTAssertFalse(last.accept(.folder("Hymns")), "a folder is nothing a playlist takes")
        // A list opened from the library has no items to insert among.
        rig.model.browse(.list(EditsViewTests.list42))
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(rig.view.grid.document.acceptPastEnd(doxology))
        XCTAssertEqual(rig.sent.count, 2)
    }
}
