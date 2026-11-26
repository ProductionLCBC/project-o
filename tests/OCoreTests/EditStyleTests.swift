import Foundation
import XCTest
@testable import OCore

/// Spec 11 §13 — "Each edit of a ... text style, grade, transition, audio
/// transition ... applies with its inverse and its checks (Spec 5 §6); ...
/// transitions 1–3 are protected". Spec 11 §9 is the page these edits serve.
final class EditStyleTests: XCTestCase {
    typealias F = FixtureLibrary

    private func set(_ type: NumberedType, _ number: Int, _ path: String, _ value: JSONValue) -> EditCommand {
        EditCommand(.numbered(type, number), .set(path: path, value: value))
    }

    // MARK: - Text styles (Spec 11 §9: "edited with the style form of §8 (`edit textstyle N FIELD VALUE`)")

    func test_aTextStylesFields() throws {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit textstyle 1 size.value 48").first?.inverse, set(.textStyle, 1, "size.value", .number(72)))
        XCTAssertEqual(edits.apply("edit textstyle 1 label \"Lyrics\"").first?.inverse, set(.textStyle, 1, "label", .string("Body")))
        edits.apply("edit textstyle 1 font \"HelveticaNeue-Medium\"")
        edits.apply("edit textstyle 1 weight 500")
        edits.apply("edit textstyle 1 lineSpacing 1.3")
        edits.apply("edit textstyle 1 letterSpacing 1.5")
        edits.apply("edit textstyle 1 shadow {\"blur\": 4, \"color\": {\"a\": 0.5, \"b\": 0, \"g\": 0, \"r\": 0}, \"x\": 1, \"y\": 1}")
        edits.apply("edit textstyle 1 variations.wght 500")
        let style = try XCTUnwrap(edits.library.textStyle(1))
        XCTAssertEqual(style.label, "Lyrics")
        XCTAssertEqual(style.values.size, TextSize(value: 48, unit: .pt))
        XCTAssertEqual(style.values.font, "HelveticaNeue-Medium")
        XCTAssertEqual(style.values.weight, 500)
        XCTAssertEqual(style.values.lineSpacing, 1.3)
        XCTAssertEqual(style.values.letterSpacing, 1.5)
        XCTAssertEqual(style.values.shadow, Shadow(x: 1, y: 1, blur: 4, color: Color(r: 0, g: 0, b: 0, a: 0.5)))
        XCTAssertEqual(style.values.variations, ["wght": 500])
        XCTAssertEqual(edits.apply("edit textstyle 1 size.value 48").first?.changes, [])

        XCTAssertEqual(edits.refuse("edit textstyle 1 size.value -1")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit textstyle 1 size.unit em")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit textstyle 1 fromStyle 2")?.reason, .unknownPath, "a numbered style comes from no style")
        XCTAssertEqual(edits.refuse("edit textstyle 9 size.value 48")?.reason, .unknownObject)
        // A style is copied when applied (Spec 1 §2), so the boxes that came from it keep their own values.
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[1].textStyle?.values.size, TextSize(value: 72, unit: .pt))
    }

    /// Spec 11 §8 — "Save as Style… ... `edit textstyle N create` with the
    /// box's style ... N is one more than the highest style number in the
    /// catalog or named by any box's `fromStyle`, the number the engine itself
    /// would pick (Spec 5 §4), so a new style never adopts a deleted one's boxes".
    func test_aStyleIsMadeFromABoxsValuesAtANumberNothingNames() throws {
        var edits = Edits()
        let box = try XCTUnwrap(edits.library.preset(3)?.layouts[.any]?.boxes[0].textStyle)
        var body = try JSONCoding.encode(box).objectValue ?? [:]
        body["fromStyle"] = nil
        body["label"] = .string("Lower third")
        edits.apply("edit textstyle 3 create \(JSONCanonical.line(.object(body)))")
        XCTAssertEqual(edits.library.textStyle(3)?.values, box.values)
        XCTAssertEqual(edits.library.textStyle(3)?.label, "Lower third")

        edits.apply("edit textstyle 3 delete")
        edits.library.presets[0].layouts[.any]?.boxes[1].textStyle?.fromStyle = 7   // a box left naming a deleted style 7
        let picked = edits.apply("edit textstyle create")
        XCTAssertEqual(picked.first?.logged.address, .numbered(.textStyle, 8))
        XCTAssertEqual(edits.library.textStyle(8)?.values, TextStyleValues(), "the type's defaults")
        XCTAssertEqual(edits.refuse("edit textstyle 9 create {\"size\": {\"unit\": \"pt\", \"value\": -2}}")?.reason, .badValue)
    }

    /// Spec 11 §9 — "Deleting a style leaves each box its own copy; their
    /// `fromStyle` then names nothing, which the reference report flags."
    func test_deleteLeavesTheBoxesTheirCopiesAndRenumberCarriesThem() throws {
        var edits = Edits()
        let before = edits.library.presets
        let deleted = edits.apply("edit textstyle 2 delete")
        XCTAssertEqual(edits.library.presets, before, "no box changed")
        XCTAssertTrue(deleted.first?.warnings.first?.hasPrefix("text style 2 is still named by") == true, deleted.first?.warnings.first ?? "")
        edits.undo(deleted)

        edits.apply("edit textstyle 1 renumber 5")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[1].textStyle?.fromStyle, 5)
        edits.apply("edit textstyle 5 swap 2")
        XCTAssertEqual(edits.library.preset(1)?.layouts[.any]?.boxes[1].textStyle?.fromStyle, 2)
        XCTAssertEqual(edits.library.textStyle(2)?.label, "Body")
        edits.apply("edit textstyle 2 duplicate")
        XCTAssertEqual(edits.library.textStyle(6)?.label, "Body")
        assertRoundTrip(["edit textstyle 2 delete"])
        assertRoundTrip(["edit textstyle 1 renumber 5", "edit textstyle 5 swap 2", "edit textstyle 2 duplicate", "edit textstyle create"])
    }

    // MARK: - Grades (Spec 11 §9: "Each sends one `edit.set` when its drag ends")

    func test_aGradesParameters() throws {
        var edits = Edits()
        let warm = try XCTUnwrap(edits.library.grade(1))
        XCTAssertEqual(edits.apply("edit grade 1 saturation 1.2").first?.inverse, set(.grade, 1, "saturation", .number(warm.saturation)))
        edits.apply("edit grade 1 hue -30")
        edits.apply("edit grade 1 brightness 0.1")
        edits.apply("edit grade 1 contrast 1.5")
        edits.apply("edit grade 1 blur 12")
        edits.apply("edit grade 1 opacity 0.5")
        edits.apply("edit grade 1 tint {\"a\": 0.2, \"b\": 0, \"g\": 0.5, \"r\": 1}")
        let grade = try XCTUnwrap(edits.library.grade(1))
        XCTAssertEqual([grade.saturation, grade.hue, grade.brightness, grade.contrast, grade.blur, grade.opacity], [1.2, -30, 0.1, 1.5, 12, 0.5])
        XCTAssertEqual(grade.tint, Color(r: 1, g: 0.5, b: 0, a: 0.2))
        for bad in ["edit grade 1 saturation -1", "edit grade 1 contrast -0.5", "edit grade 1 blur -1", "edit grade 1 opacity 1.5",
                    "edit grade 1 tint {\"a\": 1, \"b\": 0, \"g\": 0, \"r\": 2}", "edit grade 1 hue warm"] {
            XCTAssertEqual(edits.refuse(bad)?.reason, .badValue, bad)
        }
        XCTAssertEqual(edits.refuse("edit grade 1 gamma 2")?.reason, .unknownPath)
    }

    func test_gradesAreMadeCopiedAndDeleted() throws {
        var edits = Edits()
        edits.apply("edit grade create")
        XCTAssertEqual(edits.library.grade(2), Grade(number: 2, label: "", uuid: Edits.pick(1)), "every parameter at its identity")
        edits.apply("edit grade 1 duplicate")
        XCTAssertEqual(edits.library.grade(3)?.label, "Warm")
        // Grade 1 is a box's grade in preset 3, a rider in list 42 and an item's default.
        let deleted = edits.apply("edit grade 1 delete")
        XCTAssertTrue(deleted.first?.warnings.first?.hasPrefix("grade 1 is still named by 3 references") == true, deleted.first?.warnings.first ?? "")
        edits.undo(deleted)
        edits.apply("edit grade 1 renumber 9")
        XCTAssertEqual(edits.library.preset(3)?.layouts[.any]?.boxes[0].grade, 9)
        XCTAssertEqual(edits.library.mediaIndex.entry(F.mountains)?.defaults.grade, 9)
        assertRoundTrip(["edit grade create", "edit grade 1 duplicate", "edit grade 1 renumber 9", "edit grade 9 delete"])
    }

    // MARK: - Transitions (Spec 11 §9 as corrected 2026-11-25, G-38)

    /// "Every transition's duration (`ms`), easing and, for a fade, color can be edited; the type of a new one is
    /// picked from the three, and 1–3 keep theirs (`protected`)"; Spec 5 §6 — "Transitions 1–3 can't be deleted,
    /// renumbered or swapped".
    func test_theBuiltInTransitionsKeepTheirTypeAndStayProtected() {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit transition 2 ms 750").first?.inverse, set(.transition, 2, "ms", .number(500)))
        XCTAssertEqual(edits.apply("edit transition 2 easing linear").first?.inverse, set(.transition, 2, "easing", .string("easeInOut")))
        edits.apply("edit transition 2 label \"Slow dissolve\"")
        XCTAssertEqual(edits.library.transition(2)?.ms, 750)
        XCTAssertEqual(edits.library.transition(2)?.easing, .linear)
        // A fade's color can change, 3's too.
        edits.apply("edit transition 3 color {\"a\": 1, \"b\": 1, \"g\": 1, \"r\": 1}")
        XCTAssertEqual(edits.library.transition(3)?.color, Color(r: 1, g: 1, b: 1, a: 1))
        // 1–3 keep their type.
        XCTAssertEqual(edits.refuse("edit transition 2 type cut")?.reason, .protected)
        XCTAssertEqual(edits.library.transition(2)?.type, .dissolve)
        XCTAssertEqual(edits.refuse("edit transition 2 builtIn false")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit transition 2 ms -1")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit transition 2 ms 0.5")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit transition 2 easing bounce")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit transition 2 type wipe")?.reason, .badValue, "new types are v2's")
        for number in 1...3 {
            XCTAssertEqual(edits.refuse("edit transition \(number) delete")?.reason, .protected)
            XCTAssertEqual(edits.refuse("edit transition \(number) renumber 9")?.reason, .protected)
        }
        XCTAssertEqual(edits.refuse("edit transition 1 swap 2")?.reason, .protected)
        XCTAssertEqual(edits.refuse("edit transition 9 ms 1")?.reason, .unknownObject)
        assertRoundTrip(["edit transition 2 ms 750", "edit transition 3 easing easeIn", "edit transition 1 label \"Hard cut\""])
    }

    /// "New (a 500 ms dissolve), Duplicate, Renumber… and Delete as for grades": a new transition's type is its own.
    func test_aNewTransitionIsMadeChangedAndDeletedAsAGradeIs() throws {
        var edits = Edits()
        let made = try XCTUnwrap(edits.apply("edit transition create").first)
        let fresh = try XCTUnwrap(edits.library.transition(4))
        XCTAssertEqual(fresh.type, .dissolve)
        XCTAssertEqual(fresh.ms, 500)
        XCTAssertFalse(fresh.builtIn)
        XCTAssertEqual(made.inverse, EditCommand(.numbered(.transition, 4), .delete))
        // Its type, its color.
        XCTAssertEqual(edits.apply("edit transition 4 type fadeThroughColor").first?.inverse, set(.transition, 4, "type", .string("dissolve")))
        edits.apply("edit transition 4 color {\"a\": 1, \"b\": 0, \"g\": 0, \"r\": 1}")
        XCTAssertEqual(edits.library.transition(4)?.type, .fadeThroughColor)
        XCTAssertEqual(edits.library.transition(4)?.color, Color(r: 1, g: 0, b: 0, a: 1))
        // A copy of a built-in one is not built in, and its type is its own.
        edits.apply("edit transition 2 duplicate")
        XCTAssertEqual(edits.library.transition(5)?.type, .dissolve)
        XCTAssertEqual(edits.library.transition(5)?.builtIn, false)
        edits.apply("edit transition 5 type cut")
        XCTAssertEqual(edits.library.transition(5)?.type, .cut)
        // Renumbered, swapped among the new ones, deleted.
        edits.apply("edit transition 5 renumber 9")
        XCTAssertNotNil(edits.library.transition(9))
        edits.apply("edit transition 4 swap 9")
        XCTAssertEqual(edits.library.transition(4)?.type, .cut)
        XCTAssertEqual(edits.refuse("edit transition 4 swap 2")?.reason, .protected)
        edits.apply("edit transition 9 delete")
        XCTAssertNil(edits.library.transition(9))
        assertRoundTrip(["edit transition create", "edit transition 2 duplicate", "edit transition 4 type cut", "edit transition 5 renumber 9",
                         "edit transition 9 delete"])
    }

    // MARK: - Audio transitions (Spec 11 §9, choice A-7)

    /// "duration, easing, and the offset, signed and measured from the
    /// trigger ... New, Duplicate and Delete as for grades, the type picked
    /// from cut, crossfade and fade through silence."
    func test_anAudioTransitionsFields() throws {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit audiotransition 2 offsetMs -200").first?.inverse, set(.audioTransition, 2, "offsetMs", .number(0)))
        edits.apply("edit audiotransition 2 ms 900")
        edits.apply("edit audiotransition 2 easing easeOut")
        edits.apply("edit audiotransition 2 type fadeThroughSilence")
        XCTAssertEqual(edits.library.audioTransition(2),
                       AudioTransition(number: 2, type: .fadeThroughSilence, ms: 900, offsetMs: -200, label: "Crossfade",
                                       uuid: try XCTUnwrap(edits.library.audioTransition(2)?.uuid), easing: .easeOut))
        XCTAssertEqual(edits.refuse("edit audiotransition 2 offsetMs 1001")?.reason, .badValue, "offsets within ±1000 ms")
        XCTAssertEqual(edits.refuse("edit audiotransition 2 offsetMs -1001")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit audiotransition 2 type dissolve")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit audiotransition 2 ms -5")?.reason, .badValue)

        edits.apply("edit audiotransition create")
        XCTAssertEqual(edits.library.audioTransition(4), AudioTransition(number: 4, type: .cut, ms: 0, offsetMs: 0, label: "", uuid: Edits.pick(1), easing: .linear))
        edits.apply("edit audiotransition 6 create {\"label\": \"J cut\", \"ms\": 800, \"offsetMs\": -400, \"type\": \"crossfade\"}")
        XCTAssertEqual(edits.library.audioTransition(6)?.offsetMs, -400)
        edits.apply("edit audiotransition 3 duplicate")
        XCTAssertEqual(edits.library.audioTransition(7)?.type, .fadeThroughSilence)
        // Audio transition 2 is a rider in list 42.
        XCTAssertTrue(edits.apply("edit audiotransition 2 delete").first?.warnings.first?.hasPrefix("audio transition 2 is still named by 1 reference") == true)
        edits.apply("edit audiotransition 1 renumber 9")
        XCTAssertEqual(edits.library.channel(1)?.defaults.audioTransition, 9)
        assertRoundTrip(["edit audiotransition create", "edit audiotransition 2 delete", "edit audiotransition 1 renumber 9", "edit audiotransition 9 swap 3"])
    }

    func test_theyAreLibraryObjects() {
        var readOnly = Edits(writable: false)
        for text in ["edit textstyle 1 weight 400", "edit grade 1 hue 10", "edit transition 2 ms 600", "edit audiotransition 2 ms 600",
                     "edit grade create", "edit textstyle 1 delete"] {
            XCTAssertEqual(readOnly.refuse(text)?.reason, .readOnlyLibrary, text)
        }
    }
}
