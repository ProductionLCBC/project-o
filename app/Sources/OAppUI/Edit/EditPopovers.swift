// OAppUI — Spec 11 §4, the small panels the Cues page's controls open: content, a chip, a command.

import AppKit
import OApp
import OCore

/// Spec 11 §2, "Picking media" (G-42) — "the pool's folder rail as a tree, its search and kind filter over its tiles
/// (Spec 10 §6), with only the kinds that fit offered; a click selects a tile, and a double-click or Choose takes it.
/// Where nothing is a choice (a transition's black, the preset editor's test pattern), it is the first tile." The rail
/// shows when there is room for it beside the tiles.
@MainActor
final class MediaPickerView: Surface {
    private let model: ShowModel
    private let machineRoot: URL?
    /// The kinds that fit; the filter's All means all of them.
    let kinds: [ViewSettings.PoolKind]
    /// The first tile's title, which picks nothing; nil for none.
    let extra: String?
    let search = Kit.search(placeholder: Strings.text(.poolSearch))
    let kindFilter: SegmentedView
    private let railScroll = NSScrollView()
    private let rail = InspectorDocument()
    private(set) var folders: [FlatButton] = []
    private let scroll = NSScrollView()
    private let document = InspectorDocument()
    private(set) var tiles: [PoolTileView] = []
    private var folder: String?
    private var kind = ViewSettings.PoolKind.all
    /// The chosen item's id; nil is the first tile's nothing, when there is one.
    var selected: String? { didSet { rebuild() } }
    /// A click selects: the item's id, or nil for the first tile.
    var onPick: ((String?) -> Void)?
    /// A double-click takes.
    var onChoose: ((String?) -> Void)?

    static let railWidth: CGFloat = 170

    init(model: ShowModel, machineRoot: URL?, selected: String?, kinds: [ViewSettings.PoolKind] = [.video, .image, .audio], extra: String? = nil) {
        self.model = model
        self.machineRoot = machineRoot
        self.selected = selected
        self.kinds = kinds
        self.extra = extra
        kindFilter = SegmentedView(([.all] + kinds).map { EditModeWording.poolKind($0) }, small: true)
        super.init(frame: .zero)
        search.target = self
        search.action = #selector(searched)
        kindFilter.selected = 0
        kindFilter.setAccessibilityLabel(Strings.text(.editChooserKind))
        kindFilter.onSelect = { [weak self] index in
            let all: [ViewSettings.PoolKind] = [.all] + (self?.kinds ?? [])
            guard let self, all.indices.contains(index) else { return }
            self.kind = all[index]
            self.kindFilter.selected = index
            self.rebuild()
        }
        kindFilter.isHidden = kinds.count < 2
        for view in [scroll, railScroll] {
            view.drawsBackground = false
            view.hasVerticalScroller = true
            view.autohidesScrollers = true
        }
        scroll.documentView = document
        railScroll.documentView = rail
        for view in [search, kindFilter, railScroll, scroll] as [NSView] { addSubview(view) }
        buildRail()
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func searched() { rebuild() }

    /// "the pool's folder rail as a tree": every media, then each folder indented under the one it is in.
    private func buildRail() {
        folders.forEach { $0.removeFromSuperview() }
        let names: [String?] = [nil] + MediaPool.folders(model.store.media).map { Optional($0) }
        folders = names.map { path in
            let depth = path.map { $0.split(separator: "/").count - 1 } ?? 0
            let title = path.map { String($0.split(separator: "/").last ?? "") } ?? Strings.text(.editChooserAll)
            let button = FlatButton(String(repeating: "   ", count: depth) + title, style: .bare)
            button.leading = true
            button.fontSize = 12
            button.setAccessibilityLabel(path ?? title)
            button.onPress = { [weak self] in
                self?.folder = path
                self?.rebuild()
            }
            rail.addSubview(button)
            return button
        }
    }

    private func rebuild() {
        tiles.forEach { $0.removeFromSuperview() }
        var filter = MediaPool.Filter()
        filter.search = search.stringValue
        filter.kind = kind
        filter.folder = folder
        var shown = MediaPool.tiles(model.store.media, filter: filter)
        // "with only the kinds that fit offered".
        let fits = Set(kinds)
        shown = shown.filter { tile in
            switch tile.kind {
            case .video: fits.contains(.video)
            case .image: fits.contains(.image)
            case .audio, .audioSet: fits.contains(.audio)
            default: false
            }
        }
        var views: [PoolTileView] = []
        if let extra {
            let nothing = PoolTile(id: "", name: extra, kind: .image, durationMs: nil, tile: nil, overlay: .none, isOnThisMac: false)
            let view = PoolTileView(nothing, isSelected: selected == nil, machineRoot: nil)
            // Not an item in the pool, so no kind under its name.
            view.kind.stringValue = ""
            view.onClick = { [weak self] clicks, _ in self?.click(nil, clicks) }
            views.append(view)
        }
        for tile in shown {
            let view = PoolTileView(tile, isSelected: tile.id == selected, machineRoot: machineRoot)
            view.onClick = { [weak self] clicks, _ in self?.click(tile.id, clicks) }
            views.append(view)
        }
        tiles = views
        tiles.forEach { document.addSubview($0) }
        for (button, path) in zip(folders, [nil] + MediaPool.folders(model.store.media).map { Optional($0) }) {
            button.isOn = path == folder
        }
        needsLayout = true
    }

    private func click(_ id: String?, _ clicks: Int) {
        if id != selected { selected = id }
        onPick?(id)
        if clicks >= 2 { onChoose?(id) }
    }

    /// Picks an item, as a click on its tile would; nil is the first tile.
    func pick(_ id: String?) {
        click(id, 1)
    }

    override func layout() {
        super.layout()
        let showsRail = bounds.width >= 460 && folders.count > 1
        railScroll.isHidden = !showsRail
        let left: CGFloat = showsRail ? Self.railWidth + 8 : 0
        let filterWidth = kindFilter.isHidden ? 0 : min(kindFilter.fitting.width, (bounds.width - left) * 0.5)
        search.frame = NSRect(x: left, y: 0, width: max(0, bounds.width - left - filterWidth - (filterWidth > 0 ? 8 : 0)), height: 24)
        kindFilter.frame = NSRect(x: bounds.width - filterWidth, y: 0, width: filterWidth, height: 24)
        railScroll.frame = NSRect(x: 0, y: 0, width: Self.railWidth, height: bounds.height)
        var y: CGFloat = 0
        for button in folders {
            button.frame = NSRect(x: 0, y: y, width: Self.railWidth - 4, height: 24)
            y += 26
        }
        rail.frame = NSRect(x: 0, y: 0, width: Self.railWidth, height: max(railScroll.frame.height, y))
        scroll.frame = NSRect(x: left, y: 30, width: max(0, bounds.width - left), height: max(0, bounds.height - 30))
        let width = scroll.frame.width
        let columns = max(2, Int(width / 150))
        let tileWidth = floor((width - CGFloat(columns - 1) * 6) / CGFloat(columns))
        let height = floor(tileWidth * 9 / 16) + 44
        for (index, tile) in tiles.enumerated() {
            tile.frame = NSRect(x: CGFloat(index % columns) * (tileWidth + 6), y: CGFloat(index / columns) * (height + 6), width: tileWidth, height: height)
        }
        let rows = CGFloat((tiles.count + columns - 1) / columns)
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.frame.height, rows * (height + 6)))
    }
}

/// Spec 11 §2, "Picking media" (G-42) — the media chooser in its panel: the picker, and Choose, which takes the
/// selected tile, as a double-click does.
@MainActor
enum MediaChooser {
    static func panel(model: ShowModel, machineRoot: URL?, selected: String?, kinds: [ViewSettings.PoolKind], extra: String? = nil,
                      choose: @escaping @MainActor (String?) -> Void) -> (PromptView, MediaPickerView) {
        let panel = PromptView(heading: Strings.text(.editChooserHeading), width: 680)
        panel.save.title = Strings.text(.editChooserChoose)
        let picker = MediaPickerView(model: model, machineRoot: machineRoot, selected: selected, kinds: kinds, extra: extra)
        panel.addRow("", picker, height: 400)
        panel.onSave = {
            choose(picker.selected)
            return nil
        }
        picker.onChoose = { [weak panel] id in
            choose(id)
            panel?.onClose?()
        }
        return (panel, picker)
    }
}

/// What the content popover holds while it is open: the kind, the text's
/// fields in order, and the media picked with its overrides.
@MainActor
final class ContentDraft {
    enum Kind { case text, media }

    var kind: Kind
    /// The text's fields: the body first, then the others.
    var fields: [(name: String, value: String)]
    var media: MediaContent?

    init(kind: Kind, fields: [(name: String, value: String)], media: MediaContent?) {
        self.kind = kind
        self.fields = fields
        self.media = media
    }
}

/// Spec 11 §4 — the panels the inspector's controls open, each built over the model's edit for it.
@MainActor
enum EditPopovers {
    private static func numbers(_ items: [(number: Int, label: String)], selected: Int?) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 12)
        for item in items {
            popup.addItem(withTitle: item.label.isEmpty ? String(item.number) : "\(item.number) \(item.label)")
            popup.lastItem?.tag = item.number
        }
        if let selected { popup.selectItem(withTag: selected) }
        return popup
    }

    private static func choices(_ titles: [String], selected: Int = 0) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = .systemFont(ofSize: 12)
        for (index, title) in titles.enumerated() {
            popup.addItem(withTitle: title)
            popup.lastItem?.tag = index
        }
        popup.selectItem(withTag: selected)
        return popup
    }

    /// Spec 6 §5's names, as a menu's items insert them: "a Variables ▸ menu that inserts Spec 6 §5's names".
    static func variableNames(catalog: Catalog?) -> [String] {
        let settings = catalog?.settings ?? MachineSettings()
        var names: [VariableName] = [.time, .date, .serviceIn]
        names += (1...max(1, settings.timers)).map(VariableName.timer)
        names += (1...max(1, settings.popups)).map(VariableName.popup)
        names += [.liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli]
        return names.map(\.label)
    }

    /// "a Variables ▸ menu": a button whose menu lists the names alone.
    private static func variablesMenu(catalog: Catalog?, insert: @escaping @MainActor (String) -> Void) -> FlatButton {
        let button = FlatButton(Strings.text(.editContentFormVariables), style: .plain)
        button.fontSize = 12
        let menu = NSMenu()
        for name in variableNames(catalog: catalog) { menu.addItem(ClosureMenuItem(title: name) { insert(name) }) }
        button.dropMenu = menu
        return button
    }

    // MARK: - The palette (Spec 11 §4, "The palette (E4)")

    /// "Add Command offers, grouped by what they touch and only for what
    /// exists ... Each opens a small form with pickers ...; Add inserts the
    /// command after the selected one, or at the end." A command that needs
    /// nothing asked is added at once.
    /// A command's Edit: the command in the canonical text OCore's parser
    /// reads (Spec 2 §4), in one field; Save sets it at its place.
    static func command(heading: String, command: Command, options: ParseOptions, onSave: @escaping @MainActor (Command) -> Void) -> PromptView {
        let panel = PromptView(heading: heading, width: 420)
        let field = panel.text(Strings.text(.editFormCommand), CommandText.print(command) ?? "")
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        panel.onSave = {
            switch CommandText.parse(field.stringValue, options: options) {
            case .success(let entry):
                onSave(entry.command)
                return nil
            case .failure(let rejection):
                return .invalid(Strings.text(.editFormInvalid, rejection.message))
            }
        }
        panel.finish()
        return panel
    }

    // MARK: - A chip (Spec 11 §4, "Attribute chips")

    /// "A click opens a popover with the value (None or a grade; a
    /// transition whose type applies to pixels; an audio transition;
    /// decibels for gain), a duration where the command takes one, the
    /// scope, and Remove."
    static func chip(_ chip: AttributeChip, model: ShowModel) -> PromptView {
        let catalog = model.store.catalog
        let panel = PromptView(heading: EditModeWording.name(chip.kind), width: 300)
        var current: CueAttribute?
        if case .same(let attribute?) = chip.value { current = attribute }
        var value: NSPopUpButton?
        var gain: ShowField?
        var duration: ShowField?
        switch chip.kind {
        case .transition:
            // "a transition whose type applies to pixels": v1's transitions are cut, dissolve and fade through a color.
            let items = (catalog?.transitions ?? []).sorted { $0.number < $1.number }.map { (number: $0.number, label: $0.label) }
            value = numbers(items, selected: current?.ref ?? items.first?.number)
        case .audioTransition:
            let items = (catalog?.audioTransitions ?? []).sorted { $0.number < $1.number }.map { (number: $0.number, label: $0.label) }
            value = numbers(items, selected: current?.ref ?? items.first?.number)
        case .grade:
            let popup = numbers((catalog?.grades ?? []).sorted { $0.number < $1.number }.map { (number: $0.number, label: $0.label) }, selected: nil)
            // "None or a grade".
            popup.insertItem(withTitle: Strings.text(.editChipFormNone), at: 0)
            popup.item(at: 0)?.tag = 0
            popup.selectItem(withTag: current?.ref ?? 0)
            value = popup
        case .gain:
            gain = panel.text(Strings.text(.editChipFormGain), current?.db.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? "0")
        }
        if let value {
            panel.addRow(Strings.text(.editChipFormValue), value)
            duration = panel.text(Strings.text(.editChipFormDuration), SecondsText.text(ms: current?.ms), placeholder: Strings.text(.editChipFormOwn))
        }
        // "with Clear or Hold it is a standalone attribute command, which is always `track`, so its popover offers no scope."
        var scope: NSPopUpButton?
        if chip.offersScope {
            let popup = choices([EditModeWording.scope(.once), EditModeWording.scope(.track)], selected: chip.scope == .once ? 0 : 1)
            panel.addRow(Strings.text(.editChipFormScope), popup)
            scope = popup
        }
        if current != nil || chip.value == .mixed {
            let remove = FlatButton(Strings.text(.editChipFormRemove), style: .plain)
            remove.onPress = { [weak model, weak panel] in
                model?.editing.removeChip(chip.kind)
                panel?.onClose?()
            }
            panel.addRow(" ", remove)
        }
        panel.onSave = { [weak model] in
            let picked: Scope = scope.map { $0.indexOfSelectedItem == 0 ? .once : .track } ?? .track
            var attribute = CueAttribute(kind: chip.kind, scope: picked, isRider: chip.offersScope)
            if let gain {
                let typed = gain.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
                guard let db = Double(typed), db >= -60, db <= 60 else { return .invalid(Strings.text(.editChipFormRange)) }
                attribute.db = db
            }
            if let value { attribute.ref = value.selectedTag() }
            if let duration {
                let typed = duration.stringValue.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty {
                    guard let ms = SecondsText.ms(typed) else { return .invalid(Strings.text(.editFormNumber)) }
                    attribute.ms = ms
                }
            }
            model?.editing.setChip(attribute)
            return nil
        }
        panel.finish()
        return panel
    }

    // MARK: - The content (Spec 11 §4, "The content popover")

    private static let knownFields = ["title", "reference", "copyright"]

    /// What the popover opens on: the cell's write, or for a held or cleared
    /// cell "the kind the channel's `usualContent` names, with a switch to the other".
    static func draft(model: ShowModel) -> ContentDraft? {
        let editing = model.editing
        guard let cue = editing.selectedCues.first, let channel = editing.channel else { return nil }
        let says = CueSays.about(channel, in: cue)
        switch says.state {
        case .write(.text(let fields), _):
            var ordered = [(name: "body", value: fields["body"] ?? "")]
            for name in knownFields where fields[name] != nil { ordered.append((name, fields[name] ?? "")) }
            for name in fields.keys.sorted() where name != "body" && !knownFields.contains(name) { ordered.append((name, fields[name] ?? "")) }
            return ContentDraft(kind: .text, fields: ordered, media: nil)
        case .write(.media(let media), _):
            return ContentDraft(kind: .media, fields: [("body", "")], media: media)
        default:
            let usual = model.store.catalog?.channels.first { $0.number == channel }?.usualContent
            return ContentDraft(kind: usual == .text ? .text : .media, fields: [("body", "")], media: nil)
        }
    }

    /// The content popover. `represent` shows the panel again after a
    /// change to what it holds: the other kind, or another field.
    static func content(model: ShowModel, machineRoot: URL?, draft given: ContentDraft? = nil, represent: (@MainActor (PromptView) -> Void)? = nil) -> PromptView {
        let editing = model.editing
        let channel = editing.channel ?? 0
        let number = editing.selection.first(in: editing.grid.headers.map(\.uuid)).flatMap { editing.grid.cue(of: $0) }.map { $0 + 1 } ?? 0
        let panel = PromptView(heading: Strings.text(.editContentFormHeading, number, channel, model.channelLabel(channel)), width: 440)
        guard let draft = given ?? self.draft(model: model) else {
            panel.finish()
            return panel
        }
        func again() {
            represent?(content(model: model, machineRoot: machineRoot, draft: draft, represent: represent))
        }
        let kinds = SegmentedView([Strings.text(.editContentFormText), Strings.text(.editContentFormMedia)])
        kinds.fills = true
        kinds.selected = draft.kind == .text ? 0 : 1
        panel.addRow("", kinds, height: 28)

        switch draft.kind {
        case .text:
            // "the body in a multi-line field with the cursor at its end (Return commits and closes the popover,
            // ⇧Return makes a line, Escape discards)".
            let body = CommandsTextView()
            body.returnCommits = true
            body.font = .systemFont(ofSize: 12.5)
            body.string = draft.fields.first?.value ?? ""
            body.setAccessibilityLabel(Strings.text(.editContentFormBody))
            panel.focus = body
            body.onCommit = { [weak panel] in panel?.commit() }
            body.onDiscard = { [weak panel] in panel?.onClose?() }
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.backgroundColor = Palette.well
            scroll.documentView = body
            panel.addRow(Strings.text(.editContentFormBody), scroll, height: 92)
            // "and a field for each other field the write has".
            var others: [(name: String, field: ShowField)] = []
            for field in draft.fields.dropFirst() {
                others.append((field.name, panel.text(field.name.prefix(1).uppercased() + field.name.dropFirst(), field.value)))
            }
            func keep() {
                draft.fields[0].value = body.string
                for (index, other) in others.enumerated() where index + 1 < draft.fields.count { draft.fields[index + 1].value = other.field.stringValue }
            }
            // "with Add Field for `title`, `reference`, `copyright` or a custom name, and a Variables ▸ menu".
            let addField = FlatButton(Strings.text(.editContentFormAddField), style: .plain)
            addField.fontSize = 12
            let fieldMenu = NSMenu()
            for name in knownFields where !draft.fields.contains(where: { $0.name == name }) {
                fieldMenu.addItem(ClosureMenuItem(title: name.prefix(1).uppercased() + name.dropFirst()) {
                    keep()
                    draft.fields.append((name, ""))
                    again()
                })
            }
            fieldMenu.addItem(ClosureMenuItem(title: Strings.text(.editContentFormCustom)) {
                keep()
                let asking = PromptView(heading: Strings.text(.editContentFormFieldName), width: 280)
                let name = asking.text(Strings.text(.editContentFormFieldName), "")
                asking.onSave = {
                    let typed = name.stringValue.trimmingCharacters(in: .whitespaces)
                    if !typed.isEmpty, !draft.fields.contains(where: { $0.name == typed }) { draft.fields.append((typed, "")) }
                    // The content popover comes back once this small one has closed.
                    DispatchQueue.main.async { again() }
                    return nil
                }
                asking.finish()
                represent?(asking)
            })
            addField.dropMenu = fieldMenu
            panel.addRow(" ", addField)
            panel.addRow(" ", variablesMenu(catalog: model.store.catalog) { [weak body] name in body?.insertText(name, replacementRange: body?.selectedRange() ?? NSRange(location: 0, length: 0)) })
            kinds.onSelect = { index in
                guard index == 1 else { return }
                keep()
                draft.kind = .media
                again()
            }
            panel.onSave = { [weak model] in
                keep()
                var fields: [String: String] = ["body": draft.fields[0].value]
                // An emptied field other than the body leaves the write.
                for field in draft.fields.dropFirst() where !field.value.isEmpty { fields[field.name] = field.value }
                model?.editing.write(.text(fields: fields))
                return nil
            }
        case .media:
            // "For media, the pool's search and tiles to pick from, and for the chosen item its trim (in and out) and loop".
            let name = Kit.content(Kit.label(size: 12))
            func named(_ id: String?) -> String {
                id.flatMap { id in model.store.media.first { $0.id == id } }.map { MediaPool.name(of: $0.entry) } ?? Strings.text(.editContentFormPick)
            }
            name.stringValue = named(draft.media?.ref)
            let picker = MediaPickerView(model: model, machineRoot: machineRoot, selected: draft.media?.ref)
            picker.onPick = { [weak name] id in
                guard let id else { return }
                // Another item starts without the last one's trim.
                if draft.media?.ref != id { draft.media = MediaContent(ref: id) }
                name?.stringValue = named(id)
            }
            panel.addRow("", picker, height: 260)
            panel.addRow(Strings.text(.editContentFormItem), name)
            let inField = panel.text(Strings.text(.editContentFormIn), SecondsText.text(ms: draft.media?.inMs))
            let outField = panel.text(Strings.text(.editContentFormOut), SecondsText.text(ms: draft.media?.outMs))
            let loop = NSButton(checkboxWithTitle: Strings.text(.editContentFormLoop), target: nil, action: nil)
            loop.font = .systemFont(ofSize: 12)
            loop.state = draft.media?.loop == true ? .on : .off
            panel.addRow(" ", loop)
            kinds.onSelect = { index in
                guard index == 0 else { return }
                draft.kind = .text
                again()
            }
            panel.onSave = { [weak model] in
                guard var media = draft.media else { return .invalid(Strings.text(.editContentFormPick)) }
                for (field, set) in [(inField, { (ms: Int?) in media.inMs = ms }), (outField, { (ms: Int?) in media.outMs = ms })] {
                    let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
                    if typed.isEmpty { set(nil) } else if let ms = SecondsText.ms(typed) { set(ms) } else { return .invalid(Strings.text(.editFormNumber)) }
                }
                // "Loop only turns looping on, since a write can't refuse an item's own loop".
                media = CueEdits.loop(loop.state == .on, on: media)
                model?.editing.pick(media)
                return nil
            }
        }
        panel.finish()
        return panel
    }
}
