// OAppUI — Spec 11 §2, "The Browser": Playlists, Library and Media, one to a tab.

import AppKit
import OApp
import OCore

/// One media item in the Browser's List view: "a small tile beside the
/// item's name with its kind and duration under it". It drags as a pool
/// tile does.
@MainActor
final class MediaRowView: Surface, NSDraggingSource {
    static let height: CGFloat = 42

    let tile: PoolTile
    private let picture = NSImageView()
    let name = Kit.content(Kit.label(size: 12))
    let detail = Kit.label(size: 11)
    var makeMenu: (() -> NSMenu?)?
    private var pressedAt: NSPoint?
    private var overlay: TagView?

    init(_ tile: PoolTile, machineRoot: URL?) {
        self.tile = tile
        super.init(frame: .zero)
        radius = 4
        picture.wantsLayer = true
        picture.layer?.backgroundColor = Palette.well.cgColor
        picture.layer?.cornerRadius = 3
        picture.layer?.masksToBounds = true
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.setAccessibilityElement(false)
        if let file = tile.tile, let root = machineRoot {
            picture.image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] in self?.picture.image = $0 }
        }
        name.stringValue = tile.name
        let kind = ShowWording.kind(tile.kind)
        detail.stringValue = tile.durationMs.map { Strings.text(.editMediaDetail, kind, TimeText.clock(ms: $0)) } ?? kind
        detail.textColor = Palette.faintText
        for view in [picture, name, detail] as [NSView] { addSubview(view) }
        switch tile.overlay {
        case .none: break
        case .missing: overlay = TagView(Strings.text(.tagMissing), style: .dashedRed)
        case .deleted: overlay = TagView(Strings.text(.tagDeleted), style: .dashedRed)
        }
        if let overlay { addSubview(overlay) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(([tile.name, detail.stringValue] + (overlay.map { [$0.text] } ?? [])).joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 6, y: 5, width: 56, height: 32)
        let x: CGFloat = 72
        let tagWidth = overlay?.fitting.width ?? 0
        name.frame = NSRect(x: x, y: 5, width: max(0, bounds.width - x - 6 - (tagWidth > 0 ? tagWidth + 6 : 0)), height: 16)
        detail.frame = NSRect(x: x, y: 22, width: max(0, bounds.width - x - 6), height: 14)
        if let overlay { overlay.frame = NSRect(x: bounds.width - tagWidth - 6, y: 5, width: tagWidth, height: 16) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return showMenu(event) }
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    var menuNow: NSMenu? { makeMenu?() }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .generic] : []
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - pressedAt.x) + abs(point.y - pressedAt.y) > 5 else { return }
        self.pressedAt = nil
        Dragging.begin(dragPayload, from: self, event: event)
    }

    var dragPayload: DragPayload { .media(tile.id) }
}

/// A document view measured from its top, for a scroll view.
@MainActor
private final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Spec 11 §2, "The Browser" — "stands where show mode's left column does
/// and holds what edit mode picks from." Its Playlists and Library tabs are
/// show mode's own two windows, which the window lays over this panel's
/// body; the Media tab is drawn here: "the media pool (Spec 10 §6) at the
/// Browser's width".
@MainActor
final class BrowserView: PanelView {
    private let model: ShowModel
    let tabs = SegmentedView(BrowserTab.allCases.map { EditModeWording.tab($0) }, small: true)
    // The Media tab.
    let search = Kit.search(placeholder: Strings.text(.poolSearch))
    let filter = NSPopUpButton(frame: .zero, pullsDown: true)
    let count = Kit.label(size: 11)
    let views = SegmentedView(MediaListView.allCases.map { EditModeWording.mediaView($0) }, small: true)
    private let scroll = NSScrollView()
    private let document = FlippedDocument()
    private(set) var tiles: [PoolTileView] = []
    private(set) var rows: [MediaRowView] = []
    private var jobs: [ImportRowView] = []
    private var isMarked = false { didSet { if isMarked != oldValue { needsDisplay = true } } }
    var machineRoot: URL? { didSet { refresh() } }
    /// The window, which opens an item's Defaults, its replacement's file dialog and the Finder.
    weak var host: ShowWindowView?

    init(model: ShowModel) {
        self.model = model
        super.init(title: "")
        setAccessibilityLabel(Strings.text(.editBrowser))
        tabs.fills = true
        tabs.onSelect = { [weak model] index in model?.editing.show(tab: BrowserTab.allCases[index]) }
        search.target = self
        search.action = #selector(searched)
        filter.font = .systemFont(ofSize: 11)
        filter.isBordered = false
        filter.setAccessibilityLabel(Strings.text(.poolKindAll))
        count.textColor = Palette.faintText
        views.onSelect = { [weak model] index in model?.editing.show(mediaView: MediaListView.allCases[index]) }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        for view in [tabs, search, filter, count, views, scroll] as [NSView] { addSubview(view) }
        // "Files dropped on the tab are imported as on the pool (Spec 10 §6)".
        registerForDraggedTypes(Dragging.withFiles)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var tab: BrowserTab { model.settings.browserTab }

    @objc private func searched() { model.setPool { $0.search = self.search.stringValue } }

    /// "the filter menu, with show mode's kinds, its folders, Used in This List, Replaced and the sort".
    private func buildFilter() {
        let current = model.poolFilter
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down's first item is its title: what is filtered by now.
        let kinds: [(ViewSettings.PoolKind, StringKey)] = [(.all, .poolKindAll), (.video, .kindVideo), (.image, .kindImage), (.audio, .kindAudio)]
        var title = Strings.text(kinds.first { $0.0 == current.kind }?.1 ?? .poolKindAll)
        if let folder = current.folder { title = LibraryTreeName.last(folder) + " · " + title }
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        func add(_ title: String, on: Bool, indent: Int = 0, _ run: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: title, run)
            item.state = on ? .on : .off
            item.indentationLevel = indent
            menu.addItem(item)
        }
        for (kind, key) in kinds {
            add(Strings.text(key), on: current.kind == kind) { [weak model] in model?.setPool { $0.kind = kind } }
        }
        menu.addItem(.separator())
        add(Strings.text(.poolAllMedia), on: current.folder == nil) { [weak model] in model?.setPool { $0.folder = nil } }
        for folder in MediaPool.folders(model.store.media) {
            add(LibraryTreeName.last(folder), on: current.folder == folder, indent: folder.split(separator: "/").count) { [weak model] in
                model?.setPool { $0.folder = folder }
            }
        }
        menu.addItem(.separator())
        add(Strings.text(.poolUsedInList), on: current.usedIn != nil) { [weak self] in self?.toggleUsed() }
        add(Strings.text(.poolReplaced), on: current.replacedOnly) { [weak model] in model?.setPool { $0.replacedOnly.toggle() } }
        menu.addItem(.separator())
        add(Strings.text(.poolSortName), on: current.sort == .name) { [weak model] in model?.setPool { $0.sort = .name } }
        add(Strings.text(.poolSortDate), on: current.sort == .dateAdded) { [weak model] in model?.setPool { $0.sort = .dateAdded } }
        filter.menu = menu
    }

    /// "Used in This List": the items the Cues page's list writes.
    private func toggleUsed() {
        if model.poolFilter.usedIn != nil {
            model.setPool { $0.usedIn = nil }
            return
        }
        var ids: Set<String> = []
        for cue in model.editing.list?.cues ?? [] {
            for case .channelWrite(let write) in cue.commands.map(\.command) {
                if let ref = write.content.mediaRef { ids.insert(ref) }
            }
        }
        model.setPool { $0.usedIn = ids }
    }

    /// "An item's menu has Defaults…, Replace with…, Reveal in Finder and
    /// Delete…. A double-click and Fire to… are show mode's alone, so
    /// nothing in the Browser goes to air."
    func itemMenu(for id: String, at anchor: NSView?) -> NSMenu {
        var entries = model.tileMenu(for: id).filter { entry in
            switch entry.kind {
            case .fireTo, .fireToMenu: return false
            default: return true
            }
        }
        // The line that stood between the fire entries and the rest has nothing over it now.
        while entries.first?.kind == .separator { entries.removeFirst() }
        return MenuBuilder.menu(entries) { [weak self, weak anchor] entry in
            guard let self else { return }
            switch entry.kind {
            case .defaults: self.host?.showDefaults(of: id, at: anchor ?? self)
            case .replace: self.host?.replace(media: id)
            case .reveal: self.host?.reveal(media: id)
            case .deleteMedia: self.model.deleteMedia(id)
            default: break
            }
        }
    }

    func refresh() {
        tabs.selected = BrowserTab.allCases.firstIndex(of: tab)
        let showsMedia = tab == .media
        for view in [search, filter, count, views, scroll] as [NSView] { view.isHidden = !showsMedia }
        tiles.forEach { $0.removeFromSuperview() }
        rows.forEach { $0.removeFromSuperview() }
        jobs.forEach { $0.removeFromSuperview() }
        tiles = []
        rows = []
        jobs = []
        guard showsMedia else {
            needsLayout = true
            return
        }
        if search.currentEditor() == nil, search.stringValue != model.poolFilter.search { search.stringValue = model.poolFilter.search }
        buildFilter()
        let items = model.poolTiles
        count.stringValue = Strings.counted(.editMediaCount, items.count)
        views.selected = MediaListView.allCases.firstIndex(of: model.settings.mediaView)
        if model.settings.mediaView == .grid {
            tiles = items.map { tile in
                let view = PoolTileView(tile, isSelected: false, machineRoot: machineRoot)
                view.makeMenu = { [weak self, weak view] in self?.itemMenu(for: tile.id, at: view) }
                document.addSubview(view)
                return view
            }
        } else {
            rows = items.map { tile in
                let view = MediaRowView(tile, machineRoot: machineRoot)
                view.makeMenu = { [weak self, weak view] in self?.itemMenu(for: tile.id, at: view) }
                document.addSubview(view)
                return view
            }
        }
        // "with the jobs and the refusals listed at the tab's foot until dismissed".
        jobs = model.imports.rows.suffix(3).map { ImportRowView($0, model: model) }
        jobs.forEach { addSubview($0) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        tabs.frame = NSRect(x: 8, y: (Self.headerHeight - 24) / 2, width: w - 16, height: 24)
        guard tab == .media else { return }
        var y = Self.headerHeight + 12
        search.frame = NSRect(x: 12, y: y, width: w - 24, height: 24)
        y += 24 + 8
        let viewsSize = views.fitting
        views.frame = NSRect(x: w - 12 - viewsSize.width, y: y, width: viewsSize.width, height: viewsSize.height)
        let filterWidth = min(filter.fittingSize.width, 96)
        filter.frame = NSRect(x: 8, y: y, width: filterWidth, height: viewsSize.height)
        count.frame = NSRect(x: filter.frame.maxX + 4, y: y + (viewsSize.height - 14) / 2, width: max(0, views.frame.minX - filter.frame.maxX - 8), height: 14)
        y += viewsSize.height + 10
        var foot = bounds.height
        for job in jobs.reversed() {
            foot -= ImportRowView.height + 2
            job.frame = NSRect(x: 8, y: foot, width: w - 16, height: ImportRowView.height)
        }
        scroll.frame = NSRect(x: 0, y: y, width: w, height: max(0, foot - y))
        // "Grid, two tiles to a row, or List".
        let inner = w - 24
        var height: CGFloat = 0
        if !tiles.isEmpty {
            let tileWidth = floor((inner - 8) / 2)
            let tileHeight = floor(tileWidth * 9 / 16) + 44
            for (index, tile) in tiles.enumerated() {
                tile.frame = NSRect(x: 12 + CGFloat(index % 2) * (tileWidth + 8), y: 4 + CGFloat(index / 2) * (tileHeight + 8), width: tileWidth, height: tileHeight)
            }
            height = 4 + CGFloat((tiles.count + 1) / 2) * (tileHeight + 8)
        }
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 6, y: 4 + CGFloat(index) * (MediaRowView.height + 2), width: w - 12, height: MediaRowView.height)
            height = row.frame.maxY + 6
        }
        document.frame = NSRect(x: 0, y: 0, width: w, height: max(height, scroll.frame.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isMarked else { return }
        Palette.selection.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6, yRadius: 6)
        path.lineWidth = 2
        path.stroke()
    }

    // MARK: Files dropped on the Media tab

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard tab == .media, let payload = Dragging.payload(from: info.draggingPasteboard) else { return [] }
        let plan = model.planOnPool(payload)
        isMarked = plan.isAccepted
        if case .refused = plan { return .generic }
        return plan.isAccepted ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { isMarked = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { isMarked = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isMarked = false
        guard let payload = Dragging.payload(from: sender.draggingPasteboard) else { return false }
        return accept(payload)
    }

    /// Lands a drag on the Media tab, as letting go of it would.
    @discardableResult
    func accept(_ payload: DragPayload) -> Bool {
        guard tab == .media else { return false }
        let plan = model.planOnPool(payload)
        guard plan != .none else { return false }
        model.landOnPool(plan)
        return true
    }
}
