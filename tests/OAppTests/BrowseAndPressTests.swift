import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §6, "Browsing and live" (S10) — "The live context is the live
/// playlist, or the list fired from the library when that is live. While
/// the grid shows anything else, it is browsing ... A song opened from the
/// Library while its playlist is live is browsing too. Scrolling within the
/// live playlist isn't browsing. A fire from the grid makes what it fired
/// the live context, so the grid stops browsing; a fire from anywhere else
/// (a key, a trigger, OSC) leaves the grid where it is. Back to Live ...
/// returns the grid to the live context ... With nothing live there is no
/// amber."
final class BrowseStateTests: XCTestCase {
    private func live(playlist: String? = nil, list: String? = nil) -> LiveStatus {
        var live = LiveStatus()
        live.playlist = playlist
        live.listUuid = list
        return live
    }

    func test_theLiveContextIsTheLivePlaylistOrTheListFiredFromTheLibrary() {
        XCTAssertEqual(BrowseState.liveContext(live(playlist: "b1a7", list: "a9f0")), .playlist("b1a7"))
        XCTAssertEqual(BrowseState.liveContext(live(list: "a9f0")), .list("a9f0"), "a list fired from the library")
        XCTAssertNil(BrowseState.liveContext(live()))
    }

    func test_showingAnythingButTheLiveContextIsBrowsing() {
        var browse = BrowseState(shown: .playlist("b1a7"))
        XCTAssertFalse(browse.isBrowsing(live: live(playlist: "b1a7", list: "a9f0")), "the live playlist, wherever it is scrolled to")
        browse.browse(.playlist("0ther"))
        XCTAssertTrue(browse.isBrowsing(live: live(playlist: "b1a7")))
        browse.browse(.list("a9f0"))
        XCTAssertTrue(browse.isBrowsing(live: live(playlist: "b1a7", list: "a9f0")), "a song opened from the Library while its playlist is live is browsing too")
    }

    func test_withNothingLiveThereIsNoAmber() {
        let browse = BrowseState(shown: .playlist("b1a7"))
        XCTAssertFalse(browse.isBrowsing(live: live()))
        XCTAssertFalse(BrowseState().isBrowsing(live: live(playlist: "b1a7")), "and none before the grid shows anything")
    }

    func test_aFireFromTheGridMakesWhatItFiredLiveSoTheGridStopsBrowsing() {
        let browse = BrowseState(shown: .playlist("0ther"))
        XCTAssertTrue(browse.isBrowsing(live: live(playlist: "b1a7")))
        // The click sent `playlist "Other"` and `item 2 cue 1`; the live event names that playlist.
        XCTAssertFalse(browse.isBrowsing(live: live(playlist: "0ther", list: "a9f0")))
    }

    func test_aFireFromAnywhereElseLeavesTheGridWhereItIs() {
        let browse = BrowseState(shown: .playlist("b1a7"))
        // A key, a trigger or OSC loaded another playlist: the grid doesn't move, so now it is browsing.
        XCTAssertEqual(browse.shown, .playlist("b1a7"))
        XCTAssertTrue(browse.isBrowsing(live: live(playlist: "0ther")))
    }

    func test_backToLiveReturnsTheGridToTheLiveContext() {
        var browse = BrowseState(shown: .list("a9f0"))
        browse.backToLive(live: live(playlist: "b1a7"))
        XCTAssertEqual(browse.shown, .playlist("b1a7"))
        browse.backToLive(live: live())
        XCTAssertEqual(browse.shown, .playlist("b1a7"), "with nothing live there is nowhere to go back to")
    }

    func test_atConnectTheGridShowsTheLiveContextElseTheLastThingBrowsed() {
        // Area 13 reading — the live context when something is live, else the last thing browsed.
        var browse = BrowseState()
        browse.connected(live: live(playlist: "b1a7"), lastBrowsed: .list("a9f0"))
        XCTAssertEqual(browse.shown, .playlist("b1a7"))
        var quiet = BrowseState()
        quiet.connected(live: live(), lastBrowsed: .list("a9f0"))
        XCTAssertEqual(quiet.shown, .list("a9f0"))
        // A reconnection leaves a grid that already shows something where it is.
        var showing = BrowseState(shown: .playlist("0ther"))
        showing.connected(live: live(playlist: "b1a7"), lastBrowsed: nil)
        XCTAssertEqual(showing.shown, .playlist("0ther"))
    }
}

/// Spec 10 §6, "Following the live cue" — "The grid scrolls only when the
/// live cue is out of view, and by the least amount. It never scrolls while
/// the pointer has moved over the grid in the last second, while a mouse
/// button is down or while a drag is under way; it catches up when the
/// pointer leaves the grid or rests, so a press never lands on a cue the
/// grid moved under it."
final class FollowLiveScrollTests: XCTestCase {
    func test_itScrollsOnlyWhenTheLiveCueIsOutOfViewAndByTheLeastAmount() {
        XCTAssertEqual(FollowLive.leastScroll(toShow: 100...220, in: 0...600), 0, "in view: no scroll")
        XCTAssertEqual(FollowLive.leastScroll(toShow: 560...680, in: 0...600), 80, "below: just far enough to show its foot")
        XCTAssertEqual(FollowLive.leastScroll(toShow: -40...80, in: 0...600), -40, "above: just far enough to show its top")
        XCTAssertEqual(FollowLive.leastScroll(toShow: 500...1300, in: 0...600), 500, "taller than the view: its top to the top")
    }

    func test_itNeverScrollsWhileThePointerMovedOverTheGridInTheLastSecond() {
        var follow = FollowLive()
        XCTAssertTrue(follow.mayScroll(at: 10))
        follow.pointerMoved(inside: true, at: 10)
        XCTAssertFalse(follow.mayScroll(at: 10.5))
        XCTAssertEqual(follow.catchUpAt(now: 10.5), 11, "it catches up when the pointer rests")
        XCTAssertTrue(follow.mayScroll(at: 11))
    }

    func test_itCatchesUpWhenThePointerLeavesTheGrid() {
        var follow = FollowLive()
        follow.pointerMoved(inside: true, at: 10)
        follow.pointerMoved(inside: false, at: 10.2)
        XCTAssertTrue(follow.mayScroll(at: 10.2))
        XCTAssertNil(follow.catchUpAt(now: 10.2))
    }

    func test_itNeverScrollsWhileAButtonIsDownOrADragIsUnderWay() {
        var follow = FollowLive()
        follow.buttonDown = true
        XCTAssertFalse(follow.mayScroll(at: 100))
        XCTAssertNil(follow.catchUpAt(now: 100), "nothing to wait for but the button")
        follow.buttonDown = false
        follow.dragging = true
        XCTAssertFalse(follow.mayScroll(at: 100))
        follow.dragging = false
        XCTAssertTrue(follow.mayScroll(at: 100))
    }
}

/// Spec 10 §6, "Clicking" — "Clicking a cue fires it, on the press ... A
/// second press on the same cue within the double-click interval doesn't
/// fire again, since a refire restarts media (Spec 3 §4). With ⌥ held, a
/// press doesn't fire. A secondary click (the right button, two fingers,
/// ⌃-click) opens the cue's menu and never fires." "Double-click" (S7) —
/// "Its first press has already fired the cue, as every press does;
/// ⌥-double-click, or the cue's menu, edits without firing."
final class CuePressGateTests: XCTestCase {
    func test_aPressFiresAndASecondOneWithinTheIntervalDoesNot() {
        var gate = CuePressGate()
        XCTAssertEqual(gate.press(cue: "11aa", at: 10, interval: 0.5), .fire)
        XCTAssertEqual(gate.press(cue: "11aa", at: 10.3, interval: 0.5), .doubleClick, "no refire: it would restart the media")
        XCTAssertEqual(gate.press(cue: "11aa", at: 10.4, interval: 0.5), .nothing, "nor a third")
        XCTAssertEqual(gate.press(cue: "11aa", at: 11.2, interval: 0.5), .fire, "after the interval it is a press like any other")
    }

    func test_aPressOnAnotherCueFiresAtOnce() {
        var gate = CuePressGate()
        XCTAssertEqual(gate.press(cue: "11aa", at: 10, interval: 0.5), .fire)
        XCTAssertEqual(gate.press(cue: "22bb", at: 10.1, interval: 0.5), .fire)
    }

    func test_withOptionHeldAPressDoesNotFireAndADoubleClickStillEdits() {
        var gate = CuePressGate()
        XCTAssertEqual(gate.press(cue: "11aa", at: 10, interval: 0.5, option: true), .nothing)
        XCTAssertEqual(gate.press(cue: "11aa", at: 10.2, interval: 0.5, option: true), .doubleClick, "⌥-double-click edits without firing")
    }

    func test_aSecondaryClickOpensTheMenuAndNeverFires() {
        var gate = CuePressGate()
        XCTAssertEqual(gate.press(cue: "11aa", at: 10, interval: 0.5, secondary: true), .menu)
        XCTAssertEqual(gate.press(cue: "11aa", at: 10.1, interval: 0.5), .fire, "and it is no first press of a double-click")
    }
}
