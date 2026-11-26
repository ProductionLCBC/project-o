// OApp — Spec 11 §9, the Objects page's selection, its edits, Used by, a grade's preview and a macro's Run on Air.

import Foundation
import OCore

/// Spec 11 §9 — what the Objects page keeps between redraws.
public struct ObjectEditorState: Equatable, Sendable {
    /// "Used by, from `uses` (§3)", and whether the answer stopped short.
    public var usedBy: [ObjectUse] = []
    public var usedMore = false
    /// "The preview is the engine's picture of a pool item through the grade beside the same item without it".
    public var graded = PreviewPicture()
    public var ungraded = PreviewPicture()
    /// "the item picked under the preview"; nil takes "at first the pool's first video or image".
    public var gradeMedia: String?
    /// Spec 11 §9 as corrected 2026-11-25 — a transition's stage: "from one pool item to another, both picked over
    /// it", nil for black, and the engine's pictures of them.
    public var transitionFrom: String??
    public var transitionTo: String??
    public var fromPicture = PreviewPicture()
    public var toPicture = PreviewPicture()
    /// A text style's sample, as typed over the stage; nil for the built-in sample.
    public var styleSample: String?
    /// Spec 11 §9 as corrected 2026-11-26 (G-43) — the values a grade's sliders or tint show while dragged or chosen,
    /// drawn in the stored grade's place until the edit sent at the end is answered; nil draws the stored grade.
    public var gradeDraft: Grade?
    /// G-43 — the time into a video both pictures are of: the scrub bar's, or the time played.
    public var gradeTimeMs = 0
    /// G-43 — "a loop switch".
    public var gradeLoop = false
    /// G-43 — while a video plays: when it started on the app's clock, and from which time.
    public var gradePlay: GradePlay?
    var pixels = 0
    var gradeAsked = 0
    var gradeSubject: [String: JSONValue]?
    var ungradedAsked = 0
    var ungradedSubject: [String: JSONValue]?
    /// The grade's canvases asked for whose answers are still to come.
    var gradeWaiting: Set<String> = []
    var usesFor: ObjectKey?
    var usesAsked = 0

    public init() {}
}

/// Spec 11 §9 as corrected 2026-11-26 (G-43) — a video played on a grade's stage: when, on the app's clock, and from
/// which time into the item.
public struct GradePlay: Equatable, Sendable {
    public var since: TimeInterval
    public var fromMs: Int
}

extension GradeParameter {
    /// The parameter's stored value in a grade.
    func value(of grade: Grade) -> Double {
        switch self {
        case .brightness: grade.brightness
        case .contrast: grade.contrast
        case .saturation: grade.saturation
        case .hue: grade.hue
        case .opacity: grade.opacity
        case .blur: grade.blur
        }
    }

    /// A grade with the parameter's stored value set.
    func set(_ stored: Double, in grade: inout Grade) {
        switch self {
        case .brightness: grade.brightness = stored
        case .contrast: grade.contrast = stored
        case .saturation: grade.saturation = stored
        case .hue: grade.hue = stored
        case .opacity: grade.opacity = stored
        case .blur: grade.blur = stored
        }
    }
}

extension EditModel {
    // MARK: - The selection (Spec 11 §9)

    public var objectsPage: ObjectsPage {
        guard let catalog = model.store.catalog else { return ObjectsPage() }
        return ObjectsPage.make(catalog: catalog, chosen: chosenObject)
    }

    /// The object chosen last, as `view.json` keeps it, whether or not it exists now.
    private var chosenObject: ObjectKey? {
        model.settings.editObjectKind.flatMap { kind in model.settings.editObject.map { ObjectKey(kind, $0) } }
    }

    public var selectedObject: ObjectKey? { objectsPage.selected }

    public func selectObject(_ key: ObjectKey) {
        guard key != chosenObject else { return }
        model.settings.editObjectKind = key.kind
        model.settings.editObject = key.number
        // G-43 — the values dragged and the video played are the grade's own.
        objectState.gradeDraft = nil
        objectState.gradePlay = nil
        model.changed([.edit])
        askObjectUses()
        askGrade()
    }

    func objectsOpened() {
        objectState.gradeSubject = nil
        objectState.ungradedSubject = nil
        objectState.gradeDraft = nil
        objectState.gradePlay = nil
        // A text style's font menu lists the `fonts` query's faces, as the preset editor's does.
        askFonts()
        askObjectUses(again: true)
        askGrade()
    }

    public var selectedGrade: Grade? {
        guard let key = selectedObject, key.kind == .grade else { return nil }
        return model.store.catalog?.grades.first { $0.number == key.number }
    }

    public var selectedTransition: LibraryTransition? {
        guard let key = selectedObject, key.kind == .transition else { return nil }
        return model.store.catalog?.transitions.first { $0.number == key.number }
    }

    public var selectedAudioTransition: AudioTransition? {
        guard let key = selectedObject, key.kind == .audioTransition else { return nil }
        return model.store.catalog?.audioTransitions.first { $0.number == key.number }
    }

    public var selectedTextStyle: TextStyle? {
        guard let key = selectedObject, key.kind == .textStyle else { return nil }
        return model.store.catalog?.textStyles.first { $0.number == key.number }
    }

    public var selectedMacro: Macro? {
        guard let key = selectedObject, key.kind == .macro else { return nil }
        return model.store.catalog?.macros.first { $0.number == key.number }
    }

    /// The selected object's label.
    public var objectLabel: String {
        guard let key = selectedObject else { return "" }
        return objectsPage.groups.first { $0.kind == key.kind }?.rows.first { $0.key == key }?.label ?? ""
    }

    // MARK: - What every object shares (Spec 11 §9)

    /// Each field's edit, one `edit.set` on commit.
    public func setObject(_ path: String, _ value: JSONValue) {
        guard let key = selectedObject else { return }
        _ = send(ObjectEdits.set(key, path, value))
    }

    /// "Each sends one `edit.set` when its drag ends": a slider's value, or its number field's, as shown. G-43 — the
    /// stage keeps the values shown until the edit is answered, then draws the grade as the engine holds it.
    public func setGrade(_ parameter: GradeParameter, shown: Double) {
        guard let grade = selectedGrade, shown.isFinite else { return }
        let stored = parameter.stored(shown)
        var draft = objectState.gradeDraft ?? grade
        parameter.set(stored, in: &draft)
        guard stored != parameter.value(of: grade) else {
            settleGradeDraft(draft, stored: grade)
            return
        }
        sendGrade(parameter.rawValue, .number(stored), draft: draft)
    }

    /// Spec 11 §9 as corrected 2026-11-26 (G-43) — "while it is dragged ... the stage draws the grade with the values
    /// shown (`render` with the grade's values, §3)": nothing is sent.
    public func previewGrade(_ parameter: GradeParameter, shown: Double) {
        guard let grade = selectedGrade, shown.isFinite else { return }
        var draft = objectState.gradeDraft ?? grade
        parameter.set(parameter.stored(shown), in: &draft)
        objectState.gradeDraft = draft
        askGrade()
    }

    /// G-43 — "and while the tint's colour panel is open".
    public func previewGradeTint(_ color: Color) {
        guard let grade = selectedGrade else { return }
        var draft = objectState.gradeDraft ?? grade
        draft.tint = color
        objectState.gradeDraft = draft
        askGrade()
    }

    /// The tint the color panel chose: one edit, as a slider's release is.
    public func setGradeTint(_ color: Color) {
        guard let grade = selectedGrade else { return }
        var draft = objectState.gradeDraft ?? grade
        draft.tint = color
        guard color != grade.tint else {
            settleGradeDraft(draft, stored: grade)
            return
        }
        sendGrade("tint", .object(["r": .number(color.r), "g": .number(color.g), "b": .number(color.b), "a": .number(color.a)]), draft: draft)
    }

    /// A value let go where it is stored: nothing to send, and the stored grade drawn once nothing else differs.
    private func settleGradeDraft(_ draft: Grade, stored: Grade) {
        objectState.gradeDraft = draft == stored ? nil : draft
        askGrade()
    }

    /// One edit of the selected grade, its values drawn meanwhile; once it is answered, applied or not, the stage
    /// draws the grade by its number, as the engine then holds it, unless another drag has moved on.
    private func sendGrade(_ path: String, _ value: JSONValue, draft: Grade) {
        guard let key = selectedObject else { return }
        objectState.gradeDraft = draft
        askGrade()
        let sent = send(ObjectEdits.set(key, path, value), answered: { [weak self] in
            guard let self, self.objectState.gradeDraft == draft else { return }
            self.objectState.gradeDraft = nil
            self.askGrade()
        })
        if sent != nil {
            // Not sent: nothing will answer it.
            objectState.gradeDraft = nil
            askGrade()
        }
    }

    /// "a + that creates one"; the new one is selected.
    public func newObject(_ kind: ObjectKind) {
        _ = send(ObjectEdits.create(kind)) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?[kind.type.editWord]?.intValue else { return }
            self?.selectObject(ObjectKey(kind, number))
        }
    }

    /// "Duplicate (the UX spec's duplicate-from)", opening the copy.
    public func duplicateObject() {
        guard let key = selectedObject else { return }
        _ = send(ObjectEdits.duplicate(key)) { [weak self] outcome in
            guard let number = outcome.applied.first?.command.objectValue?[key.kind.type.editWord]?.intValue, number != key.number else { return }
            self?.selectObject(ObjectKey(key.kind, number))
        }
    }

    /// "its number, with renumber, or swap for a taken one (Spec 5 §4)".
    public func renumberObject(to number: Int) {
        guard let key = selectedObject, let catalog = model.store.catalog else { return }
        let taken = ObjectsPage.make(catalog: catalog, chosen: nil).contains(ObjectKey(key.kind, number))
        _ = send(ObjectEdits.renumber(key, to: number, swap: taken)) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.selectObject(ObjectKey(key.kind, number))
        }
    }

    /// "Delete asks first, with the counts from `uses`: the references stay, and the reference report flags them".
    public func deleteObject() {
        guard let key = selectedObject, let sending = ObjectEdits.delete(key) else { return }
        deleteAsking(key.kind.type.editWord, key.number, name: objectName(key), always: true, sending)
    }

    /// "Grade 3 Warm", or "Grade 3" while it has no label.
    public func objectName(_ key: ObjectKey) -> String {
        let label = objectsPage.groups.first { $0.kind == key.kind }?.rows.first { $0.key == key }?.label ?? ""
        let name = EditModeWording.objectName(key.kind, key.number)
        return label.isEmpty ? name : "\(name) \(label)"
    }

    /// "Used by, from `uses` (§3)".
    func askObjectUses(again: Bool = false) {
        guard model.mode == .edit, page == .objects, let key = selectedObject, again || objectState.usesFor != key else { return }
        objectState.usesFor = key
        objectState.usesAsked += 1
        let asked = objectState.usesAsked
        let word = key.kind.type.editWord
        model.ask(.query("uses", ["object": .string(word), word: .number(Double(key.number))])) { [weak self] answer in
            guard let self, asked == self.objectState.usesAsked, let answer else { return }
            let read = ObjectUse.read(answer)
            self.objectState.usedBy = read.uses
            self.objectState.usedMore = read.more
            self.model.changed([.edit])
        }
    }

    // MARK: - Grades (Spec 11 §9, "Grades")

    /// The items a grade's preview can show: the pool's videos and images that are there.
    public var gradeMediaChoices: [MediaItem] {
        model.store.media.filter { [.video, .image].contains($0.entry.kind) && $0.presence == "ok" }
    }

    /// "the item picked under the preview, at first the pool's first video or image".
    public var gradeMedia: String? {
        let choices = gradeMediaChoices
        if let chosen = objectState.gradeMedia, choices.contains(where: { $0.id == chosen }) { return chosen }
        return choices.first?.id
    }

    public func setGradeMedia(_ id: String) {
        objectState.gradeMedia = id
        objectState.gradeTimeMs = 0
        objectState.gradePlay = nil
        model.changed([.edit])
        askGrade()
    }

    // MARK: - A video on a grade's stage (Spec 11 §9 as corrected 2026-11-26, G-43)

    /// The item's length when it is a video: "a scrub bar over the item's length"; nil for a still.
    public var gradeVideoMs: Int? {
        guard let id = gradeMedia, let item = model.store.media.first(where: { $0.id == id }), item.entry.kind == .video else { return nil }
        return item.entry.durationMs.map { max(1, $0) }
    }

    public var isGradePlaying: Bool { objectState.gradePlay != nil }

    /// "Play": from the scrub bar's time, or from the start when that is the end.
    public func playGrade() {
        guard selectedGrade != nil, let length = gradeVideoMs else { return }
        let from = objectState.gradeTimeMs >= length ? 0 : objectState.gradeTimeMs
        objectState.gradeTimeMs = from
        objectState.gradePlay = GradePlay(since: model.now, fromMs: from)
        askGrade(again: true)
        model.changed([.stage])
    }

    public func stopGrade() {
        objectState.gradePlay = nil
        model.changed([.stage])
    }

    public func setGradeLoop(_ on: Bool) {
        objectState.gradeLoop = on
        model.changed([.stage])
    }

    /// "stopped, both pictures are of the scrub bar's time": a move of it stops the video there.
    public func scrubGrade(toMs ms: Int) {
        guard let length = gradeVideoMs else { return }
        objectState.gradePlay = nil
        objectState.gradeTimeMs = min(length, max(0, ms))
        askGrade()
        model.changed([.stage])
    }

    /// "playing asks for both pictures at the time played and for the next as soon as both have come ...; at the end
    /// it stops, or with the loop on starts again".
    private func nextGradeFrame() {
        guard let play = objectState.gradePlay else { return }
        guard model.mode == .edit, page == .objects, selectedGrade != nil, let length = gradeVideoMs else {
            objectState.gradePlay = nil
            return
        }
        guard objectState.gradeWaiting.isEmpty else { return }
        var ms = play.fromMs + Int(((model.now - play.since) * 1000).rounded())
        if ms >= length {
            if objectState.gradeLoop {
                ms %= length
            } else {
                ms = length
                objectState.gradePlay = nil
            }
        }
        guard ms != objectState.gradeTimeMs || objectState.gradePlay == nil else {
            // No time has passed since the last pair: ask again a moment later.
            model.later(1.0 / 60) { [weak self] in self?.nextGradeFrame() }
            return
        }
        objectState.gradeTimeMs = ms
        askGrade(again: true)
        model.changed([.stage])
    }

    /// One of the grade's pictures has come: the next pair once both have, while playing.
    private func gradeAnswered(_ canvas: String) {
        objectState.gradeWaiting.remove(canvas)
        guard objectState.gradePlay != nil, objectState.gradeWaiting.isEmpty else { return }
        model.later(0) { [weak self] in self?.nextGradeFrame() }
    }

    /// The width each picture is asked for at.
    public func gradeWidth(_ pixels: Int) {
        let pixels = min(1920, max(160, pixels))
        guard pixels != objectState.pixels else { return }
        objectState.pixels = pixels
        askGrade()
    }

    /// The stage's two items for a transition: the ones picked, else the pool's first two videos or images; nil is black.
    public var transitionMedia: (from: String?, to: String?) {
        let ids = gradeMediaChoices.map(\.id)
        func kept(_ picked: String??, _ fallback: String?) -> String? {
            guard let picked else { return fallback }
            guard let id = picked else { return nil }
            return ids.contains(id) ? id : fallback
        }
        return (kept(objectState.transitionFrom, ids.first), kept(objectState.transitionTo, ids.dropFirst().first))
    }

    public func setTransitionMedia(from id: String?) {
        objectState.transitionFrom = .some(id)
        model.changed([.edit])
        askGrade()
    }

    public func setTransitionMedia(to id: String?) {
        objectState.transitionTo = .some(id)
        model.changed([.edit])
        askGrade()
    }

    /// The text style's sample: what was typed over the stage, else the built-in sample's body (§8).
    public var styleSampleText: String {
        objectState.styleSample ?? LayoutSample.builtIn(verse: 0)["body"] ?? ""
    }

    public func setStyleSample(_ text: String) {
        objectState.styleSample = text.isEmpty ? nil : text
        model.changed([.edit])
    }

    /// The transition's two pictures, "the engine's (`render` with `subject.kind` `grade` and `grade` null)".
    private func askTransitionPictures(again: Bool) {
        guard objectState.pixels > 0 else { return }
        let media = transitionMedia
        func request(_ canvas: String, _ id: String) -> [String: JSONValue] {
            ["canvas": .string(canvas), "subject": .object(["kind": .string("grade"), "grade": .null, "media": .string(id)]),
             "width": .number(Double(objectState.pixels))]
        }
        let key: [String: JSONValue] = ["from": media.from.map(JSONValue.string) ?? .null, "to": media.to.map(JSONValue.string) ?? .null,
                                        "width": .number(Double(objectState.pixels))]
        guard again || key != objectState.gradeSubject else { return }
        objectState.gradeSubject = key
        objectState.gradeAsked += 1
        let asked = objectState.gradeAsked
        objectState.fromPicture = PreviewPicture()
        objectState.toPicture = PreviewPicture()
        for (id, isFrom) in [(media.from, true), (media.to, false)] {
            guard let id else { continue }
            model.ask(.query("render", request(isFrom ? "from" : "to", id))) { [weak self] answer in
                guard let self, asked == self.objectState.gradeAsked, let answer, answer["superseded"] != .bool(true),
                      let file = answer["file"]?.stringValue else { return }
                let picture = PreviewPicture(file: file, width: answer["width"]?.intValue, height: answer["height"]?.intValue,
                                             isMissing: answer["missing"] == .bool(true))
                if isFrom { self.objectState.fromPicture = picture } else { self.objectState.toPicture = picture }
                self.model.changed([.edit])
            }
        }
    }

    /// "`render` with `subject.kind` `grade`, and `grade` null for the second, §3": two canvases, asked together; for a
    /// transition, its two items.
    func askGrade(again: Bool = false) {
        guard model.mode == .edit, page == .objects else { return }
        if selectedTransition != nil {
            askTransitionPictures(again: again)
            return
        }
        guard objectState.pixels > 0, let grade = selectedGrade, let media = gradeMedia else { return }
        // G-43 — a video's pictures are of the scrub bar's time, or the time played.
        let at: JSONValue? = gradeVideoMs == nil ? nil : .number(Double(objectState.gradeTimeMs))
        func request(_ canvas: String, _ grade: JSONValue) -> [String: JSONValue] {
            var subject: [String: JSONValue] = ["kind": .string("grade"), "grade": grade, "media": .string(media)]
            if let at { subject["atMs"] = at }
            return ["canvas": .string(canvas), "subject": .object(subject), "width": .number(Double(objectState.pixels))]
        }
        // G-43 — the values shown while a slider is dragged, else the grade by its number.
        let graded = request("grade", objectState.gradeDraft.map { Self.values($0) } ?? .number(Double(grade.number)))
        let plain = request("ungraded", .null)
        if again || graded != objectState.gradeSubject {
            objectState.gradeSubject = graded
            objectState.gradeAsked += 1
            let asked = objectState.gradeAsked
            objectState.gradeWaiting.insert("grade")
            model.ask(.query("render", graded)) { [weak self] answer in
                guard let self, asked == self.objectState.gradeAsked else { return }
                if let picture = Self.picture(answer) { self.objectState.graded = picture }
                self.model.changed([.stage])
                self.gradeAnswered("grade")
            }
        }
        // The item as it is changes only with the item, its time and the width.
        if again || plain != objectState.ungradedSubject {
            objectState.ungradedSubject = plain
            objectState.ungradedAsked += 1
            let asked = objectState.ungradedAsked
            objectState.gradeWaiting.insert("ungraded")
            model.ask(.query("render", plain)) { [weak self] answer in
                guard let self, asked == self.objectState.ungradedAsked else { return }
                if let picture = Self.picture(answer) { self.objectState.ungraded = picture }
                self.model.changed([.stage])
                self.gradeAnswered("ungraded")
            }
        }
    }

    /// A render's answer as a picture; nil for one superseded, refused or without a file.
    private static func picture(_ answer: [String: JSONValue]?) -> PreviewPicture? {
        guard let answer, answer["superseded"] != .bool(true), let file = answer["file"]?.stringValue else { return nil }
        return PreviewPicture(file: file, width: answer["width"]?.intValue, height: answer["height"]?.intValue, isMissing: answer["missing"] == .bool(true))
    }

    /// Spec 11 §3 as corrected 2026-11-26 (G-43) — "A grade's values (Spec 1 §2's `hue`, `saturation`, `brightness`,
    /// `contrast`, `blur`, `tint` and `opacity`)".
    static func values(_ grade: Grade) -> JSONValue {
        .object([
            "hue": .number(grade.hue), "saturation": .number(grade.saturation), "brightness": .number(grade.brightness),
            "contrast": .number(grade.contrast), "blur": .number(grade.blur), "opacity": .number(grade.opacity),
            "tint": .object(["r": .number(grade.tint.r), "g": .number(grade.tint.g), "b": .number(grade.tint.b), "a": .number(grade.tint.a)]),
        ])
    }

    // MARK: - Text styles (Spec 11 §9, "Text styles")

    /// "the style form of §8 (`edit textstyle N FIELD VALUE`)".
    public func setTextStyle(_ field: String, _ value: JSONValue) {
        setObject(field, value)
    }

    /// The boxes that name the selected style in `fromStyle`.
    public var styledBoxes: [ObjectEdits.StyledBox] {
        guard let style = selectedTextStyle, let catalog = model.store.catalog else { return [] }
        return ObjectEdits.boxes(naming: style.number, catalog: catalog)
    }

    /// "Re-apply to Boxes copies the style's value into every one of them ..., after saying how many."
    public func reapplyToBoxes() {
        guard let style = selectedTextStyle, let catalog = model.store.catalog, let sending = ObjectEdits.reapply(style, catalog: catalog),
              let key = selectedObject else { return }
        model.ask(.reapplyStyle(name: objectName(key), boxes: sending.commands.count)) { [weak self] in _ = self?.send(sending) }
    }

    // MARK: - Macros (Spec 11 §9, "Macros")

    public func insertMacroCommand(_ command: Command, after position: Int?) {
        guard let macro = selectedMacro else { return }
        _ = send(ObjectEdits.insert(command, after: position, macro: macro))
    }

    public func setMacroCommand(_ command: Command, at position: Int) {
        guard let macro = selectedMacro else { return }
        _ = send(ObjectEdits.setCommand(command, at: position, macro: macro))
    }

    public func removeMacroCommand(at position: Int) {
        guard let macro = selectedMacro else { return }
        _ = send(ObjectEdits.removeCommand(at: position, macro: macro))
    }

    public func moveMacroCommand(at position: Int, up: Bool) {
        guard let macro = selectedMacro else { return }
        _ = send(ObjectEdits.moveCommand(at: position, up: up, macro: macro))
    }

    /// Commands as text commits; false while a line has an error, when nothing is sent.
    @discardableResult
    public func setMacroCommands(text: String) -> Bool {
        guard let macro = selectedMacro else { return true }
        if !CommandsText.parse(text, commands: macro.commands, options: parseOptions).errors.isEmpty { return false }
        _ = send(ObjectEdits.commands(text, macro: macro, options: parseOptions))
        return true
    }

    /// The macro's rows: "each a row with its plain name (Spec 10 §15) and Edit, Move Up, Move Down and Remove".
    public var macroLines: [CueCommandLine] {
        guard let macro = selectedMacro, let catalog = model.store.catalog else { return [] }
        let media = model.store.media
        return macro.commands.enumerated().map { index, entry in
            let command = entry.command
            let kept = command.isUnknown || command.isInvalid
            let warning = MacroCheck.warning(command, in: macro.number, catalog: catalog, media: media)
            return CueCommandLine(position: index, name: kept ? command.cmd : macroCommandName(command), warning: warning,
                                  canEdit: !kept, canMoveUp: index > 0, canMoveDown: index < macro.commands.count - 1)
        }
    }

    /// A command's plain name (Spec 10 §15); a channel write, which a cue shows in its grid, says what it shows here.
    private func macroCommandName(_ command: Command) -> String {
        guard case .channelWrite(let write) = command, case .number(let channel) = write.channel else { return KeyWording.plain(command) }
        switch write.content {
        case .media(let media):
            let name = model.store.media.first { $0.id == media.ref }.map { ($0.entry.path as NSString).lastPathComponent } ?? media.ref
            return Strings.text(.editObjectWriteMedia, channel, name)
        case .text(let fields):
            let body = fields["body"] ?? fields.keys.sorted().first.flatMap { fields[$0] } ?? ""
            return Strings.text(.editObjectWriteText, channel, body.components(separatedBy: "\n").first ?? body)
        default:
            return KeyWording.plain(command)
        }
    }

    /// "Run on Air (choice A-10) ... sends `macro N` with source `ui`: at once while nothing is live, and after asking
    /// while something is. A macro that holds an edit says first "This also changes the library."" The view commits
    /// an open field before it calls this.
    public func runMacro() {
        guard let macro = selectedMacro, let key = selectedObject else { return }
        let live = model.store.live.isSomethingLive
        let edits = ObjectEdits.holdsEdit(macro)
        let run: @MainActor () -> Void = { [weak self] in _ = self?.model.send(Actions.macro(macro.number)) }
        guard live || edits else {
            run()
            return
        }
        model.ask(.runMacro(name: objectName(key), live: live, edits: edits), then: run)
    }
}
