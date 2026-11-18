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
    private var slow: Timer?
    private var fast: Timer?
    private var observers: [NSObjectProtocol] = []
    var machineRoot: URL? {
        didSet {
            grid.machineRoot = machineRoot
            pool.machineRoot = machineRoot
        }
    }

    init(model: ShowModel, mach: MachLink?, banner: BannerView) {
        self.model = model
        self.mach = mach
        self.banner = banner
        topBar = TopBarView(model: model)
        left = LeftColumnView(model: model)
        grid = GridView(model: model)
        pool = PoolView(model: model)
        preview = PreviewView(model: model, mach: mach)
        nextRow = NextRowView(model: model)
        tabs = TabsView(model: model)
        strip = StripView(model: model, mach: mach)
        super.init(frame: .zero)
        fill = Palette.window
        for view in [grid, pool, left, preview, nextRow, tabs, strip, topBar, banner] as [NSView] { addSubview(view) }
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
        let poolHeight = min(PoolView.height(model.settings.panel, center: height),
                             max(PoolView.headerHeight, height - GridView.headerHeight - CueCellView.height(settings: model.settings) - 70))
        grid.frame = NSRect(x: leftWidth, y: top, width: centerWidth, height: height - poolHeight)
        pool.frame = NSRect(x: leftWidth, y: top + height - poolHeight, width: centerWidth, height: poolHeight)

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

    /// "A click opens the output's details ... with a Stack ▸ menu that
    /// switches its live stack (`output N stack M`)." The stacks now; the
    /// device, format and counts come with the settings they are read beside.
    private func showOutput(_ dot: OutputDot, at anchor: NSView) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let title = NSMenuItem(title: ShowWording.output(dot), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let away = model.store.cannotSend
        for stack in (model.store.catalog?.stacks ?? []).sorted(by: { $0.number < $1.number }) {
            let item = ClosureMenuItem(title: Strings.text(.previewStack, stack.number, stack.label)) { [weak model] in
                model?.send(Actions.outputStack(output: dot.number, stack: stack.number))
            }
            item.state = stack.number == dot.stack ? .on : .off
            item.isEnabled = away == nil
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
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
                      enabled: (() -> Bool)? = nil, _ run: @escaping @MainActor () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: Strings.text(title), key: key, modifiers: modifiers, run)
        updates.append { [weak item] in
            if let state { item?.state = state() ? .on : .off }
            if let enabled { item?.isEnabled = enabled() }
        }
        return item
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
            later(.menuNewPlaylist, key: "n"), later(.menuNewList, key: "n", modifiers: [.shift, .command]), later(.menuImportMedia, key: "i"),
            .separator(), later(.menuTakeSnapshot), later(.menuRestoreSnapshot),
        ])
        let edit: [NSMenuItem] = [
            later(.menuUndo, key: "z"), later(.menuRedo, key: "z", modifiers: [.shift, .command]), .separator(),
            standard(.menuCut, #selector(NSText.cut(_:)), key: "x"), standard(.menuCopy, #selector(NSText.copy(_:)), key: "c"),
            standard(.menuPaste, #selector(NSText.paste(_:)), key: "v"), standard(.menuSelectAll, #selector(NSText.selectAll(_:)), key: "a"),
            .separator(),
            item(.menuFindInList, key: "f", enabled: { [weak self] in self?.model?.grid.context != nil }) { [weak self] in self?.view?.grid.focusSearch() },
        ]
        add(.menuEdit, to: edit)
        // The text items find their target along the responder chain.
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
            later(.menuCommandBar, key: "k"),
        ])
        add(.menuMode, to: [
            item(.menuShow, key: "1", state: { true }) {},
            later(.menuEditMode, key: "2"),
        ])
        add(.menuHelp, to: [
            later(.menuKeys, key: "/"),
            later(.menuReleaseOutput, key: "\u{1B}", modifiers: [.control, .option, .command]),
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
