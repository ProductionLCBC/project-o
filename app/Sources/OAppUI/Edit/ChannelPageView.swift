// OAppUI — Spec 11 §7, the channel sheet: the channel list and the selected channel's form in the workspace, and the
// stacks that hold it in the inspector (G-31).

import AppKit
import OApp
import OCore

/// The notice line of a page's inspector: "A rejected edit puts its control back, outlined in red, and the line says
/// why in plain words"; warnings in yellow (Spec 11 §2). Announced when it appears (§10).
@MainActor
enum NoticeLine {
    static func show(_ standing: EditNotice?, in notice: NSTextField, from view: NSView) {
        guard let standing else {
            notice.stringValue = ""
            notice.isHidden = true
            return
        }
        notice.stringValue = EditModeWording.notice(standing)
        switch standing {
        case .rejected, .notSent: notice.textColor = Palette.live
        case .warnings, .skipped, .onAir: notice.textColor = Palette.browsing
        }
        notice.toolTip = notice.stringValue
        if notice.isHidden {
            NSAccessibility.post(element: view, notification: .announcementRequested,
                                 userInfo: [.announcement: notice.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        notice.isHidden = false
    }
}

/// Spec 11 §7 — one row of the channel list: "its number, label, usual content and the stacks that hold it".
@MainActor
final class ChannelRowView: NSView {
    static let height: CGFloat = 30
    let number = Kit.label(size: 12, color: Palette.faintText, mono: true)
    let name = Kit.label(size: 12.5, weight: .medium)
    let usual = Kit.label(size: 11.5, color: Palette.dimText)
    let stacks = Kit.label(size: 11.5, color: Palette.dimText)
    var isSelected = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    private(set) var channel = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Kit.content(name)
        for view in [number, name, usual, stacks] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ row: ChannelListRow) {
        channel = row.number
        number.stringValue = String(row.number)
        name.stringValue = row.label.isEmpty ? Strings.text(.editChannelUntitled, row.number) : row.label
        usual.stringValue = ChannelWorkspaceView.usualTitle(row.usualContent)
        stacks.stringValue = row.stacks.isEmpty ? Strings.text(.editChannelInNone) : row.stacks.map(String.init).joined(separator: ", ")
        setAccessibilityLabel([EditModeWording.numbered(row.number, row.label), usual.stringValue,
                               Strings.text(.editChannelStacks) + " " + stacks.stringValue].joined(separator: ", "))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let w = bounds.width
        number.frame = NSRect(x: 10, y: (h - 16) / 2, width: 24, height: 16)
        let usualX = max(150, w * 0.5)
        name.frame = NSRect(x: 38, y: (h - 16) / 2, width: usualX - 46, height: 16)
        usual.frame = NSRect(x: usualX, y: (h - 15) / 2, width: w * 0.24, height: 15)
        stacks.frame = NSRect(x: usualX + w * 0.25, y: (h - 15) / 2, width: max(0, w - usualX - w * 0.25 - 8), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Palette.selection.withAlphaComponent(0.28).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Spec 11 §7 and G-31 — the Channels page's workspace: "the channel list, each with its number, label, usual content
/// and the stacks that hold it, and beside it the selected channel's form".
@MainActor
final class ChannelWorkspaceView: NSView {
    private let model: ShowModel
    let listHeading = Kit.heading(Strings.text(.editChannelList))
    let usualHeading = Kit.heading(Strings.text(.editChannelUsual))
    let stacksHeading = Kit.heading(Strings.text(.editChannelStacks))
    private(set) var rows: [ChannelRowView] = []
    let formHeading = Kit.heading(Strings.text(.editChannelForm))
    private var names: [NSTextField] = []
    let number = EditField()
    let label = EditField()
    let defaultPreset = ChoicePopUp(label: Strings.text(.editChannelDefaultPreset))
    let transition = ChoicePopUp(label: Strings.text(.editChannelTransition))
    let audioTransition = ChoicePopUp(label: Strings.text(.editChannelAudioTransition))
    let gain = EditField()
    private let gainUnit = Kit.label(Strings.text(.editChannelGainUnit), size: 11.5, color: Palette.faintText)
    private let resets = Kit.label(Strings.text(.editChannelResets), size: 11, color: Palette.faintText)
    let decoderCap = SegmentedView([Strings.text(.editChannelDecoderMachine), "2", "3"], small: true)
    private let decoderCost = Kit.label(Strings.text(.editChannelDecoderCost), size: 11, color: Palette.faintText)
    private(set) var audioBoxes: [ChoiceBox] = []
    let thumbnail = SegmentedView([Strings.text(.editChannelBody), Strings.text(.editChannelFirstLine)], small: true)
    let usual = SegmentedView(ChannelWorkspaceView.usualOrder.map(ChannelWorkspaceView.usualTitle), small: true)
    let renderSize = SegmentedView([Strings.text(.editChannelLargest), Strings.text(.editChannelCustom)], small: true)
    let width = EditField()
    let height = EditField()
    private let by = Kit.label("×", size: 12, color: Palette.dimText)
    let sizeProblem = Kit.label(Strings.text(.editChannelBadSize), size: 11, color: Palette.live)
    /// The channel whose Custom render size was chosen and has no width and height sent yet.
    private var customFor: Int?
    /// The window, which opens the renumber popover.
    weak var host: ShowWindowView?
    /// The field committed last: outlined in red while the engine's refusal of it stands (Spec 11 §2).
    private weak var lastField: EditField?

    static let usualOrder: [UsualContent] = [.media, .text, .slide, .live, .any]

    static func usualTitle(_ usual: UsualContent) -> String {
        switch usual {
        case .media: Strings.text(.editChannelMedia)
        case .text: Strings.text(.editChannelText)
        case .slide: Strings.text(.editChannelSlide)
        case .live: Strings.text(.editChannelLive)
        case .any: Strings.text(.editChannelAny)
        }
    }

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        for key in [StringKey.editChannelNumber, .editFieldLabel, .editChannelDefaultPreset, .editChannelTransition, .editChannelAudioTransition,
                    .editChannelGain, .editChannelDecoderCap, .editChannelAudioOutputs, .editChannelThumbnail, .editChannelUsual, .editChannelRenderSize] {
            let name = Kit.label(Strings.text(key), size: 12, color: Palette.dimText)
            names.append(name)
            addSubview(name)
        }
        number.setAccessibilityLabel(Strings.text(.editChannelNumber))
        number.onCommit = { [weak self] text in
            self?.lastField = self?.number
            self?.askRenumber(text)
        }
        label.setAccessibilityLabel(Strings.text(.editFieldLabel))
        label.onCommit = { [weak self] text in
            self?.lastField = self?.label
            self?.model.editing.setChannel("label", .string(text))
        }
        defaultPreset.onChoose = { [weak self] tag in self?.model.editing.setChannel("defaultPreset", .number(Double(tag))) }
        transition.onChoose = { [weak self] tag in self?.model.editing.setChannel("defaults.transition", .number(Double(tag))) }
        audioTransition.onChoose = { [weak self] tag in self?.model.editing.setChannel("defaults.audioTransition", .number(Double(tag))) }
        gain.setAccessibilityLabel(Strings.text(.editChannelGain))
        gain.onCommit = { [weak self] text in
            guard let self else { return }
            self.lastField = self.gain
            let typed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "dB", with: "").trimmingCharacters(in: .whitespaces)
            if let decibels = Double(typed) {
                self.model.editing.setChannelGain(decibels)
            } else {
                self.gain.putBack()
                self.refresh()
            }
        }
        decoderCap.setAccessibilityLabel(Strings.text(.editChannelDecoderCap))
        decoderCap.onSelect = { [weak self] index in self?.model.editing.setChannel("decoderCap", index == 0 ? .null : .number(Double(index + 1))) }
        thumbnail.setAccessibilityLabel(Strings.text(.editChannelThumbnail))
        thumbnail.onSelect = { [weak self] index in self?.model.editing.setChannel("textThumbnail", .string(index == 1 ? "firstLine" : "body")) }
        usual.setAccessibilityLabel(Strings.text(.editChannelUsual))
        usual.onSelect = { [weak self] index in
            guard index < Self.usualOrder.count else { return }
            self?.model.editing.setChannel("usualContent", .string(Self.usualOrder[index].rawValue))
        }
        renderSize.setAccessibilityLabel(Strings.text(.editChannelRenderSize))
        renderSize.onSelect = { [weak self] index in self?.chooseRenderSize(custom: index == 1) }
        width.setAccessibilityLabel(Strings.text(.editChannelWidth))
        height.setAccessibilityLabel(Strings.text(.editChannelHeight))
        width.onCommit = { [weak self] _ in
            self?.lastField = self?.width
            self?.sendSize()
        }
        height.onCommit = { [weak self] _ in
            self?.lastField = self?.height
            self?.sendSize()
        }
        sizeProblem.isHidden = true
        for note in [resets, decoderCost] {
            note.maximumNumberOfLines = 2
            note.lineBreakMode = .byWordWrapping
            note.cell?.wraps = true
        }
        for view in [listHeading, usualHeading, stacksHeading, formHeading, number, label, defaultPreset, transition, audioTransition, gain, gainUnit,
                     resets, decoderCap, decoderCost, thumbnail, usual, renderSize, width, by, height, sizeProblem] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.channelPage
        let catalog = model.store.catalog
        // Before the fields show the model's values, so a refused one shows its value again.
        var refused = false
        if case .rejected? = editing.notice { refused = true }
        for field in [number, label, gain, width, height] { field.isRefused = refused && field === lastField }
        while rows.count < page.rows.count {
            let row = ChannelRowView()
            row.onSelect = { [weak self, weak row] in
                guard let row else { return }
                self?.model.editing.selectChannel(row.channel)
            }
            addSubview(row)
            rows.append(row)
        }
        while rows.count > page.rows.count { rows.removeLast().removeFromSuperview() }
        for (row, channel) in zip(rows, page.rows) {
            row.show(channel)
            row.isSelected = channel.number == page.channel?.number
        }
        let form: [NSView] = [formHeading, number, label, defaultPreset, transition, audioTransition, gain, gainUnit, resets, decoderCap, decoderCost,
                              thumbnail, usual, renderSize] + names
        for view in form { view.isHidden = page.channel == nil }
        for view in [listHeading, usualHeading, stacksHeading] as [NSView] { view.isHidden = page.rows.isEmpty }
        if let channel = page.channel {
            if customFor != nil, customFor != channel.number { customFor = nil }
            number.show(String(channel.number), placeholder: String(channel.number), subject: AnyHashable(channel.uuid))
            label.show(channel.label, placeholder: Strings.text(.editChannelUntitled, channel.number), subject: AnyHashable(channel.uuid))
            let presets = (catalog?.presets ?? []).sorted { $0.number < $1.number }
            defaultPreset.set(presets.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }, selected: channel.defaultPreset)
            let transitions = (catalog?.transitions ?? []).sorted { $0.number < $1.number }
            transition.set(transitions.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }, selected: channel.defaults.transition)
            let audio = (catalog?.audioTransitions ?? []).sorted { $0.number < $1.number }
            audioTransition.set(audio.map { (EditModeWording.numbered($0.number, $0.label), $0.number) }, selected: channel.defaults.audioTransition)
            gain.show(Self.decibels(channel.defaults.gain), placeholder: "0", subject: AnyHashable(channel.uuid))
            decoderCap.selected = channel.decoderCap.map { min(2, max(1, $0 - 1)) } ?? 0
            thumbnail.selected = channel.textThumbnail == .firstLine ? 1 : 0
            usual.selected = Self.usualOrder.firstIndex(of: channel.usualContent)
            // The audio outputs: a checkbox per audio output on this machine.
            for box in audioBoxes { box.removeFromSuperview() }
            audioBoxes = page.audioOutputs.map { output in
                let box = ChoiceBox(EditModeWording.numbered(output.number, output.label))
                box.state = channel.audioOutputs.contains(output.number) ? .on : .off
                box.onToggle = { [weak self] on in self?.model.editing.setChannelAudio(output: output.number, on: on) }
                addSubview(box)
                return box
            }
            // Render size: largest, or a width and height; Custom shows the fields before anything is sent.
            switch channel.renderSize {
            case .largest where customFor == nil:
                renderSize.selected = 0
                width.show("", placeholder: "1920", subject: AnyHashable(channel.uuid))
                height.show("", placeholder: "1080", subject: AnyHashable(channel.uuid))
            case .largest:
                renderSize.selected = 1
            case .size(let w, let h):
                renderSize.selected = 1
                width.show(String(w), placeholder: "1920", subject: AnyHashable(channel.uuid))
                height.show(String(h), placeholder: "1080", subject: AnyHashable(channel.uuid))
            }
        } else {
            for box in audioBoxes { box.removeFromSuperview() }
            audioBoxes = []
        }
        let custom = page.channel != nil && renderSize.selected == 1
        for view in [width, by, height] as [NSView] { view.isHidden = !custom }
        if !custom { sizeProblem.isHidden = true }
        needsLayout = true
    }

    /// "-6", "0", "4.5": a gain as the field shows it.
    static func decibels(_ gain: Double) -> String {
        gain == gain.rounded() ? String(Int(gain)) : String(format: "%.1f", gain)
    }

    private func chooseRenderSize(custom: Bool) {
        guard let channel = model.editing.channelPage.channel else { return }
        if custom {
            guard channel.renderSize == .largest else { return }
            customFor = channel.number
            refresh()
            window?.makeFirstResponder(width)
            return
        }
        customFor = nil
        model.editing.setChannel("renderSize", .string("largest"))
        refresh()
    }

    /// Return in the width or the height sends both, once both are numbers.
    private func sendSize() {
        let w = width.stringValue.isEmpty ? width.placeholderString ?? "" : width.stringValue
        let h = height.stringValue.isEmpty ? height.placeholderString ?? "" : height.stringValue
        guard let value = RenderSizeChoice.value(largest: false, width: w, height: h) else {
            sizeProblem.isHidden = false
            needsLayout = true
            return
        }
        sizeProblem.isHidden = true
        customFor = nil
        model.editing.setChannel("renderSize", value)
    }

    /// "Before it sends, a popover says what doesn't follow"; a channel on air is refused before it asks.
    private func askRenumber(_ text: String) {
        guard let typed = Int(text.trimmingCharacters(in: .whitespaces)) else {
            number.putBack()
            refresh()
            return
        }
        let plan = model.editing.renumbering(to: typed)
        let from: Int
        let heading: String
        let button: String
        switch plan {
        case .nothing:
            number.putBack()
            refresh()
            return
        case .onAir:
            model.editing.renumberChannel(to: typed)
            return
        case .renumber(let old, let new):
            from = old
            heading = Strings.text(.editChannelRenumberTitle, old, new)
            button = Strings.text(.editChannelRenumber)
        case .swap(let old, let new):
            from = old
            heading = Strings.text(.editChannelSwapTitle, old, new)
            button = Strings.text(.editChannelSwap)
        }
        let panel = PromptView(heading: heading, width: 340)
        let body = Kit.label(Strings.text(.editChannelRenumberBody, from), size: 12, color: Palette.dimText)
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        panel.addRow("", body, height: 64)
        panel.save.title = button
        var sent = false
        panel.onSave = { [weak self] in
            sent = true
            self?.model.editing.renumberChannel(to: typed)
            return nil
        }
        // Cancelled, the number goes back.
        panel.onClose = { [weak self] in
            if !sent { self?.number.putBack() }
            self?.refresh()
        }
        panel.finish()
        host?.present(panel, at: number)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 120 else { return }
        // The list on the left, the form beside it.
        let listWidth = min(max(260, w * 0.42), w - 340)
        let rowWidth = listWidth - 8
        listHeading.frame = NSRect(x: 14, y: 12, width: 160, height: 14)
        usualHeading.frame = NSRect(x: max(150, rowWidth * 0.5), y: 12, width: rowWidth * 0.24, height: 14)
        stacksHeading.frame = NSRect(x: max(150, rowWidth * 0.5) + rowWidth * 0.25, y: 12, width: rowWidth * 0.25, height: 14)
        var y: CGFloat = 32
        for row in rows {
            row.frame = NSRect(x: 4, y: y, width: rowWidth, height: ChannelRowView.height)
            y += ChannelRowView.height
        }
        // The form.
        let x = listWidth + 18
        let formWidth = w - x - 14
        formHeading.frame = NSRect(x: x, y: 12, width: 200, height: 14)
        let nameWidth = min(formWidth / 2.5, max(120, names.map { Kit.width(of: $0) }.max() ?? 0) + 12)
        let field = x + nameWidth
        let fieldWidth = min(300, formWidth - nameWidth)
        y = 34
        func place(_ index: Int, _ control: NSView, height: CGFloat = 24, width: CGFloat? = nil) {
            names[index].frame = NSRect(x: x, y: y + (height - 16) / 2, width: nameWidth - 8, height: 16)
            control.frame = NSRect(x: field, y: y, width: width ?? fieldWidth, height: height)
            y += height + 8
        }
        place(0, number, height: 26, width: 80)
        place(1, label, height: 26)
        place(2, defaultPreset)
        place(3, transition)
        place(4, audioTransition)
        place(5, gain, height: 26, width: 80)
        gainUnit.frame = NSRect(x: gain.frame.maxX + 8, y: gain.frame.minY + 5, width: max(0, formWidth - nameWidth - 88), height: 16)
        y += placeNote(resets, at: field, y: y - 4, width: max(0, formWidth - nameWidth))
        place(6, decoderCap, width: decoderCap.fitting.width)
        y += placeNote(decoderCost, at: field, y: y - 4, width: max(0, formWidth - nameWidth))
        // The audio outputs, one checkbox each, in a row.
        names[7].frame = NSRect(x: x, y: y + 2, width: nameWidth - 8, height: 16)
        var boxX = field
        for box in audioBoxes {
            let boxWidth = box.fittingSize.width + 4
            if boxX + boxWidth > w - 14, boxX > field {
                boxX = field
                y += 24
            }
            box.frame = NSRect(x: boxX, y: y, width: boxWidth, height: 20)
            boxX += boxWidth + 14
        }
        y += 30
        place(8, thumbnail, width: thumbnail.fitting.width)
        place(9, usual, width: usual.fitting.width)
        names[10].frame = NSRect(x: x, y: y + 4, width: nameWidth - 8, height: 16)
        let sizeWidth = renderSize.fitting.width
        renderSize.frame = NSRect(x: field, y: y, width: sizeWidth, height: renderSize.fitting.height)
        var sizeX = renderSize.frame.maxX + 12
        if sizeX + 148 > w - 14 {
            y += renderSize.frame.height + 8
            sizeX = field
        }
        width.frame = NSRect(x: sizeX, y: y - 1, width: 64, height: 26)
        by.frame = NSRect(x: width.frame.maxX + 4, y: y + 4, width: 12, height: 16)
        height.frame = NSRect(x: by.frame.maxX + 4, y: y - 1, width: 64, height: 26)
        y += 32
        sizeProblem.frame = NSRect(x: field, y: y - 4, width: max(0, formWidth - nameWidth), height: 15)
    }

    /// A note under a field, on one line or two: the height it takes, with the gap after it.
    private func placeNote(_ note: NSTextField, at x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let height = min(32, ceil(note.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100)).height ?? 15))
        note.frame = NSRect(x: x, y: y, width: width, height: height)
        return height + 4
    }

    override func draw(_ dirtyRect: NSRect) {
        // The line between the list and the form.
        let listWidth = min(max(260, bounds.width * 0.42), bounds.width - 340)
        Palette.hairline.setFill()
        NSRect(x: listWidth + 4, y: 8, width: 1, height: max(0, bounds.height - 16)).fill()
    }
}

/// Spec 11 §7 and G-31 — the Channels page's inspector: "the stacks that hold the channel, each with Remove from
/// Stack, and Add to Stack ▸ for the others".
@MainActor
final class ChannelInspectorView: PanelView {
    private let model: ShowModel
    let notice = Kit.content(Kit.label(size: 11.5, weight: .medium))
    let holdersHeading = Kit.heading(Strings.text(.editChannelHolders))
    let none = Kit.label(Strings.text(.editChannelHeldNone), size: 12, color: Palette.faintText)
    private(set) var holderNames: [NSTextField] = []
    private(set) var removeButtons: [FlatButton] = []
    let addToStack = NSPopUpButton(frame: .zero, pullsDown: true)

    init(model: ShowModel) {
        self.model = model
        super.init(title: "")
        notice.isHidden = true
        addToStack.setAccessibilityLabel(Strings.text(.editChannelAddToStack))
        addToStack.font = .systemFont(ofSize: 12)
        for view in [notice, holdersHeading, none, addToStack] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let editing = model.editing
        let page = editing.channelPage
        title.stringValue = page.channel.map { EditModel.name(of: $0) } ?? ""
        title.isHidden = page.channel == nil
        NoticeLine.show(editing.notice, in: notice, from: self)
        while holderNames.count < page.holders.count {
            let name = Kit.label(size: 12.5)
            let remove = FlatButton(Strings.text(.editStackRemove), style: .plain)
            remove.fontSize = 11
            addSubview(name)
            addSubview(remove)
            holderNames.append(name)
            removeButtons.append(remove)
        }
        while holderNames.count > page.holders.count {
            holderNames.removeLast().removeFromSuperview()
            removeButtons.removeLast().removeFromSuperview()
        }
        for (index, stack) in page.holders.enumerated() {
            holderNames[index].stringValue = EditModel.name(of: stack)
            removeButtons[index].onPress = { [weak model] in model?.editing.removeChannel(fromStack: stack.number) }
            removeButtons[index].setAccessibilityLabel(Strings.text(.editStackRemove) + ", " + EditModel.name(of: stack))
        }
        none.isHidden = page.channel == nil || !page.holders.isEmpty
        holdersHeading.isHidden = page.channel == nil
        // "Add to Stack ▸ for the others".
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: Strings.text(.editChannelAddToStack), action: nil, keyEquivalent: ""))
        for stack in page.others {
            menu.addItem(ClosureMenuItem(title: EditModel.name(of: stack)) { [weak model] in model?.editing.addChannel(toStack: stack.number) })
        }
        addToStack.menu = menu
        addToStack.isHidden = page.channel == nil
        addToStack.isEnabled = !page.others.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 120 else { return }
        let h = Self.headerHeight
        let titleRight = title.frame.maxX + 14
        notice.frame = NSRect(x: titleRight, y: (h - 15) / 2, width: max(0, bounds.width - titleRight - 14), height: 15)
        let column = floor(bounds.width / 4)
        let pad: CGFloat = 14
        let inner = max(0, min(column * 2, max(column, 360)) - 2 * pad)
        var y = h + 12
        holdersHeading.frame = NSRect(x: pad, y: y, width: inner, height: 14)
        y += 22
        none.frame = NSRect(x: pad, y: y + 2, width: inner, height: 16)
        for (name, remove) in zip(holderNames, removeButtons) {
            let removeWidth = remove.fitting.width
            remove.frame = NSRect(x: pad + inner - removeWidth, y: y, width: removeWidth, height: 22)
            name.frame = NSRect(x: pad, y: y + 3, width: max(0, inner - removeWidth - 8), height: 16)
            y += 28
        }
        if !none.isHidden { y += 24 }
        let size = addToStack.fittingSize
        addToStack.frame = NSRect(x: pad - 4, y: y + 4, width: min(inner, size.width + 12), height: size.height)
    }
}
