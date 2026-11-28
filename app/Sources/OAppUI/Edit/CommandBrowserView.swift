// OAppUI — Spec 11 §4 as corrected 2026-11-25 (G-37): the palette as a command browser, a search field over a tree of
// the commands, the picked command's small form beside it with its canonical text, and a line for any command typed.

import AppKit
import OApp
import OCore

/// One row of the browser's tree: a group, or a command.
@MainActor
final class BrowserNode: NSObject {
    let title: String
    let leaf: CommandLeaf?
    var children: [BrowserNode]

    init(title: String, leaf: CommandLeaf?, children: [BrowserNode] = []) {
        self.title = title
        self.leaf = leaf
        self.children = children
    }
}

/// Spec 11 §4 — "Add Command opens a search field over a tree of the commands ... Picking one shows its small form with
/// pickers beside the tree and its canonical text under the form as it is filled".
@MainActor
final class CommandBrowserView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate {
    private let model: ShowModel
    private let all: [CommandBranch]
    /// Where the pool's tiles are, for a media field.
    var machineRoot: URL?
    private(set) var nodes: [BrowserNode] = []
    let search = NSSearchField()
    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    let formTitle = Kit.label(size: 12.5, weight: .semibold)
    let pick = Kit.label(Strings.text(.editBrowserPick), size: 12, color: Palette.faintText)
    /// The picked command's canonical text (Spec 2 §4), as the form is filled.
    let preview = Kit.content(Kit.label(size: 11.5, color: Palette.dimText, mono: true))
    private(set) var names: [NSTextField] = []
    /// One per field, in the fields' order.
    private(set) var controls: [NSView] = []
    /// What the form lays out, a name and its control a row: the fields, and a popup text's Variables ▸ under it.
    private var rows: [(NSTextField, NSView)] = []
    private var fields: [CommandField] = []
    private var choices: [String: [CommandValue]] = [:]
    private(set) var leaf: CommandLeaf?
    /// Something changed: the panel says whether Add would work.
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }

    /// The tree for a cue's commands, or for macro `macro`'s (§9).
    init(model: ShowModel, macro: Int?) {
        self.model = model
        all = model.store.catalog.map { CommandCatalog.groups(catalog: $0, macro: macro) } ?? []
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 320))
        search.placeholderString = Strings.text(.editBrowserSearch)
        search.setAccessibilityLabel(Strings.text(.editBrowserSearch))
        search.delegate = self
        search.sendsSearchStringImmediately = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 20
        outline.dataSource = self
        outline.delegate = self
        outline.backgroundColor = Palette.well
        outline.setAccessibilityLabel(Strings.text(.editBrowserHeading))
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        preview.maximumNumberOfLines = 2
        for view in [search, scroll, formTitle, pick, preview] as [NSView] { addSubview(view) }
        show(all)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func show(_ groups: [CommandBranch]) {
        nodes = groups.map { group in
            BrowserNode(title: group.title, leaf: nil, children: group.leaves.map { BrowserNode(title: $0.title, leaf: $0) })
        }
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    // MARK: - The search

    func controlTextDidChange(_ notification: Notification) {
        if (notification.object as? NSSearchField) === search {
            filter(search.stringValue)
        } else {
            refreshPreview()
        }
    }

    /// "a search field over a tree".
    func filter(_ query: String) {
        show(CommandCatalog.filter(all, query))
    }

    // MARK: - The tree

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? BrowserNode)?.children.count ?? nodes.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? BrowserNode)?.children[index] ?? nodes[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BrowserNode)?.leaf == nil
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? BrowserNode else { return nil }
        let isGroup = node.leaf == nil
        var text = node.title
        if let refused = node.leaf?.refused { text += "  " + refused }
        let label = Kit.label(text, size: isGroup ? 11.5 : 12, weight: isGroup ? .semibold : .regular,
                              color: isGroup ? Palette.dimText : (node.leaf?.refused == nil ? Palette.text : Palette.faintText))
        label.setAccessibilityLabel(text)
        return label
    }

    /// "Recursive and not offered": a refused command can't be picked.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let leaf = (item as? BrowserNode)?.leaf else { return false }
        return leaf.refused == nil
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        choose((outline.item(atRow: outline.selectedRow) as? BrowserNode)?.leaf)
    }

    /// Picks a command by its title, as a click in the tree does.
    @discardableResult
    func select(_ title: String) -> Bool {
        for group in nodes {
            for node in group.children where node.title == title {
                let row = outline.row(forItem: node)
                guard row >= 0, node.leaf?.refused == nil else { return false }
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                choose(node.leaf)
                return true
            }
        }
        return false
    }

    // MARK: - The form

    private func choose(_ leaf: CommandLeaf?) {
        guard leaf != self.leaf else { return }
        self.leaf = leaf
        for (name, control) in rows {
            name.removeFromSuperview()
            control.removeFromSuperview()
        }
        names = []
        controls = []
        rows = []
        choices = [:]
        fields = leaf?.fields ?? []
        let catalog = model.store.catalog ?? Catalog()
        for field in fields {
            let name = Kit.label(Strings.text(field.label), size: 11.5, color: Palette.dimText)
            let control: NSView
            func popup(_ items: [(CommandValue, String)]) -> NSPopUpButton {
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.font = .systemFont(ofSize: 12)
                popup.addItems(withTitles: items.map(\.1))
                popup.target = self
                popup.action = #selector(changed)
                choices[field.id] = items.map(\.0)
                return popup
            }
            switch field.kind {
            case .pick(.media):
                // "it opens the media chooser" (G-42): here, inside the browser's form.
                let picker = MediaPickerView(model: model, machineRoot: machineRoot, selected: nil)
                picker.onPick = { [weak self] _ in self?.refreshPreview() }
                control = picker
            case .pick(let pick):
                control = popup(CommandCatalog.choices(pick, catalog: catalog, media: model.store.media).map { ($0.value, $0.title) })
            case .state:
                control = popup([(.text("on"), Strings.text(.editFormOn)), (.text("off"), Strings.text(.editFormOff)), (.text("toggle"), Strings.text(.editFormToggle))])
            case .transport:
                control = popup([(.text("play"), Strings.text(.editBrowserPlay)), (.text("pause"), Strings.text(.editBrowserPause)),
                                 (.text("stop"), Strings.text(.editBrowserStop))])
            case .endBehavior:
                control = popup([(.text("loop"), Strings.text(.editBrowserLoop)), (.text("hold"), Strings.text(.editBrowserHold)),
                                 (.text("clear"), Strings.text(.editBrowserClear))])
            case .lock:
                control = popup([(.bool(true), Strings.text(.editBrowserLockOn)), (.bool(false), Strings.text(.editBrowserUnlock))])
            case .flag:
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(changed))
                control = box
            case .number, .text, .seconds, .ms, .decibels:
                let text = NSTextField()
                text.font = .systemFont(ofSize: 12.5)
                text.bezelStyle = .roundedBezel
                text.delegate = self
                if field.kind == .decibels { text.stringValue = "0" }
                if field.kind == .ms { text.placeholderString = Strings.text(.editChipFormOwn) }
                control = text
            }
            control.setAccessibilityLabel(Strings.text(field.label))
            names.append(name)
            controls.append(control)
            rows.append((name, control))
            addSubview(name)
            addSubview(control)
            // "a popup's text has the Variables ▸ menu".
            if leaf?.kind == .popupSet, field.kind == .text, let text = control as? NSTextField {
                let variables = FlatButton(Strings.text(.editPresetVariables), style: .plain)
                variables.fontSize = 11.5
                let menu = NSMenu()
                for word in EditPopovers.variableNames(catalog: catalog) {
                    menu.addItem(ClosureMenuItem(title: word) { [weak self, weak text] in
                        guard let text else { return }
                        text.stringValue += word
                        self?.refreshPreview()
                    })
                }
                variables.dropMenu = menu
                variables.setAccessibilityLabel(Strings.text(.editPresetVariables))
                let blank = Kit.label("", size: 11.5)
                rows.append((blank, variables))
                addSubview(blank)
                addSubview(variables)
            }
        }
        formTitle.stringValue = leaf?.title.replacingOccurrences(of: "…", with: "") ?? ""
        pick.isHidden = leaf != nil
        refreshPreview()
        needsLayout = true
    }

    @objc private func changed() { refreshPreview() }

    /// The form's values, as the command takes them.
    var values: [String: CommandValue] {
        var values: [String: CommandValue] = [:]
        for (field, control) in zip(fields, controls) {
            if let picker = control as? MediaPickerView {
                if let id = picker.selected { values[field.id] = .text(id) }
            } else if let popup = control as? NSPopUpButton, let list = choices[field.id], list.indices.contains(popup.indexOfSelectedItem) {
                values[field.id] = list[popup.indexOfSelectedItem]
            } else if let box = control as? NSButton, field.kind == .flag {
                values[field.id] = .bool(box.state == .on)
            } else if let text = control as? NSTextField {
                let typed = text.stringValue.trimmingCharacters(in: .whitespaces)
                switch field.kind {
                case .number, .ms: if let n = Int(typed) { values[field.id] = .int(n) }
                case .seconds: if let ms = SecondsText.ms(typed) { values[field.id] = .int(ms) }
                case .text: values[field.id] = .text(text.stringValue)
                case .decibels: values[field.id] = .text(typed)
                default: break
                }
            }
        }
        return values
    }

    /// The command the form makes now, or nil while a field it needs is missing.
    var command: Command? {
        guard let leaf, leaf.refused == nil else { return nil }
        return CommandCatalog.build(leaf.kind, values)
    }

    /// Fills a field, as typing in it does, for a test.
    func type(_ text: String, into id: String) {
        guard let index = fields.firstIndex(where: { $0.id == id }), let field = controls[index] as? NSTextField else { return }
        field.stringValue = text
        refreshPreview()
    }

    private func refreshPreview() {
        preview.stringValue = command.flatMap { CommandText.print($0) } ?? ""
        onChange?()
    }

    override func layout() {
        super.layout()
        let treeWidth: CGFloat = min(240, bounds.width * 0.42)
        search.frame = NSRect(x: 0, y: 0, width: treeWidth, height: 24)
        scroll.frame = NSRect(x: 0, y: 30, width: treeWidth, height: max(0, bounds.height - 30))
        outline.tableColumns.first?.width = scroll.contentSize.width - 4
        let x = treeWidth + 16
        let width = max(0, bounds.width - x)
        formTitle.frame = NSRect(x: x, y: 2, width: width, height: 18)
        pick.frame = NSRect(x: x, y: 30, width: width, height: 16)
        let nameWidth = min(width * 0.4, max(80, names.map { Kit.width(of: $0) }.max() ?? 0) + 8)
        var y: CGFloat = 30
        for (name, control) in rows {
            name.frame = NSRect(x: x, y: y + 4, width: nameWidth - 6, height: 16)
            // A media field is the picker, as tall as the form has room for.
            let height: CGFloat = control is MediaPickerView ? max(120, bounds.height - y - 44) : 24
            control.frame = NSRect(x: x + nameWidth, y: y, width: max(0, width - nameWidth), height: height)
            y += height + 8
        }
        preview.frame = NSRect(x: x, y: max(y + 6, bounds.height - 34), width: width, height: 32)
    }
}

/// The browser in its panel: the tree and the form, a line for any command typed, and Add.
@MainActor
enum CommandBrowser {
    /// `insert` puts the command where it goes, a cue's or a macro's.
    static func panel(model: ShowModel, macro: Int?, insert: @escaping @MainActor (Command) -> Void) -> (PromptView, CommandBrowserView) {
        let panel = PromptView(heading: Strings.text(.editBrowserHeading), width: 640)
        panel.save.title = Strings.text(.editFormAdd)
        let browser = CommandBrowserView(model: model, macro: macro)
        panel.addRow("", browser, height: 320)
        // "a line at the browser's foot takes any command typed in canonical text (Spec 2 §4)".
        let typed = panel.text(Strings.text(.editBrowserTyped), "")
        typed.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let options = model.editing.parseOptions
        panel.onSave = {
            let line = typed.stringValue.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                switch CommandText.parse(line, options: options) {
                case .success(let entry):
                    insert(entry.command)
                    return nil
                case .failure(let rejection):
                    return .invalid(Strings.text(.editFormInvalid, rejection.message))
                }
            }
            guard let command = browser.command else { return .invalid(Strings.text(.editBrowserPick)) }
            insert(command)
            return nil
        }
        return (panel, browser)
    }
}
