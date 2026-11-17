import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §7, "The next row", and §18: "Next disabled while nothing is live
/// and enabled for a list fired from the library, Hold".
final class NextRowModelTests: XCTestCase {
    private func live(playlist: String? = nil, list: String? = nil, cue: String? = nil) -> LiveStatus {
        var live = LiveStatus()
        live.playlist = playlist
        live.listUuid = list
        live.cue = cue
        live.listTitle = "Great Is Thy Faithfulness"
        return live
    }

    func test_nextIsDisabledWhileNothingIsLive() {
        let row = NextRow.make(live: live(), cannotSend: nil)
        XCTAssertFalse(row.nextEnabled, "choice U-15: Space's next does nothing then")
        XCTAssertFalse(row.lastEnabled)
        XCTAssertFalse(row.goToEnabled)
        XCTAssertFalse(row.showsHold)
    }

    func test_aPlaylistLoadedIsEnoughForNext() {
        let ready = NextRow.make(live: live(playlist: "b1a7"), cannotSend: nil)
        XCTAssertTrue(ready.nextEnabled, "live with no cue fired, so the next `next` fires its first cue")
        XCTAssertFalse(ready.lastEnabled, "nothing has been fired to go back from")
        XCTAssertFalse(ready.goToEnabled, "and there is no live list for `cue N` yet")
    }

    func test_nextIsEnabledForAListFiredFromTheLibrary() {
        let row = NextRow.make(live: live(list: "a9f0", cue: "11aa"), cannotSend: nil)
        XCTAssertTrue(row.nextEnabled)
        XCTAssertTrue(row.lastEnabled)
        XCTAssertTrue(row.goToEnabled)
        XCTAssertEqual(row.goToTitle, "Great Is Thy Faithfulness", "while digits wait, it shows the live list's title")
    }

    func test_holdAppearsWhileATriggerIsArmed() {
        var armed = live(playlist: "b1a7", list: "a9f0", cue: "22bb")
        armed.armed = .init(item: nil, cue: "33cc", itemPosition: 2, cuePosition: 3, inMs: 8000)
        XCTAssertTrue(NextRow.make(live: armed, cannotSend: nil).showsHold)
        XCTAssertFalse(NextRow.make(live: armed, cannotSend: .engineAway).showsHold)
    }

    func test_withTheEngineAwayNothingIsEnabledAndTheRowSaysWhy() {
        let row = NextRow.make(live: live(playlist: "b1a7", list: "a9f0", cue: "11aa"), cannotSend: .engineAway)
        XCTAssertFalse(row.nextEnabled)
        XCTAssertFalse(row.lastEnabled)
        XCTAssertEqual(row.unavailable, .engineAway)
    }

    // MARK: - Why nothing happened

    func test_theRowSaysWhyANavigationCommandDidNothing() {
        let playing = live(playlist: "b1a7", list: "a9f0", cue: "44dd")
        XCTAssertEqual(WhyLine.reason(for: .next, result: .noop, live: playing), .endOfPlaylist)
        XCTAssertEqual(WhyLine.reason(for: .next, result: .noop, live: live(list: "a9f0", cue: "44dd")), .endOfLibraryList,
                       "End of this song: it was fired from the library")
        XCTAssertEqual(WhyLine.reason(for: .cue(14), result: .noop, live: playing), .noCue(number: 14, title: "Great Is Thy Faithfulness"))
        XCTAssertEqual(WhyLine.reason(for: .cue(14), result: .rejected, live: playing), .noCue(number: 14, title: "Great Is Thy Faithfulness"))
        XCTAssertEqual(WhyLine.reason(for: .next, result: .noop, live: live()), .nothingLive)
        XCTAssertEqual(WhyLine.reason(for: .previous, result: .noop, live: playing), .startOfPlaylist)
        XCTAssertEqual(WhyLine.seconds, 3)
    }

    func test_afterARestoreThatCouldNotPlaceThePointerItSaysToClickACue() {
        var lost = live(playlist: "b1a7", list: "a9f0")
        lost.gone = ["cue"]
        XCTAssertEqual(WhyLine.reason(for: .next, result: .noop, live: lost), .pickUp, "Click a cue to pick up where you were")
    }

    func test_aCommandThatDidSomethingOrIsNotNavigationSaysNothing() {
        let playing = live(playlist: "b1a7", list: "a9f0", cue: "11aa")
        XCTAssertNil(WhyLine.reason(for: .next, result: .ok, live: playing))
        XCTAssertNil(WhyLine.reason(for: .systemClearAll, result: .noop, live: playing))
    }
}

/// Spec 10 §7, Transport.
final class TransportPanelTests: XCTestCase {
    private func media(position: Int, duration: Int? = 60_000, loop: Bool = false, state: String = "playing") -> ChannelStatus {
        ChannelStatus(number: 1, state: state,
                      content: ChannelContent(kind: .media(ref: "sha256:a", missing: false, loop: loop, endBehavior: loop ? "loop" : "hold"), label: "dawn.mp4",
                                              hasPicture: true, durationMs: duration, positionMs: position))
    }

    func test_oneChannelWithTimedMediaShowsItsPositionAndItsEndBehaviour() {
        let panel = TransportPanel.make(selection: [1], channels: [1: media(position: 12_000)])
        XCTAssertEqual(panel, .one(channel: 1, positionMs: 12_000, durationMs: 60_000, isPlaying: true, endBehavior: "hold"))
    }

    func test_betweenEventsThePositionCountsOnTheAppsClock() {
        let playing = TransportPanel.make(selection: [1], channels: [1: media(position: 12_000)]) { _ in 700 }
        XCTAssertEqual(playing, .one(channel: 1, positionMs: 12_700, durationMs: 60_000, isPlaying: true, endBehavior: "hold"))
        let paused = TransportPanel.make(selection: [1], channels: [1: media(position: 12_000, state: "paused")]) { _ in 700 }
        XCTAssertEqual(paused, .one(channel: 1, positionMs: 12_000, durationMs: 60_000, isPlaying: false, endBehavior: "hold"), "a paused one stands still")
        let atEnd = TransportPanel.make(selection: [1], channels: [1: media(position: 59_800)]) { _ in 700 }
        XCTAssertEqual(atEnd, .one(channel: 1, positionMs: 60_000, durationMs: 60_000, isPlaying: true, endBehavior: "hold"), "and never past its length")
        let looping = TransportPanel.make(selection: [1], channels: [1: media(position: 59_800, loop: true)]) { _ in 700 }
        XCTAssertEqual(looping, .one(channel: 1, positionMs: 500, durationMs: 60_000, isPlaying: true, endBehavior: "loop"), "a loop goes round")
    }

    func test_severalChannelsShowTheButtonsForAllOfThem() {
        XCTAssertEqual(TransportPanel.make(selection: [3, 1], channels: [1: media(position: 0)]), .several([1, 3]))
    }

    func test_anythingElseShowsNoTransport() {
        XCTAssertEqual(TransportPanel.make(selection: [], channels: [1: media(position: 0)]), TransportPanel.none)
        let text = ChannelStatus(number: 2, state: "playing", content: ChannelContent(kind: .text(fields: ["body": "x"]), label: ""))
        XCTAssertEqual(TransportPanel.make(selection: [2], channels: [2: text]), TransportPanel.none)
        XCTAssertEqual(TransportPanel.make(selection: [1], channels: [1: media(position: 0, duration: nil)]), TransportPanel.none, "an image has no length")
        XCTAssertEqual(TransportPanel.make(selection: [4], channels: [:]), TransportPanel.none)
    }
}

/// Spec 10 §7, Clears, and §18: "the Clears tiles".
final class ClearsTilesTests: XCTestCase {
    private func tiles(blackout: [Int: Bool] = [:], muted: [Int: Bool] = [:], stacks: [Int] = [1, 2], audio: [Int] = [1, 2], slots: Int = 4,
                       cannotSend: Unavailable? = nil) -> [ClearsTile] {
        ClearsTile.all(previewStack: 1, stacks: stacks.map { Stack(number: $0, slots: []) },
                       stackStatus: Dictionary(uniqueKeysWithValues: blackout.map { ($0.key, StackStatus(number: $0.key, blackout: $0.value)) }),
                       audioOutputs: audio.map { AudioOutput(number: $0) },
                       audio: Dictionary(uniqueKeysWithValues: muted.map { ($0.key, AudioStatus(number: $0.key, state: "ok", muted: $0.value)) }),
                       channels: 3, popupSlots: slots, cannotSend: cannotSend)
    }

    func test_theSixTilesEachSendOneCommand() {
        let all = tiles()
        XCTAssertEqual(all.map(\.kind), [.clearAll, .blackoutStack(1), .blackoutAll, .muteAllAudio, .resetChannels, .clearPopups])
        XCTAssertEqual(all.map(\.sending.text), [["system clearall"], ["stack 1 blackout toggle"], ["stack all blackout toggle"], ["audio all mute toggle"],
                                                 ["channel all reset"], ["popup 1 clear", "popup 2 clear", "popup 3 clear", "popup 4 clear"]])
        XCTAssertEqual(all.map(\.isEnabled), [true, true, true, true, true, true])
        XCTAssertEqual(all.map(\.lit), [.off, .off, .off, .off, .off, .off])
    }

    func test_aTileLightsWhileAllItsTargetsAreOnAndOutlinesWhileOnlySomeAre() {
        let some = tiles(blackout: [2: true], muted: [1: true])
        XCTAssertEqual(some[1].lit, .off, "the preview's stack isn't blacked out")
        XCTAssertEqual(some[2].lit, .some, "a red outline while only some are")
        XCTAssertEqual(some[3].lit, .some)
        let all = tiles(blackout: [1: true, 2: true], muted: [1: true, 2: true])
        XCTAssertEqual(all[1].lit, .all)
        XCTAssertEqual(all[2].lit, .all, "lights red while all its targets are on")
        XCTAssertEqual(all[3].lit, .all)
        XCTAssertEqual(all[0].lit, .off, "a tile that only fires is never lit")
    }

    func test_aTileWithNoTargetsIsUnlitAndDisabled() {
        let bare = tiles(stacks: [], audio: [], slots: 0)
        XCTAssertEqual(bare.map(\.isEnabled), [true, false, false, false, true, false])
        XCTAssertEqual(bare.map(\.lit), [.off, .off, .off, .off, .off, .off])
    }

    func test_withTheEngineAwayEveryTileIsDisabled() {
        XCTAssertEqual(tiles(cannotSend: .engineAway).map(\.isEnabled), [false, false, false, false, false, false])
    }
}

/// Spec 10 §7, "The channel strip", and §18's strip bullet.
final class StripCellModelTests: XCTestCase {
    private func cells(view: StripView = .all, selection: StripSelection = StripSelection(), elapsedMs: Int = 0) throws -> [StripCell] {
        let store = try RecordedState()
        return StripCell.cells(view: view, selection: selection, catalog: store.catalog, channels: store.channels, stackStatus: store.stacks,
                               media: store.media, lists: store.lists) { _ in elapsedMs }
    }

    /// The recorded `state` answer's channels and stacks, with the catalog, media and lists beside.
    private struct RecordedState {
        var catalog: Catalog
        var channels: [Int: ChannelStatus] = [:]
        var stacks: [Int: StackStatus] = [:]
        var media: [MediaItem]
        var lists: [String: ListDocument] = [:]

        init() throws {
            catalog = try Recorded.catalog()
            media = try Recorded.media()
            for name in ["list-42", "list-7", "list-local"] {
                let document = try Recorded.list(name)
                lists[document.uuid] = document
            }
            for value in try RecordedAPI.load("state").items("events") ?? [] {
                guard let fields = value.objectValue else { continue }
                if let channel = ChannelStatus(event: fields) { channels[channel.number] = channel }
                if let stack = StackStatus(event: fields) { stacks[stack.number] = stack }
            }
        }
    }

    func test_aCellShowsItsNumberItsLabelItsKindAndItsPicture() throws {
        let cells = try cells()
        XCTAssertEqual(cells.map(\.number), [1, 2, 3], "all channels in number order")
        XCTAssertEqual(cells.map(\.label), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(cells[0].kind, .video)
        XCTAssertEqual(cells[0].picture, .live, "pixel content: the channel's live picture from the Mach channel")
        XCTAssertEqual(cells[0].contentLabel, "dawn.mp4")
        XCTAssertEqual(cells[1].kind, .text)
        XCTAssertEqual(cells[1].picture, .text("Great is Thy faithfulness,\nO God my Father"), "text: as the channel's textThumbnail says, here the body")
        XCTAssertEqual(cells[2].kind, .empty)
        XCTAssertEqual(cells[2].picture, .none, "nothing when empty")
    }

    func test_theButtonsFollowTheContent() throws {
        let cells = try cells()
        XCTAssertEqual(cells[0].buttons, [.pause, .stop, .clear], "media shows Play or Pause, Stop and Clear")
        XCTAssertEqual(cells[1].buttons, [.clear], "text shows Clear")
        XCTAssertEqual(cells[2].buttons, [], "an empty channel shows nothing")
    }

    func test_loopingMediaSaysLoopsAndTimedMediaCountsDown() throws {
        XCTAssertEqual(try cells()[0].remaining, .loops, "dawn.mp4 loops")
        let playing = ChannelContent(kind: .media(ref: "sha256:a", missing: false, loop: false, endBehavior: "hold"), label: "clip.mov", hasPicture: true,
                                     hasAudio: true, durationMs: 90_000, positionMs: 7_000)
        var catalog = Catalog()
        catalog.channels = [Channel(number: 1, label: "Background")]
        func cell(_ state: String, elapsed: Int = 0) -> StripCell? {
            StripCell.cells(view: .all, selection: StripSelection(), catalog: catalog, channels: [1: ChannelStatus(number: 1, state: state, content: playing)],
                            stackStatus: [:], media: [], lists: [:]) { _ in elapsed }.first
        }
        XCTAssertEqual(cell("playing")?.remaining, .counting(ms: 83_000))
        XCTAssertEqual(cell("playing", elapsed: 500)?.remaining, .counting(ms: 82_500), "counted on the app's clock between events")
        XCTAssertEqual(cell("paused", elapsed: 500)?.remaining, .paused(ms: 83_000), "paused 1:23")
        XCTAssertEqual(cell("playing")?.hasMeter, true, "the meter when its content has sound")
        XCTAssertEqual(cell("playing")?.buttons.first, .pause)
        XCTAssertEqual(cell("paused")?.buttons.first, .play)
    }

    func test_theStackDotsSitInStackOrderOnEveryCell() throws {
        let cells = try cells()
        XCTAssertEqual(cells[0].dots, [StackDot(stack: 1, label: "Main", state: .showing), StackDot(stack: 2, label: "Confidence", state: .absent)],
                       "hollow grey and inert where the stack doesn't hold the channel")
        XCTAssertEqual(cells[1].dots.map(\.state), [.showing, .showing])
        XCTAssertEqual(cells[2].dots.map(\.state), [.absent, .showing])
    }

    func test_aMutedChannelsDotIsMuted() throws {
        var catalog = Catalog()
        catalog.channels = [Channel(number: 2, label: "Foreground")]
        catalog.stacks = [Stack(number: 2, slots: [StackSlot(channel: 2)], label: "Confidence")]
        let cells = StripCell.cells(view: .all, selection: StripSelection(), catalog: catalog, channels: [:], stackStatus: [2: StackStatus(number: 2, muted: [2])],
                                    media: [], lists: [:])
        XCTAssertEqual(cells.first?.dots, [StackDot(stack: 2, label: "Confidence", state: .muted)], "hollow amber while that stack mutes it")
    }

    func test_oneStacksViewShowsItsChannelsTopLayerFirstKeepingTheirNumbers() throws {
        XCTAssertEqual(try cells(view: .stack(1)).map(\.number), [2, 1], "stack 1 is Background under Foreground")
        XCTAssertEqual(try cells(view: .stack(2)).map(\.number), [3, 2])
        XCTAssertEqual(try cells(view: .stack(9)).map(\.number), [])
    }

    func test_whatPutTheContentThereIsSaidFromTheCueAndItsList() throws {
        let cells = try cells()
        XCTAssertEqual(cells[1].origin, .cue(label: "Verse 1", list: "Great Is Thy Faithfulness"), "from Verse 1 · Great Is Thy Faithfulness")
        XCTAssertNil(cells[2].origin, "an empty channel that nothing has written")
        var catalog = Catalog()
        catalog.channels = [Channel(number: 1, label: "Background")]
        let fromUI = ChannelStatus(number: 1, state: "playing", content: ChannelContent(kind: .text(fields: ["body": "x"]), label: ""), provenance: .source(.ui))
        let restored = ChannelStatus(number: 1, state: "playing", content: ChannelContent(kind: .text(fields: ["body": "x"]), label: ""),
                                     provenance: .restored(cue: nil, list: nil))
        func origin(_ status: ChannelStatus) -> StripCell.Origin? {
            StripCell.cells(view: .all, selection: StripSelection(), catalog: catalog, channels: [1: status], stackStatus: [:], media: [], lists: [:]).first?.origin
        }
        XCTAssertEqual(origin(fromUI), .source("ui"))
        XCTAssertEqual(origin(restored), .restored)
    }

    func test_theTagsSayLockedTheGradeInUseAndMissing() {
        var catalog = Catalog()
        catalog.channels = [Channel(number: 1, label: "Background")]
        catalog.grades = [Grade(number: 4, label: "Warm")]
        let content = ChannelContent(kind: .media(ref: "sha256:gone", missing: true, loop: false, endBehavior: "hold"), label: "mountains.mp4")
        let status = ChannelStatus(number: 1, state: "missing", lock: true, content: content, attributes: ["grade": .init(value: .number(4), origin: "tracked")])
        let cell = StripCell.cells(view: .all, selection: StripSelection([1]), catalog: catalog, channels: [1: status], stackStatus: [:], media: [], lists: [:]).first
        XCTAssertEqual(cell?.isLocked, true)
        XCTAssertEqual(cell?.grade, "Warm")
        XCTAssertEqual(cell?.isMissing, true)
        XCTAssertEqual(cell?.isSelected, true)
    }

    // MARK: - Selection

    func test_theBadgeTogglesAChannelAndTheThumbnailSelectsItAlone() {
        var selection = StripSelection()
        selection.toggle(2)
        selection.toggle(5)
        XCTAssertEqual(selection.channels, [2, 5], "no modifier keys")
        selection.toggle(2)
        XCTAssertEqual(selection.channels, [5])
        selection.selectOnly(1)
        XCTAssertEqual(selection.channels, [1])
        selection.selectAll([1, 2, 3])
        XCTAssertEqual(selection.channels, [1, 2, 3])
        selection.selectNone()
        XCTAssertEqual(selection.channels, [])
    }

    func test_changingTheViewDropsAChannelItHidesFromTheSelection() {
        var selection = StripSelection([1, 2, 3])
        selection.keep(only: [3, 2])
        XCTAssertEqual(selection.channels, [2, 3], "so Clear Selected never clears what can't be seen")
    }

    // MARK: - The meter and the drop

    func test_theMeterIsGreenBelowMinusTwelveAmberToMinusThreeAndRedAbove() {
        XCTAssertEqual(MeterZone.of(dBFS: -40), .green)
        XCTAssertEqual(MeterZone.of(dBFS: -12.1), .green)
        XCTAssertEqual(MeterZone.of(dBFS: -12), .amber)
        XCTAssertEqual(MeterZone.of(dBFS: -3), .amber)
        XCTAssertEqual(MeterZone.of(dBFS: -2.9), .red)
        XCTAssertEqual(MeterZone.of(dBFS: 0), .red)
    }

    func test_aCellTakesADropOnlyOnceItHasHoveredThereForThreeTenthsOfASecond() {
        var hover = DropHover()
        hover.over(2, at: 10)
        XCTAssertFalse(hover.takes(2, at: 10.29), "a drag that overshoots a cue doesn't go to air")
        XCTAssertTrue(hover.takes(2, at: 10.3))
        XCTAssertFalse(hover.takes(1, at: 10.3), "only the cell it hovers on")
        hover.over(2, at: 10.4)
        XCTAssertTrue(hover.takes(2, at: 10.4), "staying on the cell doesn't start the wait again")
        hover.over(nil, at: 10.5)
        hover.over(2, at: 10.6)
        XCTAssertFalse(hover.takes(2, at: 10.7), "leaving and coming back does")
    }
}
