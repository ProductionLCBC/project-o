import Foundation
import XCTest
@testable import OCore

/// Spec 11 §13 — "Each edit of a ... stack ..., and of an output's default
/// stack and transitions, applies with its inverse and its checks (Spec 5
/// §6); renumbering ... a stack an output shows, is `onAir`, and so is a swap
/// when either object is". Spec 11 §6 is the editor these edits serve.
final class EditStackTests: XCTestCase {
    typealias F = FixtureLibrary

    private func slotJSON(_ channel: Int, preset: Int? = nil, opacity: Double = 1) -> String {
        "{\"channel\": \(channel), \"mute\": false, \"opacity\": \(opacity), \"preset\": \(preset.map(String.init) ?? "null")}"
    }

    // MARK: - Slots (Spec 5 §3: "a slot, named by its channel")

    func test_aSlotsPresetOpacityAndMuteOnAReadOnlyMastersMachine() {
        // Spec 11 §6 — "Stacks and outputs are machine-level, so the page stays editable on a `readOnlyMasters` machine".
        var edits = Edits(writable: false)
        let slot = EditAddress.slot(stack: 1, channel: 2)
        let preset = edits.apply("edit stack 1 slot 2 preset 3")
        XCTAssertEqual(edits.machine.stack(1)?.slots[1].preset, 3)
        XCTAssertEqual(preset.first?.logged, EditCommand(slot, .set(path: "preset", value: .number(3))))
        XCTAssertEqual(preset.first?.inverse, EditCommand(slot, .set(path: "preset", value: .null)))
        XCTAssertEqual(preset.first?.changes, [Edits.changed(.stack, 1, ["slots.1.preset"])])

        XCTAssertEqual(edits.apply("edit stack 1 slot 2 opacity 0.8").first?.inverse, EditCommand(slot, .set(path: "opacity", value: .number(1))))
        XCTAssertEqual(edits.machine.stack(1)?.slots[1].opacity, 0.8)
        // "None, which means the stack's default, else the channel's, else Preset 1".
        edits.apply("edit stack 1 slot 2 preset null")
        XCTAssertNil(edits.machine.stack(1)?.slots[1].preset)
        // Spec 11 §6 — "the slot's stored `mute` stays as it was written": the engine still takes the edit.
        edits.apply("edit stack 1 slot 2 mute true")
        XCTAssertEqual(edits.machine.stack(1)?.slots[1].mute, true)
        XCTAssertEqual(edits.apply("edit stack 1 slot 2 mute true").first?.isNoop, true)

        XCTAssertEqual(edits.refuse("edit stack 1 slot 2 opacity 1.5")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 2 preset 99")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 2 channel 3")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 2 colour \"red\"")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 3 opacity 0.5")?.reason, .unknownObject, "stack 1 doesn't hold channel 3")
        XCTAssertEqual(edits.refuse("edit stack 9 slot 1 opacity 0.5")?.reason, .unknownObject)
    }

    /// Spec 11 §6 — "Rows drag to a new place (`edit stack S slot C move
    /// K`) ... A row's menu has Remove from Stack (`edit stack S slot C remove`)."
    func test_aSlotMovesAndComesOut() throws {
        var edits = Edits()
        let moved = edits.apply("edit stack 1 slot 1 move 1")
        XCTAssertEqual(edits.machine.stack(1)?.slots.map(\.channel), [2, 1])
        XCTAssertEqual(moved.first?.inverse, EditCommand(.slot(stack: 1, channel: 1), .move(path: nil, from: nil, at: 0)))
        XCTAssertEqual(moved.first?.changes, [Edits.changed(.stack, 1, ["slots"])])
        XCTAssertEqual(edits.apply("edit stack 1 slot 1 move 1").first?.isNoop, true)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 1 move 2")?.reason, .badValue)

        let slot = try XCTUnwrap(edits.machine.stack(1)?.slots[0])
        let removed = edits.apply("edit stack 1 slot 2 remove")
        XCTAssertEqual(edits.machine.stack(1)?.slots.map(\.channel), [1])
        XCTAssertEqual(removed.first?.inverse,
                       EditCommand(.numbered(.stack, 1), .insert(path: "slots", at: 0, value: try JSONCoding.encode(slot))),
                       "\"`edit.insert` of the removed value at its old position\"")
        XCTAssertEqual(edits.refuse("edit stack 1 slot 2 remove")?.reason, .unknownObject)
        XCTAssertEqual(edits.refuse("edit stack 1 slot 1 delete")?.reason, .badValue)
        assertRoundTrip(["edit stack 1 slot 1 move 1", "edit stack 1 slot 2 opacity 0.4", "edit stack 1 slot 2 remove"], writable: false)
    }

    /// Spec 11 §6 — "A channel dragged in from the right column adds a slot
    /// where it lands (`edit stack S insert slots K {...}`); a channel the
    /// stack already holds is refused ..., since a channel appears once per
    /// stack (P13)."
    func test_aChannelGoesIntoAStackOnce() {
        var edits = Edits()
        let added = edits.apply("edit stack 1 insert slots 2 \(slotJSON(3))")
        XCTAssertEqual(edits.machine.stack(1)?.slots.map(\.channel), [1, 2, 3])
        XCTAssertEqual(added.first?.inverse, EditCommand(.numbered(.stack, 1), .remove(path: "slots", at: 2)))
        XCTAssertEqual(edits.refuse("edit stack 1 insert slots 0 \(slotJSON(3))")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit stack 1 insert slots 0 \(slotJSON(9))")?.reason, .unknownReference, "no channel 9")
        XCTAssertEqual(edits.refuse("edit stack 2 insert slots 0 \(slotJSON(1, preset: 99))")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit stack 2 insert slots 0 \(slotJSON(1, opacity: 2))")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit stack 2 insert slots 0 {\"preset\": null}")?.reason, .badValue, "a slot needs its channel")
        XCTAssertEqual(edits.refuse("edit stack 2 insert slots 5 \(slotJSON(1))")?.reason, .badValue)
        assertRoundTrip(["edit stack 2 insert slots 0 \(slotJSON(1, preset: 3, opacity: 0.5))"])
    }

    /// Spec 6 §2 — "A later slot stays in the document as read": a stack that
    /// came with a channel twice still takes other edits, and no edit adds a third.
    func test_aStackThatCameWithAChannelTwiceIsStillEdited() {
        var edits = Edits()
        edits.machine.stacks[0].slots.append(StackSlot(channel: 2))
        edits.apply("edit stack 1 insert slots 0 \(slotJSON(3))")
        XCTAssertEqual(edits.refuse("edit stack 1 insert slots 0 \(slotJSON(2))")?.reason, .duplicate)
        edits.apply("edit stack 1 slot 2 opacity 0.5")
        XCTAssertEqual(edits.machine.stack(1)?.slots.filter { $0.channel == 2 }.map(\.opacity), [0.5, 1], "an edit by channel reaches the first")
    }

    // MARK: - The stack's own fields (Spec 11 §6)

    func test_labelBaseDefaultPresetAndGammaBlend() {
        var edits = Edits(writable: false)
        func set(_ path: String, _ value: JSONValue) -> EditCommand { EditCommand(.numbered(.stack, 2), .set(path: path, value: value)) }
        XCTAssertEqual(edits.apply("edit stack 2 label \"Stage\"").first?.inverse, set("label", .string("Confidence")))
        XCTAssertEqual(edits.apply("edit stack 2 base transparent").first?.inverse, set("base", .string("black")))
        XCTAssertEqual(edits.apply("edit stack 2 gammaBlend true").first?.inverse, set("gammaBlend", .bool(false)))
        XCTAssertEqual(edits.machine.stack(2)?.base, .transparent)
        XCTAssertEqual(edits.machine.stack(2)?.gammaBlend, true)

        // Spec 5 §6 — the result warns of "a preset used as a stack default without a pixel box or a body box at offset 0".
        let clock = edits.apply("edit stack 2 defaultPreset 2")
        XCTAssertEqual(clock.first?.inverse, set("defaultPreset", .null))
        XCTAssertEqual(clock.first?.warnings, ["preset 2 is stack 2's default and has no pixel box and no body box at offset 0"])
        // Preset 1's layout for stack 2 has body boxes and no pixel box; on stack 1 its * layout has both.
        XCTAssertEqual(edits.apply("edit stack 2 defaultPreset 1").first?.warnings, ["preset 1 is stack 2's default and has no pixel box at offset 0"])
        XCTAssertEqual(edits.apply("edit stack 1 defaultPreset 1").first?.warnings, [])
        XCTAssertEqual(edits.apply("edit stack 2 defaultPreset null").first?.warnings, [])

        XCTAssertEqual(edits.refuse("edit stack 2 defaultPreset 99")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit stack 2 base white")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit stack 2 gammaBlend 1")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit stack 2 number 4")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit stack 2 offset 1")?.reason, .unknownPath)
    }

    // MARK: - Its menu (Spec 11 §6)

    func test_createAndDuplicate() throws {
        var edits = Edits(writable: false)
        let made = edits.apply("edit stack create")
        XCTAssertEqual(edits.machine.stack(3), Stack(number: 3, slots: [], label: "", uuid: Edits.pick(1)))
        XCTAssertEqual(made.first?.inverse, EditCommand(.numbered(.stack, 3), .delete))
        let copied = edits.apply("edit stack 2 duplicate")
        var expected = try XCTUnwrap(edits.machine.stack(2))
        expected.number = 4
        expected.uuid = Edits.pick(2)
        XCTAssertEqual(edits.machine.stack(4), expected)
        XCTAssertEqual(copied.first?.logged, EditCommand(.numbered(.stack, 2), .duplicate(to: 4, title: nil, picks: EditPicks(uuid: Edits.pick(2)))))
        edits.apply("edit stack 7 create {\"label\": \"Side\", \"slots\": [\(slotJSON(1)), \(slotJSON(2))]}")
        XCTAssertEqual(edits.machine.stack(7)?.slots.map(\.channel), [1, 2])
        XCTAssertEqual(edits.refuse("edit stack 8 create {\"slots\": [\(slotJSON(1)), \(slotJSON(1))]}")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit stack 8 create {\"slots\": [\(slotJSON(9))]}")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit stack 7 create")?.reason, .duplicate)
        assertRoundTrip(["edit stack create", "edit stack 2 duplicate 9", "edit stack 9 label \"Copy\""], writable: false)
    }

    /// Spec 5 §4 — "Renumbering a machine-level object therefore rewrites
    /// references in the machine root only. It leaves portable documents
    /// alone and returns a warning listing the portable references that now
    /// name something else on this machine."
    func test_renumberRewritesTheMachineRootAndWarnsOfPortableReferences() throws {
        var edits = Edits(writable: false)
        let portable = edits.library
        let renumbered = edits.apply("edit stack 2 renumber 6")
        XCTAssertNotNil(edits.machine.stack(6))
        XCTAssertEqual(edits.machine.macro(2)?.commands[3].command, .stackMute(stack: 6, channel: 2, state: .off))
        XCTAssertEqual(edits.library, portable, "the library is as it was")
        XCTAssertEqual(renumbered.first?.inverse, EditCommand(.numbered(.stack, 6), .renumber(to: 2)))
        let warning = try XCTUnwrap(renumbered.first?.warnings.first)
        XCTAssertEqual(renumbered.first?.warnings.count, 1)
        XCTAssertTrue(warning.hasPrefix("2 references in the library still name stack 2"), warning)
        XCTAssertTrue(warning.contains("preset 1's layout for stack 2") && warning.contains("preset 3's layout for stack 2"), warning)
        let changed = renumbered.first?.changes ?? []
        XCTAssertEqual(changed.first, Edits.changed(.stack, 6))
        XCTAssertTrue(changed.contains(Edits.changed(.macro, 2, ["commands"])))
        XCTAssertFalse(changed.contains { $0.object == "preset" })

        // Renumbering onto a number the library's layouts name is how a machine meets them: they aren't broken references.
        edits.apply("edit stack 6 renumber 2")
        // A machine-root reference to a stack that isn't there is one.
        edits.machine.outputs[1].defaultStack = 5
        XCTAssertEqual(edits.refuse("edit stack 2 renumber 5")?.reason, .danglingReferences)
        XCTAssertEqual(edits.refuse("edit stack 2 renumber 1")?.reason, .duplicate)
        assertRoundTrip(["edit stack 2 renumber 6", "edit stack 6 swap 1"], writable: false)
    }

    func test_deleteWarnsOfWhatStillNamesIt() throws {
        var edits = Edits()
        let stack = try XCTUnwrap(edits.machine.stack(2))
        let deleted = edits.apply("edit stack 2 delete")
        XCTAssertNil(edits.machine.stack(2))
        XCTAssertEqual(deleted.first?.inverse, EditCommand(.numbered(.stack, 2), .create(body: try JSONCoding.encode(stack), folder: nil, title: nil)))
        XCTAssertTrue(deleted.first?.warnings.first?.hasPrefix("stack 2 is still named by 3 references") == true, deleted.first?.warnings.first ?? "")
        assertRoundTrip(["edit stack 2 delete"])
    }

    // MARK: - On air (Spec 5 §6, check 7; Spec 11 §6)

    /// "Renumber…, ... refused while an output shows the stack, and Swap
    /// while an output shows either stack (`onAir` ...); and Delete, refused
    /// while an output shows the stack (E-7)".
    func test_aStackAnOutputShowsIsOnAir() {
        var edits = Edits()
        edits.play()   // a fresh state: both outputs on their default stack, stack 1
        XCTAssertEqual(edits.refuse("edit stack 1 delete")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit stack 1 renumber 9")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit stack 1 swap 2")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit stack 2 swap 1")?.reason, .onAir, "a swap checks both objects")
        // Its slots and fields are still edited: that is the stack editor's live render (Spec 5 §2).
        edits.apply("edit stack 1 slot 2 opacity 0.5")
        edits.apply("edit stack 1 label \"Wall\"")
        // Stack 2 is on no output.
        edits.apply("edit stack 2 renumber 6")
        // ShowState holds a stack by its number: the engine gives stack 6 its entry between ticks (Spec 5 §2).
        edits.context.state = nil
        edits.play("output 2 stack 6")
        XCTAssertEqual(edits.refuse("edit stack 6 delete")?.reason, .onAir)
        edits.play("output 2 stack 1")
        edits.apply("edit stack 6 delete")
    }

    // MARK: - An output (Spec 11 §6: "Editable here: its default stack ... and its switch and blackout transitions")

    func test_anOutputsDefaultStackAndTransitions() {
        var edits = Edits(writable: false)
        func set(_ output: Int, _ path: String, _ value: Double) -> EditCommand {
            EditCommand(.numbered(.output, output), .set(path: path, value: .number(value)))
        }
        let stack = edits.apply("edit output 2 defaultStack 2")
        XCTAssertEqual(edits.machine.output(2)?.defaultStack, 2)
        XCTAssertEqual(stack.first?.inverse, set(2, "defaultStack", 1))
        XCTAssertEqual(stack.first?.changes, [Edits.changed(.output, 2, ["defaultStack"])])
        XCTAssertEqual(edits.apply("edit output 1 transitions.switch 1").first?.inverse, set(1, "transitions.switch", 2))
        XCTAssertEqual(edits.apply("edit output 1 transitions.blackout 2").first?.inverse, set(1, "transitions.blackout", 3))
        XCTAssertEqual(edits.machine.output(1)?.transitions, OutputTransitions(switch: 1, blackout: 2))
        XCTAssertEqual(edits.apply("edit output 1 transitions.blackout 2").first?.isNoop, true)

        XCTAssertEqual(edits.refuse("edit output 1 defaultStack 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit output 1 transitions.switch 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit output 1 defaultStack null")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit output 1 transitions.fade 2")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit output 1 uuid \"x\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit output 9 defaultStack 1")?.reason, .unknownObject)
        assertRoundTrip(["edit output 2 defaultStack 2", "edit output 1 transitions.switch 3"], writable: false)
    }

    /// Spec 10 §16 as Spec 11 corrected it — "the edits of outputs (apart
    /// from their default stack and transitions, which are Area 14's ...)"
    /// are Area 17's.
    func test_theRestOfAnOutputWaitsForArea17() {
        var edits = Edits()
        for text in ["edit output 1 label \"Wall\"", "edit output 1 colorRange limited", "edit output 1 format.width 3840",
                     "edit output 1 keyFillPartner 2", "edit output 1 delete", "edit output create", "edit output 1 renumber 3",
                     "edit output 1 swap 2", "edit output 1 duplicate"] {
            let rejection = edits.refuse(text)
            XCTAssertEqual(rejection?.reason, .notInV1, text)
            XCTAssertTrue(rejection?.message.contains("Area 17") == true, "\(text): \(rejection?.message ?? "")")
        }
    }
}
