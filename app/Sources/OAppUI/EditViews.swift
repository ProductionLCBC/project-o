// OAppUI — Spec 10 §5, §6 and §10, what the edits are made with: a menu from the model's entries, a field in place, a small panel, a message line.

import AppKit
import OApp
import OCore

/// Builds a context menu from the model's entries (`Menus`), so a menu
/// shows what the tests hold it to: each entry's title, its tick, and when
/// it is disabled, the reason.
@MainActor
enum MenuBuilder {
    static func menu(_ entries: [MenuEntry], perform: @escaping @MainActor (MenuEntry) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.kind == .separator {
                menu.addItem(.separator())
                continue
            }
            let item = ClosureMenuItem(title: EditWording.title(entry)) { perform(entry) }
            item.isEnabled = entry.isEnabled
            item.toolTip = entry.reason.map(EditWording.reason)
            item.state = entry.isOn ? .on : .off
            if !entry.children.isEmpty { item.submenu = self.menu(entry.children, perform: perform) }
            menu.addItem(item)
        }
        return menu
    }
}

extension NSMenu {
    /// The entry with this title, at any depth, for a test to choose.
    @MainActor
    func entry(_ title: String) -> ClosureMenuItem? {
        for item in items {
            if item.title == title, let found = item as? ClosureMenuItem, item.submenu == nil { return found }
            if let found = item.submenu?.entry(title) { return found }
        }
        return nil
    }

    /// Every entry's title, with a submenu's entries after it, indented.
    @MainActor
    var titles: [String] {
        items.filter { !$0.isSeparatorItem }.flatMap { [$0.title] + ($0.submenu?.titles.map { "  " + $0 } ?? []) }
    }
}

/// A message line: what a region says for a few seconds beside what was
/// tried (Spec 10 §10, "Rejections come back as a short message in plain words").
@MainActor
final class NoticeLabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: 11.5, weight: .medium)
        textColor = Palette.browsing
        maximumNumberOfLines = 2
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows a region's message, or nothing.
    func show(_ notice: Notice?) {
        stringValue = notice.map(EditWording.notice) ?? ""
        isHidden = notice == nil
        if case .done? = notice { textColor = Palette.dimText } else { textColor = Palette.browsing }
        // VoiceOver hears it when it appears.
        if notice != nil { NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue]) }
    }

    /// The height its words need at a width.
    func height(width: CGFloat) -> CGFloat {
        guard !isHidden, let cell else { return 0 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 200)).height)
    }
}

/// Spec 10 §10, "Text fields" — a field opened in place over what it edits:
/// a rename, a new title, a header's label, a cue's words. It "send[s] one
/// edit when [it] commit[s], never while typing"; Escape discards; a click
/// outside commits and does nothing else; and "A commit that can't be sent
/// ... leaves the field open with its text, the reason and Copy."
@MainActor
final class InlineEditor: Surface, NSTextFieldDelegate {
    let field: ShowField
    private let problem = Kit.label(size: 11.5, weight: .medium)
    private let copy = FlatButton(Strings.text(.fieldCopy), style: .plain)
    /// Sends what was typed; answers why it couldn't, or nil when the field may close.
    private let commit: (String) -> CannotEdit?
    private let isMultiline: Bool
    var onClose: (() -> Void)?
    private var isClosing = false

    /// `kind` is `.edit` for a one-line field that saves on Return, or
    /// `.inPlaceText` for a cue's words, where "Return makes a new line; ⌘Return commits".
    init(text: String, kind: FieldKind, label: String, placeholder: String = "", commit: @escaping (String) -> CannotEdit?) {
        field = ShowField(kind: kind)
        isMultiline = kind == .inPlaceText
        self.commit = commit
        super.init(frame: .zero)
        fill = Palette.raisedHigh
        radius = 6
        outline = Palette.selection
        outlineWidth = 1.5
        field.stringValue = text
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: isMultiline ? 13 : 12.5)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Palette.text
        field.setAccessibilityLabel(label)
        field.delegate = self
        field.target = self
        field.action = #selector(returned)
        if isMultiline {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.alignment = .center
        } else {
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        problem.textColor = Palette.live
        problem.isHidden = true
        copy.isHidden = true
        copy.onPress = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.field.stringValue, forType: .string)
        }
        // Escape "discards what was typed and leaves the field".
        field.onEscape = { [weak self] in self?.close() }
        for view in [field, problem, copy] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Puts the cursor in it, with everything selected, as a rename starts.
    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func returned() {
        // In a cue's words Return is a new line (below); in any other field it saves.
        commitNow()
    }

    /// Return in a cue's words "makes a new line; ⌘Return commits".
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard isMultiline, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApplication.shared.currentEvent?.modifierFlags.contains(.command) == true {
            commitNow()
        } else {
            textView.insertNewlineIgnoringFieldEditor(nil)
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘Return, wherever the menus left it.
        if isMultiline, event.modifierFlags.contains(.command), event.keyCode == 36, window?.firstResponder === field.currentEditor() {
            commitNow()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Commits what the field holds. Says whether the field closed: it
    /// stays, with the reason and Copy, when the edit couldn't be sent.
    @discardableResult
    func commitNow() -> Bool {
        guard !isClosing else { return true }
        // What is being typed is the field's text.
        field.validateEditing()
        if let cannot = commit(field.stringValue) {
            // It stays open, a line taller, with the reason and Copy.
            if problem.isHidden { frame.size.height += 26 }
            problem.stringValue = EditWording.reason(cannot)
            problem.isHidden = false
            copy.isHidden = false
            needsLayout = true
            return false
        }
        close()
        return true
    }

    /// Whether the field is showing why its text couldn't be saved.
    var isHeld: Bool { !problem.isHidden }
    var shownProblem: String { problem.isHidden ? "" : problem.stringValue }

    /// Closes it and hands the keys back, sending nothing.
    func close() {
        guard !isClosing else { return }
        isClosing = true
        if window?.firstResponder === field.currentEditor() || window?.firstResponder === field { field.handKeysBack() }
        removeFromSuperview()
        onClose?()
    }

    /// How much taller it is while it shows a reason.
    var extraHeight: CGFloat { problem.isHidden ? 0 : 26 }

    override func layout() {
        super.layout()
        let fieldHeight = bounds.height - extraHeight
        field.frame = NSRect(x: 6, y: isMultiline ? 6 : (fieldHeight - 17) / 2, width: bounds.width - 12, height: isMultiline ? fieldHeight - 12 : 17)
        let copyWidth = copy.fitting.width
        copy.frame = NSRect(x: bounds.width - copyWidth - 4, y: fieldHeight + 1, width: copyWidth, height: 22)
        problem.frame = NSRect(x: 8, y: fieldHeight + 4, width: max(0, bounds.width - copyWidth - 18), height: 16)
    }
}

/// A small panel in a popover: a heading, a few fields, Save and Cancel.
/// What the playlist's Duplicate… and Date and Time…, a cue's Note… and its
/// trigger's seconds are asked in (Spec 10 §5, §6). Return in a field
/// saves; Escape closes it and saves nothing.
@MainActor
final class PromptView: Surface {
    let heading = Kit.content(Kit.label(size: 12.5, weight: .semibold))
    private var rows: [(label: NSTextField, control: NSView, none: NSButton?)] = []
    let save = FlatButton(Strings.text(.promptSave), style: .primary)
    let cancel = FlatButton(Strings.text(.cancel), style: .plain)
    let problem = Kit.label(size: 11.5, weight: .medium)
    /// Saves; answers why it couldn't, or nil when the panel may close.
    var onSave: (() -> PromptProblem?)?
    var onClose: (() -> Void)?
    private let width: CGFloat
    private var targets: [ClosureTarget] = []

    /// Why a panel didn't save.
    enum PromptProblem: Equatable {
        case cannot(CannotEdit)
        /// What was typed isn't what the field takes: the sentence to show.
        case invalid(String)
    }

    init(heading text: String, width: CGFloat = 300) {
        self.width = width
        super.init(frame: .zero)
        fill = Palette.panel
        heading.stringValue = text
        heading.maximumNumberOfLines = 2
        heading.lineBreakMode = .byWordWrapping
        heading.cell?.wraps = true
        problem.textColor = Palette.live
        problem.maximumNumberOfLines = 2
        problem.lineBreakMode = .byWordWrapping
        problem.cell?.wraps = true
        problem.isHidden = true
        save.onPress = { [weak self] in self?.commit() }
        cancel.onPress = { [weak self] in self?.onClose?() }
        for view in [heading, problem, save, cancel] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func add(_ label: String, _ control: NSView, none: NSButton? = nil) {
        let name = Kit.label(label, size: 11.5, color: Palette.dimText)
        rows.append((name, control, none))
        addSubview(name)
        addSubview(control)
        if let none { addSubview(none) }
        control.setAccessibilityLabel(label)
    }

    /// A one-line field. Return in it saves.
    @discardableResult
    func text(_ label: String, _ value: String, placeholder: String = "") -> ShowField {
        let field = ShowField(kind: .edit)
        field.stringValue = value
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.bezelStyle = .roundedBezel
        let returned = ClosureTarget { [weak self] in self?.commit() }
        field.target = returned
        field.action = #selector(ClosureTarget.fire)
        targets.append(returned)
        field.onEscape = { [weak self] in self?.onClose?() }
        add(label, field)
        return field
    }

    /// A "None" checkbox for the row just added: ticked, the row's control is set aside.
    @discardableResult
    func none(_ isNone: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: Strings.text(.promptNone), target: nil, action: nil)
        box.state = isNone ? .on : .off
        box.font = .systemFont(ofSize: 11.5)
        guard var last = rows.popLast() else { return box }
        let control = last.control
        let toggled = ClosureTarget { [weak box, weak control] in (control as? NSControl)?.isEnabled = box?.state != .on }
        box.target = toggled
        box.action = #selector(ClosureTarget.fire)
        targets.append(toggled)
        (control as? NSControl)?.isEnabled = !isNone
        last.none = box
        rows.append(last)
        addSubview(box)
        return box
    }

    /// A date or a time, as the system writes one.
    @discardableResult
    func picker(_ label: String, _ value: Date, elements: NSDatePicker.ElementFlags) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = elements
        picker.dateValue = value
        picker.calendar = Calendar(identifier: .gregorian)
        picker.timeZone = TimeZone(identifier: "UTC")
        picker.font = .systemFont(ofSize: 12.5)
        add(label, picker)
        return picker
    }

    /// Sizes the panel to what it holds.
    func finish() {
        let inner = width - 28
        let headingHeight = ceil(heading.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 17)
        var y: CGFloat = 14
        heading.frame = NSRect(x: 14, y: y, width: inner, height: headingHeight)
        y += headingHeight + 10
        let labelWidth = min(inner * 0.4, (rows.map { Kit.width(of: $0.label) }.max() ?? 0) + 6)
        for row in rows {
            row.label.frame = NSRect(x: 14, y: y + 4, width: labelWidth, height: 16)
            var controlWidth = inner - labelWidth - 6
            if let none = row.none {
                none.sizeToFit()
                none.frame.origin = NSPoint(x: 14 + inner - none.frame.width, y: y + 3)
                controlWidth -= none.frame.width + 8
            }
            row.control.frame = NSRect(x: 14 + labelWidth + 6, y: y, width: controlWidth, height: 24)
            y += 32
        }
        if !problem.isHidden {
            let height = ceil(problem.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 100)).height ?? 16)
            problem.frame = NSRect(x: 14, y: y, width: inner, height: height)
            y += height + 8
        }
        let saveWidth = max(64, save.fitting.width)
        let cancelWidth = max(64, cancel.fitting.width)
        save.frame = NSRect(x: width - 14 - saveWidth, y: y + 2, width: saveWidth, height: 26)
        cancel.frame = NSRect(x: save.frame.minX - 8 - cancelWidth, y: y + 2, width: cancelWidth, height: 26)
        y += 26 + 14
        frame.size = NSSize(width: width, height: y)
    }

    /// Save, or Return in a field. The panel closes when what it holds was sent, or there was nothing to send.
    func commit() {
        for row in rows { (row.control as? NSTextField)?.validateEditing() }
        switch onSave?() {
        case nil:
            onClose?()
        case .cannot(let reason)?:
            show(problem: EditWording.reason(reason))
        case .invalid(let sentence)?:
            show(problem: sentence)
        }
    }

    private func show(problem text: String) {
        problem.stringValue = text
        problem.isHidden = false
        finish()
        needsDisplay = true
    }

    var shownProblem: String { problem.isHidden ? "" : problem.stringValue }

    /// The first field, for the cursor when the panel opens.
    var firstField: NSView? { rows.first?.control }
}

/// The small panels of Spec 10 §5 and §6, each built over the model's edit
/// for it: what it asks, and what Save sends.
@MainActor
enum Prompts {
    private static func seconds(_ ms: Int?) -> String {
        guard let ms else { return "" }
        return ms % 1000 == 0 ? String(ms / 1000) : String(Double(ms) / 1000)
    }

    /// "Duplicate… (asks for the new title; `… duplicate`)".
    static func duplicate(_ playlist: Playlist, model: ShowModel) -> PromptView {
        let panel = PromptView(heading: Strings.text(.promptDuplicate, playlist.title))
        let title = panel.text(Strings.text(.promptNewTitle), "")
        let uuid = playlist.uuid.uuidString.lowercased()
        panel.onSave = { [weak model, weak title] in
            let typed = (title?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if typed.isEmpty { return .invalid(Strings.text(.promptEmpty)) }
            return model?.duplicate(playlist: uuid, as: typed).map(PromptView.PromptProblem.cannot)
        }
        return panel
    }

    private static let utc = TimeZone(identifier: "UTC") ?? .current

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = format
        return formatter
    }

    /// "Date and Time… (a popover setting `serviceDate` and `serviceTime`,
    /// each with "None")". The pickers hold the date and the time as they
    /// are written in the playlist, with no time zone of their own.
    static func schedule(_ playlist: Playlist, model: ShowModel, today: Date = Date()) -> (panel: PromptView, date: NSDatePicker, noDate: NSButton, time: NSDatePicker, noTime: NSButton) {
        let panel = PromptView(heading: Strings.text(.promptSchedule, playlist.title), width: 330)
        let dates = formatter("yyyy-MM-dd")
        let times = formatter("HH:mm")
        let day = playlist.serviceDate.flatMap(dates.date) ?? dates.date(from: dates.string(from: today)) ?? today
        let date = panel.picker(Strings.text(.promptDate), day, elements: [.yearMonthDay])
        let noDate = panel.none(playlist.serviceDate == nil)
        let clock = playlist.serviceTime.flatMap(times.date) ?? times.date(from: "09:00") ?? today
        let time = panel.picker(Strings.text(.promptTime), clock, elements: [.hourMinute])
        let noTime = panel.none(playlist.serviceTime == nil)
        let uuid = playlist.uuid.uuidString.lowercased()
        panel.onSave = { [weak model, weak date, weak noDate, weak time, weak noTime] in
            guard let date, let time else { return nil }
            let newDate = noDate?.state == .on ? nil : dates.string(from: date.dateValue)
            let newTime = noTime?.state == .on ? nil : times.string(from: time.dateValue)
            return model?.schedule(playlist: uuid, date: newDate, time: newTime).map(PromptView.PromptProblem.cannot)
        }
        return (panel, date, noDate, time, noTime)
    }

    /// "Note… (a popover; `edit list L cue C note "…"`)".
    static func note(_ cell: CueCell, in section: GridSection, model: ShowModel) -> PromptView {
        let panel = PromptView(heading: Strings.text(.promptNote, cell.number))
        let field = panel.text(Strings.text(.promptNoteField), cell.note)
        panel.onSave = { [weak model, weak field] in
            model?.note(field?.stringValue ?? "", cell: cell, in: section).map(PromptView.PromptProblem.cannot)
        }
        return panel
    }

    /// "Time after Previous… (seconds)".
    static func triggerTime(_ cell: CueCell, in section: GridSection, model: ShowModel) -> PromptView {
        let panel = PromptView(heading: Strings.text(.promptTriggerTime))
        var now: Int?
        if case .time(let ms) = cell.trigger { now = ms }
        let field = panel.text(Strings.text(.promptSeconds), seconds(now))
        panel.onSave = { [weak model, weak field] in
            guard let ms = DurationText.ms(field?.stringValue ?? ""), ms > 0 else { return .invalid(Strings.text(.promptBadSeconds)) }
            return model?.trigger(.time(ms: ms), cell: cell, in: section).map(PromptView.PromptProblem.cannot)
        }
        return panel
    }

    /// "Advance After… (seconds or none)".
    static func advanceAfter(_ cell: CueCell, in section: GridSection, model: ShowModel) -> (panel: PromptView, none: NSButton) {
        let panel = PromptView(heading: Strings.text(.promptAdvanceAfter))
        let field = panel.text(Strings.text(.promptSeconds), seconds(cell.advanceAfterMs))
        let none = panel.none(cell.advanceAfterMs == nil)
        panel.onSave = { [weak model, weak field, weak none] in
            if none?.state == .on { return model?.advanceAfter(ms: nil, cell: cell, in: section).map(PromptView.PromptProblem.cannot) }
            guard let ms = DurationText.ms(field?.stringValue ?? ""), ms > 0 else { return .invalid(Strings.text(.promptBadSeconds)) }
            return model?.advanceAfter(ms: ms, cell: cell, in: section).map(PromptView.PromptProblem.cannot)
        }
        return (panel, none)
    }
}
