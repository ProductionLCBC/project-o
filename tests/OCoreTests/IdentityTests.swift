import Foundation
import XCTest
@testable import OCore

/// Spec 1 §10 — Identity: "Renumbering a channel rewrites every reference in
/// lists, presets, stacks and macros; a swap renumbers both; `uuid` survives.
/// Hashing the same bytes at two paths yields one index entry." Spec 1 §4 is
/// the rule being tested; §7's `replace media` is the media counterpart.
final class IdentityTests: XCTestCase {
    typealias F = FixtureLibrary

    private var roots: (library: Library, machine: Machine) {
        let loaded = F.load()
        return (loaded.library, loaded.machine)
    }

    /// Every channel number named anywhere in both roots.
    private func channelReferences(_ library: Library, _ machine: Machine) -> [Int] {
        var numbers: [Int] = []
        func visit(_ commands: [GuardedCommand]) {
            for entry in commands {
                entry.command.forEachReference(of: .channel) { numbers.append($0) }
            }
        }
        for list in library.lists + machine.localLists { for cue in list.cues { visit(cue.commands) } }
        for macro in library.macros + machine.macros { visit(macro.commands) }
        for stack in machine.stacks { numbers.append(contentsOf: stack.slots.map(\.channel)) }
        for key in machine.keys { key.command.forEachReference(of: .channel) { numbers.append($0) } }
        for entry in library.mediaIndex.entries + machine.mediaLocal.entries {
            if let n = entry.defaults.defaultChannel { numbers.append(n) }
        }
        return numbers
    }

    // MARK: - Renumbering

    func test_renumberingAChannelRewritesEveryReferenceAndKeepsTheUuid() {
        var (library, machine) = roots
        let uuid = library.channel(2)?.uuid
        let before = channelReferences(library, machine)
        XCTAssertTrue(before.contains(2))

        let outcome = Identity.renumber(.channel, from: 2, to: 5, library: &library, machine: &machine)
        XCTAssertEqual(outcome, .renumbered)

        XCTAssertNil(library.channel(2))
        XCTAssertEqual(library.channel(5)?.uuid, uuid)
        XCTAssertEqual(library.channel(5)?.label, "Foreground")
        let after = channelReferences(library, machine)
        XCTAssertFalse(after.contains(2))
        XCTAssertEqual(after.filter { $0 == 5 }.count, before.filter { $0 == 2 }.count)
        XCTAssertEqual(after.filter { $0 == 1 }, before.filter { $0 == 1 }, "channel 1 is untouched")

        // The §9 confidence stack: both slots named channel 2.
        XCTAssertEqual(machine.stack(2)?.slots.map(\.channel), [5, 5])
        // The macro guard that reads channel 2 follows too (Spec 2 §7 values name channels).
        XCTAssertEqual(library.macro(1)?.commands.first?.when?.variable, "Channel 5 Content")
        // The slide entry's default channel.
        XCTAssertEqual(library.mediaIndex.entry(F.welcomeSlide)?.defaults.defaultChannel, 5)
        // The library stays in number order.
        XCTAssertEqual(library.channels.map(\.number), [1, 5])
    }

    func test_renumberingToATakenNumberIsRefused() {
        var (library, machine) = roots
        let untouched = (library, machine)
        XCTAssertEqual(Identity.renumber(.channel, from: 2, to: 1, library: &library, machine: &machine), .numberTaken)
        XCTAssertEqual(Identity.renumber(.channel, from: 9, to: 3, library: &library, machine: &machine), .noSuchObject)
        XCTAssertEqual(Identity.renumber(.channel, from: 2, to: 0, library: &library, machine: &machine), .invalidNumber)
        XCTAssertEqual(library, untouched.0)
        XCTAssertEqual(machine, untouched.1)
    }

    /// Spec 1 §4 — "Moving to a number that is already taken offers a swap,
    /// which renumbers both objects and rewrites both sets of references."
    func test_swappingTwoChannelsRenumbersBothAndRewritesBothSetsOfReferences() {
        var (library, machine) = roots
        let uuid1 = library.channel(1)?.uuid
        let uuid2 = library.channel(2)?.uuid
        XCTAssertEqual(machine.stack(1)?.slots.map(\.channel), [1, 2])

        XCTAssertEqual(Identity.swap(.channel, 1, 2, library: &library, machine: &machine), .renumbered)

        XCTAssertEqual(library.channel(1)?.uuid, uuid2)
        XCTAssertEqual(library.channel(2)?.uuid, uuid1)
        XCTAssertEqual(library.channel(1)?.label, "Foreground")
        XCTAssertEqual(machine.stack(1)?.slots.map(\.channel), [2, 1], "slot order is kept; the numbers swap")
        XCTAssertEqual(machine.stack(2)?.slots.map(\.channel), [1, 1])
        let verse = library.list(number: 42)?.cues[0].commands.map(\.command)
        XCTAssertEqual(verse?.first?.channelTarget, .number(2), "the background write now names channel 2")
        XCTAssertEqual(verse?.last?.channelTarget, .number(1))
    }

    func test_renumberingPresetsTransitionsAndGradesRewritesBoxesOutputsRidersAndIndexDefaults() {
        var (library, machine) = roots

        XCTAssertEqual(Identity.renumber(.preset, from: 3, to: 9, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.stack(2)?.slots.map(\.preset), [nil, 9])
        XCTAssertEqual(library.presets.map(\.number), [1, 2, 9])
        XCTAssertEqual(library.channel(1)?.defaultPreset, 1)

        XCTAssertEqual(Identity.renumber(.transition, from: 2, to: 4, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.preset(1)?.layouts[.any]?.boxes[1].transition.ref, 4)
        XCTAssertEqual(library.preset(1)?.layouts[.any]?.boxes[0].transition.ref, 1)
        XCTAssertEqual(machine.output(1)?.transitions, OutputTransitions(switch: 4, blackout: 3))
        XCTAssertEqual(machine.output(2)?.transitions, OutputTransitions(switch: 1, blackout: 4))
        XCTAssertEqual(library.list(number: 42)?.cues[0].commands[0].command.riders?.transition?.ref, 4)
        XCTAssertEqual(library.list(number: 42)?.cues[3].commands[0].command.riders?.audioTransition?.ref, 2, "audio transitions are their own space")
        XCTAssertEqual(library.list(number: 7)?.cues[1].commands[1].command, .channelTransition(channel: .number(1), ref: 4, ms: 750))
        XCTAssertEqual(machine.localLists[0].cues[0].commands[0].command.riders?.transition?.ref, 4, "local copies are rewritten too")
        XCTAssertEqual(library.channel(1)?.defaults.transition, 1)

        XCTAssertEqual(Identity.renumber(.grade, from: 1, to: 2, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.preset(9)?.layouts[.any]?.boxes[0].grade, 2)
        XCTAssertEqual(library.list(number: 42)?.cues[3].commands[0].command.riders?.grade?.ref, 2)
        XCTAssertEqual(library.mediaIndex.entry(F.mountains)?.defaults.grade, 2)

        XCTAssertEqual(Identity.renumber(.textStyle, from: 1, to: 3, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.preset(1)?.layouts[.any]?.boxes[1].textStyle?.fromStyle, 3)
        XCTAssertEqual(library.preset(2)?.layouts[.any]?.boxes[1].textStyle?.fromStyle, 2)
    }

    func test_renumberingMachineObjectsRewritesSettingsKeysMacrosAndLayouts() {
        var (library, machine) = roots

        XCTAssertEqual(Identity.renumber(.stack, from: 1, to: 3, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.outputs.map(\.defaultStack), [3, 3])
        XCTAssertEqual(machine.settings.thumbnailStack, 3)
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[1], .outputStack(output: 1, stack: 3))
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[2], .stackBlackout(stack: 3, state: .off))
        XCTAssertEqual(machine.keys[4].command, .stackBlackout(stack: 3, state: .toggle))
        XCTAssertEqual(library.preset(3)?.layouts.keys.sorted(), [.any, .stack(2)], "preset layouts for other stacks are untouched")
        XCTAssertEqual(Identity.renumber(.stack, from: 2, to: 6, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.preset(3)?.layouts.keys.sorted(), [.any, .stack(6)], "a preset's per-stack layout follows the stack")
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[3], .stackMute(stack: 6, channel: 2, state: .off))

        XCTAssertEqual(Identity.renumber(.output, from: 2, to: 7, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.audioOutput(2)?.device, .sdiOutput(7))
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[1], .outputStack(output: 1, stack: 3))

        XCTAssertEqual(Identity.renumber(.audioOutput, from: 1, to: 4, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.channels.map(\.audioOutputs), [[4], [4]])

        XCTAssertEqual(Identity.renumber(.macro, from: 2, to: 6, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.settings.startupMacro, 6)
        XCTAssertEqual(machine.keys[5].command, .macro(6))
        XCTAssertEqual(Identity.renumber(.macro, from: 1, to: 5, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.list(number: 7)?.cues[2].commands[1].command, .macro(5))

        XCTAssertEqual(Identity.renumber(.list, from: 42, to: 43, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.playlists[0].items.map(\.kind)[1], .linked(list: 43))
        XCTAssertEqual(library.list(number: 43)?.uuid, F.listUuid(42))
        XCTAssertEqual(machine.localLists[0].number, 42, "a local copy is its own document; its number records what it was cut from")

        // Input references live in content expressions and the inputs document.
        library.lists[0].cues[0].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .input(1)))))
        XCTAssertEqual(Identity.renumber(.input, from: 1, to: 2, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.inputs.map(\.number), [2])
        XCTAssertEqual(library.lists[0].cues[0].commands.last?.command, .channelWrite(ChannelWrite(channel: .number(1), content: .input(2))))
    }

    // MARK: - Media identity

    /// Spec 1 §4 — "Identical files anywhere under the root resolve to one identity."
    func test_hashingTheSameBytesAtTwoPathsYieldsOneIndexEntry() throws {
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: F.mediaRoot.appendingPathComponent("backgrounds/cross.png").path))
        let again = try XCTUnwrap(FileManager.default.contents(atPath: F.mediaRoot.appendingPathComponent("local/cross-fast.png").path))
        XCTAssertEqual(MediaID.sha256(of: bytes), F.cross)
        XCTAssertEqual(MediaID.sha256(of: again), F.cross)

        var index = MediaIndex()
        let first = MediaEntry(id: MediaID.sha256(of: bytes), path: "backgrounds/cross.png", kind: .image, size: bytes.count)
        let second = MediaEntry(id: MediaID.sha256(of: again), path: "local/cross-fast.png", kind: .image, size: again.count)
        XCTAssertTrue(index.add(first))
        XCTAssertFalse(index.add(second), "the same bytes are one identity")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entry(F.cross)?.path, "backgrounds/cross.png")
    }

    /// Spec 1 §7 — "A `replace media` command rewrites every reference from one
    /// id to another across lists, macros and presets, and records the mapping
    /// in the index so re-imports of the old file resolve to the new one."
    func test_replaceMediaRewritesEveryReferenceAndRecordsTheMapping() {
        var (library, machine) = roots
        let rewritten = Identity.replaceMedia(from: F.mountains, with: F.dawn, library: &library, machine: &machine)
        XCTAssertEqual(rewritten, 1)
        XCTAssertEqual(library.list(number: 7)?.cues[0].commands[0].command.mediaRef, F.dawn)
        XCTAssertEqual(library.mediaIndex.replaced[F.mountains], F.dawn)
        XCTAssertEqual(library.mediaIndex.resolveReplaced(F.mountains), F.dawn)
        XCTAssertEqual(library.mediaIndex.resolveReplaced(F.cross), F.cross)
        XCTAssertEqual(library.list(number: 42)?.cues[0].commands[0].command.mediaRef, F.dawn, "untouched")
    }
}
