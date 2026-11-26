import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §8, "The top bar".
final class TopBarModelTests: XCTestCase {
    private func live(playlist: String? = nil, list: String? = nil, cue: String? = nil) -> LiveStatus {
        var live = LiveStatus()
        live.playlist = playlist
        live.listUuid = list
        live.cue = cue
        live.playlistTitle = "Sunday"
        live.listTitle = "Great Is Thy Faithfulness"
        live.label = "Verse 2"
        live.cuePosition = 3
        return live
    }

    func test_theLivePositionSaysThePlaylistTheListAndTheCue() {
        XCTAssertEqual(LivePosition.make(live: live(playlist: "b1a7", list: "a9f0", cue: "33cc"), shown: nil),
                       .cue(playlist: "Sunday", list: "Great Is Thy Faithfulness", number: 3, label: "Verse 2"))
        XCTAssertEqual(LivePosition.make(live: live(playlist: "b1a7"), shown: nil), .ready(playlist: "Sunday"), "a playlist loaded and no cue fired")
        XCTAssertEqual(LivePosition.make(live: live(list: "a9f0", cue: "33cc"), shown: nil),
                       .library(list: "Great Is Thy Faithfulness", number: 3, label: "Verse 2"), "a list fired from the library")
    }

    func test_nothingLiveSaysHowToStartWhileAPlaylistIsBrowsed() {
        // "Nothing live", and nothing more, whatever the grid browses (Spec 10 §8 as corrected 2026-11-25).
        XCTAssertEqual(LivePosition.make(live: live(), shown: .playlist("b1a7")), .nothing)
        XCTAssertEqual(LivePosition.make(live: live(), shown: .list("a9f0")), .nothing)
        XCTAssertEqual(LivePosition.make(live: live(), shown: nil), .nothing)
    }

    func test_oneDotPerOutputWithItsStackAndItsState() {
        let outputs = [Output(number: 2, defaultStack: 2, label: "Confidence"), Output(number: 1, defaultStack: 1, label: "Main"),
                       Output(number: 3, defaultStack: 1, label: "Lobby")]
        let dots = OutputDot.all(outputs: outputs,
                                 status: [1: OutputStatus(number: 1, stack: 1, state: "presenting"), 2: OutputStatus(number: 2, stack: 3, state: "paused")],
                                 stackStatus: [3: StackStatus(number: 3, blackout: true)])
        XCTAssertEqual(dots, [OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false),
                              OutputDot(number: 2, label: "Confidence", stack: 3, state: .lost, isBlackedOut: true),
                              OutputDot(number: 3, label: "Lobby", stack: 1, state: .absent, isBlackedOut: false)],
                       "in number order; paused reads lost; one the engine hasn't reported is absent on its default stack")
        XCTAssertEqual(OutputDot.all(outputs: [Output(number: 1, defaultStack: 1)], status: [1: OutputStatus(number: 1, stack: 1, state: "released")],
                                     stackStatus: [:]).first?.state, .released)
    }

    func test_theTagsShowOnlyWhileTheyApply() {
        let channels = [Channel(number: 1, label: "Background", audioOutputs: [1])]
        XCTAssertEqual(TopBarTag.all(channels: channels, audio: [:], popups: [:], engine: EngineStatus(), saving: nil), [])
        let tags = TopBarTag.all(channels: channels, audio: [1: AudioStatus(number: 1, state: "ok", muted: true)],
                                 popups: [1: PopupStatus(slot: 1, text: "Nursery 14"), 2: PopupStatus(slot: 2), 3: PopupStatus(slot: 3, text: "Car 7")],
                                 engine: EngineStatus(badges: [.init(kind: "disk")]), saving: .unsaved(3))
        XCTAssertEqual(tags, [.audioMuted, .popup(1), .popup(3), .engine(badges: 1), .saving(.unsaved(3))])
    }

    func test_audioLostIsForAnOutputAChannelRoutesTo() {
        // Area 13 reading — an embedded output nothing feeds is always silent, and says nothing.
        let channels = [Channel(number: 1, label: "Background", audioOutputs: [1])]
        let unfed = TopBarTag.all(channels: channels, audio: [1: AudioStatus(number: 1, state: "ok", muted: false), 2: AudioStatus(number: 2, state: "silent", muted: false)],
                                  popups: [:], engine: EngineStatus(), saving: nil)
        XCTAssertEqual(unfed, [])
        let lost = TopBarTag.all(channels: channels, audio: [1: AudioStatus(number: 1, state: "silent", muted: true)], popups: [:], engine: EngineStatus(),
                                 saving: nil)
        XCTAssertEqual(lost, [.audioLost], "lost says more than muted")
        let fallback = TopBarTag.all(channels: channels, audio: [1: AudioStatus(number: 1, state: "fallback", muted: false)], popups: [:], engine: EngineStatus(),
                                     saving: nil)
        XCTAssertEqual(fallback, [], "on its fallback device it still sounds")
    }

    func test_withNoOutputsTheBarSaysSoOrThatTheScreensAreMirrored() {
        XCTAssertEqual(OutputsNote.make(outputs: [], screensAreMirrored: false), .noOutputs)
        XCTAssertEqual(OutputsNote.make(outputs: [], screensAreMirrored: true), .mirrored)
        XCTAssertNil(OutputsNote.make(outputs: [Output(number: 1, defaultStack: 1)], screensAreMirrored: true))
    }

    func test_theRemoteDotIsLitForTwoSecondsAfterEachRemoteCommand() {
        var dot = RemoteDot()
        XCTAssertFalse(dot.isLit(at: 0))
        dot.arrived(from: ["osc"], at: 10)
        XCTAssertTrue(dot.isLit(at: 11.9))
        XCTAssertFalse(dot.isLit(at: 12))
        XCTAssertEqual(dot.sources, ["osc"])
    }

    func test_theArmedCountdownCountsOnTheAppsClock() {
        let armed = LiveStatus.Armed(item: nil, cue: "33cc", itemPosition: 2, cuePosition: 3, inMs: 8000)
        XCTAssertEqual(Countdown.remainingMs(armed, elapsedMs: 0), 8000)
        XCTAssertEqual(Countdown.remainingMs(armed, elapsedMs: 2500), 5500)
        XCTAssertEqual(Countdown.remainingMs(armed, elapsedMs: 9000), 0)
        XCTAssertNil(Countdown.remainingMs(nil, elapsedMs: 0))
    }
}

/// Spec 10 §4, "View settings" (S8), and §18: "under 1000 points of height
/// the panel collapses whatever it says".
final class ViewSettingsTests: XCTestCase {
    func test_theDefaultsAreTheFirstRunLayout() {
        let settings = ViewSettings()
        XCTAssertEqual(settings.leftColumnWidth, 248)
        XCTAssertEqual(settings.rightColumnWidth, 380)
        XCTAssertEqual(settings.panel, .default, "the divider at default")
        XCTAssertFalse(settings.tabbedPanelCollapsed, "the panel open")
        XCTAssertTrue(settings.showsThumbnails && settings.showsChips && settings.showsTriggers, "thumbnails, chips, labels and triggers")
        XCTAssertFalse(settings.showsNotes, "with notes off")
        XCTAssertFalse(settings.multiviewer, "the multiviewer off")
        XCTAssertNil(settings.previewStack, "the preview on the thumbnail stack")
        XCTAssertNil(settings.stripStack, "the strip showing all channels")
        XCTAssertFalse(settings.showsArchivedPlaylists)
        XCTAssertFalse(settings.isCompact)
    }

    func test_theColumnsStayInsideTheirLimits() {
        XCTAssertEqual(ViewSettings.clampedLeft(120), 200)
        XCTAssertEqual(ViewSettings.clampedLeft(300), 300)
        XCTAssertEqual(ViewSettings.clampedLeft(500), 360)
        XCTAssertEqual(ViewSettings.clampedRight(100), 340)
        XCTAssertEqual(ViewSettings.clampedRight(600), 480)
    }

    func test_underAThousandPointsThePanelCollapsesWhateverTheSettingSays() {
        XCTAssertTrue(PanelCollapseRule.isCollapsed(windowHeight: 900, setting: false))
        XCTAssertTrue(PanelCollapseRule.isCollapsed(windowHeight: 999, setting: false))
        XCTAssertFalse(PanelCollapseRule.isCollapsed(windowHeight: 1000, setting: false), "above that, the setting applies")
        XCTAssertTrue(PanelCollapseRule.isCollapsed(windowHeight: 1200, setting: true))
    }

    func test_recentlyUsedMediaKeepsTheNewestTwenty() {
        var settings = ViewSettings()
        for n in 1...25 { settings.used(media: "sha256:\(n)") }
        settings.used(media: "sha256:20")
        XCTAssertEqual(settings.recentMedia.count, 20)
        XCTAssertEqual(settings.recentMedia.prefix(3), ["sha256:20", "sha256:25", "sha256:24"], "an item used again goes to the front, once")
    }

    func test_theSettingsRoundTripAsJSON() throws {
        var settings = ViewSettings()
        settings.leftColumnWidth = 300
        settings.panel = .collapsed
        settings.stripStack = 2
        settings.openFolders = ["Hymns"]
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(ViewSettings.self, from: data), settings)
    }
}

/// Spec 10 §6, "The Media pool panel".
final class MediaPoolTests: XCTestCase {
    private func names(_ filter: MediaPool.Filter) throws -> [String] {
        MediaPool.tiles(try Recorded.media(), filter: filter).map(\.name)
    }

    func test_theTilesShowEveryItemByNameAndAMissingOneKeepsItsPlace() throws {
        let tiles = MediaPool.tiles(try Recorded.media(), filter: MediaPool.Filter())
        XCTAssertEqual(tiles.map(\.name), ["announcement.png", "cross.png", "dawn.mp4", "mountains.mp4", "welcome.oslide"])
        XCTAssertEqual(tiles.map(\.overlay), [.none, .none, .none, .missing, .none])
        XCTAssertEqual(tiles.map(\.isOnThisMac), [true, false, false, false, false])
        XCTAssertEqual(tiles[2].durationMs, 2000, "a duration badge on timed items")
    }

    func test_theKindFilterAndTheSearch() throws {
        var filter = MediaPool.Filter()
        filter.kind = .video
        XCTAssertEqual(try names(filter), ["dawn.mp4", "mountains.mp4"])
        filter.kind = .image
        XCTAssertEqual(try names(filter), ["announcement.png", "cross.png"])
        filter.kind = .all
        filter.folder = "slides"
        filter.search = "DAWN"
        XCTAssertEqual(try names(filter), ["dawn.mp4"], "search across every folder, whatever folder is chosen")
    }

    func test_aFolderShowsWhatIsInItAndBelowIt() throws {
        var filter = MediaPool.Filter()
        filter.folder = "backgrounds"
        XCTAssertEqual(try names(filter), ["cross.png", "dawn.mp4", "mountains.mp4"])
        XCTAssertEqual(MediaPool.folders(try Recorded.media()), ["backgrounds", "slides"])
    }

    func test_usedInThisListKeepsTheListsReferences() throws {
        var filter = MediaPool.Filter()
        filter.usedIn = ["sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"]
        XCTAssertEqual(try names(filter), ["dawn.mp4"])
    }

    func test_aDeletedItemShowsWhileSomethingUsesItAndAReplacedOneOnlyUnderItsFilter() throws {
        var media = try Recorded.media()
        media[0].presence = "deleted"          // dawn.mp4, used once
        media[2].presence = "deleted"          // cross.png
        media[2].uses = 0
        media[1].replacedBy = media[0].id      // mountains.mp4 was replaced
        XCTAssertEqual(MediaPool.tiles(media, filter: MediaPool.Filter()).map(\.name), ["announcement.png", "dawn.mp4", "welcome.oslide"])
        XCTAssertEqual(MediaPool.tiles(media, filter: MediaPool.Filter()).first { $0.name == "dawn.mp4" }?.overlay, .deleted)
        var replaced = MediaPool.Filter()
        replaced.replacedOnly = true
        XCTAssertEqual(MediaPool.tiles(media, filter: replaced).map(\.name), ["mountains.mp4"], "so they can be deleted")
    }

    func test_sortByDateAddedPutsTheNewestFirst() throws {
        var media = try Recorded.media()
        for index in media.indices { media[index].entry.addedAt = "2026-11-0\(index + 1)T10:00:00Z" }
        var filter = MediaPool.Filter()
        filter.sort = .dateAdded
        XCTAssertEqual(MediaPool.tiles(media, filter: filter).first?.name, "announcement.png", "the last one added")
    }

    func test_anItemsDropChannelIsItsOwnElseTheMachinesForItsKind() throws {
        let media = try Recorded.media()
        let settings = try XCTUnwrap(try Recorded.catalog().settings)
        let cross = try XCTUnwrap(media.first { $0.entry.path.hasSuffix("cross.png") }).entry
        let dawn = try XCTUnwrap(media.first { $0.entry.path.hasSuffix("dawn.mp4") }).entry
        XCTAssertEqual(MediaPool.dropChannel(for: dawn, settings: settings), 1, "its defaults.defaultChannel")
        XCTAssertEqual(MediaPool.dropChannel(for: cross, settings: settings), settings.dropChannels?.image, "the machine's dropChannels for its kind")
        var audio = dawn
        audio.kind = .audio
        audio.defaults.defaultChannel = nil
        var asking = settings
        asking.dropChannels = DropChannels(video: 1, image: 1, audio: nil)
        XCTAssertNil(MediaPool.dropChannel(for: audio, settings: asking), "Ask")
    }

    func test_theRecentStripShowsTheItemsLastUsedNewestFirst() throws {
        let media = try Recorded.media()
        let recents = MediaPool.recents(media, recent: [media[2].id, "sha256:gone", media[0].id])
        XCTAssertEqual(recents.map(\.name), ["cross.png", "dawn.mp4"], "an item the pool no longer has drops out")
    }
}

/// Spec 10 §13, "The first window".
final class FirstWindowLineTests: XCTestCase {
    func test_theFirstWindowNamesEachNewOutputUntilDismissed() {
        let outputs = [Output(number: 2, defaultStack: 3, label: "LG TV"), Output(number: 1, defaultStack: 1, label: "DELL U2720Q")]
        let line = FirstWindowLine.make(firstRun: true, dismissed: false, outputs: outputs)
        XCTAssertEqual(line?.outputs.map(\.number), [1, 2])
        XCTAssertEqual(line?.outputs.map(\.device), ["DELL U2720Q", "LG TV"], "Output 1 is DELL U2720Q")
        XCTAssertNil(FirstWindowLine.make(firstRun: true, dismissed: true, outputs: outputs))
        XCTAssertNil(FirstWindowLine.make(firstRun: false, dismissed: false, outputs: outputs), "only in the run that made the outputs")
    }
}
