import Foundation
import XCTest
@testable import OCore

/// Spec 11 §3 — "**References:** a channel's default preset, transitions and
/// audio outputs; a stack's default preset and its slots' channels and
/// presets; ... a preset's layout for a stack; an output's default stack,
/// transitions and key-fill partner, and the audio outputs that embed into an
/// output; a box's style (`fromStyle`), transition and grade; a media item's
/// default grade and channel; the commands, riders, guards and held edits of
/// cues and macros, and the commands of key bindings and scheduler entries;
/// the machine settings' startup and shutdown macros, thumbnail stack and
/// drop channels." Each is found in the fixture roots, with where it is.
final class ReferencesTests: XCTestCase {
    typealias F = FixtureLibrary

    private var roots: (library: Library, machine: Machine) {
        let loaded = F.load()
        return (loaded.library, loaded.machine)
    }

    private func sites(_ type: NumberedType, _ number: Int, in roots: (library: Library, machine: Machine)) -> [Reference.Site] {
        References.to(type, number, library: roots.library, machine: roots.machine).map(\.site)
    }

    private func assert(_ type: NumberedType, _ number: Int, at site: Reference.Site, _ why: String = "",
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(sites(type, number, in: roots).contains(site), "\(type.displayName) \(number) at \(site) \(why)", file: file, line: line)
    }

    // MARK: - Objects' own fields

    func test_aChannelsDefaultPresetTransitionsAndAudioOutputs() {
        assert(.preset, 1, at: .channel(1, field: "defaultPreset"))
        assert(.preset, 2, at: .channel(3, field: "defaultPreset"), "the clock channel")
        assert(.transition, 1, at: .channel(2, field: "defaults.transition"))
        assert(.audioTransition, 1, at: .channel(2, field: "defaults.audioTransition"))
        assert(.audioOutput, 1, at: .channel(3, field: "audioOutputs"))
    }

    func test_aStacksDefaultPresetAndItsSlotsChannelsAndPresets() {
        let library = roots.library
        var machine = roots.machine
        machine.stacks[1].defaultPreset = 4
        machine.stacks[0].slots[1].preset = 3
        let found = References.all(library: library, machine: machine)
        XCTAssertTrue(found.contains(Reference(.preset, 4, at: .stack(2, field: "defaultPreset"))))
        XCTAssertTrue(found.contains(Reference(.preset, 3, at: .slot(stack: 1, channel: 2, field: "preset"))))
        XCTAssertTrue(found.contains(Reference(.channel, 1, at: .slot(stack: 1, channel: 1, field: "channel"))))
        XCTAssertTrue(found.contains(Reference(.channel, 3, at: .slot(stack: 2, channel: 3, field: "channel"))))
        XCTAssertFalse(found.contains { $0.site == .slot(stack: 1, channel: 1, field: "preset") }, "a slot with no preset names none")
    }

    func test_aPresetsLayoutForAStackAndABoxsStyleTransitionAndGrade() {
        assert(.stack, 2, at: .layout(preset: 3, layout: .stack(2)))
        assert(.stack, 2, at: .layout(preset: 1, layout: .stack(2)), "Preset 1's confidence layout")
        assert(.grade, 1, at: .box(preset: 3, layout: .any, box: 0, field: "grade"))
        assert(.textStyle, 2, at: .box(preset: 3, layout: .any, box: 0, field: "textStyle.fromStyle"))
        assert(.transition, 2, at: .box(preset: 3, layout: .any, box: 0, field: "transition.ref"))
        assert(.textStyle, 1, at: .box(preset: 3, layout: .stack(2), box: 0, field: "textStyle.fromStyle"))
        XCTAssertFalse(sites(.stack, 1, in: roots).contains { if case .layout = $0 { return true } else { return false } },
                       "the * layout names no stack")
    }

    func test_anOutputsDefaultStackTransitionsAndPartnerAndTheAudioOutputsThatEmbedIntoIt() {
        assert(.stack, 1, at: .output(1, field: "defaultStack"))
        assert(.stack, 1, at: .output(2, field: "defaultStack"))
        assert(.transition, 2, at: .output(1, field: "transitions.switch"))
        assert(.transition, 3, at: .output(1, field: "transitions.blackout"))
        assert(.output, 2, at: .audioOutput(2, field: "device"), "the SDI embedded audio output")
        var (library, machine) = roots
        machine.outputs[0].keyFillPartner = 2
        XCTAssertTrue(References.to(.output, 2, library: library, machine: machine).contains(Reference(.output, 2, at: .output(1, field: "keyFillPartner"))))
        library.channels.removeAll()
        XCTAssertFalse(References.all(library: library, machine: machine).contains { if case .channel = $0.site { return true } else { return false } },
                       "a channel that is gone names nothing")
    }

    func test_aMediaItemsDefaultGradeAndChannelInBothIndexes() throws {
        assert(.grade, 1, at: .media(F.mountains, machineIndex: false, field: "defaults.grade"))
        assert(.channel, 1, at: .media(F.dawn, machineIndex: false, field: "defaults.defaultChannel"))
        assert(.channel, 2, at: .media(F.welcomeSlide, machineIndex: false, field: "defaults.defaultChannel"))
        var (library, machine) = roots
        let id = try XCTUnwrap(machine.mediaLocal.entries.first?.id, "the fixture has machine-only media")
        machine.mediaLocal.entries[0].defaults.grade = 1
        XCTAssertTrue(References.to(.grade, 1, library: library, machine: machine)
            .contains(Reference(.grade, 1, at: .media(id, machineIndex: true, field: "defaults.grade"))))
        library.grades.removeAll()
        XCTAssertFalse(References.to(.grade, 1, library: library, machine: machine).isEmpty, "a reference is found whether or not its object is there")
    }

    func test_theMachineSettingsMacrosThumbnailStackAndDropChannels() {
        assert(.macro, 2, at: .machine(field: "startupMacro"))
        assert(.stack, 1, at: .machine(field: "thumbnailStack"))
        assert(.channel, 1, at: .machine(field: "dropChannels.video"))
        assert(.channel, 1, at: .machine(field: "dropChannels.image"))
        let library = roots.library
        var machine = roots.machine
        machine.settings.shutdownMacro = 1
        machine.settings.dropChannels?.audio = 3
        let found = References.all(library: library, machine: machine)
        XCTAssertTrue(found.contains(Reference(.macro, 1, at: .machine(field: "shutdownMacro"))))
        XCTAssertTrue(found.contains(Reference(.channel, 3, at: .machine(field: "dropChannels.audio"))))
    }

    // MARK: - Commands

    func test_theCommandsRidersAndGuardsOfCuesAndMacros() throws {
        let list = try XCTUnwrap(roots.library.list(number: 42))
        func cue(_ index: Int, command: Int) -> Reference.Site {
            .cue(Reference.CuePlace(listUuid: list.uuid, list: 42, local: false, cue: list.cues[index].uuid, number: index + 1,
                                    label: list.cues[index].label), command: command)
        }
        assert(.channel, 1, at: cue(0, command: 0), "a write's channel")
        assert(.transition, 2, at: cue(0, command: 0), "its transition rider")
        assert(.audioTransition, 2, at: cue(3, command: 0), "an audio transition rider")
        assert(.grade, 1, at: cue(3, command: 0), "a grade rider")
        assert(.channel, 1, at: cue(3, command: 1), "a gain command's channel")

        // A local copy's cues are found as its own, in the machine root.
        let local = try XCTUnwrap(roots.machine.localLists.first)
        let place = Reference.CuePlace(listUuid: local.uuid, list: local.number, local: true, cue: local.cues[0].uuid, number: 1,
                                       label: local.cues[0].label)
        assert(.channel, 1, at: .cue(place, command: 0))

        // Macros of both roots, the guard beside its command.
        assert(.channel, 2, at: .macro(1, machineLevel: false, command: 0), "the write and its guard, [Channel 2 Content]")
        XCTAssertEqual(sites(.channel, 2, in: roots).filter { $0 == .macro(1, machineLevel: false, command: 0) }.count, 2,
                       "the command's own reference and its guard's")
        assert(.output, 1, at: .macro(2, machineLevel: true, command: 1))
        assert(.stack, 1, at: .macro(2, machineLevel: true, command: 1))
        assert(.stack, 2, at: .macro(2, machineLevel: true, command: 3))
        assert(.channel, 2, at: .macro(2, machineLevel: true, command: 3))
        assert(.output, 1, at: .macro(2, machineLevel: true, command: 5), "a guard, [Output 1 Stack]")
    }

    func test_theCommandsOfKeyBindingsAndSchedulerEntries() {
        assert(.stack, 1, at: .key(device: "streamdeck:AL12K3", key: "button 1", at: 4))
        assert(.macro, 2, at: .key(device: "scheduler", key: nil, at: 5), "a scheduler entry has no key")
    }

    func test_anEditACueHoldsNamesWhatItsAddressNames() throws {
        var library = roots.library
        let machine = roots.machine
        let held = try XCTUnwrap(Edits().edit("edit stack 2 slot 3 remove"))
        library.lists[0].cues[0].commands.append(GuardedCommand(.edit(held)))
        let list = library.lists[0]
        let place = Reference.CuePlace(listUuid: list.uuid, list: list.number, local: false, cue: list.cues[0].uuid, number: 1,
                                       label: list.cues[0].label)
        let at = Reference.Site.cue(place, command: list.cues[0].commands.count - 1)
        let found = References.all(library: library, machine: machine)
        XCTAssertTrue(found.contains(Reference(.stack, 2, at: at)))
        XCTAssertTrue(found.contains(Reference(.channel, 3, at: at)))
    }

    // MARK: - Where a reference lives

    func test_aSiteKnowsWhetherItIsInAPortableDocument() throws {
        let list = try XCTUnwrap(roots.library.list(number: 42))
        let master = Reference.CuePlace(listUuid: list.uuid, list: 42, local: false, cue: list.cues[0].uuid, number: 1, label: "")
        var local = master
        local.local = true
        let portable: [Reference.Site] = [
            .channel(1, field: "audioOutputs"), .layout(preset: 3, layout: .stack(2)), .box(preset: 3, layout: .any, box: 0, field: "grade"),
            .cue(master, command: 0), .macro(1, machineLevel: false, command: 0), .media(F.dawn, machineIndex: false, field: "defaults.grade"),
        ]
        let machine: [Reference.Site] = [
            .stack(1, field: "defaultPreset"), .slot(stack: 1, channel: 1, field: "channel"), .output(1, field: "defaultStack"),
            .audioOutput(2, field: "device"), .cue(local, command: 0), .macro(2, machineLevel: true, command: 0),
            .key(device: "keyboard", key: "space", at: 0), .media(F.dawn, machineIndex: true, field: "defaults.grade"),
            .machine(field: "thumbnailStack"),
        ]
        for site in portable { XCTAssertTrue(site.isPortable, "\(site)") }
        for site in machine { XCTAssertFalse(site.isPortable, "\(site)") }
    }

    func test_numbersNamedGivesEveryNumberOfATypeThatAnythingNames() {
        let (library, machine) = roots
        XCTAssertEqual(References.numbers(of: .stack, library: library, machine: machine), [1, 2])
        XCTAssertEqual(References.numbers(of: .macro, library: library, machine: machine), [1, 2],
                       "macro 1 from list 7's cue, macro 2 from the startup setting and the scheduler")
        XCTAssertEqual(References.numbers(of: .audioOutput, library: library, machine: machine), [1])
        XCTAssertTrue(References.numbers(of: .input, library: library, machine: machine).isEmpty)
    }
}
