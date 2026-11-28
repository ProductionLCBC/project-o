// OAppUI — Spec 11 §2, "The monitors": Preview over Program.

import AppKit
import OApp
import OCore

/// Spec 11 §2, "Preview" — "the engine's picture of what the page has
/// selected (choice A-1), outlined in the selection's blue ... Its header
/// holds the stack picker, which is show mode's preview stack".
@MainActor
final class PreviewPanelView: PanelView {
    private let model: ShowModel
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let frame_ = Surface()
    let picture = NSImageView()
    /// G-30 — on the Stacks page, the stack's live picture, "the stack's preview surface before blackout" (Spec 11 §6).
    let live = SurfaceView()
    /// On the Channels page, the channel's text, which has no picture of its own, or that it is empty.
    let caption = Kit.content(Kit.label(size: 13))
    var mach: MachLink?
    var machineRoot: URL? { didSet { refresh() } }
    private var shownFile: String?

    init(model: ShowModel) {
        self.model = model
        super.init(title: Strings.text(.editPreview))
        picker.font = .systemFont(ofSize: 12)
        picker.isBordered = false
        picker.target = self
        picker.action = #selector(picked)
        picker.setAccessibilityLabel(Strings.text(.previewPicker))
        frame_.fill = Palette.well
        frame_.radius = 4
        frame_.outline = Palette.selection
        frame_.outlineWidth = 2
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityElement(false)
        frame_.addSubview(picture)
        frame_.addSubview(live)
        caption.alignment = .center
        caption.maximumNumberOfLines = 6
        caption.lineBreakMode = .byWordWrapping
        caption.cell?.wraps = true
        caption.isHidden = true
        frame_.addSubview(caption)
        frame_.setAccessibilityElement(true)
        frame_.setAccessibilityRole(.image)
        addSubview(picker)
        addSubview(hiding)
        addSubview(frame_)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func picked() {
        let number = picker.selectedItem?.tag
        // On the Stacks and Channels pages the picker is the page's own: it picks the stack or the channel edited.
        if model.editing.page == .stacks, let number {
            model.editing.selectStack(number)
            return
        }
        if model.editing.page == .channels, let number {
            model.editing.selectChannel(number)
            return
        }
        // G-32 — on the Presets page it names the stack the canvas is drawn at: for `*`, any stack; else the stack's tab.
        if model.editing.page == .presets, let number {
            if model.editing.presetTab == .any { model.editing.setCanvasStack(number) } else { model.editing.selectTab(.stack(number)) }
            return
        }
        model.change { $0.previewStack = number }
    }

    /// The live picture, at the display's pace, on a page that shows one: the stack's (G-30), or the channel's, the
    /// strip's picture of it (G-31).
    func draw() {
        switch model.editing.page {
        case .stacks: live.set(model.editing.stackNumber.flatMap { mach?.preview(stack: $0) })
        case .channels: live.set(model.editing.sheetChannel.flatMap { mach?.picture(channel: $0) })
        // G-32 — "the live picture of the stack the layout tab names (the thumbnail stack's for `*`)".
        case .presets: live.set(model.editing.canvasStack.flatMap { mach?.preview(stack: $0) })
        // Spec 11 §9 as corrected 2026-11-25 — "the live picture of the stack its picker names, as on the Stacks page".
        case .objects: live.set(mach?.preview(stack: model.previewStack))
        default: return
        }
    }

    func refresh() {
        let stacks = (model.store.catalog?.stacks ?? []).sorted { $0.number < $1.number }
        let page = model.editing.page
        let onStacks = page == .stacks
        let showsLive = page == .stacks || page == .channels || page == .presets || page == .objects
        let selected = onStacks ? (model.editing.stackNumber ?? model.previewStack)
            : page == .presets ? (model.editing.canvasStack ?? model.previewStack) : model.previewStack
        live.isHidden = !showsLive
        picture.isHidden = showsLive
        picker.removeAllItems()
        if page == .channels {
            let channels = (model.store.catalog?.channels ?? []).sorted { $0.number < $1.number }
            for channel in channels {
                picker.addItem(withTitle: EditModel.name(of: channel))
                picker.lastItem?.tag = channel.number
            }
            picker.selectItem(withTag: model.editing.sheetChannel ?? 0)
        } else {
            for stack in stacks {
                picker.addItem(withTitle: EditModeWording.stack(number: stack.number, label: stack.label))
                picker.lastItem?.tag = stack.number
            }
            picker.selectItem(withTag: selected)
        }
        let editing = model.editing
        let preview = editing.preview
        if preview.file != shownFile {
            shownFile = preview.file
            if let file = preview.file, let root = machineRoot {
                picture.image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] image in
                    if self?.shownFile == file { self?.picture.image = image }
                }
            } else {
                picture.image = nil
            }
        }
        let number = editing.selection.first(in: editing.grid.headers.map(\.uuid)).flatMap { editing.grid.cue(of: $0) }.map { $0 + 1 }
        frame_.setAccessibilityLabel(EditModeWording.previewSpoken(cue: editing.page == .cues || editing.page == .text ? number : nil, stack: selected,
                                                                   label: stacks.first { $0.number == selected }?.label ?? ""))
        // Spec 10 §2 — "Text gets no picture, since it has no look until a box gives it one": the channel's text shows
        // in its place, as the strip's cell shows it; an empty channel says so.
        caption.isHidden = true
        if page == .channels, let channel = editing.sheetChannel {
            let content = model.store.channels[channel]?.content
            frame_.setAccessibilityLabel(Strings.text(.editPreview) + ", " + (editing.channelPage.channel.map { EditModel.name(of: $0) } ?? String(channel)))
            if case .text(let fields)? = content?.kind {
                caption.stringValue = fields["body"] ?? fields.values.sorted().first ?? content?.label ?? ""
                caption.textColor = Palette.text
                caption.isHidden = false
            } else if content == nil {
                caption.stringValue = Strings.text(.editChannelEmpty)
                caption.textColor = Palette.faintText
                caption.isHidden = false
            }
        }
        // Spec 11 §2 — "and a pill while channels are hidden ("Hiding 2 channels")", so a partial picture is never taken for the whole.
        let hidden = editing.page == .cues || editing.page == .text ? editing.hiddenChannels.count : 0
        hiding.isHidden = hidden == 0
        if hidden > 0 { hiding.title = EditModeWording.hiding(hidden) }
        needsLayout = true
    }

    /// "Hiding 2 channels", while any cue-grid row is hidden from the picture.
    let hiding = PillButton(style: .amber)

    /// Where the picture sits: 16 by 9 inside the panel's padding.
    private var pictureFrame: NSRect {
        let pad = CGFloat(EditFrame.padding)
        let width = max(0, bounds.width - 2 * pad)
        return NSRect(x: pad, y: Self.headerHeight + pad, width: width, height: min(width * 9 / 16, max(0, bounds.height - Self.headerHeight - 2 * pad)))
    }

    override func layout() {
        super.layout()
        let size = picker.fittingSize
        let pill = hiding.isHidden ? NSSize.zero : hiding.fitting
        let width = min(size.width, max(60, bounds.width - title.frame.maxX - 20 - (pill.width > 0 ? pill.width + 8 : 0)))
        picker.frame = NSRect(x: bounds.width - width - 6, y: (Self.headerHeight - size.height) / 2, width: width, height: size.height)
        hiding.frame = NSRect(x: picker.frame.minX - pill.width - 8, y: (Self.headerHeight - pill.height) / 2, width: pill.width, height: pill.height)
        frame_.frame = pictureFrame
        picture.frame = frame_.bounds.insetBy(dx: 2, dy: 2)
        live.frame = picture.frame
        let captionHeight = min(picture.frame.height - 16, ceil(caption.cell?.cellSize(forBounds: picture.frame.insetBy(dx: 16, dy: 8)).height ?? 18))
        caption.frame = NSRect(x: picture.frame.minX + 16, y: picture.frame.midY - captionHeight / 2, width: max(0, picture.frame.width - 32),
                               height: max(0, captionHeight))
        // "from `render` ... at the monitor's width in pixels (§3)".
        let scale = window?.backingScaleFactor ?? 2
        if picture.frame.width > 0 { model.editing.previewWidth(Int((picture.frame.width * scale).rounded())) }
    }
}

/// Spec 11 §2, "Program" — "keeps the show running while editing (UX spec)":
/// the live picture of the same stack with a pill naming the outputs that
/// show it; under it the live position, the armed countdown and why a
/// command did nothing; then the go-to field, Next and Clear All.
@MainActor
final class ProgramPanelView: PanelView, NSTextFieldDelegate {
    private let model: ShowModel
    private let keys: KeysModel
    private let mach: MachLink?
    let pill = PillButton()
    private let frame_ = Surface()
    private let picture = SurfaceView()
    private let blackout = Kit.label(Strings.text(.previewBlackout), size: 12, weight: .semibold, color: Palette.browsing)
    let line = Kit.content(Kit.label(size: 11.5))
    let countdown = Kit.label(size: 11.5, weight: .semibold, mono: true)
    let goTo = EditField(kind: .goTo, commitsOnLeave: false)
    let next = FlatButton(Strings.text(.nextNext), style: .plain)
    let clearAll = FlatButton(Strings.text(.clearsClearAll), style: .dangerTint)
    private var showsWaitingDigits = false

    init(model: ShowModel, keys: KeysModel, mach: MachLink?) {
        self.model = model
        self.keys = keys
        self.mach = mach
        super.init(title: Strings.text(.editProgram))
        frame_.fill = Palette.well
        frame_.radius = 4
        frame_.outlineWidth = 2
        frame_.addSubview(picture)
        blackout.alignment = .center
        frame_.addSubview(blackout)
        frame_.setAccessibilityElement(true)
        frame_.setAccessibilityRole(.image)
        line.textColor = Palette.dimText
        countdown.textColor = Palette.browsing
        countdown.alignment = .right
        goTo.onEscape = { [weak self] in self?.refresh() }
        goTo.placeholderString = Strings.text(.editGoTo)
        goTo.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        goTo.delegate = self
        goTo.target = self
        goTo.action = #selector(went)
        goTo.setAccessibilityLabel(Strings.text(.nextGoto))
        next.isOnRaised = true
        next.fontWeight = .semibold
        next.onPress = { [weak model] in model?.send(Actions.next()) }
        clearAll.fontWeight = .semibold
        clearAll.onPress = { [weak model] in model?.send(Actions.clearAll()) }
        for view in [pill, frame_, line, countdown, goTo, next, clearAll] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var panel: ProgramPanel { ProgramPanel.make(stack: model.previewStack, dots: model.outputDots) }

    func refresh() {
        let panel = self.panel
        let label = model.store.catalog?.stacks.first { $0.number == panel.stack }?.label ?? ""
        // "outlined in the live red while an output shows it ...; when none does, the outline is plain and the pill says "Preview only"".
        pill.title = EditModeWording.pill(panel)
        pill.style = panel.isOnAir ? .live : .quiet
        pill.dot = panel.isOnAir ? .filled(Palette.live) : .none
        frame_.outline = panel.isOnAir ? Palette.live : Palette.hairlineStrong
        // "A blacked-out stack is dimmed and labeled as in show mode's preview."
        let isBlack = model.store.stacks[panel.stack]?.blackout ?? panel.isBlackedOut
        blackout.isHidden = !isBlack
        picture.alphaValue = isBlack ? 0.35 : 1
        frame_.setAccessibilityLabel(EditModeWording.programSpoken(panel, label: label) + (isBlack ? ", " + Strings.text(.previewBlackout) : ""))

        let row = model.nextRow
        let reason = ShowWording.unavailable(row.unavailable) ?? Strings.text(.whyNothingLive)
        // "Next (`next`), disabled while nothing is live (choice U-15)".
        next.isEnabled = row.nextEnabled
        next.reason = reason
        goTo.isEnabled = row.goToEnabled
        goTo.toolTip = row.goToEnabled ? nil : reason
        clearAll.isEnabled = model.store.cannotSend == nil
        clearAll.reason = ShowWording.unavailable(model.store.cannotSend)
        // "takes digit entry as in show mode ... showing the live list's title while digits wait".
        if goTo.currentEditor() == nil, goTo.stringValue != keys.digits.digits, showsWaitingDigits || keys.digits.isWaiting {
            goTo.stringValue = keys.digits.digits
        }
        showsWaitingDigits = goTo.currentEditor() == nil && keys.digits.isWaiting
        // "a line gives the live position in the top bar's words and, in amber, the armed countdown; for three
        // seconds it says instead why a command did nothing".
        if let why = model.why {
            line.stringValue = ShowWording.why(why)
            line.textColor = Palette.browsing
        } else if !goTo.stringValue.isEmpty {
            line.stringValue = row.goToTitle
            line.textColor = Palette.dimText
        } else {
            line.stringValue = ShowWording.position(model.livePosition)
            line.textColor = Palette.dimText
        }
        if let ms = model.countdownMs, model.why == nil {
            countdown.stringValue = ShowWording.countdown(ms: ms)
            countdown.isHidden = false
        } else {
            countdown.stringValue = ""
            countdown.isHidden = true
        }
        needsLayout = true
        draw()
    }

    /// Shows the stack's newest surface; called at the display's pace.
    func draw() {
        picture.set(mach?.preview(stack: model.previewStack))
    }

    /// Digits only, as show mode's go-to field takes them.
    func controlTextDidChange(_ notification: Notification) {
        let digits = goTo.stringValue.filter(\.isNumber)
        if digits != goTo.stringValue { goTo.stringValue = digits }
        refresh()
    }

    @objc private func went() {
        // "fires cue N of the live list, whatever the page shows".
        if let number = Int(goTo.stringValue), number > 0 { model.send(Actions.goTo(cue: number)) }
        goTo.stringValue = ""
        goTo.handKeysBack()
        refresh()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        goTo.escape()
        return true
    }

    /// Types a cue number and presses Return, as the operator would.
    func go(to number: String) {
        goTo.stringValue = number
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        went()
    }

    override func layout() {
        super.layout()
        let pad = CGFloat(EditFrame.padding)
        let pillSize = pill.fitting
        pill.frame = NSRect(x: bounds.width - pillSize.width - pad, y: (Self.headerHeight - pillSize.height) / 2, width: pillSize.width, height: pillSize.height)
        let width = max(0, bounds.width - 2 * pad)
        // The controls keep their row at the foot; the picture takes 16 by 9, or what is left over them.
        let controls: CGFloat = 28
        let lineHeight: CGFloat = 16
        let below = pad + lineHeight + 8 + controls + pad
        let pictureHeight = min(width * 9 / 16, max(40, bounds.height - Self.headerHeight - pad - below))
        frame_.frame = NSRect(x: pad, y: Self.headerHeight + pad, width: width, height: pictureHeight)
        picture.frame = frame_.bounds.insetBy(dx: 2, dy: 2)
        blackout.frame = NSRect(x: 0, y: (pictureHeight - 16) / 2, width: width, height: 16)
        var y = frame_.frame.maxY + pad
        let countdownWidth = countdown.isHidden ? 0 : Kit.width(of: countdown)
        countdown.frame = NSRect(x: bounds.width - pad - countdownWidth, y: y, width: countdownWidth, height: lineHeight)
        line.frame = NSRect(x: pad, y: y, width: max(0, width - countdownWidth - (countdownWidth > 0 ? 8 : 0)), height: lineHeight)
        y += lineHeight + 8
        let clearWidth = clearAll.fitting.width
        let nextWidth = next.fitting.width
        clearAll.frame = NSRect(x: bounds.width - pad - clearWidth, y: y, width: clearWidth, height: controls)
        next.frame = NSRect(x: clearAll.frame.minX - 8 - nextWidth, y: y, width: nextWidth, height: controls)
        goTo.frame = NSRect(x: pad, y: y, width: max(40, next.frame.minX - 8 - pad), height: controls)
    }
}
