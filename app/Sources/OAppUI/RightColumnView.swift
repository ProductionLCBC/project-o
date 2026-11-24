// OAppUI — Spec 10 §7, the right column: the preview, the next row and the tabbed panel.

import AppKit
import IOSurface
import OApp
import OCore

/// A picture the engine drew, shown as it is: the surface is the layer's
/// content, so the app renders nothing of the show itself (ARCHITECTURE.md).
@MainActor
final class SurfaceView: NSView {
    private var shown: IOSurfaceRef?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Palette.well.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Spec 10 §2 — "the engine writes the next frame into the oldest of the
    /// three": each new frame comes in another surface. Read at the display's
    /// pace (`ShowWindowView`), the same surface comes back only while no
    /// newer frame has arrived, so nothing is composited again for it.
    func set(_ surface: IOSurfaceRef?) {
        guard surface !== shown else { return }
        shown = surface
        layer?.contents = surface
    }

    var hasPicture: Bool { shown != nil }
}

/// Spec 10 §7, "The preview" — "shows the selected stack's surface (§2),
/// starting from the thumbnail stack, with a stack picker and the outputs it
/// feeds ("preview only" when none). The multiviewer ... shows every stack
/// instead".
@MainActor
final class PreviewView: Surface {
    private let model: ShowModel
    private let mach: MachLink?
    private var tiles: [(stack: Int, frame: Surface, picture: SurfaceView, label: NSTextField, blackout: NSTextField)] = []
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    let feeds = Kit.content(Kit.label(size: 11.5))
    let multiviewer = FlatButton(style: .bare)

    init(model: ShowModel, mach: MachLink?) {
        self.model = model
        self.mach = mach
        super.init(frame: .zero)
        picker.font = .systemFont(ofSize: 12)
        picker.isBordered = false
        picker.target = self
        picker.action = #selector(picked)
        feeds.textColor = Palette.dimText
        feeds.alignment = .right
        multiviewer.title = Strings.text(.menuMultiviewer)
        multiviewer.fontSize = 11
        multiviewer.onPress = { [weak model] in model?.change { $0.multiviewer.toggle() } }
        for view in [picker, feeds, multiviewer] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func picked() {
        let stack = picker.selectedItem?.tag
        model.change { $0.previewStack = stack }
    }

    private func outputs(feeding stack: Int) -> [String] {
        model.outputDots.filter { $0.stack == stack }.map { "\($0.number) \($0.label)" }
    }

    func refresh() {
        let stacks = (model.store.catalog?.stacks ?? []).sorted { $0.number < $1.number }
        let selected = model.previewStack
        picker.removeAllItems()
        for stack in stacks {
            picker.addItem(withTitle: Strings.text(.previewStack, stack.number, stack.label))
            picker.lastItem?.tag = stack.number
        }
        picker.selectItem(withTag: selected)
        picker.setAccessibilityLabel(Strings.text(.previewPicker))
        multiviewer.isOn = model.settings.multiviewer
        let feeding = outputs(feeding: selected)
        feeds.stringValue = feeding.isEmpty ? Strings.text(.previewOnly) : Strings.text(.previewFeeds, ListFormatter.localizedString(byJoining: feeding))

        // One tile, or with the multiviewer every stack, "assigned or not, in a grid by stack number (S5)".
        let shown = model.settings.multiviewer ? stacks.map(\.number) : (stacks.contains { $0.number == selected } ? [selected] : [])
        for tile in tiles { tile.frame.removeFromSuperview() }
        tiles = shown.map { number in
            let frame = Surface()
            frame.radius = 8
            frame.fill = Palette.well
            // "stays outlined in green as the blackout target": green for the selected preview (Spec 10 §4).
            frame.outline = number == selected ? Palette.outputting : nil
            frame.outlineWidth = 2
            let picture = SurfaceView()
            let stack = stacks.first { $0.number == number }
            let feeding = outputs(feeding: number)
            let name = Strings.text(.previewStack, number, stack?.label ?? "")
            let label = Kit.label(model.settings.multiviewer ? "\(name) · \(feeding.isEmpty ? Strings.text(.previewOnly) : ListFormatter.localizedString(byJoining: feeding))" : "",
                                  size: 10.5, color: Palette.dimText)
            Kit.content(label)
            let blackout = Kit.label(Strings.text(.previewBlackout), size: 12, weight: .semibold, color: Palette.browsing)
            blackout.alignment = .center
            // "a blacked-out stack's tile is dimmed and labelled "Blackout"".
            let isBlack = model.store.stacks[number]?.blackout ?? false
            blackout.isHidden = !isBlack
            picture.alphaValue = isBlack ? 0.35 : 1
            frame.addSubview(picture)
            frame.addSubview(label)
            frame.addSubview(blackout)
            frame.setAccessibilityElement(true)
            frame.setAccessibilityRole(.image)
            frame.setAccessibilityLabel(Strings.text(.previewLabel, number, stack?.label ?? "") + (isBlack ? ", " + Strings.text(.previewBlackout) : ""))
            addSubview(frame)
            return (number, frame, picture, label, blackout)
        }
        needsLayout = true
        draw()
    }

    /// Shows each tile's newest surface; called at the display's pace.
    func draw() {
        for tile in tiles { tile.picture.set(mach?.preview(stack: tile.stack)) }
    }

    /// "one column for one stack, two for up to four, three for up to nine, four beyond that".
    static func columns(for stacks: Int) -> Int {
        switch stacks {
        case ...1: return 1
        case ...4: return 2
        case ...9: return 3
        default: return 4
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let captionY = bounds.height - 26
        let columns = Self.columns(for: tiles.count)
        let gap: CGFloat = 6
        let tileWidth = (w - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = max(1, Int(ceil(Double(tiles.count) / Double(columns))))
        let tileHeight = min(tileWidth * 9 / 16 + (model.settings.multiviewer ? 16 : 0), (captionY - gap * CGFloat(rows - 1)) / CGFloat(rows))
        for (index, tile) in tiles.enumerated() {
            let (row, column) = (index / columns, index % columns)
            tile.frame.frame = NSRect(x: CGFloat(column) * (tileWidth + gap), y: CGFloat(row) * (tileHeight + gap), width: tileWidth, height: tileHeight)
            let labelHeight: CGFloat = model.settings.multiviewer ? 16 : 0
            tile.picture.frame = NSRect(x: 3, y: 3, width: tileWidth - 6, height: tileHeight - 6 - labelHeight)
            tile.label.frame = NSRect(x: 6, y: tileHeight - 17, width: tileWidth - 12, height: 14)
            tile.blackout.frame = NSRect(x: 0, y: tile.picture.frame.midY - 8, width: tileWidth, height: 16)
        }
        let button = multiviewer.fitting
        multiviewer.frame = NSRect(x: w - button.width, y: captionY + 2, width: button.width, height: 22)
        picker.frame = NSRect(x: -4, y: captionY, width: min(170, w * 0.45), height: 24)
        feeds.frame = NSRect(x: picker.frame.maxX + 4, y: captionY + 5, width: max(0, multiviewer.frame.minX - picker.frame.maxX - 12), height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        // "a click on a tile selects that stack".
        let point = convert(event.locationInWindow, from: nil)
        if let tile = tiles.first(where: { $0.frame.frame.contains(point) }) {
            let stack = tile.stack
            model.change { $0.previewStack = stack }
        }
    }

    var shownStacks: [Int] { tiles.map(\.stack) }
}

/// Spec 10 §7, "The next row" — "Last (`previous`), a large Next (`next`)
/// and the go-to field".
@MainActor
final class NextRowView: Surface, NSTextFieldDelegate {
    private let model: ShowModel
    private let keys: KeysModel
    let last = FlatButton(Strings.text(.nextLast), style: .plain)
    let next = FlatButton(Strings.text(.nextNext), style: .primary)
    let hold = FlatButton(Strings.text(.nextHold), style: .amber)
    let goTo = ShowField(kind: .goTo)
    let line = Kit.content(Kit.label(size: 11.5))
    static let height: CGFloat = 92

    init(model: ShowModel, keys: KeysModel) {
        self.model = model
        self.keys = keys
        super.init(frame: .zero)
        goTo.onEscape = { [weak self] in self?.refresh() }
        next.fontSize = 17
        next.fontWeight = .semibold
        last.onPress = { [weak model] in model?.send(Actions.previous()) }
        next.onPress = { [weak model] in model?.send(Actions.next()) }
        hold.onPress = { [weak model] in model?.send(Actions.hold()) }
        goTo.placeholderString = Strings.text(.nextGoto)
        goTo.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        goTo.alignment = .center
        goTo.bezelStyle = .roundedBezel
        goTo.delegate = self
        goTo.target = self
        goTo.action = #selector(went)
        goTo.setAccessibilityLabel(Strings.text(.nextGoto))
        // The why-line may run to a second line, so a long title in it is never cut short.
        line.maximumNumberOfLines = 2
        line.lineBreakMode = .byWordWrapping
        line.cell?.wraps = true
        for view in [last, next, hold, goTo, line] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let row = model.nextRow
        let reason = ShowWording.unavailable(row.unavailable) ?? Strings.text(.whyNothingLive)
        next.isEnabled = row.nextEnabled
        next.reason = reason
        last.isEnabled = row.lastEnabled
        last.reason = reason
        goTo.isEnabled = row.goToEnabled
        goTo.toolTip = row.goToEnabled ? nil : reason
        // Spec 10 §9, "Digit entry" — "an unbound digit key ... goes into the go-to field": the digits waiting
        // show there while the cursor is elsewhere, and leave it when they fire, time out or are cleared.
        if goTo.currentEditor() == nil, goTo.stringValue != keys.digits.digits, showsWaitingDigits || keys.digits.isWaiting {
            goTo.stringValue = keys.digits.digits
        }
        showsWaitingDigits = goTo.currentEditor() == nil && keys.digits.isWaiting
        hold.isHidden = !row.showsHold
        // "the row says why for three seconds"; else, "while digits wait, it shows the live list's title".
        if let why = model.why {
            line.stringValue = ShowWording.why(why)
            line.textColor = Palette.browsing
        } else if !goTo.stringValue.isEmpty {
            line.stringValue = row.goToTitle
            line.textColor = Palette.dimText
        } else {
            line.stringValue = ""
        }
        needsLayout = true
    }

    /// Digits only (Area 13 reading).
    func controlTextDidChange(_ notification: Notification) {
        let digits = goTo.stringValue.filter(\.isNumber)
        if digits != goTo.stringValue { goTo.stringValue = digits }
        refresh()
    }

    /// Whether the field is showing digits typed with no field focused, which the keys' model holds.
    private var showsWaitingDigits = false

    @objc private func went() {
        // "fires `cue N` in the live list on Return"; Return on an empty field does nothing.
        if let number = Int(goTo.stringValue), number > 0 { model.send(Actions.goTo(cue: number)) }
        goTo.stringValue = ""
        // "A single-line field that acts on Return ... hands the focus back to the window when it acts".
        goTo.handKeysBack()
        refresh()
    }

    /// Escape, should the field be given it: what the key tap does first for every field of the window's (Spec 10 §9).
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
        let w = bounds.width
        let holdWidth: CGFloat = hold.isHidden ? 0 : hold.fitting.width + 8
        last.frame = NSRect(x: 0, y: 0, width: 72, height: 52)
        goTo.frame = NSRect(x: w - 92, y: 14, width: 92, height: 24)
        hold.frame = NSRect(x: goTo.frame.minX - holdWidth, y: 0, width: max(0, holdWidth - 8), height: 52)
        next.frame = NSRect(x: 80, y: 0, width: max(60, goTo.frame.minX - 8 - holdWidth - 80), height: 52)
        line.frame = NSRect(x: 2, y: 58, width: w - 4, height: 30)
    }
}

/// Spec 10 §7, "The tabbed panel" — "four tabs and collapses to its tab bar
/// with its – button (+ opens it again)".
@MainActor
final class TabsView: Surface {
    enum Tab: Int, CaseIterable {
        case transport, clears, macros, popups
    }

    private let model: ShowModel
    private(set) var tab = Tab.clears
    private var tabButtons: [FlatButton] = []
    let collapse = FlatButton(style: .bare)
    private let content = Surface()
    /// The controls of the tab shown, for a test to press and read.
    private(set) var controls: [FlatButton] = []
    private(set) var labels: [NSTextField] = []
    private var drafts: [Int: String] = [:]
    private var clearAfter: [Int: Int?] = [:]
    /// Spec 10 §7 — a macro tile's Edit: "edit mode's macro editor, which also makes, renames and removes macros, Spec 11 §9".
    var onEditMacro: ((Int) -> Void)?
    private var durations: [Int: String] = [:]
    private var counting: [Int: Bool] = [:]
    static let barHeight: CGFloat = 34
    var isCollapsed = false { didSet { refresh() } }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        radius = 10
        let titles: [StringKey] = [.tabTransport, .tabClears, .tabMacros, .tabPopups]
        for (index, key) in titles.enumerated() {
            let button = FlatButton(Strings.text(key), style: .bare)
            button.onPress = { [weak self] in self?.show(Tab(rawValue: index) ?? .clears) }
            tabButtons.append(button)
            addSubview(button)
        }
        collapse.onPress = { [weak model] in model?.change { $0.tabbedPanelCollapsed.toggle() } }
        addSubview(collapse)
        addSubview(content)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ tab: Tab) {
        self.tab = tab
        refresh()
    }

    /// The height the panel wants: its bar alone when collapsed.
    var wantedHeight: CGFloat {
        if isCollapsed { return Self.barHeight }
        switch tab {
        case .transport: return Self.barHeight + 96
        case .clears: return Self.barHeight + 110
        case .macros: return Self.barHeight + 110
        case .popups:
            let settings = model.store.catalog?.settings
            return Self.barHeight + CGFloat((settings?.popups ?? 0) + (settings?.timers ?? 0)) * 34 + 16
        }
    }

    /// Draws the panel again, keeping the keyboard's focus on the control it was on (Spec 10 §15).
    func refresh() {
        FocusKeeper.keeping(in: self) { redraw() }
    }

    private func redraw() {
        for (index, button) in tabButtons.enumerated() { button.isOn = index == tab.rawValue && !isCollapsed }
        collapse.title = isCollapsed ? "+" : "–"
        collapse.setAccessibilityLabel(Strings.text(isCollapsed ? .tabExpand : .tabCollapse))
        for view in content.subviews { view.removeFromSuperview() }
        controls = []
        labels = []
        content.isHidden = isCollapsed
        guard !isCollapsed else { return needsLayout = true }
        switch tab {
        case .transport: buildTransport()
        case .clears: buildClears()
        case .macros: buildMacros()
        case .popups: buildPopups()
        }
        needsLayout = true
    }

    private func button(_ title: String, style: FlatButton.Style = .plain, frame: NSRect, _ sending: @escaping () -> Sending?) -> FlatButton {
        let button = FlatButton(title, style: style)
        button.frame = frame
        let away = model.store.cannotSend
        button.isEnabled = away == nil
        button.reason = ShowWording.unavailable(away)
        button.onPress = { [weak model] in
            if let sending = sending() { model?.send(sending) }
        }
        content.addSubview(button)
        controls.append(button)
        return button
    }

    private func text(_ string: String, frame: NSRect, color: NSColor? = nil, mono: Bool = false) -> NSTextField {
        // These hold what the engine reported (a popup's text, a timer's value) beside the app's own words.
        let label = Kit.content(Kit.label(string, size: 12, color: color ?? Palette.dimText, mono: mono))
        label.frame = frame
        content.addSubview(label)
        labels.append(label)
        return label
    }

    private var contentWidth: CGFloat { max(200, bounds.width - 24) }

    // "Transport, for the selected channels."
    private func buildTransport() {
        let w = contentWidth
        switch model.transport {
        case .none:
            let label = text(Strings.text(.transportNone), frame: NSRect(x: 0, y: 30, width: w, height: 16), color: Palette.faintText)
            label.alignment = .center
        case .one(let channel, let position, let duration, let playing, let end):
            let bar = ProgressBar(frame: NSRect(x: 0, y: 6, width: w, height: 6))
            bar.fraction = duration > 0 ? Double(position) / Double(duration) : 0
            bar.setAccessibilityLabel(Strings.text(.transportPosition, TimeText.clock(ms: position), TimeText.clock(ms: duration)))
            content.addSubview(bar)
            _ = text(Strings.text(.transportPosition, TimeText.clock(ms: position), TimeText.clock(ms: duration)),
                     frame: NSRect(x: 0, y: 18, width: w, height: 15), mono: true)
            let third = (w - 16) / 3
            _ = button(Strings.text(playing ? .transportPause : .transportPlay), frame: NSRect(x: 0, y: 40, width: third, height: 26)) {
                Actions.transport(playing ? .pause : .play, channels: [channel])
            }
            _ = button(Strings.text(.transportStop), frame: NSRect(x: third + 8, y: 40, width: third, height: 26)) { Actions.transport(.stop, channels: [channel]) }
            // "its end behaviour as Loop, Hold and Clear".
            let ends: [(StringKey, EndBehavior, String)] = [(.transportLoop, .loop, "loop"), (.transportHold, .hold, "hold"), (.transportClear, .clear, "clear")]
            for (index, entry) in ends.enumerated() {
                let made = button(Strings.text(entry.0), style: .bare, frame: NSRect(x: CGFloat(index) * (third + 8), y: 70, width: third, height: 22)) {
                    Actions.end(entry.1, channel: channel)
                }
                made.isOn = end == entry.2
                made.fontSize = 11
            }
        case .several(let channels):
            _ = text(Strings.counted(.transportChannels, channels.count), frame: NSRect(x: 0, y: 12, width: w, height: 15))
            let third = (w - 16) / 3
            let modes: [(StringKey, TransportMode)] = [(.transportPlay, .play), (.transportPause, .pause), (.transportStop, .stop)]
            for (index, entry) in modes.enumerated() {
                _ = button(Strings.text(entry.0), frame: NSRect(x: CGFloat(index) * (third + 8), y: 40, width: third, height: 26)) {
                    Actions.transport(entry.1, channels: channels)
                }
            }
        }
    }

    // "Clears: tiles that each send one command (choice U-4)".
    private func buildClears() {
        let w = contentWidth
        let third = (w - 16) / 3
        for (index, tile) in model.clearsTiles.enumerated() {
            let frame = NSRect(x: CGFloat(index % 3) * (third + 8), y: 4 + CGFloat(index / 3) * 52, width: third, height: 44)
            let made = button(ShowWording.tile(tile.kind), frame: frame) { tile.sending }
            made.lit = tile.lit
            made.fontSize = 11.5
            if !tile.isEnabled {
                made.isEnabled = false
                made.reason = ShowWording.unavailable(model.store.cannotSend)
            }
            made.setAccessibilityValue(tile.lit == .all ? "on" : (tile.lit == .some ? "mixed" : "off"))
        }
    }

    // "Macros: the macros of both roots by number, each a tile with its label and colour".
    private func buildMacros() {
        let w = contentWidth
        let macros = model.store.catalog?.macros ?? []
        guard !macros.isEmpty else {
            let label = text(Strings.text(.macrosNone), frame: NSRect(x: 0, y: 30, width: w, height: 16), color: Palette.faintText)
            label.alignment = .center
            return
        }
        let third = (w - 16) / 3
        for (index, macro) in macros.enumerated() {
            let frame = NSRect(x: CGFloat(index % 3) * (third + 8), y: 4 + CGFloat(index / 3) * 52, width: third, height: 44)
            let title = macro.tileLabel.isEmpty ? (macro.label.isEmpty ? "\(macro.number)" : macro.label) : macro.tileLabel
            let made = button(title, frame: frame) { Actions.macro(macro.number) }
            made.fontSize = 11.5
            made.setAccessibilityLabel(Strings.text(.macrosTile, macro.number, macro.label))
            made.menu = macroMenu(macro.number)
            let stripe = Surface(frame: NSRect(x: frame.minX + 6, y: frame.maxY - 7, width: frame.width - 12, height: 3))
            stripe.radius = 1.5
            stripe.fill = NSColor(srgbRed: macro.color.r, green: macro.color.g, blue: macro.color.b, alpha: 1)
            content.addSubview(stripe)
        }
    }

    /// Spec 10 §7 — "A tile's menu: Run; Bind a Key… (Settings ▸ Key bindings
    /// with a new row for it); Edit (edit mode's macro editor ...)". Key
    /// bindings are Area 17's, so Bind a Key… waits; Edit is disabled under
    /// the lock with the reason (Spec 11 §2).
    func macroMenu(_ number: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let run = ClosureMenuItem(title: Strings.text(.editMacroRun)) { [weak model] in model?.send(Actions.macro(number)) }
        run.isEnabled = model.store.cannotSend == nil
        menu.addItem(run)
        let bind = ClosureMenuItem(title: Strings.text(.editMacroBindKey)) {}
        bind.isEnabled = false
        bind.toolTip = Strings.text(.unavailableLater)
        menu.addItem(bind)
        let edit = ClosureMenuItem(title: Strings.text(.editMacroEdit)) { [weak self] in self?.onEditMacro?(number) }
        let cannot = model.editing.cannotOpen
        edit.isEnabled = cannot == nil
        edit.toolTip = cannot.map(UnavailableWording.sentence)
        menu.addItem(edit)
        return menu
    }

    // "Popups, one row per popup slot ... Below, the timers (P9): one row per timer slot".
    private func buildPopups() {
        let w = contentWidth
        let settings = model.store.catalog?.settings
        var y: CGFloat = 4
        for slot in stride(from: 1, through: settings?.popups ?? 0, by: 1) {
            let status = model.store.popups[slot]
            _ = text("\(slot)", frame: NSRect(x: 0, y: y + 5, width: 14, height: 15), mono: true)
            // "the slot's current text, read-only on one line with the time left on its clear-after".
            var current = status?.isSet == true ? (status?.text ?? "") : Strings.text(.popupEmpty)
            if let left = status?.clearInMs, left > 0, let at = model.store.popupAt[slot] {
                current += "  " + TimeText.clock(ms: max(0, left - Int((model.now - at) * 1000)), roundUp: true)
            }
            let shown = text(current, frame: NSRect(x: 16, y: y + 5, width: w * 0.26, height: 15), color: status?.isSet == true ? Palette.text : Palette.faintText)
            shown.setAccessibilityLabel(Strings.text(.popupSlot, slot) + ": " + current)
            // "then the operator's draft in a text field that no event changes".
            let field = DraftField(text: drafts[slot] ?? "", label: Strings.text(.popupDraft, slot)) { [weak self] in self?.drafts[slot] = $0 }
            let fieldX = 16 + w * 0.26 + 4
            let buttons: CGFloat = 54 + 50 + 64 + 12
            field.frame = NSRect(x: fieldX, y: y + 1, width: max(40, w - fieldX - buttons), height: 24)
            content.addSubview(field)
            let after = NSPopUpButton(frame: NSRect(x: field.frame.maxX + 4, y: y, width: 64, height: 26), pullsDown: false)
            after.font = .systemFont(ofSize: 11)
            after.isBordered = false
            for choice in PopupClearAfter.choices { after.addItem(withTitle: ShowWording.clearAfter(choice)) }
            after.selectItem(at: PopupClearAfter.choices.firstIndex { $0 == (clearAfter[slot] ?? nil) } ?? 0)
            after.setAccessibilityLabel(Strings.text(.popupClearAfter))
            let picked = ClosureTarget { [weak self, weak after] in
                guard let self, let after else { return }
                self.clearAfter[slot] = PopupClearAfter.choices[max(0, after.indexOfSelectedItem)]
            }
            after.target = picked
            after.action = #selector(ClosureTarget.fire)
            targets.append(picked)
            content.addSubview(after)
            let send = button(Strings.text(.popupSend), frame: NSRect(x: after.frame.maxX + 4, y: y, width: 54, height: 26)) { [weak self] in
                guard let self, let draft = self.drafts[slot], !draft.isEmpty else { return nil }
                // "Send empties the draft and hands the focus back to the window (§9)."
                self.drafts[slot] = ""
                field.stringValue = ""
                field.handKeysBack()
                return Actions.popupSend(slot: slot, text: draft, clearAfterSeconds: self.clearAfter[slot] ?? nil)
            }
            field.onReturn = { [weak send] in send?.press() }
            _ = button(Strings.text(.transportClear), frame: NSRect(x: send.frame.maxX + 4, y: y, width: 50, height: 26)) { Actions.popupClear(slot: slot) }
            y += 34
        }
        for slot in stride(from: 1, through: settings?.timers ?? 0, by: 1) {
            let status = model.store.timers[slot]
            _ = text("\(slot)", frame: NSRect(x: 0, y: y + 5, width: 14, height: 15), mono: true)
            let value = text(status?.text ?? "", frame: NSRect(x: 16, y: y + 5, width: 60, height: 15), color: Palette.text, mono: true)
            value.setAccessibilityLabel(Strings.text(.timerSlot, slot) + ": " + (status?.text ?? ""))
            // "a duration field that no event changes".
            let field = DraftField(text: durations[slot] ?? "", label: Strings.text(.timerDuration, slot)) { [weak self] in self?.durations[slot] = $0 }
            field.frame = NSRect(x: 80, y: y + 1, width: max(40, w - 80 - 62 - 44 - 56 - 54 - 16), height: 24)
            content.addSubview(field)
            let up = counting[slot] ?? (status?.direction == "up")
            let direction = button(Strings.text(up ? .timerUp : .timerDown), style: .bare, frame: NSRect(x: field.frame.maxX + 4, y: y, width: 58, height: 26)) { nil }
            direction.onPress = { [weak self] in
                self?.counting[slot] = !up
                self?.refresh()
            }
            direction.isEnabled = true
            // "Set (`timer N set DURATION [up]`)": the grammar's spellings (Area 13 reading).
            let set = button(Strings.text(.timerSet), frame: NSRect(x: direction.frame.maxX + 4, y: y, width: 40, height: 26)) { [weak self] in
                guard let self, let ms = DurationText.ms(self.durations[slot] ?? "") else { return nil }
                // Spec 10 §9 — "A single-line field that acts on Return (... a popup or timer row ...) hands the focus back".
                field.handKeysBack()
                return Actions.timerSet(slot: slot, ms: ms, up: up)
            }
            // Return in the duration field is Set (Area 13 reading: the row's field acts as its first button does).
            field.onReturn = { [weak set] in set?.press() }
            let running = status?.isRunning ?? false
            let start = button(Strings.text(running ? .transportPause : .timerStart), frame: NSRect(x: direction.frame.maxX + 48, y: y, width: 52, height: 26)) {
                running ? Actions.timerPause(slot: slot) : Actions.timerStart(slot: slot)
            }
            _ = button(Strings.text(.timerReset), frame: NSRect(x: start.frame.maxX + 4, y: y, width: 50, height: 26)) { Actions.timerReset(slot: slot) }
            y += 34
        }
    }

    private var targets: [ClosureTarget] = []

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for button in tabButtons {
            let size = button.fitting
            button.frame = NSRect(x: x, y: 5, width: size.width, height: 24)
            x += size.width + 2
        }
        collapse.frame = NSRect(x: bounds.width - 32, y: 5, width: 24, height: 24)
        content.frame = NSRect(x: 12, y: Self.barHeight, width: bounds.width - 24, height: max(0, bounds.height - Self.barHeight))
    }
}

/// A thin bar that shows how far something has run, with no way to move it (choice U-5: "there is no seek command in v1").
@MainActor
final class ProgressBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }
    var color = Palette.selection { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Palette.raisedHigh.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        color.setFill()
        let width = bounds.width * CGFloat(min(1, max(0, fraction)))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// A text field that holds the operator's draft: "a text field that no event changes" (Spec 10 §7).
@MainActor
final class DraftField: ShowField, NSTextFieldDelegate {
    private let changed: (String) -> Void
    var onReturn: (() -> Void)?

    init(text: String, label: String, changed: @escaping (String) -> Void) {
        self.changed = changed
        // Spec 10 §9 — a popup or timer row's field: Return acts, and Escape "leaves the field and keeps the text".
        super.init(kind: .row)
        stringValue = text
        font = .systemFont(ofSize: 12)
        bezelStyle = .roundedBezel
        placeholderString = label
        setAccessibilityLabel(label)
        delegate = self
        target = self
        action = #selector(returned)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ notification: Notification) {
        changed(stringValue)
    }

    @objc private func returned() {
        changed(stringValue)
        onReturn?()
    }

    /// Types into it, as the operator would.
    func type(_ text: String) {
        stringValue = text
        changed(text)
    }
}

/// A target for a control that runs a closure.
@MainActor
final class ClosureTarget: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) {
        self.run = run
    }

    @objc func fire() {
        run()
    }
}
