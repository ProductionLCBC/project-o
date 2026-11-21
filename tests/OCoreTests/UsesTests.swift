import Foundation
import XCTest
@testable import OCore

/// Spec 11 §3 — "`uses` lists what refers to a numbered object, counted over
/// both roots' documents on this machine, as `mediaUse` counts media":
/// "`counts` covers everything, per kind; the entries stop at 500 in all,
/// with `more` true beyond", and each kind's entry carries what the spec
/// lists for it. On the fixture roots (Spec 1 §10), changed where a test
/// says so.
final class UsesTests: XCTestCase {
    typealias F = FixtureLibrary

    private func roots() -> (library: Library, machine: Machine) {
        let loaded = F.load()
        return (loaded.library, loaded.machine)
    }

    private func object(_ members: [String: JSONValue]) -> JSONValue { .object(members) }

    /// Spec 11 §3's own example, of a preset: a channel's default, a slot
    /// that names it, a stack's default and a slot that reaches it by fallback.
    func test_aPresetsUsesWithTheSlotsThatReachItByFallback() {
        var (library, machine) = roots()
        library.presets.append(Preset(number: 30, label: "Lower third", uuid: UUID(), layouts: [.any: Layout(boxes: [])]))
        library.channels[1].defaultPreset = 30                                     // channel 2
        machine.stacks[0].slots[1].preset = 30                                     // stack 1's slot for channel 2 names it
        machine.stacks[1].defaultPreset = 30                                       // stack 2's default
        machine.stacks[1].slots[0].preset = nil                                    // stack 2's slot for channel 2: by the stack's default
        machine.stacks[1].slots[1].preset = 2                                      // stack 2's slot for channel 3 names another
        machine.stacks.append(Stack(number: 3, slots: [StackSlot(channel: 2)], label: "Side"))   // by channel 2's default
        let uses = Uses.of(.preset, 30, library: library, machine: machine)
        XCTAssertEqual(uses.entries["channels"], [object(["channel": .number(2), "field": .string("defaultPreset")])])
        XCTAssertEqual(uses.entries["stacks"], [
            object(["stack": .number(1), "slot": .number(2)]),
            object(["stack": .number(2), "field": .string("defaultPreset")]),
            object(["stack": .number(2), "slot": .number(2), "fallback": .bool(true)]),
            object(["stack": .number(3), "slot": .number(2), "fallback": .bool(true)]),
        ])
        XCTAssertEqual(uses.counts["channels"], 1)
        XCTAssertEqual(uses.counts["stacks"], 4)
        XCTAssertFalse(uses.more)
        // Every kind has its count, used or not; only the used kinds have entries.
        XCTAssertEqual(Set(uses.counts.keys), Set(Uses.kinds))
        XCTAssertEqual(uses.counts["cues"], 0)
        XCTAssertEqual(Set(uses.entries.keys), ["channels", "stacks"])
        // The answer's fields, as the query sends them.
        XCTAssertEqual(uses.fields["more"], .bool(false))
        XCTAssertEqual(uses.fields["counts"]?.objectValue?["stacks"], .number(4))
        XCTAssertEqual(uses.fields["uses"]?.objectValue?["channels"], .array(uses.entries["channels"] ?? []))
    }

    /// A slot that names no preset draws its channel's default, and one that names a preset nothing has
    /// draws Preset 1 (Spec 6 §2).
    func test_aSlotReachesItsChannelsDefaultAndPresetOneWhenWhatItNamesIsGone() {
        var (library, machine) = roots()
        library.channels[0].defaultPreset = 1
        machine.stacks[0].defaultPreset = nil
        machine.stacks[0].slots[0].preset = nil      // stack 1's slot for channel 1: by channel 1's default, Preset 1
        machine.stacks[0].slots[1].preset = 77       // stack 1's slot for channel 2: a preset that doesn't exist
        let stacks = Uses.of(.preset, 1, library: library, machine: machine).entries["stacks"] ?? []
        XCTAssertTrue(stacks.contains(object(["stack": .number(1), "slot": .number(1), "fallback": .bool(true)])))
        XCTAssertTrue(stacks.contains(object(["stack": .number(1), "slot": .number(2), "fallback": .bool(true)])))
        let dangling = Uses.of(.preset, 77, library: library, machine: machine)
        XCTAssertEqual(dangling.entries["stacks"], [object(["stack": .number(1), "slot": .number(2)])], "a number nothing has is still answered for")
    }

    func test_aStacksUsesAreAPresetsLayoutAnOutputsDefaultAndTheThumbnailStack() {
        var (library, machine) = roots()
        machine.outputs[0].defaultStack = 2
        let uses = Uses.of(.stack, 2, library: library, machine: machine)
        let presets = uses.entries["presets"] ?? []
        XCTAssertTrue(presets.contains(object(["preset": .number(3), "layout": .number(2)])), "\(presets)")
        XCTAssertTrue(presets.contains(object(["preset": .number(1), "layout": .number(2)])))
        let defaulting = machine.outputs.filter { $0.defaultStack == 2 }.map(\.number)
        XCTAssertFalse(defaulting.isEmpty)
        XCTAssertEqual(uses.entries["outputs"], defaulting.map { object(["output": .number(Double($0)), "field": .string("defaultStack")]) })
        if machine.settings.thumbnailStack == 2 {
            XCTAssertEqual(uses.entries["machine"], [object(["field": .string("thumbnailStack")])])
        } else {
            XCTAssertEqual(Uses.of(.stack, machine.settings.thumbnailStack, library: library, machine: machine).entries["machine"],
                           [object(["field": .string("thumbnailStack")])])
        }
    }

    func test_aBoxEntryCarriesItsPresetLayoutPlaceAndField() {
        let (library, machine) = roots()
        XCTAssertTrue((Uses.of(.grade, 1, library: library, machine: machine).entries["boxes"] ?? [])
            .contains(object(["preset": .number(3), "layout": .string("*"), "box": .number(0), "field": .string("grade")])))
        XCTAssertTrue((Uses.of(.textStyle, 1, library: library, machine: machine).entries["boxes"] ?? [])
            .contains(object(["preset": .number(3), "layout": .number(2), "box": .number(0), "field": .string("textStyle.fromStyle")])))
        XCTAssertTrue((Uses.of(.transition, 2, library: library, machine: machine).entries["boxes"] ?? [])
            .contains(object(["preset": .number(3), "layout": .string("*"), "box": .number(0), "field": .string("transition.ref")])))
    }

    /// "a cue entry `listUuid` (or `local`), `list`, `cue`, its number and
    /// its label": one entry a cue, however many of its commands name the object.
    func test_aCueIsListedOnceWithItsListItsNumberAndItsLabel() throws {
        var (library, machine) = roots()
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        let write = Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "again"])))
        library.lists[index].cues[0].commands.append(GuardedCommand(write))
        let list = library.lists[index]
        let cue = list.cues[0]
        let writes = cue.commands.filter { if case .channelWrite(let w) = $0.command, w.channel == .number(2) { return true } else { return false } }
        XCTAssertGreaterThanOrEqual(writes.count, 2, "two commands of the cue write channel 2")
        let uses = Uses.of(.channel, 2, library: library, machine: machine)
        let entry = object(["listUuid": .string(list.uuid.uuidString.lowercased()), "list": .number(42), "cue": .string(cue.uuid.uuidString.lowercased()),
                            "number": .number(1), "label": .string(cue.label)])
        XCTAssertEqual((uses.entries["cues"] ?? []).filter { $0 == entry }.count, 1)
        // A local copy's cue names its list as `local`.
        let local = try XCTUnwrap(machine.localLists.first { copy in copy.cues.contains { cue in
            cue.commands.contains { if case .channelWrite(let w) = $0.command, w.channel == .number(2) { return true } else { return false } } } })
        let localEntries = (uses.entries["cues"] ?? []).filter { $0.objectValue?["local"] == .string(local.uuid.uuidString.lowercased()) }
        XCTAssertFalse(localEntries.isEmpty)
        XCTAssertNil(localEntries.first?.objectValue?["listUuid"])
        XCTAssertEqual(uses.counts["cues"], uses.entries["cues"]?.count)
    }

    func test_macrosKeysMediaOutputsAndAudioOutputs() throws {
        var (library, machine) = roots()
        // A macro's command, by its place.
        let macro = try XCTUnwrap(library.macros.first)
        library.macros[0].commands = [GuardedCommand(.channelClear(channel: .number(1))), GuardedCommand(.channelClear(channel: .number(3)))]
        // A key binding and a scheduler entry.
        machine.keys = [KeyBinding(device: "keyboard", key: "F5", command: .channelClear(channel: .number(3))),
                        KeyBinding(device: "scheduler", key: nil, command: .channelClear(channel: .number(3)))]
        // A media item's default channel, and the machine's drop channel.
        let item = try XCTUnwrap(library.mediaIndex.entries.first)
        library.mediaIndex.entries[0].defaults.defaultChannel = 3
        machine.settings.dropChannels = DropChannels(video: 3, image: nil, audio: nil)
        let uses = Uses.of(.channel, 3, library: library, machine: machine)
        XCTAssertEqual(uses.entries["macros"], [object(["macro": .number(Double(macro.number)), "command": .number(1)])])
        XCTAssertEqual(uses.entries["keys"], [object(["device": .string("keyboard"), "key": .string("F5")]),
                                              object(["device": .string("scheduler"), "at": .number(1)])])
        XCTAssertEqual(uses.entries["media"], [object(["media": .string(item.id), "field": .string("defaults.defaultChannel")])])
        XCTAssertEqual(uses.entries["machine"], [object(["field": .string("dropChannels.video")])])
        // An output's transitions, and the audio output a channel routes to.
        machine.outputs[0].transitions = OutputTransitions(switch: 2, blackout: 2)
        XCTAssertEqual(Uses.of(.transition, 2, library: library, machine: machine).entries["outputs"]?.prefix(2).map { $0 },
                       [object(["output": .number(Double(machine.outputs[0].number)), "field": .string("transitions.switch")]),
                        object(["output": .number(Double(machine.outputs[0].number)), "field": .string("transitions.blackout")])])
        library.channels[2].audioOutputs = [1]
        XCTAssertTrue((Uses.of(.audioOutput, 1, library: library, machine: machine).entries["channels"] ?? [])
            .contains(object(["channel": .number(3), "field": .string("audioOutputs")])))
    }

    /// "the entries stop at 500 in all, with `more` true beyond", in the order of the kinds.
    func test_theEntriesStopAtTheLimitAndTheCountsCoverEverything() {
        let (library, machine) = roots()
        let all = Uses.of(.channel, 2, library: library, machine: machine)
        let total = all.counts.values.reduce(0, +)
        XCTAssertGreaterThan(total, 3)
        XCTAssertEqual(all.entries.values.map(\.count).reduce(0, +), total)
        let cut = Uses.of(.channel, 2, library: library, machine: machine, limit: 3)
        XCTAssertEqual(cut.counts, all.counts)
        XCTAssertEqual(cut.entries.values.map(\.count).reduce(0, +), 3)
        XCTAssertTrue(cut.more)
        // The first kinds fill first.
        var expected: [JSONValue] = []
        for kind in Uses.kinds { expected += all.entries[kind] ?? [] }
        var got: [JSONValue] = []
        for kind in Uses.kinds { got += cut.entries[kind] ?? [] }
        XCTAssertEqual(got, Array(expected.prefix(3)))
        XCTAssertEqual(Uses.limit, 500)
    }

    func test_theObjectsTheQueryNames() {
        XCTAssertEqual(Uses.objects.keys.sorted(), ["audiooutput", "audiotransition", "channel", "grade", "macro", "output", "preset", "stack", "textstyle", "transition"])
        XCTAssertEqual(Uses.objects["textstyle"], .textStyle)
        XCTAssertNil(Uses.objects["list"], "lists keep `listUse`")
    }
}
