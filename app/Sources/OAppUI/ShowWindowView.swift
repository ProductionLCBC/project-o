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
final class ShowWindowView: Surface, NSPopoverDelegate {
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
    // Spec 11 §2 — edit mode's regions, which take the window under the top bar while it is in edit mode: the
    // Browser (whose Playlists and Library tabs are `left`, laid over it), the workspace, the monitors and the inspector.
    let browser: BrowserView
    let workspace: WorkspaceView
    let previewPanel: PreviewPanelView
    let programPanel: ProgramPanelView
    let inspector: InspectorView
    /// Spec 11 §2, "The lock" — "an open field's unsent text is offered in a sheet with Copy": what was offered last.
    private(set) var unsentText: String?
    /// Spec 10 §4 — the columns' widths, "200 to 360" and "340 to 480"; Spec 10 §6 — the pool's divider.
    let leftDivider = DividerView(axis: .columns, label: Strings.text(.dividerLeft))
    let rightDivider = DividerView(axis: .columns, label: Strings.text(.dividerRight))
    let poolDivider = DividerView(axis: .rows, label: Strings.text(.dividerPool))
    /// Spec 11 §2 — "The gaps beside the Browser, the monitors and the inspector drag to resize them".
    let browserDivider = DividerView(axis: .columns, label: Strings.text(.editDividerBrowser))
    let monitorsDivider = DividerView(axis: .columns, label: Strings.text(.editDividerMonitors))
    let inspectorDivider = DividerView(axis: .rows, label: Strings.text(.editDividerInspector))
    /// What a divider's column or panel measured when its drag began.
    private var dragStart = 0.0
    /// The pool's height while its divider is being dragged; it snaps to a state when the drag ends.
    private var poolDragHeight: CGFloat?
    private var outputPopover: NSPopover?
    private var slow: Timer?
    private var pictures: CADisplayLink?
    private var observers: [NSObjectProtocol] = []
    var machineRoot: URL? {
        didSet {
            grid.machineRoot = machineRoot
            pool.machineRoot = machineRoot
            browser.machineRoot = machineRoot
            workspace.machineRoot = machineRoot
            previewPanel.machineRoot = machineRoot
            inspector.machineRoot = machineRoot
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
    /// Spec 10 §10 — the list of channels a drop on a cue opened, while it is open.
    private(set) var picker: ChannelPickerView?
    /// Spec 10 §4 — "every confirmation and file dialog is a sheet on the
    /// main window": how files are chosen, as a seam the app fills with the
    /// system's dialog and a test with its own answer.
    var chooseFiles: ((FileChoice, @escaping @MainActor ([String]) -> Void) -> Void)?
    /// Reveal in Finder, as a seam: a test shows nothing in the Finder.
    var reveal: ((URL) -> Void)?
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
        browser = BrowserView(model: model)
        workspace = WorkspaceView(model: model)
        previewPanel = PreviewPanelView(model: model)
        programPanel = ProgramPanelView(model: model, keys: keys, mach: mach)
        inspector = InspectorView(model: model)
        super.init(frame: .zero)
        fill = Palette.window
        for view in [grid, commandBar, pool, browser, left, workspace, previewPanel, programPanel, inspector, preview, nextRow, tabs, strip, topBar, banner,
                     leftDivider, rightDivider, poolDivider, browserDivider, monitorsDivider, inspectorDivider] as [NSView] {
            addSubview(view)
        }
        for view in [browser, workspace, previewPanel, programPanel, inspector] as [NSView] { view.isHidden = true }
        browser.host = self
        workspace.host = self
        inspector.host = self
        workspace.grid.onEditContent = { [weak self] in self?.inspector.editContent() }
        // Spec 11 §2 — Show and Edit in the top bar, and its page picker.
        topBar.onShow = { [weak self] in self?.leaveEdit() }
        topBar.onEdit = { [weak self] in self?.enterEdit() }
        topBar.onPage = { [weak self] page in self?.model.editing.show(page: page) }
        // "Edit on a macro tile opens Objects on that macro (Spec 10 §7)"; the page itself comes with the small editors.
        tabs.onEditMacro = { [weak self] _ in self?.enterEdit(page: .objects) }
        // "the grid browses where its list came from ... and scrolls to it, firing nothing".
        model.onRevealCue = { [weak self] item, list, cue in self?.grid.scrollTo(cue: cue, item: item, list: list) }
        model.editing.onLocked = { [weak self] in self?.offerUnsentText() }
        commandBar.isHidden = !keys.showsCommandBar
        // The window opens the fields in place and the panels the regions' edits ask for (Spec 10 §10).
        left.host = self
        grid.host = self
        pool.host = self
        // The digits waiting, the command bar's lines and the table the overlay lists.
        keys.onChange = { [weak self] in self?.keysChanged() }
        topBar.onKeys = { [weak self] in self?.toggleKeys() }
        // "Popup 1" while a slot is set, which opens the Popups tab (Spec 10 §8).
        topBar.onPopupTag = { [weak self] in
            guard let self else { return }
            if self.model.settings.tabbedPanelCollapsed { self.model.change { $0.tabbedPanelCollapsed = false } }
            self.tabs.show(.popups)
        }
        // "A click lists how many documents are waiting ..., with Reveal in Finder for the machine folder" (Spec 10 §14).
        topBar.onRevealMachine = { [weak self] in
            if let root = self?.machineRoot { self?.reveal?(root) }
        }
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
        // Edit mode's: each starts from the size the panel has now, as laid out, and `view.json` keeps where it ends.
        browserDivider.onBegin = { [weak self] in self?.dragStart = Double(self?.browser.frame.width ?? 0) }
        browserDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            let start = self.dragStart
            self.model.resize { $0.editBrowserWidth = start + Double(delta) }
        }
        monitorsDivider.onBegin = { [weak self] in self?.dragStart = Double(self?.previewPanel.frame.width ?? 0) }
        monitorsDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            let start = self.dragStart
            self.model.resize { $0.editMonitorsWidth = start - Double(delta) }
        }
        inspectorDivider.onBegin = { [weak self] in self?.dragStart = Double(self?.inspector.frame.height ?? 0) }
        inspectorDivider.onDrag = { [weak self] delta in
            guard let self else { return }
            let start = self.dragStart
            self.model.resize { $0.editInspectorHeight = start - Double(delta) }
        }
        left.onShowItem = { [weak self] item in self?.grid.scrollTo(item: item) }
        topBar.onOutput = { [weak self] dot, anchor in self?.showOutput(dot, at: anchor) }
        model.onChange = { [weak self] changes in self?.refresh(changes) }
        model.onFollowLive = { [weak self] in self?.grid.scrollToLive() }
        // Spec 10 §15 — what VoiceOver is told as the show moves.
        model.onAnnounce = { [weak self] announcement in self?.say(AnnounceWording.text(announcement)) }
        // The regions the keyboard's focus rests in, by name.
        for (list, name) in [(left.playlists, StringKey.focusPlaylists), (left.library, .focusLibrary), (pool.rail, .focusPoolFolders)] {
            list.setAccessibilityLabel(Strings.text(name))
        }
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
        if model.mode == .edit { programPanel.refresh() }
        commandBar.refresh()
        // The command bar is show mode's: edit mode's layout has no place for it.
        if model.mode == .show, commandBar.isHidden == keys.showsCommandBar {
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
    var hasPopover: Bool { (outputPopover?.isShown ?? false) || prompt != nil || picker != nil }

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
    func present(_ panel: PromptView, at anchor: NSView?, rect: NSRect? = nil) {
        closePrompt()
        panel.finish()
        panel.onClose = { [weak self] in self?.closePrompt() }
        prompt = panel
        promptAnchor = anchor
        popUp(panel, at: anchor, rect: rect, focus: panel.firstField)
    }

    /// The view the open panel hangs from, for the tests: a popover can't be seen offscreen.
    private(set) weak var promptAnchor: NSView?

    /// Spec 11 §4 — the content popover "hangs from that cell in the grid,
    /// scrolled into view, so what is edited sits beside its cue"; with no
    /// cell in view, from `fallback`.
    func presentAtSelectedCell(_ panel: PromptView, fallback: NSView?) {
        let grid = workspace.grid
        grid.scrollSelectionIntoView()
        if let rect = grid.selectionRect, grid.bounds.intersects(rect) {
            present(panel, at: grid, rect: rect)
        } else {
            present(panel, at: fallback)
        }
    }

    /// A window that is on no screen shows no popover; the panel is the same
    /// either way. The popover points at where `anchor` is now and hangs
    /// from the window's own view: a cell or a tile is made again whenever
    /// the engine says something changed, and a panel hung from one would
    /// close under the operator's hands.
    private func popUp(_ panel: NSView, at anchor: NSView?, rect: NSRect? = nil, focus: NSView?) {
        guard let anchor, anchor.window === window, window?.isVisible == true else { return }
        let controller = NSViewController()
        controller.view = panel
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = panel.frame.size
        popover.behavior = .semitransient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.show(relativeTo: convert(rect ?? anchor.bounds, from: anchor), of: self, preferredEdge: .maxX)
        promptPopover = popover
        if let focus { panel.window?.makeFirstResponder(focus) }
        // Spec 11 §4 — text opens "with the cursor at its end".
        if let text = focus as? NSTextView { text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0)) }
    }

    func closePrompt() {
        let open = promptPopover
        promptPopover = nil
        prompt = nil
        picker = nil
        defaultsPanel = nil
        open?.close()
    }

    /// A popover the system closed by itself, on a click elsewhere: the
    /// panel is forgotten, so the keys are the window's again (Spec 10 §9,
    /// "When bindings fire", 6, holds only while one is open).
    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === promptPopover else { return }
        promptPopoverClosed()
    }

    func promptPopoverClosed() {
        promptPopover = nil
        prompt = nil
        picker = nil
        defaultsPanel = nil
    }

    // MARK: - Drops on a cue, and the pool's dialogs (Spec 10 §6, §10)

    /// "The channel popover opens at the drop, with the drop channel ...
    /// picked ... Return or a click sends". The list has the keys while it
    /// is open, so the arrows move its pick and fire nothing (§9).
    func chooseChannel(for drop: CueDrop, cue view: CueCellView) {
        closePrompt()
        let (cell, section) = (view.cell, view.section)
        let heading: String
        switch drop.source {
        case .media(let id):
            let name = model.store.media.first { $0.id == id }.map { MediaPool.name(of: $0.entry) } ?? ""
            heading = Strings.text(.channelsMedia, name, cell.number)
        case .file(let path):
            heading = Strings.text(.channelsFile, (path as NSString).lastPathComponent, cell.number)
        }
        let list = ChannelPickerView(heading: heading, channels: model.store.catalog?.channels ?? [], picked: drop.picked)
        list.finish()
        list.onChoose = { [weak self] channel in self?.model.write(drop, into: cell, in: section, channel: channel) }
        list.onClose = { [weak self] in self?.closePrompt() }
        picker = list
        popUp(list, at: view, focus: list)
    }

    /// Import… (⌘I): "a file dialog", then the files are imported as files dropped on the pool are.
    func importMedia() {
        if let cannot = model.cannotImport { return model.say(.notSent(cannot), at: .pool) }
        chooseFiles?(.importMedia) { [weak self] paths in
            guard let self, !paths.isEmpty else { return }
            self.model.landOnPool(self.model.planOnPool(.files(paths)))
        }
    }

    /// "Replace with… (a file dialog: the app imports the file and sends
    /// `media replace OLD NEW` when the import's `done` names the new id, Spec 8 §6)".
    func replace(media id: String) {
        guard let item = model.store.media.first(where: { $0.id == id }) else { return }
        if let cannot = model.cannotEdit(media: id) { return model.say(.notSent(cannot), at: .pool) }
        chooseFiles?(.replace(name: MediaPool.name(of: item.entry))) { [weak self] paths in
            guard let self, let path = paths.first else { return }
            if let cannot = self.model.imports.importFile(path, replacing: id) { self.model.say(.notSent(cannot), at: .pool) }
        }
    }

    /// "Defaults… (a popover editing its trim in and out, loop, gain, grade, sync offset and default channel ...)".
    private(set) var defaultsPanel: DefaultsPanel?

    func showDefaults(of id: String, at anchor: NSView?) {
        guard let item = model.store.media.first(where: { $0.id == id }) else { return }
        let made = Prompts.mediaDefaults(item, model: model)
        present(made.panel, at: anchor)
        defaultsPanel = made
    }

    /// Reveal in Finder, for a media item's file.
    func reveal(media id: String) {
        if let url = model.location(ofMedia: id, machineRoot: machineRoot) { reveal?(url) }
    }

    /// Reveal in Finder, for one of the media root's folders.
    func reveal(mediaFolder folder: String) {
        if let root = model.mediaRoot(machineRoot: machineRoot) { reveal?(folder.isEmpty ? root : root.appendingPathComponent(folder)) }
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

    /// Spec 10 §14, "Snapshots" — Restore a Snapshot…: the sheet of
    /// snapshots, which "shows it working until its result" and then says a
    /// refusal "with its reason in plain words".
    func restoreSnapshot() {
        if let cannot = model.cannotRestore { return model.say(.notSent(cannot), at: .top) }
        model.snapshots { [weak self] snapshots in
            guard let self else { return }
            let machine = self.model.store.catalog?.settings?.uuid.uuidString ?? self.model.store.hello?.machine
            let sheet = Sheets.snapshots(snapshots, thisMachine: machine, cannot: self.model.cannotRestore) { [weak self] snapshot in
                guard let self else { return }
                self.model.restore(snapshot, began: { [weak self] in
                    self?.sheetView?.show(status: Strings.text(.snapshotsWorking))
                    self?.sheetView?.buttons.forEach { $0.isEnabled = false }
                }, ended: { [weak self] rejection in
                    guard let sheet = self?.sheetView else { return }
                    sheet.buttons.forEach { $0.isEnabled = true }
                    if let rejection {
                        sheet.show(status: StateWording.refusal(rejection), isProblem: true)
                    } else {
                        sheet.show(status: Strings.text(.snapshotsRestored))
                    }
                })
            }
            self.present(sheet: sheet)
        }
    }

    /// What the window last told VoiceOver, for a test; the newest last.
    private(set) var spoken: [String] = []

    /// Spec 10 §15 — an announcement: VoiceOver reads it over whatever it was reading.
    func say(_ words: String) {
        spoken.append(words)
        if spoken.count > 20 { spoken.removeFirst(spoken.count - 20) }
        NSAccessibility.post(element: window ?? self, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Spec 10 §15 — the system's Increase Contrast and Reduce Motion, as they stand: "Increase Contrast thickens
    /// borders and outlines", and Reduce Motion "shows the transition bar's end state instead of running it".
    func follow(increaseContrast: Bool, reduceMotion: Bool) {
        Look.increasesContrast = increaseContrast
        model.reducesMotion = reduceMotion
        refreshAll()
        var waiting: [NSView] = [self]
        while let view = waiting.popLast() {
            view.needsDisplay = true
            waiting.append(contentsOf: view.subviews)
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

    // MARK: - Edit mode (Spec 11 §2)

    /// "Mode ▸ Edit (⌘2) or Edit in the top bar opens the last page on what
    /// show mode had in hand". A field open in place commits first (Spec 10 §10).
    func enterEdit() {
        guard model.mode == .show, commitOpenField() else { return }
        closePrompt()
        model.editing.open()
    }

    /// "a double-click on a cue that isn't a text cue, or Edit Cue in a cue's menu, opens the Cues page on that cue".
    func enterEdit(cue: CueCell, in section: GridSection) {
        guard model.mode == .show, commitOpenField() else { return }
        closePrompt()
        model.editing.open(cue: cue, in: section)
    }

    /// Opens edit mode on one of its pages, as Edit on a macro tile and Edit in Stack Editor do.
    func enterEdit(page: EditPage) {
        guard commitOpenField() else { return }
        closePrompt()
        if model.mode == .edit { model.editing.show(page: page) } else { model.editing.open(page: page) }
    }

    /// "Show in the top bar, Escape with nothing else to close (below), or
    /// Mode ▸ Show (⌘1) returns to show mode ... An open field commits first".
    func leaveEdit() {
        guard model.mode == .edit else { return }
        closePrompt()
        let left = model.editing.leave { [weak self] in
            guard let self else { return true }
            guard self.commitOpenField() else { return false }
            // A field of edit mode's commits as the cursor leaves it; what can't be sent keeps edit mode open.
            if let editor = self.window?.firstResponder as? NSText, editor.isDescendant(of: self.inspector) || editor.isFieldEditor {
                self.window?.makeFirstResponder(self)
            }
            if case .notSent? = self.model.editing.notice { return false }
            return true
        }
        if left { window?.makeFirstResponder(self) }
    }

    /// "When it comes on from elsewhere, edit mode closes to show mode on
    /// the same cue, and an open field's unsent text is offered in a sheet
    /// with Copy, since the engine would refuse it."
    private func offerUnsentText() {
        closePrompt()
        guard let editor = window?.firstResponder as? NSText, editor.isDescendant(of: inspector) || (editor.isFieldEditor && (editor.delegate as? NSView)?.isDescendant(of: inspector) == true) else { return }
        let text = editor.string
        guard !text.isEmpty else { return }
        unsentText = text
        window?.makeFirstResponder(self)
        guard let window, window.isVisible, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = UnavailableWording.sentence(for: .locked)
        alert.informativeText = text
        alert.addButton(withTitle: Strings.text(.fieldCopy))
        alert.addButton(withTitle: Strings.text(.cancel))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// Shows or hides each mode's regions, and tells the left column which tab of the Browser it is.
    private func placeModes() {
        let editing = model.mode == .edit
        for view in [grid, pool, preview, nextRow, tabs, strip, leftDivider, rightDivider, poolDivider] as [NSView] { view.isHidden = editing }
        commandBar.isHidden = editing || !keys.showsCommandBar
        for view in [browser, workspace, previewPanel, programPanel, inspector, browserDivider, monitorsDivider, inspectorDivider] as [NSView] {
            view.isHidden = !editing
        }
        fill = editing ? Palette.gut : Palette.window
        let tab = editing ? model.settings.browserTab : nil
        left.isHidden = tab == .media
        if left.tab != tab { left.tab = tab }
    }

    private func refreshEdit() {
        browser.refresh()
        left.refresh()
        workspace.refresh()
        previewPanel.refresh()
        programPanel.refresh()
        inspector.refresh()
    }

    /// Redraws the regions a change touches.
    func refresh(_ changes: Set<ShowModel.Change>) {
        let editing = model.mode == .edit
        if changes.contains(.layout) || changes.contains(.edit) { placeModes() }
        if editing {
            if changes.contains(.edit) {
                refreshEdit()
                topBar.refresh()
            } else {
                // Show mode's changes that edit mode's regions show too: the pool's items, what is live, the outputs.
                if changes.contains(.pool) { browser.refresh() }
                if !changes.isDisjoint(with: [.right, .top, .grid]) { programPanel.refresh() }
            }
        }
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
        // A cell's word about a drop: the cells stay as they are, and say it.
        if changes.contains(.dropNotes) {
            if !changes.contains(.grid) { grid.refreshNotes() }
            if !changes.contains(.strip) { strip.refreshNotes() }
        }
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
    /// Spec 10 §2 — the engine sends a stack's newest frame "at most 30 a second" on its own clock. Read on the
    /// display's refresh, each frame shows within a refresh of its arrival; read on a 30 Hz timer of the app's own,
    /// the two clocks beat, and some frames showed twice and others never (Adam's try, 2026-11-24).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        slow?.invalidate()
        pictures?.invalidate()
        pictures = nil
        guard window != nil else { return }
        let slowTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(slowTimer, forMode: .common)
        slow = slowTimer
        let link = displayLink(target: self, selector: #selector(pictureStep(_:)))
        link.add(to: .main, forMode: .common)
        pictures = link
    }

    @objc private func pictureStep(_ link: CADisplayLink) {
        drawPictures()
    }

    /// What counts on the app's clock between events (Spec 10 §3).
    func tick() {
        topBar.refresh()
        if model.mode == .edit {
            // The armed countdown under the Program picture counts on the app's clock too.
            programPanel.refresh()
            return
        }
        grid.tick()
        strip.tick()
        if case .one = model.transport, tabs.tab == .transport, !tabs.isCollapsed { tabs.refresh() }
    }

    func drawPictures() {
        mach?.poll()
        if model.mode == .edit {
            programPanel.draw()
            return
        }
        preview.draw()
        strip.draw()
    }

    // MARK: - Layout (Spec 10 §4)

    override func layout() {
        super.layout()
        let w = bounds.width
        let bannerHeight = banner.isHidden ? 0 : banner.fittingSize.height
        banner.frame = NSRect(x: 0, y: 0, width: w, height: bannerHeight)
        if model.mode == .edit {
            // Spec 11 §2 — "Edit mode keeps the main window and lays it out its own way".
            let settings = model.settings
            let frame = EditFrame.make(width: Double(w), height: Double(bounds.height), top: Double(bannerHeight), browser: settings.editBrowserWidth,
                                       monitors: settings.editMonitorsWidth, inspector: settings.editInspectorHeight)
            func rect(_ box: EditFrame.Box) -> NSRect { NSRect(x: box.x, y: box.y, width: box.width, height: box.height) }
            topBar.frame = rect(frame.topBar)
            browser.frame = rect(frame.browser)
            workspace.frame = rect(frame.workspace)
            previewPanel.frame = rect(frame.preview)
            programPanel.frame = rect(frame.program)
            inspector.frame = rect(frame.inspector)
            // The dividers sit in the gaps, a few points either side of each.
            let thick = DividerView.thickness
            let gap = CGFloat(EditFrame.gap)
            browserDivider.frame = NSRect(x: browser.frame.maxX + gap / 2 - thick / 2, y: browser.frame.minY, width: thick, height: browser.frame.height)
            monitorsDivider.frame = NSRect(x: previewPanel.frame.minX - gap / 2 - thick / 2, y: workspace.frame.minY, width: thick,
                                           height: workspace.frame.height)
            inspectorDivider.frame = NSRect(x: inspector.frame.minX, y: inspector.frame.minY - gap / 2 - thick / 2, width: inspector.frame.width, height: thick)
            // The Playlists and Library tabs are show mode's own two windows, laid over the Browser's body.
            left.frame = browser.frame.insetBy(dx: 1, dy: 1).offsetBy(dx: 0, dy: 0)
            left.frame.origin.y += PanelView.headerHeight
            left.frame.size.height -= PanelView.headerHeight
            keysOverlay?.frame = bounds
            return
        }
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
        // Edit mode's panels draw themselves, on the darker ground.
        guard model.mode == .show else { return }
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
        return OutputDetailsView(details, stacks: model.store.catalog?.stacks ?? [], cannotSend: model.store.cannotSend, onStack: { [weak self] stack in
            self?.model.send(Actions.outputStack(output: dot.number, stack: stack))
            self?.outputPopover?.close()
        }, onScreen: { [weak self] screen, putBack in
            self?.onScreen?(screen, putBack)
            self?.outputPopover?.close()
        })
    }

    /// Spec 10 §8 — an output's Release This Screen and Put Back on This
    /// Screen: the screen, and whether it is put back. The app's controller
    /// holds the released screens (§9), so it takes them.
    var onScreen: ((String, Bool) -> Void)?

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

    /// Spec 11 §2 — "The pages are picked in the top bar's page picker, and
    /// in the View menu with ⌥⌘1 to ⌥⌘6"; each opens edit mode on it from show mode.
    private func editPages() -> [NSMenuItem] {
        let keys: [EditPage: StringKey] = [.cues: .editPageCues, .text: .editPageText, .stacks: .editPageStacks, .channels: .editPageChannels,
                                           .presets: .editPagePresets, .objects: .editPageObjects]
        return EditPage.allCases.compactMap { page in
            guard let key = keys[page] else { return nil }
            return item(key, key: String(page.shortcut), modifiers: [.option, .command],
                        state: { [weak self] in self?.model?.mode == .edit && self?.model?.editing.page == page },
                        enabled: { [weak self] in page.isBuilt && self?.model?.editing.cannotOpen == nil }) { [weak self] in self?.view?.enterEdit(page: page) }
        }
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
            // Spec 10 §6, "The header" — "Import… (⌘I, a file dialog)".
            item(.menuImportMedia, key: "i", enabled: { [weak self] in self?.model?.cannotImport == nil }) { [weak self] in self?.view?.importMedia() },
            .separator(),
            // Spec 10 §12 — Take Snapshot works under the lock; the restore pickers don't.
            item(.menuTakeSnapshot, enabled: { [weak self] in self?.model?.store.cannotSend == nil }) { [weak self] in self?.model?.takeSnapshot() },
            item(.menuRestoreSnapshot, enabled: { [weak self] in self?.model?.cannotRestore == nil }) { [weak self] in self?.view?.restoreSnapshot() },
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
            .separator(),
        ] + editPages())
        add(.menuGo, to: [
            item(.menuBackToLive, key: "l", enabled: { [weak self] in self?.model?.store.live.isSomethingLive ?? false && self?.model?.mode == .show }) { [weak self] in
                self?.model?.backToLive()
            },
            item(.menuGoToCue, key: "j", enabled: { [weak self] in self?.model?.nextRow.goToEnabled ?? false }) { [weak self] in
                guard let view = self?.view else { return }
                // The go-to field is under the Program monitor in edit mode (Spec 11 §2).
                let field = view.model.mode == .edit ? view.programPanel.goTo : view.nextRow.goTo
                field.window?.makeFirstResponder(field)
            },
            item(.menuHoldAutoAdvance, enabled: { [weak self] in self?.model?.nextRow.showsHold ?? false }) { [weak self] in self?.model?.send(Actions.hold()) },
            // "The command bar, off by default (`commandBar`) ... ⌘K focuses it."
            item(.menuCommandBar, key: "k", enabled: { [weak self] in (self?.view?.keys.showsCommandBar ?? false) && self?.model?.mode == .show }) { [weak self] in
                self?.view?.focusCommandBar()
            },
        ])
        // Spec 10 §4 — "Mode: Show ⌘1; Edit ⌘2 (choice U-13)"; Spec 11 §2 — "While operator lock is on, Mode ▸ Edit
        // ... [is] disabled with the reason".
        add(.menuMode, to: [
            item(.menuShow, key: "1", state: { [weak self] in self?.model?.mode != .edit }) { [weak self] in self?.view?.leaveEdit() },
            item(.menuEditMode, key: "2", state: { [weak self] in self?.model?.mode == .edit },
                 enabled: { [weak self] in self?.model?.editing.cannotOpen == nil }) { [weak self] in self?.view?.enterEdit() },
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

/// What a file dialog is asked for (Spec 10 §6).
enum FileChoice: Equatable {
    /// Import…: any number of files and folders.
    case importMedia
    /// Replace with…: one file, to take the place of the item named.
    case replace(name: String)
}
