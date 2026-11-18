import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §4–§8 — the show-mode window's model over a store fed the
/// engine's recorded answers: what the grid shows at a connection, what a
/// press sends and when it sends nothing, the why-line, the strip's
/// selection, the pool's live writes, and the marks that last a moment.
@MainActor
final class ShowModelTests: XCTestCase {
    /// A model, its store filled from `tests/fixtures/api-v1/`, and every request it sent.
    @MainActor
    final class Rig {
        let clock = ManualClock()
        let store = ShowStore()
        let model: ShowModel
        var sent: [EngineRequest] = []
        var answers: [(Reply?) -> Void] = []
        var held: [Set<String>] = []
        var follows = 0
        var changes: [Set<ShowModel.Change>] = []

        init(connected: Bool = true) throws {
            model = ShowModel(store: store, clock: clock)
            model.transmit = { [unowned self] request, answer in
                self.sent.append(request)
                self.answers.append(answer)
            }
            model.hold = { [unowned self] in self.held.append($0) }
            model.onFollowLive = { [unowned self] in self.follows += 1 }
            model.onChange = { [unowned self] in self.changes.append($0) }
            if connected { try connect() }
        }

        func connect() throws {
            store.connected(Hello.test())
            store.apply(catalog: try RecordedAPI.load("catalog"))
            store.apply(media: try RecordedAPI.load("media"))
            for name in ["list-42", "list-7", "list-local"] { store.apply(list: try RecordedAPI.load(name)) }
            store.apply(state: try RecordedAPI.load("state"), now: clock.now)
        }

        /// The commands sent, in canonical text, one request each.
        var commands: [[String]] {
            sent.map { request in
                let values = request.fields["commands"]?.arrayValue ?? request.fields["command"].map { [$0] } ?? []
                return values.compactMap { (try? JSONCoding.decode(Command.self, from: $0)).flatMap(CommandText.print) }
            }
        }

        func live(_ change: (inout [String: JSONValue]) -> Void) throws {
            var event = try XCTUnwrap(try RecordedAPI.load("state").items("events")?.compactMap(\.objectValue).first { $0.text("topic") == "live" })
            change(&event)
            store.apply(event: "live", event, now: clock.now)
        }

        func cell(_ section: Int, _ cue: Int) -> (CueCell, GridSection) {
            (model.grid.sections[section].cells[cue], model.grid.sections[section])
        }
    }

    // MARK: - At a connection

    func test_atAConnectionTheGridShowsWhatIsLiveAndTheAppHoldsItsLists() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.model.browse.shown, .playlist(Recorded.sunday), "the recorded state has Sunday live")
        XCTAssertFalse(rig.model.isBrowsing)
        XCTAssertEqual(rig.model.grid.title, "Sunday")
        XCTAssertEqual(rig.model.grid.sections[1].cells.map(\.isLive), [true, false, false, false])
        XCTAssertEqual(rig.held.last, [Recorded.list42, Recorded.localCopy, Recorded.list7])
        XCTAssertEqual(rig.model.livePosition, .cue(playlist: "Sunday", list: "Great Is Thy Faithfulness", number: 1, label: "Verse 1"))
        XCTAssertEqual(rig.model.previewStack, 1, "the thumbnail stack")
        XCTAssertEqual(rig.model.stripCells.map(\.number), [1, 2, 3])
    }

    // MARK: - Presses (Spec 10 §6)

    func test_aPressFiresOnceAndASecondPressWithinTheIntervalSendsNothing() throws {
        let rig = try Rig()
        let (cell, section) = rig.cell(1, 1)
        XCTAssertEqual(rig.model.press(cue: cell, in: section), .fire)
        XCTAssertEqual(rig.commands, [["item 2 cue 2"]], "in the live playlist, item N cue M")
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.model.press(cue: cell, in: section), .doubleClick)
        XCTAssertEqual(rig.sent.count, 1, "a refire restarts media")
        XCTAssertEqual(rig.model.press(cue: cell, in: section, secondary: true), .menu)
        XCTAssertEqual(rig.model.press(cue: cell, in: section, option: true), .nothing, "with ⌥ held, a press doesn't fire")
        XCTAssertEqual(rig.sent.count, 1)
    }

    func test_aPressInAPlaylistThatIsNotLoadedLoadsItAndFiresInOneGroup() throws {
        let rig = try Rig()
        rig.model.choose(playlist: Recorded.sundayNight, option: false)
        XCTAssertTrue(rig.model.isBrowsing, "amber: the grid shows something that isn't live")
        XCTAssertEqual(rig.model.expandedPlaylists, [Recorded.sundayNight])
        let (cell, section) = rig.cell(2, 0)
        rig.model.press(cue: cell, in: section)
        XCTAssertEqual(rig.commands, [["playlist \"Sunday Night\"", "item 3 cue 1"]])
        XCTAssertEqual(rig.sent.first?.fields["group"], .bool(true))
        // The engine's live event names that playlist: the grid stops browsing without moving.
        try rig.live { $0["playlist"] = .string(Recorded.sundayNight) }
        XCTAssertFalse(rig.model.isBrowsing)
    }

    func test_aPressInAListFromTheLibraryFiresByItsNumber() throws {
        let rig = try Rig()
        rig.model.browse(.list(Recorded.list7))
        let (cell, section) = rig.cell(0, 2)
        rig.model.press(cue: cell, in: section)
        XCTAssertEqual(rig.commands, [["list 7 cue 3"]])
    }

    func test_withTheEngineAwayAPressSendsNothingAndNothingIsKeptForLater() throws {
        let rig = try Rig()
        rig.store.disconnected()
        let (cell, section) = rig.cell(1, 1)
        rig.model.press(cue: cell, in: section)
        XCTAssertFalse(rig.model.send(Actions.next()))
        XCTAssertEqual(rig.sent.count, 0)
        try rig.connect()
        XCTAssertEqual(rig.sent.count, 0, "a key that would send a command is dropped, never queued")
    }

    func test_backToLiveReturnsTheGridAndScrollsToTheLiveCue() throws {
        let rig = try Rig()
        rig.model.browse(.list(Recorded.list7))
        XCTAssertTrue(rig.model.isBrowsing)
        let before = rig.follows
        rig.model.backToLive()
        XCTAssertEqual(rig.model.browse.shown, .playlist(Recorded.sunday))
        XCTAssertFalse(rig.model.isBrowsing)
        XCTAssertEqual(rig.follows, before + 1)
    }

    // MARK: - The why-line (Spec 10 §7)

    func test_aNextThatDoesNothingSaysWhyForThreeSeconds() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.model.send(Actions.next()))
        rig.answers[0](.result(CommandOutcome(kind: .noop)))
        XCTAssertEqual(rig.model.why, .endOfPlaylist)
        rig.clock.advance(by: 2.9)
        XCTAssertEqual(rig.model.why, .endOfPlaylist)
        rig.clock.advance(by: 0.2)
        XCTAssertNil(rig.model.why)
        rig.model.send(Actions.goTo(cue: 14))
        rig.answers[1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(reason: "noSuchCue: no cue 14"))))
        XCTAssertEqual(rig.model.why, .noCue(number: 14, title: "Great Is Thy Faithfulness"))
        rig.model.send(Actions.next())
        rig.answers[2](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.model.why, .noCue(number: 14, title: "Great Is Thy Faithfulness"), "a command that worked says nothing, and clears nothing early")
    }

    // MARK: - Following the live cue (Spec 10 §6)

    func test_theGridFollowsTheLiveCueButNeverWhileThePointerMovedOverItInTheLastSecond() throws {
        let rig = try Rig()
        let before = rig.follows
        try rig.live { $0["cue"] = .string(Recorded.cues42[1]) }
        XCTAssertEqual(rig.follows, before + 1)
        rig.model.follow.pointerMoved(inside: true, at: rig.clock.now)
        try rig.live { $0["cue"] = .string(Recorded.cues42[2]) }
        XCTAssertEqual(rig.follows, before + 1, "so a press never lands on a cue the grid moved under it")
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.follows, before + 2, "it catches up when the pointer rests")
        rig.model.follow.buttonDown = true
        try rig.live { $0["cue"] = .string(Recorded.cues42[3]) }
        XCTAssertEqual(rig.follows, before + 2)
        rig.model.follow.buttonDown = false
        rig.model.pointerRested()
        XCTAssertEqual(rig.follows, before + 3)
    }

    // MARK: - The strip (Spec 10 §7)

    func test_theStripsSelectionIsTheWindowsAndClearSelectedGoesInNumberOrder() throws {
        let rig = try Rig()
        rig.model.toggleSelection(2)
        rig.model.toggleSelection(1)
        XCTAssertEqual(rig.model.stripCells.map(\.isSelected), [true, true, false])
        XCTAssertEqual(rig.sent.count, 0, "selection is never sent")
        rig.model.send(Actions.clearSelected(rig.model.selection.channels))
        XCTAssertEqual(rig.commands, [["channel 1 clear", "channel 2 clear"]])
        rig.model.selectOnly(1)
        XCTAssertEqual(rig.model.transport, .one(channel: 1, positionMs: 0, durationMs: 2000, isPlaying: true, endBehavior: "loop"))
        rig.model.selectAll()
        XCTAssertEqual(rig.model.selection.channels, [1, 2, 3])
        rig.model.show(stripStack: 2)
        XCTAssertEqual(rig.model.stripCells.map(\.number), [3, 2], "stack 2, top layer first")
        XCTAssertEqual(rig.model.selection.channels, [2, 3], "the channel the view hides drops out of the selection")
        rig.model.selectNone()
        XCTAssertEqual(rig.model.transport, TransportPanel.none)
    }

    func test_aResetMarkShowsForThreeSecondsAfterAFireEntersAnotherList() throws {
        let rig = try Rig()
        XCTAssertFalse(rig.model.showsReset)
        try rig.live { $0["boundary"] = .object(["reset": .bool(true)]) }
        XCTAssertTrue(rig.model.showsReset)
        rig.clock.advance(by: 3)
        XCTAssertFalse(rig.model.showsReset)
        try rig.live { $0["boundary"] = .object(["reset": .bool(false)]) }
        XCTAssertFalse(rig.model.showsReset, "a list that tracks through resets nothing")
    }

    func test_aTransitionRunsItsBarAndASteppedOnChannelFlashes() throws {
        let rig = try Rig()
        var event = try RecordedAPI.event("channels.media")
        event["transition"] = .object(["ms": .number(1000), "audioMs": .number(0), "audioOffsetMs": .number(0)])
        event["steppedOn"] = .bool(true)
        rig.store.apply(event: "channels", event, now: rig.clock.now)
        let channel = try XCTUnwrap(event.integer("channel"))
        XCTAssertEqual(rig.model.transitionProgress(channel: channel), 0)
        XCTAssertTrue(rig.model.isSteppedOn(channel))
        rig.clock.advance(by: 0.5)
        XCTAssertEqual(try XCTUnwrap(rig.model.transitionProgress(channel: channel)), 0.5, accuracy: 0.001)
        rig.clock.advance(by: 0.6)
        XCTAssertNil(rig.model.transitionProgress(channel: channel), "for the transition's duration")
        XCTAssertFalse(rig.model.isSteppedOn(channel))
    }

    // MARK: - The pool (Spec 10 §6)

    func test_aPoolItemGoesLiveOnItsDropChannelAndJoinsTheRecentStrip() throws {
        let rig = try Rig()
        let dawn = try XCTUnwrap(rig.store.media.first { $0.entry.path.hasSuffix("dawn.mp4") })
        XCTAssertTrue(rig.model.goLive(media: dawn.id))
        XCTAssertEqual(rig.commands, [["channel 1 write media \(dawn.id)"]], "no rider: its trim, loop and gain fall back to its defaults")
        XCTAssertEqual(rig.model.recentTiles.map(\.name), ["dawn.mp4"])
        let mountains = try XCTUnwrap(rig.store.media.first { $0.entry.path.hasSuffix("mountains.mp4") })
        rig.model.goLive(media: mountains.id, on: 3)
        XCTAssertEqual(rig.commands.last, ["channel 3 write media \(mountains.id) grade 1 once"], "its default grade as a once rider, on the channel chosen")
        XCTAssertEqual(rig.model.recentTiles.map(\.name), ["mountains.mp4", "dawn.mp4"])
    }

    // MARK: - The library changing (Spec 10 §6)

    func test_aMasterReloadedFromDiskSaysUpdatedUntilItIsNextFired() throws {
        let rig = try Rig()
        let event: [String: JSONValue] = ["topic": .string("library"), "rev": .number(9_999), "cause": .string("file"), "seq": .number(1),
                                          "changed": .array([.object(["object": .string("list"), "list": .number(7), "listUuid": .string(Recorded.list7)])])]
        rig.store.apply(event: "library", event, now: rig.clock.now)
        try rig.live { $0["cue"] = .string(Recorded.cues42[1]) }
        XCTAssertEqual(rig.model.grid.sections.last?.isUpdated, true)
        XCTAssertEqual(rig.model.grid.sections[1].isUpdated, false)
        try rig.live {
            $0["listUuid"] = .string(Recorded.list7)
            $0["cue"] = .string("55ee0000-0000-4000-8000-000000000001")
        }
        XCTAssertEqual(rig.model.grid.sections.last?.isUpdated, false, "until the list is next fired")
    }

    /// Spec 10 §5 and §6, "Show in Library".
    func test_showInLibraryOpensTheListsFoldersAndMarksItWithoutMovingTheGrid() throws {
        let rig = try Rig()
        rig.model.showInLibrary(list: Recorded.list42)
        XCTAssertEqual(rig.model.settings.openFolders, ["Hymns"], "every folder on its way is opened")
        XCTAssertEqual(rig.model.revealedList, Recorded.list42)
        XCTAssertTrue(rig.model.libraryRows.contains { $0.uuid == Recorded.list42 })
        XCTAssertEqual(rig.model.browse.shown, .playlist(Recorded.sunday), "showing where a list lives isn't browsing it")
        XCTAssertEqual(rig.sent.count, 0)
        rig.model.browse(.list(Recorded.list7))
        XCTAssertNil(rig.model.revealedList, "until the operator next chooses something there")
        rig.model.showInLibrary(list: Recorded.localCopy)
        XCTAssertNil(rig.model.revealedList, "a local copy isn't in the library")
    }

    /// Spec 10 §4 — "Left column ... 200 to 360"; "Right column ... 340 to 480".
    func test_aDividerMovesInsideItsLimitsAndRedrawsNothing() throws {
        let rig = try Rig()
        rig.changes = []
        rig.model.resize { $0.leftColumnWidth = 500 }
        XCTAssertEqual(rig.model.settings.leftColumnWidth, 360)
        rig.model.resize { $0.rightColumnWidth = 100; $0.leftSplit = 0.95 }
        XCTAssertEqual(rig.model.settings.rightColumnWidth, 340)
        XCTAssertEqual(rig.model.settings.leftSplit, 0.8)
        XCTAssertEqual(rig.changes, [[.layout], [.layout]], "the regions are placed again; nothing in them is rebuilt")
    }

    func test_resetLayoutPutsTheDefaultsBack() throws {
        let rig = try Rig()
        rig.model.change { $0.showsNotes = true; $0.leftColumnWidth = 300; $0.stripStack = 2 }
        rig.model.resetLayout()
        XCTAssertEqual(rig.model.settings, ViewSettings())
        XCTAssertEqual(rig.sent.count, 0, "it's a UI action, not a command")
    }
}
