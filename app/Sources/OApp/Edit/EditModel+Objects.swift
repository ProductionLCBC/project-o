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
    var pixels = 0
    var gradeAsked = 0
    var gradeSubject: [String: JSONValue]?
    var usesFor: ObjectKey?
    var usesAsked = 0

    public init() {}
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
        model.changed([.edit])
        askObjectUses()
        askGrade()
    }

    func objectsOpened() {
        objectState.gradeSubject = nil
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

    /// "Each sends one `edit.set` when its drag ends": a slider's value, or its number field's, as shown.
    public func setGrade(_ parameter: GradeParameter, shown: Double) {
        guard let grade = selectedGrade, shown.isFinite else { return }
        let stored = parameter.stored(shown)
        let current: Double
        switch parameter {
        case .brightness: current = grade.brightness
        case .contrast: current = grade.contrast
        case .saturation: current = grade.saturation
        case .hue: current = grade.hue
        case .opacity: current = grade.opacity
        case .blur: current = grade.blur
        }
        guard stored != current else { return }
        setObject(parameter.rawValue, .number(stored))
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
        model.changed([.edit])
        askGrade()
    }

    /// The width each picture is asked for at.
    public func gradeWidth(_ pixels: Int) {
        let pixels = min(1920, max(160, pixels))
        guard pixels != objectState.pixels else { return }
        objectState.pixels = pixels
        askGrade()
    }

    /// "`render` with `subject.kind` `grade`, and `grade` null for the second, §3": two canvases, asked together.
    func askGrade(again: Bool = false) {
        guard model.mode == .edit, page == .objects, objectState.pixels > 0, let grade = selectedGrade, let media = gradeMedia else { return }
        func request(_ canvas: String, _ grade: JSONValue) -> [String: JSONValue] {
            ["canvas": .string(canvas), "subject": .object(["kind": .string("grade"), "grade": grade, "media": .string(media)]),
             "width": .number(Double(objectState.pixels))]
        }
        let graded = request("grade", .number(Double(grade.number)))
        guard again || graded != objectState.gradeSubject else { return }
        objectState.gradeSubject = graded
        objectState.gradeAsked += 1
        let asked = objectState.gradeAsked
        for (subject, isGraded) in [(graded, true), (request("ungraded", .null), false)] {
            model.ask(.query("render", subject)) { [weak self] answer in
                guard let self, asked == self.objectState.gradeAsked, let answer, answer["superseded"] != .bool(true),
                      let file = answer["file"]?.stringValue else { return }
                let picture = PreviewPicture(file: file, width: answer["width"]?.intValue, height: answer["height"]?.intValue,
                                             isMissing: answer["missing"] == .bool(true))
                if isGraded { self.objectState.graded = picture } else { self.objectState.ungraded = picture }
                self.model.changed([.edit])
            }
        }
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
        guard let macro = selectedMacro else { return [] }
        return macro.commands.enumerated().map { index, entry in
            let command = entry.command
            let kept = command.isUnknown || command.isInvalid
            var warning: CueCommandLine.Warning?
            if kept { warning = .keptVerbatim } else if case .edit = command { warning = .changesLibrary }
            return CueCommandLine(position: index, name: kept ? command.cmd : KeyWording.plain(command), warning: warning,
                                  canEdit: !kept, canMoveUp: index > 0, canMoveDown: index < macro.commands.count - 1)
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
