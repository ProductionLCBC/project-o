import Foundation
import XCTest
@testable import OCore

/// Spec 11 §13 — "Each edit of a channel ... applies with its inverse and
/// its checks (Spec 5 §6); renumbering a channel with content on air ... is
/// `onAir`, and so is a swap when either object is". Spec 11 §7 is the sheet
/// these edits serve.
final class EditChannelTests: XCTestCase {
    typealias F = FixtureLibrary

    private func set(_ path: String, _ value: JSONValue, on channel: Int = 2) -> EditCommand {
        EditCommand(.numbered(.channel, channel), .set(path: path, value: value))
    }

    // MARK: - Fields (Spec 11 §7: "Each field is an `edit.set` on commit, apart from the number")

    func test_eachFieldSetsWithItsInverseAndNamesWhatChanged() {
        var edits = Edits()
        let label = edits.apply("edit channel 2 label \"Lyrics\"")
        XCTAssertEqual(edits.library.channel(2)?.label, "Lyrics")
        XCTAssertEqual(label.first?.logged, set("label", .string("Lyrics")))
        XCTAssertEqual(label.first?.inverse, set("label", .string("Foreground")))
        XCTAssertEqual(label.first?.changes, [Edits.changed(.channel, 2, ["label"])])

        XCTAssertEqual(edits.apply("edit channel 2 defaultPreset 3").first?.inverse, set("defaultPreset", .number(1)))
        XCTAssertEqual(edits.library.channel(2)?.defaultPreset, 3)
        XCTAssertEqual(edits.apply("edit channel 2 defaults.transition 2").first?.inverse, set("defaults.transition", .number(1)))
        XCTAssertEqual(edits.apply("edit channel 2 defaults.audioTransition 3").first?.inverse, set("defaults.audioTransition", .number(1)))
        XCTAssertEqual(edits.apply("edit channel 2 defaults.gain -6").first?.inverse, set("defaults.gain", .number(0)))
        XCTAssertEqual(edits.library.channel(2)?.defaults, ChannelDefaults(transition: 2, audioTransition: 3, gain: -6))
        XCTAssertEqual(edits.apply("edit channel 2 decoderCap 3").first?.inverse, set("decoderCap", .number(2)))
        XCTAssertEqual(edits.apply("edit channel 2 textThumbnail firstLine").first?.inverse, set("textThumbnail", .string("body")))
        XCTAssertEqual(edits.apply("edit channel 2 usualContent any").first?.inverse, set("usualContent", .string("text")))
        XCTAssertEqual(edits.library.channel(2)?.decoderCap, 3)
        XCTAssertEqual(edits.library.channel(2)?.textThumbnail, .firstLine)
        XCTAssertEqual(edits.library.channel(2)?.usualContent, .any)

        // Render size: "largest, or a width and height".
        let size = JSONValue.object(["height": .number(1080), "width": .number(1920)])
        XCTAssertEqual(edits.apply("edit channel 2 renderSize largest").first?.inverse, set("renderSize", size))
        XCTAssertEqual(edits.library.channel(2)?.renderSize, .largest)
        edits.apply("edit channel 2 renderSize {\"height\": 720, \"width\": 1280}")
        XCTAssertEqual(edits.library.channel(2)?.renderSize, .size(width: 1280, height: 720))
        XCTAssertEqual(edits.apply("edit channel 2 renderSize.width 1920").first?.inverse, set("renderSize.width", .number(1280)))

        // A value equal to the current one is a noop (Spec 5 §4).
        XCTAssertEqual(edits.apply("edit channel 2 label \"Lyrics\"").first?.isNoop, true)
        XCTAssertEqual(edits.apply("edit channel 2 label \"Lyrics\"").first?.changes, [])
    }

    /// Spec 11 §6 — "keeping the numbers this machine has no audio output
    /// for, since another campus meets them (Spec 1 §2)".
    func test_audioOutputsMayNameANumberThisMachineLacks() {
        var edits = Edits()
        XCTAssertNil(edits.machine.audioOutput(7))
        let out = edits.apply("edit channel 2 audioOutputs [1, 2, 7]")
        XCTAssertEqual(edits.library.channel(2)?.audioOutputs, [1, 2, 7])
        XCTAssertEqual(out.first?.inverse, set("audioOutputs", .array([.number(1)])))
    }

    func test_thePathAndTheValueAreChecked() {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit channel 2 color \"red\"")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit channel 2 defaults.fade 2")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit channel 1 renderSize.width 1280")?.reason, .unknownPath, "\"largest\" has no width")
        XCTAssertEqual(edits.refuse("edit channel 2 uuid \"8d1e0000-0000-4000-8000-000000000009\"")?.reason, .readOnlyField)
        let number = edits.refuse("edit channel 2 number 5")
        XCTAssertEqual(number?.reason, .readOnlyField)
        XCTAssertTrue(number?.message.contains("renumber") == true, number?.message ?? "")
        for bad in ["edit channel 2 decoderCap 4", "edit channel 2 defaults.gain 61", "edit channel 2 defaults.gain -60.5",
                    "edit channel 2 usualContent video", "edit channel 2 label 3", "edit channel 2 audioOutputs 1",
                    "edit channel 2 renderSize smallest", "edit channel 2 renderSize {\"width\": 1280}", "edit channel 2 defaultPreset null"] {
            XCTAssertEqual(edits.refuse(bad)?.reason, .badValue, bad)
        }
        XCTAssertEqual(edits.refuse("edit channel 9 label \"x\"")?.reason, .unknownObject)
        XCTAssertEqual(edits.refuse("edit channel 2 unset label")?.reason, .badValue, "a channel writes every field")
    }

    /// Spec 5 §6, check 5 — "Every number the value names exists on this machine".
    func test_aReferenceMustExist() {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit channel 2 defaultPreset 99")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit channel 2 defaults.transition 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit channel 2 defaults.audioTransition 9")?.reason, .unknownReference)
    }

    func test_lockAndLibraryMode() {
        var readOnly = Edits(writable: false)
        XCTAssertEqual(readOnly.refuse("edit channel 2 label \"x\"")?.reason, .readOnlyLibrary)
        XCTAssertEqual(readOnly.refuse("edit channel create")?.reason, .readOnlyLibrary)
        var locked = Edits()
        locked.machine.settings.operatorLock.enabled = true
        XCTAssertEqual(locked.refuse("edit channel 2 label \"x\"")?.reason, .operatorLock)
    }

    // MARK: - New, Duplicate, Delete (Spec 11 §7, "Its menu")

    /// "New Channel (`edit channel create`, with the first-run channels'
    /// defaults, Spec 6 §9, and an empty label".
    func test_createTakesTheFirstRunDefaultsAFreeNumberAndAFreshUuid() throws {
        var edits = Edits()
        let made = edits.apply("edit channel create")
        let channel = try XCTUnwrap(edits.library.channel(4))
        XCTAssertEqual(channel, Channel(number: 4, label: "", decoderCap: 2, uuid: Edits.pick(1), defaultPreset: 1, audioOutputs: [1],
                                        renderSize: .largest, usualContent: .any))
        XCTAssertEqual(made.first?.logged, EditCommand(.numbered(.channel, 4),
                                                       .create(body: .object(["uuid": .string(Edits.pick(1).uuidString.lowercased())]), folder: nil, title: nil)),
                       "the logged command records what the engine picked")
        XCTAssertEqual(made.first?.inverse, EditCommand(.numbered(.channel, 4), .delete))
        XCTAssertEqual(made.first?.changes, [Edits.changed(.channel, 4)])
        XCTAssertEqual(edits.library.channels.map(\.number), [1, 2, 3, 4])

        // A number and a body: the body's fields win over the defaults.
        edits.apply("edit channel 9 create {\"label\": \"Lower third\", \"usualContent\": \"text\", \"audioOutputs\": []}")
        XCTAssertEqual(edits.library.channel(9)?.label, "Lower third")
        XCTAssertEqual(edits.library.channel(9)?.usualContent, .text)
        XCTAssertEqual(edits.library.channel(9)?.audioOutputs, [])
        XCTAssertEqual(edits.library.channel(9)?.decoderCap, 2)
        XCTAssertEqual(edits.library.channels.map(\.number), [1, 2, 3, 4, 9], "in number order")

        XCTAssertEqual(edits.refuse("edit channel 9 create")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit channel 12 create {\"number\": 13}")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit channel 12 create {\"decoderCap\": 5}")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit channel 12 create {\"defaultPreset\": 77}")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit channel 12 create {\"uuid\": \"\(F.channelUuid(1).uuidString.lowercased())\"}")?.reason, .duplicate,
                       "a uuid another channel has")
    }

    /// Spec 5 §4 — "A number it picks is one more than the highest of that
    /// type in use or named by any reference, so a new object never takes
    /// over references meant for a deleted one".
    func test_aPickedNumberPassesEveryNumberSomethingNames() {
        var edits = Edits()
        edits.machine.stacks[0].slots.append(StackSlot(channel: 7))   // a slot left behind by a deleted channel 7
        edits.apply("edit channel create")
        XCTAssertNotNil(edits.library.channel(8))
        XCTAssertNil(edits.library.channel(4))
        // A number given outright may take such a number: "those references then resolve to the new object".
        edits.apply("edit channel 7 create")
        XCTAssertNotNil(edits.library.channel(7))
    }

    func test_duplicateCopiesToAFreeNumberWithANewUuid() throws {
        var edits = Edits()
        let copied = edits.apply("edit channel 2 duplicate")
        let copy = try XCTUnwrap(edits.library.channel(4))
        var expected = try XCTUnwrap(edits.library.channel(2))
        expected.number = 4
        expected.uuid = Edits.pick(1)
        XCTAssertEqual(copy, expected)
        XCTAssertEqual(copied.first?.logged, EditCommand(.numbered(.channel, 2), .duplicate(to: 4, title: nil, picks: EditPicks(uuid: Edits.pick(1)))))
        XCTAssertEqual(copied.first?.inverse, EditCommand(.numbered(.channel, 4), .delete))
        edits.apply("edit channel 2 duplicate 9")
        XCTAssertEqual(edits.library.channel(9)?.label, "Foreground")
        XCTAssertEqual(edits.refuse("edit channel 2 duplicate 9")?.reason, .duplicate)
    }

    /// Spec 5 §4 — delete: "References to it stay, and the reference report
    /// flags them (Spec 1 §8, E7)"; its inverse is "`edit.create` with the
    /// whole previous object". Spec 5 §6 — the result warns of "an object
    /// deleted while still referenced".
    func test_deleteLeavesItsReferencesWarnsAndComesBackWhole() throws {
        var edits = Edits()
        let channel = try XCTUnwrap(edits.library.channel(3))
        let deleted = edits.apply("edit channel 3 delete")
        XCTAssertNil(edits.library.channel(3))
        XCTAssertEqual(edits.machine.stack(2)?.slots.map(\.channel), [2, 3], "the slot that named it stays")
        XCTAssertEqual(deleted.first?.inverse, EditCommand(.numbered(.channel, 3), .create(body: try JSONCoding.encode(channel), folder: nil, title: nil)))
        XCTAssertEqual(deleted.first?.warnings.count, 1)
        XCTAssertTrue(deleted.first?.warnings.first?.contains("channel 3 is still named") == true, deleted.first?.warnings.first ?? "")
        // A channel nothing names goes without a word.
        edits.apply("edit channel create")
        XCTAssertEqual(edits.apply("edit channel 4 delete").first?.warnings, [])
        assertRoundTrip(["edit channel 3 delete"])
        assertRoundTrip(["edit channel create", "edit channel 2 duplicate 9", "edit channel 9 label \"Copy\""])
    }

    // MARK: - The number (Spec 11 §7)

    /// "Changing it sends `edit channel N renumber M`, which carries every
    /// reference in the library and this machine's root with it ...; a taken
    /// number offers Swap".
    func test_renumberCarriesEveryReferenceAndSwapExchangesTwo() throws {
        var edits = Edits()
        let before = References.to(.channel, 2, library: edits.library, machine: edits.machine).count
        let renumbered = edits.apply("edit channel 2 renumber 5")
        XCTAssertEqual(edits.library.channel(5)?.uuid, F.channelUuid(2))
        XCTAssertNil(edits.library.channel(2))
        XCTAssertEqual(References.to(.channel, 5, library: edits.library, machine: edits.machine).count, before)
        XCTAssertTrue(References.to(.channel, 2, library: edits.library, machine: edits.machine).isEmpty)
        XCTAssertEqual(edits.machine.stack(1)?.slots.map(\.channel), [1, 5])
        XCTAssertEqual(renumbered.first?.inverse, EditCommand(.numbered(.channel, 5), .renumber(to: 2)))
        // Spec 5 §2 — "The event names what changed": the channel, then every document whose references were
        // rewritten, so a client asks again for a list whose cues now write channel 5.
        let changed = renumbered.first?.changes ?? []
        XCTAssertEqual(changed.first, Edits.changed(.channel, 5))
        XCTAssertTrue(changed.contains(Edits.changed(.stack, 1, ["slots"])))
        XCTAssertTrue(changed.contains(Edits.changed(.stack, 2, ["slots"])))
        XCTAssertTrue(changed.contains { $0.object == "list" && $0.address["list"] == .number(42) && $0.paths == ["cues"] })
        XCTAssertTrue(changed.contains { $0.object == "list" && $0.address["local"] != nil }, "the local copy's cues were rewritten too")
        XCTAssertTrue(changed.contains { $0.object == "media" }, "an item whose default channel it was")
        XCTAssertFalse(changed.contains(Edits.changed(.preset, 1)), "what named no channel is not named")

        XCTAssertEqual(edits.refuse("edit channel 5 renumber 1")?.reason, .duplicate, "a taken number offers a swap")
        XCTAssertEqual(edits.refuse("edit channel 5 renumber 0")?.reason, .badValue)
        XCTAssertEqual(edits.apply("edit channel 5 renumber 5").first?.isNoop, true)

        let swapped = edits.apply("edit channel 5 swap 1")
        XCTAssertEqual(edits.library.channel(1)?.uuid, F.channelUuid(2))
        XCTAssertEqual(edits.library.channel(5)?.uuid, F.channelUuid(1))
        XCTAssertEqual(edits.machine.stack(1)?.slots.map(\.channel), [5, 1])
        XCTAssertEqual(swapped.first?.inverse, EditCommand(.numbered(.channel, 5), .swap(with: 1)))
        XCTAssertEqual(edits.refuse("edit channel 5 swap 8")?.reason, .unknownObject)
        assertRoundTrip(["edit channel 2 renumber 5", "edit channel 5 swap 1"])
    }

    /// Spec 5 §6, check 6 — "`renumber` and `swap` also refuse a number that
    /// broken references still name, so they never adopt references meant for
    /// a deleted object."
    func test_renumberRefusesANumberBrokenReferencesStillName() {
        var edits = Edits()
        edits.machine.stacks[0].slots.append(StackSlot(channel: 7))
        XCTAssertEqual(edits.refuse("edit channel 2 renumber 7")?.reason, .danglingReferences)
        edits.apply("edit channel 2 renumber 8")
    }

    // MARK: - On air (Spec 5 §6, check 7; Spec 11 §7)

    /// "Renumber is refused while the channel has content in a stack an
    /// output shows, and Swap while either channel has content and either is
    /// in a stack an output shows (`onAir`, as for Delete)".
    func test_aChannelWithContentInAShownStackIsOnAir() {
        var edits = Edits()
        // Both outputs show stack 1, which holds channels 1 and 2; stack 2 holds 2 and 3 and is on no output.
        edits.play("channel 2 write text \"Great is Thy faithfulness\"")
        XCTAssertEqual(edits.refuse("edit channel 2 delete")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 2 renumber 9")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 2 swap 3")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 3 swap 2")?.reason, .onAir, "a swap checks both objects")
        XCTAssertEqual(edits.refuse("edit channel 1 swap 2")?.reason, .onAir)
        // Its fields are still edited: only the three verbs that move a number are held.
        edits.apply("edit channel 2 label \"Lyrics\"")
        // Channel 1 is in the shown stack and holds nothing: it is not on air.
        edits.apply("edit channel 1 renumber 9")
        edits.play("channel 2 clear")
        edits.apply("edit channel 2 renumber 8")
    }

    func test_contentInAStackNoOutputShowsIsNotOnAir() {
        var edits = Edits()
        edits.play("channel 3 write text \"9:55\"")
        edits.apply("edit channel 3 renumber 9")
        // ShowState holds a channel by its number (Spec 3 §2): the engine gives channel 9 an empty entry.
        edits.context.state = nil
        edits.play("channel 9 write text \"9:55\"")
        edits.play("output 1 stack 2")
        XCTAssertEqual(edits.refuse("edit channel 9 delete")?.reason, .onAir, "the confidence stack is on an output now")
        XCTAssertEqual(edits.refuse("edit channel 9 renumber 3")?.reason, .onAir)
    }

    /// Spec 5 §6, check 7, Adam's answer of 2026-11-18 — "a channel whose
    /// content has sound and is routed to an audio output this machine has,
    /// since the sound would stop".
    func test_aChannelSoundingOnAnAudioOutputIsOnAir() throws {
        var edits = Edits()
        // A channel of its own for walk-in music: in no stack at all.
        edits.apply("edit channel 6 create {\"label\": \"Music\", \"audioOutputs\": [1]}")
        XCTAssertEqual(edits.library.mediaIndex.entry(F.mountains)?.hasAudio, true)
        edits.play("channel 6 write media \(F.mountains)")
        XCTAssertEqual(edits.refuse("edit channel 6 delete")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 6 renumber 7")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 6 swap 3")?.reason, .onAir)
        XCTAssertEqual(edits.refuse("edit channel 3 swap 6")?.reason, .onAir)

        // Silent media, or sound with nowhere to go on this machine, isn't.
        edits.play("channel 6 write media \(F.dawn)")
        XCTAssertEqual(edits.library.mediaIndex.entry(F.dawn)?.hasAudio, false)
        edits.apply("edit channel 6 renumber 7")
        edits.apply("edit channel 7 audioOutputs [9]")
        edits.play("channel 7 write media \(F.mountains)")
        edits.apply("edit channel 7 delete")
    }

    func test_withNoStateNothingIsOnAir() {
        var edits = Edits()
        XCTAssertNil(edits.context.state)
        edits.apply("edit channel 2 renumber 9")
    }
}
