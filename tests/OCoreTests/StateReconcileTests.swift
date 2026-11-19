import Foundation
import XCTest
@testable import OCore

/// Spec 5 §1 and §2 as corrected 2026-11-18 — "a channel or a stack that an
/// edit makes gets its empty entry in ShowState, and one that an edit deletes
/// loses it"; "every other entry stays as it was. A deleted stack's mutes go
/// with it, and a stack's mute of a channel goes when that channel's slot is
/// removed."
final class StateReconcileTests: XCTestCase {
    typealias F = FixtureLibrary

    /// A state with something in every part of it, on the fixture roots.
    private func busy(_ edits: inout Edits) -> ShowState {
        edits.play("playlist \"Sunday\"", "next", "channel 3 write text \"9:55\"", "stack 1 mute 2 on", "stack 2 mute 3 on",
                   "stack 2 blackout on", "output 2 stack 2", "popup 1 set \"Nursery\"")
        return edits.context.state ?? ShowState()
    }

    func test_aStateMadeForTheRootsComesBackAsItIs() {
        var edits = Edits()
        let fresh = ShowState.fresh(library: edits.library, machine: edits.machine)
        XCTAssertEqual(fresh.reconciled(library: edits.library, machine: edits.machine), fresh)
        let state = busy(&edits)
        XCTAssertNotEqual(state, fresh)
        XCTAssertEqual(state.reconciled(library: edits.library, machine: edits.machine), state)
    }

    func test_newOnesStartEmptyDeletedOnesGoAndTheRestStayAsTheyWere() throws {
        var edits = Edits()
        let state = busy(&edits)
        XCTAssertNotEqual(state.channels[1]?.content, .empty)
        XCTAssertNotNil(state.pointer)

        // The roots as a restore or an undo may leave them: channel 3 and stack 2 gone, a channel 5 and a stack 3 made.
        var library = edits.library
        var machine = edits.machine
        library.channels.removeAll { $0.number == 3 }
        library.channels.append(Channel(number: 5, label: "Lower third", defaults: ChannelDefaults(transition: 2, audioTransition: 1, gain: -6), uuid: F.uuid("5c5c", 5)))
        machine.stacks.removeAll { $0.number == 2 }
        machine.stacks.append(Stack(number: 3, slots: [StackSlot(channel: 5)], uuid: F.uuid("5e5e", 3)))

        let now = state.reconciled(library: library, machine: machine)
        XCTAssertEqual(now.channels.keys.sorted(), [1, 2, 5])
        XCTAssertEqual(now.channels[1], state.channels[1], "what a surviving channel holds, with its attributes and its lock")
        XCTAssertEqual(now.channels[2], state.channels[2])
        XCTAssertEqual(now.channels[5], .fresh(for: try XCTUnwrap(library.channel(5))), "empty, each attribute at the channel's default")
        XCTAssertEqual(now.stacks.keys.sorted(), [1, 3])
        XCTAssertEqual(now.stacks[1], state.stacks[1])
        XCTAssertEqual(now.stacks[3], StackState())
        XCTAssertEqual(now.outputs, [1: 1, 2: 1], "output 2 showed stack 2, which is gone: it is on its default stack")
        XCTAssertEqual(now.pointer, state.pointer)
        XCTAssertEqual(now.armed, state.armed)
        XCTAssertEqual(now.popups, state.popups)
        XCTAssertEqual(now.reconciled(library: library, machine: machine), now, "once is enough")
    }

    func test_aStacksMuteOfAChannelGoesWithItsSlot() {
        var edits = Edits()
        let state = busy(&edits)
        XCTAssertEqual(state.stacks[1]?.muted, [2])
        XCTAssertEqual(state.stacks[2], StackState(blackout: true, muted: [3]))
        edits.apply("edit stack 1 slot 2 remove")
        edits.apply("edit stack 2 slot 2 move 1")
        let now = state.reconciled(library: edits.library, machine: edits.machine)
        XCTAssertEqual(now.stacks[1]?.muted, [])
        XCTAssertEqual(now.stacks[2], StackState(blackout: true, muted: [3]), "a slot that only moved keeps its mute, and the stack its blackout")
    }

    /// Spec 3 §2 — state is held by number, which is why a channel on air
    /// can't be renumbered (Spec 5 §6): off air, it starts empty under its
    /// new number.
    func test_aRenumberedChannelStartsEmptyUnderItsNewNumber() {
        var edits = Edits()
        edits.play("channel 3 write text \"9:55\"")
        let state = edits.context.state ?? ShowState()
        edits.apply("edit channel 3 renumber 9")
        let now = state.reconciled(library: edits.library, machine: edits.machine)
        XCTAssertNil(now.channels[3])
        XCTAssertEqual(now.channels[9]?.content, .empty)
    }
}
