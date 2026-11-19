import Foundation
import XCTest
@testable import OCore

/// Spec 11 §13 — "Each edit of a ... preset ... applies with its inverse and
/// its checks (Spec 5 §6); ... Preset 1 ... protected; ... a box moves by
/// position." Spec 11 §8 is the editor these edits serve: "each an
/// `edit.set` of `layouts.L.boxes.I.FIELD` on commit".
final class EditPresetTests: XCTestCase {
    typealias F = FixtureLibrary

    private func set(_ preset: Int, _ path: String, _ value: JSONValue) -> EditCommand {
        EditCommand(.numbered(.preset, preset), .set(path: path, value: value))
    }

    private func line<T: Encodable>(_ value: T) throws -> String { JSONCanonical.line(try JSONCoding.encode(value)) }

    private func textBox(_ name: String = "title") -> Box {
        Box(binding: .field(name: name), frame: Frame(x: 0.1, y: 0.4, w: 0.8, h: 0.2), fit: .text(TextFit()),
            textStyle: BoxTextStyle(values: TextStyleValues(), fromStyle: 1), transition: BoxTransition(ref: 1))
    }

    // MARK: - A box's properties (Spec 11 §8)

    func test_eachPropertyOfABoxSetsAtItsPath() throws {
        var edits = Edits()
        let x = edits.apply("edit preset 3 layouts.2.boxes.0.frame.x 0.1")
        XCTAssertEqual(edits.library.preset(3)?.layouts[.stack(2)]?.boxes[0].frame.x, 0.1)
        XCTAssertEqual(x.first?.inverse, set(3, "layouts.2.boxes.0.frame.x", .number(0.03)))
        XCTAssertEqual(x.first?.changes, [Edits.changed(.preset, 3, ["layouts.2.boxes.0.frame.x"])])

        // "when the drag or the nudge ends, one `edit.set` of the box's `frame`".
        let frame = edits.apply("edit preset 3 layouts.*.boxes.0.frame {\"h\": 0.2, \"w\": 0.8, \"x\": 0.1, \"y\": 0.7}")
        XCTAssertEqual(edits.library.preset(3)?.layouts[.any]?.boxes[0].frame, Frame(x: 0.1, y: 0.7, w: 0.8, h: 0.2))
        XCTAssertEqual(frame.first?.inverse, set(3, "layouts.*.boxes.0.frame", try JSONCoding.encode(Frame(x: 0.05, y: 0.78, w: 0.9, h: 0.12))))

        let star = "layouts.*.boxes.0"
        XCTAssertEqual(edits.apply("edit preset 3 \(star).offset 1").first?.inverse, set(3, "\(star).offset", .number(0)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).fallback true").first?.inverse, set(3, "\(star).fallback", .bool(false)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).grade null").first?.inverse, set(3, "\(star).grade", .number(1)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).transition.ref 1").first?.inverse, set(3, "\(star).transition.ref", .number(2)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).transition.ms null").first?.inverse, set(3, "\(star).transition.ms", .number(300)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).transitionOnVariableChange true").first?.inverse,
                       set(3, "\(star).transitionOnVariableChange", .bool(false)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).fit.maxLines 3").first?.inverse, set(3, "\(star).fit.maxLines", .number(2)))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).fit.policy maxLines").first?.inverse, set(3, "\(star).fit.policy", .string("shrinkToFit")))
        XCTAssertEqual(edits.apply("edit preset 3 \(star).binding.name body").first?.inverse, set(3, "\(star).binding.name", .string("title")))
        let box = try XCTUnwrap(edits.library.preset(3)?.layouts[.any]?.boxes[0])
        XCTAssertEqual(box.offset, 1)
        XCTAssertTrue(box.fallback)
        XCTAssertNil(box.grade)
        XCTAssertEqual(box.transition, BoxTransition(ref: 1, ms: nil))
        XCTAssertTrue(box.transitionOnVariableChange)
        XCTAssertEqual(box.fit, .text(TextFit(policy: .maxLines, maxLines: 3, minSize: 18)))
        XCTAssertEqual(box.binding, .field(name: "body"))
    }

    /// Spec 11 §8 — "Each change sets one field of `textStyle`."
    func test_theInlineTextStyleOfABox() throws {
        var edits = Edits()
        let style = "layouts.*.boxes.0.textStyle"
        XCTAssertEqual(edits.apply("edit preset 3 \(style).size.value 60").first?.inverse, set(3, "\(style).size.value", .number(4.5)))
        edits.apply("edit preset 3 \(style).size.unit pt")
        edits.apply("edit preset 3 \(style).font \"DMSans-9ptRegular_Bold\"")
        edits.apply("edit preset 3 \(style).alignment center")
        edits.apply("edit preset 3 \(style).verticalAlignment bottom")
        edits.apply("edit preset 3 \(style).color {\"a\": 1, \"b\": 0, \"g\": 0.5, \"r\": 1}")
        edits.apply("edit preset 3 \(style).outline.width 2")
        edits.apply("edit preset 3 \(style).shadow.blur 6")
        edits.apply("edit preset 3 \(style).allCaps false")
        edits.apply("edit preset 3 \(style).variations.wght 650")
        // A new axis is a new entry of the map, which unset takes away again.
        XCTAssertEqual(edits.apply("edit preset 3 \(style).variations.opsz 14").first?.inverse,
                       EditCommand(.numbered(.preset, 3), .unset(path: "\(style).variations.opsz")))
        XCTAssertEqual(edits.apply("edit preset 3 unset \(style).variations.wdth").first?.inverse, set(3, "\(style).variations.wdth", .number(110)))
        let values = try XCTUnwrap(edits.library.preset(3)?.layouts[.any]?.boxes[0].textStyle?.values)
        XCTAssertEqual(values.size, TextSize(value: 60, unit: .pt))
        XCTAssertEqual(values.font, "DMSans-9ptRegular_Bold")
        XCTAssertEqual(values.alignment, .center)
        XCTAssertEqual(values.verticalAlignment, .bottom)
        XCTAssertEqual(values.color, Color(r: 1, g: 0.5, b: 0, a: 1))
        XCTAssertEqual(values.outline.width, 2)
        XCTAssertEqual(values.shadow.blur, 6)
        XCTAssertFalse(values.allCaps)
        XCTAssertEqual(values.variations, ["wght": 650, "opsz": 14])

        // "Apply Style ▸ copies a numbered style's value into the box and sets `fromStyle` (one `edit.set` of `textStyle`)."
        let body = BoxTextStyle(values: try XCTUnwrap(edits.library.textStyle(1)?.values), fromStyle: 1)
        edits.apply("edit preset 3 \(style) \(try line(body))")
        XCTAssertEqual(edits.library.preset(3)?.layouts[.any]?.boxes[0].textStyle, body)
        XCTAssertEqual(edits.refuse("edit preset 3 \(style).fromStyle 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit preset 3 \(style).alignment middle")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 3 \(style).color {\"r\": 2, \"g\": 0, \"b\": 0, \"a\": 1}")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 3 \(style).kerning 2")?.reason, .unknownPath)
    }

    func test_thePathAndTheValueAreChecked() {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.*.boxes.0.frame.x 1.2")?.reason, .badValue, "box frames 0–1")
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.*.boxes.0.offset 4")?.reason, .badValue, "−2 to +3")
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.*.boxes.0.grade 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.*.boxes.0.transition.ref 9")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.2.boxes.4.frame.x 0.1")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.7.boxes.0.frame.x 0.1")?.reason, .unknownPath, "preset 3 has no layout for stack 7")
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.x {\"boxes\": [], \"mask\": null}")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit preset 3 builtIn true")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit preset 9 label \"x\"")?.reason, .unknownObject)
        var readOnly = Edits(writable: false)
        XCTAssertEqual(readOnly.refuse("edit preset 3 label \"x\"")?.reason, .readOnlyLibrary)
    }

    /// Spec 11 §8 — "Changing between pixels and text sets the whole box in
    /// one edit, so it never holds half of each".
    func test_aBindingChangesKindWithItsWholeBox() throws {
        var edits = Edits()
        // Preset 1's * layout: a pixel box, then a fallback body box.
        XCTAssertEqual(edits.refuse("edit preset 1 layouts.*.boxes.0.binding {\"kind\": \"field\", \"name\": \"title\"}")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 1 layouts.*.boxes.1.fit fill")?.reason, .badValue)
        let asText = edits.apply("edit preset 1 layouts.*.boxes.0 \(try line(textBox()))")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[0], textBox())
        XCTAssertEqual(asText.first?.inverse,
                       set(1, "layouts.*.boxes.0", try JSONCoding.encode(Box(binding: .pixels, frame: .full, fit: .pixels(.fit), transition: BoxTransition(ref: 1)))))
        // Within a kind, the binding alone changes: a field's name, or a field for static text.
        edits.apply("edit preset 1 layouts.*.boxes.0.binding {\"kind\": \"static\", \"text\": \"[Time]\"}")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[0].binding, .static(text: "[Time]"))
    }

    // MARK: - The box list (Spec 11 §8: add, duplicate, remove, reorder)

    /// Spec 5 §4 as Spec 11 corrected it — "`edit preset 3 move
    /// layouts.2.boxes 1 3` ... a child without an address of its own, such
    /// as a box ..., is named by its array's path and its position".
    func test_boxesGoInComeOutAndMoveByPosition() throws {
        var edits = Edits()
        let address = EditAddress.numbered(.preset, 1)
        let added = edits.apply("edit preset 1 insert layouts.*.boxes 2 \(try line(textBox()))")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes.count, 3)
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[2], textBox())
        XCTAssertEqual(added.first?.inverse, EditCommand(address, .remove(path: "layouts.*.boxes", at: 2)))
        XCTAssertEqual(added.first?.changes, [Edits.changed(.preset, 1, ["layouts.*.boxes"])])

        let moved = edits.apply("edit preset 1 move layouts.*.boxes 2 0")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes.map(\.binding), [.field(name: "title"), .pixels, .field(name: "body")])
        XCTAssertEqual(moved.first?.logged, EditCommand(address, .move(path: "layouts.*.boxes", from: 2, at: 0)))
        XCTAssertEqual(moved.first?.inverse, EditCommand(address, .move(path: "layouts.*.boxes", from: 0, at: 2)))
        XCTAssertEqual(edits.apply("edit preset 1 move layouts.*.boxes 1 1").first?.isNoop, true)

        let removed = edits.apply("edit preset 1 remove layouts.*.boxes 0")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes.map(\.binding), [.pixels, .field(name: "body")])
        XCTAssertEqual(removed.first?.inverse, EditCommand(address, .insert(path: "layouts.*.boxes", at: 0, value: try JSONCoding.encode(textBox()))))

        XCTAssertEqual(edits.refuse("edit preset 1 move layouts.*.boxes 0 2")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 1 remove layouts.*.boxes 2")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 1 insert layouts.*.boxes 3 \(try line(textBox()))")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 1 insert layouts.* 0 \(try line(textBox()))")?.reason, .badValue, "a layout isn't an array")
        XCTAssertEqual(edits.refuse("edit preset 1 insert layouts.*.boxes 0 {\"binding\": {\"kind\": \"pixels\"}}")?.reason, .badValue)
        var mixed = textBox()
        mixed.fit = .pixels(.fill)
        XCTAssertEqual(edits.refuse("edit preset 1 insert layouts.*.boxes 0 \(try line(mixed))")?.reason, .badValue, "a text box with a pixel fit")
        var graded = textBox()
        graded.grade = 9
        XCTAssertEqual(edits.refuse("edit preset 1 insert layouts.*.boxes 0 \(try line(graded))")?.reason, .unknownReference)
        assertRoundTrip(["edit preset 1 insert layouts.*.boxes 2 \(try line(textBox()))", "edit preset 1 move layouts.*.boxes 2 0",
                         "edit preset 1 remove layouts.*.boxes 1"])
    }

    // MARK: - Layouts (Spec 11 §8)

    /// "Copy from \*, which sets `layouts.S` to a copy of the `*` layout
    /// (`edit.set`). A stack's own layout offers Remove This Stack's Layout
    /// (`edit preset P unset layouts.S`)".
    func test_aStacksLayoutIsCopiedFromStarAndRemoved() throws {
        var edits = Edits()
        let star = try XCTUnwrap(edits.library.preset(3)?.layouts[.any])
        let copied = edits.apply("edit preset 3 layouts.1 \(try line(star))")
        XCTAssertEqual(edits.library.preset(3)?.layouts[.stack(1)], star)
        XCTAssertEqual(copied.first?.inverse, EditCommand(.numbered(.preset, 3), .unset(path: "layouts.1")))
        // "A layout for a stack this machine doesn't have stays in the preset ..., since it meets that number at other campuses".
        XCTAssertNil(edits.machine.stack(7))
        edits.apply("edit preset 3 layouts.7 \(try line(star))")

        let own = try XCTUnwrap(edits.library.preset(3)?.layouts[.stack(2)])
        let removed = edits.apply("edit preset 3 unset layouts.2")
        XCTAssertNil(edits.library.preset(3)?.layouts[.stack(2)])
        XCTAssertEqual(removed.first?.inverse, set(3, "layouts.2", try JSONCoding.encode(own)))
        XCTAssertEqual(edits.apply("edit preset 3 unset layouts.9").first?.isNoop, true)
        XCTAssertEqual(edits.refuse("edit preset 3 unset layouts.*")?.reason, .badValue, "a preset keeps its * layout")
        XCTAssertEqual(edits.refuse("edit preset 3 unset label")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit preset 3 layouts.2 {\"boxes\": 3}")?.reason, .badValue)
        assertRoundTrip(["edit preset 3 layouts.1 \(try line(star))", "edit preset 3 unset layouts.2"])
    }

    // MARK: - The preset (Spec 11 §8)

    /// "Preset 1 can be edited but not deleted, renumbered or swapped (Spec 5 §6)."
    func test_presetOneIsProtectedAndStaysEditable() {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit preset 1 delete")?.reason, .protected)
        XCTAssertEqual(edits.refuse("edit preset 1 renumber 9")?.reason, .protected)
        XCTAssertEqual(edits.refuse("edit preset 1 swap 2")?.reason, .protected)
        XCTAssertEqual(edits.refuse("edit preset 2 swap 1")?.reason, .protected)
        edits.apply("edit preset 1 label \"House\"")
        edits.apply("edit preset 1 layouts.*.boxes.1.frame.y 0.2")
        XCTAssertEqual(edits.library.preset(1)?.builtIn, true)
    }

    /// "New Preset (`edit preset create`, with an empty `*` layout),
    /// Duplicate (`edit preset P duplicate`, the UX spec's duplicate-from ...)".
    func test_createAndDuplicate() throws {
        var edits = Edits()
        edits.apply("edit preset create")
        XCTAssertEqual(edits.library.preset(5), Preset(number: 5, label: "", uuid: Edits.pick(1), layouts: [.any: Layout(boxes: [])]))
        edits.apply("edit preset 1 duplicate")
        let copy = try XCTUnwrap(edits.library.preset(6))
        XCTAssertFalse(copy.builtIn, "a copy of Preset 1 is an ordinary preset")
        XCTAssertEqual(copy.layouts, edits.library.preset(1)?.layouts)
        XCTAssertEqual(copy.uuid, Edits.pick(2))
        edits.apply("edit preset 6 delete")
        XCTAssertEqual(edits.refuse("edit preset 8 create {\"layouts\": {\"2\": {\"boxes\": [], \"mask\": null}}}")?.reason, .badValue,
                       "a preset keeps its * layout")
        XCTAssertEqual(edits.refuse("edit preset 3 create")?.reason, .duplicate)
        assertRoundTrip(["edit preset create", "edit preset 1 duplicate 9", "edit preset 9 label \"Wide\""])
    }

    func test_deleteRenumberAndSwapCarryTheFile() throws {
        var edits = Edits()
        XCTAssertEqual(edits.library.documentPaths["preset/2"], "presets/002-clock.json")
        // Preset 2 is channel 3's default.
        let renumbered = edits.apply("edit preset 2 renumber 9")
        XCTAssertEqual(edits.library.channel(3)?.defaultPreset, 9)
        XCTAssertEqual(edits.library.documentPaths["preset/9"], "presets/002-clock.json", "the writer renames the file it came from")
        XCTAssertNil(edits.library.documentPaths["preset/2"])
        XCTAssertEqual(renumbered.first?.inverse, EditCommand(.numbered(.preset, 9), .renumber(to: 2)))
        XCTAssertTrue(renumbered.first?.changes.contains(Edits.changed(.channel, 3, ["defaultPreset"])) == true)

        edits.apply("edit preset 9 swap 3")
        XCTAssertEqual(edits.library.documentPaths["preset/3"], "presets/002-clock.json")
        XCTAssertEqual(edits.library.documentPaths["preset/9"], "presets/003-lower-third.json")
        XCTAssertEqual(edits.library.preset(3)?.label, "Clock")

        let deleted = edits.apply("edit preset 3 delete")
        XCTAssertEqual(deleted.first?.structure, [.removeDocument(.preset(3), path: "presets/002-clock.json")])
        XCTAssertTrue(deleted.first?.warnings.first?.hasPrefix("preset 3 is still named by 1 reference") == true, deleted.first?.warnings.first ?? "")
        XCTAssertNil(edits.library.documentPaths["preset/3"])
        assertRoundTrip(["edit preset 3 delete"])
        assertRoundTrip(["edit preset 2 renumber 9", "edit preset 9 swap 3"])
    }

    /// Spec 5 §6 — the result warns of "a preset used as a stack default
    /// without a pixel box or a body box at offset 0"; Spec 6 §3 — it "counts
    /// only boxes at offset 0".
    func test_anEditOfAStacksDefaultPresetWarns() throws {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit preset 4 label \"Credits\"").first?.warnings, [], "no stack defaults to preset 4")
        edits.apply("edit stack 1 defaultPreset 1")
        XCTAssertEqual(edits.apply("edit preset 1 label \"House\"").first?.warnings, [])
        // Its body box moves to +1: nothing at offset 0 draws the text now.
        let moved = edits.apply("edit preset 1 layouts.*.boxes.1.offset 1")
        XCTAssertEqual(moved.first?.warnings, ["preset 1 is stack 1's default and has no body box at offset 0"])
        let removed = edits.apply("edit preset 1 remove layouts.*.boxes 0")
        XCTAssertEqual(removed.first?.warnings, ["preset 1 is stack 1's default and has no pixel box and no body box at offset 0"])
    }
}
