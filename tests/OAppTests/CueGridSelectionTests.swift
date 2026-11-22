import Foundation
import XCTest
@testable import OApp

/// Spec 11 §4, "Selecting" — "The selection is one cue or several, and one
/// row: a channel's, or the header row", moved by clicks and by the arrows.
final class CueGridSelectionTests: XCTestCase {
    private let order = ["a", "b", "c", "d", "e"]
    private let channels = [1, 2, 3]

    func test_aClickOnACellSelectsItsCueAndChannelAndOnAHeaderItsCue() {
        var selection = CueGridSelection()
        selection.click(cue: "c", row: .channel(2))
        XCTAssertEqual(selection.ordered(in: order), ["c"])
        XCTAssertEqual(selection.row, .channel(2))
        XCTAssertEqual(selection.channel, 2)
        // "A click on a header selects its cue and the header row, and the inspector keeps the channel it showed."
        selection.click(cue: "d", row: .header)
        XCTAssertEqual(selection.ordered(in: order), ["d"])
        XCTAssertEqual(selection.row, .header)
        XCTAssertEqual(selection.channel, 2)
        XCTAssertFalse(selection.isMulti)
    }

    func test_shiftClickSelectsARangeAndCommandClickAddsOrRemovesOne() {
        var selection = CueGridSelection()
        selection.click(cue: "b", row: .channel(1))
        // "⇧-click selects a range of cues".
        selection.extend(to: "d", in: order)
        XCTAssertEqual(selection.ordered(in: order), ["b", "c", "d"])
        XCTAssertTrue(selection.isMulti)
        XCTAssertEqual(selection.row, .channel(1), "the row stays")
        // A second ⇧-click measures from the same cue, the other way too.
        selection.extend(to: "a", in: order)
        XCTAssertEqual(selection.ordered(in: order), ["a", "b"])
        // "⌘-click adds or removes one".
        selection.toggle(cue: "e", in: order)
        XCTAssertEqual(selection.ordered(in: order), ["a", "b", "e"])
        selection.toggle(cue: "a", in: order)
        XCTAssertEqual(selection.ordered(in: order), ["b", "e"])
        selection.toggle(cue: "e", in: order)
        selection.toggle(cue: "b", in: order)
        XCTAssertEqual(selection.ordered(in: order), ["b"], "the last cue stays selected: the page always shows one")
        XCTAssertEqual(selection.first(in: order), "b")
    }

    func test_theArrowsMoveThroughCuesAndRowsWithTheHeaderRowAtTheTop() {
        var selection = CueGridSelection()
        selection.click(cue: "b", row: .channel(2))
        // "← and → move to the cue before and after".
        selection.move(.right, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["c"])
        selection.move(.left, extend: false, order: order, channels: channels)
        selection.move(.left, extend: false, order: order, channels: channels)
        selection.move(.left, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["a"], "it stops at the first cue")
        // "↑ and ↓ move through the rows, the header row at the top".
        selection.move(.up, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.row, .channel(1))
        selection.move(.up, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.row, .header)
        XCTAssertEqual(selection.channel, 1, "the inspector keeps the channel it showed")
        selection.move(.up, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.row, .header)
        selection.move(.down, extend: false, order: order, channels: channels)
        selection.move(.down, extend: false, order: order, channels: channels)
        selection.move(.down, extend: false, order: order, channels: channels)
        selection.move(.down, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.row, .channel(3), "it stops at the last row")
        XCTAssertEqual(selection.channel, 3)
    }

    func test_shiftWithTheArrowsExtendsTheSelectionAcrossCues() {
        var selection = CueGridSelection()
        selection.click(cue: "c", row: .header)
        selection.move(.right, extend: true, order: order, channels: channels)
        selection.move(.right, extend: true, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["c", "d", "e"])
        // Back past where it began: the range turns round its first cue.
        selection.move(.left, extend: true, order: order, channels: channels)
        selection.move(.left, extend: true, order: order, channels: channels)
        selection.move(.left, extend: true, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["b", "c"])
        // A plain arrow leaves one cue selected, next to where the range ended.
        selection.move(.right, extend: false, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["c"])
        // ⇧ with ↑ or ↓ moves the row and keeps the cues.
        selection.extend(to: "e", in: order)
        selection.move(.down, extend: true, order: order, channels: channels)
        XCTAssertEqual(selection.ordered(in: order), ["c", "d", "e"])
        XCTAssertEqual(selection.row, .channel(1))
    }

    func test_theSelectionFollowsTheListWhenItChanges() {
        var selection = CueGridSelection()
        selection.click(cue: "c", row: .channel(3))
        selection.extend(to: "d", in: order)
        // One of the selected cues is deleted elsewhere: the other stays.
        selection.reconcile(order: ["a", "b", "d", "e"], channels: channels)
        XCTAssertEqual(selection.ordered(in: ["a", "b", "d", "e"]), ["d"])
        // Every selected cue is gone: the cue now at that place is selected, or the last.
        selection.reconcile(order: ["a", "b"], channels: channels, was: order)
        XCTAssertEqual(selection.ordered(in: ["a", "b"]), ["b"])
        // The row's channel is gone: the header row, and no channel a missing one.
        selection.reconcile(order: ["a", "b"], channels: [1, 2])
        XCTAssertEqual(selection.row, .header)
        XCTAssertEqual(selection.channel, 1)
        // An empty list has nothing to select.
        selection.reconcile(order: [], channels: [1, 2])
        XCTAssertTrue(selection.cues.isEmpty)
        XCTAssertNil(selection.first(in: []))
    }

    func test_openingOnACueSelectsItOnTheTextChannelsRow() {
        // Spec 11 §2, "Opening it": "the selected cue, else the live cue if it is in that list, else the first".
        let opened = CueGridSelection(cue: "d", channel: 2)
        XCTAssertEqual(opened.ordered(in: order), ["d"])
        XCTAssertEqual(opened.row, .channel(2))
        XCTAssertEqual(opened.channel, 2)
        let none = CueGridSelection(cue: nil, channel: nil)
        XCTAssertTrue(none.cues.isEmpty)
        XCTAssertEqual(none.row, .header)
    }
}
