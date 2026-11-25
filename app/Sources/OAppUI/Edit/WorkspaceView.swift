// OAppUI — Spec 11 §2 and §4, the workspace: the page's editing space; on the Cues page, the cue grid under its header.

import AppKit
import OApp
import OCore

/// Spec 11 §2 — "Workspace: the page's editing space; on the Cues page, the
/// cue grid (§4)". Spec 11 §4, "The list" — "The workspace's header names
/// the list, its cue count and its version, and holds the zoom slider
/// (below), Open in Text Editor (§5) and Renumber…".
@MainActor
final class WorkspaceView: PanelView {
    private let model: ShowModel
    /// "its cue count and its version", then why the list is read-only, or that another shares its number.
    let meta = Kit.content(Kit.label(size: 12))
    let zoom = NSSlider(value: CueGridZoom.standard, minValue: CueGridZoom.range.lowerBound, maxValue: CueGridZoom.range.upperBound, target: nil, action: nil)
    let openText = FlatButton(Strings.text(.editCuesOpenText), style: .plain)
    let renumber = FlatButton(Strings.text(.editCuesRenumber), style: .plain)
    /// What stands in the workspace when there is no grid to show: no list chosen, a page not built yet, a list deleted.
    let message = Kit.label(size: 13)
    /// "A page whose object is deleted under it says "Deleted", with Undo while that delete is the history's top group."
    let undo = FlatButton(Strings.text(.menuUndo), style: .plain)
    let grid: CueGridView
    /// Spec 11 §6 — the Stacks page's workspace (G-30), and its header's picker of the stack and the stack's menu.
    let stacks: StackWorkspaceView
    /// Spec 11 §7 — the Channels page's workspace (G-31).
    let channels: ChannelWorkspaceView
    /// Spec 11 §8 — the Presets page's workspace (G-32).
    let presets: PresetWorkspaceView
    let objectPicker = ChoicePopUp(label: Strings.text(.editStackPicker))
    let objectMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    /// The header's ⋯ menu for each page that has one.
    private var stackMenu_ = NSMenu()
    private var channelMenu_ = NSMenu()
    private var presetMenu_ = NSMenu()
    var machineRoot: URL? {
        didSet {
            grid.machineRoot = machineRoot
            presets.machineRoot = machineRoot
        }
    }
    /// The window, which opens the popovers the page's controls ask for.
    weak var host: ShowWindowView? {
        didSet {
            grid.host = host
            channels.host = host
        }
    }

    init(model: ShowModel) {
        self.model = model
        grid = CueGridView(model: model)
        stacks = StackWorkspaceView(model: model)
        channels = ChannelWorkspaceView(model: model)
        presets = PresetWorkspaceView(model: model)
        super.init(title: "")
        Kit.content(title)
        meta.textColor = Palette.dimText
        zoom.controlSize = .small
        zoom.target = self
        zoom.action = #selector(zoomed)
        zoom.isContinuous = true
        zoom.setAccessibilityLabel(Strings.text(.editCuesZoom))
        zoom.toolTip = Strings.text(.editCuesZoom)
        // "Open in Text Editor ... stays disabled until it lands" (Spec 11 §11).
        openText.isEnabled = false
        openText.reason = Strings.text(.unavailableLater)
        openText.fontSize = 11.5
        renumber.fontSize = 11.5
        renumber.onPress = { [weak self] in self?.askRenumber() }
        message.textColor = Palette.faintText
        message.alignment = .center
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        undo.onPress = { [weak model] in model?.undo() }
        objectPicker.isBordered = false
        // The header's picker is the page's: the stack on the Stacks page, the preset on the Presets page.
        objectPicker.onChoose = { [weak model] number in
            guard let editing = model?.editing else { return }
            if editing.page == .presets { editing.selectPreset(number) } else { editing.selectStack(number) }
        }
        objectMenu.isBordered = false
        stackMenu_ = stackMenu()
        channelMenu_ = channelMenu()
        presetMenu_ = presetMenu()
        objectMenu.menu = stackMenu_
        for view in [meta, zoom, openText, renumber, grid, stacks, channels, presets, objectPicker, objectMenu, message, undo] as [NSView] { addSubview(view) }
        refresh()
    }

    /// Spec 11 §8 — "New Preset (`edit preset create`, with an empty `*` layout), Duplicate (...) and Delete"; and its
    /// number's Renumber, with swap for a taken number.
    private func presetMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "⋯", action: nil, keyEquivalent: ""))
        menu.addItem(ClosureMenuItem(title: Strings.text(.editPresetNew)) { [weak model] in model?.editing.newPreset() })
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDuplicate)) { [weak model] in model?.editing.duplicatePreset() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDelete)) { [weak model] in model?.editing.deletePreset() })
        return menu
    }

    /// Spec 11 §7 — "Its menu: New Channel ...; Duplicate ...; Delete".
    private func channelMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "⋯", action: nil, keyEquivalent: ""))
        menu.addItem(ClosureMenuItem(title: Strings.text(.editChannelNew)) { [weak model] in model?.editing.newChannel() })
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDuplicate)) { [weak model] in model?.editing.duplicateChannel() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDelete)) { [weak model] in model?.editing.deleteChannel() })
        return menu
    }

    /// Spec 11 §6 — "Its menu: New Stack ...; Duplicate ...; Renumber…, with swap for a taken number ...; and Delete".
    private func stackMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "⋯", action: nil, keyEquivalent: ""))
        menu.addItem(ClosureMenuItem(title: Strings.text(.editStackNew)) { [weak model] in model?.editing.newStack() })
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDuplicate)) { [weak model] in model?.editing.duplicateStack() })
        menu.addItem(ClosureMenuItem(title: Strings.text(.editCuesRenumber)) { [weak self] in self?.askStackNumber() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: Strings.text(.menuDelete)) { [weak model] in model?.editing.deleteStack() })
        return menu
    }

    /// "Renumber…, with swap for a taken number": a small panel with the number.
    private func askStackNumber() {
        guard let stack = model.editing.stackNumber else { return }
        let panel = PromptView(heading: Strings.text(.editCuesRenumber), width: 240)
        let field = panel.text(Strings.text(.editCuesRenumber), String(stack), placeholder: String(stack))
        panel.onSave = { [weak model] in
            guard let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            model?.editing.renumberStack(to: number)
            return nil
        }
        panel.finish()
        host?.present(panel, at: objectMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func zoomed() {
        model.editing.zoom(to: zoom.doubleValue)
    }

    /// "Renumber… (`edit list N renumber M`, or Swap for a taken number)": a small panel with the number.
    private func askRenumber() {
        guard let list = model.editing.list else { return }
        let panel = PromptView(heading: Strings.text(.editCuesRenumber), width: 240)
        let field = panel.text(Strings.text(.editCuesRenumber), String(list.number), placeholder: String(list.number))
        panel.onSave = { [weak model] in
            guard let model, let number = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), number > 0 else { return nil }
            // A list that shares its number is read-only here, and the offer is to renumber the other, which comes first.
            if model.editing.cannotEdit == .renumberToEdit { model.editing.renumberOther(to: number) } else { model.editing.renumber(to: number) }
            return nil
        }
        panel.finish()
        host?.present(panel, at: renumber)
    }

    func refresh() {
        let editing = model.editing
        if editing.page == .stacks {
            refreshStacks()
            return
        }
        if editing.page == .channels {
            refreshChannels()
            return
        }
        if editing.page == .presets {
            refreshPresets()
            return
        }
        stacks.isHidden = true
        channels.isHidden = true
        presets.isHidden = true
        objectPicker.isHidden = true
        objectMenu.isHidden = true
        let onCues = editing.page == .cues
        let deleted = onCues && editing.isListDeleted
        let hasList = onCues && editing.listUuid != nil && !deleted
        undo.isHidden = !(deleted && editing.canUndoDelete)
        title.stringValue = hasList ? editing.grid.title : EditModeWording.page(editing.page)
        title.isHidden = false
        var words: [String] = []
        if hasList, let version = editing.grid.version { words.append(EditModeWording.meta(cues: editing.grid.cueCount, version: version)) }
        // "A page that is read-only says why in its workspace's header (§1)."
        let cannot = hasList ? editing.cannotEdit : nil
        if let cannot { words.append(EditModeWording.readOnly(cannot)) }
        if hasList, cannot == nil, let number = editing.grid.listNumber, sharesNumber(number) { words.append(EditModeWording.sharedNumber(number)) }
        meta.stringValue = words.joined(separator: " · ")
        meta.textColor = cannot == nil ? Palette.dimText : Palette.browsing
        for view in [zoom, openText, renumber] as [NSView] { view.isHidden = !hasList }
        zoom.doubleValue = model.settings.gridZoom
        zoom.setAccessibilityValueDescription(Strings.text(.editCuesZoomValue, Int(model.settings.gridZoom)))
        // "the other's opens read-only, offering to renumber the first".
        let offersOther = cannot == .renumberToEdit
        renumber.title = Strings.text(offersOther ? .editCuesRenumberOther : .editCuesRenumber)
        renumber.isEnabled = cannot == nil || offersOther
        renumber.reason = cannot.map(EditModeWording.readOnly)
        grid.isHidden = !hasList
        if hasList {
            grid.refresh()
            // "An empty list shows, with its + header, "No cues yet. Add one with +, or paste the song's text in the text editor"".
            message.stringValue = editing.grid.cueCount == 0 ? Strings.text(.editCuesEmpty) : ""
        } else if deleted {
            message.stringValue = Strings.text(.editDeleted)
        } else {
            message.stringValue = onCues ? Strings.text(.editCuesNoList) : Strings.text(.editPageLater)
        }
        message.isHidden = message.stringValue.isEmpty
        needsLayout = true
    }

    /// Spec 11 §6 and G-30 — the header names the stack, with a picker of every stack and the stack's menu; the slots
    /// and the stack's fields fill the body.
    private func refreshStacks() {
        let page = model.editing.stackPage
        for view in [meta, zoom, openText, renumber, grid, undo, channels, presets] as [NSView] { view.isHidden = true }
        title.stringValue = EditModeWording.page(.stacks)
        title.isHidden = false
        objectPicker.isHidden = page.stacks.isEmpty
        objectPicker.set(page.stacks.map { (EditModel.name(of: $0), $0.number) }, selected: page.stack?.number ?? 0)
        objectPicker.setAccessibilityLabel(Strings.text(.editStackPicker))
        objectMenu.menu = stackMenu_
        objectMenu.setAccessibilityLabel(Strings.text(.editStackMenu))
        objectMenu.isHidden = false
        for item in objectMenu.menu?.items ?? [] where item.title == Strings.text(.menuDuplicate) || item.title == Strings.text(.editCuesRenumber) {
            item.isEnabled = page.stack != nil
        }
        // "Delete, refused while an output shows the stack".
        objectMenu.menu?.items.last?.isEnabled = page.stack != nil && page.shownOn.isEmpty
        stacks.isHidden = page.stack == nil
        stacks.refresh()
        message.stringValue = page.stacks.isEmpty ? Strings.text(.editStackNone) : ""
        message.isHidden = message.stringValue.isEmpty
        needsLayout = true
    }

    /// Spec 11 §7 and G-31 — the header names the page and holds its menu; the list and the form fill the body.
    private func refreshChannels() {
        let page = model.editing.channelPage
        for view in [meta, zoom, openText, renumber, grid, undo, stacks, presets, objectPicker] as [NSView] { view.isHidden = true }
        title.stringValue = EditModeWording.page(.channels)
        title.isHidden = false
        objectMenu.menu = channelMenu_
        objectMenu.setAccessibilityLabel(Strings.text(.editChannelMenu))
        objectMenu.isHidden = false
        for item in channelMenu_.items where item.title == Strings.text(.menuDuplicate) { item.isEnabled = page.channel != nil }
        // "A channel with content on an output's stack ... can't be deleted".
        channelMenu_.items.last?.isEnabled = page.channel != nil && !page.isOnAir
        channels.isHidden = page.rows.isEmpty
        channels.refresh()
        message.stringValue = page.rows.isEmpty ? Strings.text(.editChannelNone) : ""
        message.isHidden = message.stringValue.isEmpty
        needsLayout = true
    }

    /// Spec 11 §8 and G-32 — "a header naming the preset, with a picker of every preset and the preset's menu".
    private func refreshPresets() {
        let page = model.editing.presetPage
        for view in [meta, zoom, openText, renumber, grid, undo, stacks, channels] as [NSView] { view.isHidden = true }
        title.stringValue = EditModeWording.page(.presets)
        title.isHidden = false
        objectPicker.isHidden = page.presets.isEmpty
        objectPicker.set(page.presets.map { (EditModel.name(of: $0), $0.number) }, selected: page.preset?.number ?? 0)
        objectPicker.setAccessibilityLabel(Strings.text(.editPresetPicker))
        objectMenu.menu = presetMenu_
        objectMenu.setAccessibilityLabel(Strings.text(.editPresetMenu))
        objectMenu.isHidden = false
        // "Preset 1 can be edited but not deleted, renumbered or swapped".
        for item in presetMenu_.items where item.title == Strings.text(.menuDuplicate) { item.isEnabled = page.preset != nil }
        presetMenu_.items.last?.isEnabled = page.preset != nil && page.preset?.number != 1
        presets.isHidden = page.preset == nil
        presets.refresh()
        message.stringValue = page.presets.isEmpty ? Strings.text(.editPresetNone) : ""
        message.isHidden = message.stringValue.isEmpty
        needsLayout = true
    }

    /// Whether another master has this list's number: "that list's page says "Another list shares number 57"".
    private func sharesNumber(_ number: Int) -> Bool {
        (model.store.catalog?.lists.filter { $0.number == number && !$0.local }.count ?? 0) > 1
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        var right = bounds.width - 12
        for button in [renumber, openText] where !button.isHidden {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: (h - 24) / 2, width: size.width, height: 24)
            right -= size.width + 8
        }
        if !zoom.isHidden {
            zoom.frame = NSRect(x: right - 96, y: (h - 18) / 2, width: 96, height: 18)
            right -= 96 + 12
        }
        let titleWidth = min(Kit.width(of: title), max(0, right - 12 - 40))
        title.frame = NSRect(x: 12, y: (h - 16) / 2, width: titleWidth, height: 16)
        meta.frame = NSRect(x: title.frame.maxX + 10, y: (h - 16) / 2, width: max(0, right - title.frame.maxX - 16), height: 16)
        // The Stacks page's picker beside the title, its menu at the right.
        let picked = objectPicker.fittingSize
        objectPicker.frame = NSRect(x: title.frame.maxX + 10, y: (h - picked.height) / 2, width: min(picked.width + 10, 260), height: picked.height)
        objectMenu.frame = NSRect(x: bounds.width - 12 - 34, y: (h - 24) / 2, width: 34, height: 24)
        grid.frame = body
        stacks.frame = body
        channels.frame = body
        presets.frame = body
        let width = min(360, bounds.width - 40)
        // Under the grid's band and headers, where an empty list has nothing.
        let top = grid.isHidden ? body.midY - 18 : body.minY + CGFloat(CueGridGeometry.band + grid.geometry.header) + 28
        message.frame = NSRect(x: (bounds.width - width) / 2, y: top, width: width, height: 36)
        let undoWidth = undo.fitting.width
        undo.frame = NSRect(x: (bounds.width - undoWidth) / 2, y: top + 30, width: undoWidth, height: 24)
    }
}
