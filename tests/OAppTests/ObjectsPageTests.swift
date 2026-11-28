import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the small editors" — "A grade edit on release, its ranges and its preview beside the item as
/// it is; transitions 1–3 with only duration and easing, and no New, Duplicate or Delete; an audio transition's offset,
/// New, Duplicate and Delete; Re-apply to Boxes ...; a macro's commands ..., Run on Air", over a store fed the engine's
/// recorded answers (grade 1 Warm, transitions 1 to 3, audio transitions 1 to 3, text styles 1 and 2, macro 1 Welcome
/// in the library and macro 2 Preshow on this machine).
@MainActor
final class ObjectsPageTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func last(_ rig: Rig) -> [String]? { rig.commands.last { !$0.isEmpty } }
    private func count(_ rig: Rig) -> Int { rig.commands.filter { !$0.isEmpty }.count }
    private func query(_ rig: Rig, _ what: String) -> [String: JSONValue]? {
        rig.sent.last { $0.fields["what"] == .string(what) }?.fields
    }

    private func ok(_ rig: Rig, _ fields: [String: JSONValue]? = nil) {
        var outcome = CommandOutcome(kind: .ok)
        if let fields { outcome.applied = [AppliedEdit(command: .object(fields), inverse: nil)] }
        rig.answers[rig.answers.count - 1](.result(outcome))
    }

    // MARK: - The list (Spec 11 §9)

    /// "On its left, a list in groups (Grades, Transitions, Audio transitions, Text styles, Macros), each with its
    /// objects by number and label"; a macro from either root.
    func test_theListGroupsEveryObjectByNumberAndSelectsTheFirstAtFirst() throws {
        let rig = try Rig()
        let page = rig.model.editing.objectsPage
        XCTAssertEqual(page.groups.map(\.kind), [.grade, .transition, .audioTransition, .textStyle, .macro])
        XCTAssertEqual(page.groups.map { $0.rows.map(\.key.number) }, [[1], [1, 2, 3], [1, 2, 3], [1, 2], [1, 2]])
        XCTAssertEqual(page.groups[4].rows.map(\.label), ["Welcome", "Preshow"])
        XCTAssertEqual(page.selected, ObjectKey(.grade, 1), "the first object of the first group")
        // The chosen one while it exists, kept in view.json.
        XCTAssertTrue(rig.model.editing.open(page: .objects))
        rig.model.editing.selectObject(ObjectKey(.macro, 2))
        XCTAssertEqual(rig.model.settings.editObjectKind, .macro)
        XCTAssertEqual(rig.model.settings.editObject, 2)
        XCTAssertEqual(rig.model.editing.selectedMacro?.label, "Preshow")
        XCTAssertNil(rig.model.editing.selectedGrade)
        rig.model.settings.editObject = 9
        XCTAssertEqual(rig.model.editing.selectedObject, ObjectKey(.grade, 1), "a number that's gone falls back to the first")
    }

    /// Spec 11 §9 as corrected 2026-11-25 (G-38) — "New (a 500 ms dissolve), Duplicate, Renumber… and Delete as for
    /// grades, but for transitions 1–3, which ship built in and stay protected (Spec 5 §6)".
    func test_transitionsOneToThreeAreProtectedAndNewOnesAreNot() {
        let key = ObjectKey(.transition, 2)
        XCTAssertTrue(key.isProtected)
        XCTAssertFalse(ObjectKey(.transition, 4).isProtected)
        XCTAssertFalse(ObjectKey(.grade, 2).isProtected)
        XCTAssertEqual(ObjectEdits.create(.transition)?.lines, ["edit transition create"])
        XCTAssertEqual(ObjectEdits.duplicate(key)?.lines, ["edit transition 2 duplicate"], "a copy of one is a new transition")
        XCTAssertNil(ObjectEdits.delete(key))
        XCTAssertNil(ObjectEdits.renumber(key, to: 7, swap: false))
        XCTAssertEqual(ObjectEdits.delete(ObjectKey(.transition, 4))?.lines, ["edit transition 4 delete"])
        XCTAssertEqual(ObjectEdits.renumber(ObjectKey(.transition, 4), to: 7, swap: false)?.lines, ["edit transition 4 renumber 7"])
        // "Their duration (`ms`) and easing can be edited".
        XCTAssertEqual(ObjectEdits.set(key, "ms", .number(750)).lines, ["edit transition 2 ms 750"])
        XCTAssertEqual(ObjectEdits.set(key, "easing", .string("easeOut")).lines, ["edit transition 2 easing \"easeOut\""])
    }

    // MARK: - Grades (Spec 11 §9, "Grades")

    /// "brightness, contrast and saturation from 0 to 200% (100% is identity), hue from −180° to 180° (0°), opacity from
    /// 0 to 100% (100%), blur from 0 to the largest radius the grade pass takes (0)".
    func test_aGradesParametersShowInTheirRangesWithTheirIdentity() {
        let identity = Grade(number: 1)
        XCTAssertTrue(identity.isIdentity)
        for parameter in GradeParameter.allCases {
            XCTAssertEqual(parameter.shown(identity), parameter.identity, "\(parameter) shows its identity")
            XCTAssertTrue(parameter.range.contains(parameter.identity))
        }
        XCTAssertEqual(GradeParameter.allCases.map(\.range), [0...200, 0...200, 0...200, 0...360, 0...100, 0...64])
        // Shown and stored: brightness is held as the change from identity (Spec 4 §7: × (1 + brightness)).
        XCTAssertEqual(GradeParameter.brightness.stored(120), 0.2, accuracy: 1e-9)
        XCTAssertEqual(GradeParameter.brightness.stored(0), -1)
        XCTAssertEqual(GradeParameter.contrast.stored(150), 1.5)
        XCTAssertEqual(GradeParameter.saturation.stored(0), 0)
        XCTAssertEqual(GradeParameter.hue.stored(330), 330)
        XCTAssertEqual(GradeParameter.opacity.stored(40), 0.4)
        XCTAssertEqual(GradeParameter.blur.stored(12), 12)
        // A value past the range is held to it.
        XCTAssertEqual(GradeParameter.saturation.stored(500), 2)
        XCTAssertEqual(GradeParameter.hue.stored(400), 360)
        // G-39 — a hue stored outside 0° to 360° shows turned into it.
        XCTAssertEqual(GradeParameter.hue.shown(Grade(number: 1, hue: -30)), 330, accuracy: 1e-9)
        XCTAssertEqual(GradeParameter.blur.stored(1000), 64)
        // Grade 1 Warm, as the sliders show it.
        let warm = Grade(number: 1, hue: 8, saturation: 1.15, brightness: -0.05, contrast: 1.1)
        XCTAssertEqual(GradeParameter.brightness.shown(warm), 95, accuracy: 1e-9)
        XCTAssertEqual(GradeParameter.contrast.shown(warm), 110, accuracy: 1e-9)
        XCTAssertEqual(EditModeWording.shown(95, of: .brightness), "95%")
        XCTAssertEqual(EditModeWording.shown(330, of: .hue), "330°")
    }

    /// "Each sends one `edit.set` when its drag ends"; the preview is "`render` with `subject.kind` `grade`, and `grade`
    /// null for the second, §3", "the item picked under the preview, at first the pool's first video or image".
    func test_aGradeSendsOneEditAndAsksForItsPictureBesideTheItemAsItIs() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        let uses = try XCTUnwrap(query(rig, "uses"))
        XCTAssertEqual(uses["object"], .string("grade"))
        XCTAssertEqual(uses["grade"], .number(1))
        XCTAssertNil(query(rig, "render"), "nothing is drawn until the monitor says its width")
        editing.gradeWidth(640)
        let first = try XCTUnwrap(editing.gradeMediaChoices.first?.id)
        let renders = rig.sent.filter { $0.fields["what"] == .string("render") }.map(\.fields)
        XCTAssertEqual(renders.count, 2)
        XCTAssertEqual(renders.map { $0["canvas"] }, [.string("grade"), .string("ungraded")])
        XCTAssertEqual(renders.map { $0["subject"]?.objectValue?["grade"] }, [.number(1), .null])
        XCTAssertEqual(renders.map { $0["subject"]?.objectValue?["media"] }, [.string(first), .string(first)])
        XCTAssertEqual(renders.map { $0["width"] }, [.number(640), .number(640)])
        // The answers fill the two pictures.
        let indices = rig.sent.indices.filter { rig.sent[$0].fields["what"] == .string("render") }
        rig.answers[indices[0]](.answer(["file": .string("thumbnails/render/c1-grade-5.png"), "width": .number(640), "height": .number(360)]))
        rig.answers[indices[1]](.answer(["file": .string("thumbnails/render/c1-ungraded-6.png"), "width": .number(640), "height": .number(360)]))
        XCTAssertEqual(editing.objectState.graded.file, "thumbnails/render/c1-grade-5.png")
        XCTAssertEqual(editing.objectState.ungraded.file, "thumbnails/render/c1-ungraded-6.png")
        // A slider's release: one edit, in the grade's own terms; the same value sends nothing.
        editing.setGrade(.brightness, shown: 120)
        XCTAssertEqual(last(rig), ["edit grade 1 brightness 0.2"])
        let sent = count(rig)
        editing.setGrade(.contrast, shown: 110)
        XCTAssertEqual(count(rig), sent, "contrast is 110% already")
        editing.setGrade(.opacity, shown: 50)
        XCTAssertEqual(last(rig), ["edit grade 1 opacity 0.5"])
        // Another item under the preview.
        if let other = editing.gradeMediaChoices.dropFirst().first?.id {
            editing.setGradeMedia(other)
            XCTAssertEqual(query(rig, "render")?["subject"]?.objectValue?["media"], .string(other))
        }
    }

    private func renders(_ rig: Rig) -> [(index: Int, fields: [String: JSONValue])] {
        rig.sent.indices.filter { rig.sent[$0].fields["what"] == .string("render") }.map { ($0, rig.sent[$0].fields) }
    }

    /// Answers every render asked for since `from` (an index into `rig.sent`), as the engine would.
    private func answerRenders(_ rig: Rig, from: Int) {
        for (index, fields) in renders(rig) where index >= from {
            let canvas = fields["canvas"]?.stringValue ?? "x"
            rig.answers[index](.answer(["file": .string("thumbnails/render/c1-\(canvas)-\(index).png"), "width": .number(640), "height": .number(360)]))
        }
    }

    private func subject(_ fields: [String: JSONValue]?) -> [String: JSONValue]? { fields?["subject"]?.objectValue }

    /// Spec 11 §9 as corrected 2026-11-26 (G-43) — "Each sends one `edit.set` when its drag ends; while it is dragged,
    /// and while the tint's colour panel is open, the stage draws the grade with the values shown (`render` with the
    /// grade's values, §3)".
    func test_aDraggedSliderDrawsTheGradeWithTheValuesShownAndSendsOneEditWhenItEnds() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        let still = try XCTUnwrap(editing.gradeMediaChoices.first { $0.entry.kind == .image }?.id)
        editing.setGradeMedia(still)
        editing.gradeWidth(640)
        answerRenders(rig, from: 0)
        let edits = count(rig)
        let before = rig.sent.count
        editing.previewGrade(.brightness, shown: 130)
        editing.previewGrade(.brightness, shown: 140)
        XCTAssertEqual(count(rig), edits, "nothing sent while it is dragged")
        let asked = renders(rig).filter { $0.index >= before }.map(\.fields)
        XCTAssertEqual(asked.map { $0["canvas"] }, [.string("grade"), .string("grade")], "only the graded picture changes")
        let values = try XCTUnwrap(subject(asked.last)?["grade"]?.objectValue)
        XCTAssertEqual(values["brightness"]?.doubleValue ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(values["hue"], .number(8), "the grade's other values as stored (grade 1 Warm)")
        XCTAssertNil(subject(asked.last)?["atMs"], "a still has no time")
        // Let go: one edit. The picture keeps the values until the edit's outcome, then is the grade's by its number.
        editing.setGrade(.brightness, shown: 140)
        XCTAssertEqual(last(rig), ["edit grade 1 brightness 0.4"])
        XCTAssertNotNil(editing.objectState.gradeDraft)
        ok(rig)
        XCTAssertNil(editing.objectState.gradeDraft)
        XCTAssertEqual(subject(renders(rig).last?.fields)?["grade"], .number(1))
        // The tint while the color panel is open, then chosen.
        editing.previewGradeTint(Color(r: 1, g: 0.5, b: 0, a: 0.3))
        let tint = subject(renders(rig).last?.fields)?["grade"]?.objectValue?["tint"]
        XCTAssertEqual(tint, .object(["r": .number(1), "g": .number(0.5), "b": .number(0), "a": .number(0.3)]))
        XCTAssertEqual(count(rig), edits + 1, "nothing sent while the panel chooses")
        editing.setGradeTint(Color(r: 1, g: 0.5, b: 0, a: 0.3))
        XCTAssertEqual(last(rig), ["edit grade 1 tint { \"a\": 0.3, \"b\": 0, \"g\": 0.5, \"r\": 1 }"])
        // A refused edit draws the grade as it is again.
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .rejected)))
        XCTAssertNil(editing.objectState.gradeDraft)
        XCTAssertEqual(subject(renders(rig).last?.fields)?["grade"], .number(1))
        // Another object: no values carried over.
        editing.previewGrade(.contrast, shown: 150)
        editing.selectObject(ObjectKey(.transition, 1))
        XCTAssertNil(editing.objectState.gradeDraft)
    }

    /// G-43 — "For a video it has Play, a loop switch and a scrub bar over the item's length: playing asks for both
    /// pictures at the time played and for the next as soon as both have come, so it plays as fast as the engine
    /// draws, dropping frames rather than queueing them; at the end it stops, or with the loop on starts again;
    /// stopped, both pictures are of the scrub bar's time."
    func test_aVideoPlaysAsFastAsBothPicturesComeAndStopsOrStartsAgainAtItsEnd() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        let video = try XCTUnwrap(editing.gradeMediaChoices.first { $0.entry.kind == .video })
        editing.setGradeMedia(video.id)
        editing.gradeWidth(640)
        let length = try XCTUnwrap(editing.gradeVideoMs)
        XCTAssertEqual(length, video.entry.durationMs)
        // Stopped: both pictures at the scrub bar's time, from the start.
        XCTAssertEqual(renders(rig).suffix(2).map { subject($0.fields)?["atMs"] }, [.number(0), .number(0)])
        var mark = rig.sent.count
        editing.scrubGrade(toMs: 500)
        XCTAssertEqual(renders(rig).filter { $0.index >= mark }.map { subject($0.fields)?["atMs"] }, [.number(500), .number(500)])
        answerRenders(rig, from: 0)

        // Play from there: the next pair only once both have come.
        mark = rig.sent.count
        editing.playGrade()
        XCTAssertTrue(editing.isGradePlaying)
        let pair = renders(rig).filter { $0.index >= mark }
        XCTAssertEqual(pair.map { $0.fields["canvas"] }, [.string("grade"), .string("ungraded")])
        rig.clock.advance(by: 0.2)
        rig.answers[pair[0].index](.answer(["file": .string("thumbnails/render/c1-grade-p.png")]))
        rig.clock.advance(by: 0.01)
        XCTAssertEqual(renders(rig).count, renders(rig).filter { $0.index < mark }.count + 2, "one of the two still to come")
        rig.answers[pair[1].index](.answer(["file": .string("thumbnails/render/c1-ungraded-p.png")]))
        mark = rig.sent.count
        rig.clock.advance(by: 0.01)
        let next = renders(rig).filter { $0.index >= mark }
        XCTAssertEqual(next.count, 2)
        let played = try XCTUnwrap(subject(next.first?.fields)?["atMs"]?.intValue)
        XCTAssertEqual(played, 500 + 220, accuracy: 15, "the time played, from the scrub bar's")
        XCTAssertEqual(editing.objectState.gradeTimeMs, played)

        // At the end it stops, on its last frame: the video's length passes while that pair is drawn.
        rig.clock.advance(by: Double(length) / 1000)
        let drawing = mark
        mark = rig.sent.count
        answerRenders(rig, from: drawing)
        rig.clock.advance(by: 0.01)
        XCTAssertEqual(renders(rig).filter { $0.index >= mark }.map { subject($0.fields)?["atMs"] }, [.number(Double(length)), .number(Double(length))])
        XCTAssertFalse(editing.isGradePlaying)
        answerRenders(rig, from: mark)
        mark = rig.sent.count
        rig.clock.advance(by: 1)
        XCTAssertTrue(renders(rig).filter { $0.index >= mark }.isEmpty, "stopped: nothing more asked")

        // With the loop on it starts again: Play at the end starts from the start, and the end wraps.
        editing.setGradeLoop(true)
        mark = rig.sent.count
        editing.playGrade()
        XCTAssertEqual(subject(renders(rig).filter { $0.index >= mark }.first?.fields)?["atMs"], .number(0))
        rig.clock.advance(by: Double(length) / 1000 + 0.3)
        let looping = mark
        mark = rig.sent.count
        answerRenders(rig, from: looping)
        rig.clock.advance(by: 0.01)
        let wrapped = try XCTUnwrap(subject(renders(rig).filter { $0.index >= mark }.first?.fields)?["atMs"]?.intValue)
        XCTAssertEqual(wrapped, 300, accuracy: 15)
        XCTAssertTrue(editing.isGradePlaying)

        // Scrubbing stops it; another object stops it too.
        editing.scrubGrade(toMs: 100)
        XCTAssertFalse(editing.isGradePlaying)
        editing.playGrade()
        editing.selectObject(ObjectKey(.transition, 1))
        XCTAssertFalse(editing.isGradePlaying)
    }

    /// A still has no time, no Play and no scrub bar.
    func test_aStillHasNoTime() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        let still = try XCTUnwrap(editing.gradeMediaChoices.first { $0.entry.kind == .image }?.id)
        editing.setGradeMedia(still)
        editing.gradeWidth(640)
        XCTAssertNil(editing.gradeVideoMs)
        XCTAssertNil(subject(renders(rig).last?.fields)?["atMs"])
        let now = rig.sent.count
        editing.playGrade()
        XCTAssertFalse(editing.isGradePlaying)
        XCTAssertEqual(rig.sent.count, now)
    }

    // MARK: - What every object shares (Spec 11 §9)

    /// "its number, with renumber, or swap for a taken one"; Duplicate; "Delete asks first, with the counts from
    /// `uses`"; New at a free number, selected once made.
    func test_numberDuplicateDeleteAndNewForAnAudioTransition() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        var asked: [Confirmation] = []
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(true)
        }
        editing.selectObject(ObjectKey(.audioTransition, 2))
        // "the offset, signed and measured from the trigger, that makes J and L cuts".
        editing.setObject("offsetMs", .number(-250))
        XCTAssertEqual(last(rig), ["edit audiotransition 2 offsetMs -250"])
        editing.renumberObject(to: 3)
        XCTAssertEqual(last(rig), ["edit audiotransition 2 swap 3"], "3 is taken")
        editing.renumberObject(to: 7)
        XCTAssertEqual(last(rig), ["edit audiotransition 2 renumber 7"])
        ok(rig)
        XCTAssertEqual(rig.model.settings.editObject, 7, "the selection follows")
        editing.selectObject(ObjectKey(.audioTransition, 2))
        editing.duplicateObject()
        XCTAssertEqual(last(rig), ["edit audiotransition 2 duplicate"])
        ok(rig, ["cmd": .string("edit.duplicate"), "object": .string("audiotransition"), "audiotransition": .number(4)])
        XCTAssertEqual(rig.model.settings.editObject, 4, "the copy opens, once the library event brings it")
        editing.newObject(.grade)
        XCTAssertEqual(last(rig), ["edit grade create"])
        ok(rig, ["cmd": .string("edit.create"), "object": .string("grade"), "grade": .number(2)])
        XCTAssertEqual(rig.model.settings.editObjectKind, .grade)
        XCTAssertEqual(rig.model.settings.editObject, 2)
        editing.selectObject(ObjectKey(.grade, 1))
        editing.deleteObject()
        XCTAssertEqual(query(rig, "uses")?["grade"], .number(1))
        rig.answers[rig.answers.count - 1](.answer(["counts": .object(["cues": .number(3), "boxes": .number(1)])]))
        XCTAssertEqual(asked, [.deleteNumbered(name: "Grade 1 Warm", uses: ["cues": 3, "boxes": 1])])
        XCTAssertEqual(last(rig), ["edit grade 1 delete"])
        // A built-in transition: not deleted, not renumbered.
        editing.selectObject(ObjectKey(.transition, 2))
        let now = rig.sent.count
        editing.deleteObject()
        editing.renumberObject(to: 9)
        XCTAssertEqual(rig.sent.count, now)
    }

    /// "Used by, from `uses` (§3)": each kind of entry read in its shape.
    func test_usedByReadsEveryKindOfEntry() {
        let answer: [String: JSONValue] = ["more": .bool(true), "uses": .object([
            "channels": .array([.object(["channel": .number(2), "field": .string("defaults.transition")])]),
            "stacks": .array([.object(["stack": .number(1), "slot": .number(2)]), .object(["stack": .number(2), "field": .string("defaultPreset")])]),
            "boxes": .array([.object(["preset": .number(1), "layout": .string("*"), "box": .number(1), "field": .string("grade")])]),
            "cues": .array([.object(["listUuid": .string("a9f0"), "list": .number(42), "cue": .string("11aa"), "number": .number(3), "label": .string("Chorus")]),
                            .object(["local": .string("b1"), "list": .number(7), "cue": .string("22bb"), "number": .number(1), "label": .string("")])]),
            "macros": .array([.object(["macro": .number(2), "command": .number(0)])]),
            "keys": .array([.object(["device": .string("streamdeck:A1"), "key": .string("3")]), .object(["device": .string("scheduler"), "at": .number(4)])]),
            "machine": .array([.object(["field": .string("startupMacro")])]),
        ])]
        let read = ObjectUse.read(answer)
        XCTAssertTrue(read.more)
        XCTAssertEqual(read.uses, [.channel(2, field: "defaults.transition"), .slot(stack: 1, channel: 2, fallback: false), .stack(2, field: "defaultPreset"),
                                   .box(preset: 1, layout: "*", box: 1, field: "grade"), .cue(list: 42, number: 3, label: "Chorus", isLocal: false),
                                   .cue(list: 7, number: 1, label: "", isLocal: true), .macro(2, command: 0), .key(device: "streamdeck:A1", key: "3"),
                                   .schedule(4), .machine(field: "startupMacro")])
        let words = read.uses.map { EditModeWording.use($0, media: { $0 }) }
        XCTAssertEqual(words[3], "Preset 1, any stack, box 2")
        XCTAssertEqual(words[4], "Cue 3 in list 42 · Chorus")
        XCTAssertEqual(words[5], "Cue 1 in list 7 (local copy)")
        XCTAssertEqual(words.last, "The startup macro")
    }

    // MARK: - Text styles (Spec 11 §9, "Text styles")

    /// "the numbered styles, edited with the style form of §8 (`edit textstyle N FIELD VALUE`) ... Re-apply to Boxes
    /// copies the style's value into every one of them, as one group of `edit.set`s of each box's `textStyle`, after
    /// saying how many."
    func test_aTextStyleIsEditedAndReappliedToTheBoxesThatNameIt() throws {
        try CatalogFile.install()
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        editing.selectObject(ObjectKey(.textStyle, 1))
        editing.setTextStyle("size.value", .number(60))
        XCTAssertEqual(last(rig), ["edit textstyle 1 size.value 60"])
        // Style 1 is named by five boxes in the recorded presets.
        XCTAssertEqual(editing.styledBoxes, [.init(preset: 1, layout: "*", index: 1), .init(preset: 1, layout: "2", index: 0),
                                             .init(preset: 1, layout: "2", index: 1), .init(preset: 3, layout: "2", index: 0),
                                             .init(preset: 4, layout: "*", index: 0)])
        var asked: [Confirmation] = []
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(true)
        }
        editing.reapplyToBoxes()
        XCTAssertEqual(asked, [.reapplyStyle(name: "Text style 1 Body", boxes: 5)])
        let group = try XCTUnwrap(last(rig))
        XCTAssertEqual(group.count, 5, "one group")
        XCTAssertEqual(group.map { $0.components(separatedBy: " {").first }, [
            "edit preset 1 layouts.*.boxes.1.textStyle", "edit preset 1 layouts.2.boxes.0.textStyle", "edit preset 1 layouts.2.boxes.1.textStyle",
            "edit preset 3 layouts.2.boxes.0.textStyle", "edit preset 4 layouts.*.boxes.0.textStyle",
        ])
        XCTAssertTrue(group[0].contains("\"fromStyle\": 1"))
    }

    // MARK: - Macros (Spec 11 §9, "Macros")

    /// "Commands, in order, each a row with its plain name (Spec 10 §15) and Edit, Move Up, Move Down and Remove ...
    /// Commands as Text works as in §4."
    func test_aMacrosCommandsAreEditedRowByRowAndAsText() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        editing.selectObject(ObjectKey(.macro, 1))
        let lines = editing.macroLines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.map(\.canMoveUp), [false, true, true, true])
        XCTAssertEqual(lines.map(\.canMoveDown), [true, true, true, false])
        XCTAssertEqual(lines[0].name, "Channel 2 shows “Welcome”", "a channel write says what it shows")
        XCTAssertEqual(lines[1].name, KeyWording.plain(.timerSet(timer: 1, ms: 300_000)))
        editing.insertMacroCommand(.timerReset(timer: 1), after: 0)
        XCTAssertEqual(last(rig), ["edit macro 1 insert commands 1 { \"cmd\": \"timer.reset\", \"timer\": 1 }"])
        editing.moveMacroCommand(at: 2, up: true)
        XCTAssertEqual(last(rig), ["edit macro 1 move commands 2 1"])
        editing.moveMacroCommand(at: 0, up: true)
        XCTAssertEqual(last(rig), ["edit macro 1 move commands 2 1"], "the first can't move up")
        editing.removeMacroCommand(at: 3)
        XCTAssertEqual(last(rig), ["edit macro 1 remove commands 3"])
        editing.setMacroCommand(.timerStart(timer: 2), at: 2)
        XCTAssertEqual(last(rig)?.first?.hasPrefix("edit macro 1 commands.2 {"), true)
        // As text: a line with an error sends nothing; the same text sends nothing; a change sends the whole list.
        let macro = try XCTUnwrap(editing.selectedMacro)
        let text = CommandsText.lines(of: macro.commands).joined(separator: "\n")
        let sent = count(rig)
        XCTAssertFalse(editing.setMacroCommands(text: text + "\nnot a command"))
        XCTAssertTrue(editing.setMacroCommands(text: text))
        XCTAssertEqual(count(rig), sent)
        XCTAssertTrue(editing.setMacroCommands(text: text + "\ntimer 1 reset"))
        XCTAssertEqual(last(rig)?.first?.hasPrefix("edit macro 1 commands ["), true)
        // "Fields: the tile's color and label".
        editing.setObject("tileLabel", .string("Hello"))
        XCTAssertEqual(last(rig), ["edit macro 1 tileLabel \"Hello\""])
    }

    /// "A marker shows its scope, computed: a macro that names a stack or an output belongs to this machine".
    func test_aMacrosScopeIsComputedFromWhatItNames() throws {
        let rig = try Rig()
        let macros = try XCTUnwrap(rig.model.store.catalog?.macros)
        XCTAssertEqual(macros.map(\.isMachineLevel), [false, true], "Welcome is portable; Preshow names output 1 and stack 1")
    }

    /// "Run on Air ... sends `macro N` with source `ui`: at once while nothing is live, and after asking while
    /// something is. A macro that holds an edit says first "This also changes the library.""
    func test_runOnAirAsksWhileSomethingIsLiveOrWhenItChangesTheLibrary() throws {
        let rig = try Rig()
        let editing = rig.model.editing
        XCTAssertTrue(editing.open(page: .objects))
        var asked: [Confirmation] = []
        var yes = false
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(yes)
        }
        editing.selectObject(ObjectKey(.macro, 1))
        XCTAssertTrue(rig.model.store.live.isSomethingLive, "the recorded state has Sunday live")
        let sent = count(rig)
        editing.runMacro()
        XCTAssertEqual(asked, [.runMacro(name: "Macro 1 Welcome", live: true, edits: false)])
        XCTAssertEqual(count(rig), sent, "declined, nothing runs")
        yes = true
        editing.runMacro()
        XCTAssertEqual(last(rig), ["macro 1"])
        XCTAssertEqual(rig.sent.last?.fields["source"], .string("ui"))
        // Nothing live: at once.
        try rig.live { event in
            event["playlist"] = .null
            event["listUuid"] = .null
            event["item"] = .null
            event["cue"] = .null
        }
        XCTAssertFalse(rig.model.store.live.isSomethingLive)
        asked = []
        editing.runMacro()
        XCTAssertEqual(asked, [])
        XCTAssertEqual(last(rig), ["macro 1"])
        // A macro holding an edit asks even then.
        XCTAssertTrue(ObjectEdits.holdsEdit(Macro(number: 5, commands: [GuardedCommand(.edit(EditCommand(.numbered(.grade, 1), .set(path: "hue", value: .number(0)))))])))
        XCTAssertFalse(ObjectEdits.holdsEdit(Macro(number: 5, commands: [GuardedCommand(.macro(1))])))
    }

    /// "The preview is the easing curve drawn over the duration", as the engine eases (Spec 4 §4).
    func test_theEasingCurveIsTheEnginesEasing() {
        XCTAssertEqual(EasingCurve.value(.linear, at: 0.25), 0.25)
        XCTAssertEqual(EasingCurve.value(.easeIn, at: 0.5), 0.25)
        XCTAssertEqual(EasingCurve.value(.easeOut, at: 0.5), 0.75)
        XCTAssertEqual(EasingCurve.value(.easeInOut, at: 0.5), 0.5)
        XCTAssertEqual(EasingCurve.value(.easeInOut, at: 0.25), 0.125)
        XCTAssertEqual(EasingCurve.value(.easeInOut, at: 2), 1)
    }
}

private extension Sending {
    /// The commands in canonical text.
    var lines: [String] { commands.compactMap { CommandText.print($0) } }
}
