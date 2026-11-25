// OAppUI — Spec 11 §4, "The inspector": the selected cue in four columns, under its header.

import AppKit
import OApp
import OCore

/// A field of edit mode's: Spec 11 §1 — "Fields commit on Return or when
/// they lose focus"; Escape "discards what was typed and leaves the field"
/// (Spec 10 §9), as in any field that edits.
@MainActor
final class EditField: ShowField {
    var onCommit: ((String) -> Void)?

    override class var cellClass: AnyClass? {
        get { CenteredFieldCell.self }
        set {}
    }

    /// A field that edits commits on Return and when it loses the focus;
    /// one that acts, as the go-to field does, acts on Return alone.
    init(kind: FieldKind = .edit, commitsOnLeave: Bool = true) {
        super.init(kind: kind)
        (cell as? NSTextFieldCell)?.sendsActionOnEndEditing = commitsOnLeave
        (cell as? NSTextFieldCell)?.allowsUndo = true
        font = .systemFont(ofSize: 12)
        isBordered = false
        drawsBackground = true
        backgroundColor = Palette.well
        textColor = Palette.text
        focusRingType = .default
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        layer?.borderColor = Palette.hairline.cgColor
        target = self
        action = #selector(committed)
    }

    /// The model's value last shown, or the text last sent: a commit with
    /// nothing typed since (the focus leaving after Return) sends nothing.
    private var shown = ""
    /// Text sent and not yet seen back from the engine: a redraw before the
    /// answer keeps it, so the old value never shows, nor is sent back.
    private var pending: String?
    /// What the field edits (the selected cues): another subject drops `pending`.
    private var subject: AnyHashable?

    @objc private func committed() {
        let text = stringValue
        guard text != shown else { return }
        shown = text
        pending = text
        onCommit?(text)
    }

    /// Shows the model's value, unless the cursor is in the field: "a field
    /// that has the focus ... keeps its text until it commits" (Spec 11 §2);
    /// and unless the field's own edit is still on its way to the engine.
    func show(_ text: String, placeholder: String? = nil, subject: AnyHashable? = nil) {
        if let placeholder { placeholderString = placeholder }
        if subject != self.subject {
            self.subject = subject
            pending = nil
        }
        if let pending {
            guard text == pending else { return }
            self.pending = nil
        }
        shown = text
        if currentEditor() == nil, stringValue != text { stringValue = text }
    }

    /// What was typed is dropped, unsent: a number that is the same, or that isn't one. The next redraw puts the
    /// model's value back.
    func putBack() {
        pending = nil
        shown = ""
    }

    /// Outlined in red while its last edit stands refused (Spec 11 §2, "Rejections and warnings");
    /// the refused text is dropped, and the next redraw puts the model's value back.
    var isRefused = false {
        didSet {
            if isRefused { pending = nil }
            layer?.borderColor = (isRefused ? Palette.live : Palette.hairline).cgColor
        }
    }
}

/// A field's cell that sets its line in the middle of the field's height,
/// a little in from its edges; a field of several lines starts at its top.
final class CenteredFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var drawn = super.drawingRect(forBounds: rect).insetBy(dx: 4, dy: 0)
        guard usesSingleLineMode || !wraps else {
            drawn.origin.y += 4
            drawn.size.height -= 6
            return drawn
        }
        let face = font ?? .systemFont(ofSize: 12)
        let line = ceil(face.ascender - face.descender + face.leading) + 2
        let spare = drawn.height - line
        if spare > 0 {
            drawn.origin.y += floor(spare / 2)
            drawn.size.height = line
        }
        return drawn
    }
}

/// Seconds as a field shows and takes them: "seconds, to a tenth" (Spec 11 §4).
@MainActor
enum SecondsText {
    private static var formatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 1
        return formatter
    }

    static func text(ms: Int?) -> String {
        guard let ms else { return "" }
        return formatter.string(from: NSNumber(value: Double(ms) / 1000)) ?? String(Double(ms) / 1000)
    }

    /// The milliseconds a typed number of seconds means, to a tenth; nil for what isn't a number of seconds.
    static func ms(_ text: String) -> Int? {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        let value = formatter.number(from: typed)?.doubleValue ?? Double(typed.replacingOccurrences(of: ",", with: "."))
        guard let value, value >= 0, value.isFinite else { return nil }
        return Int((value * 10).rounded()) * 100
    }
}

/// Spec 11 §4, "The inspector" — "shows the selected cue in four columns.
/// Its header says "Cue 3 of 14", with the live dot on the live cue; then
/// the notice line (§2); then where Fire fires; ‹ and › ...; and Fire."
@MainActor
final class InspectorView: PanelView, EditFocus, NSTextViewDelegate {
    private let model: ShowModel
    weak var host: ShowWindowView?
    var machineRoot: URL?

    // The header.
    private let liveDot = DotView()
    let notice = Kit.content(Kit.label(size: 11.5, weight: .medium))
    let fireNote = Kit.label(size: 11.5)
    let previous = FlatButton("‹", style: .plain)
    let next = FlatButton("›", style: .plain)
    let fire = FlatButton(Strings.text(.editFire), style: .dangerTint)

    // The four columns' headings.
    private let headings = [Kit.heading(Strings.text(.editColumnCue)), Kit.heading(Strings.text(.editColumnTrigger)),
                            Kit.heading(Strings.text(.editColumnCommands)), Kit.heading("")]

    // The Cue column.
    private let labelName = Kit.label(Strings.text(.editFieldLabel), size: 12)
    private let sectionName = Kit.label(Strings.text(.editFieldSection), size: 12)
    private let noteName = Kit.label(Strings.text(.editFieldNote), size: 12)
    let labelField = EditField()
    let sectionField = EditField()
    let sectionMenu = FlatButton("▾", style: .bare)
    private let sectionSwatch = Surface()
    let noteField = EditField()

    // The Trigger column.
    let goRadio = NSButton(radioButtonWithTitle: Strings.text(.editTriggerGo), target: nil, action: nil)
    let timeRadio = NSButton(radioButtonWithTitle: Strings.text(.editTriggerTime), target: nil, action: nil)
    let timecodeRadio = NSButton(radioButtonWithTitle: Strings.text(.editTriggerTimecode), target: nil, action: nil)
    let timeField = EditField()
    private let advanceName = Kit.label(Strings.text(.editTriggerAdvance), size: 12)
    let advanceField = EditField()
    let pairLabel = Kit.label(size: 11)
    let usePrevious = FlatButton(Strings.text(.editTriggerUsePrevious), style: .plain)

    // The Commands column.
    private let commandsScroll = NSScrollView()
    private let commandsDocument = InspectorDocument()
    private(set) var commandRows: [CommandRowView] = []
    let addCommand = PillButton(Strings.text(.editCommandsAdd), style: .add)
    private let asTextName = Kit.label(Strings.text(.editCommandsAsText), size: 12)
    let asText = NSSwitch()
    let selectOne = Kit.label(Strings.text(.editCommandsSelectOne), size: 11.5)

    // Commands as text, over the Commands and Channel columns.
    private let textScroll = NSScrollView()
    let textArea = CommandsTextView()
    let textErrors = Kit.label(size: 11)
    private(set) var showsText = false
    /// The cue the text area holds, so another cue selected commits or discards it first.
    private var textCue: UUID?

    // The Channel column.
    let stateControl = SegmentedView([Strings.text(.editStateWrite), Strings.text(.editStateClear), Strings.text(.editStateHold)])
    private let contentName = Kit.label(Strings.text(.editContent), size: 12)
    let contentButton = FlatButton("", style: .plain)
    private var chipNames: [NSTextField] = []
    private(set) var chipButtons: [PillButton] = []

    private(set) var inspector = CueInspector()
    /// The control whose edit was last sent, outlined while that edit stands refused.
    private weak var lastField: EditField?

    init(model: ShowModel) {
        self.model = model
        super.init(title: "")
        liveDot.color = Palette.live
        liveDot.setAccessibilityElement(true)
        liveDot.setAccessibilityRole(.image)
        liveDot.setAccessibilityLabel(Strings.text(.editCuesLive))
        fireNote.textColor = Palette.dimText
        fireNote.alignment = .right
        for (button, key) in [(previous, StringKey.editPreviousCue), (next, .editNextCue)] {
            button.setAccessibilityLabel(Strings.text(key))
            button.toolTip = Strings.text(key)
            button.fontSize = 14
        }
        // "‹ and › (Previous Cue, Next Cue), which move the selection, never the pointer".
        previous.onPress = { [weak model] in model?.editing.step(false) }
        next.onPress = { [weak model] in model?.editing.step(true) }
        fire.fontWeight = .semibold
        fire.onPress = { [weak model] in model?.editing.fire() }

        for name in [labelName, sectionName, noteName, advanceName, contentName, asTextName] { name.textColor = Palette.dimText }
        labelField.onCommit = { [weak self] text in self?.send(self?.labelField) { $0.setLabel(text) } }
        sectionField.onCommit = { [weak self] text in self?.send(self?.sectionField) { $0.setSection(text) } }
        noteField.onCommit = { [weak self] text in self?.send(self?.noteField) { $0.setNote(text) } }
        noteField.placeholderString = Strings.text(.editFieldNotePlaceholder)
        noteField.usesSingleLineMode = false
        noteField.cell?.wraps = true
        noteField.cell?.isScrollable = false
        noteField.maximumNumberOfLines = 3
        sectionSwatch.radius = 2
        sectionMenu.setAccessibilityLabel(Strings.text(.editFieldSection))
        sectionMenu.onPress = { [weak self] in self?.showSections() }

        for (radio, selector) in [(goRadio, #selector(pickedGo)), (timeRadio, #selector(pickedTime)), (timecodeRadio, #selector(pickedTimecode))] {
            radio.target = self
            radio.action = selector
            radio.font = .systemFont(ofSize: 12)
        }
        // "Timecode shows, disabled, as v2."
        timecodeRadio.isEnabled = false
        timecodeRadio.toolTip = Strings.text(.editTriggerTimecodeLater)
        for field in [timeField, advanceField] {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        timeField.setAccessibilityLabel(Strings.text(.editTriggerTime))
        advanceField.setAccessibilityLabel(Strings.text(.editTriggerAdvance))
        timeField.onCommit = { [weak self] text in
            guard let ms = SecondsText.ms(text) else { return }
            self?.send(self?.timeField) { $0.setTrigger(.time(ms: ms)) }
        }
        advanceField.onCommit = { [weak self] text in
            let typed = text.trimmingCharacters(in: .whitespaces)
            // An emptied field is none; what isn't a number of seconds changes nothing.
            if typed.isEmpty { self?.send(self?.advanceField) { $0.setAdvanceAfter(ms: nil) } } else if let ms = SecondsText.ms(typed) {
                self?.send(self?.advanceField) { $0.setAdvanceAfter(ms: ms) }
            }
        }
        pairLabel.textColor = Palette.browsing
        pairLabel.maximumNumberOfLines = 4
        pairLabel.lineBreakMode = .byWordWrapping
        pairLabel.cell?.wraps = true
        usePrevious.fontSize = 11.5
        usePrevious.onPress = { [weak self] in
            guard let self, let ms = self.inspector.previousVideoMs else { return }
            self.model.editing.setTrigger(.time(ms: ms))
        }

        commandsScroll.drawsBackground = false
        commandsScroll.hasVerticalScroller = true
        commandsScroll.autohidesScrollers = true
        commandsScroll.documentView = commandsDocument
        addCommand.onPress = { [weak self] in self?.showPalette() }
        asText.controlSize = .small
        asText.target = self
        asText.action = #selector(toggledText)
        asText.setAccessibilityLabel(Strings.text(.editCommandsAsText))
        selectOne.textColor = Palette.faintText
        selectOne.maximumNumberOfLines = 2
        selectOne.lineBreakMode = .byWordWrapping
        selectOne.cell?.wraps = true

        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.drawsBackground = true
        textScroll.backgroundColor = Palette.well
        textScroll.wantsLayer = true
        textScroll.layer?.cornerRadius = 5
        textScroll.documentView = textArea
        textArea.delegate = self
        textArea.onCommit = { [weak self] in self?.commitText() }
        textArea.onDiscard = { [weak self] in self?.discardText() }
        textErrors.textColor = Palette.live
        textErrors.maximumNumberOfLines = 3
        textErrors.lineBreakMode = .byWordWrapping
        textErrors.cell?.wraps = true

        stateControl.fills = true
        stateControl.onSelect = { [weak self] index in self?.pickedState(index) }
        contentButton.fontSize = 12
        contentButton.onPress = { [weak self] in self?.editContent() }
        for kind in CueAttribute.Kind.allCases {
            let name = Kit.label(EditModeWording.name(kind), size: 12, color: Palette.dimText)
            let button = PillButton()
            button.onPress = { [weak self, weak button] in self?.showChip(kind, at: button) }
            chipNames.append(name)
            chipButtons.append(button)
        }

        var views: [NSView] = [liveDot, notice, fireNote, previous, next, fire]
        views.append(contentsOf: headings as [NSView])
        views.append(contentsOf: [labelName, sectionName, noteName, labelField, sectionField, sectionSwatch, sectionMenu, noteField] as [NSView])
        views.append(contentsOf: [goRadio, timeRadio, timecodeRadio, timeField, advanceName, advanceField, pairLabel, usePrevious] as [NSView])
        views.append(contentsOf: [commandsScroll, addCommand, asTextName, asText, selectOne, textScroll, textErrors] as [NSView])
        views.append(contentsOf: [stateControl, contentName, contentButton] as [NSView])
        views.append(contentsOf: chipNames as [NSView])
        views.append(contentsOf: chipButtons as [NSView])
        for view in views { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Sends a field's edit, remembering the field so a refusal is shown on it.
    private func send(_ field: EditField?, _ edit: (EditModel) -> Void) {
        lastField = field
        edit(model.editing)
    }

    // MARK: - The Cue column

    /// "a combo box offering the list's sections and E3's names".
    private func showSections() {
        let menu = NSMenu()
        for name in inspector.sections {
            menu.addItem(ClosureMenuItem(title: name) { [weak self] in self?.send(self?.sectionField) { $0.setSection(name) } })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sectionMenu.bounds.height + 2), in: sectionMenu)
    }

    // MARK: - The Trigger column

    @objc private func pickedGo() {
        model.editing.setTrigger(.go)
    }

    /// Time after previous: the seconds in its field, or the field to type them in.
    @objc private func pickedTime() {
        if let ms = SecondsText.ms(timeField.stringValue) {
            model.editing.setTrigger(.time(ms: ms))
        } else {
            window?.makeFirstResponder(timeField)
            refresh()
        }
    }

    @objc private func pickedTimecode() {}

    // MARK: - The Commands column

    /// "The palette (E4): Add Command offers, grouped by what they touch and only for what exists ...".
    private func showPalette() {
        guard !inspector.isMulti, inspector.number != nil else { return }
        let after = commandRows.first(where: \.isChosen)?.line.position
        let menu = EditPopovers.palette(model: model, after: after) { [weak self] panel in
            guard let self else { return }
            self.host?.present(panel, at: self.addCommand)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: addCommand.bounds.height + 2), in: addCommand)
    }

    private func menu(for line: CueCommandLine, at anchor: NSView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let canEdit = model.editing.cannotEdit == nil
        func add(_ key: StringKey, _ enabled: Bool, _ run: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: Strings.text(key), run)
            item.isEnabled = enabled && canEdit
            menu.addItem(item)
        }
        add(.editMenuEdit, line.canEdit) { [weak self, weak anchor] in
            guard let self, let cue = self.model.editing.selectedCues.first, cue.commands.indices.contains(line.position) else { return }
            let panel = EditPopovers.command(heading: line.name, command: cue.commands[line.position].command, options: self.model.editing.parseOptions) { [weak self] command in
                self?.model.editing.setCommand(command, at: line.position)
            }
            self.host?.present(panel, at: anchor ?? self)
        }
        add(.editMenuMoveUp, line.canMoveUp) { [weak model] in model?.editing.moveCommand(at: line.position, up: true) }
        add(.editMenuMoveDown, line.canMoveDown) { [weak model] in model?.editing.moveCommand(at: line.position, up: false) }
        add(.editMenuRemove, true) { [weak model] in model?.editing.removeCommand(at: line.position) }
        return menu
    }

    // MARK: - Commands as text

    @objc private func toggledText() {
        if asText.state == .on {
            showsText = true
            loadText()
        } else if !leaveText() {
            asText.state = .on
        }
        refresh()
    }

    private func loadText() {
        guard let cue = model.editing.selectedCues.first, !inspector.isMulti else { return }
        textCue = cue.uuid
        textArea.string = CommandsText.lines(of: cue).joined(separator: "\n")
        checkText()
    }

    /// "parsed as it is typed with OCore's parser (Spec 2 §4), each error beside its line".
    private func checkText() {
        guard let cue = textCueNow else {
            textErrors.stringValue = ""
            return
        }
        let parsed = CommandsText.parse(textArea.string, cue: cue, options: model.editing.parseOptions)
        textErrors.stringValue = parsed.errors.keys.sorted().compactMap { line in
            parsed.errors[line].map { Strings.text(.editCommandsError, line + 1, $0) }
        }.joined(separator: "\n")
        needsLayout = true
    }

    private var textCueNow: Cue? {
        model.editing.list?.cues.first { $0.uuid == textCue }
    }

    func textDidChange(_ notification: Notification) {
        checkText()
    }

    /// "⌘Return, or leaving the area, sends one `edit.set` of the cue's
    /// `commands` with the parsed list, but only while no line has an error".
    @discardableResult
    private func commitText() -> Bool {
        guard showsText, let cue = textCueNow else { return true }
        if CommandsText.hasErrors(textArea.string, cue: cue, options: model.editing.parseOptions) { return false }
        model.editing.setCommands(text: textArea.string)
        return true
    }

    /// "Escape discards."
    private func discardText() {
        loadText()
        window?.makeFirstResponder(host)
    }

    func textDidEndEditing(_ notification: Notification) {
        if !commitText() { askAboutText() }
    }

    /// "with one, nothing is sent, and leaving asks Keep Editing or Discard Changes, Discard never the default."
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

    /// Leaves the text area for the rows: what it holds is sent, or stays with its errors. Says whether it left.
    private func leaveText() -> Bool {
        guard commitText() else {
            askAboutText()
            return false
        }
        showsText = false
        textCue = nil
        return true
    }

    // MARK: - The Channel column

    /// "Write on a held or cleared cell opens the content popover (below), and the cell writes nothing until something is chosen".
    private func pickedState(_ index: Int) {
        switch index {
        case 0: editContent()
        case 1: model.editing.set(.clear)
        default: model.editing.set(.hold)
        }
        refresh()
    }

    /// Opens the content popover on the selected cell.
    func editContent() {
        guard !inspector.isMulti, inspector.number != nil, inspector.channelExists, model.editing.cannotEdit == nil else { return }
        // Spec 11 §4 — the popover "hangs from that cell in the grid, scrolled into view".
        let panel = EditPopovers.content(model: model, machineRoot: machineRoot) { [weak self] again in
            guard let self else { return }
            self.host?.presentAtSelectedCell(again, fallback: self.contentButton)
        }
        host?.presentAtSelectedCell(panel, fallback: contentButton)
    }

    private func showChip(_ kind: CueAttribute.Kind, at anchor: NSView?) {
        guard let chip = inspector.chips.first(where: { $0.kind == kind }), model.editing.cannotEdit == nil else { return }
        host?.present(EditPopovers.chip(chip, model: model), at: anchor ?? self)
    }

    // MARK: - Showing the model

    func refresh() {
        let editing = model.editing
        let catalog = model.store.catalog
        if let list = editing.list, let catalog, editing.page == .cues {
            inspector = CueInspector.make(list: list, grid: editing.grid, selection: editing.selection, catalog: catalog, media: model.store.media)
        } else {
            inspector = CueInspector()
        }
        let one = inspector.number != nil && !inspector.isMulti
        let any = inspector.number != nil
        let cannot = editing.cannotEdit
        let canEdit = cannot == nil && any

        // The header.
        title.stringValue = EditModeWording.title(inspector)
        title.isHidden = false
        liveDot.isHidden = !inspector.isLive
        let fireWords = EditModeWording.fire(editing.fireNote)
        fireNote.stringValue = fireWords ?? ""
        var canFire = false
        if case .fires = editing.fireNote { canFire = true }
        fire.isEnabled = canFire
        fire.reason = fireWords ?? ShowWording.unavailable(model.store.cannotSend)
        previous.isEnabled = any
        next.isEnabled = any
        if let standing = editing.notice {
            notice.stringValue = EditModeWording.notice(standing)
            switch standing {
            case .rejected, .notSent: notice.textColor = Palette.live
            case .warnings, .skipped, .onAir: notice.textColor = Palette.browsing
            }
            notice.toolTip = notice.stringValue
            if notice.isHidden {
                // "A rejection and a warning are announced where they show" (Spec 11 §10).
                NSAccessibility.post(element: self, notification: .announcementRequested,
                                     userInfo: [.announcement: notice.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            notice.isHidden = false
        } else {
            notice.stringValue = ""
            notice.isHidden = true
        }
        var refused = false
        if case .rejected? = editing.notice { refused = true }
        for field in [labelField, sectionField, noteField, timeField, advanceField] { field.isRefused = refused && field === lastField }

        // The Cue column: "the Cue column keeps only the section" for several cues.
        let mixed = Strings.text(.editChipMixed)
        let subject = AnyHashable([AnyHashable(editing.listUuid), AnyHashable(editing.selection.cues)])
        if case .same(let label)? = inspector.label {
            labelField.show(label, placeholder: "", subject: subject)
        } else {
            labelField.show("", placeholder: any ? mixed : "", subject: subject)
        }
        var section = ""
        if case .same(let name)? = inspector.section { section = name }
        sectionField.show(section, placeholder: inspector.section == .mixed ? mixed : "", subject: subject)
        sectionSwatch.fill = section.isEmpty ? nil : Palette.section(SectionHue.index(for: section))
        noteField.show(inspector.note, subject: subject)
        labelField.isEnabled = canEdit && one
        noteField.isEnabled = canEdit && one
        sectionField.isEnabled = canEdit
        sectionMenu.isEnabled = canEdit

        // The Trigger column.
        var kind: CueTrigger.Kind?
        if case .same(let same)? = inspector.trigger { kind = same }
        goRadio.state = kind == .go ? .on : .off
        var timeMs: Int?
        if case .time(let ms)? = kind { timeMs = ms }
        let typingTime = timeField.currentEditor() != nil
        timeRadio.state = timeMs != nil || (typingTime && kind != .go) ? .on : .off
        if case .timecode? = kind { timecodeRadio.state = .on } else { timecodeRadio.state = .off }
        timeField.show(SecondsText.text(ms: timeMs), placeholder: inspector.trigger == .mixed ? mixed : Strings.text(.editTriggerSeconds), subject: subject)
        var advance: Int?
        if case .same(let same)? = inspector.advanceAfterMs { advance = same }
        advanceField.show(SecondsText.text(ms: advance), placeholder: inspector.advanceAfterMs == .mixed ? mixed : Strings.text(.editTriggerNone),
                          subject: subject)
        for control in [goRadio, timeRadio, timeField, advanceField] as [NSControl] { control.isEnabled = canEdit }
        pairLabel.stringValue = inspector.pairWarnings.map { EditModeWording.pair($0, selected: one ? inspector.number : nil) }.joined(separator: "\n")
        pairLabel.isHidden = pairLabel.stringValue.isEmpty
        usePrevious.isHidden = inspector.previousVideoMs == nil
        usePrevious.isEnabled = canEdit

        // Commands as text follows the selected cue, and closes when there isn't one cue to hold.
        if showsText, !one || editing.selectedCues.first?.uuid != textCue {
            if one, textArea.window?.firstResponder !== textArea { loadText() } else if !one {
                showsText = false
                textCue = nil
            }
        }
        asText.state = showsText ? .on : .off
        asText.isEnabled = one

        // The Commands column.
        commandRows.forEach { $0.removeFromSuperview() }
        commandRows = inspector.commands.map { line in
            let row = CommandRowView(line)
            row.more.isEnabled = cannot == nil
            row.makeMenu = { [weak self, weak row] in
                guard let self, let row else { return nil }
                return self.menu(for: line, at: row)
            }
            commandsDocument.addSubview(row)
            return row
        }
        selectOne.isHidden = !inspector.isMulti
        addCommand.isEnabled = canEdit && one
        for view in [commandsScroll, addCommand] as [NSView] { view.isHidden = showsText || inspector.isMulti }
        for view in [textScroll, textErrors] as [NSView] { view.isHidden = !showsText }
        textArea.isEditable = canEdit

        // The Channel column.
        let hasChannel = inspector.channel != nil
        let heading = inspector.channel.map { Strings.text(.editColumnChannel, $0, inspector.channelExists ? inspector.channelLabel : Strings.text(.editCuesNoChannel, $0)) } ?? ""
        Kit.setHeading(headings[3], heading)
        headings[2].isHidden = false
        headings[3].isHidden = showsText || !hasChannel
        stateControl.isHidden = showsText || !one || !hasChannel
        if let state = inspector.state {
            stateControl.selected = state == .write ? 0 : (state == .clear ? 1 : 2)
            stateControl.setAccessibilityLabel(EditModeWording.stateSpoken(channel: inspector.channel ?? 0, label: inspector.channelLabel, state: state, content: inspector.content))
        }
        // "On a "No channel" row the only action is Hold".
        stateControl.disable(0, reason: canEdit && inspector.channelExists ? nil : (cannot.map(EditModeWording.readOnly) ?? Strings.text(.editCuesNoChannel, inspector.channel ?? 0)))
        stateControl.disable(1, reason: canEdit && inspector.channelExists ? nil : (cannot.map(EditModeWording.readOnly) ?? Strings.text(.editCuesNoChannel, inspector.channel ?? 0)))
        stateControl.disable(2, reason: canEdit ? nil : cannot.map(EditModeWording.readOnly))
        for view in [contentName, contentButton] as [NSView] { view.isHidden = showsText || !one || !hasChannel }
        // "Content. For a write, a small tile and the media's name or the first line of the text; for a hold, the
        // same for what the channel holds, with the cue it came from ("From cue 3"); a dash for a clear or for holding nothing."
        if let content = inspector.content {
            let words = EditModeWording.content(content)
            contentButton.title = inspector.state == .hold ? (inspector.heldFrom.map { words + " · " + Strings.text(.editContentFrom, $0) } ?? words) : words
        } else {
            contentButton.title = Strings.text(.editContentNone)
        }
        contentButton.isEnabled = canEdit && inspector.channelExists
        for (index, button) in chipButtons.enumerated() {
            let hidden = showsText || !any || !hasChannel || index >= inspector.chips.count
            button.isHidden = hidden
            chipNames[index].isHidden = hidden
            guard !hidden else { continue }
            let words = EditModeWording.chip(inspector.chips[index], catalog: catalog)
            button.title = words.title
            button.style = words.isSet ? .set : .add
            button.setAccessibilityLabel(words.isSet ? words.spoken : Strings.text(.editChipAdd, EditModeWording.name(inspector.chips[index].kind)))
            button.isEnabled = canEdit && inspector.channelExists
        }
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        // The header: the title and the live dot, the notice, then from the right Fire, › ‹ and where Fire fires.
        let titleWidth = Kit.width(of: title)
        title.frame = NSRect(x: 12, y: (h - 16) / 2, width: titleWidth, height: 16)
        liveDot.frame = NSRect(x: title.frame.maxX + 6, y: (h - 9) / 2, width: 9, height: 9)
        var right = bounds.width - 12
        let fireWidth = fire.fitting.width
        fire.frame = NSRect(x: right - fireWidth, y: (h - 24) / 2, width: fireWidth, height: 24)
        right -= fireWidth + 8
        next.frame = NSRect(x: right - 24, y: (h - 24) / 2, width: 24, height: 24)
        previous.frame = NSRect(x: right - 50, y: (h - 24) / 2, width: 24, height: 24)
        right -= 50 + 10
        let noteWidth = Kit.width(of: fireNote)
        fireNote.frame = NSRect(x: right - noteWidth, y: (h - 15) / 2, width: noteWidth, height: 15)
        right -= noteWidth + 12
        let noticeX = liveDot.frame.maxX + 14
        notice.frame = NSRect(x: noticeX, y: (h - 15) / 2, width: max(0, right - noticeX), height: 15)

        // Four columns of equal width, each with its heading.
        let column = floor(bounds.width / 4)
        let pad: CGFloat = 14
        let top = h + 12
        for (index, heading) in headings.enumerated() {
            heading.frame = NSRect(x: CGFloat(index) * column + pad, y: top, width: column - 2 * pad, height: 14)
        }
        let rowTop = top + 22
        let rowHeight: CGFloat = 26
        let gap: CGFloat = 8
        let inner = column - 2 * pad
        let nameWidth: CGFloat = 58

        // Cue.
        var x = pad
        var y = rowTop
        labelName.frame = NSRect(x: x, y: y + 5, width: nameWidth, height: 16)
        labelField.frame = NSRect(x: x + nameWidth + 6, y: y, width: inner - nameWidth - 6, height: rowHeight)
        y += rowHeight + gap
        sectionName.frame = NSRect(x: x, y: y + 5, width: nameWidth, height: 16)
        sectionSwatch.frame = NSRect(x: x + nameWidth + 6, y: y + 8.5, width: 9, height: 9)
        sectionField.frame = NSRect(x: x + nameWidth + 6 + 14, y: y, width: inner - nameWidth - 6 - 14 - 26, height: rowHeight)
        sectionMenu.frame = NSRect(x: x + inner - 24, y: y + 1, width: 24, height: 24)
        y += rowHeight + gap
        noteName.frame = NSRect(x: x, y: y + 5, width: nameWidth, height: 16)
        noteField.frame = NSRect(x: x + nameWidth + 6, y: y, width: inner - nameWidth - 6, height: max(rowHeight, min(58, bounds.height - y - 12)))

        // Trigger.
        x = column + pad
        y = rowTop
        let secondsWidth: CGFloat = 62
        goRadio.frame = NSRect(x: x, y: y + 3, width: inner, height: 20)
        y += rowHeight + 2
        timeRadio.frame = NSRect(x: x, y: y + 3, width: inner - secondsWidth - 6, height: 20)
        timeField.frame = NSRect(x: x + inner - secondsWidth, y: y, width: secondsWidth, height: 24)
        y += rowHeight + 2
        timecodeRadio.frame = NSRect(x: x, y: y + 3, width: inner, height: 20)
        y += rowHeight + 2
        advanceName.frame = NSRect(x: x + 20, y: y + 4, width: inner - secondsWidth - 26, height: 16)
        advanceField.frame = NSRect(x: x + inner - secondsWidth, y: y, width: secondsWidth, height: 24)
        y += rowHeight + 4
        if !usePrevious.isHidden {
            let size = usePrevious.fitting
            usePrevious.frame = NSRect(x: x, y: y, width: min(inner, size.width), height: 22)
            y += 26
        }
        pairLabel.frame = NSRect(x: x, y: y, width: inner, height: max(0, bounds.height - y - 8))

        // Commands: the rows, Add Command under them, and the switch at the column's foot.
        x = 2 * column + pad
        let footY = bounds.height - 12 - 20
        let switchSize = asText.intrinsicContentSize
        asText.frame = NSRect(x: (showsText ? 4 * column : 3 * column) - pad - switchSize.width, y: footY, width: switchSize.width, height: switchSize.height)
        asTextName.frame = NSRect(x: x, y: footY + 2, width: max(0, asText.frame.minX - x - 8), height: 16)
        selectOne.frame = NSRect(x: x, y: rowTop, width: inner, height: 32)
        let listHeight = max(0, footY - 8 - 26 - 6 - rowTop)
        var rowY: CGFloat = 0
        for row in commandRows {
            let height = row.wantedHeight
            row.frame = NSRect(x: 0, y: rowY, width: inner, height: height)
            rowY += height + 6
        }
        let shown = min(listHeight, rowY)
        commandsScroll.frame = NSRect(x: x, y: rowTop, width: inner, height: shown)
        commandsDocument.frame = NSRect(x: 0, y: 0, width: inner, height: max(rowY, shown))
        addCommand.frame = NSRect(x: x, y: rowTop + shown + (shown > 0 ? 2 : 0), width: inner, height: 26)

        // Commands as text: one area over the Commands and Channel columns.
        let wide = 2 * column - 2 * pad
        let errorsHeight: CGFloat = textErrors.stringValue.isEmpty ? 0 : min(44, ceil(textErrors.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: wide, height: 100)).height ?? 15))
        textScroll.frame = NSRect(x: x, y: rowTop, width: wide, height: max(0, footY - 8 - rowTop - (errorsHeight > 0 ? errorsHeight + 4 : 0)))
        textErrors.frame = NSRect(x: x, y: textScroll.frame.maxY + 4, width: wide, height: errorsHeight)
        textArea.frame.size.width = textScroll.contentSize.width
        textArea.minSize = NSSize(width: 0, height: textScroll.contentSize.height)

        // Channel: the three-way control, the content, the chips.
        x = 3 * column + pad
        y = rowTop
        if !stateControl.isHidden {
            stateControl.frame = NSRect(x: x, y: y, width: inner, height: 28)
            y += 28 + gap
            contentName.frame = NSRect(x: x, y: y + 5, width: nameWidth, height: 16)
            contentButton.frame = NSRect(x: x + nameWidth + 6, y: y, width: inner - nameWidth - 6, height: rowHeight)
            y += rowHeight + gap
        }
        let chipName: CGFloat = 104
        for (index, button) in chipButtons.enumerated() where !button.isHidden {
            chipNames[index].frame = NSRect(x: x, y: y + 2, width: chipName, height: 16)
            let size = button.fitting
            button.frame = NSRect(x: x + chipName + 6, y: y, width: min(size.width, inner - chipName - 6), height: PillButton.height)
            y += PillButton.height + 7
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // One hairline between columns.
        Palette.hairline.setFill()
        let column = floor(bounds.width / 4)
        for index in 1..<4 where !(showsText && index == 3) {
            NSRect(x: CGFloat(index) * column, y: Self.headerHeight, width: 1, height: bounds.height - Self.headerHeight).fill()
        }
    }
}

/// A scroll view's document measured from its top.
@MainActor
final class InspectorDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Spec 11 §4, "Commands" — one of the cue's other commands: "each as its
/// plain name (Spec 10 §15) with a ⋯ menu: Edit, Move Up, Move Down, Remove".
@MainActor
final class CommandRowView: Surface {
    let line: CueCommandLine
    let name = Kit.content(Kit.label(size: 12))
    let warning = Kit.label(size: 11)
    let more = FlatButton("⋯", style: .bare)
    var makeMenu: (() -> NSMenu?)?
    /// The row last clicked: "Add inserts the command after the selected one, or at the end."
    private(set) var isChosen = false { didSet { fill = isChosen ? Palette.raisedHigh : Palette.raised } }

    init(_ line: CueCommandLine) {
        self.line = line
        super.init(frame: .zero)
        fill = Palette.raised
        radius = 6
        name.stringValue = line.name
        name.toolTip = line.name
        if let kind = line.warning {
            warning.stringValue = EditModeWording.warning(kind)
            warning.toolTip = warning.stringValue
        }
        warning.textColor = Palette.browsing
        warning.isHidden = line.warning == nil
        more.setAccessibilityLabel(line.name)
        more.onPress = { [weak self] in
            guard let self, let menu = self.makeMenu?() else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.more.bounds.height + 2), in: self.more)
        }
        for view in [name, warning, more] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var wantedHeight: CGFloat { line.warning == nil ? 28 : 42 }

    /// The row's menu as it stands, for a test and for ⌃Return.
    var menuNow: NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        for case let row as CommandRowView in superview?.subviews ?? [] where row !== self { row.isChosen = false }
        isChosen.toggle()
    }

    override func layout() {
        super.layout()
        more.frame = NSRect(x: bounds.width - 26, y: (bounds.height - 22) / 2, width: 22, height: 22)
        let width = max(0, bounds.width - 10 - 30)
        name.frame = NSRect(x: 10, y: line.warning == nil ? 6 : 5, width: width, height: 16)
        warning.frame = NSRect(x: 10, y: 22, width: width, height: 14)
    }
}

/// Spec 11 §4, "Commands as text" — the text area: "⌘Return, or leaving the
/// area, sends ... Escape discards."
@MainActor
final class CommandsTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onDiscard: (() -> Void)?

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        isRichText = false
        allowsUndo = true
        font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        textColor = Palette.text
        backgroundColor = Palette.well
        insertionPointColor = Palette.text
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 6, height: 6)
        textContainer?.widthTracksTextView = true
        setAccessibilityLabel(Strings.text(.editCommandsAsText))
    }

    /// The content popover's text: "Return commits and closes the popover, ⇧Return makes a line" (Spec 11 §4,
    /// corrected 2026-11-24). Elsewhere, as in Commands as Text, Return makes a line and ⌘Return sends.
    var returnCommits = false

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, !hasMarkedText() else { return super.keyDown(with: event) }
        if event.modifierFlags.contains(.command) {
            onCommit?()
        } else if returnCommits {
            if event.modifierFlags.contains(.shift) { insertNewline(nil) } else { onCommit?() }
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.command) {
            onCommit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onDiscard?()
    }
}
