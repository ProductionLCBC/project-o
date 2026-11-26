// OAppUI — Spec 11 §9, the small editors: the Objects page's workspace, the selected object's own editor in one tall
// column and beside it what every object shares; the grade's sliders, the easing curve and a macro's commands.

import AppKit
import OApp
import OCore

/// Spec 11 §9 — the Objects page's workspace: "The rest of the center edits the selected object; the right column holds
/// what every object shares". The objects themselves are the page's list (PageListView), in their groups.
@MainActor
final class ObjectWorkspaceView: NSView {
    private let model: ShowModel
    weak var host: ShowWindowView? { didSet { commands.host = host } }
    /// The object's own editor, one tall column.
    let editor = FormColumn()
    let heading = Kit.heading("")
    let selectNote = Kit.label(Strings.text(.editObjectSelectOne), size: 12, color: Palette.faintText)
    // Grades.
    private(set) var sliders: [GradeParameter: GradeSlider] = [:]
    private(set) var gradeFields: [GradeParameter: EditField] = [:]
    let tint = FormColorWell(label: Strings.text(.editGradeTint))
    // Transitions and audio transitions.
    let transitionType = Kit.label(size: 12)
    let audioType = ChoicePopUp(label: Strings.text(.editObjectType))
    let ms = EditField()
    let easing = ChoicePopUp(label: Strings.text(.editObjectEasing))
    let transitionColor = FormColorWell(label: Strings.text(.editObjectColor))
    let offset = EditField()
    let offsetNote = Kit.label(Strings.text(.editObjectOffsetNote), size: 11, color: Palette.faintText)
    // Text styles.
    let style = StyleForm()
    // Macros.
    let runOnAir = FlatButton(Strings.text(.editObjectRunOnAir), style: .plain)
    let scope = Kit.label(size: 11.5, color: Palette.dimText)
    let commands: MacroCommandsView
    let tileHeading = Kit.heading(Strings.text(.editObjectTileHeading))
    let tileColor = FormColorWell(label: Strings.text(.editObjectTileColor))
    let tileLabel = EditField()
    /// What every object shares.
    let shared = FormColumn()
    let sharedHeading = Kit.heading(Strings.text(.editObjectShared))
    let number = EditField()
    let fixedNote = Kit.label(Strings.text(.editObjectFixed), size: 11, color: Palette.faintText)
    let label = EditField()
    let styleBoxes = Kit.label(size: 11.5, color: Palette.dimText)
    let reapply = FlatButton(Strings.text(.editObjectReapply), style: .plain)
    let usedHeading = Kit.heading(Strings.text(.editObjectUsedBy))
    let usedBy = Kit.label(size: 11.5, color: Palette.text)
    /// The field committed last: outlined in red while the engine's refusal of it stands (Spec 11 §2).
    private weak var lastField: EditField?

    static let easings: [Easing] = [.linear, .easeIn, .easeOut, .easeInOut]
    static let audioTypes: [AudioTransitionType] = [.cut, .crossfade, .fadeThroughSilence]

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        commands = MacroCommandsView(model: model)
        super.init(frame: .zero)
        buildEditor()
        buildShared()
        addSubview(editor.scroll)
        addSubview(shared.scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func wrap(_ note: NSTextField) {
        note.maximumNumberOfLines = 0
        note.lineBreakMode = .byWordWrapping
        note.cell?.wraps = true
    }

    /// A field that sends a number, parsed; anything else is put back.
    private func numeric(_ field: EditField, _ label: String, _ send: @escaping (Double) -> Void) {
        field.setAccessibilityLabel(label)
        field.onCommit = { [weak self, weak field] text in
            guard let self, let field else { return }
            self.lastField = field
            if let value = FormNumber.value(text) { send(value) } else {
                field.putBack()
                self.refresh()
            }
        }
    }

    private func buildEditor() {
        let c = editor
        c.nameShare = 0.3
        c.wide(heading, height: 14)
        wrap(selectNote)
        c.wide(selectNote, height: 34)
        // "Each parameter is a slider with a number field and its identity marked".
        for parameter in GradeParameter.allCases {
            let slider = GradeSlider(parameter)
            slider.onRelease = { [weak model] value in model?.editing.setGrade(parameter, shown: value) }
            let field = EditField()
            numeric(field, EditModeWording.parameter(parameter)) { [weak model] value in model?.editing.setGrade(parameter, shown: value) }
            sliders[parameter] = slider
            gradeFields[parameter] = field
            c.row(EditModeWording.parameter(parameter), [slider, field], widths: [nil, 64], height: 24)
        }
        // "tint, a colour well (white is identity)".
        tint.onChoose = { [weak model] picked in model?.editing.setObject("tint", FormColor.value(picked)) }
        tint.toolTip = Strings.text(.editGradeIdentity, "white")
        c.row(Strings.text(.editGradeTint), [tint], widths: [44], height: 24)
        // "Their duration (`ms`) and easing can be edited; their type and colour stay as built"; an audio transition's
        // type is "picked from cut, crossfade and fade through silence".
        audioType.onChoose = { [weak model] tag in
            guard Self.audioTypes.indices.contains(tag) else { return }
            model?.editing.setObject("type", .string(Self.audioTypes[tag].rawValue))
        }
        c.row(Strings.text(.editObjectType), [transitionType, audioType], height: 24)
        numeric(ms, Strings.text(.editObjectDuration)) { [weak model] value in model?.editing.setObject("ms", .number(max(0, value.rounded()))) }
        c.row(Strings.text(.editObjectDuration), [ms], widths: [80], height: 26)
        easing.onChoose = { [weak model] tag in
            guard Self.easings.indices.contains(tag) else { return }
            model?.editing.setObject("easing", .string(Self.easings[tag].rawValue))
        }
        c.row(Strings.text(.editObjectEasing), [easing], height: 24)
        transitionColor.isEnabled = false
        c.row(Strings.text(.editObjectColor), [transitionColor], widths: [44], height: 24)
        // "the offset, signed and measured from the trigger, that makes J and L cuts".
        numeric(offset, Strings.text(.editObjectOffset)) { [weak model] value in
            model?.editing.setObject("offsetMs", .number(min(1000, max(-1000, value.rounded()))))
        }
        c.row(Strings.text(.editObjectOffset), [offset], widths: [80], height: 26)
        wrap(offsetNote)
        c.wide(offsetNote, height: 30)
        // Text styles: "the style form of §8".
        style.onSet = { [weak model] field, value in model?.editing.setTextStyle(field, value) }
        style.onCommit = { [weak self] field in self?.lastField = field }
        style.onPutBack = { [weak self] in self?.refresh() }
        style.addRows(to: c)
        // Macros: Run on Air, the scope, the commands, then the tile.
        runOnAir.fontSize = 12
        runOnAir.onPress = { [weak self] in
            // "commits an open field first".
            self?.window?.makeFirstResponder(nil)
            self?.model.editing.runMacro()
        }
        c.row(nil, [runOnAir], widths: [max(140, runOnAir.fitting.width + 8)], height: 26)
        wrap(scope)
        c.wide(scope, height: 30)
        c.wide(commands, height: 60)
        commands.onResize = { [weak self] in self?.refresh() }
        c.wide(tileHeading, height: 14)
        tileColor.onChoose = { [weak model] picked in model?.editing.setObject("color", FormColor.value(picked)) }
        c.row(Strings.text(.editObjectTileColor), [tileColor], widths: [44], height: 24)
        tileLabel.setAccessibilityLabel(Strings.text(.editObjectTileLabel))
        tileLabel.onCommit = { [weak self] text in
            self?.lastField = self?.tileLabel
            self?.model.editing.setObject("tileLabel", .string(text))
        }
        c.row(Strings.text(.editObjectTileLabel), [tileLabel], height: 26)
    }

    private func buildShared() {
        let c = shared
        c.wide(sharedHeading, height: 14)
        number.setAccessibilityLabel(Strings.text(.editObjectNumber))
        number.onCommit = { [weak self] text in
            guard let self else { return }
            self.lastField = self.number
            if let value = Int(text.trimmingCharacters(in: .whitespaces)), value >= 1 { self.model.editing.renumberObject(to: value) } else { self.number.putBack() }
            self.refresh()
        }
        c.row(Strings.text(.editObjectNumber), [number], widths: [70], height: 26)
        wrap(fixedNote)
        c.wide(fixedNote, height: 44)
        label.setAccessibilityLabel(Strings.text(.editFieldLabel))
        label.onCommit = { [weak self] text in
            self?.lastField = self?.label
            self?.model.editing.setObject("label", .string(text))
        }
        c.row(Strings.text(.editFieldLabel), [label], height: 26)
        wrap(styleBoxes)
        c.wide(styleBoxes, height: 18)
        reapply.fontSize = 11.5
        reapply.onPress = { [weak model] in model?.editing.reapplyToBoxes() }
        c.row(nil, [reapply], widths: [max(150, reapply.fitting.width + 8)], height: 24)
        c.wide(usedHeading, height: 14)
        wrap(usedBy)
        c.wide(usedBy, height: 18)
    }

    // MARK: - Showing the model

    func refresh() {
        let editing = model.editing
        let key = editing.selectedObject
        var refused = false
        if case .rejected? = editing.notice { refused = true }
        for field in [number, label, ms, offset, tileLabel] + Array(gradeFields.values) + style.fields { field.isRefused = refused && field === lastField }
        let kind = key?.kind
        selectNote.isHidden = key != nil
        heading.isHidden = key == nil
        let subject = AnyHashable(key.map { "\($0.kind.rawValue)-\($0.number)" } ?? "")
        // Grades.
        let grade = editing.selectedGrade
        for parameter in GradeParameter.allCases {
            sliders[parameter]?.isHidden = grade == nil
            gradeFields[parameter]?.isHidden = grade == nil
            guard let grade else { continue }
            let value = parameter.shown(grade)
            sliders[parameter]?.show(value)
            gradeFields[parameter]?.show(FormNumber.text(value, places: 1), subject: subject)
        }
        tint.isHidden = grade == nil
        // "white is identity": a clear tint does nothing, as white does.
        if let grade { tint.color = grade.tint.a == 0 ? .white : FormColor.ns(grade.tint) }
        // Transitions and audio transitions.
        let transition = editing.selectedTransition
        let audio = editing.selectedAudioTransition
        transitionType.isHidden = transition == nil
        audioType.isHidden = audio == nil
        ms.isHidden = transition == nil && audio == nil
        easing.isHidden = ms.isHidden
        transitionColor.isHidden = transition?.type != .fadeThroughColor
        offset.isHidden = audio == nil
        offsetNote.isHidden = audio == nil
        let easings = Self.easings.enumerated().map { (EditModeWording.easing($0.element), $0.offset) }
        if let transition {
            transitionType.stringValue = EditModeWording.transitionType(transition.type)
            ms.show(String(transition.ms), subject: subject)
            easing.set(easings, selected: Self.easings.firstIndex(of: transition.easing) ?? 0)
            if let color = transition.color { transitionColor.color = FormColor.ns(color) }
        }
        if let audio {
            audioType.set(Self.audioTypes.enumerated().map { (EditModeWording.audioTransitionType($0.element), $0.offset) },
                          selected: Self.audioTypes.firstIndex(of: audio.type) ?? 0)
            ms.show(String(audio.ms), subject: subject)
            easing.set(easings, selected: Self.easings.firstIndex(of: audio.easing) ?? 0)
            offset.show(String(audio.offsetMs), subject: subject)
        }
        // Text styles.
        let textStyle = editing.selectedTextStyle
        style.setHidden(textStyle == nil)
        if let textStyle { style.show(textStyle.values, subject: subject, fonts: editing.presetState.fonts) }
        // Macros.
        let macro = editing.selectedMacro
        for view in [runOnAir, scope, commands, tileHeading, tileColor, tileLabel] as [NSView] { view.isHidden = macro == nil }
        if let macro {
            // "A marker shows its scope, computed".
            scope.stringValue = Strings.text(macro.isMachineLevel ? .editObjectScopeMachine : .editObjectScopeLibrary)
            tileColor.color = FormColor.ns(macro.color)
            tileLabel.show(macro.tileLabel, subject: subject)
            runOnAir.isEnabled = model.store.cannotSend == nil
            runOnAir.reason = ShowWording.unavailable(model.store.cannotSend)
            commands.refresh()
            editor.setHeight(commands.wantedHeight, of: commands)
        }
        if let kind {
            switch kind {
            case .grade: Kit.setHeading(heading, Strings.text(.editObjectGradeHeading))
            case .transition: Kit.setHeading(heading, Strings.text(.editObjectTransitionHeading))
            case .audioTransition: Kit.setHeading(heading, Strings.text(.editObjectAudioHeading))
            case .textStyle: Kit.setHeading(heading, Strings.text(.editObjectStyleHeading))
            case .macro: Kit.setHeading(heading, Strings.text(.editObjectMacroHeading))
            }
        }
        refreshShared(key)
        editor.needsLayout = true
        shared.needsLayout = true
        needsLayout = true
    }

    private func refreshShared(_ key: ObjectKey?) {
        let editing = model.editing
        for view in [sharedHeading, number, label, usedHeading, usedBy] as [NSView] { view.isHidden = key == nil }
        guard let key else {
            for view in [fixedNote, styleBoxes, reapply] as [NSView] { view.isHidden = true }
            return
        }
        let subject = AnyHashable("\(key.kind.rawValue)-\(key.number)")
        number.show(String(key.number), placeholder: String(key.number), subject: subject)
        // "Transitions ... can't be renumbered or swapped (Spec 5 §6)."
        number.isEnabled = !key.kind.isFixed
        fixedNote.isHidden = !key.kind.isFixed
        label.show(editing.objectLabel, placeholder: EditModeWording.objectName(key.kind, key.number), subject: subject)
        // Text styles: "Re-apply to Boxes ..., after saying how many".
        let boxes = key.kind == .textStyle ? editing.styledBoxes.count : 0
        styleBoxes.isHidden = key.kind != .textStyle
        reapply.isHidden = key.kind != .textStyle
        styleBoxes.stringValue = Strings.counted(.editObjectStyleBoxes, boxes)
        reapply.isEnabled = boxes > 0
        // "Used by, from `uses` (§3)".
        let media = model.store.media
        var lines = editing.objectState.usedBy.map { use in
            EditModeWording.use(use, media: { id in media.first { $0.id == id }.map { ($0.entry.path as NSString).lastPathComponent } ?? id })
        }
        if editing.objectState.usedMore { lines.append(Strings.text(.editObjectUsedMore)) }
        usedBy.stringValue = lines.isEmpty ? Strings.text(.editObjectUsedNone) : lines.joined(separator: "\n")
        usedBy.textColor = lines.isEmpty ? Palette.faintText : Palette.text
        shared.setHeight(CGFloat(max(1, lines.count)) * 17 + 2, of: usedBy)
    }

    /// The editor's column: as wide as its fields want, the shared column taking the rest.
    private var editorWidth: CGFloat { max(360, min(600, bounds.width * 0.62)) }

    override func layout() {
        super.layout()
        guard bounds.width > 120 else { return }
        editor.scroll.frame = NSRect(x: 0, y: 0, width: editorWidth, height: bounds.height)
        editor.place()
        shared.scroll.frame = NSRect(x: editorWidth + 1, y: 0, width: max(0, bounds.width - editorWidth - 1), height: bounds.height)
        shared.place()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The line between the object's editor and what every object shares.
        Palette.hairline.setFill()
        NSRect(x: editorWidth, y: 10, width: 1, height: max(0, bounds.height - 20)).fill()
    }
}

/// Spec 11 §9, "Grades" — a parameter's slider, "its identity marked": a tick under the track where it does nothing.
/// "Each sends one `edit.set` when its drag ends", so the slider says its value only when it is let go.
@MainActor
final class GradeSlider: NSSlider {
    let parameter: GradeParameter
    var onRelease: ((Double) -> Void)?

    init(_ parameter: GradeParameter) {
        self.parameter = parameter
        super.init(frame: .zero)
        minValue = parameter.range.lowerBound
        maxValue = parameter.range.upperBound
        doubleValue = parameter.identity
        isContinuous = false
        controlSize = .small
        target = self
        action = #selector(released)
        setAccessibilityLabel(EditModeWording.parameter(parameter))
        toolTip = Strings.text(.editGradeIdentity, EditModeWording.shown(parameter.identity, of: parameter))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func released() { onRelease?(doubleValue) }

    func show(_ value: Double) {
        doubleValue = value
        setAccessibilityValueDescription(EditModeWording.shown(value, of: parameter))
    }

    /// Lets go at a value, as a drag would end.
    func release(at value: Double) {
        doubleValue = value
        released()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let knob = (cell as? NSSliderCell)?.knobThickness ?? 14
        let span = max(0, bounds.width - knob)
        let share = (parameter.identity - minValue) / max(1e-9, maxValue - minValue)
        let x = (knob / 2 + span * share).rounded() - 0.5
        Palette.dimText.setFill()
        NSRect(x: x, y: bounds.maxY - 4, width: 1, height: 4).fill()
    }
}

/// Spec 11 §9, "Transitions" — "The preview is the easing curve drawn over the duration"; for an audio transition the
/// curve starts at its offset from the trigger, which a line marks.
@MainActor
final class EasingCurveView: NSView {
    var easing = Easing.linear { didSet { needsDisplay = true } }
    var ms = 0 { didSet { needsDisplay = true } }
    var offsetMs = 0 { didSet { needsDisplay = true } }
    let caption = Kit.label(size: 11.5, color: Palette.dimText)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        caption.alignment = .center
        addSubview(caption)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(easing: Easing, ms: Int, offsetMs: Int = 0) {
        self.easing = easing
        self.ms = ms
        self.offsetMs = offsetMs
        caption.stringValue = Strings.text(.editObjectPreviewCurve, EditModeWording.easing(easing), SecondsText.text(ms: ms) + " s")
        setAccessibilityLabel(caption.stringValue)
    }

    override func layout() {
        super.layout()
        caption.frame = NSRect(x: 8, y: bounds.height - 22, width: max(0, bounds.width - 16), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 18, y: 14, width: max(0, bounds.width - 36), height: max(0, bounds.height - 48))
        guard plot.width > 10, plot.height > 10 else { return }
        Palette.hairline.setStroke()
        let frame = NSBezierPath(rect: plot.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()
        // Time runs from the earlier of the trigger and the start to the later of the trigger and the end.
        let start = min(0, offsetMs)
        let end = max(max(1, ms) + offsetMs, 0, 1)
        let span = Double(max(1, end - start))
        func x(_ t: Int) -> CGFloat { plot.minX + plot.width * CGFloat(Double(t - start) / span) }
        if offsetMs != 0 {
            // The trigger.
            Palette.browsing.setStroke()
            let trigger = NSBezierPath()
            trigger.move(to: NSPoint(x: x(0), y: plot.minY))
            trigger.line(to: NSPoint(x: x(0), y: plot.maxY))
            trigger.lineWidth = 1
            trigger.setLineDash([3, 3], count: 2, phase: 0)
            trigger.stroke()
        }
        Palette.selection.setStroke()
        let curve = NSBezierPath()
        let from = x(offsetMs)
        let to = x(offsetMs + max(1, ms))
        let steps = 48
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let point = NSPoint(x: from + (to - from) * CGFloat(t), y: plot.maxY - plot.height * CGFloat(EasingCurve.value(easing, at: t)))
            if step == 0 { curve.move(to: point) } else { curve.line(to: point) }
        }
        if to < plot.maxX { curve.line(to: NSPoint(x: plot.maxX, y: plot.minY)) }
        curve.lineWidth = 2
        curve.stroke()
    }
}

/// Spec 11 §9, "Macros" — "Commands, in order, each a row with its plain name (Spec 10 §15) and Edit, Move Up, Move Down
/// and Remove, built with the cue inspector's palette (§4) ... Commands as Text works as in §4."
@MainActor
final class MacroCommandsView: NSView, NSTextViewDelegate {
    private let model: ShowModel
    weak var host: ShowWindowView?
    private(set) var rows: [CommandRowView] = []
    let none = Kit.label(Strings.text(.editObjectNoCommands), size: 12, color: Palette.faintText)
    let addCommand = FlatButton(Strings.text(.editCommandsAdd), style: .bare)
    let asTextName = Kit.label(Strings.text(.editCommandsAsText), size: 12, color: Palette.dimText)
    let asText = NSSwitch()
    let textArea = CommandsTextView()
    private let textScroll = NSScrollView()
    let textErrors = Kit.label(size: 11, color: Palette.live)
    private(set) var showsText = false
    /// The macro the text area holds.
    private var textMacro: Int?

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        addCommand.leading = true
        addCommand.chevron = false
        addCommand.fontSize = 12
        addCommand.onPress = { [weak self] in self?.showPalette() }
        asText.controlSize = .small
        asText.target = self
        asText.action = #selector(toggledText)
        asText.setAccessibilityLabel(Strings.text(.editCommandsAsText))
        textArea.delegate = self
        textArea.onCommit = { [weak self] in _ = self?.commitText() }
        textArea.onDiscard = { [weak self] in self?.loadText() }
        textScroll.documentView = textArea
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.backgroundColor = Palette.well
        textScroll.borderType = .noBorder
        textErrors.maximumNumberOfLines = 0
        textErrors.lineBreakMode = .byWordWrapping
        textErrors.cell?.wraps = true
        for view in [none, addCommand, asTextName, asText, textScroll, textErrors] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The rows', the + row's and the switch's height, or the text area's.
    var wantedHeight: CGFloat {
        if showsText { return 26 + 180 + (textErrors.stringValue.isEmpty ? 0 : 40) }
        let lines = rows.reduce(0) { $0 + $1.wantedHeight + 4 }
        return 26 + (rows.isEmpty ? 22 : lines) + 34
    }

    func refresh() {
        let editing = model.editing
        let lines = editing.macroLines
        if editing.selectedMacro?.number != textMacro, showsText {
            showsText = false
            textMacro = nil
        }
        for row in rows { row.removeFromSuperview() }
        rows = lines.map { line in
            let row = CommandRowView(line)
            row.makeMenu = { [weak self, weak row] in
                guard let self, let row else { return nil }
                return self.menu(for: line, at: row.more)
            }
            addSubview(row)
            return row
        }
        none.isHidden = !lines.isEmpty || showsText
        for row in rows { row.isHidden = showsText }
        addCommand.isHidden = showsText
        addCommand.isEnabled = model.store.cannotEdit(master: true) == nil
        textScroll.isHidden = !showsText
        textErrors.isHidden = !showsText || textErrors.stringValue.isEmpty
        asText.state = showsText ? .on : .off
        needsLayout = true
    }

    /// "Add Command" with the palette, the Channels group in it: after the row last clicked, or at the end.
    private func showPalette() {
        let after = rows.first(where: \.isChosen)?.line.position
        let menu = EditPopovers.palette(model: model, after: after, insert: { [weak model] command in
            model?.editing.insertMacroCommand(command, after: after)
        }, channelGroup: true) { [weak self] panel in
            guard let self else { return }
            self.host?.present(panel, at: self.addCommand)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addCommand.bounds.height + 2), in: addCommand)
    }

    /// The palette as it stands, for a test.
    var paletteNow: NSMenu {
        EditPopovers.palette(model: model, after: nil, insert: { [weak model] command in model?.editing.insertMacroCommand(command, after: nil) },
                             channelGroup: true) { _ in }
    }

    private func menu(for line: CueCommandLine, at anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ key: StringKey, _ enabled: Bool, _ run: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: Strings.text(key), run)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(.editMenuEdit, line.canEdit) { [weak self, weak anchor] in
            guard let self, let macro = self.model.editing.selectedMacro, macro.commands.indices.contains(line.position) else { return }
            let panel = EditPopovers.command(heading: line.name, command: macro.commands[line.position].command,
                                             options: self.model.editing.parseOptions) { [weak self] command in
                self?.model.editing.setMacroCommand(command, at: line.position)
            }
            self.host?.present(panel, at: anchor ?? self)
        }
        add(.editMenuMoveUp, line.canMoveUp) { [weak model] in model?.editing.moveMacroCommand(at: line.position, up: true) }
        add(.editMenuMoveDown, line.canMoveDown) { [weak model] in model?.editing.moveMacroCommand(at: line.position, up: false) }
        add(.editMenuRemove, true) { [weak model] in model?.editing.removeMacroCommand(at: line.position) }
        return menu
    }

    // MARK: - Commands as text (Spec 11 §4)

    @objc private func toggledText() {
        if asText.state == .on {
            showsText = true
            loadText()
        } else if commitText() {
            showsText = false
            textMacro = nil
        } else {
            asText.state = .on
            askAboutText()
        }
        refresh()
        onResize?()
    }

    /// The rows or the text area changed height: the workspace places its column again.
    var onResize: (() -> Void)?

    func loadText() {
        guard let macro = model.editing.selectedMacro else { return }
        textMacro = macro.number
        textArea.string = CommandsText.lines(of: macro.commands).joined(separator: "\n")
        checkText()
    }

    /// "parsed as it is typed with OCore's parser (Spec 2 §4), each error beside its line".
    private func checkText() {
        guard let macro = model.editing.selectedMacro, macro.number == textMacro else {
            textErrors.stringValue = ""
            return
        }
        let parsed = CommandsText.parse(textArea.string, commands: macro.commands, options: model.editing.parseOptions)
        textErrors.stringValue = parsed.errors.keys.sorted().compactMap { line in
            parsed.errors[line].map { Strings.text(.editCommandsError, line + 1, $0) }
        }.joined(separator: "\n")
        textErrors.isHidden = textErrors.stringValue.isEmpty
        needsLayout = true
    }

    func textDidChange(_ notification: Notification) { checkText() }

    func textDidEndEditing(_ notification: Notification) {
        if !commitText() { askAboutText() }
    }

    /// "⌘Return, or leaving the area, sends one `edit.set` of ... `commands` with the parsed list, but only while no
    /// line has an error".
    @discardableResult
    func commitText() -> Bool {
        guard showsText, model.editing.selectedMacro?.number == textMacro else { return true }
        return model.editing.setMacroCommands(text: textArea.string)
    }

    /// "leaving asks Keep Editing or Discard Changes, Discard never the default."
    private func askAboutText() {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = Strings.text(.editCommandsErrorsTitle)
        alert.informativeText = textErrors.stringValue
        alert.addButton(withTitle: Strings.text(.editCommandsKeepEditing))
        alert.addButton(withTitle: Strings.text(.editCommandsDiscard))
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .alertSecondButtonReturn { self.loadText() } else { self.window?.makeFirstResponder(self.textArea) }
            }
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let switchSize = asText.intrinsicContentSize
        asText.frame = NSRect(x: width - switchSize.width, y: 0, width: switchSize.width, height: switchSize.height)
        asTextName.frame = NSRect(x: 0, y: 2, width: max(0, asText.frame.minX - 8), height: 16)
        var y: CGFloat = 26
        if showsText {
            textScroll.frame = NSRect(x: 0, y: y, width: width, height: 176)
            textArea.frame.size.width = textScroll.contentSize.width
            textErrors.frame = NSRect(x: 0, y: y + 180, width: width, height: 36)
            return
        }
        none.frame = NSRect(x: 0, y: y + 2, width: width, height: 16)
        if rows.isEmpty { y += 22 }
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: width, height: row.wantedHeight)
            y += row.wantedHeight + 4
        }
        addCommand.frame = NSRect(x: -10, y: y + 2, width: width + 10, height: 28)
    }
}
