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

        // The confidence stack's slot for channel 2, beside the clock's (Spec 6 §9).
        XCTAssertEqual(machine.stack(2)?.slots.map(\.channel), [5, 3])
        // The macro guard that reads channel 2 follows too (Spec 2 §7 values name channels).
        XCTAssertEqual(library.macro(1)?.commands.first?.when?.variable, "Channel 5 Content")
        // The slide entry's default channel.
        XCTAssertEqual(library.mediaIndex.entry(F.welcomeSlide)?.defaults.defaultChannel, 5)
        // The library stays in number order.
        XCTAssertEqual(library.channels.map(\.number), [1, 3, 5])
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
        XCTAssertEqual(machine.stack(2)?.slots.map(\.channel), [1, 3])
        let verse = library.list(number: 42)?.cues[0].commands.map(\.command)
        XCTAssertEqual(verse?.first?.channelTarget, .number(2), "the background write now names channel 2")
        XCTAssertEqual(verse?.last?.channelTarget, .number(1))
    }

    func test_renumberingPresetsTransitionsAndGradesRewritesBoxesOutputsRidersAndIndexDefaults() {
        var (library, machine) = roots
        machine.stacks[1].slots[0].preset = 3
        // Preset 1's body box with a transition of its own; its pixel box takes the channel's (null).
        if let at = library.presets.firstIndex(where: { $0.number == 1 }) {
            library.presets[at].layouts[.any]?.boxes[1].transition = BoxTransition(ref: 2, ms: 250)
        }

        XCTAssertEqual(Identity.renumber(.preset, from: 3, to: 9, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.stack(2)?.slots.map(\.preset), [9, nil])
        XCTAssertNil(machine.stack(2)?.defaultPreset)
        XCTAssertEqual(library.presets.map(\.number), [1, 2, 4, 9])
        XCTAssertEqual(library.channel(3)?.defaultPreset, 2, "the clock channel's default preset is not preset 3")
        XCTAssertEqual(library.channel(1)?.defaultPreset, 1)

        XCTAssertEqual(Identity.renumber(.transition, from: 2, to: 4, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.preset(1)?.layouts[.any]?.boxes[1].transition?.ref, 4)
        XCTAssertNil(library.preset(1)?.layouts[.any]?.boxes[0].transition, "the channel's stays the channel's")
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
        XCTAssertEqual(library.preset(2)?.layouts[.any]?.boxes[0].textStyle?.fromStyle, 2, "the Clock's [Time] box is in Caption's look")
        XCTAssertEqual(library.preset(1)?.layouts[.stack(2)]?.boxes.map { $0.textStyle?.fromStyle }, [3, 3])
    }

    /// Spec 5 §4 — "A stack, output, audio output or input belongs to one
    /// machine, but portable documents name machine-level numbers so that
    /// they meet them at every campus ... Renumbering a machine-level object
    /// therefore rewrites references in the machine root only. It leaves
    /// portable documents alone".
    func test_renumberingAMachineObjectRewritesTheMachineRootAndLeavesPortableDocuments() {
        var (library, machine) = roots
        // A master's cue may name an output, a stack, an audio output and an input: it meets them by number at every campus.
        library.lists[0].cues[0].commands.append(GuardedCommand(.outputStack(output: 2, stack: 2)))
        library.lists[0].cues[0].commands.append(GuardedCommand(.audioMute(audio: .number(1), state: .on)))
        library.lists[0].cues[0].commands.append(GuardedCommand(.channelWrite(ChannelWrite(channel: .number(1), content: .input(1)))))
        // A local copy is a document of the machine root (Spec 1 §2).
        machine.localLists[0].cues[0].commands.append(GuardedCommand(.outputStack(output: 2, stack: 2)))
        machine.localLists[0].cues[0].commands.append(GuardedCommand(.audioMute(audio: .number(1), state: .on)))
        let portable = library

        XCTAssertEqual(Identity.renumber(.stack, from: 1, to: 3, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.outputs.map(\.defaultStack), [3, 3])
        XCTAssertEqual(machine.settings.thumbnailStack, 3)
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[1], .outputStack(output: 1, stack: 3))
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[2], .stackBlackout(stack: .number(3), state: .off))
        XCTAssertEqual(machine.keys[4].command, .stackBlackout(stack: .number(3), state: .toggle))

        XCTAssertEqual(Identity.renumber(.stack, from: 2, to: 6, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[3], .stackMute(stack: 6, channel: 2, state: .off))
        XCTAssertEqual(machine.localLists[0].cues[0].commands.suffix(2).first?.command, .outputStack(output: 2, stack: 6))
        XCTAssertEqual(library.preset(3)?.layouts.keys.sorted(), [.any, .stack(2)],
                       "a preset's layout for stack 2 still meets stack 2 at every campus")
        XCTAssertEqual(library.preset(1)?.layouts.keys.sorted(), [.any, .stack(2)], "and so does Preset 1's confidence layout")

        XCTAssertEqual(Identity.renumber(.output, from: 2, to: 7, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.audioOutput(2)?.device, .sdiOutput(7))
        XCTAssertEqual(machine.localLists[0].cues[0].commands.suffix(2).first?.command, .outputStack(output: 7, stack: 6))
        XCTAssertEqual(machine.macro(2)?.commands.map(\.command)[1], .outputStack(output: 1, stack: 3))

        XCTAssertEqual(Identity.renumber(.audioOutput, from: 1, to: 4, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.audioOutputs.map(\.number), [2, 4])
        XCTAssertEqual(machine.localLists[0].cues[0].commands.last?.command, .audioMute(audio: .number(4), state: .on))
        XCTAssertEqual(library.channels.map(\.audioOutputs), [[1], [1], [1]], "channels are portable: they still name audio output 1")

        XCTAssertEqual(Identity.renumber(.input, from: 1, to: 2, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.inputs.map(\.number), [2])

        XCTAssertEqual(library, portable, "no portable document changed")
    }

    /// Spec 1 §4 — "every internal reference in the library and the machine
    /// root is rewritten in the same save", for the portable types.
    func test_renumberingAMacroOrAListRewritesBothRoots() {
        var (library, machine) = roots

        XCTAssertEqual(Identity.renumber(.macro, from: 2, to: 6, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.settings.startupMacro, 6)
        XCTAssertEqual(machine.keys[5].command, .macro(6))
        XCTAssertEqual(Identity.renumber(.macro, from: 1, to: 5, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.list(number: 7)?.cues[2].commands[1].command, .macro(5))

        XCTAssertEqual(Identity.renumber(.list, from: 42, to: 43, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.playlist(uuid: F.playlistUuid)?.items.map(\.kind)[1], .linked(list: 43, listUuid: F.listUuid(42)))
        XCTAssertEqual(library.list(number: 43)?.uuid, F.listUuid(42))
        XCTAssertEqual(machine.localLists[0].number, 42, "a local copy is its own document; its number records what it was cut from")
    }

    /// Spec 8 §8 — "`dropChannels` ... each a channel number or null": a
    /// reference like any other, so it follows its channel (Spec 1 §4).
    func test_renumberingAChannelCarriesTheMachinesDropChannels() {
        var (library, machine) = roots
        XCTAssertEqual(machine.settings.dropChannels, DropChannels(video: 1, image: 1, audio: nil))
        XCTAssertEqual(Identity.renumber(.channel, from: 1, to: 8, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.settings.dropChannels, DropChannels(video: 8, image: 8, audio: nil))
        XCTAssertEqual(Identity.swap(.channel, 8, 2, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(machine.settings.dropChannels, DropChannels(video: 2, image: 2, audio: nil))
    }

    /// Spec 1 §4 — "every internal reference in the library and the machine
    /// root is rewritten": an edit a cue or a macro holds names objects in
    /// its value too, a slot's preset or the command it would insert, and
    /// those numbers follow. Spec 11 §3 counts them among "the commands,
    /// riders, guards and held edits of cues and macros".
    func test_theNumbersInTheValueOfAHeldEditFollowARenumber() throws {
        var (library, machine) = roots
        let edits = Edits()
        func hold(_ text: String) throws {
            library.lists[0].cues[0].commands.append(GuardedCommand(.edit(try XCTUnwrap(edits.edit(text)))))
        }
        try hold("edit stack 2 slot 3 preset 4")
        try hold("edit preset 3 layouts.*.boxes.0.grade 1")
        try hold("edit stack 1 insert slots 0 {\"channel\": 3, \"mute\": false, \"opacity\": 1, \"preset\": 4}")
        try hold("edit list 7 cue \(F.list7Cues[0].uuidString.lowercased()) insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 2}")
        try hold("edit macro 1 commands [{\"cmd\": \"macro.run\", \"macro\": 2}]")
        try hold("edit channel 9 create {\"defaultPreset\": 4}")
        let count = library.lists[0].cues[0].commands.count
        func held(_ back: Int) -> EditCommand? {
            if case .edit(let edit) = library.lists[0].cues[0].commands[count - back].command { return edit }
            return nil
        }
        XCTAssertTrue(References.to(.preset, 4, library: library, machine: machine).count >= 3, "the uses query finds them")
        XCTAssertTrue(References.to(.grade, 1, library: library, machine: machine).contains { if case .cue = $0.site { return $0.site.isPortable } else { return false } })

        XCTAssertEqual(Identity.renumber(.preset, from: 4, to: 9, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(held(6), EditCommand(.slot(stack: 2, channel: 3), .set(path: "preset", value: .number(9))))
        XCTAssertEqual(held(4)?.action, .insert(path: "slots", at: 0, value: .object(["channel": .number(3), "mute": .bool(false),
                                                                                        "opacity": .number(1), "preset": .number(9)])))
        XCTAssertEqual(held(1)?.action, .create(body: .object(["defaultPreset": .number(9)]), folder: nil, title: nil))

        XCTAssertEqual(Identity.renumber(.grade, from: 1, to: 8, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(held(5), EditCommand(.numbered(.preset, 3), .set(path: "layouts.*.boxes.0.grade", value: .number(8))))

        XCTAssertEqual(Identity.renumber(.macro, from: 2, to: 6, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(held(3)?.action, .insert(path: "commands", at: 0, value: .object(["cmd": .string("macro.run"), "macro": .number(6)])))
        XCTAssertEqual(held(2)?.action, .set(path: "commands", value: .array([.object(["cmd": .string("macro.run"), "macro": .number(6)])])))

        // A stack's number in a path is a layout's key, which meets its stack at every campus: it stays (Spec 5 §4).
        var (portable, local) = roots
        let layout = try XCTUnwrap(edits.edit("edit preset 3 unset layouts.2"))
        local.macros[0].commands.append(GuardedCommand(.edit(layout)))
        XCTAssertEqual(Identity.renumber(.stack, from: 2, to: 6, library: &portable, machine: &local), .renumbered)
        XCTAssertEqual(local.macros[0].commands.last?.command, .edit(layout))
    }

    /// Spec 1 §4 and Spec 5 §4 — the references a renumber rewrites are the
    /// ones `References` finds: afterwards what named the old number names
    /// the new, in both roots for a portable type and in the machine root
    /// alone for a machine-level one.
    func test_whatNamedTheOldNumberNamesTheNew() {
        let cases: [(NumberedType, Int)] = [(.channel, 2), (.preset, 2), (.textStyle, 1), (.grade, 1), (.transition, 2),
                                            (.audioTransition, 1), (.macro, 2), (.stack, 2), (.output, 2), (.audioOutput, 1)]
        for (type, from) in cases {
            var (library, machine) = roots
            let before = References.to(type, from, library: library, machine: machine)
            XCTAssertFalse(before.isEmpty, "\(type.displayName) \(from) is named in the fixture")
            XCTAssertEqual(Identity.renumber(type, from: from, to: 90, library: &library, machine: &machine), .renumbered, type.displayName)
            let moved = References.to(type, 90, library: library, machine: machine)
            let stayed = References.to(type, from, library: library, machine: machine)
            if type.isMachineLevel {
                XCTAssertEqual(moved.count, before.filter { !$0.site.isPortable }.count, "\(type.displayName): the machine root follows")
                XCTAssertEqual(stayed.count, before.filter(\.site.isPortable).count, "\(type.displayName): portable documents stay")
                XCTAssertTrue(stayed.allSatisfy(\.site.isPortable), type.displayName)
            } else {
                XCTAssertEqual(moved.count, before.count, type.displayName)
                XCTAssertTrue(stayed.isEmpty, "\(type.displayName): nothing names \(from) any more")
            }
        }
    }

    // MARK: - Media identity

    /// Spec 1 §4 — "Identical files anywhere under the root resolve to one identity."
    /// Spec 7 §2 — "Two different lists with the same number both load ...
    /// Anything that names the number alone ... gets the one that comes first";
    /// Spec 7 §3 — a link "still finds the list after a renumber or a swap".
    /// So a renumber moves that first list alone, rewrites the links that
    /// follow its uuid and the commands that name its number, and leaves the
    /// other list, and the links that follow it, where they are.
    func test_renumberingOneOfTwoListsSharingANumberMovesOnlyThatOne() throws {
        var (library, machine) = roots
        machine.settings.libraryMode = .writable
        let first = try XCTUnwrap(library.list(number: 42))
        var second = first
        second.uuid = F.uuid("5ec0", 42)
        second.title = "Great Is Thy Faithfulness (second)"
        library.lists.append(second)   // after the first: a number reaches the first
        let p = try XCTUnwrap(machine.playlists.firstIndex { $0.uuid == F.playlistUuid })
        machine.playlists[p].items.append(.linked(list: 42, listUuid: second.uuid, uuid: F.uuid("4d4d", 6)))
        machine.keys.append(KeyBinding(device: "keyboard", key: "f1", command: .listCue(list: 42, cue: 1)))

        XCTAssertEqual(Identity.renumber(.list, from: 42, to: 43, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.list(uuid: first.uuid)?.number, 43)
        XCTAssertEqual(library.list(uuid: second.uuid)?.number, 42)
        XCTAssertEqual(machine.playlists[p].items[1].kind, .linked(list: 43, listUuid: first.uuid))
        XCTAssertEqual(machine.playlists[p].items[5].kind, .linked(list: 42, listUuid: second.uuid))
        XCTAssertEqual(machine.keys.last?.command, .listCue(list: 43, cue: 1))

        // A swap exchanges the two lists' numbers, and the links follow their lists.
        XCTAssertEqual(Identity.swap(.list, 42, 43, library: &library, machine: &machine), .renumbered)
        XCTAssertEqual(library.list(uuid: first.uuid)?.number, 42)
        XCTAssertEqual(library.list(uuid: second.uuid)?.number, 43)
        XCTAssertEqual(machine.playlists[p].items[1].kind, .linked(list: 42, listUuid: first.uuid))
        XCTAssertEqual(machine.playlists[p].items[5].kind, .linked(list: 43, listUuid: second.uuid))
        XCTAssertEqual(machine.keys.last?.command, .listCue(list: 42, cue: 1))
    }

    func test_hashingTheSameBytesAtTwoPathsYieldsOneIndexEntry() throws {
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: F.mediaRoot.appendingPathComponent("backgrounds/cross.png").path))
        let again = try XCTUnwrap(FileManager.default.contents(atPath: F.machineMediaRoot.appendingPathComponent("cross-fast.png").path))
        XCTAssertEqual(MediaID.sha256(of: bytes), F.cross)
        XCTAssertEqual(MediaID.sha256(of: again), F.cross)

        var index = MediaIndex()
        let first = MediaEntry(id: MediaID.sha256(of: bytes), path: "backgrounds/cross.png", kind: .image, size: bytes.count)
        let second = MediaEntry(id: MediaID.sha256(of: again), path: "copies/cross-fast.png", kind: .image, size: again.count)
        XCTAssertTrue(index.add(first))
        XCTAssertFalse(index.add(second), "the same bytes are one identity")
        XCTAssertEqual(index.entries.count, 1)
        XCTAssertEqual(index.entry(F.cross)?.path, "backgrounds/cross.png")
    }
}
