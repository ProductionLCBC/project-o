// OAppUI — Spec 10 §7, the channel strip, and Spec 10 §6, the media pool panel.

import AppKit
import OApp
import OCore

/// Spec 10 §7, "A cell shows".
@MainActor
final class StripCellView: Surface {
    static let height: CGFloat = 78

    let cell: StripCell
    private let model: ShowModel
    let badge = FlatButton(style: .plain)
    private let picture = SurfaceView()
    private let text = Kit.content(Kit.label(size: 9.5, weight: .medium))
    let label = Kit.content(Kit.label(size: 12.5, weight: .semibold))
    let kind = Kit.label(size: 11)
    let detail = Kit.content(Kit.label(size: 11))
    let remaining = Kit.label(size: 11, mono: true)
    private var tags: [TagView] = []
    private(set) var buttons: [FlatButton] = []
    private(set) var dots: [FlatButton] = []
    private var dotMarks: [DotView] = []
    private let meter = MeterView()
    private let transition = ProgressBar(frame: .zero)
    private var showsOriginUntil: TimeInterval = 0

    init(_ cell: StripCell, model: ShowModel, showsOriginUntil: TimeInterval = 0) {
        self.cell = cell
        self.model = model
        self.showsOriginUntil = showsOriginUntil
        super.init(frame: .zero)
        radius = 9
        fill = Palette.raised
        // Blue for selection (Spec 10 §4); the badge says it too, so colour is never the only signal.
        if cell.isSelected {
            outline = Palette.selection
            outlineWidth = 1.5
        }
        let away = model.store.cannotSend
        badge.title = "\(cell.number)"
        badge.isOnRaised = true
        badge.isOn = cell.isSelected
        badge.fontSize = 12
        badge.setAccessibilityLabel(Strings.text(.stripSelect, cell.number))
        badge.setAccessibilityValue(cell.isSelected ? "1" : "0")
        // "the number badge toggles a channel in or out".
        badge.onPress = { [weak model] in model?.toggleSelection(cell.number) }
        label.stringValue = cell.label
        kind.stringValue = ShowWording.kind(cell.kind)
        kind.textColor = Palette.faintText
        detail.textColor = Palette.dimText
        detail.stringValue = cell.contentLabel
        remaining.textColor = Palette.dimText
        remaining.alignment = .right
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.cell?.truncatesLastVisibleLine = true
        text.alignment = .center
        text.setAccessibilityElement(false)
        switch cell.picture {
        case .text(let body): text.stringValue = body
        case .audio: text.stringValue = "♪"
        case .live, .none: text.stringValue = ""
        }
        picture.setAccessibilityElement(false)
        if cell.isLocked { tags.append(TagView(Strings.text(.tagLocked), style: model.isBlocked(cell.number) ? .red : .quiet)) }
        if let grade = cell.grade { tags.append(TagView(grade, style: .quiet)) }
        if cell.isMissing { tags.append(TagView(Strings.text(.tagMissing), style: .dashedRed)) }
        if model.showsReset { tags.append(TagView(Strings.text(.stripReset), style: .amber)) }
        for button in cell.buttons {
            let made: FlatButton
            switch button {
            case .play: made = FlatButton(Strings.text(.transportPlay)) { [weak model] in model?.send(Actions.transport(.play, channels: [cell.number])) }
            case .pause: made = FlatButton(Strings.text(.transportPause)) { [weak model] in model?.send(Actions.transport(.pause, channels: [cell.number])) }
            case .stop: made = FlatButton(Strings.text(.transportStop)) { [weak model] in model?.send(Actions.transport(.stop, channels: [cell.number])) }
            case .clear: made = FlatButton(Strings.text(.transportClear)) { [weak model] in model?.send(Actions.clear(channel: cell.number)) }
            }
            made.fontSize = 10.5
            made.isOnRaised = true
            made.isEnabled = away == nil
            made.reason = ShowWording.unavailable(away)
            buttons.append(made)
        }
        // "Stack dots: one per stack, in stack order ... a hit area of at least 16 points".
        for dot in cell.dots {
            let button = FlatButton(style: .bare)
            let mark = DotView()
            switch dot.state {
            case .showing: mark.color = Palette.outputting
            case .muted:
                mark.color = Palette.browsing
                mark.isHollow = true
            case .absent:
                mark.color = Palette.faintText
                mark.isHollow = true
            }
            button.setAccessibilityLabel(ShowWording.dot(dot))
            button.toolTip = ShowWording.dot(dot)
            // "hollow grey and inert where the stack doesn't hold the channel".
            button.isEnabled = dot.state != .absent && away == nil
            button.reason = dot.state == .absent ? ShowWording.dot(dot) : ShowWording.unavailable(away)
            button.onPress = { [weak model] in model?.send(Actions.stackMute(stack: dot.stack, channel: cell.number)) }
            button.addSubview(mark)
            dots.append(button)
            dotMarks.append(mark)
        }
        meter.isHidden = !cell.hasMeter
        meter.setAccessibilityLabel(Strings.text(.meterLabel, cell.number))
        transition.isHidden = true
        transition.setAccessibilityElement(false)
        for view in [picture, text, badge, label, kind, detail, remaining, meter, transition] as [NSView] + tags + buttons + dots { addSubview(view) }
        tick()
        setAccessibilityElement(false)
        setAccessibilityLabel(Strings.text(.stripChannel, cell.number, cell.label))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What moves between events: the remaining time, the transition's bar, the provenance line.
    func tick() {
        if let left = cell.remaining {
            remaining.stringValue = ShowWording.remaining(left)
        } else {
            remaining.stringValue = ""
        }
        if let progress = model.transitionProgress(channel: cell.number) {
            transition.isHidden = false
            transition.fraction = progress
            // "Stepped on, it flashes red".
            transition.color = model.isSteppedOn(cell.number) ? Palette.live : Palette.selection
        } else {
            transition.isHidden = true
        }
        // "for five seconds under the label, what put the content there".
        if model.now < showsOriginUntil, let origin = cell.origin {
            detail.stringValue = ShowWording.origin(origin)
        } else {
            detail.stringValue = cell.contentLabel
        }
    }

    func draw(mach: MachLink?) {
        if case .live = cell.picture { picture.set(mach?.picture(channel: cell.number)) } else { picture.set(nil) }
        if cell.hasMeter { meter.level = mach?.level(channel: cell.number) }
    }

    /// Shows what put the content there, as a click on the thumbnail does.
    func showOrigin() {
        showsOriginUntil = model.now + 5
        tick()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        picture.frame = NSRect(x: 8, y: 8, width: 96, height: 54)
        text.frame = picture.frame.insetBy(dx: 4, dy: 4)
        let x: CGFloat = 114
        let meterWidth: CGFloat = cell.hasMeter ? 10 : 0
        let right = w - 10 - meterWidth
        badge.frame = NSRect(x: x, y: 8, width: 24, height: 20)
        let kindWidth = Kit.width(of: kind)
        kind.frame = NSRect(x: right - kindWidth, y: 11, width: kindWidth, height: 14)
        label.frame = NSRect(x: x + 30, y: 9, width: max(20, right - kindWidth - 8 - x - 30), height: 17)
        let remainingWidth = Kit.width(of: remaining)
        remaining.frame = NSRect(x: right - remainingWidth, y: 31, width: remainingWidth, height: 14)
        var tagRight = right - remainingWidth - (remainingWidth > 0 ? 6 : 0)
        for tag in tags.reversed() {
            let size = tag.fitting
            tag.frame = NSRect(x: tagRight - size.width, y: 30, width: size.width, height: size.height)
            tagRight -= size.width + 4
        }
        detail.frame = NSRect(x: x, y: 31, width: max(20, tagRight - x - 4), height: 14)
        var bx = x
        for button in buttons {
            let size = button.fitting
            button.frame = NSRect(x: bx, y: 51, width: size.width - 4, height: 21)
            bx += size.width
        }
        var dx = right
        for (button, mark) in zip(dots, dotMarks).reversed() {
            button.frame = NSRect(x: dx - 18, y: 51, width: 18, height: 18)
            mark.frame = NSRect(x: 4, y: 4, width: 10, height: 10)
            dx -= 20
        }
        meter.frame = NSRect(x: w - 14, y: 8, width: 6, height: 60)
        transition.frame = NSRect(x: 8, y: bounds.height - 6, width: w - 16, height: 3)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.control) { return showMenu(event) }
        // "a click on the thumbnail selects that channel alone", and shows its provenance for five seconds.
        if picture.frame.contains(point) {
            onThumbnail?(cell.number)
            model.selectOnly(cell.number)
        }
    }

    /// Called on a click on the thumbnail, before the selection changes and the cells are made again.
    var onThumbnail: ((Int) -> Void)?

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    /// Spec 10 §7, "A cell's menu".
    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let away = model.store.cannotSend
        let number = cell.number
        func add(_ title: String, _ sending: @escaping () -> Sending) {
            let item = ClosureMenuItem(title: title) { [weak model] in model?.send(sending()) }
            item.isEnabled = away == nil
            item.toolTip = ShowWording.unavailable(away)
            menu.addItem(item)
        }
        // "The cell's menu starts with the same line."
        if let origin = cell.origin {
            let line = NSMenuItem(title: ShowWording.origin(origin), action: nil, keyEquivalent: "")
            line.isEnabled = false
            menu.addItem(line)
            menu.addItem(.separator())
        }
        let locked = cell.isLocked
        add(Strings.text(.transportClear)) { Actions.clear(channel: number) }
        // "Lock or Unlock (`channel N lock`, `unlock`)".
        add(Strings.text(locked ? .stripUnlock : .stripLock)) { Actions.lock(channel: number, !locked) }
        add(Strings.text(.stripResetAttributes)) { Actions.resetAttributes(channel: number) }
        func submenu(_ title: String, _ fill: (NSMenu) -> Void) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            fill(sub)
            item.submenu = sub
            menu.addItem(item)
        }
        func entry(_ sub: NSMenu, _ title: String, _ sending: @escaping () -> Sending) {
            let item = ClosureMenuItem(title: title) { [weak model] in model?.send(sending()) }
            item.isEnabled = away == nil
            sub.addItem(item)
        }
        submenu(Strings.text(.stripEndBehaviour)) { sub in
            entry(sub, Strings.text(.transportLoop)) { Actions.end(.loop, channel: number) }
            entry(sub, Strings.text(.transportHold)) { Actions.end(.hold, channel: number) }
            entry(sub, Strings.text(.transportClear)) { Actions.end(.clear, channel: number) }
        }
        // "Grade ▸ (None and each grade; `channel N grade G`, which tracks, Spec 2 §3)".
        submenu(Strings.text(.stripGrade)) { sub in
            entry(sub, Strings.text(.stripGradeNone)) { Actions.grade(channel: number, grade: 0) }
            for grade in (model.store.catalog?.grades ?? []).sorted(by: { $0.number < $1.number }) {
                entry(sub, Strings.text(.stripGradeNumbered, grade.number, grade.label)) { Actions.grade(channel: number, grade: grade.number) }
            }
        }
        // "Transition ▸ (each transition; `channel N transition R`)".
        submenu(Strings.text(.stripTransition)) { sub in
            for transition in (model.store.catalog?.transitions ?? []).sorted(by: { $0.number < $1.number }) {
                entry(sub, Strings.text(.stripGradeNumbered, transition.number, transition.label)) {
                    Actions.transition(channel: number, transition: transition.number)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.stripSelectOnly)) { [weak model] in model?.selectOnly(number) })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    var shownTags: [String] { tags.map(\.text) }
}

/// Spec 10 §7 — "the meter when its content has sound, from the Mach
/// channel, green below −12 dBFS, amber to −3 and red above".
@MainActor
final class MeterView: NSView {
    /// The peak in dBFS; nil for none.
    var level: Double? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Palette.well.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        guard let level else { return }
        // −60 dBFS at the foot, 0 at the top.
        let fraction = CGFloat(min(1, max(0, (level + 60) / 60)))
        switch MeterZone.of(dBFS: level) {
        case .green: Palette.outputting.setFill()
        case .amber: Palette.browsing.setFill()
        case .red: Palette.live.setFill()
        }
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * fraction), xRadius: 2, yRadius: 2).fill()
        setAccessibilityValue(String(format: "%.0f dBFS", level))
    }
}

/// Spec 10 §7, "The channel strip".
@MainActor
final class StripView: Surface {
    private let model: ShowModel
    private let mach: MachLink?
    let clearAll = FlatButton(Strings.text(.clearsClearAll), style: .danger)
    let clearPopups = FlatButton(Strings.text(.clearsClearPopups), style: .plain)
    let clearSelected = FlatButton(Strings.text(.stripClearSelected), style: .plain)
    let all = FlatButton(Strings.text(.stripAll), style: .bare)
    let none = FlatButton(Strings.text(.stripNone), style: .bare)
    let view = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scroll = NSScrollView()
    private let document = Surface()
    private(set) var cells: [StripCellView] = []
    static let headerHeight: CGFloat = 72

    init(model: ShowModel, mach: MachLink?) {
        self.model = model
        self.mach = mach
        super.init(frame: .zero)
        // "Clear All has no hold-to-confirm: it is the panic button."
        clearAll.fontWeight = .semibold
        clearAll.onPress = { [weak model] in model?.send(Actions.clearAll()) }
        clearPopups.onPress = { [weak model] in
            guard let model else { return }
            model.send(Actions.clearPopups(slots: model.store.catalog?.settings?.popups ?? 0))
        }
        clearSelected.onPress = { [weak model] in
            guard let model else { return }
            model.send(Actions.clearSelected(model.selection.channels))
        }
        all.onPress = { [weak model] in model?.selectAll() }
        none.onPress = { [weak model] in model?.selectNone() }
        view.font = .systemFont(ofSize: 11.5)
        view.isBordered = false
        view.target = self
        view.action = #selector(viewed)
        view.setAccessibilityLabel(Strings.text(.stripView))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        for sub in [clearAll, clearPopups, clearSelected, all, none, view, scroll] as [NSView] { addSubview(sub) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func viewed() {
        let tag = view.selectedItem?.tag ?? 0
        model.show(stripStack: tag == 0 ? nil : tag)
    }

    func refresh() {
        let away = model.store.cannotSend
        let reason = ShowWording.unavailable(away)
        clearAll.isEnabled = away == nil
        clearAll.reason = reason
        // "It leaves popups up (Spec 6 §7), so while any popup slot is set, Clear Popups shows beside it."
        clearPopups.isHidden = !model.store.popups.values.contains(where: \.isSet)
        clearPopups.isEnabled = away == nil
        clearPopups.reason = reason
        // "enabled only with a selection and heavier when there is one".
        let selected = !model.selection.channels.isEmpty
        clearSelected.isEnabled = selected && away == nil
        clearSelected.reason = reason
        clearSelected.fontWeight = selected ? .semibold : .medium
        view.removeAllItems()
        view.addItem(withTitle: Strings.text(.stripViewAll))
        view.lastItem?.tag = 0
        for stack in (model.store.catalog?.stacks ?? []).sorted(by: { $0.number < $1.number }) {
            view.addItem(withTitle: Strings.text(.previewStack, stack.number, stack.label))
            view.lastItem?.tag = stack.number
        }
        view.selectItem(withTag: model.settings.stripStack ?? 0)
        for cell in cells { cell.removeFromSuperview() }
        cells = model.stripCells.map { cell in
            let view = StripCellView(cell, model: model, showsOriginUntil: originUntil[cell.number] ?? 0)
            // "A click on the thumbnail also shows, for five seconds under the label, what put the content there".
            view.onThumbnail = { [weak self] channel in
                guard let self else { return }
                self.originUntil = [channel: self.model.now + 5]
            }
            return view
        }
        for cell in cells { document.addSubview(cell) }
        needsLayout = true
        draw()
    }

    /// The channel whose provenance shows, and until when on the app's clock.
    private var originUntil: [Int: TimeInterval] = [:]

    func tick() {
        for cell in cells { cell.tick() }
    }

    func draw() {
        for cell in cells { cell.draw(mach: mach) }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        // "Clear All, wide, red and set apart by a gap from Clear Selected", which sits at the far side; Clear
        // Popups "shows beside it" while a slot is set. Under them, All, None and the view.
        let clearAllWidth = max(96, clearAll.fitting.width + 16)
        clearAll.frame = NSRect(x: 0, y: 4, width: clearAllWidth, height: 30)
        if !clearPopups.isHidden {
            let size = clearPopups.fitting
            clearPopups.frame = NSRect(x: clearAllWidth + 6, y: 7, width: size.width, height: 24)
        }
        let selectedSize = clearSelected.fitting
        clearSelected.frame = NSRect(x: w - selectedSize.width, y: 7, width: selectedSize.width, height: 24)
        var x: CGFloat = 0
        for button in [all, none] {
            let size = button.fitting
            button.frame = NSRect(x: x, y: 42, width: size.width, height: 22)
            x += size.width + 2
        }
        view.frame = NSRect(x: max(x + 8, w - 170), y: 40, width: min(170, w - x - 8), height: 26)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight, width: w, height: max(0, bounds.height - Self.headerHeight))
        let width = scroll.contentSize.width
        for (index, cell) in cells.enumerated() {
            cell.frame = NSRect(x: 0, y: CGFloat(index) * (StripCellView.height + 6), width: width, height: StripCellView.height)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, CGFloat(cells.count) * (StripCellView.height + 6)))
    }
}

/// Spec 10 §6, "Tiles" — one item of the pool.
@MainActor
final class PoolTileView: Surface {
    static let size = NSSize(width: 140, height: 98)
    let tile: PoolTile
    private let picture = NSImageView()
    private let glyph = Kit.label(size: 18)
    let name = Kit.content(Kit.label(size: 11, weight: .medium))
    let kind = Kit.label(size: 10)
    private let duration = Kit.label(size: 9.5, weight: .medium, mono: true)
    private var overlay: TagView?
    var onClick: ((_ clicks: Int, NSEvent) -> Void)?

    init(_ tile: PoolTile, isSelected: Bool, machineRoot: URL?) {
        self.tile = tile
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        radius = 8
        fill = isSelected ? Palette.raisedHigh : Palette.raised
        if isSelected {
            outline = Palette.selection
            outlineWidth = 1.5
        }
        picture.wantsLayer = true
        picture.layer?.backgroundColor = Palette.well.cgColor
        picture.layer?.cornerRadius = 5
        picture.layer?.masksToBounds = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityElement(false)
        // "for audio its kind glyph and duration".
        glyph.stringValue = tile.kind == .audio || tile.kind == .audioSet ? "♪" : ""
        glyph.textColor = Palette.faintText
        glyph.alignment = .center
        glyph.setAccessibilityElement(false)
        if let file = tile.tile, let root = machineRoot {
            picture.image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] in self?.picture.image = $0 }
        }
        name.stringValue = tile.name
        var kindText = ShowWording.kind(tile.kind)
        if tile.isOnThisMac { kindText += " · " + Strings.text(.poolThisMac) }
        kind.stringValue = kindText
        kind.textColor = Palette.faintText
        duration.stringValue = tile.durationMs.map { TimeText.clock(ms: $0) } ?? ""
        duration.textColor = Palette.text
        duration.alignment = .right
        for view in [picture, glyph, name, kind, duration] as [NSView] { addSubview(view) }
        // "A missing item keeps its place with a striped, red-dashed overlay."
        switch tile.overlay {
        case .none: break
        case .missing: overlay = TagView(Strings.text(.tagMissing), style: .dashedRed)
        case .deleted: overlay = TagView(Strings.text(.tagDeleted), style: .dashedRed)
        }
        if let overlay {
            addSubview(overlay)
            outline = Palette.live
            isDashed = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(([tile.name, kindText, duration.stringValue] + (overlay.map { [$0.text] } ?? [])).filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: 54)
        glyph.frame = NSRect(x: 6, y: 20, width: bounds.width - 12, height: 24)
        duration.frame = NSRect(x: 6, y: 44, width: bounds.width - 16, height: 13)
        name.frame = NSRect(x: 7, y: 63, width: bounds.width - 14, height: 14)
        kind.frame = NSRect(x: 7, y: 78, width: bounds.width - 14, height: 13)
        if let overlay {
            let size = overlay.fitting
            overlay.frame = NSRect(x: (bounds.width - size.width) / 2, y: 25, width: size.width, height: size.height)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(event.clickCount, event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(1, NSEvent())
        return true
    }
}

/// Spec 10 §6, "The Media pool panel" — "sits under the grid behind a
/// divider ... the panel has no tabs and is headed "Media"."
@MainActor
final class PoolView: Surface {
    private let model: ShowModel
    var machineRoot: URL?
    private let title = Kit.heading(Strings.text(.poolTitle))
    let search = Kit.search(placeholder: Strings.text(.poolSearch))
    let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    let sort = NSPopUpButton(frame: .zero, pullsDown: false)
    let usedInList = FlatButton(Strings.text(.poolUsedInList), style: .bare)
    let replaced = FlatButton(Strings.text(.poolReplaced), style: .bare)
    let importMedia = FlatButton(Strings.text(.poolImport), style: .plain)
    let rail = RowList()
    private let scroll = NSScrollView()
    private let document = Surface()
    private(set) var tiles: [PoolTileView] = []
    static let headerHeight: CGFloat = 40
    /// Spec 10 §6, "The divider" — collapsed, the panel "shows the pool's header and one strip of the twenty most
    /// recently used items": this height.
    static let collapsedHeight: CGFloat = headerHeight + PoolTileView.size.height + 14

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        search.target = self
        search.action = #selector(searched)
        for (popup, action) in [(kind, #selector(kindPicked)), (sort, #selector(sortPicked))] {
            popup.font = .systemFont(ofSize: 11.5)
            popup.isBordered = false
            popup.target = self
            popup.action = action
        }
        for key in [StringKey.poolKindAll, .kindVideo, .kindImage, .kindAudio] { kind.addItem(withTitle: Strings.text(key)) }
        kind.setAccessibilityLabel(Strings.text(.poolKindAll))
        for key in [StringKey.poolSortName, .poolSortDate] { sort.addItem(withTitle: Strings.text(key)) }
        sort.setAccessibilityLabel(Strings.text(.poolSortName))
        usedInList.fontSize = 11
        replaced.fontSize = 11
        usedInList.onPress = { [weak self] in self?.toggleUsed() }
        replaced.onPress = { [weak model] in model?.setPool { $0.replacedOnly.toggle() } }
        // Importing comes with the drops' stage.
        importMedia.isEnabled = false
        importMedia.reason = Strings.text(.unavailableLater)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        for view in [title, search, kind, sort, usedInList, replaced, importMedia, rail, scroll] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func searched() { model.setPool { $0.search = self.search.stringValue } }
    @objc private func kindPicked() {
        let kinds: [ViewSettings.PoolKind] = [.all, .video, .image, .audio]
        model.setPool { $0.kind = kinds[max(0, min(3, self.kind.indexOfSelectedItem))] }
    }
    @objc private func sortPicked() { model.setPool { $0.sort = self.sort.indexOfSelectedItem == 1 ? .dateAdded : .name } }

    /// "a "used in this list" filter over the browsed list's references".
    private func toggleUsed() {
        if model.poolFilter.usedIn != nil {
            model.setPool { $0.usedIn = nil }
        } else {
            var ids: Set<String> = []
            for section in model.grid.sections {
                guard let uuid = section.listUuid, let list = model.store.lists[uuid]?.list else { continue }
                for cue in list.cues {
                    for case .channelWrite(let write) in cue.commands.map(\.command) {
                        if case .media(let media) = write.content { ids.insert(media.ref) }
                        if case .slide(let ref, _) = write.content { ids.insert(ref) }
                    }
                }
            }
            model.setPool { $0.usedIn = ids }
        }
    }

    func refresh() {
        let filter = model.poolFilter
        usedInList.isOn = filter.usedIn != nil
        replaced.isOn = filter.replacedOnly
        kind.selectItem(at: [ViewSettings.PoolKind.all, .video, .image, .audio].firstIndex(of: filter.kind) ?? 0)
        sort.selectItem(at: filter.sort == .dateAdded ? 1 : 0)
        let collapsed = model.settings.panel == .collapsed
        // "The folder rail shows the default import folder pinned at the top, then the media root's folders as a tree."
        var rows: [RowView] = []
        var all = RowContent(title: Strings.text(.poolAllMedia), isSelected: filter.folder == nil)
        all.spoken = all.title
        let allRow = RowView(all)
        allRow.onClick = { [weak model] _ in model?.setPool { $0.folder = nil } }
        rows.append(allRow)
        for folder in MediaPool.folders(model.store.media) {
            var content = RowContent(indent: CGFloat(folder.split(separator: "/").count - 1) * 12, title: LibraryTreeName.last(folder), isSelected: filter.folder == folder)
            content.spoken = folder
            let row = RowView(content)
            row.onClick = { [weak model] _ in model?.setPool { $0.folder = folder } }
            rows.append(row)
        }
        rail.set(rows)
        rail.isHidden = collapsed

        for tile in tiles { tile.removeFromSuperview() }
        // "collapsed, which shows the pool's header and one strip of the twenty most recently used items".
        let shown = collapsed ? model.recentTiles : model.poolTiles
        tiles = shown.map { tile in
            let view = PoolTileView(tile, isSelected: tile.id == model.selectedMedia, machineRoot: machineRoot)
            view.onClick = { [weak self, weak view] clicks, event in
                guard let self, let view else { return }
                // "Single click selects ... Double-click writes it live to its drop channel ... There is no single-click firing."
                if clicks >= 2 {
                    if !self.model.goLive(media: tile.id) { self.askChannel(for: tile, at: view, event) }
                } else {
                    self.model.select(media: tile.id)
                }
            }
            return view
        }
        for tile in tiles { document.addSubview(tile) }
        needsLayout = true
    }

    /// "asking for a channel when that is "Ask"".
    private func askChannel(for tile: PoolTile, at view: NSView, _ event: NSEvent) {
        let menu = NSMenu()
        for channel in (model.store.catalog?.channels ?? []).sorted(by: { $0.number < $1.number }) {
            menu.addItem(ClosureMenuItem(title: Strings.text(.stripChannel, channel.number, channel.label)) { [weak model] in
                model?.goLive(media: tile.id, on: channel.number)
            })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 16, y: 13, width: 84, height: 14)
        let importSize = importMedia.fitting
        importMedia.frame = NSRect(x: w - 14 - importSize.width, y: 8, width: importSize.width, height: 24)
        var right = importMedia.frame.minX - 8
        for button in [replaced, usedInList] {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: 9, width: size.width, height: 22)
            right -= size.width + 2
        }
        sort.frame = NSRect(x: right - 104, y: 7, width: 104, height: 26)
        kind.frame = NSRect(x: sort.frame.minX - 72, y: 7, width: 72, height: 26)
        search.frame = NSRect(x: 104, y: 8, width: max(60, min(220, kind.frame.minX - 116)), height: 24)
        let railWidth: CGFloat = rail.isHidden ? 0 : 150
        rail.frame = NSRect(x: 0, y: Self.headerHeight, width: railWidth, height: max(0, bounds.height - Self.headerHeight))
        scroll.frame = NSRect(x: railWidth, y: Self.headerHeight, width: w - railWidth, height: max(0, bounds.height - Self.headerHeight))
        let width = scroll.contentSize.width
        let gap: CGFloat = 10
        var x: CGFloat = 12
        var y: CGFloat = 4
        for tile in tiles {
            if x + PoolTileView.size.width > width - 8, x > 12 {
                x = 12
                y += PoolTileView.size.height + gap
            }
            tile.frame = NSRect(origin: NSPoint(x: x, y: y), size: PoolTileView.size)
            x += PoolTileView.size.width + gap
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, y + PoolTileView.size.height + 8))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    // "Double-click toggles collapsed and default."
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, convert(event.locationInWindow, from: nil).y < Self.headerHeight else { return }
        model.change { $0.panel = PoolDivider.toggled($0.panel) }
    }
}

/// The last part of a folder's path: its own name.
enum LibraryTreeName {
    static func last(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
