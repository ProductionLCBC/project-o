// OAppUI — Spec 10 §4, the main window's regions, laid out; and the menu bar.

import AppKit
import OApp
import OCore

/// Spec 10 §4, "Regions" — the top bar; the left column, "Playlists window
/// over Library window"; the center, "Cue grid over the Media pool panel";
/// the right column, "Preview, next row, tabbed panel, channel strip".
///
/// Built so edit mode can take the center and the right column and put its
/// edit bar under the top bar (Spec 11 §2): each region is its own view,
/// placed here and nowhere else.
@MainActor
final class ShowWindowView: Surface {
    let model: ShowModel
    let mach: MachLink?
    let banner: BannerView
    let topBar: TopBarView
    let left: LeftColumnView
    let grid: GridView
    let pool: PoolView
    let preview: PreviewView
    let nextRow: NextRowView
    let tabs: TabsView
    let strip: StripView
    /// Spec 10 §4 — the columns' widths, "200 to 360" and "340 to 480"; Spec 10 §6 — the pool's divider.
    let leftDivider = DividerView(axis: .columns, label: Strings.text(.dividerLeft))
    let rightDivider = DividerView(axis: .columns, label: Strings.text(.dividerRight))
    let poolDivider = DividerView(axis: .rows, label: Strings.text(.dividerPool))
    /// What a divider's column or panel measured when its drag began.
    private var dragStart = 0.0
    /// The pool's height while its divider is being dragged; it snaps to a state when the drag ends.
    private var poolDragHeight: CGFloat?
    private var outputPopover: NSPopover?
    private var slow: Timer?
    private var fast: Timer?
    private var observers: [NSObjectProtocol] = []
    var machineRoot: URL? {
        didSet {
            grid.machineRoot = machineRoot
            pool.machineRoot = machineRoot
        }
    }
    /// Spec 10 §9 — the keys' model, the command bar "across the top of the center when on", and the keys overlay while it is up.
    let keys: KeysModel
    let commandBar: CommandBarView
    private(set) var keysOverlay: KeysOverlayView?
    /// Whether the system gave the app ⌃⌥⌘⎋ as a system-wide key; the overlay says so when it didn't.
    var releaseKeyRegistered = true
    /// What a keyboard layout prints on a key, for the overlay, where a test gives a layout of its own; nil is the Mac's current one.
    var layoutLabel: ((UInt16) -> String?)?
    /// Spec 10 §10 — the field open in place, if one is, and the small panel open in a popover.
    private(set) var inlineEditor: InlineEditor?
    private(set) var prompt: PromptView?
    private var promptPopover: NSPopover?
    /// Spec 10 §14 — the sheet of versions or snapshots up now, if one is.
    private(set) var sheetView: PickerSheetView?
    private var sheetWindow: NSWindow?

    init(model: ShowModel, keys: KeysModel, mach: MachLink?, banner: BannerView) {
        self.model = model
        self.keys = keys
        self.mach = mach
        self.banner = banner
        topBar = TopBarView(model: model)
        left = LeftColumnView(model: model)
        grid = GridView(model: model)
        pool = PoolView(model: model)
        preview = PreviewView(model: model, mach: mach)
        nextRow = NextRowView(model: model, keys: keys)
        tabs = TabsView(model: model)
        strip = StripView(model: model, mach: mach)
        commandBar = CommandBarView(keys: keys)
        super.init(frame: .zero)
        fill = Palette.window
        for view in [grid, commandBar, pool, left, preview, nextRow, tabs, strip, topBar, banner, leftDivider, rightDivider, poolDivider] as [NSView] {
            addSubview(view)
        }
        commandBar.isHidden = !keys.showsCommandBar
        // The window opens the fields in place and the panels the regions' edits ask for (Spec 10 §10).
        left.host = self
        grid.host = self
        // The digits waiting, the command bar's lines and the table the overlay lists.
        keys.onChange = { [weak self] in self?.keysChanged() }
        topBar.onKeys = { [weak self] in self?.toggleKeys() }
        leftDivider.onBegin = { [weak self] in self?.dragStart = self?.model.settings.leftColumnWidth ?? 0 }
        leftDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            let start = self.dragStart
            self.model.resize { $0.leftColumnWidth = start + Double(delta) }
        }
        rightDivider.onBegin = { [weak self] in self?.dragStart = self?.model.settings.rightColumnWidth ?? 0 }
        rightDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            let start = self.dragStart
            self.model.resize { $0.rightColumnWidth = start - Double(delta) }
        }
        // "The divider snaps to three states": it follows the pointer while it is dragged and snaps when it is let go.
        poolDivider.onBegin = { [weak self] in self?.dragStart = Double(self?.pool.frame.height ?? 0) }
        poolDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            self.poolDragHeight = max(PoolView.collapsedHeight, CGFloat(self.dragStart) - delta)
            self.needsLayout = true
        }
        poolDivider.onEnd = { [weak self] in
            guard let self, let height = self.poolDragHeight else { return }
            self.poolDragHeight = nil
            let center = Double(self.grid.frame.height + self.pool.frame.height)
            self.model.change { $0.panel = PoolDivider.snap(height: Double(height), center: center, collapsed: Double(PoolView.collapsedHeight)) }
        }
        poolDivider.onDoubleClick = { [weak self] in self?.model.change { $0.panel = PoolDivider.toggled($0.panel) } }
        left.onShowItem = { [weak self] item in self?.grid.scrollTo(item: item) }
        topBar.onOutput = { [weak self] dot, anchor in self?.showOutput(dot, at: anchor) }
        model.onChange = { [weak self] changes in self?.refresh(changes) }
        model.onFollowLive = { [weak self] in self?.grid.scrollToLive() }
        mach?.onChange = { [weak self] in self?.drawPictures() }
        // "While another app is active, the whole bar says ..." (Spec 10 §8).
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.topBar.activeElsewhere = NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.topBar.activeElsewhere = nil }
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Spec 10 §4, "Focus" — "The grid, the pool, the right column and the
    /// top bar never take typing; text fields do". The regions hold the keys
    /// whenever no field does, so the window never hands them to a field by
    /// itself; the show keys of §9 are read from here.
    override var acceptsFirstResponder: Bool { true }

    /// A key nothing took ends here, quietly: the Mac's alert sound has no
    /// place in a show. Tab and ⇧Tab go on to the window, which moves the
    /// focus with them (Spec 10 §15).
    override func keyDown(with event: NSEvent) {
        let stroke = KeyTap.stroke(event)
        if !stroke.command, let name = stroke.name, name.key == "tab", name.isReserved { super.keyDown(with: event) }
    }

    // MARK: - The keys (Spec 10 §9)

    private func keysChanged() {
        nextRow.refresh()
        commandBar.refresh()
        if commandBar.isHidden == keys.showsCommandBar {
            commandBar.isHidden = !keys.showsCommandBar
            needsLayout = true
        }
        if let keysOverlay { keysOverlay.show(overlayModel) }
    }

    private var overlayModel: KeysOverlay {
        let given = layoutLabel
        return KeysOverlay.make(table: keys.table, releaseKeyRegistered: releaseKeyRegistered) { code in
            given.map { $0(code) } ?? KeyboardLayout.label(code: code)
        }
    }

    var isShowingKeys: Bool { keysOverlay != nil }

    /// Whether a popover of the window's is open (Spec 10 §9, "When bindings fire", 6).
    var hasPopover: Bool { (outputPopover?.isShown ?? false) || prompt != nil }

    // MARK: - Fields in place and small panels (Spec 10 §10)

    /// Opens a field in place over `anchor`, or over `rect` of it. A field
    /// already open commits first, and stays if it can't.
    func editInPlace(over anchor: NSView, rect: NSRect? = nil, text: String, kind: FieldKind = .edit, label: String, placeholder: String = "",
                     commit: @escaping (String) -> CannotEdit?) {
        if let open = inlineEditor, !open.commitNow() { return }
        let editor = InlineEditor(text: text, kind: kind, label: label, placeholder: placeholder, commit: commit)
        var frame = convert(rect ?? anchor.bounds, from: anchor)
        if kind != .inPlaceText { frame.size.height = max(frame.height, 24) }
        editor.frame = frame.intersection(bounds.insetBy(dx: 2, dy: 2))
        editor.onClose = { [weak self, weak editor] in
            if self?.inlineEditor === editor { self?.inlineEditor = nil }
        }
        // Under the keys overlay, over everything else.
        if let keysOverlay { addSubview(editor, positioned: .below, relativeTo: keysOverlay) } else { addSubview(editor) }
        inlineEditor = editor
        editor.focus()
    }

    /// Spec 10 §10 — "⌘Q, ⌘2 and Lock Station commit an open field first."
    /// Says whether nothing is left open: a field whose text can't be saved
    /// stays, with its reason, and what was asked for waits.
    @discardableResult
    func commitOpenField() -> Bool {
        inlineEditor?.commitNow() ?? true
    }

    /// Shows a small panel in a popover beside `anchor`.
    func present(_ panel: PromptView, at anchor: NSView?) {
        closePrompt()
        panel.finish()
        panel.onClose = { [weak self] in self?.closePrompt() }
        prompt = panel
        // A window that is on no screen shows no popover; the panel is the same either way.
        guard let anchor, anchor.window?.isVisible == true else { return }
        let controller = NSViewController()
        controller.view = panel
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.behavior = .semitransient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        promptPopover = popover
        if let first = panel.firstField { panel.window?.makeFirstResponder(first) }
    }

    func closePrompt() {
        promptPopover?.close()
        promptPopover = nil
        prompt = nil
    }

    // MARK: - Sheets to choose from (Spec 10 §14)

    /// Puts a sheet of things to choose from on the main window (Spec 10
    /// §4: "every confirmation and file dialog is a sheet on the main window").
    func present(sheet view: PickerSheetView) {
        closeSheet()
        view.onClose = { [weak self] in self?.closeSheet() }
        sheetView = view
        // A window that is on no screen shows no sheet; what it would hold is the same either way.
        guard let window, window.isVisible else { return }
        let controller = NSViewController()
        controller.view = view
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.setContentSize(view.frame.size)
        window.beginSheet(sheet)
        sheetWindow = sheet
    }

    func closeSheet() {
        if let sheetWindow { window?.endSheet(sheetWindow) }
        sheetWindow = nil
        sheetView = nil
    }

    /// Spec 10 §14, "A list's versions" — Restore a Version…, from a list's menu or its header's.
    func restoreVersion(of listUuid: String) {
        model.versions(ofList: listUuid) { [weak self] title, versions, onAir in
            guard let self else { return }
            let cannot = self.model.cannotEdit(listUuid: listUuid)
            self.present(sheet: Sheets.versions(title: title, versions: versions, onAir: onAir, cannot: cannot) { [weak self] version in
                // The question that follows names the version whole, and is a sheet of its own.
                self?.closeSheet()
                self?.model.restore(version, ofList: listUuid)
            })
        }
    }

    /// "The keys overlay (Help ▸ Keys, ⌘/, or ? in the top bar)".
    func showKeys() {
        guard keysOverlay == nil else { return }
        // Digits that were waiting are no longer seen: they don't wait under the overlay.
        keys.clearDigits()
        let overlay = KeysOverlayView(overlayModel)
        overlay.onClose = { [weak self] in self?.hideKeys() }
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        keysOverlay = overlay
        (window as? MainWindow)?.handKeysBack()
        NSAccessibility.post(element: overlay, notification: .layoutChanged)
    }

    /// "Escape or a click closes it."
    func hideKeys() {
        keysOverlay?.removeFromSuperview()
        keysOverlay = nil
    }

    func toggleKeys() {
        if isShowingKeys { hideKeys() } else { showKeys() }
    }

    /// ⌘K: "The command bar ... ⌘K focuses it."
    func focusCommandBar() {
        guard keys.showsCommandBar else { return }
        window?.makeFirstResponder(commandBar.field)
    }

    /// The focus moved: the top bar says what a focused field's keys do (Spec 10 §8).
    func focusChanged() {
        topBar.fieldHint = KeyTap.fieldKind(window?.firstResponder).map { KeyWording.hint($0.hint) }
    }

    /// Redraws the regions a change touches.
    func refresh(_ changes: Set<ShowModel.Change>) {
        if changes.contains(.top) { topBar.refresh() }
        if changes.contains(.left) { left.refresh() }
        if changes.contains(.grid) {
            grid.refresh()
            topBar.refresh()
        }
        if changes.contains(.pool) { pool.refresh() }
        if changes.contains(.right) {
            preview.refresh()
            nextRow.refresh()
            tabs.isCollapsed = PanelCollapseRule.isCollapsed(windowHeight: Double(bounds.height), setting: model.settings.tabbedPanelCollapsed)
        }
        if changes.contains(.strip) { strip.refresh() }
        if changes.contains(.layout) {
            // A divider moved: the regions are placed again and the lines between them redrawn.
            left.needsLayout = true
            left.needsDisplay = true
            needsDisplay = true
        }
        needsLayout = true
    }

    func refreshAll() {
        refresh([.top, .left, .grid, .pool, .right, .strip])
    }

    // MARK: - Clocks

    /// Starts what moves without an event: the countdowns four times a second, the pictures at the display's pace.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        slow?.invalidate()
        fast?.invalidate()
        guard window != nil else { return }
        let slowTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        let fastTimer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.drawPictures() } }
        RunLoop.main.add(slowTimer, forMode: .common)
        RunLoop.main.add(fastTimer, forMode: .common)
        slow = slowTimer
        fast = fastTimer
    }

    /// What counts on the app's clock between events (Spec 10 §3).
    func tick() {
        topBar.refresh()
        grid.tick()
        strip.tick()
        if case .one = model.transport, tabs.tab == .transport, !tabs.isCollapsed { tabs.refresh() }
    }

    func drawPictures() {
        mach?.poll()
        preview.draw()
        strip.draw()
    }

    // MARK: - Layout (Spec 10 §4)

    override func layout() {
        super.layout()
        let w = bounds.width
        let bannerHeight = banner.isHidden ? 0 : banner.fittingSize.height
        banner.frame = NSRect(x: 0, y: 0, width: w, height: bannerHeight)
        topBar.frame = NSRect(x: 0, y: bannerHeight, width: w, height: TopBarView.height)
        let top = bannerHeight + TopBarView.height
        let height = max(0, bounds.height - top)
        // "Left column ... 248 points wide by default, 200 to 360"; "Right column ... 380 points wide by default, 340 to 480".
        let leftWidth = CGFloat(ViewSettings.clampedLeft(model.settings.leftColumnWidth))
        let rightWidth = CGFloat(ViewSettings.clampedRight(model.settings.rightColumnWidth))
        left.frame = NSRect(x: 0, y: top, width: leftWidth, height: height)
        let centerWidth = max(200, w - leftWidth - rightWidth)
        // "The grid keeps at least its header and one row of cues".
        let wanted = poolDragHeight ?? CGFloat(PoolDivider.height(model.settings.panel, center: Double(height), collapsed: Double(PoolView.collapsedHeight)))
        // "The command bar ... is a field across the top of the center when on."
        let barHeight = commandBar.isHidden ? 0 : CommandBarView.height
        commandBar.frame = NSRect(x: leftWidth, y: top, width: centerWidth, height: barHeight)
        let poolHeight = min(wanted, max(PoolView.headerHeight, height - barHeight - GridView.headerHeight - CueCellView.height(settings: model.settings) - 70))
        grid.frame = NSRect(x: leftWidth, y: top + barHeight, width: centerWidth, height: height - barHeight - poolHeight)
        pool.frame = NSRect(x: leftWidth, y: top + height - poolHeight, width: centerWidth, height: poolHeight)

        let half = DividerView.thickness / 2
        leftDivider.frame = NSRect(x: leftWidth - half, y: top, width: DividerView.thickness, height: height)
        rightDivider.frame = NSRect(x: leftWidth + centerWidth - half, y: top, width: DividerView.thickness, height: height)
        poolDivider.frame = NSRect(x: leftWidth + half, y: pool.frame.minY - half, width: centerWidth - DividerView.thickness, height: DividerView.thickness)

        let rx = leftWidth + centerWidth + 12
        let rw = rightWidth - 24
        var y = top + 12
        let previewHeight = model.settings.multiviewer ? min(height * 0.42, rw * 0.9) : rw * 9 / 16 + 30
        preview.frame = NSRect(x: rx, y: y, width: rw, height: previewHeight)
        y += previewHeight + 10
        nextRow.frame = NSRect(x: rx, y: y, width: rw, height: NextRowView.height)
        y += NextRowView.height + 4
        // "While it is less than 1000 points high the tabbed panel collapses to its tab bar ... and the strip takes the space".
        let collapsed = PanelCollapseRule.isCollapsed(windowHeight: Double(bounds.height), setting: model.settings.tabbedPanelCollapsed)
        if tabs.isCollapsed != collapsed { tabs.isCollapsed = collapsed }
        let tabsHeight = tabs.wantedHeight
        tabs.frame = NSRect(x: rx, y: y, width: rw, height: tabsHeight)
        y += tabsHeight + 10
        strip.frame = NSRect(x: rx, y: y, width: rw, height: max(0, bounds.height - y - 10))
        keysOverlay?.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The right column's panel.
        let rightWidth = CGFloat(ViewSettings.clampedRight(model.settings.rightColumnWidth))
        Palette.panel.setFill()
        NSRect(x: bounds.width - rightWidth, y: topBar.frame.maxY, width: rightWidth, height: bounds.height - topBar.frame.maxY).fill()
        Palette.hairline.setFill()
        NSRect(x: bounds.width - rightWidth, y: topBar.frame.maxY, width: 1, height: bounds.height - topBar.frame.maxY).fill()
    }

    // MARK: - An output's details (Spec 10 §8)

    /// "A click opens the output's details (its device, format, reference,
    /// state, and its presented, late and dropped counts from `metrics`)
    /// with a Stack ▸ menu that switches its live stack (`output N stack M`)."
    func outputDetails(for dot: OutputDot) -> OutputDetailsView? {
        guard let output = model.store.catalog?.outputs.first(where: { $0.number == dot.number }) else { return nil }
        let details = OutputDetails.make(output: output, dot: dot, status: model.store.outputs[dot.number], devices: model.store.devices,
                                         metrics: model.store.metrics)
        return OutputDetailsView(details, stacks: model.store.catalog?.stacks ?? [], cannotSend: model.store.cannotSend) { [weak self] stack in
            self?.model.send(Actions.outputStack(output: dot.number, stack: stack))
            self?.outputPopover?.close()
        }
    }

    private func showOutput(_ dot: OutputDot, at anchor: NSView) {
        guard let view = outputDetails(for: dot) else { return }
        outputPopover?.close()
        let controller = NSViewController()
        controller.view = view
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        outputPopover = popover
    }
}

/// Spec 10 §4, "Menus" — "The menu bar holds every app-level action, with
/// these shortcuts." An entry whose area hasn't been built is there and
/// disabled, so the bar is the spec's from the first build.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private weak var controller: AppController?
    private var updates: [() -> Void] = []
    let menu = NSMenu()

    init(controller: AppController?) {
        self.controller = controller
        super.init()
        build()
    }

    private var model: ShowModel? { controller?.model }
    private var view: ShowWindowView? { controller?.windowController.regions }

    private func add(_ title: StringKey, to items: [NSMenuItem]) {
        let top = NSMenuItem()
        let sub = NSMenu(title: Strings.text(title))
        sub.autoenablesItems = false
        sub.delegate = self
        for item in items { sub.addItem(item) }
        top.submenu = sub
        menu.addItem(top)
    }

    /// An entry a later area or stage builds: there, and disabled with the reason.
    private func later(_ title: StringKey, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: Strings.text(title), action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.isEnabled = false
        item.toolTip = Strings.text(.unavailableLater)
        return item
    }

    private func item(_ title: StringKey, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], state: (() -> Bool)? = nil,
                      enabled: (() -> Bool)? = nil, named: (() -> String)? = nil, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: Strings.text(title), key: key, modifiers: modifiers, run)
        if let enabled { item.isAllowed = { enabled() } }
        updates.append { [weak item] in
            if let state { item?.state = state() ? .on : .off }
            if let enabled { item?.isEnabled = enabled() }
            if let named { item?.title = named() }
        }
        return item
    }

    /// The field being typed in, whose own typing ⌘Z undoes (Spec 10 §10).
    private var typingField: NSTextView? {
        NSApplication.shared.keyWindow?.firstResponder as? NSTextView ?? controller?.windowController.window.firstResponder as? NSTextView
    }

    /// Spec 10 §10, "Undo and redo" — "Edit ▸ Undo and Redo send `undo` and
    /// `redo` ... While a text field has the focus, ⌘Z and ⇧⌘Z undo its own
    /// typing instead (Spec 5 §8)".
    private func history(undo: Bool) -> NSMenuItem {
        item(undo ? .menuUndo : .menuRedo, key: "z", modifiers: undo ? [.command] : [.shift, .command],
             enabled: { [weak self] in
                 if let field = self?.typingField { return undo ? field.undoManager?.canUndo ?? false : field.undoManager?.canRedo ?? false }
                 return (undo ? self?.model?.undoStep : self?.model?.redoStep) != nil
             },
             named: { [weak self] in
                 if self?.typingField != nil { return Strings.text(undo ? .menuUndo : .menuRedo) }
                 return EditWording.menuTitle(undo: undo, step: undo ? self?.model?.undoStep : self?.model?.redoStep)
             },
             { [weak self] in
                 if let field = self?.typingField {
                     if undo { field.undoManager?.undo() } else { field.undoManager?.redo() }
                 } else if undo {
                     self?.model?.undo()
                 } else {
                     self?.model?.redo()
                 }
             })
    }

    private func standard(_ title: StringKey, _ action: Selector, key: String) -> NSMenuItem {
        NSMenuItem(title: Strings.text(title), action: action, keyEquivalent: key)
    }

    private func build() {
        let quit = NSMenuItem(title: Strings.text(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(.appName, to: [
            item(.menuAbout) { [weak self] in self?.controller?.showAbout() },
            .separator(),
            later(.menuSettings, key: ","),
            later(.menuLock, key: "l", modifiers: [.control, .command]),
            .separator(),
            quit,
        ])
        add(.menuFile, to: [
            // Spec 10 §5 — "New playlist: the window's + button or ⌘N"; "New List (⇧⌘N, or New List Here)".
            item(.menuNewPlaylist, key: "n", enabled: { [weak self] in self?.model?.cannotEditMachine == nil }) { [weak self] in self?.view?.left.beginNewPlaylist() },
            item(.menuNewList, key: "n", modifiers: [.shift, .command], enabled: { [weak self] in self?.model?.cannotEditMasters == nil }) { [weak self] in
                self?.view?.left.newList()
            },
            later(.menuImportMedia, key: "i"),
            .separator(), later(.menuTakeSnapshot), later(.menuRestoreSnapshot),
        ])
        let edit: [NSMenuItem] = [
            history(undo: true), history(undo: false), .separator(),
            standard(.menuCut, #selector(NSText.cut(_:)), key: "x"), standard(.menuCopy, #selector(NSText.copy(_:)), key: "c"),
            standard(.menuPaste, #selector(NSText.paste(_:)), key: "v"), standard(.menuSelectAll, #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            item(.menuFindInList, key: "f", enabled: { [weak self] in self?.model?.grid.context != nil }) { [weak self] in self?.view?.grid.focusSearch() },
        ]
        add(.menuEdit, to: edit)
        // The text items find their target along the responder chain: AppKit enables Cut, Copy, Paste and Select All
        // by asking it, and leaves Undo, Redo and Find in List, whose targets are their own, as the app set them.
        menu.items.last?.submenu?.autoenablesItems = true
        add(.menuView, to: [
            item(.menuMultiviewer, key: "m", modifiers: [.option, .command], state: { [weak self] in self?.model?.settings.multiviewer ?? false }) { [weak self] in
                self?.model?.change { $0.multiviewer.toggle() }
            },
            item(.menuShowArchived, state: { [weak self] in self?.model?.settings.showsArchivedPlaylists ?? false }) { [weak self] in
                self?.model?.change { $0.showsArchivedPlaylists.toggle() }
            },
            item(.menuCompactGrid, state: { [weak self] in self?.model?.settings.isCompact ?? false }) { [weak self] in
                self?.model?.change { $0.showsThumbnails.toggle() }
            },
            item(.menuCollapsePanel, state: { [weak self] in self?.model?.settings.tabbedPanelCollapsed ?? false }) { [weak self] in
                self?.model?.change { $0.tabbedPanelCollapsed.toggle() }
            },
            item(.menuResetLayout) { [weak self] in self?.model?.resetLayout() },
            .separator(),
            item(.menuFullScreen) { [weak self] in self?.controller?.windowController.window.toggleFullScreen(nil) },
        ])
        add(.menuGo, to: [
            item(.menuBackToLive, key: "l", enabled: { [weak self] in self?.model?.store.live.isSomethingLive ?? false }) { [weak self] in self?.model?.backToLive() },
            item(.menuGoToCue, key: "j", enabled: { [weak self] in self?.model?.nextRow.goToEnabled ?? false }) { [weak self] in
                guard let row = self?.view?.nextRow else { return }
                row.window?.makeFirstResponder(row.goTo)
            },
            item(.menuHoldAutoAdvance, enabled: { [weak self] in self?.model?.nextRow.showsHold ?? false }) { [weak self] in self?.model?.send(Actions.hold()) },
            // "The command bar, off by default (`commandBar`) ... ⌘K focuses it."
            item(.menuCommandBar, key: "k", enabled: { [weak self] in self?.view?.keys.showsCommandBar ?? false }) { [weak self] in self?.view?.focusCommandBar() },
        ])
        add(.menuMode, to: [
            item(.menuShow, key: "1", state: { true }) {},
            later(.menuEditMode, key: "2"),
        ])
        add(.menuHelp, to: [
            // "The keys overlay (Help ▸ Keys, ⌘/, or ? in the top bar)".
            item(.menuKeys, key: "/", state: { [weak self] in self?.view?.isShowingKeys ?? false }) { [weak self] in self?.view?.toggleKeys() },
            // Spec 10 §9, "Fixed keys" — ⌃⌥⌘⎋, here too, so it is there when the system didn't give the app the key.
            item(.menuReleaseOutput, key: "\u{1B}", modifiers: [.control, .option, .command]) { [weak self] in self?.controller?.releaseThisScreen() },
        ])
        refresh()
    }

    /// Brings every entry's tick and its enabling up to date.
    func refresh() {
        for update in updates { update() }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
    }

    /// The menus' titles, and one menu's entries, for a test.
    var titles: [String] { menu.items.compactMap { $0.submenu?.title } }

    func entries(of title: String) -> [NSMenuItem] {
        menu.items.first { $0.submenu?.title == title }?.submenu?.items.filter { !$0.isSeparatorItem } ?? []
    }
}
