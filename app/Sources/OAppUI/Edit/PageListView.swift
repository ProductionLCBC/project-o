// OAppUI — Spec 11 §2, "Where a page's parts sit": the Stacks, Channels and Presets pages' own list, in the Browser's
// place, each with a + row at its foot and a ⋯ menu on each row (G-30 to G-33).

import AppKit
import OApp
import OCore

/// A scroll view's document laid out from its top.
@MainActor
final class ListDocument: NSView {
    override var isFlipped: Bool { true }
}

/// One row of a page's list: its number, its label, a word about it, the live dot, and its ⋯ menu.
@MainActor
final class PageListRowView: NSView {
    static let height: CGFloat = 40
    let number = Kit.label(size: 11.5, color: Palette.faintText, mono: true)
    let name = Kit.content(Kit.label(size: 12.5, weight: .medium))
    let detail = Kit.content(Kit.label(size: 11, color: Palette.dimText))
    let more = FlatButton("⋯", style: .bare)
    var isSelected = false { didSet { needsDisplay = true } }
    var isLive = false { didSet { needsDisplay = true } }
    var onSelect: (() -> Void)?
    /// A click gives the list the keys.
    var onFocus: (() -> Void)?
    /// A row that drags to a new place says where the pointer is, and when it lets go.
    var onDrag: ((NSPoint, Bool) -> Void)?
    private var dragging = false
    private(set) var key = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        more.chevron = false
        more.fontSize = 13
        more.setAccessibilityLabel(Strings.text(.editListRowMenu))
        for view in [number, name, detail, more] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ entry: PageListView.Entry) {
        key = entry.key
        number.stringValue = entry.number
        name.stringValue = entry.name
        detail.stringValue = entry.detail
        isSelected = entry.isSelected
        isLive = entry.isLive
        more.dropMenu = entry.menu
        more.isHidden = entry.menu == nil
        setAccessibilityLabel([entry.number, entry.name, entry.detail].filter { !$0.isEmpty }.joined(separator: " "))
        setAccessibilitySelected(entry.isSelected)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let numberWidth: CGFloat = number.stringValue.isEmpty ? 0 : 26
        number.frame = NSRect(x: 12, y: (h - 16) / 2, width: numberWidth, height: 16)
        // The name, and the word about it under it, so neither is cut short.
        let right = bounds.width - (more.isHidden ? 8 : 34)
        more.frame = NSRect(x: bounds.width - 32, y: (h - 24) / 2, width: 26, height: 24)
        let nameX = 12 + numberWidth + (numberWidth > 0 ? 4 : 0) + (isLive ? 12 : 0)
        let twoLines = !detail.stringValue.isEmpty
        name.frame = NSRect(x: nameX, y: twoLines ? 4 : (h - 17) / 2, width: max(0, right - nameX), height: 17)
        detail.frame = NSRect(x: nameX, y: 22, width: max(0, right - nameX), height: 14)
        detail.isHidden = !twoLines
        number.frame.origin.y = twoLines ? 4 : (h - 16) / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Palette.selection.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if isLive {
            // "the live dot on what is on air".
            Palette.live.setFill()
            let x: CGFloat = 12 + (number.stringValue.isEmpty ? 0 : 30)
            NSBezierPath(ovalIn: NSRect(x: x, y: (detail.isHidden ? bounds.midY : 12.5) - 3.5, width: 7, height: 7)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        onFocus?()
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let onDrag else { return }
        dragging = true
        onDrag(event.locationInWindow, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging, let onDrag else { return }
        dragging = false
        onDrag(event.locationInWindow, true)
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}

/// Spec 11 §2 and G-30 to G-33 — the page's own list, "the page's objects by number and label, the selected one
/// highlighted and the live dot on what is on air, with a + row at the list's foot that adds one, and on each row a
/// ⋯ menu". The Presets page shows two: the presets, then the boxes of the layout shown.
@MainActor
final class PageListView: PanelView, EditFocus {
    /// What a row shows and does.
    struct Entry {
        var key: Int
        var number: String
        var name: String
        var detail = ""
        var isSelected = false
        var isLive = false
        var select: () -> Void
        var menu: NSMenu?
    }

    /// One list: a heading, its rows, its + row and, for boxes, a drag to a new place.
    struct Section {
        var heading: String?
        var entries: [Entry]
        var add: String
        /// The + row's action, or the menu of its choices.
        var onAdd: (() -> Void)?
        var addMenu: NSMenu?
        var canAdd = true
        /// Spec 11 §9 — "but for Transitions, a + that creates one".
        var showsAdd = true
        var empty: String?
        /// A row dropped above the row at a place (0 = the top): its key and the place.
        var move: ((Int, Int) -> Void)?
    }

    /// The views of one list.
    @MainActor
    final class SectionViews {
        let heading = Kit.heading("")
        var rows: [PageListRowView] = []
        let add = FlatButton("", style: .bare)
        let empty = Kit.label(size: 11.5, color: Palette.faintText)
        var dropRow: Int?
        var move: ((Int, Int) -> Void)?
    }

    private let model: ShowModel
    private let scroll = NSScrollView()
    private let document = ListDocument()
    private(set) var sections: [SectionViews] = []
    /// Where a dragged row would land: its list and its place.
    private let dropLine = NSView()
    /// The window, which opens the panels a row's menu asks for.
    weak var host: ShowWindowView?

    init(model: ShowModel) {
        self.model = model
        super.init(title: "")
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
        dropLine.wantsLayer = true
        dropLine.layer?.backgroundColor = Palette.selection.cgColor
        dropLine.isHidden = true
        document.addSubview(dropLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: - Keys (Spec 11 §10, "Keyboard")

    override var acceptsFirstResponder: Bool { true }

    /// The list the arrows walk: the one whose row was clicked last, else the first with a row selected. The Objects
    /// page's groups are one list.
    private var keyList = 0

    /// "the cue grid, lists and canvases with the arrows (§2)": ↑ and ↓ select the row before or after; ⌃Return opens
    /// the selected row's menu (Spec 10 §15).
    override func keyDown(with event: NSEvent) {
        let rows: [PageListRowView]
        if model.editing.page == .objects {
            rows = sections.flatMap(\.rows)
        } else {
            let index = sections.indices.contains(keyList) && sections[keyList].rows.contains(where: \.isSelected) ? keyList
                : sections.firstIndex { $0.rows.contains(where: \.isSelected) } ?? 0
            rows = sections.indices.contains(index) ? sections[index].rows : []
        }
        let at = rows.firstIndex(where: \.isSelected)
        switch event.keyCode {
        case 126, 125:
            let step = event.keyCode == 126 ? -1 : 1
            let target = at.map { $0 + step } ?? (step > 0 ? 0 : rows.count - 1)
            guard rows.indices.contains(target) else { return }
            rows[target].onSelect?()
            rows[target].scrollToVisible(rows[target].bounds)
        case 36, 76:
            guard event.modifierFlags.contains(.control) else { return super.keyDown(with: event) }
            guard let at, let menu = rows[at].more.dropMenu else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: rows[at].more.bounds.height + 2), in: rows[at].more)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - What each page lists

    func refresh() {
        let editing = model.editing
        title.stringValue = EditModeWording.page(editing.page)
        title.isHidden = false
        switch editing.page {
        case .stacks: show([stacks()])
        case .channels: show([channels()])
        case .presets: show(presets())
        case .objects: show(objects())
        default: show([])
        }
    }

    private func menu(_ items: [(String, Bool, () -> Void)]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, enabled, act) in items {
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = ClosureMenuItem(title: title) { act() }
            item.isEnabled = enabled
            menu.addItem(item)
        }
        return menu
    }

    /// G-30 — "the stacks, with New Stack as its + row".
    private func stacks() -> Section {
        let editing = model.editing
        let page = editing.stackPage
        let entries = page.stacks.map { stack -> Entry in
            let showing = page.outputs.filter { $0.liveStack == stack.number }.map(\.number)
            let select: () -> Void = { [weak model] in model?.editing.selectStack(stack.number) }
            return Entry(key: stack.number, number: String(stack.number), name: stack.label.isEmpty ? Strings.text(.editStackUntitled, stack.number) : stack.label,
                         detail: showing.isEmpty ? "" : Strings.text(.editListOnOutputs, showing.map(String.init).joined(separator: ", ")),
                         isSelected: stack.number == page.stack?.number, isLive: !showing.isEmpty, select: select,
                         menu: menu([
                            (Strings.text(.menuDuplicate), true, { [weak model] in
                                select()
                                model?.editing.duplicateStack()
                            }),
                            (Strings.text(.editCuesRenumber), true, { [weak self] in
                                select()
                                self?.askNumber(stack.number) { self?.model.editing.renumberStack(to: $0) }
                            }),
                            ("", true, {}),
                            // "Delete, refused while an output shows the stack".
                            (Strings.text(.menuDelete), showing.isEmpty, { [weak model] in
                                select()
                                model?.editing.deleteStack()
                            }),
                         ]))
        }
        return Section(heading: nil, entries: entries, add: Strings.text(.editStackNew), onAdd: { [weak model] in model?.editing.newStack() },
                       empty: Strings.text(.editStackNone))
    }

    /// G-31 — "the channels, with New Channel as its + row".
    private func channels() -> Section {
        let editing = model.editing
        let page = editing.channelPage
        let content = Set(model.store.channels.values.filter { $0.content != nil }.map(\.number))
        let entries = page.rows.map { row -> Entry in
            let select: () -> Void = { [weak model] in model?.editing.selectChannel(row.number) }
            let onAir = model.store.catalog.map { ChannelPage.isOnAir(channel: row.number, catalog: $0, dots: model.outputDots, content: content) } ?? false
            var words = [ChannelWorkspaceView.usualTitle(row.usualContent)]
            if !row.stacks.isEmpty { words.append(Strings.text(.editListInStacks, row.stacks.map(String.init).joined(separator: ", "))) }
            return Entry(key: row.number, number: String(row.number), name: row.label.isEmpty ? Strings.text(.editChannelUntitled, row.number) : row.label,
                         detail: words.joined(separator: " · "), isSelected: row.number == page.channel?.number, isLive: onAir, select: select,
                         menu: menu([
                            (Strings.text(.menuDuplicate), true, { [weak model] in
                                select()
                                model?.editing.duplicateChannel()
                            }),
                            ("", true, {}),
                            // "A channel with content on an output's stack ... can't be deleted".
                            (Strings.text(.menuDelete), !onAir, { [weak model] in
                                select()
                                model?.editing.deleteChannel()
                            }),
                         ]))
        }
        return Section(heading: nil, entries: entries, add: Strings.text(.editChannelNew), onAdd: { [weak model] in model?.editing.newChannel() },
                       empty: Strings.text(.editChannelNone))
    }

    /// G-32 — "the presets, with New Preset as its + row, and under them the boxes, with Add Box as theirs".
    private func presets() -> [Section] {
        let editing = model.editing
        let page = editing.presetPage
        let entries = page.presets.map { preset -> Entry in
            let select: () -> Void = { [weak model] in model?.editing.selectPreset(preset.number) }
            let builtIn = preset.number == 1
            let layouts = preset.layouts.keys.sorted().map(\.string).joined(separator: ", ")
            return Entry(key: preset.number, number: String(preset.number), name: preset.label.isEmpty ? Strings.text(.editPresetUntitled, preset.number) : preset.label,
                         detail: Strings.text(.editListLayouts, layouts), isSelected: preset.number == page.preset?.number, select: select,
                         menu: menu([
                            (Strings.text(.menuDuplicate), true, { [weak model] in
                                select()
                                model?.editing.duplicatePreset()
                            }),
                            // "Preset 1 can be edited but not deleted, renumbered or swapped".
                            (Strings.text(.editCuesRenumber), !builtIn, { [weak self] in
                                select()
                                self?.askNumber(preset.number) { self?.model.editing.renumberPreset(to: $0) }
                            }),
                            ("", true, {}),
                            (Strings.text(.menuDelete), !builtIn, { [weak model] in
                                select()
                                model?.editing.deletePreset()
                            }),
                         ]))
        }
        let list = Section(heading: Strings.text(.editPresetList), entries: entries, add: Strings.text(.editPresetNew),
                           onAdd: { [weak model] in model?.editing.newPreset() }, empty: Strings.text(.editPresetNone))
        // The boxes, top first, of the layout the tab shows.
        let count = page.layout?.boxes.count ?? 0
        let boxes = page.boxes.map { box -> Entry in
            var words = LayoutCanvasView.tag(of: box.binding)
            if case .static(let text) = box.binding, !text.isEmpty { words += " · " + text }
            let index = box.index
            return Entry(key: index, number: "", name: words, detail: box.offset == 0 ? "" : (box.offset > 0 ? "+\(box.offset)" : "\(box.offset)"),
                         isSelected: page.ownsLayout && index == editing.presetState.box,
                         select: { [weak model] in model?.editing.selectBox(index) },
                         menu: page.ownsLayout ? menu([
                            (Strings.text(.editMenuMoveUp), index < count - 1, { [weak model] in model?.editing.moveBox(index, up: true) }),
                            (Strings.text(.editMenuMoveDown), index > 0, { [weak model] in model?.editing.moveBox(index, up: false) }),
                            (Strings.text(.menuDuplicate), true, { [weak model] in model?.editing.duplicateBox(index) }),
                            ("", true, {}),
                            (Strings.text(.confirmRemove), true, { [weak model] in model?.editing.removeBox(index) }),
                         ]) : nil)
        }
        let boxSection = Section(heading: Strings.text(.editPresetBoxes), entries: boxes, add: Strings.text(.editPresetAddBox), addMenu: addBoxMenu(),
                                 canAdd: page.ownsLayout && page.preset != nil,
                                 empty: page.ownsLayout ? Strings.text(.editPresetNoBoxes) : Strings.text(.editPresetUsesAny),
                                 move: page.ownsLayout ? { [weak model] index, row in
                                     // Dropped above the row at `row`, top first; `boxes` run bottom to top.
                                     var place = count - max(0, min(row, count))
                                     if index < place { place -= 1 }
                                     model?.editing.moveBox(index, to: min(max(0, place), count - 1))
                                 } : nil)
        return [list, boxSection]
    }

    /// Spec 11 §9 — "a list in groups (Grades, Transitions, Audio transitions, Text styles, Macros), each with its objects
    /// by number and label and, but for Transitions, a + that creates one"; a row's menu has Duplicate, Renumber… and
    /// Delete, which transitions don't have.
    private func objects() -> [Section] {
        let editing = model.editing
        let page = editing.objectsPage
        let catalog = model.store.catalog
        return page.groups.map { group in
            let kind = group.kind
            let entries = group.rows.map { row -> Entry in
                let key = row.key
                let select: () -> Void = { [weak model] in model?.editing.selectObject(key) }
                let name = row.label.isEmpty ? EditModeWording.objectName(kind, key.number) : row.label
                // A detail that says only the name again ("Cut" under "Cut") is left out.
                let detail = catalog.map { Self.detail(key, catalog: $0) } ?? ""
                return Entry(key: key.number, number: String(key.number), name: name, detail: detail == name ? "" : detail,
                             isSelected: key == page.selected, select: select,
                             menu: kind.isFixed ? nil : menu([
                                (Strings.text(.menuDuplicate), true, { [weak model] in
                                    select()
                                    model?.editing.duplicateObject()
                                }),
                                (Strings.text(.editCuesRenumber), true, { [weak self] in
                                    select()
                                    self?.askNumber(key.number) { self?.model.editing.renumberObject(to: $0) }
                                }),
                                ("", true, {}),
                                (Strings.text(.menuDelete), true, { [weak model] in
                                    select()
                                    model?.editing.deleteObject()
                                }),
                             ]))
            }
            return Section(heading: EditModeWording.group(kind), entries: entries, add: EditModeWording.newObject(kind),
                           onAdd: kind.isFixed ? nil : { [weak model] in model?.editing.newObject(kind) }, showsAdd: !kind.isFixed,
                           empty: Strings.text(.editObjectNoneYet))
        }
    }

    /// What a row says under its name: a transition's type and duration, a style's font and size, a macro's commands.
    static func detail(_ key: ObjectKey, catalog: Catalog) -> String {
        func seconds(_ ms: Int) -> String { SecondsText.text(ms: ms) + " s" }
        switch key.kind {
        case .grade:
            return ""
        case .transition:
            guard let t = catalog.transitions.first(where: { $0.number == key.number }) else { return "" }
            return t.type == .cut ? EditModeWording.transitionType(t.type) : "\(EditModeWording.transitionType(t.type)) · \(seconds(t.ms))"
        case .audioTransition:
            guard let t = catalog.audioTransitions.first(where: { $0.number == key.number }) else { return "" }
            return t.type == .cut ? EditModeWording.audioTransitionType(t.type) : "\(EditModeWording.audioTransitionType(t.type)) · \(seconds(t.ms))"
        case .textStyle:
            guard let style = catalog.textStyles.first(where: { $0.number == key.number }) else { return "" }
            let size = FormNumber.text(style.values.size.value) + (style.values.size.unit == .percent ? "%" : " pt")
            return "\(style.values.font) · \(size)"
        case .macro:
            guard let macro = catalog.macros.first(where: { $0.number == key.number }) else { return "" }
            return Strings.counted(.editObjectCommandCount, macro.commands.count)
        }
    }

    /// "Add Box ▸ Pixels, Field ▸ (body, title, copyright, reference, or a custom name) or Static Text".
    private func addBoxMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: Strings.text(.editPresetAddPixels)) { [weak model] in model?.editing.addBox(.pixels) })
        let fields = NSMenuItem(title: Strings.text(.editPresetAddField), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for name in PresetInspectorView.fieldNames {
            sub.addItem(ClosureMenuItem(title: name) { [weak model] in model?.editing.addBox(.field(name: name)) })
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem(title: Strings.text(.editPresetFieldCustom)) { [weak self] in self?.askFieldName() })
        fields.submenu = sub
        menu.addItem(fields)
        menu.addItem(ClosureMenuItem(title: Strings.text(.editPresetAddStatic)) { [weak model] in model?.editing.addBox(.static(text: "")) })
        return menu
    }

    // MARK: - The panels a row asks for

    /// "Renumber…, with swap for a taken number": a small panel with the number.
    private func askNumber(_ current: Int, _ renumber: @escaping (Int) -> Void) {
        let panel = PromptView(heading: Strings.text(.editCuesRenumber), width: 240)
        let field = panel.text(Strings.text(.editCuesRenumber), String(current), placeholder: String(current))
        panel.onSave = {
            guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            renumber(number)
            return nil
        }
        panel.finish()
        let anchor = sections.flatMap(\.rows).first { $0.isSelected } ?? self
        host?.present(panel, at: anchor)
    }

    /// "Field ▸ (... or a custom name)": the name is asked for.
    private func askFieldName() {
        let panel = PromptView(heading: Strings.text(.editPresetAddField), width: 260)
        let field = panel.text(Strings.text(.editPresetFieldName), "", placeholder: "author")
        panel.onSave = { [weak model] in
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            model?.editing.addBox(.field(name: name))
            return nil
        }
        panel.finish()
        host?.present(panel, at: sections.last?.add ?? self)
    }

    // MARK: - Showing the lists

    private func show(_ lists: [Section]) {
        while sections.count < lists.count {
            let views = SectionViews()
            views.add.leading = true
            views.add.fontSize = 12.5
            for view in [views.heading, views.add, views.empty] as [NSView] { document.addSubview(view) }
            sections.append(views)
        }
        while sections.count > lists.count {
            let views = sections.removeLast()
            for view in [views.heading, views.add, views.empty] + views.rows as [NSView] { view.removeFromSuperview() }
        }
        for (index, (views, list)) in zip(sections, lists).enumerated() {
            if let heading = list.heading { Kit.setHeading(views.heading, heading) }
            views.heading.isHidden = list.heading == nil
            while views.rows.count < list.entries.count {
                let row = PageListRowView()
                document.addSubview(row)
                views.rows.append(row)
            }
            while views.rows.count > list.entries.count { views.rows.removeLast().removeFromSuperview() }
            views.move = list.move
            for (row, entry) in zip(views.rows, list.entries) {
                row.show(entry)
                row.onSelect = entry.select
                row.onFocus = { [weak self] in
                    guard let self else { return }
                    self.keyList = index
                    self.window?.makeFirstResponder(self)
                }
                row.onDrag = list.move == nil ? nil : { [weak self, weak row] point, ended in
                    guard let self, let row else { return }
                    self.drag(row.key, in: index, to: self.document.convert(point, from: nil), ended: ended)
                }
            }
            // "a + row at the list's foot that adds one".
            views.add.title = "+  " + list.add
            views.add.setAccessibilityLabel(list.add)
            views.add.onPress = list.onAdd
            views.add.dropMenu = list.addMenu
            views.add.chevron = false
            views.add.isEnabled = list.canAdd
            views.add.isHidden = !list.showsAdd
            views.empty.stringValue = list.entries.isEmpty ? (list.empty ?? "") : ""
            views.empty.isHidden = views.empty.stringValue.isEmpty
        }
        needsLayout = true
    }

    /// A row dragged within its list: the line shows where it would land; letting go moves it there.
    private func drag(_ key: Int, in section: Int, to point: NSPoint, ended: Bool) {
        guard sections.indices.contains(section), let first = sections[section].rows.first else { return }
        let views = sections[section]
        let place = min(views.rows.count, max(0, Int(((point.y - first.frame.minY) / PageListRowView.height).rounded())))
        if ended {
            dropLine.isHidden = true
            views.dropRow = nil
            views.move?(key, place)
            return
        }
        views.dropRow = place
        dropLine.frame = NSRect(x: 8, y: first.frame.minY + CGFloat(place) * PageListRowView.height - 1, width: document.bounds.width - 16, height: 2)
        dropLine.isHidden = false
    }

    /// Drops a row as a drag would, for the keyboard and the tests.
    func drop(_ key: Int, inList section: Int, atRow row: Int) {
        guard sections.indices.contains(section) else { return }
        sections[section].move?(key, row)
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        scroll.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
        let width = scroll.contentSize.width
        var y: CGFloat = 6
        for views in sections {
            if !views.heading.isHidden {
                y += 8
                views.heading.frame = NSRect(x: 14, y: y, width: width - 28, height: 14)
                y += 20
            }
            for row in views.rows {
                row.frame = NSRect(x: 0, y: y, width: width, height: PageListRowView.height)
                y += PageListRowView.height
            }
            if !views.empty.isHidden {
                views.empty.frame = NSRect(x: 14, y: y + 4, width: width - 28, height: 16)
                y += 24
            }
            if views.add.isHidden {
                y += 4
                continue
            }
            views.add.frame = NSRect(x: 4, y: y + 2, width: width - 8, height: 28)
            y += 36
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }
}
