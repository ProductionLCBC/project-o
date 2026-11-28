import XCTest
import OCore
@testable import OEngine

/// Spec 4 §5 — a stack texture is "The size of the output showing it, the
/// largest when several do; for a stack no output shows, that of the largest
/// output whose default stack it is, else 1920 by 1080 (Spec 11 §3). The old
/// stack of a running switch keeps its size until the switch ends"; a channel
/// texture is "The channel's render size (largest including stack ...)".
/// Adam's answer of 2026-11-18: at a live switch too.
final class MachineGeometryTests: XCTestCase {
    static let wall = PixelSize(width: 4096, height: 2160)
    static let hd = PixelSize(width: 1920, height: 1080)

    /// Output 1, the wall, defaults to stack 1; output 2, a 1080p screen, to stack 2; stack 3 is no output's default.
    private func roots() throws -> (library: Library, machine: Machine) {
        let library = try EngineFixtures.library()
        var machine = try EngineFixtures.spikeMachine()
        machine.outputs[0].format.width = Self.wall.width
        machine.outputs[0].format.height = Self.wall.height
        machine.outputs[0].defaultStack = 1
        machine.outputs[1].format.width = Self.hd.width
        machine.outputs[1].format.height = Self.hd.height
        machine.outputs[1].defaultStack = 2
        machine.stacks.append(Stack(number: 3, slots: [StackSlot(channel: 3)], label: "Side"))
        return (library, machine)
    }

    func test_aStackTakesTheSizeOfTheOutputShowingIt() throws {
        let (library, machine) = try roots()
        var state = ShowState.fresh(library: library, machine: machine)
        var geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.stackSize(1), Self.wall)
        XCTAssertEqual(geometry.stackSize(2), Self.hd)
        XCTAssertEqual(geometry.stackSize(3), Self.hd, "no output shows it or defaults to it: 1920 by 1080")

        // The wall is switched to stack 3: stack 3 is the wall's size, and stack 1 keeps the size of the output that defaults to it.
        state.outputs[1] = 3
        geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.stackSize(3), Self.wall)
        XCTAssertEqual(geometry.stackSize(1), Self.wall, "no output shows it; output 1 defaults to it")

        // The small screen shows stack 1: the output showing it comes before the one that defaults to it.
        state.outputs[2] = 1
        geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.stackSize(1), Self.hd)
        XCTAssertEqual(geometry.stackSize(2), Self.hd, "no output shows it; output 2 defaults to it")

        // Both show stack 2: the largest.
        state.outputs = [1: 2, 2: 2]
        geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.stackSize(2), Self.wall)
    }

    func test_theOldStackOfARunningSwitchKeepsItsSize() throws {
        let (library, machine) = try roots()
        var state = ShowState.fresh(library: library, machine: machine)
        // Output 2 defaults to stack 1 here, so nothing but the wall's showing makes stack 1 the wall's size.
        var both = machine
        both.outputs[0].defaultStack = 3
        both.outputs[1].defaultStack = 2
        state = ShowState.fresh(library: library, machine: both)
        state.outputs[1] = 1
        XCTAssertEqual(MachineGeometry(library: library, machine: both, state: state).stackSize(1), Self.wall)
        // The wall switches to stack 2 over a dissolve: stack 1 is still mixed, at the wall's size, until the switch ends.
        state.outputs[1] = 2
        XCTAssertEqual(MachineGeometry(library: library, machine: both, state: state, switching: [1: 1]).stackSize(1), Self.wall)
        XCTAssertEqual(MachineGeometry(library: library, machine: both, state: state, switching: [1: 1]).stackSize(2), Self.wall)
        XCTAssertEqual(MachineGeometry(library: library, machine: both, state: state).stackSize(1), Self.hd, "the switch is over: 1920 by 1080")
    }

    func test_aChannelSetToLargestFollowsItsStacksAndAFixedSizeStays() throws {
        var (library, machine) = try roots()
        library.channels[1].renderSize = .size(width: 1280, height: 720)   // channel 2
        var state = ShowState.fresh(library: library, machine: machine)
        var geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.channelSize(1), Self.wall, "stack 1 holds it, on the wall")
        XCTAssertEqual(geometry.channelSize(2), PixelSize(width: 1280, height: 720))
        XCTAssertEqual(geometry.channelSize(3), Self.hd, "stacks 2 and 3 hold it")
        state.outputs[1] = 3
        geometry = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(geometry.channelSize(3), Self.wall, "stack 3 is on the wall now")
        XCTAssertEqual(geometry.channelSize(2), PixelSize(width: 1280, height: 720))
        machine.stacks.removeAll { $0.number != 1 }
        geometry = MachineGeometry(library: library, machine: machine, state: ShowState.fresh(library: library, machine: machine))
        XCTAssertEqual(geometry.channelSize(3), Self.hd, "no stack holds it: 1920 by 1080")
    }

    func test_twoGeometriesCompare() throws {
        let (library, machine) = try roots()
        var state = ShowState.fresh(library: library, machine: machine)
        let before = MachineGeometry(library: library, machine: machine, state: state)
        XCTAssertEqual(before, MachineGeometry(library: library, machine: machine, state: state))
        XCTAssertEqual(before, MachineGeometry(library: library, machine: machine), "with no state, every output is on its default stack")
        state.outputs[1] = 3
        XCTAssertNotEqual(before, MachineGeometry(library: library, machine: machine, state: state))
    }
}
