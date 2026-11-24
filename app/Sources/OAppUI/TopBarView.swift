// OAppUI — Spec 10 §8, the top bar.

import AppKit
import OApp
import OCore

/// Spec 10 §8 — "Status, with a few buttons, the same in show and edit
/// mode ... The buttons are Show and Edit, Back to Live, the output dots,
/// the tags, and ?, each opening or doing what it says; nothing else in the
/// bar is a control".
@MainActor
final class TopBarView: Surface {
    /// Spec 10 §4 — "Top bar ... 38 points high".
    static let height: CGFloat = 38

    private let model: ShowModel
    let show = FlatButton(style: .bare)
    let edit = FlatButton(style: .bare)
    private let liveDot = DotView()
    let position = Kit.content(Kit.label(size: 13, weight: .medium))
    let backToLive = FlatButton(style: .amber)
    let countdown = Kit.label(size: 13, weight: .semibold, mono: true)
    private var outputs: [(button: FlatButton, dot: DotView)] = []
    /// The tags: a word alone, or a button drawn as one where the tag opens something.
    private var tags: [NSView] = []
    private(set) var tagButtons: [FlatButton] = []
    /// Reveal in Finder, for the machine folder (Spec 10 §14, "The saving tag").
    var onRevealMachine: (() -> Void)?
    let note = Kit.label(size: 12)
    private let remote = DotView()
    let time = Kit.label(size: 12, mono: true)
    let keys = FlatButton(style: .bare)
    /// "While another app is active, the whole bar says ...".
    let notActive = Kit.content(Kit.label(size: 13, weight: .medium))
    /// The other app's name while this one isn't active; nil while it is.
    var activeElsewhere: String? { didSet { refresh() } }
    /// Opens an output's details, with its Stack ▸ menu.
    var onOutput: ((OutputDot, NSView) -> Void)?
    var onPopupTag: (() -> Void)?
    /// "?, which opens the keys overlay (§9)".
    var onKeys: (() -> Void)?
    /// Spec 10 §8 — "while a text field has the focus, what its keys do (§9)"; nil while none has it.
    let hint = Kit.label(size: 12, weight: .medium)
    var fieldHint: String? {
        didSet {
            guard fieldHint != oldValue else { return }
            refresh()
        }
    }
    /// The message last read out, so VoiceOver hears each once.
    private var said: String?

    // Spec 11 §2, "The top bar in edit mode" — what the bar holds there and not in show mode.
    /// "Show and Edit, one control with Edit chosen": the well the two buttons sit in.
    private let modeWell = Surface()
    /// "then what the page edits".
    let crumb = Kit.content(Kit.label(size: 12))
    /// "Center: the page picker: Cues, Text, Stacks, Channels, Presets, Objects."
    let pagePicker = SegmentedView(EditPage.allCases.map { EditModeWording.page($0) })
    /// Spec 11 §2 — "Live ... one toggle beside the page picker ... drawn in the live red while it is on".
    let liveToggle = PillButton(Strings.text(.editLive))
    /// "the saving pill, which reads "Saved" while nothing waits to be written".
    let saved = PillButton()
    /// "the engine pill, a green dot and "Engine"".
    let engine = PillButton()
    /// Show, Edit and a page chosen in the bar; the window acts on them, since leaving commits an open field first.
    var onShow: (() -> Void)?
    var onEdit: (() -> Void)?
    var onPage: ((EditPage) -> Void)?

    /// The bar's height in each mode: Spec 10 §4's 38 points, and Spec 11 §2's 44 in edit mode.
    static func height(_ mode: WindowMode) -> CGFloat {
        mode == .edit ? CGFloat(EditFrame.topBarHeight) : height
    }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        show.title = Strings.text(.menuShow)
        show.isOn = true
        show.onPress = { [weak self] in self?.onShow?() }
        edit.title = Strings.text(.menuEditMode)
        edit.onPress = { [weak self] in self?.onEdit?() }
        modeWell.fill = Palette.well
        modeWell.radius = 6
        crumb.textColor = Palette.dimText
        pagePicker.setAccessibilityLabel(Strings.text(.editPages))
        pagePicker.onSelect = { [weak self] index in self?.onPage?(EditPage.allCases[index]) }
        liveToggle.onPress = { [weak self] in
            guard let self else { return }
            self.model.editing.setLive(!self.model.editing.isLive)
        }
        liveToggle.setAccessibilityLabel(Strings.text(.editLiveSpoken))
        liveToggle.setAccessibilityRole(.checkBox)
        addSubview(liveToggle)
        saved.onPress = { [weak self] in
            guard let self else { return }
            self.popUp(self.savingMenu, at: self.saved)
        }
        engine.onPress = { [weak self] in
            guard let self else { return }
            self.popUp(self.outputsMenu, at: self.engine)
        }
        for view in [modeWell, crumb, pagePicker, saved, engine] as [NSView] { addSubview(view) }
        liveDot.color = Palette.live
        backToLive.title = Strings.text(.menuBackToLive)
        backToLive.onPress = { [weak model] in model?.backToLive() }
        countdown.textColor = Palette.browsing
        countdown.alignment = .center
        note.textColor = Palette.dimText
        remote.color = Palette.selection
        remote.setAccessibilityElement(true)
        remote.setAccessibilityRole(.image)
        time.textColor = Palette.dimText
        keys.title = "?"
        keys.setAccessibilityLabel(Strings.text(.menuKeys))
        keys.onPress = { [weak self] in self?.onKeys?() }
        hint.textColor = Palette.selection
        hint.alignment = .center
        notActive.alignment = .center
        notActive.textColor = Palette.browsing
        for view in [show, edit, liveDot, position, backToLive, countdown, hint, note, remote, time, keys, notActive] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The time of day, in the system's short format (Area 13 reading).
    static func clockText(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Draws the bar again, keeping the keyboard's focus on the button it was on (Spec 10 §8, §15).
    func refresh() {
        FocusKeeper.keeping(in: self) { redraw() }
    }

    private func redraw() {
        let inactive = activeElsewhere != nil
        notActive.stringValue = activeElsewhere.map { Strings.text(.topNotActive, $0) } ?? ""
        notActive.isHidden = !inactive
        // Spec 11 §2 — in edit mode the bar holds Show and Edit, what is edited, the page picker and a short status.
        let editing = model.mode == .edit
        let status = editing ? EditStatus.make(dots: model.outputDots, tags: model.tags, isConnected: model.store.isConnected) : nil
        show.isOn = !editing
        edit.isOn = editing
        // "While operator lock is on, Mode ▸ Edit, Edit in the top bar and every entry above are disabled with the reason".
        let cannotEdit = model.editing.cannotOpen
        edit.isEnabled = cannotEdit == nil
        edit.reason = cannotEdit.map(UnavailableWording.sentence)
        let browsing = model.isBrowsing && !editing
        // "the top bar, the grid's edge and Back to Live turn amber".
        fill = browsing ? Palette.browsing.withAlphaComponent(0.10).blended(withFraction: 0.86, of: Palette.panel) : Palette.panel
        position.stringValue = ShowWording.position(model.livePosition)
        liveDot.isHidden = !model.store.live.isSomethingLive || inactive
        backToLive.isHidden = !browsing || inactive
        if let ms = model.countdownMs, !editing {
            countdown.stringValue = ShowWording.countdown(ms: ms)
            countdown.isHidden = inactive
        } else {
            countdown.stringValue = ""
            countdown.isHidden = true
        }
        // Spec 10 §10 — "After an undo or a redo, the window says for three seconds what changed"; a refusal of one, too.
        // It takes the place of the line about a focused field's keys while it stands.
        if let notice = model.notices[.top] {
            hint.stringValue = EditWording.notice(notice)
            if case .done = notice { hint.textColor = Palette.text } else { hint.textColor = Palette.browsing }
            hint.isHidden = inactive
            if said != hint.stringValue {
                said = hint.stringValue
                NSAccessibility.post(element: self, notification: .announcementRequested,
                                     userInfo: [.announcement: hint.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        } else {
            said = nil
            hint.stringValue = fieldHint ?? ""
            hint.textColor = Palette.selection
            hint.isHidden = fieldHint == nil || inactive
        }
        time.stringValue = Self.clockText()
        remote.isHollow = !model.isRemoteLit
        remote.setAccessibilityLabel(Strings.text(.topRemote))

        // One dot an output; in edit mode only "an output that isn't presenting or is blacked out" (Spec 11 §2).
        let dots = status?.dots ?? model.outputDots
        while outputs.count > dots.count {
            let last = outputs.removeLast()
            last.button.removeFromSuperview()
        }
        while outputs.count < dots.count {
            let button = FlatButton(style: .bare)
            let dot = DotView()
            button.addSubview(dot)
            addSubview(button)
            outputs.append((button, dot))
        }
        for (index, dot) in dots.enumerated() {
            let (button, mark) = outputs[index]
            // The text carries the state in words; the dot's shape says it again, so colour is never the only signal.
            button.title = "    " + ShowWording.output(dot)
            button.setAccessibilityLabel(ShowWording.output(dot))
            mark.color = dot.state == .presenting ? Palette.outputting : Palette.live
            mark.isHollow = dot.state != .presenting || dot.isBlackedOut
            mark.isSquare = dot.state != .presenting
            button.onPress = { [weak self, weak button] in
                guard let self, let button else { return }
                self.onOutput?(dot, button)
            }
            button.isHidden = inactive
        }
        if let outputsNote = OutputsNote.make(outputs: model.store.catalog?.outputs ?? [], screensAreMirrored: Self.screensAreMirrored),
           model.store.catalog != nil, !editing {
            note.stringValue = ShowWording.note(outputsNote)
            note.isHidden = inactive
        } else {
            note.stringValue = ""
            note.isHidden = true
        }

        tags.forEach { $0.removeFromSuperview() }
        tagButtons = []
        tags = (status?.tags ?? model.tags).map { tag in
            let words = ShowWording.tag(tag)
            let view: NSView
            switch tag {
            case .audioLost: view = TagView(words, style: .red)
            case .audioMuted: view = TagView(words, style: .amber)
            // "the tags, ... each opening or doing what it says": these three are buttons.
            case .popup: view = tagButton(words, .quiet) { [weak self] _ in self?.onPopupTag?() }
            case .engine: view = tagButton(words, .amber) { [weak self] button in self?.popUp(self?.engineMenu, at: button) }
            case .saving(let saving): view = tagButton(words, saving.isRed ? .red : .amber) { [weak self] button in self?.popUp(self?.savingMenu, at: button) }
            }
            view.isHidden = inactive
            addSubview(view)
            return view
        }
        for view in [show, edit, time] as [NSView] { view.isHidden = inactive }
        // Show mode's own: the live position, "?" and the remote dot. Edit mode says the position under its Program monitor.
        for view in [position, keys, remote] as [NSView] { view.isHidden = inactive || editing }
        liveDot.isHidden = inactive || editing || !model.store.live.isSomethingLive

        // Edit mode's own (Spec 11 §2).
        for view in [modeWell, crumb, pagePicker, liveToggle, saved, engine] as [NSView] { view.isHidden = inactive || !editing }
        let live = model.editing.isLive
        liveToggle.style = live ? .live : .quiet
        liveToggle.dot = live ? .filled(Palette.text) : .hollow(Palette.dimText, square: false)
        liveToggle.setAccessibilityValue(live ? 1 : 0)
        if let status {
            let page = model.editing.page
            crumb.stringValue = page == .cues || page == .text ? EditModeWording.crumb(model.editing.crumb) : EditModeWording.page(page)
            pagePicker.selected = EditPage.allCases.firstIndex(of: page)
            for (index, page) in EditPage.allCases.enumerated() where !page.isBuilt {
                pagePicker.disable(index, reason: Strings.text(.unavailableLater))
            }
            if let saving = status.saving {
                saved.title = StateWording.tag(saving)
                saved.style = saving.isRed ? .red : .amber
            } else {
                saved.title = Strings.text(.editSaved)
                saved.style = .quiet
            }
            engine.title = Strings.text(.editEngine)
            engine.setAccessibilityLabel(EditModeWording.engineSpoken(status.engine))
            switch status.engine {
            case .fine: engine.dot = .filled(Palette.outputting)
            case .attention: engine.dot = .hollow(Palette.browsing, square: false)
            case .away: engine.dot = .hollow(Palette.live, square: true)
            }
        }
        needsLayout = true
    }

    /// Spec 11 §2 — "A click on the engine pill lists every output as show
    /// mode's dots do, each with its details and its Stack ▸ menu", then the
    /// standing badges in the engine tag's words.
    var outputsMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for dot in model.outputDots {
            menu.addItem(ClosureMenuItem(title: ShowWording.output(dot)) { [weak self] in
                guard let self else { return }
                self.onOutput?(dot, self.engine)
            })
        }
        let badges = model.store.engine.badges
        if !badges.isEmpty, !model.outputDots.isEmpty { menu.addItem(.separator()) }
        for badge in badges { menu.addItem(line(StateWording.badge(badge))) }
        return menu
    }

    /// Spec 10 §13 — a Mac "whose screens are mirrored, which macOS reports as one screen".
    static var screensAreMirrored: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsInMirrorSet(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        notActive.frame = NSRect(x: 12, y: (h - 18) / 2, width: bounds.width - 24, height: 18)
        if model.mode == .edit { return layoutEdit(h) }
        var x: CGFloat = 10
        for button in [show, edit] {
            let size = button.fitting
            button.frame = NSRect(x: x, y: (h - 26) / 2, width: size.width, height: 26)
            x += size.width + 2
        }
        x += 12
        liveDot.frame = NSRect(x: x, y: (h - 10) / 2, width: 10, height: 10)
        if !liveDot.isHidden { x += 18 }
        // From the right.
        var right = bounds.width - 10
        keys.frame = NSRect(x: right - 26, y: (h - 26) / 2, width: 26, height: 26)
        right -= 34
        let timeWidth = Kit.width(of: time)
        time.frame = NSRect(x: right - timeWidth, y: (h - 16) / 2, width: timeWidth, height: 16)
        right -= timeWidth + 12
        remote.frame = NSRect(x: right - 9, y: (h - 9) / 2, width: 9, height: 9)
        right -= 21
        for tag in tags.reversed() {
            let size = (tag as? TagView)?.fitting ?? (tag as? FlatButton)?.fitting ?? .zero
            tag.frame = NSRect(x: right - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 6
        }
        if !note.isHidden {
            let width = Kit.width(of: note)
            note.frame = NSRect(x: right - width, y: (h - 16) / 2, width: width, height: 16)
            right -= width + 10
        }
        for (button, dot) in outputs.reversed() {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: (h - 26) / 2, width: size.width, height: 26)
            dot.frame = NSRect(x: 9, y: 8, width: 10, height: 10)
            right -= size.width + 2
        }
        // The middle: the position at the left, Back to Live after it, the countdown centred in what is left.
        let positionWidth = min(Kit.width(of: position), max(80, right - x - 20))
        position.frame = NSRect(x: x, y: (h - 17) / 2, width: positionWidth, height: 17)
        x += positionWidth + 12
        if !backToLive.isHidden {
            let size = backToLive.fitting
            backToLive.frame = NSRect(x: x, y: (h - 24) / 2, width: size.width, height: 24)
            x += size.width + 12
        }
        // "Center: the armed countdown ...; and, while a text field has the focus, what its keys do": side by side, centred together.
        let countdownWidth = countdown.isHidden ? 0 : Kit.width(of: countdown)
        let hintWidth = hint.isHidden ? 0 : Kit.width(of: hint)
        let gap: CGFloat = countdownWidth > 0 && hintWidth > 0 ? 18 : 0
        let middle = countdownWidth + gap + hintWidth
        let start = max(x, min((bounds.width - middle) / 2, right - middle - 8))
        countdown.frame = NSRect(x: start, y: (h - 17) / 2, width: countdownWidth, height: 17)
        hint.frame = NSRect(x: start + countdownWidth + gap, y: (h - 16) / 2, width: hintWidth, height: 16)
    }

    /// Spec 11 §2, "The top bar in edit mode" — Show and Edit and what is
    /// edited at the left; the page picker in the middle; at the right the
    /// time, the saving pill and the engine pill, with what needs a look
    /// before them.
    private func layoutEdit(_ h: CGFloat) {
        var x: CGFloat = 12
        let showSize = show.fitting
        let editSize = edit.fitting
        modeWell.frame = NSRect(x: x, y: (h - 28) / 2, width: showSize.width + editSize.width + 6, height: 28)
        show.frame = NSRect(x: x + 2, y: (h - 24) / 2, width: showSize.width, height: 24)
        edit.frame = NSRect(x: x + 4 + showSize.width, y: (h - 24) / 2, width: editSize.width, height: 24)
        x = modeWell.frame.maxX + 12
        let picker = pagePicker.fitting
        pagePicker.frame = NSRect(x: floor((bounds.width - picker.width) / 2), y: (h - picker.height) / 2, width: picker.width, height: picker.height)
        let toggleSize = liveToggle.fitting
        liveToggle.frame = NSRect(x: pagePicker.frame.maxX + 12, y: (h - toggleSize.height) / 2, width: toggleSize.width, height: toggleSize.height)
        var right = bounds.width - 12
        for pill in [engine, saved] {
            let size = pill.fitting
            pill.frame = NSRect(x: right - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 8
        }
        let timeWidth = Kit.width(of: time)
        time.frame = NSRect(x: right - timeWidth, y: (h - 16) / 2, width: timeWidth, height: 16)
        right -= timeWidth + 12
        for tag in tags.reversed() {
            let size = (tag as? TagView)?.fitting ?? (tag as? FlatButton)?.fitting ?? .zero
            tag.frame = NSRect(x: right - size.width, y: (h - size.height) / 2, width: size.width, height: size.height)
            right -= size.width + 6
        }
        for (button, dot) in outputs.reversed() {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: (h - 26) / 2, width: size.width, height: 26)
            dot.frame = NSRect(x: 9, y: 8, width: 10, height: 10)
            right -= size.width + 2
        }
        // What is edited, then what a focused field's keys do, in the room left before the page picker.
        let limit = min(pagePicker.frame.minX, right) - 12
        let crumbWidth = min(Kit.width(of: crumb), max(0, limit - x))
        crumb.frame = NSRect(x: x, y: (h - 16) / 2, width: crumbWidth, height: 16)
        x += crumbWidth + 14
        let hintWidth = hint.isHidden ? 0 : min(Kit.width(of: hint), max(0, limit - x))
        hint.frame = NSRect(x: x, y: (h - 16) / 2, width: hintWidth, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        // "Click here to come back."
        if activeElsewhere != nil { NSApplication.shared.activate(ignoringOtherApps: true) } else { super.mouseDown(with: event) }
    }

    // MARK: Tags that open something (Spec 10 §8, §14)

    private func tagButton(_ words: String, _ style: TagView.Style, _ press: @escaping (FlatButton) -> Void) -> FlatButton {
        let button = FlatButton(words, style: .bare)
        button.fontSize = 10
        button.tagStyle = style
        button.onPress = { [weak button] in
            if let button { press(button) }
        }
        tagButtons.append(button)
        return button
    }

    private func popUp(_ menu: NSMenu?, at button: NSView) {
        menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    private func line(_ words: String) -> NSMenuItem {
        let item = NSMenuItem(title: words, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// "The engine tag lists the standing badges in plain words".
    var engineMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for badge in model.store.engine.badges { menu.addItem(line(StateWording.badge(badge))) }
        return menu
    }

    /// "A click lists how many documents are waiting, how the disk stands and whether the log is in memory, with
    /// Reveal in Finder for the machine folder".
    var savingMenu: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for words in StateWording.saving(model.savingDetails) { menu.addItem(line(words)) }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.savingReveal)) { [weak self] in self?.onRevealMachine?() })
        return menu
    }

    /// What the bar shows, for a test.
    var shownOutputs: [String] { outputs.map { $0.button.accessibilityLabel() ?? "" } }
    var shownTags: [String] { tags.map { ($0 as? TagView)?.text ?? ($0 as? FlatButton)?.title ?? "" } }
}
