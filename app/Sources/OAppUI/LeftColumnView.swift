// OAppUI — Spec 10 §5, the left column: the Playlists window over the Library window.

import AppKit
import OApp
import OCore

/// What one row of a tree shows.
struct RowContent {
    var indent: CGFloat = 0
    /// Nil for no triangle; true when open.
    var disclosure: Bool?
    var hasLiveDot = false
    var title = ""
    var isHeading = false
    var isRed = false
    var isDimmed = false
    /// Quiet text at the right: a date, a number.
    var trailing: String?
    var tags: [(text: String, style: TagView.Style)] = []
    var isSelected = false
    /// Pointed at by "Show in Library": outlined, until something else is chosen.
    var isRevealed = false
    /// What VoiceOver reads: the title with its states in words.
    var spoken = ""
}

/// One row of a tree: a button, to VoiceOver and to the keyboard as to the mouse.
@MainActor
final class RowView: Surface, NSDraggingSource {
    static let height: CGFloat = 26

    // MARK: Drags (Spec 10 §5, "Dragging")

    /// What dragging this row carries; nil for a row that isn't dragged.
    var dragPayload: DragPayload?
    /// What landing a drag on this row would do: on it, or below its middle.
    var planDrop: ((DragPayload, _ below: Bool) -> DropPlan)?
    /// Does it, or says why it can't be done.
    var performDrop: ((DropPlan) -> Void)?
    /// Whether a drop goes between rows (an item among items) or onto the row (a playlist, a folder).
    var dropsBetween = false
    private var pressedAt: NSPoint?
    private(set) var dropMark = DropMark.none { didSet { needsDisplay = true } }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.move, .copy, .generic] : []
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragPayload, let pressedAt else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard abs(point.x - pressedAt.x) + abs(point.y - pressedAt.y) > 5 else { return }
        self.pressedAt = nil
        Dragging.begin(dragPayload, from: self, event: event)
    }

    /// What a drag carrying `payload` would do at a point of the row.
    func plan(for payload: DragPayload, at point: NSPoint) -> DropPlan {
        planDrop?(payload, point.y > bounds.midY) ?? .none
    }

    /// Lands a drag here, as letting go of it would. Says whether the row took it.
    @discardableResult
    func accept(_ payload: DragPayload, at point: NSPoint) -> Bool {
        let plan = plan(for: payload, at: point)
        guard plan != .none else { return false }
        performDrop?(plan)
        return true
    }

    private func mark(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = Dragging.payload(from: info.draggingPasteboard) else { return [] }
        let point = convert(info.draggingLocation, from: nil)
        switch plan(for: payload, at: point) {
        case .none:
            dropMark = .none
            return []
        case .refused:
            // It may be let go here, and the column then says why nothing happened.
            dropMark = .none
            return .generic
        case .edit:
            dropMark = dropsBetween ? (point.y > bounds.midY ? .below : .above) : .onto
            return .move
        default:
            // A row takes edits only; the pool's and the cells' drops are theirs.
            dropMark = .none
            return []
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { mark(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { mark(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropMark = .none }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropMark = .none }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropMark = .none
        guard let payload = Dragging.payload(from: sender.draggingPasteboard) else { return false }
        return accept(payload, at: convert(sender.draggingLocation, from: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.selection.setFill()
        switch dropMark {
        case .none: break
        case .onto:
            Palette.selection.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            path.lineWidth = 2
            path.stroke()
        case .above: NSRect(x: 4, y: 0, width: bounds.width - 8, height: 2).fill()
        case .below: NSRect(x: 4, y: bounds.height - 2, width: bounds.width - 8, height: 2).fill()
        }
    }

    private let triangle = Kit.label(size: 9)
    private let dot = DotView()
    let title = Kit.content(Kit.label(size: 12.5))
    private let trailing = Kit.content(Kit.label(size: 11, mono: true))
    private var tags: [TagView] = []
    private let content: RowContent
    var onClick: ((_ option: Bool) -> Void)?
    /// Spec 10 §5 — "Double-click or the menu renames one in place".
    var onDoubleClick: (() -> Void)?
    var makeMenu: (() -> NSMenu?)?

    init(_ content: RowContent) {
        self.content = content
        super.init(frame: .zero)
        radius = 6
        fill = content.isSelected ? Palette.selection.withAlphaComponent(0.22) : nil
        if content.isRevealed {
            outline = Palette.selection
            outlineWidth = 1.5
        }
        if content.isHeading {
            Kit.setHeading(title, content.title)
        } else {
            title.stringValue = content.title
            title.textColor = content.isRed ? Palette.live : (content.isDimmed ? Palette.faintText : Palette.text)
        }
        triangle.stringValue = content.disclosure.map { $0 ? "▼" : "▶" } ?? ""
        triangle.textColor = Palette.faintText
        dot.color = Palette.live
        dot.isHidden = !content.hasLiveDot
        trailing.stringValue = content.trailing ?? ""
        trailing.textColor = Palette.faintText
        trailing.alignment = .right
        tags = content.tags.map { TagView($0.text, style: $0.style) }
        for view in [triangle, dot, title, trailing] as [NSView] + tags { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(content.isHeading ? .staticText : .button)
        setAccessibilityLabel(content.spoken.isEmpty ? content.title : content.spoken)
        if content.disclosure != nil { setAccessibilityExpanded(content.disclosure ?? false) }
        registerForDraggedTypes(Dragging.own)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        var x = 8 + content.indent
        triangle.frame = NSRect(x: x - 2, y: 7, width: 16, height: 12)
        if content.disclosure != nil { x += 15 }
        dot.frame = NSRect(x: x, y: 8.5, width: 9, height: 9)
        if content.hasLiveDot { x += 15 }
        var right = bounds.width - 8
        if !trailing.stringValue.isEmpty {
            let width = Kit.width(of: trailing)
            trailing.frame = NSRect(x: right - width, y: 6, width: width, height: 14)
            right -= width + 6
        }
        for tag in tags.reversed() {
            let size = tag.fitting
            tag.frame = NSRect(x: right - size.width, y: 5, width: size.width, height: size.height)
            right -= size.width + 5
        }
        title.frame = NSRect(x: x, y: content.isHeading ? 7 : 5, width: max(20, right - x - 4), height: 16)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(event)
        } else if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
        } else {
            pressedAt = convert(event.locationInWindow, from: nil)
            onClick?(event.modifierFlags.contains(.option))
        }
    }

    override func mouseUp(with event: NSEvent) { pressedAt = nil }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    /// The row's menu as it stands now, for a test and for ⌃Return (Spec 10 §15).
    var menuNow: NSMenu? { makeMenu?() }

    override func accessibilityPerformPress() -> Bool {
        guard !content.isHeading else { return false }
        onClick?(false)
        return true
    }

    var shownTags: [String] { tags.map(\.text) }
}

/// A scrolling column of rows.
@MainActor
final class RowList: NSScrollView {
    /// The rows' ground, which has a menu of its own where no row is: the Library's New Folder and New List Here.
    private final class Ground: Surface {
        var makeMenu: (() -> NSMenu?)?
        /// What a drag let go where no row is would do, and doing it: the Library's top.
        var planDrop: ((DragPayload) -> DropPlan)?
        var performDrop: ((DropPlan) -> Void)?

        private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
            guard let payload = Dragging.payload(from: info.draggingPasteboard), let plan = planDrop?(payload) else { return [] }
            switch plan {
            case .refused: return .generic
            case .edit: return .move
            default: return []
            }
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let payload = Dragging.payload(from: sender.draggingPasteboard), let plan = planDrop?(payload), plan != .none else { return false }
            performDrop?(plan)
            return true
        }

        override func rightMouseDown(with event: NSEvent) {
            if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control), let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        }
    }

    private let document = Ground()
    private(set) var rows: [RowView] = []
    /// The menu of the empty space under the rows.
    var makeMenu: (() -> NSMenu?)? {
        get { document.makeMenu }
        set { document.makeMenu = newValue }
    }

    /// What a drag let go on the empty space would do, and doing it.
    var planDrop: ((DragPayload) -> DropPlan)? {
        get { document.planDrop }
        set { document.planDrop = newValue }
    }

    var performDrop: ((DropPlan) -> Void)? {
        get { document.performDrop }
        set { document.performDrop = newValue }
    }

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = document
        document.registerForDraggedTypes(Dragging.own)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(_ rows: [RowView]) {
        for row in self.rows { row.removeFromSuperview() }
        self.rows = rows
        for row in rows { document.addSubview(row) }
        needsLayout = true
        layoutRows()
    }

    private func layoutRows() {
        let width = max(contentSize.width, 100)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 4, y: CGFloat(index) * RowView.height + 2, width: width - 8, height: RowView.height - 1)
        }
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(contentSize.height, CGFloat(rows.count) * RowView.height + 6))
    }

    override func layout() {
        super.layout()
        layoutRows()
    }

    /// Scrolls so the row at this place shows.
    func show(row index: Int) {
        guard rows.indices.contains(index) else { return }
        layoutRows()
        rows[index].scrollToVisible(rows[index].bounds)
    }
}

/// Spec 10 §5 — "Playlists window over Library window".
@MainActor
final class LeftColumnView: Surface {
    private let model: ShowModel
    private let playlistsTitle = Kit.heading(Strings.text(.leftPlaylists))
    let newPlaylist = FlatButton("+", style: .bare)
    let playlists = RowList()
    private let libraryTitle = Kit.heading(Strings.text(.leftLibrary))
    let search = Kit.search(placeholder: Strings.text(.leftSearch))
    let library = RowList()
    /// The divider between the two windows of the column.
    let split = DividerView(axis: .rows, label: Strings.text(.dividerSplit))
    private var splitStart = 0.5
    /// Called when an item is clicked, so the grid scrolls to its list (Spec 10 §5).
    var onShowItem: ((String) -> Void)?
    /// The window, which opens the fields in place and the small panels (Spec 10 §10).
    weak var host: ShowWindowView?
    /// What the column says for a few seconds beside what was tried (Spec 10 §10).
    let notice = NoticeLabel()

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        newPlaylist.setAccessibilityLabel(Strings.text(.menuNewPlaylist))
        // "New playlist: the window's + button or ⌘N opens a title field in the tree".
        newPlaylist.onPress = { [weak self] in self?.beginNewPlaylist() }
        search.target = self
        search.action = #selector(searched)
        for view in [playlistsTitle, newPlaylist, playlists, libraryTitle, search, library, notice, split] as [NSView] { addSubview(view) }
        library.makeMenu = { [weak self] in
            guard let self else { return nil }
            return MenuBuilder.menu(Menus.libraryTop(cannotEditMasters: self.model.cannotEditMasters)) { [weak self] entry in self?.perform(entry, folder: "", over: nil) }
        }
        // "onto the tree's empty space moves it to the top".
        library.planDrop = { [weak model] payload in model?.plan(payload, onto: .libraryTop) ?? .none }
        library.performDrop = { [weak model] plan in model?.perform(plan, at: .left) }
        split.onBegin = { [weak self] in self?.splitStart = self?.model.settings.leftSplit ?? 0.5 }
        split.onDrag = { [weak self] delta in
            guard let self, self.bounds.height > 0 else { return }
            let start = self.splitStart
            let share = Double(delta / self.bounds.height)
            self.model.resize { $0.leftSplit = start + share }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func searched() {
        model.search(library: search.stringValue)
    }

    func refresh() {
        let cannotNew = model.cannotEditMachine
        newPlaylist.isEnabled = cannotNew == nil
        newPlaylist.reason = cannotNew.map(UnavailableWording.sentence)
        notice.show(model.notices[.left])
        needsLayout = true
        playlists.set(model.playlistRows.map { row in
            var content = RowContent()
            var spoken = [row.title]
            switch row.kind {
            case .playlist:
                content.disclosure = row.isExpanded
                content.title = row.title
                content.trailing = ShowWording.serviceDate(row.date)
                content.isSelected = row.isBrowsed
                content.isDimmed = row.isArchived
                if row.isArchived { content.tags.append((Strings.text(.tagArchived), .quiet)) }
            case .header:
                content.indent = 22
                content.title = row.title
                content.isHeading = true
            case .item:
                content.indent = 22
                content.title = row.title.isEmpty ? Strings.text(.tagMissing) : row.title
                content.isRed = row.isMissing
                content.isDimmed = row.isArchived
                if row.isMissing, !row.title.isEmpty { content.tags.append((Strings.text(.tagMissing), .red)) }
                if row.isLocal { content.tags.append((Strings.text(.tagLocal), .quiet)) }
            }
            content.hasLiveDot = row.isLive
            if row.isLive { spoken.append(Strings.text(.tagLive)) }
            spoken.append(contentsOf: content.tags.map(\.text))
            content.spoken = spoken.joined(separator: ", ")
            let view = RowView(content)
            view.performDrop = { [weak model] plan in model?.perform(plan, at: .left) }
            switch row.kind {
            case .playlist:
                view.onClick = { [weak model] option in model?.choose(playlist: row.playlist, option: option) }
                view.makeMenu = { [weak self, weak view] in self?.playlistMenu(row, over: view) }
                // "onto a playlist in the Playlists window inserts it there".
                view.planDrop = { [weak model] payload, _ in model?.plan(payload, onto: .playlist(row.playlist)) ?? .none }
            case .item, .header:
                if row.kind == .item {
                    view.onClick = { [weak self] _ in
                        self?.model.browse(.playlist(row.playlist))
                        if let item = row.itemUuid { self?.onShowItem?(item) }
                    }
                }
                view.makeMenu = { [weak self, weak view] in self?.itemMenu(row, over: view) }
                // "Items drag to reorder ... A list dragged from the Library window ... is inserted where it lands".
                if let item = row.itemUuid {
                    view.dragPayload = .item(playlist: row.playlist, item: item)
                    view.dropsBetween = true
                    view.planDrop = { [weak model] payload, below in model?.plan(payload, onto: .item(playlist: row.playlist, item: item, below: below)) ?? .none }
                }
            }
            return view
        })

        let searching = !model.librarySearch.trimmingCharacters(in: .whitespaces).isEmpty
        library.set(model.libraryRows.map { row in
            var content = RowContent()
            content.indent = CGFloat(row.depth) * 14
            content.title = row.title
            switch row.kind {
            case .folder:
                content.disclosure = row.isOpen
                content.spoken = row.title
            case .list:
                content.indent += 14
                let number = row.number.map(String.init) ?? ""
                // "the matches as a flat list with their folders".
                content.trailing = searching && !row.path.isEmpty ? "\(row.path) · \(number)" : number
                content.isSelected = row.uuid.map { model.browse.shown == .list($0) } ?? false
                content.isRevealed = row.uuid != nil && row.uuid == model.revealedList
                content.spoken = [row.title, number].joined(separator: ", ")
            }
            let view = RowView(content)
            view.performDrop = { [weak model] plan in model?.perform(plan, at: .left) }
            // "Dragging a list onto a folder moves it ..., and onto a playlist in the Playlists window inserts it
            // there. A folder dragged onto another moves into it".
            switch row.kind {
            case .folder:
                view.dragPayload = .folder(row.path)
                view.planDrop = { [weak model] payload, _ in model?.plan(payload, onto: .folder(row.path)) ?? .none }
            case .list:
                view.dragPayload = row.uuid.map(DragPayload.list)
            }
            switch row.kind {
            case .folder:
                view.onClick = { [weak model] _ in model?.toggle(folder: row.path) }
                // "Double-click or the menu renames one in place".
                view.onDoubleClick = { [weak self, weak view] in self?.perform(MenuEntry(.renameFolder), folder: row.path, over: view) }
                view.makeMenu = { [weak self, weak view] in
                    guard let self else { return nil }
                    let entries = Menus.folder(isEmpty: self.model.isEmpty(folder: row.path), cannotEditMasters: self.model.cannotEditMasters)
                    return MenuBuilder.menu(entries) { [weak self, weak view] entry in self?.perform(entry, folder: row.path, over: view) }
                }
            case .list:
                view.onClick = { [weak model] _ in if let uuid = row.uuid { model?.browse(.list(uuid)) } }
                view.makeMenu = { [weak self, weak view] in self?.listMenu(row, over: view) }
            }
            return view
        })
        // "Show in Library" brings the list's row into view.
        if let revealed = model.revealedList, let index = model.libraryRows.firstIndex(where: { $0.uuid == revealed }) {
            library.show(row: index)
        }
    }

    // MARK: - The playlists' edits (Spec 10 §5)

    /// "New playlist: the window's + button or ⌘N opens a title field in the tree; Return sends `edit playlist create "TITLE"`."
    func beginNewPlaylist() {
        guard model.cannotEditMachine == nil else { return }
        let top = NSRect(x: 4, y: 2, width: max(60, playlists.bounds.width - 8), height: RowView.height - 1)
        host?.editInPlace(over: playlists, rect: top, text: "", label: Strings.text(.fieldNewPlaylist), placeholder: Strings.text(.fieldNewPlaylist)) { [weak model] in
            model?.newPlaylist(title: $0)
        }
    }

    /// Spec 10 §5, "A playlist's menu".
    private func playlistMenu(_ row: PlaylistRow, over view: RowView?) -> NSMenu? {
        guard let entry = model.store.catalog?.playlist(uuid: row.playlist) else { return nil }
        let entries = Menus.playlist(entry, live: model.store.live, cannotSend: model.store.cannotSend, cannotEdit: model.cannotEditMachine)
        return MenuBuilder.menu(entries) { [weak self, weak view] chosen in self?.perform(chosen, playlist: entry.playlist, over: view) }
    }

    private func perform(_ entry: MenuEntry, playlist: Playlist, over view: RowView?) {
        let uuid = playlist.uuid.uuidString.lowercased()
        switch entry.kind {
        case .makeLive:
            model.makeLive(playlist: uuid)
        case .renamePlaylist:
            guard let view else { return }
            host?.editInPlace(over: view, text: playlist.title, label: Strings.text(.fieldRename, playlist.title)) { [weak model] in model?.rename(playlist: uuid, to: $0) }
        case .dateAndTime:
            host?.present(Prompts.schedule(playlist, model: model).panel, at: view)
        case .duplicatePlaylist:
            host?.present(Prompts.duplicate(playlist, model: model), at: view)
        case .archiveCopy:
            model.edit(Edits.archiveCopy(playlist: playlist.uuid), at: .left)
        case .archive:
            model.edit(Edits.archive(playlist: playlist.uuid, true), at: .left)
        case .restoreFromArchive:
            model.edit(Edits.archive(playlist: playlist.uuid, false), at: .left)
        case .deletePlaylist:
            model.deletePlaylist(uuid)
        default:
            break
        }
    }

    /// Spec 10 §5, "An item's menu".
    private func itemMenu(_ row: PlaylistRow, over view: RowView?) -> NSMenu? {
        guard let entry = model.store.catalog?.playlist(uuid: row.playlist), let uuid = row.itemUuid,
              let item = entry.playlist.items.first(where: { $0.uuid.uuidString.lowercased() == uuid }) else { return nil }
        // A linked item whose list is gone has nothing to show in the library.
        let entries = Menus.item(item, in: entry, cannotEdit: model.cannotEditMachine).filter { !($0.kind == .showInLibrary && row.isMissing) }
        return MenuBuilder.menu(entries) { [weak self, weak view] chosen in self?.perform(chosen, item: uuid, row: row, over: view) }
    }

    private func perform(_ entry: MenuEntry, item: String, row: PlaylistRow, over view: RowView?) {
        switch entry.kind {
        case .removeItem:
            model.removeItem(item, from: row.playlist)
        case .addHeaderAbove:
            guard let view else { return }
            host?.editInPlace(over: view, text: "", label: Strings.text(.fieldNewHeader), placeholder: Strings.text(.fieldNewHeader)) { [weak model] in
                model?.addHeader($0, above: item, in: row.playlist)
            }
        case .renameHeader:
            guard let view else { return }
            host?.editInPlace(over: view, text: row.title, label: Strings.text(.fieldRename, row.title)) { [weak model] in
                model?.rename(header: item, in: row.playlist, to: $0)
            }
        case .showInLibrary:
            if let list = row.listUuid { model.showInLibrary(list: list) }
        default:
            break
        }
    }

    // MARK: - The library's edits (Spec 10 §5)

    /// Spec 10 §5, "A list's menu".
    private func listMenu(_ row: LibraryRow, over view: RowView?) -> NSMenu? {
        guard let catalog = model.store.catalog, let uuid = row.uuid, let list = catalog.list(uuid: uuid) else { return nil }
        let entries = Menus.list(list, playlists: catalog.playlists, cannotEditMasters: model.cannotEditMasters, cannotEditMachine: model.cannotEditMachine)
        return MenuBuilder.menu(entries) { [weak self, weak view] chosen in self?.perform(chosen, list: list, over: view) }
    }

    private func perform(_ entry: MenuEntry, list: ListSummary, over view: RowView?) {
        switch entry.kind {
        case .addToPlaylist(let playlist):
            model.add(list: list.uuid, toPlaylist: playlist)
        case .renameList:
            guard let view else { return }
            host?.editInPlace(over: view, text: list.title, label: Strings.text(.fieldRename, list.title)) { [weak model] in model?.rename(list: list.uuid, to: $0) }
        case .duplicateList:
            model.edit(Edits.duplicate(list: list.number), at: .left)
        case .restoreVersion:
            host?.restoreVersion(of: list.uuid)
        case .deleteList:
            model.deleteList(list.uuid)
        case .newListHere:
            model.newList(in: list.folder)
        default:
            break
        }
    }

    /// A folder's menu, and with an empty path the Library's own: a folder or a list at the top.
    private func perform(_ entry: MenuEntry, folder path: String, over view: RowView?) {
        switch entry.kind {
        case .renameFolder:
            guard let view, model.cannotEditMasters == nil else { return }
            let name = LibraryTree.name(of: path)
            host?.editInPlace(over: view, text: name, label: Strings.text(.fieldRename, name)) { [weak model] in model?.rename(folder: path, to: $0) }
        case .newFolder:
            // The field opens under the folder's row, or at the top of the tree.
            let rect = view.map { NSRect(x: 14, y: $0.bounds.height + 1, width: max(60, $0.bounds.width - 14), height: RowView.height - 1) }
                ?? NSRect(x: 4, y: 2, width: max(60, library.bounds.width - 8), height: RowView.height - 1)
            host?.editInPlace(over: view ?? library, rect: rect, text: "", label: Strings.text(.fieldNewFolder), placeholder: Strings.text(.fieldNewFolder)) { [weak model] in
                model?.newFolder($0, in: path)
            }
        case .deleteFolder:
            model.edit(Edits.delete(folder: path), at: .left)
        case .newListHere:
            model.newList(in: path)
        default:
            break
        }
    }

    /// File ▸ New List (⇧⌘N): "for the selected folder, or ... at the top".
    /// The selected folder is the one the list the grid browses from the
    /// library is in (Area 13 reading: the tree has no selection of its own).
    func newList() {
        var folder: String?
        if case .list(let uuid)? = model.browse.shown { folder = model.store.catalog?.list(uuid: uuid)?.folder }
        model.newList(in: folder)
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let split = floor(bounds.height * CGFloat(model.settings.leftSplit))
        playlistsTitle.frame = NSRect(x: 14, y: 12, width: w - 60, height: 14)
        newPlaylist.frame = NSRect(x: w - 34, y: 6, width: 24, height: 24)
        playlists.frame = NSRect(x: 0, y: 34, width: w, height: max(0, split - 34))
        libraryTitle.frame = NSRect(x: 14, y: split + 12, width: w - 28, height: 14)
        search.frame = NSRect(x: 10, y: split + 34, width: w - 20, height: 24)
        // What the column says about an edit stands at its foot, over the library's last rows.
        let noticeHeight = notice.height(width: w - 28)
        notice.frame = NSRect(x: 14, y: bounds.height - noticeHeight - 8, width: w - 28, height: noticeHeight)
        library.frame = NSRect(x: 0, y: split + 64, width: w, height: max(0, bounds.height - split - 64 - (noticeHeight > 0 ? noticeHeight + 14 : 0)))
        self.split.frame = NSRect(x: 0, y: split - DividerView.thickness / 2, width: w, height: DividerView.thickness)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: floor(bounds.height * CGFloat(model.settings.leftSplit)), width: bounds.width - 1, height: 1).fill()
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem, NSMenuItemValidation {
    private nonisolated(unsafe) var run: @MainActor () -> Void = {}
    /// Whether it can be chosen now, asked each time its menu opens or its
    /// key is pressed; nil leaves it as it was set. In a menu AppKit
    /// enables by itself (the Edit menu, for its text items), this is what
    /// AppKit asks.
    nonisolated(unsafe) var isAllowed: (@MainActor () -> Bool)?

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        isAllowed?() ?? isEnabled
    }

    init(title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], _ run: @escaping @MainActor () -> Void) {
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.run = run
        keyEquivalentModifierMask = modifiers
        target = self
    }

    /// Never decoded from a file; an item that were would do nothing.
    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc private func fire() {
        run()
    }

    /// Runs it, as choosing it would: nothing happens when it can't be chosen now.
    func choose() {
        if isAllowed?() ?? isEnabled { run() }
    }
}
