// OAppUI — Spec 11 §6 and G-30, the stack editor: in the workspace, two tall columns, the slots with their Add Channel
// row and the stack's own fields, then the outputs, the selected output and the audio routing. The stacks themselves
// are the page's list (PageListView).

import AppKit
import OApp
import OCore

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

/// Spec 11 §6 — one slot: "the channel's number and label, its preset and its opacity", with its menu. The opacity's
/// slider has a field beside it that takes a typed percentage (§1).
@MainActor
final class SlotRowView: NSView {
    static let height: CGFloat = 46
    let grip = GripView()
    let number = Kit.label(size: 12, color: Palette.faintText, mono: true)
    let name = Kit.content(Kit.label(size: 12.5, weight: .medium))
    let preset = ChoicePopUp(label: Strings.text(.editStackPreset))
    let resolves = Kit.label(size: 10.5, color: Palette.dimText)
    let opacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let percent = EditField()
    let more = FlatButton("⋯", style: .bare)
    private(set) var channel = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        opacity.controlSize = .small
        opacity.isContinuous = false
        percent.alignment = .right
        more.chevron = false
        more.fontSize = 13
        more.setAccessibilityLabel(Strings.text(.editStackSlotMenu))
        for view in [grip, number, name, preset, resolves, opacity, percent, more] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ row: StackSlotRow, presets: [Preset]) {
        channel = row.channel
        number.stringValue = String(row.channel)
        name.stringValue = row.label.isEmpty ? Strings.text(.editChannelUntitled, row.channel) : row.label
        var choices = [(Strings.text(.editStackPresetNone), 0)]
        choices += presets.sorted { $0.number < $1.number }.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }
        preset.set(choices, selected: row.preset ?? 0)
        let drawn = presets.first { $0.number == row.resolved }
        resolves.stringValue = Strings.text(.editStackResolves, EditModeWording.numbered(row.resolved, drawn?.label ?? ""))
        opacity.doubleValue = row.opacity
        percent.show(FormNumber.text(row.opacity * 100, places: 0) + "%", subject: AnyHashable(row.channel))
        opacity.setAccessibilityLabel(Strings.text(.editStackOpacity) + ", " + name.stringValue)
        percent.setAccessibilityLabel(Strings.text(.editStackOpacity) + " %, " + name.stringValue)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let w = bounds.width
        grip.frame = NSRect(x: 8, y: (h - 14) / 2, width: 14, height: 14)
        number.frame = NSRect(x: 28, y: 6, width: 22, height: 16)
        name.frame = NSRect(x: 50, y: 6, width: max(0, w * 0.42 - 54), height: 17)
        // The preset under the name; the opacity at the right.
        preset.frame = NSRect(x: 46, y: 23, width: max(120, w * 0.42 - 46), height: 20)
        resolves.frame = NSRect(x: preset.frame.maxX + 8, y: 26, width: max(0, w * 0.58 - 100), height: 14)
        more.frame = NSRect(x: w - 32, y: 4, width: 26, height: 22)
        percent.frame = NSRect(x: w - 32 - 50, y: 3, width: 44, height: 22)
        let sliderX = w * 0.42 + 8
        opacity.frame = NSRect(x: sliderX, y: 5, width: max(40, percent.frame.minX - 8 - sliderX), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}

/// Spec 11 §6 and G-30 — the Stacks page's workspace: "two tall columns", the slots ("the bottom slot at the bottom")
/// with Add Channel as their + row and the stack's own fields under them; then the outputs, the selected output's
/// properties and the audio routing.
@MainActor
final class StackWorkspaceView: NSView {
    private let model: ShowModel
    let slotsHeading = Kit.heading(Strings.text(.editStackSlots))
    private(set) var rows: [SlotRowView] = []
    /// Spec 11 §6 — "Under the rows, the list's + row, Add Channel, offers the library's channels the stack doesn't hold".
    let addChannel = FlatButton("", style: .bare)
    let fieldsHeading = Kit.heading(Strings.text(.editStackFields))
    private let labelName = Kit.label(Strings.text(.editFieldLabel), size: 12, color: Palette.dimText)
    let label = EditField()
    private let baseName = Kit.label(Strings.text(.editStackBase), size: 12, color: Palette.dimText)
    let base = SegmentedView([Strings.text(.editStackBlack), Strings.text(.editStackTransparent)], small: true)
    private let defaultName = Kit.label(Strings.text(.editStackDefaultPreset), size: 12, color: Palette.dimText)
    let defaultPreset = ChoicePopUp(label: Strings.text(.editStackDefaultPreset))
    let gamma = ChoiceBox(Strings.text(.editStackGamma))
    private let gammaNote = Kit.label(Strings.text(.editStackGammaNote), size: 11.5, color: Palette.faintText)
    /// The second column.
    let outputs: StackOutputsView
    /// Where a dragged slot would land, as a row from the top; nil while nothing is dragged.
    private(set) var dropRow: Int? { didSet { needsDisplay = true } }
    /// The field committed last: outlined in red while the engine's refusal of it stands.
    private weak var lastField: EditField?

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        outputs = StackOutputsView(model: model)
        super.init(frame: .zero)
        label.onCommit = { [weak self] text in
            self?.lastField = self?.label
            self?.model.editing.setStack("label", .string(text))
        }
        base.onSelect = { [weak self] index in self?.model.editing.setStack("base", .string(index == 1 ? "transparent" : "black")) }
        base.setAccessibilityLabel(Strings.text(.editStackBase))
        defaultPreset.onChoose = { [weak self] tag in self?.model.editing.setStack("defaultPreset", tag == 0 ? .null : .number(Double(tag))) }
        gamma.onToggle = { [weak self] on in self?.model.editing.setStack("gammaBlend", .bool(on)) }
        addChannel.leading = true
        addChannel.chevron = false
        addChannel.fontSize = 12.5
        addChannel.title = "+  " + Strings.text(.editStackAddChannel)
        addChannel.setAccessibilityLabel(Strings.text(.editStackAddChannel))
        for view in [slotsHeading, addChannel, fieldsHeading, labelName, label, baseName, base, defaultName, defaultPreset, gamma, gammaNote,
                     outputs.scroll] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.stackPage
        let presets = model.store.catalog?.presets ?? []
        var refused = false
        if case .rejected? = editing.notice { refused = true }
        label.isRefused = refused && lastField === label
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
            row.percent.onCommit = { [weak self, weak row] text in
                guard let self, let row else { return }
                if let value = FormNumber.value(text) {
                    self.lastField = row.percent
                    self.model.editing.setSlotOpacity(channel: row.channel, opacity: value / 100)
                } else {
                    row.percent.putBack()
                    self.refresh()
                }
            }
            addSubview(row)
            rows.append(row)
        }
        while rows.count > page.slots.count { rows.removeLast().removeFromSuperview() }
        for (index, (row, slot)) in zip(rows, page.slots).enumerated() {
            row.show(slot, presets: presets)
            row.more.dropMenu = slotMenu(channel: slot.channel, canMoveUp: index > 0, canMoveDown: index < page.slots.count - 1)
            row.percent.isRefused = refused && lastField === row.percent
        }
        // Add Channel: the channels the stack doesn't hold, since a channel appears once per stack.
        let menu = NSMenu()
        menu.autoenablesItems = false
        for channel in page.channels where !channel.isHeld {
            menu.addItem(ClosureMenuItem(title: EditModeWording.numbered(channel.number, channel.label)) { [weak model] in
                model?.editing.addSlot(channel: channel.number, atRow: 0)
            })
        }
        addChannel.dropMenu = menu
        addChannel.isEnabled = page.stack != nil && !menu.items.isEmpty
        let stack = page.stack
        for view in [fieldsHeading, labelName, label, baseName, base, defaultName, defaultPreset, gamma, gammaNote, slotsHeading, addChannel] as [NSView] {
            view.isHidden = stack == nil
        }
        if let stack {
            label.show(stack.label, placeholder: Strings.text(.editStackUntitled, stack.number), subject: AnyHashable(stack.number))
            base.selected = stack.base == .transparent ? 1 : 0
            var choices = [(Strings.text(.editStackPresetNone), 0)]
            choices += presets.sorted { $0.number < $1.number }.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }
            defaultPreset.set(choices, selected: stack.defaultPreset ?? 0)
            gamma.state = stack.gammaBlend ? .on : .off
        }
        outputs.refresh()
        needsLayout = true
    }

    /// A slot's ⋯: Move Up, Move Down, Edit Preset and Remove from Stack.
    private func slotMenu(channel: Int, canMoveUp: Bool, canMoveDown: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let up = ClosureMenuItem(title: Strings.text(.editMenuMoveUp)) { [weak model] in model?.editing.moveSlot(channel: channel, up: true) }
        up.isEnabled = canMoveUp
        let down = ClosureMenuItem(title: Strings.text(.editMenuMoveDown)) { [weak model] in model?.editing.moveSlot(channel: channel, up: false) }
        down.isEnabled = canMoveDown
        menu.addItem(up)
        menu.addItem(down)
        menu.addItem(ClosureMenuItem(title: Strings.text(.editStackEditPreset)) { [weak model] in
            guard let editing = model?.editing, let slot = editing.stackPage.slots.first(where: { $0.channel == channel }) else { return }
            editing.editPreset(slot.resolved, stack: editing.stackNumber)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.editStackRemove)) { [weak model] in model?.editing.removeSlot(channel: channel) })
        return menu
    }

    @objc private func opacityMoved(_ slider: NSSlider) {
        guard let row = rows.first(where: { $0.opacity === slider }) else { return }
        model.editing.setSlotOpacity(channel: row.channel, opacity: slider.doubleValue)
    }

    // MARK: - Dragging a slot (Spec 11 §6)

    private var rowsTop: CGFloat { 36 }

    /// The row a point falls above, from 0 at the top to the count below the last.
    func row(at point: NSPoint) -> Int {
        min(rows.count, max(0, Int(((point.y - rowsTop) / SlotRowView.height).rounded())))
    }

    private func dragSlot(_ channel: Int, to point: NSPoint, ended: Bool) {
        if ended {
            if let target = dropRow { model.editing.moveSlot(channel: channel, toRow: target) }
            dropRow = nil
            return
        }
        dropRow = row(at: point)
    }

    /// The first column's width: the slots and the stack's fields.
    private var firstWidth: CGFloat { max(300, min(560, (bounds.width - 12) * 0.56)) }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 120 else { return }
        let first = firstWidth
        slotsHeading.frame = NSRect(x: 14, y: 14, width: first - 28, height: 14)
        var y = rowsTop
        for row in rows {
            row.frame = NSRect(x: 0, y: y, width: first, height: SlotRowView.height)
            y += SlotRowView.height
        }
        addChannel.frame = NSRect(x: 4, y: y + 4, width: first - 8, height: 28)
        y += 48
        fieldsHeading.frame = NSRect(x: 14, y: y, width: first - 28, height: 14)
        y += 24
        let nameWidth = min(first / 2.5, max(110, [labelName, baseName, defaultName].map { Kit.width(of: $0) }.max() ?? 0) + 14)
        labelName.frame = NSRect(x: 14, y: y + 5, width: nameWidth, height: 16)
        label.frame = NSRect(x: 14 + nameWidth, y: y, width: min(320, first - 28 - nameWidth), height: 26)
        y += 34
        baseName.frame = NSRect(x: 14, y: y + 4, width: nameWidth, height: 16)
        let baseSize = base.fitting
        base.frame = NSRect(x: 14 + nameWidth, y: y, width: baseSize.width, height: baseSize.height)
        y += 34
        defaultName.frame = NSRect(x: 14, y: y + 4, width: nameWidth, height: 16)
        defaultPreset.frame = NSRect(x: 14 + nameWidth, y: y, width: min(240, first - 28 - nameWidth), height: 24)
        y += 34
        gamma.frame = NSRect(x: 14 + nameWidth - 2, y: y, width: gamma.fittingSize.width + 4, height: 20)
        y += 22
        gammaNote.frame = NSRect(x: 14 + nameWidth, y: y, width: max(0, first - nameWidth - 28), height: 16)
        // The second column, beyond a hairline.
        outputs.scroll.frame = NSRect(x: first + 12, y: 0, width: max(0, w - first - 12), height: bounds.height)
        outputs.place()
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.setFill()
        NSRect(x: firstWidth + 6, y: 10, width: 1, height: max(0, bounds.height - 20)).fill()
        // Where a dragged slot would land.
        guard let row = dropRow else { return }
        Palette.selection.setFill()
        NSRect(x: 8, y: rowsTop + CGFloat(row) * SlotRowView.height - 1, width: firstWidth - 16, height: 2).fill()
    }
}

/// Spec 11 §6 and G-30 — the Stacks page's second column: "Outputs ... then, under "Not on an output", the stacks no
/// output shows"; "The selected output's properties"; "Audio routing". It scrolls when the window is short.
@MainActor
final class StackOutputsView: NSView {
    private let model: ShowModel
    let scroll = NSScrollView()
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
    let audioHeading = Kit.heading(Strings.text(.editStackAudio))
    private(set) var audioNames: [NSTextField] = []
    private(set) var audioColumns: [NSTextField] = []
    private(set) var audioBoxes: [[ChoiceBox]] = []

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        changeInSettings.isEnabled = false
        changeInSettings.reason = Strings.text(.unavailableLater)
        changeInSettings.fontSize = 11
        setDefault.fontSize = 11
        setDefault.onPress = { [weak model] in model?.editing.setAsDefault() }
        device.lineBreakMode = .byTruncatingMiddle
        defaultStack.onChoose = { [weak model] tag in model?.editing.setOutput("defaultStack", tag) }
        switchTransition.onChoose = { [weak model] tag in model?.editing.setOutput("transitions.switch", tag) }
        blackoutTransition.onChoose = { [weak model] tag in model?.editing.setOutput("transitions.blackout", tag) }
        for view in [outputsHeading, unshownHeading, outputHeading, deviceName, device, formatName, format, changeInSettings, defaultName, defaultStack,
                     switchName, switchTransition, blackoutName, blackoutTransition, setDefault, audioHeading] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.stackPage
        let catalog = model.store.catalog
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
        // The selected output, by the name the Mac gives its device, as the top bar's output details say it.
        let output = editing.outputNumber.flatMap { number in catalog?.outputs.first { $0.number == number } }
        Kit.setHeading(outputHeading, output.map { Strings.text(.editStackOutput, $0.number) } ?? "")
        let devices = model.store.devices
        device.stringValue = output.map { output in
            devices?.screens.first { $0.device == output.device }?.name ?? devices?.ports.first { $0.device == output.device }?.name ?? output.device
        } ?? ""
        device.toolTip = output?.device
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
        // The audio routing table: channels down, audio outputs across.
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

    /// Lays the column out top down at the scroll view's width, and sizes itself to it.
    func place() {
        let width = max(0, scroll.contentSize.width)
        guard width > 120 else { return }
        let pad: CGFloat = 14
        let inner = width - 2 * pad
        var y: CGFloat = 14
        outputsHeading.frame = NSRect(x: pad, y: y, width: inner, height: 14)
        y += 22
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
        y += 14
        outputHeading.frame = NSRect(x: pad, y: y, width: inner, height: 14)
        y += 22
        let names = [deviceName, formatName, defaultName, switchName, blackoutName]
        let nameWidth = min(inner / 2, max(80, names.map { Kit.width(of: $0) }.max() ?? 0) + 10)
        for (name, value) in [(deviceName, device), (formatName, format)] {
            name.frame = NSRect(x: pad, y: y, width: nameWidth, height: 16)
            value.frame = NSRect(x: pad + nameWidth, y: y, width: inner - nameWidth, height: 16)
            y += 20
        }
        for (name, popup) in [(defaultName, defaultStack), (switchName, switchTransition), (blackoutName, blackoutTransition)] {
            name.frame = NSRect(x: pad, y: y + 4, width: nameWidth, height: 16)
            popup.frame = NSRect(x: pad + nameWidth - 4, y: y, width: min(260, inner - nameWidth + 4), height: 24)
            y += 28
        }
        let setWidth = setDefault.fitting.width
        setDefault.frame = NSRect(x: pad, y: y + 2, width: setWidth, height: 22)
        changeInSettings.frame = NSRect(x: pad + setWidth + 8, y: y + 2, width: min(changeInSettings.fitting.width, max(0, inner - setWidth - 8)), height: 22)
        y += 40
        // Audio routing.
        audioHeading.frame = NSRect(x: pad, y: y, width: inner, height: 14)
        y += 20
        let nameColumn = min(160, inner * 0.55)
        let cell = min(36, max(24, (inner - nameColumn) / CGFloat(max(1, audioColumns.count))))
        for (index, label) in audioColumns.enumerated() {
            label.alignment = .center
            label.frame = NSRect(x: pad + nameColumn + CGFloat(index) * cell, y: y, width: cell, height: 14)
        }
        y += 20
        for (rowIndex, label) in audioNames.enumerated() {
            label.frame = NSRect(x: pad, y: y + 2, width: nameColumn - 4, height: 16)
            for (index, box) in (rowIndex < audioBoxes.count ? audioBoxes[rowIndex] : []).enumerated() {
                box.frame = NSRect(x: pad + nameColumn + CGFloat(index) * cell + (cell - 18) / 2, y: y, width: 18, height: 20)
            }
            y += 24
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + 14, scroll.contentSize.height))
    }
}
