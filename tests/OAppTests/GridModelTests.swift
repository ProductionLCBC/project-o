import Foundation
import XCTest
import OCore
@testable import OApp

/// The recorded answers of `tests/fixtures/api-v1/`, read as the store reads them.
enum Recorded {
    static let sunday = "b1a70000-0000-4000-8000-000000000001"
    static let sundayNight = "b1a70000-0000-4000-8000-000000000010"
    static let list42 = "a9f00000-0000-4000-8000-00000000002a"
    static let list7 = "a9f00000-0000-4000-8000-000000000007"
    static let localCopy = "10ca1000-0000-4000-8000-00000000002a"
    static let cues42 = ["11aa0000-0000-4000-8000-000000000001", "22bb0000-0000-4000-8000-000000000002",
                         "33cc0000-0000-4000-8000-000000000003", "44dd0000-0000-4000-8000-000000000004"]

    static func catalog() throws -> Catalog {
        try XCTUnwrap(Catalog(answer: RecordedAPI.load("catalog")))
    }

    static func list(_ name: String) throws -> ListDocument {
        try XCTUnwrap(ListDocument(answer: RecordedAPI.load(name)))
    }

    static func media() throws -> [MediaItem] {
        MediaItem.items(answer: try RecordedAPI.load("media")).items
    }

    /// The grid's inputs with the catalog, the media and the three lists the fixture's playlists show.
    static func inputs(_ context: GridContext?) throws -> GridInputs {
        var inputs = GridInputs(context: context, catalog: try catalog())
        inputs.media = try media()
        for name in ["list-42", "list-7", "list-local"] {
            let document = try list(name)
            inputs.lists[document.uuid] = document
        }
        return inputs
    }
}

/// Spec 10 §6, "The edge and the tags".
final class SectionHueTests: XCTestCase {
    func test_theCommonSectionNamesAlwaysTakeTheSameHue() {
        XCTAssertEqual(["Verse", "Chorus", "Bridge", "Pre-chorus", "Tag", "Intro", "Outro"].map(SectionHue.index), [0, 1, 2, 3, 4, 5, 6])
    }

    func test_aNameIsComparedWithoutItsCaseItsSpacesOrANumberAfterIt() {
        XCTAssertEqual(SectionHue.index(for: "Verse 2"), 0)
        XCTAssertEqual(SectionHue.index(for: "VERSE"), 0)
        XCTAssertEqual(SectionHue.index(for: "Pre Chorus"), 3)
        XCTAssertEqual(SectionHue.index(for: "prechorus 1"), 3)
        XCTAssertEqual(SectionHue.key("Chorus 12"), "chorus")
    }

    func test_anyOtherNameTakesAHueByAHashThatNeverChanges() {
        // FNV-1a over the key's UTF-8, modulo eight: the same on every Mac and at every launch.
        XCTAssertEqual(SectionHue.index(for: "Refrain"), SectionHue.index(for: "refrain 2"))
        XCTAssertEqual(SectionHue.index(for: "Refrain"), 0)
        XCTAssertEqual(SectionHue.index(for: "Out"), 7)
        for name in ["Refrain", "Out", "Vamp", "Ending", "Interlude", "Turnaround", ""] {
            XCTAssertTrue((0..<SectionHue.count).contains(SectionHue.index(for: name)), name)
        }
    }
}

final class TimeTextTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func test_aClockReadsMinutesAndSecondsAndHoursFromAnHour() {
        XCTAssertEqual(TimeText.clock(ms: 8_000), "0:08")
        XCTAssertEqual(TimeText.clock(ms: 83_000), "1:23")
        XCTAssertEqual(TimeText.clock(ms: 3_723_000), "1:02:03")
        XCTAssertEqual(TimeText.clock(ms: 8_900), "0:08", "a position counts whole seconds passed")
        XCTAssertEqual(TimeText.clock(ms: -5), "0:00")
    }

    func test_aCountdownRoundsUpSoItNeverReadsZeroBeforeItIsOver() {
        XCTAssertEqual(TimeText.clock(ms: 7_001, roundUp: true), "0:08")
        XCTAssertEqual(TimeText.clock(ms: 8_000, roundUp: true), "0:08")
        XCTAssertEqual(TimeText.clock(ms: 1, roundUp: true), "0:01")
        XCTAssertEqual(TimeText.clock(ms: 0, roundUp: true), "0:00")
    }

    func test_aShortSpanIsSecondsWithOneDecimalAtMostAndAClockFromAMinute() {
        XCTAssertEqual(TimeText.shortSeconds(ms: 8_000, locale: english), "8")
        XCTAssertEqual(TimeText.shortSeconds(ms: 2_500, locale: english), "2.5")
        XCTAssertEqual(TimeText.shortSeconds(ms: 2_500, locale: Locale(identifier: "de_DE")), "2,5", "the system's formatter")
        XCTAssertNil(TimeText.shortSeconds(ms: 90_000, locale: english))
    }
}

/// Spec 10 §6 — the grid's model, built from the engine's own answers as
/// `tests/fixtures/api-v1/` records them.
final class GridModelTests: XCTestCase {
    // MARK: - A playlist

    func test_aPlaylistShowsItsHeadersAndItsListsInOrder() throws {
        let model = GridModel.make(try Recorded.inputs(.playlist(Recorded.sunday)))
        XCTAssertEqual(model.title, "Sunday")
        XCTAssertEqual(model.serviceDate, "2026-11-01")
        XCTAssertEqual(model.listCount, 3, "the number of lists")
        XCTAssertFalse(model.isFromLibrary)
        XCTAssertEqual(model.sections.map(\.kind), [.header, .list, .list, .header, .list])
        XCTAssertEqual(model.sections.map(\.title), ["Welcome", "Great Is Thy Faithfulness", "Great Is Thy Faithfulness (Manheim)", "Response", "Doxology"])
        XCTAssertEqual(model.sections.map(\.item), [1, 2, 3, 4, 5], "an item's number counts the headers too")
        XCTAssertEqual(model.sections.map(\.isLocal), [false, false, true, false, false], "a \"local\" tag for a local copy")
        XCTAssertEqual(model.sections[1].cueCount, 4)
        XCTAssertEqual(model.sections[1].ccli, "18723")
        XCTAssertEqual(model.sections[1].cells.map(\.label), ["Verse 1", "Verse 1", "Verse 1", "Chorus"])
        XCTAssertEqual(model.sections[1].cells.map(\.number), [1, 2, 3, 4])
    }

    func test_aCellShowsItsSectionItsTriggerItsNoteAndItsText() throws {
        let cells = GridModel.make(try Recorded.inputs(.playlist(Recorded.sunday))).sections[1].cells
        XCTAssertEqual(cells.map(\.hue), [0, 0, 0, 1], "Verse 1 is Verse; Chorus is Chorus")
        XCTAssertEqual(cells[0].trigger, .go)
        XCTAssertEqual(cells[2].trigger, .time(ms: 8000))
        XCTAssertEqual(cells[2].advanceAfterMs, 12000)
        XCTAssertEqual(cells[3].note, "Build the lights here")
        XCTAssertEqual(cells[1].text, "There is no shadow\nof turning with Thee", "until a thumbnail arrives, the cue's text")
        XCTAssertNil(cells[0].thumbnail, "the recorded answer has no file yet")
    }

    func test_theChipsComeFromTheAppsOwnFoldOfTheList() throws {
        let cells = GridModel.make(try Recorded.inputs(.playlist(Recorded.sunday))).sections[1].cells
        XCTAssertEqual(cells[0].chips.map(\.channel), [1, 2, 3], "one per channel in number order")
        XCTAssertEqual(cells[0].chips.map(\.state), [.new, .new, .held])
        XCTAssertEqual(cells[1].chips.map(\.state), [.held, .new, .held])
        XCTAssertEqual(cells[3].chips.map(\.state), [.held, .new, .held])
        XCTAssertEqual(cells[3].chips[0].attributes.map(\.attribute), [.gain], "a dot marks attribute writes: channel 1's gain")
        XCTAssertEqual(cells[3].chips[1].attributes.map(\.attribute), [.grade, .audioTransition], "its write's two riders, listed on hover")
    }

    func test_pastEightChannelsTheRowEndsWithHowManyMore() {
        var cell = CueCell(uuid: "c", number: 1, label: "", note: "", section: nil, hue: nil, trigger: .go, advanceAfterMs: nil,
                           chips: (1...11).map { CueChip(channel: $0, state: .held) }, text: nil, thumbnail: nil, isLive: false, isArmed: false,
                           missingMedia: false, keptUnknown: false, matchesSearch: false)
        XCTAssertEqual(cell.shownChips.chips.map(\.channel), Array(1...8))
        XCTAssertEqual(cell.shownChips.more, 3, "+3")
        cell.chips = Array(cell.chips.prefix(8))
        XCTAssertEqual(cell.shownChips.more, 0)
    }

    func test_theLiveItemAndTheLiveCueAreMarkedAndOnlyUnderThatItem() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sundayNight))
        let catalog = try Recorded.catalog()
        let night = try XCTUnwrap(catalog.playlist(uuid: Recorded.sundayNight)).playlist
        // Sunday Night links list 42 twice, as its items 2 and 4; the pointer is on the second link.
        inputs.live.playlist = Recorded.sundayNight
        inputs.live.item = night.items[3].uuid.uuidString.lowercased()
        inputs.live.listUuid = Recorded.list42
        inputs.live.cue = Recorded.cues42[1]
        inputs.live.armed = .init(item: night.items[3].uuid.uuidString.lowercased(), cue: Recorded.cues42[2], itemPosition: 4, cuePosition: 3, inMs: 8000)
        let model = GridModel.make(inputs)
        XCTAssertEqual(model.sections.map(\.isLive), [false, false, false, true])
        XCTAssertEqual(model.sections[1].cells.map(\.isLive), [false, false, false, false], "the same list under another item isn't live")
        XCTAssertEqual(model.sections[3].cells.map(\.isLive), [false, true, false, false])
        XCTAssertEqual(model.sections[3].cells.map(\.isArmed), [false, false, true, false], "the cue armed to fire next")
        XCTAssertEqual(model.liveCell?.section, 3)
        XCTAssertEqual(model.liveCell?.cell, 1)
    }

    func test_aCueWhoseMediaIsMissingSaysSo() throws {
        let doxology = try XCTUnwrap(GridModel.make(try Recorded.inputs(.playlist(Recorded.sunday))).sections.last)
        XCTAssertEqual(doxology.title, "Doxology")
        XCTAssertEqual(doxology.cells.map(\.missingMedia), [true, false, false], "mountains.mp4 is missing in the recorded media")
    }

    func test_aLinkedItemWhoseListIsGoneIsMissingWithNoCues() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sunday))
        inputs.catalog?.lists.removeAll { $0.uuid == Recorded.list7 }
        let model = GridModel.make(inputs)
        XCTAssertEqual(model.sections.last?.isMissing, true)
        XCTAssertEqual(model.sections.last?.cells, [])
    }

    func test_aPlaylistWhoseTitleAnotherSharesAndDoesNotLoadIsRefused() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sunday))
        let index = try XCTUnwrap(inputs.catalog?.playlists.firstIndex { $0.playlist.uuid.uuidString.lowercased() == Recorded.sunday })
        inputs.catalog?.playlists[index].named = false
        XCTAssertEqual(GridModel.make(inputs).sections.filter { $0.kind == .list }.map(\.refusal), [.renameToFire, .renameToFire, .renameToFire])
        // Loaded some other way, its cues fire by item and need no title.
        inputs.live.playlist = Recorded.sunday
        XCTAssertEqual(GridModel.make(inputs).sections.filter { $0.kind == .list }.map(\.refusal), [nil, nil, nil])
    }

    func test_theSearchMarksTheCuesWhoseLabelOrTextMatches() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sunday))
        inputs.search = "FAITHFULNESS"
        let cells = GridModel.make(inputs).sections[1].cells
        XCTAssertEqual(cells.map(\.matchesSearch), [true, false, false, true], "in the text, whatever its case")
        inputs.search = "chorus"
        XCTAssertEqual(GridModel.make(inputs).sections[1].cells.map(\.matchesSearch), [false, false, false, true], "in the label")
        inputs.search = "  "
        XCTAssertEqual(GridModel.make(inputs).sections[1].cells.map(\.matchesSearch), [false, false, false, false])
    }

    func test_anUpdatedListSaysSo() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sunday))
        inputs.updated = [Recorded.list42]
        XCTAssertEqual(GridModel.make(inputs).sections.map(\.isUpdated), [false, true, false, false, false])
    }

    func test_theLiveItemRemovedStaysAtItsOldPlaceUntilThePointerLeavesIt() throws {
        var inputs = try Recorded.inputs(.playlist(Recorded.sunday))
        let before = GridModel.make(inputs)
        // Doxology, item 5, is live and is then removed from the playlist.
        let kept = try XCTUnwrap(before.sections.last)
        let index = try XCTUnwrap(inputs.catalog?.playlists.firstIndex { $0.playlist.uuid.uuidString.lowercased() == Recorded.sunday })
        inputs.catalog?.playlists[index].playlist.items.removeLast()
        inputs.live.playlist = Recorded.sunday
        inputs.live.item = kept.itemUuid
        inputs.live.listUuid = Recorded.list7
        inputs.live.cue = kept.cells[1].uuid
        inputs.live.gone = ["item"]
        inputs.removed = (index: 4, section: kept)
        let model = GridModel.make(inputs)
        XCTAssertEqual(model.sections.count, 5)
        XCTAssertEqual(model.sections[4].isRemoved, true, "Removed: finishing")
        XCTAssertEqual(model.sections[4].cells.map(\.isLive), [false, true, false], "with the live cue marked")
        inputs.live.gone = []
        XCTAssertEqual(GridModel.make(inputs).sections.count, 4, "until the pointer leaves it")
    }

    // MARK: - A list from the library

    func test_aListFromTheLibraryIsOneSectionCountedInCues() throws {
        let model = GridModel.make(try Recorded.inputs(.list(Recorded.list42)))
        XCTAssertTrue(model.isFromLibrary, "From the library: Next stops at its last cue")
        XCTAssertEqual(model.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(model.cueCount, 4)
        XCTAssertNil(model.listCount)
        XCTAssertEqual(model.sections.count, 1)
        XCTAssertNil(model.sections[0].item)
        XCTAssertEqual(model.sections[0].listNumber, 42)
        XCTAssertNil(model.sections[0].refusal)
    }

    func test_aLibraryListWhoseNumberAnotherSharesIsRefused() throws {
        var inputs = try Recorded.inputs(.list(Recorded.list42))
        let index = try XCTUnwrap(inputs.catalog?.lists.firstIndex { $0.uuid == Recorded.list42 })
        inputs.catalog?.lists[index].named = false
        XCTAssertEqual(GridModel.make(inputs).sections[0].refusal, .renumberToFire)
    }

    func test_aListNotHeldYetShowsItsSummaryAndNoCells() throws {
        var inputs = try Recorded.inputs(.list(Recorded.list42))
        inputs.lists = [:]
        let model = GridModel.make(inputs)
        XCTAssertEqual(model.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(model.cueCount, 4, "from the catalog's summary")
        XCTAssertEqual(model.sections[0].cells, [])
        XCTAssertFalse(model.sections[0].isMissing)
    }

    // MARK: - What to hold (Spec 10 §3)

    func test_theAppHoldsTheListsOfTheBrowsedAndTheLiveContexts() throws {
        let catalog = try Recorded.catalog()
        var live = LiveStatus()
        XCTAssertEqual(GridModel.listsNeeded(shown: .playlist(Recorded.sunday), live: live, catalog: catalog), [Recorded.list42, Recorded.localCopy, Recorded.list7])
        XCTAssertEqual(GridModel.listsNeeded(shown: .list(Recorded.list7), live: live, catalog: catalog), [Recorded.list7])
        live.playlist = Recorded.sundayNight
        live.listUuid = Recorded.list42
        XCTAssertEqual(GridModel.listsNeeded(shown: .list(Recorded.localCopy), live: live, catalog: catalog), [Recorded.localCopy, Recorded.list42, Recorded.list7])
        XCTAssertEqual(GridModel.listsNeeded(shown: nil, live: LiveStatus(), catalog: catalog), [])
    }
}
