import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §5, "The Playlists window" — "a tree of the machine's playlists:
/// undated ones first, by title, then dated ones, newest date first (Spec 1
/// §3). Archived playlists are hidden unless View ▸ Show Archived Playlists
/// is on (L4); then they show grayed with an "archived" tag. A playlist
/// expands to its items: headers in small capitals, linked items with their
/// list's title, an item whose list is missing in red, and a local item with
/// its "local" tag (Spec 7 §3). One playlist is expanded at a time; ⌥-click
/// expands another as well."
final class PlaylistTreeTests: XCTestCase {
    private func playlist(_ title: String, date: String? = nil, time: String? = nil, archived: Bool = false, n: Int) -> CatalogPlaylist {
        var playlist = Playlist(uuid: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(n < 10 ? "0" : "")\(n)") ?? UUID(), title: title,
                                serviceDate: date, serviceTime: time, items: [])
        playlist.archived = archived
        return CatalogPlaylist(playlist: playlist)
    }

    func test_undatedPlaylistsComeFirstByTitleThenDatedOnesNewestFirst() {
        let ordered = PlaylistTree.ordered([
            playlist("Sunday", date: "2026-11-01", n: 1), playlist("Youth 10", n: 2), playlist("Christmas Eve", date: "2026-12-24", n: 3),
            playlist("youth 2", n: 4), playlist("Sunday", date: "2026-11-08", n: 5),
        ], showArchived: false)
        XCTAssertEqual(ordered.map(\.playlist.title), ["youth 2", "Youth 10", "Christmas Eve", "Sunday", "Sunday"],
                       "titles as the Finder sorts them: case ignored, numbers by value")
        XCTAssertEqual(ordered.map(\.playlist.serviceDate), [nil, nil, "2026-12-24", "2026-11-08", "2026-11-01"])
    }

    func test_playlistsOfOneDateGoByTheirTimeThenTheirTitle() {
        // Area 13 reading — Spec 1 §3 gives the order by date only.
        let ordered = PlaylistTree.ordered([
            playlist("Second", date: "2026-11-01", time: "11:00", n: 1), playlist("First", date: "2026-11-01", time: "09:00", n: 2),
            playlist("Beta", date: "2026-11-01", n: 3), playlist("Alpha", date: "2026-11-01", n: 4),
        ], showArchived: false)
        XCTAssertEqual(ordered.map(\.playlist.title), ["Alpha", "Beta", "First", "Second"], "no time first, then by time")
    }

    func test_archivedPlaylistsShowOnlyWhenAsked() throws {
        let catalog = try Recorded.catalog()
        XCTAssertEqual(PlaylistTree.ordered(catalog.playlists, showArchived: false).map(\.playlist.title), ["Sunday Night", "Sunday"])
        XCTAssertEqual(PlaylistTree.ordered(catalog.playlists, showArchived: true).map(\.playlist.title), ["Sunday Night", "Sunday", "Sunday 2026-11-01"])
        let rows = PlaylistTree.rows(catalog: catalog, live: LiveStatus(), expanded: [], shown: nil, showArchived: true)
        XCTAssertEqual(rows.map(\.isArchived), [false, false, true], "grayed with an \"archived\" tag")
    }

    func test_aPlaylistExpandsToItsItems() throws {
        let rows = PlaylistTree.rows(catalog: try Recorded.catalog(), live: LiveStatus(), expanded: [Recorded.sunday], shown: .playlist(Recorded.sunday),
                                     showArchived: false)
        XCTAssertEqual(rows.map(\.kind), [.playlist, .playlist, .header, .item, .item, .header, .item])
        XCTAssertEqual(rows.map(\.title), ["Sunday Night", "Sunday", "Welcome", "Great Is Thy Faithfulness", "Great Is Thy Faithfulness (Manheim)",
                                           "Response", "Doxology"])
        XCTAssertEqual(rows.map(\.item), [nil, nil, 1, 2, 3, 4, 5])
        XCTAssertEqual(rows.map(\.isLocal), [false, false, false, false, true, false, false], "a local item with its \"local\" tag")
        XCTAssertEqual(rows.map(\.isExpanded), [false, true, false, false, false, false, false])
        XCTAssertEqual(rows.map(\.isBrowsed), [false, true, false, false, false, false, false])
        XCTAssertEqual(rows[1].date, "2026-11-01")
    }

    func test_anItemWhoseListIsMissingSaysSo() throws {
        var catalog = try Recorded.catalog()
        catalog.lists.removeAll { $0.uuid == Recorded.list7 }
        let rows = PlaylistTree.rows(catalog: catalog, live: LiveStatus(), expanded: [Recorded.sunday], shown: nil, showArchived: false)
        XCTAssertEqual(rows.last?.isMissing, true, "an item whose list is missing in red")
        XCTAssertEqual(rows.filter(\.isMissing).count, 1)
    }

    func test_theLivePlaylistAndItsLiveItemCarryTheLiveDot() throws {
        let catalog = try Recorded.catalog()
        let sunday = try XCTUnwrap(catalog.playlist(uuid: Recorded.sunday)).playlist
        var live = LiveStatus()
        live.playlist = Recorded.sunday
        live.item = sunday.items[4].uuid.uuidString.lowercased()
        let open = PlaylistTree.rows(catalog: catalog, live: live, expanded: [Recorded.sunday], shown: .list(Recorded.list42), showArchived: false)
        XCTAssertEqual(open.map(\.isLive), [false, true, false, false, false, false, true], "and keep it while the grid browses elsewhere")
        let closed = PlaylistTree.rows(catalog: catalog, live: live, expanded: [], shown: nil, showArchived: false)
        XCTAssertEqual(closed.map(\.isLive), [false, true], "a closed playlist keeps its dot")
    }

    func test_onePlaylistIsExpandedAtATimeAndOptionClickExpandsAnotherAsWell() {
        XCTAssertEqual(PlaylistTree.expanding("b", in: ["a"], option: false), ["b"])
        XCTAssertEqual(PlaylistTree.expanding("b", in: ["a"], option: true), ["a", "b"])
        XCTAssertEqual(PlaylistTree.expanding("a", in: ["a", "b"], option: true), ["b"], "⌥-click on an open one closes it")
        XCTAssertEqual(PlaylistTree.expanding("a", in: ["a"], option: false), ["a"], "a click on the open one leaves it open")
    }

    func test_aPlaylistWhoseTitleDoesNotLoadItCannotBeMadeLive() throws {
        var catalog = try Recorded.catalog()
        let index = try XCTUnwrap(catalog.playlists.firstIndex { $0.playlist.uuid.uuidString.lowercased() == Recorded.sunday })
        catalog.playlists[index].named = false
        let rows = PlaylistTree.rows(catalog: catalog, live: LiveStatus(), expanded: [], shown: nil, showArchived: false)
        XCTAssertEqual(rows.map(\.refusal), [nil, .renameToFire])
    }
}

/// Spec 10 §5, "The Library window" — "Its tree is the library's real
/// folders (Spec 7 §2), with each list showing its title and, dimmed at the
/// right, its number." "Search at the top matches titles, authors and CCLI
/// numbers across every folder and shows the matches as a flat list with
/// their folders."
final class LibraryTreeTests: XCTestCase {
    func test_theTreeIsTheLibrarysFoldersWithTheirLists() throws {
        let rows = LibraryTree.rows(catalog: try Recorded.catalog(), open: ["Hymns"], search: "")
        XCTAssertEqual(rows.map(\.kind), [.folder, .folder, .list, .list])
        XCTAssertEqual(rows.map(\.title), ["Christmas", "Hymns", "Great Is Thy Faithfulness", "Doxology"])
        XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 0], "folders first, then the lists at the top")
        XCTAssertEqual(rows.map(\.number), [nil, nil, 42, 7])
        XCTAssertEqual(rows.map(\.isOpen), [false, true, false, false])
        XCTAssertFalse(rows.contains { $0.title.contains("Manheim") }, "a local copy belongs to its playlist, not to the library")
    }

    func test_aClosedFolderHidesWhatIsInIt() throws {
        let rows = LibraryTree.rows(catalog: try Recorded.catalog(), open: [], search: "")
        XCTAssertEqual(rows.map(\.title), ["Christmas", "Hymns", "Doxology"])
    }

    func test_foldersNestAndSortAsTheFinderDoes() {
        var catalog = Catalog()
        catalog.folders = ["Hymns", "Hymns/Advent", "hymns 2", "Hymns/Advent/Week 10", "Hymns/Advent/Week 2"]
        catalog.lists = [ListSummary(number: 3, uuid: "c", title: "O Come", folder: "Hymns/Advent"),
                         ListSummary(number: 1, uuid: "a", title: "Abide with Me", folder: "Hymns")]
        let rows = LibraryTree.rows(catalog: catalog, open: ["Hymns", "Hymns/Advent"], search: "")
        XCTAssertEqual(rows.map(\.title), ["Hymns", "Advent", "Week 2", "Week 10", "O Come", "Abide with Me", "hymns 2"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 2, 1, 0])
        XCTAssertEqual(rows.map(\.path), ["Hymns", "Hymns/Advent", "Hymns/Advent/Week 2", "Hymns/Advent/Week 10", "Hymns/Advent", "Hymns", "hymns 2"])
    }

    func test_searchMatchesTitlesAuthorsAndCcliNumbersAcrossEveryFolder() throws {
        var catalog = try Recorded.catalog()
        let index = try XCTUnwrap(catalog.lists.firstIndex { $0.uuid == Recorded.list7 })
        catalog.lists[index].author = "Thomas Ken"
        let byTitle = LibraryTree.rows(catalog: catalog, open: [], search: "faithfulness")
        XCTAssertEqual(byTitle.map(\.title), ["Great Is Thy Faithfulness"], "a flat list, whatever is open")
        XCTAssertEqual(byTitle.map(\.path), ["Hymns"], "with their folders")
        XCTAssertEqual(byTitle.map(\.depth), [0])
        XCTAssertEqual(LibraryTree.rows(catalog: catalog, open: [], search: "KÉN").map(\.title), ["Doxology"], "authors, whatever the case or the accents")
        XCTAssertEqual(LibraryTree.rows(catalog: catalog, open: [], search: "562").map(\.title), ["Doxology"], "a CCLI number from its first digit")
        XCTAssertEqual(LibraryTree.rows(catalog: catalog, open: [], search: "204").map(\.title), [], "not from its middle")
        XCTAssertEqual(LibraryTree.rows(catalog: catalog, open: [], search: "zzz"), [])
    }

    func test_aListWhoseNumberAnotherSharesCannotBeFiredFromThere() {
        var catalog = Catalog()
        catalog.lists = [ListSummary(number: 42, uuid: "a", title: "One"), ListSummary(number: 42, uuid: "b", title: "Two", named: false)]
        XCTAssertEqual(LibraryTree.rows(catalog: catalog, open: [], search: "").map(\.refusal), [nil, .renumberToFire])
    }
}
