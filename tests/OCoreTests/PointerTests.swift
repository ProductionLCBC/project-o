import Foundation
import XCTest
@testable import OCore

/// Spec 3 §5 as Spec 7 §4 corrected it — the pointer is `{playlist,
/// itemUuid, listUuid, cueUuid}`, the armed trigger `{itemUuid, cueUuid,
/// atFrame}`; and the navigation that names a playlist, its items and its
/// triggers.
final class PointerTests: XCTestCase {
    typealias F = Fixtures

    /// The in-code playlist with list 1 linked twice: 1 header, 2 L1, 3 L2, 4 L1.
    static let twice = Playlist(uuid: F.playlistUuid, title: "Sunday", serviceDate: "2026-11-01", items: [
        .header(label: "Welcome", uuid: F.itemUuid(1)),
        .linked(list: 1, listUuid: F.listUuid(1), uuid: F.itemUuid(2)),
        .linked(list: 2, listUuid: F.listUuid(2), uuid: F.itemUuid(3)),
        .linked(list: 1, listUuid: F.listUuid(1), uuid: F.itemUuid(4)),
    ])

    func context(_ machine: Machine = F.machine, frame: Int = 100) -> ProjectionContext {
        F.context(frame: frame, source: .osc, machine: machine)
    }

    func machine(with playlist: Playlist) -> Machine {
        var machine = F.machine
        machine.playlists = [playlist]
        return machine
    }

    func liveItem(_ state: ShowState, _ context: ProjectionContext) -> String? {
        Fold(state: state, context: context).value(of: "Live Item")
    }

    /// Spec 7 §4 — "a song linked twice stays on the right copy": the pointer
    /// names the item it was fired from, so `next` goes on in that copy and
    /// `[Live Item]` reads that item's position.
    func test_aListLinkedTwiceKeepsThePointerOnTheCopyItWasFiredFrom() {
        let context = context(machine(with: Self.twice))
        var state = F.fresh()
        state.pointer = LivePointer(playlist: F.playlistUuid)
        (state, _) = project(state, [.itemCue(item: 4, cue: 2)], context: context)
        XCTAssertEqual(state.pointer, LivePointer(playlist: F.playlistUuid, itemUuid: F.itemUuid(4),
                                                  listUuid: F.listUuid(1), cueUuid: F.cueUuid(list: 1, cue: 2)))
        XCTAssertEqual(liveItem(state, context), "4")

        (state, _) = project(state, [.next], context: context)
        XCTAssertEqual(state.pointer?.itemUuid, F.itemUuid(4))
        XCTAssertEqual(state.pointer?.cueUuid, F.cueUuid(list: 1, cue: 3))
        (state, _) = project(state, [.next], context: context)
        XCTAssertEqual(state.pointer?.cueUuid, F.cueUuid(list: 1, cue: 3), "the end of the playlist: nothing past it")

        // The same cue through item 2 goes on into item 3.
        state.pointer = LivePointer(playlist: F.playlistUuid, itemUuid: F.itemUuid(2), listUuid: F.listUuid(1), cueUuid: F.cueUuid(list: 1, cue: 3))
        XCTAssertEqual(liveItem(state, context), "2")
        (state, _) = project(state, [.next], context: context)
        XCTAssertEqual(state.pointer?.itemUuid, F.itemUuid(3))
        XCTAssertEqual(state.pointer?.listUuid, F.listUuid(2))
    }

    /// Spec 3 §5 — the armed trigger names the item of the cue it will fire.
    func test_theArmedTriggerNamesItsItem() {
        var playlist = Self.twice
        playlist.items.append(.linked(list: 4, listUuid: F.listUuid(4), uuid: F.itemUuid(5)))
        let context = context(machine(with: playlist), frame: 100)
        var state = F.fresh()
        state.pointer = LivePointer(playlist: F.playlistUuid)
        (state, _) = project(state, [.itemCue(item: 5, cue: 1)], context: context)
        XCTAssertEqual(state.armed, ArmedTrigger(itemUuid: F.itemUuid(5), cueUuid: F.cueUuid(list: 4, cue: 2), atFrame: 400))

        // A library list fired directly arms with no item.
        (state, _) = project(state, [.listCue(list: 4, cue: 1)], context: context)
        XCTAssertEqual(state.armed, ArmedTrigger(itemUuid: nil, cueUuid: F.cueUuid(list: 4, cue: 2), atFrame: 400))
    }

    /// Spec 7 §4 — "`disarm` ... clears the armed trigger with a `pointer`
    /// effect whose `armed` is empty, so nothing fires on its own; with
    /// nothing armed it is a `noop`."
    func test_disarmClearsTheArmedTriggerAndIsANoopWithNothingArmed() {
        let context = context(frame: 100)
        let (armed, _) = project(F.fresh(), [.listCue(list: 4, cue: 1)], context: context)
        XCTAssertNotNil(armed.armed)
        let (disarmed, effects) = project(armed, [.disarm], context: context)
        XCTAssertNil(disarmed.armed)
        XCTAssertEqual(disarmed.pointer, armed.pointer, "the pointer stays where it was")
        XCTAssertEqual(effects, [.pointer(old: armed.pointer, new: armed.pointer, armed: nil)])
        XCTAssertEqual(disarmed.channels, armed.channels)

        let (again, noop) = project(disarmed, [.disarm], context: context)
        XCTAssertEqual(again, disarmed)
        XCTAssertEqual(noop, [.noop(.disarm)])
    }

    /// The runner logs a `disarm` as itself: its `pointer` effect names the
    /// live cue, but it fires nothing, so no cue group follows and the cue's
    /// writes don't run again on air.
    func test_theRunnerCountsOnlyNavigationAsAFire() throws {
        let context = context(frame: 100)
        let (armed, _) = project(F.fresh(), [.listCue(list: 4, cue: 1)], context: context)
        let group = CommandGroup(id: GroupID("g-00000001"), source: CommandSource(kind: .osc), commands: [GuardedCommand(.disarm)])
        let outcome = try CommandRunner.run(group, state: armed, context: context).get()
        XCTAssertEqual(outcome.executed.map(\.command), [.disarm])
        XCTAssertEqual(outcome.executed.first?.result, .ok)
        XCTAssertNil(outcome.executed.first?.fire)
        XCTAssertNil(outcome.state.armed)
    }
}
