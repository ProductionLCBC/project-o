// OAppUI — Spec 10 §6, §7 and §10: what a cell says about a drop, the list of channels a drop on a cue opens, and the pool header's imports.

import AppKit
import OApp
import OCore

/// A list that has the keys while it is in a popover or a sheet: "a list
/// that has the focus in a sheet or popover, takes every key but ⇧⎋" (Spec
/// 10 §9, "When bindings fire", 3).
@MainActor
protocol KeyList: NSView {}

/// What a cue's cell or a strip's cell says about a drop: the words, and
/// Cancel while a file is on its way in (Spec 10 §6: "the cell shows the
/// import's progress ..., with Cancel").
@MainActor
final class DropNoteView: Surface {
    let label = Kit.label(size: 10.5, weight: .medium)
    let cancel = FlatButton(Strings.text(.cancel), style: .plain)
    /// The row of the pool's jobs that Cancel lets go of.
    private(set) var row: Int?
    var onCancel: ((Int) -> Void)?

    init() {
        super.init(frame: .zero)
        radius = 5
        fill = Palette.panel.withAlphaComponent(0.94)
        label.textColor = Palette.text
        label.lineBreakMode = .byTruncatingTail
        cancel.fontSize = 10
        cancel.onPress = { [weak self] in
            guard let self, let row = self.row else { return }
            self.onCancel?(row)
        }
        addSubview(label)
        addSubview(cancel)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows words, or nothing. `row` offers Cancel for that import; `live` draws it in the live red (Spec 10 §7).
    func show(_ text: String?, row: Int? = nil, name: String = "", live: Bool = false) {
        let changed = text != label.stringValue || isHidden != (text == nil)
        self.row = row
        label.stringValue = text ?? ""
        label.toolTip = text
        isHidden = text == nil
        cancel.isHidden = row == nil
        cancel.setAccessibilityLabel(Strings.text(.dropCancel, name))
        fill = live ? Palette.live : Palette.panel.withAlphaComponent(0.94)
        label.textColor = live ? .white : Palette.text
        needsLayout = true
        // VoiceOver hears a cell's word when it appears or changes, not at every step of a progress.
        if changed, let text, row == nil {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    var text: String { isHidden ? "" : label.stringValue }

    override func layout() {
        super.layout()
        let cancelWidth = cancel.isHidden ? 0 : cancel.fitting.width
        cancel.frame = NSRect(x: bounds.width - cancelWidth - 3, y: max(0, (bounds.height - 18) / 2), width: cancelWidth, height: 18)
        label.frame = NSRect(x: 6, y: max(0, (bounds.height - 14) / 2), width: max(0, bounds.width - 12 - cancelWidth - (cancelWidth > 0 ? 4 : 0)), height: 14)
    }
}

/// Spec 10 §10 — "A pool tile dropped on a cue (S7) opens a popover of
/// channels with the item's drop channel picked (§6). Return or a click
/// sends ...". The channels as a list: a click on one chooses it, the arrows
/// move the pick, Return chooses the picked one, Escape closes.
@MainActor
final class ChannelPickerView: Surface, KeyList {
    let heading = Kit.content(Kit.label(size: 12.5, weight: .semibold))
    private(set) var rows: [FlatButton] = []
    private let channels: [Int]
    /// The channel Return would choose; nil until one is picked, when the drop channel is "Ask".
    private(set) var picked: Int?
    var onChoose: ((Int) -> Void)?
    var onClose: (() -> Void)?
    private let width: CGFloat = 280

    init(heading text: String, channels: [Channel], picked: Int?) {
        let sorted = channels.sorted { $0.number < $1.number }
        self.channels = sorted.map(\.number)
        self.picked = sorted.contains { $0.number == picked } ? picked : nil
        super.init(frame: .zero)
        fill = Palette.panel
        heading.stringValue = text
        heading.maximumNumberOfLines = 3
        heading.lineBreakMode = .byWordWrapping
        heading.cell?.wraps = true
        addSubview(heading)
        for channel in sorted {
            let number = channel.number
            let row = FlatButton(Strings.text(.channelsRow, number, channel.label), style: .bare) { [weak self] in self?.choose(number) }
            row.isOnRaised = true
            row.fontSize = 12.5
            rows.append(row)
            addSubview(row)
        }
        mark()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func mark() {
        for (row, channel) in zip(rows, channels) {
            row.isOn = channel == picked
            row.setAccessibilityValue(channel == picked ? "1" : "0")
        }
    }

    /// Sizes the panel to what it holds.
    func finish() {
        let inner = width - 28
        let headingHeight = ceil(heading.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 120)).height ?? 17)
        var y: CGFloat = 14
        heading.frame = NSRect(x: 14, y: y, width: inner, height: headingHeight)
        y += headingHeight + 8
        for row in rows {
            row.frame = NSRect(x: 10, y: y, width: width - 20, height: 26)
            y += 28
        }
        frame.size = NSSize(width: width, height: y + 10)
    }

    /// A click on a channel, or Return on the picked one.
    func choose(_ channel: Int) {
        guard channels.contains(channel) else { return }
        onChoose?(channel)
        onClose?()
    }

    /// The arrows move the pick, and stop at the ends.
    func move(_ delta: Int) {
        guard !channels.isEmpty else { return }
        let now = picked.flatMap { channels.firstIndex(of: $0) }
        let next = now.map { min(channels.count - 1, max(0, $0 + delta)) } ?? (delta > 0 ? 0 : channels.count - 1)
        picked = channels[next]
        mark()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)
        case 126: move(-1)
        case 36, 76:
            // "Return ... sends": the picked channel; with none picked, Return waits for a pick.
            if let picked { choose(picked) }
        case 53: onClose?()
        default: break
        }
    }

    /// The channels' titles, for a test.
    var titles: [String] { rows.map(\.title) }
}

/// One row of the pool header's imports: "each file's progress and outcome",
/// with Cancel while something waits on it and Dismiss once it is over
/// (Spec 10 §6, "Importing").
@MainActor
final class ImportRowView: Surface {
    static let height: CGFloat = 22
    let label = Kit.content(Kit.label(size: 11.5))
    let button = FlatButton(style: .bare)
    let row: ImportRow

    init(_ row: ImportRow, model: ShowModel) {
        self.row = row
        super.init(frame: .zero)
        label.stringValue = ImportWording.row(row)
        label.toolTip = label.stringValue
        // A refusal is the line to read; what ended well is quiet.
        label.textColor = row.staysUntilDismissed ? Palette.browsing : Palette.dimText
        button.fontSize = 11
        let id = row.id
        if row.canCancel {
            button.title = Strings.text(.cancel)
            button.setAccessibilityLabel(Strings.text(.dropCancel, row.name))
            button.onPress = { [weak model] in model?.imports.cancel(row: id) }
        } else if row.isOver {
            button.title = Strings.text(.importDismiss)
            button.setAccessibilityLabel(Strings.text(.importDismissLabel, row.name))
            button.onPress = { [weak model] in model?.imports.dismiss(row: id) }
        } else {
            button.isHidden = true
        }
        addSubview(label)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = button.isHidden ? 0 : button.fitting.width
        button.frame = NSRect(x: bounds.width - width, y: 1, width: width, height: 20)
        label.frame = NSRect(x: 0, y: 3, width: max(0, bounds.width - width - (width > 0 ? 8 : 0)), height: 16)
    }
}

extension PromptView {
    /// A checkbox row.
    @discardableResult
    func checkbox(_ label: String, _ isOn: Bool) -> NSButton {
        let box = NSButton(checkboxWithTitle: Strings.text(.defaultsOn), target: nil, action: nil)
        box.state = isOn ? .on : .off
        box.font = .systemFont(ofSize: 12)
        addRow(label, box)
        return box
    }

    /// A row that chooses one of a few things.
    @discardableResult
    func popup(_ label: String, _ titles: [String], selected: Int) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 12)
        popup.addItems(withTitles: titles)
        popup.selectItem(at: min(max(0, selected), max(0, titles.count - 1)))
        addRow(label, popup)
        return popup
    }
}

/// The fields of the Defaults… panel, for a test to set.
@MainActor
struct DefaultsPanel {
    let panel: PromptView
    let trimIn: ShowField
    let trimOut: ShowField
    let loop: NSButton
    let gain: ShowField
    let grade: NSPopUpButton
    let syncOffset: ShowField
    let channel: NSPopUpButton
}

extension Prompts {
    private nonisolated static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// A number as it was typed, with the Mac's decimal mark or a point; nil for anything else.
    private nonisolated static func number(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue ?? Double(text)
    }

    /// "Defaults… (a popover editing its trim in and out, loop, gain, grade,
    /// sync offset and default channel, each an `edit media sha256:…
    /// defaults.FIELD` edit, Spec 8 §5)". An empty field is no default.
    static func mediaDefaults(_ item: MediaItem, model: ShowModel) -> DefaultsPanel {
        let defaults = item.entry.defaults
        let panel = PromptView(heading: Strings.text(.defaultsHeading, MediaPool.name(of: item.entry)), width: 340)
        let seconds: (Int?) -> String = { ms in ms.map { plain(Double($0) / 1000) } ?? "" }
        let trimIn = panel.text(Strings.text(.defaultsTrimIn), seconds(defaults.trimInMs))
        let trimOut = panel.text(Strings.text(.defaultsTrimOut), seconds(defaults.trimOutMs))
        let loop = panel.checkbox(Strings.text(.defaultsLoop), defaults.loop)
        let gain = panel.text(Strings.text(.defaultsGain), defaults.gain.map(plain) ?? "")
        let grades = (model.store.catalog?.grades ?? []).sorted { $0.number < $1.number }
        let grade = panel.popup(Strings.text(.defaultsGrade), [Strings.text(.promptNone)] + grades.map { Strings.text(.channelsRow, $0.number, $0.label) },
                                selected: (grades.firstIndex { $0.number == defaults.grade }).map { $0 + 1 } ?? 0)
        let sync = panel.text(Strings.text(.defaultsSyncOffset), defaults.syncOffsetMs.map(String.init) ?? "")
        let channels = (model.store.catalog?.channels ?? []).sorted { $0.number < $1.number }
        let channel = panel.popup(Strings.text(.defaultsChannel), [Strings.text(.defaultsMachine)] + channels.map { Strings.text(.channelsRow, $0.number, $0.label) },
                                  selected: (channels.firstIndex { $0.number == defaults.defaultChannel }).map { $0 + 1 } ?? 0)
        let id = item.id
        panel.onSave = { [weak model, weak trimIn, weak trimOut, weak loop, weak gain, weak grade, weak sync, weak channel] in
            guard let model else { return nil }
            var new = defaults
            let bad = PromptView.PromptProblem.invalid(Strings.text(.defaultsBad))
            let typed: (ShowField?) -> String = { field in (field?.stringValue ?? "").trimmingCharacters(in: .whitespaces) }
            // Seconds, as a cue's times are typed; nothing typed is no trim.
            for (field, set) in [(trimIn, { new.trimInMs = $0 }), (trimOut, { new.trimOutMs = $0 })] as [(ShowField?, (Int?) -> Void)] {
                let text = typed(field)
                if text.isEmpty { set(nil); continue }
                guard let value = number(text), value >= 0 else { return bad }
                set(Int((value * 1000).rounded()))
            }
            new.loop = loop?.state == .on
            let gainText = typed(gain)
            if gainText.isEmpty {
                new.gain = nil
            } else {
                guard let value = number(gainText) else { return bad }
                new.gain = value
            }
            let syncText = typed(sync)
            if syncText.isEmpty {
                new.syncOffsetMs = nil
            } else {
                guard let value = number(syncText), value == value.rounded() else { return bad }
                new.syncOffsetMs = Int(value)
            }
            let gradeIndex = grade?.indexOfSelectedItem ?? 0
            new.grade = gradeIndex > 0 && gradeIndex <= grades.count ? grades[gradeIndex - 1].number : nil
            let channelIndex = channel?.indexOfSelectedItem ?? 0
            new.defaultChannel = channelIndex > 0 && channelIndex <= channels.count ? channels[channelIndex - 1].number : nil
            return model.setDefaults(new, of: id).map(PromptView.PromptProblem.cannot)
        }
        return DefaultsPanel(panel: panel, trimIn: trimIn, trimOut: trimOut, loop: loop, gain: gain, grade: grade, syncOffset: sync, channel: channel)
    }
}
