// OAppUI — Spec 11 §6, the stack editor: the slots and the stack's own fields in the workspace (G-30), and the
// outputs, the selected output, the channels and the audio routing in the inspector's four columns.

import AppKit
import OApp
import OCore

extension NSPasteboard.PasteboardType {
    /// A channel dragged from the Stacks page's Channels column into its slots (Spec 11 §6).
    static let projectOChannel = NSPasteboard.PasteboardType("org.lcbc.projecto.channel")
}

/// A pop-up of numbered choices that says which was picked: a tag per item.
@MainActor
final class ChoicePopUp: NSPopUpButton {
    var onChoose: ((Int) -> Void)?

    init(label: String) {
        super.init(frame: .zero, pullsDown: false)
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(chose)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The choices, as titles and tags, and the one shown.
    func set(_ choices: [(String, Int)], selected: Int) {
        let titles = choices.map(\.0)
        if itemTitles != titles {
            removeAllItems()
            for (title, tag) in choices {
                addItem(withTitle: title)
                lastItem?.tag = tag
            }
        }
        selectItem(withTag: selected)
    }

    @objc private func chose() {
        if let tag = selectedItem?.tag { onChoose?(tag) }
    }

    /// Chooses as the menu would.
    func choose(tag: Int) {
        selectItem(withTag: tag)
        chose()
    }
}

/// A checkbox that says when it is toggled.
@MainActor
final class ChoiceBox: NSButton {
    var onToggle: ((Bool) -> Void)?

    convenience init(_ title: String) {
        self.init(checkboxWithTitle: title, target: nil, action: nil)
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(toggled)
    }

    @objc private func toggled() { onToggle?(state == .on) }

    /// Toggles as a click would.
    func toggle() {
        state = state == .on ? .off : .on
        toggled()
    }
}

/// The ≡ at a slot's left that drags it to a new place: the press, each move and the release, in the list's space.
@MainActor
final class GripView: NSView {
    var onDrag: ((NSPoint, Bool) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.faintText.setFill()
        for row in 0..<3 {
            NSRect(x: 2, y: bounds.midY - 4 + CGFloat(row) * 3.5, width: bounds.width - 4, height: 1.5).fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.locationInWindow, false) }
    override func mouseUp(with event: NSEvent) { onDrag?(event.locationInWindow, true) }
}

/// Spec 11 §6 — one slot: "the channel's number and label, its preset and its opacity", with its menu.
@MainActor
final class SlotRowView: NSView {
    static let height: CGFloat = 44
    let grip = GripView()
    let number = Kit.label(size: 12, color: Palette.faintText, mono: true)
    let name = Kit.label(size: 12.5, weight: .medium)
    let preset = ChoicePopUp(label: Strings.text(.editStackPreset))
    let resolves = Kit.label(size: 10.5, color: Palette.dimText)
    let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let percent = Kit.label(size: 11.5, color: Palette.dimText, mono: true)
    let menuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var channel = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        opacity.controlSize = .small
        opacity.isContinuous = false
        percent.alignment = .right
        menuButton.isBordered = false
        menuButton.setAccessibilityLabel(Strings.text(.editStackSlotMenu))
        for view in [grip, number, name, preset, resolves, opacity, percent, menuButton] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ row: StackSlotRow, presets: [Preset], canMoveUp: Bool, canMoveDown: Bool) {
        channel = row.channel
        number.stringValue = String(row.channel)
        name.stringValue = row.label.isEmpty ? Strings.text(.editCuesNoChannel, row.channel) : row.label
        var choices = [(Strings.text(.editStackPresetNone), 0)]
        choices += presets.sorted { $0.number < $1.number }.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }
        preset.set(choices, selected: row.preset ?? 0)
        let drawn = presets.first { $0.number == row.resolved }
        resolves.stringValue = Strings.text(.editStackResolves, EditModeWording.numbered(row.resolved, drawn?.label ?? ""))
        opacity.doubleValue = row.opacity
        percent.stringValue = "\(Int((row.opacity * 100).rounded()))%"
        opacity.setAccessibilityLabel(Strings.text(.editStackOpacity) + ", " + name.stringValue)
        menuButton.menu?.items.dropFirst().forEach { item in
            if item.tag == 1 { item.isEnabled = canMoveUp }
            if item.tag == 2 { item.isEnabled = canMoveDown }
        }
        needsLayout = true
    }

    /// Where the preset's pop-up and the opacity's slider start in a row this wide: the columns' headings sit over them.
    static func presetX(width: CGFloat) -> CGFloat { max(200, width * 0.38) }
    static func presetWidth(width: CGFloat) -> CGFloat { min(220, max(140, width * 0.28)) }
    static func sliderX(width: CGFloat) -> CGFloat { presetX(width: width) + presetWidth(width: width) + 20 }

    override func layout() {
        super.layout()
        let h = bounds.height
        grip.frame = NSRect(x: 8, y: (h - 14) / 2, width: 14, height: 14)
        number.frame = NSRect(x: 28, y: (h - 16) / 2, width: 22, height: 16)
        let presetX = Self.presetX(width: bounds.width)
        name.frame = NSRect(x: 54, y: (h - 16) / 2, width: presetX - 64, height: 16)
        let presetWidth = Self.presetWidth(width: bounds.width)
        preset.frame = NSRect(x: presetX, y: 4, width: presetWidth, height: 22)
        resolves.frame = NSRect(x: presetX + 4, y: 26, width: presetWidth, height: 14)
        let menuX = bounds.width - 34
        menuButton.frame = NSRect(x: menuX, y: (h - 22) / 2, width: 26, height: 22)
        percent.frame = NSRect(x: menuX - 46, y: (h - 16) / 2, width: 40, height: 16)
        let sliderX = Self.sliderX(width: bounds.width)
        opacity.frame = NSRect(x: sliderX, y: (h - 18) / 2, width: max(60, percent.frame.minX - 8 - sliderX), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Spec 11 §6 and G-30 — the Stacks page's workspace: "its slots as a vertical list, the bottom slot at the bottom",
/// rows that drag to a new place and take a channel dragged in, then "The stack's own fields".
@MainActor
final class StackWorkspaceView: NSView {
    private let model: ShowModel
    let slotsHeading = Kit.heading(Strings.text(.editStackSlots))
    let presetHeading = Kit.heading(Strings.text(.editStackPreset))
    let opacityHeading = Kit.heading(Strings.text(.editStackOpacity))
    private(set) var rows: [SlotRowView] = []
    let empty = Kit.label(Strings.text(.editStackNoSlots), size: 12.5, color: Palette.faintText)
    let fieldsHeading = Kit.heading(Strings.text(.editStackFields))
    private let labelName = Kit.label(Strings.text(.editFieldLabel), size: 12, color: Palette.dimText)
    let label = EditField()
    private let baseName = Kit.label(Strings.text(.editStackBase), size: 12, color: Palette.dimText)
    let base = SegmentedView([Strings.text(.editStackBlack), Strings.text(.editStackTransparent)], small: true)
    private let defaultName = Kit.label(Strings.text(.editStackDefaultPreset), size: 12, color: Palette.dimText)
    let defaultPreset = ChoicePopUp(label: Strings.text(.editStackDefaultPreset))
    let gamma = ChoiceBox(Strings.text(.editStackGamma))
    private let gammaNote = Kit.label(Strings.text(.editStackGammaNote), size: 11.5, color: Palette.faintText)
    /// Where a dragged slot or channel would land, as a row from the top; nil while nothing is dragged.
    private(set) var dropRow: Int? { didSet { needsDisplay = true } }
    private var dragging: Int?

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        label.onCommit = { [weak self] text in self?.model.editing.setStack("label", .string(text)) }
        base.onSelect = { [weak self] index in self?.model.editing.setStack("base", .string(index == 1 ? "transparent" : "black")) }
        base.setAccessibilityLabel(Strings.text(.editStackBase))
        defaultPreset.onChoose = { [weak self] tag in self?.model.editing.setStack("defaultPreset", tag == 0 ? .null : .number(Double(tag))) }
        gamma.onToggle = { [weak self] on in self?.model.editing.setStack("gammaBlend", .bool(on)) }
        for view in [slotsHeading, presetHeading, opacityHeading, empty, fieldsHeading, labelName, label, baseName, base, defaultName,
                     defaultPreset, gamma, gammaNote] as [NSView] { addSubview(view) }
        registerForDraggedTypes([.projectOChannel])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.stackPage
        let presets = model.store.catalog?.presets ?? []
        while rows.count < page.slots.count {
            let row = SlotRowView()
            row.grip.onDrag = { [weak self, weak row] point, ended in
                guard let self, let row else { return }
                self.dragSlot(row.channel, to: self.convert(point, from: nil), ended: ended)
            }
            row.preset.onChoose = { [weak self, weak row] tag in
                guard let row else { return }
                self?.model.editing.setSlotPreset(channel: row.channel, preset: tag == 0 ? nil : tag)
            }
            row.opacity.target = self
            row.opacity.action = #selector(opacityMoved(_:))
            row.menuButton.menu = slotMenu(for: row)
            addSubview(row)
            rows.append(row)
        }
        while rows.count > page.slots.count { rows.removeLast().removeFromSuperview() }
        for (index, (row, slot)) in zip(rows, page.slots).enumerated() {
            row.show(slot, presets: presets, canMoveUp: index > 0, canMoveDown: index < page.slots.count - 1)
        }
        empty.isHidden = !page.slots.isEmpty || page.stack == nil
        let stack = page.stack
        for view in [fieldsHeading, labelName, label, baseName, base, defaultName, defaultPreset, gamma, gammaNote, slotsHeading, presetHeading,
                     opacityHeading] as [NSView] { view.isHidden = stack == nil }
        if let stack {
            label.show(stack.label, placeholder: Strings.text(.editStackUntitled, stack.number), subject: AnyHashable(stack.number))
            base.selected = stack.base == .transparent ? 1 : 0
            var choices = [(Strings.text(.editStackPresetNone), 0)]
            choices += presets.sorted { $0.number < $1.number }.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }
            defaultPreset.set(choices, selected: stack.defaultPreset ?? 0)
            gamma.state = stack.gammaBlend ? .on : .off
        }
        needsLayout = true
    }

    private func slotMenu(for row: SlotRowView) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "⋯", action: nil, keyEquivalent: ""))
        let up = ClosureMenuItem(title: Strings.text(.editMenuMoveUp)) { [weak self, weak row] in
            guard let row else { return }
            self?.model.editing.moveSlot(channel: row.channel, up: true)
        }
        up.tag = 1
        let down = ClosureMenuItem(title: Strings.text(.editMenuMoveDown)) { [weak self, weak row] in
            guard let row else { return }
            self?.model.editing.moveSlot(channel: row.channel, up: false)
        }
        down.tag = 2
        menu.addItem(up)
        menu.addItem(down)
        menu.addItem(ClosureMenuItem(title: Strings.text(.editStackEditPreset)) { [weak self, weak row] in
            guard let self, let row, let slot = self.model.editing.stackPage.slots.first(where: { $0.channel == row.channel }) else { return }
            self.model.editing.editPreset(slot.resolved, stack: self.model.editing.stackNumber)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.editStackRemove)) { [weak self, weak row] in
            guard let row else { return }
            self?.model.editing.removeSlot(channel: row.channel)
        })
        return menu
    }

    @objc private func opacityMoved(_ slider: NSSlider) {
        guard let row = rows.first(where: { $0.opacity === slider }) else { return }
        model.editing.setSlotOpacity(channel: row.channel, opacity: slider.doubleValue)
    }

    // MARK: - Dragging (Spec 11 §6)

    private var rowsTop: CGFloat { 34 }

    /// The row a point falls above, from 0 at the top to the count below the last.
    func row(at point: NSPoint) -> Int {
        min(rows.count, max(0, Int(((point.y - rowsTop) / SlotRowView.height).rounded())))
    }

    private func dragSlot(_ channel: Int, to point: NSPoint, ended: Bool) {
        if ended {
            if let target = dropRow { model.editing.moveSlot(channel: channel, toRow: target) }
            dropRow = nil
            dragging = nil
            return
        }
        dragging = channel
        dropRow = row(at: point)
    }

    /// "A channel dragged in from the right column adds a slot where it lands; a channel the stack already holds is
    /// refused before the drop lands": what a drop does, reachable without a drag.
    func accept(channel: Int, atRow row: Int) -> Bool {
        guard model.editing.canAddSlot(channel: channel) else { return false }
        model.editing.addSlot(channel: channel, atRow: row)
        return true
    }

    private func channel(in info: NSDraggingInfo) -> Int? {
        info.draggingPasteboard.string(forType: .projectOChannel).flatMap(Int.init)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let channel = channel(in: sender), model.editing.canAddSlot(channel: channel) else {
            dropRow = nil
            return []
        }
        dropRow = row(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropRow = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropRow = nil }
        guard let channel = channel(in: sender) else { return false }
        return accept(channel: channel, atRow: row(at: convert(sender.draggingLocation, from: nil)))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 120 else { return }
        let presetX = SlotRowView.presetX(width: w)
        slotsHeading.frame = NSRect(x: 14, y: 12, width: presetX - 24, height: 14)
        presetHeading.frame = NSRect(x: presetX + 4, y: 12, width: 120, height: 14)
        opacityHeading.frame = NSRect(x: SlotRowView.sliderX(width: w), y: 12, width: 120, height: 14)
        presetHeading.isHidden = rows.isEmpty || slotsHeading.isHidden
        opacityHeading.isHidden = presetHeading.isHidden
        var y = rowsTop
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: w, height: SlotRowView.height)
            y += SlotRowView.height
        }
        empty.frame = NSRect(x: 14, y: y + 10, width: w - 28, height: 18)
        if rows.isEmpty { y += 40 }
        y += 22
        fieldsHeading.frame = NSRect(x: 14, y: y, width: 200, height: 14)
        y += 24
        let nameWidth = min(w / 3, max(110, [labelName, baseName, defaultName].map { Kit.width(of: $0) }.max() ?? 0) + 14)
        labelName.frame = NSRect(x: 14, y: y + 5, width: nameWidth, height: 16)
        label.frame = NSRect(x: 14 + nameWidth, y: y, width: min(320, w - 28 - nameWidth), height: 26)
        y += 34
        baseName.frame = NSRect(x: 14, y: y + 4, width: nameWidth, height: 16)
        let baseSize = base.fitting
        base.frame = NSRect(x: 14 + nameWidth, y: y, width: baseSize.width, height: baseSize.height)
        y += 34
        defaultName.frame = NSRect(x: 14, y: y + 4, width: nameWidth, height: 16)
        defaultPreset.frame = NSRect(x: 14 + nameWidth, y: y, width: min(240, w - 28 - nameWidth), height: 24)
        y += 34
        gamma.frame = NSRect(x: 14 + nameWidth - 2, y: y, width: gamma.fittingSize.width + 4, height: 20)
        gammaNote.frame = NSRect(x: gamma.frame.maxX + 6, y: y + 2, width: max(0, w - gamma.frame.maxX - 20), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Where a dragged slot or channel would land.
        guard let row = dropRow else { return }
        Palette.selection.setFill()
        NSRect(x: 8, y: rowsTop + CGFloat(row) * SlotRowView.height - 1, width: bounds.width - 16, height: 2).fill()
    }
}

/// A channel in the Channels column, which drags into the slots.
@MainActor
final class DraggableChannelRow: NSView, NSDraggingSource {
    let name = Kit.label(size: 12)
    let mark = Kit.label(size: 12, color: Palette.outputting)
    var channel = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(name)
        addSubview(mark)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        mark.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 14, height: 16)
        name.frame = NSRect(x: 18, y: (bounds.height - 16) / 2, width: bounds.width - 18, height: 16)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDragged(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(String(channel), forType: .projectOChannel)
        let dragged = NSDraggingItem(pasteboardWriter: item)
        dragged.setDraggingFrame(bounds, contents: name.attributedStringValue)
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

/// Spec 11 §6 and G-30 — the Stacks page's inspector: "Outputs ... then, under "Not on an output", the stacks no
/// output shows"; "The selected output's properties"; "Channels"; "Audio routing".
@MainActor
final class StackInspectorView: PanelView {
    private let model: ShowModel
    let outputsHeading = Kit.heading(Strings.text(.editStackOutputs))
    private(set) var outputRows: [FlatButton] = []
    let unshownHeading = Kit.heading(Strings.text(.editStackUnshown))
    private(set) var stackRows: [FlatButton] = []
    let outputHeading = Kit.heading("")
    private let deviceName = Kit.label(Strings.text(.editStackDevice), size: 11.5, color: Palette.dimText)
    let device = Kit.content(Kit.label(size: 11.5))
    private let formatName = Kit.label(Strings.text(.editStackFormat), size: 11.5, color: Palette.dimText)
    let format = Kit.content(Kit.label(size: 11.5))
    let changeInSettings = FlatButton(Strings.text(.editStackChangeInSettings), style: .plain)
    private let defaultName = Kit.label(Strings.text(.editStackDefaultStack), size: 11.5, color: Palette.dimText)
    let defaultStack = ChoicePopUp(label: Strings.text(.editStackDefaultStack))
    private let switchName = Kit.label(Strings.text(.editStackSwitch), size: 11.5, color: Palette.dimText)
    let switchTransition = ChoicePopUp(label: Strings.text(.editStackSwitch))
    private let blackoutName = Kit.label(Strings.text(.editStackBlackout), size: 11.5, color: Palette.dimText)
    let blackoutTransition = ChoicePopUp(label: Strings.text(.editStackBlackout))
    let setDefault = FlatButton(Strings.text(.editStackSetDefault), style: .plain)
    let channelsHeading = Kit.heading(Strings.text(.editStackChannels))
    private(set) var channelRows: [DraggableChannelRow] = []
    let audioHeading = Kit.heading(Strings.text(.editStackAudio))
    private(set) var audioNames: [NSTextField] = []
    private(set) var audioColumns: [NSTextField] = []
    private(set) var audioBoxes: [[ChoiceBox]] = []

    init(model: ShowModel) {
        self.model = model
        super.init(title: "")
        changeInSettings.isEnabled = false
        changeInSettings.reason = Strings.text(.unavailableLater)
        changeInSettings.fontSize = 11
        setDefault.fontSize = 11
        setDefault.onPress = { [weak model] in model?.editing.setAsDefault() }
        defaultStack.onChoose = { [weak model] tag in model?.editing.setOutput("defaultStack", tag) }
        switchTransition.onChoose = { [weak model] tag in model?.editing.setOutput("transitions.switch", tag) }
        blackoutTransition.onChoose = { [weak model] tag in model?.editing.setOutput("transitions.blackout", tag) }
        for view in [outputsHeading, unshownHeading, outputHeading, deviceName, device, formatName, format, changeInSettings, defaultName, defaultStack,
                     switchName, switchTransition, blackoutName, blackoutTransition, setDefault, channelsHeading, audioHeading] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.stackPage
        let catalog = model.store.catalog
        title.stringValue = page.stack.map { EditModel.name(of: $0) } ?? ""
        title.isHidden = page.stack == nil
        // Outputs, then the stacks no output shows.
        rebuild(&outputRows, count: page.outputs.count)
        for (button, output) in zip(outputRows, page.outputs) {
            button.title = Strings.text(.editStackOutputRow, output.number, output.label, output.liveStack)
            button.isOn = output.number == editing.outputNumber
            button.onPress = { [weak model] in model?.editing.selectOutput(output.number) }
        }
        rebuild(&stackRows, count: page.unshown.count)
        for (button, stack) in zip(stackRows, page.unshown) {
            button.title = EditModel.name(of: stack)
            button.isOn = stack.number == page.stack?.number
            button.onPress = { [weak model] in model?.editing.selectStack(stack.number) }
        }
        unshownHeading.isHidden = page.unshown.isEmpty
        // The selected output.
        let output = editing.outputNumber.flatMap { number in catalog?.outputs.first { $0.number == number } }
        Kit.setHeading(outputHeading, output.map { Strings.text(.editStackOutput, $0.number) } ?? "")
        // The device by the name the Mac gives it, as the top bar's output details say it; its address when unseen.
        let devices = model.store.devices
        device.stringValue = output.map { output in
            devices?.screens.first { $0.device == output.device }?.name ?? devices?.ports.first { $0.device == output.device }?.name ?? output.device
        } ?? ""
        device.toolTip = output?.device
        device.lineBreakMode = .byTruncatingMiddle
        format.stringValue = output.map { ShowWording.format($0.format) } ?? ""
        let stacks = (catalog?.stacks ?? []).sorted { $0.number < $1.number }
        defaultStack.set(stacks.map { (EditModel.name(of: $0), $0.number) }, selected: output?.defaultStack ?? 0)
        // "offering transitions that apply to pixels".
        let transitions = (catalog?.transitions ?? []).sorted { $0.number < $1.number }.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }
        switchTransition.set(transitions, selected: output?.transitions.switch ?? 0)
        blackoutTransition.set(transitions, selected: output?.transitions.blackout ?? 0)
        let live = model.outputDots.first { $0.number == output?.number }?.stack
        setDefault.isEnabled = live != nil && live != output?.defaultStack
        for view in [outputHeading, deviceName, device, formatName, format, changeInSettings, defaultName, defaultStack, switchName, switchTransition,
                     blackoutName, blackoutTransition, setDefault] as [NSView] { view.isHidden = output == nil }
        // The channels, those the stack holds marked.
        while channelRows.count < page.channels.count {
            let row = DraggableChannelRow()
            addSubview(row)
            channelRows.append(row)
        }
        while channelRows.count > page.channels.count { channelRows.removeLast().removeFromSuperview() }
        for (row, channel) in zip(channelRows, page.channels) {
            row.channel = channel.number
            row.name.stringValue = EditModeWording.numbered(channel.number, channel.label)
            row.mark.stringValue = channel.isHeld ? "✓" : ""
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.button)
            row.setAccessibilityLabel(channel.isHeld ? Strings.text(.editStackHeld, row.name.stringValue) : row.name.stringValue)
        }
        // The audio routing table.
        rebuildLabels(&audioColumns, count: page.audioOutputs.count)
        for (label, audio) in zip(audioColumns, page.audioOutputs) {
            label.stringValue = String(audio.number)
            label.toolTip = audio.label
        }
        rebuildLabels(&audioNames, count: page.channels.count)
        for (label, channel) in zip(audioNames, page.channels) { label.stringValue = EditModeWording.numbered(channel.number, channel.label) }
        for row in audioBoxes { row.forEach { $0.removeFromSuperview() } }
        audioBoxes = page.channels.map { channel in
            page.audioOutputs.map { audio in
                let box = ChoiceBox("")
                box.state = channel.audioOutputs.contains(audio.number) ? .on : .off
                box.setAccessibilityLabel(Strings.text(.editStackAudioCell, channel.number, audio.number))
                box.onToggle = { [weak model] on in model?.editing.setAudio(channel: channel.number, output: audio.number, on: on) }
                addSubview(box)
                return box
            }
        }
        needsLayout = true
    }

    private func rebuild(_ buttons: inout [FlatButton], count: Int) {
        while buttons.count < count {
            let button = FlatButton("", style: .bare)
            button.fontSize = 12
            button.leading = true
            addSubview(button)
            buttons.append(button)
        }
        while buttons.count > count { buttons.removeLast().removeFromSuperview() }
    }

    private func rebuildLabels(_ labels: inout [NSTextField], count: Int) {
        while labels.count < count {
            let label = Kit.label(size: 11.5, color: Palette.dimText)
            addSubview(label)
            labels.append(label)
        }
        while labels.count > count { labels.removeLast().removeFromSuperview() }
    }

    override func layout() {
        super.layout()
        // Not placed while show mode leaves it at no size.
        guard bounds.width > 120 else { return }
        let column = floor(bounds.width / 4)
        let pad: CGFloat = 14
        let top = Self.headerHeight + 12
        let inner = column - 2 * pad
        // Outputs.
        outputsHeading.frame = NSRect(x: pad, y: top, width: inner, height: 14)
        var y = top + 22
        for button in outputRows {
            button.frame = NSRect(x: pad - 6, y: y, width: inner + 6, height: 24)
            y += 26
        }
        if !unshownHeading.isHidden {
            y += 8
            unshownHeading.frame = NSRect(x: pad, y: y, width: inner, height: 14)
            y += 22
        }
        for button in stackRows {
            button.frame = NSRect(x: pad - 6, y: y, width: inner + 6, height: 24)
            y += 26
        }
        // The selected output.
        var x = column + pad
        outputHeading.frame = NSRect(x: x, y: top, width: inner, height: 14)
        // The names' column as wide as its widest name, in any language, up to half the column.
        let names = [deviceName, formatName, defaultName, switchName, blackoutName]
        let nameWidth = min(inner / 2, max(80, names.map { Kit.width(of: $0) }.max() ?? 0) + 10)
        y = top + 22
        for (name, value) in [(deviceName, device), (formatName, format)] {
            name.frame = NSRect(x: x, y: y, width: nameWidth, height: 16)
            value.frame = NSRect(x: x + nameWidth, y: y, width: inner - nameWidth, height: 16)
            y += 20
        }
        for (name, popup) in [(defaultName, defaultStack), (switchName, switchTransition), (blackoutName, blackoutTransition)] {
            name.frame = NSRect(x: x, y: y + 4, width: nameWidth, height: 16)
            popup.frame = NSRect(x: x + nameWidth - 4, y: y, width: inner - nameWidth + 4, height: 24)
            y += 28
        }
        let setWidth = setDefault.fitting.width
        setDefault.frame = NSRect(x: x, y: y + 2, width: setWidth, height: 22)
        changeInSettings.frame = NSRect(x: x + setWidth + 8, y: y + 2, width: min(changeInSettings.fitting.width, inner - setWidth - 8), height: 22)
        // Channels.
        x = 2 * column + pad
        channelsHeading.frame = NSRect(x: x, y: top, width: inner, height: 14)
        y = top + 22
        for row in channelRows {
            row.frame = NSRect(x: x, y: y, width: inner, height: 22)
            y += 24
        }
        // Audio routing: channels down, audio outputs across.
        x = 3 * column + pad
        audioHeading.frame = NSRect(x: x, y: top, width: inner, height: 14)
        let nameColumn = min(130, inner * 0.55)
        let cell = min(34, max(22, (inner - nameColumn) / CGFloat(max(1, audioColumns.count))))
        for (index, label) in audioColumns.enumerated() {
            label.alignment = .center
            label.frame = NSRect(x: x + nameColumn + CGFloat(index) * cell, y: top + 20, width: cell, height: 14)
        }
        y = top + 40
        for (rowIndex, label) in audioNames.enumerated() {
            label.frame = NSRect(x: x, y: y + 2, width: nameColumn - 4, height: 16)
            for (index, box) in (rowIndex < audioBoxes.count ? audioBoxes[rowIndex] : []).enumerated() {
                box.frame = NSRect(x: x + nameColumn + CGFloat(index) * cell + (cell - 18) / 2, y: y, width: 18, height: 20)
            }
            y += 24
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        let column = floor(bounds.width / 4)
        for index in 1..<4 {
            NSRect(x: CGFloat(index) * column, y: Self.headerHeight, width: 1, height: bounds.height - Self.headerHeight).fill()
        }
    }
}
