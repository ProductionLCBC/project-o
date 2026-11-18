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
final class RowView: Surface {
    static let height: CGFloat = 26

    private let triangle = Kit.label(size: 9)
    private let dot = DotView()
    let title = Kit.content(Kit.label(size: 12.5))
    private let trailing = Kit.content(Kit.label(size: 11, mono: true))
    private var tags: [TagView] = []
    private let content: RowContent
    var onClick: ((_ option: Bool) -> Void)?
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
        } else {
            onClick?(event.modifierFlags.contains(.option))
        }
    }

    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    private func showMenu(_ event: NSEvent) {
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

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
    private let document = Surface()
    private(set) var rows: [RowView] = []

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        documentView = document
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

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        newPlaylist.setAccessibilityLabel(Strings.text(.menuNewPlaylist))
        // The edits of §5 come with §10's stage.
        newPlaylist.isEnabled = false
        newPlaylist.reason = Strings.text(.unavailableLater)
        search.target = self
        search.action = #selector(searched)
        for view in [playlistsTitle, newPlaylist, playlists, libraryTitle, search, library, split] as [NSView] { addSubview(view) }
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
        let cannotSend = model.store.cannotSend
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
            switch row.kind {
            case .playlist:
                view.onClick = { [weak model] option in model?.choose(playlist: row.playlist, option: option) }
                view.makeMenu = { [weak self] in self?.playlistMenu(row, cannotSend: cannotSend) }
            case .item:
                view.onClick = { [weak self] _ in
                    self?.model.browse(.playlist(row.playlist))
                    if let item = row.itemUuid { self?.onShowItem?(item) }
                }
                // Spec 10 §5, "An item's menu" — "Show in Library, for a linked item"; its edits come with §10's stage.
                if !row.isLocal, !row.isMissing, let list = row.listUuid {
                    view.makeMenu = { [weak model] in
                        let menu = NSMenu()
                        menu.addItem(ClosureMenuItem(title: Strings.text(.menuShowInLibrary)) { model?.showInLibrary(list: list) })
                        return menu
                    }
                }
            case .header:
                break
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
            switch row.kind {
            case .folder: view.onClick = { [weak model] _ in model?.toggle(folder: row.path) }
            case .list: view.onClick = { [weak model] _ in if let uuid = row.uuid { model?.browse(.list(uuid)) } }
            }
            return view
        })
        // "Show in Library" brings the list's row into view.
        if let revealed = model.revealedList, let index = model.libraryRows.firstIndex(where: { $0.uuid == revealed }) {
            library.show(row: index)
        }
    }

    /// Spec 10 §5, "A playlist's menu" — Make Live now; its edits come with §10's stage.
    private func playlistMenu(_ row: PlaylistRow, cannotSend: Unavailable?) -> NSMenu {
        let menu = NSMenu()
        let item = ClosureMenuItem(title: Strings.text(.menuMakeLive)) { [weak model] in
            guard let model, let playlist = model.store.catalog?.playlist(uuid: row.playlist), let sending = try? GridFire.makeLive(playlist).get() else { return }
            model.send(sending)
        }
        if let refusal = row.refusal {
            item.isEnabled = false
            item.toolTip = ShowWording.refusal(refusal)
        } else if let cannotSend {
            item.isEnabled = false
            item.toolTip = UnavailableWording.sentence(for: cannotSend)
        }
        menu.autoenablesItems = false
        menu.addItem(item)
        return menu
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
        library.frame = NSRect(x: 0, y: split + 64, width: w, height: max(0, bounds.height - split - 64))
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
final class ClosureMenuItem: NSMenuItem {
    private nonisolated(unsafe) var run: @MainActor () -> Void = {}

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

    /// Runs it, as choosing it would.
    func choose() {
        if isEnabled { run() }
    }
}
