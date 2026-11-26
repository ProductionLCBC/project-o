// OAppUI — Spec 11 §4, "The cue grid": the list's cues across and the channels down, drawn in one view.

import AppKit
import OApp
import OCore

/// Spec 11 §4, "The cue grid" — "fills the workspace: the list's cues
/// across, in order, and the channels down, read from left to right as the
/// list plays, as a video editor's timeline is."
///
/// The whole grid is drawn here, from `CueGridModel`, and nothing of it is a
/// child view: the band, the headers and the channel column "stay in place
/// while the grid scrolls", which is a matter of where each part is drawn.
/// `CueGridGeometry` says where a part sits and what is under the pointer.
@MainActor
final class CueGridView: Surface, EditFocus {
    private let model: ShowModel
    var machineRoot: URL? { didSet { needsDisplay = true } }
    weak var host: ShowWindowView?
    /// Opens the content popover on the selected cell (Spec 11 §4); the inspector owns it.
    var onEditContent: (() -> Void)?

    /// How far the grid is scrolled, across and down, under its fixed parts.
    private(set) var scrollX: Double = 0
    private(set) var scrollY: Double = 0
    /// The cell a drag is over, while it would take the drop.
    private var dropCell: (cue: Int, row: Int)? { didSet { needsDisplay = true } }
    /// A header being dragged to a new place: the cue, and the place it would land ahead of.
    private var reorder: (cue: Int, before: Int)? { didSet { needsDisplay = true } }
    private var pressed: (point: NSPoint, cue: Int)?
    private var elements: [NSAccessibilityElement] = []

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.panel
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.text(.editCuesGrid))
        registerForDraggedTypes(Dragging.withFiles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var grid: CueGridModel { model.editing.grid }
    private var selection: CueGridSelection { model.editing.selection }

    var geometry: CueGridGeometry {
        CueGridGeometry(column: model.settings.gridZoom, cues: grid.headers.count, folded: grid.rows.map(\.isFolded))
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: - Keeping up with the model

    func refresh() {
        clampScroll()
        // "The grid scrolls to keep the selection in view" when the selection moves; an engine event that leaves it
        // where it was leaves the grid scrolled where the operator put it.
        if selection != scrolledFor {
            scrolledFor = selection
            keepSelectionInView()
        }
        rebuildAccessibility()
        needsDisplay = true
    }

    /// The selection the grid last scrolled to show.
    private var scrolledFor: CueGridSelection?

    /// Spec 11 §4 — a popover that hangs from the selected cell shows it first.
    func scrollSelectionIntoView() {
        keepSelectionInView()
        needsDisplay = true
    }

    private func clampScroll() {
        let g = geometry
        scrollX = min(max(0, scrollX), max(0, g.width - Double(bounds.width)))
        scrollY = min(max(0, scrollY), max(0, g.height - Double(bounds.height)))
    }

    /// "The grid scrolls to keep the selection in view".
    private func keepSelectionInView() {
        guard bounds.width > 0, let lead = selection.lead ?? selection.first(in: grid.headers.map(\.uuid)), let cue = grid.cue(of: lead) else { return }
        let g = geometry
        scrollX = g.scrollX(toShow: cue, from: scrollX, viewWidth: Double(bounds.width))
        if case .channel(let channel) = selection.row, let row = grid.row(of: channel) {
            scrollY = g.scrollY(toShow: row, from: scrollY, viewHeight: Double(bounds.height))
        }
        clampScroll()
    }

    override func layout() {
        super.layout()
        clampScroll()
        rebuildAccessibility()
    }

    // MARK: - The pointer

    private func hit(_ event: NSEvent) -> CueGridGeometry.Hit {
        let point = convert(event.locationInWindow, from: nil)
        return geometry.hit(x: Double(point.x), y: Double(point.y), scrollX: scrollX, scrollY: scrollY)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.control) { return showMenu(event) }
        let flags = event.modifierFlags
        pressed = nil
        selectOnUp = nil
        switch hit(event) {
        case .cell(let cue, let row):
            model.editing.click(cue: cue, row: .channel(grid.rows[row].channel), shift: flags.contains(.shift), command: flags.contains(.command))
            // "A double-click on a cell opens the popover too".
            if event.clickCount == 2, !flags.contains(.shift), !flags.contains(.command) { onEditContent?() }
        case .header(let cue):
            // "A drag that starts on a selected header ... moves every selected cue": a plain press on one of several
            // selected headers keeps them, and selects that cue alone only when it comes up without a drag.
            let plain = !flags.contains(.shift) && !flags.contains(.command)
            if plain, selection.isMulti, selection.cues.contains(grid.headers[cue].uuid) {
                selectOnUp = cue
            } else {
                model.editing.click(cue: cue, row: .header, shift: flags.contains(.shift), command: flags.contains(.command))
            }
            pressed = (convert(event.locationInWindow, from: nil), cue)
        case .band(let cue):
            // "A click on a band selects its run's cues ... and a band drags as its headers do".
            model.editing.clickBand(cue: cue, shift: flags.contains(.shift), command: flags.contains(.command))
            pressed = (convert(event.locationInWindow, from: nil), cue)
        case .add:
            model.editing.newCue(atEnd: true)
        case .fold(let row):
            model.editing.toggleFold(row: row)
        case .eye(let row):
            // A row for a channel number no channel has has no eye: its name answers the click.
            if grid.rows[row].exists { model.editing.toggleHidden(row: row) } else { model.editing.select(row: .channel(grid.rows[row].channel)) }
        case .channel(let row):
            model.editing.select(row: .channel(grid.rows[row].channel))
        case .corner, .nothing:
            break
        }
    }

    /// A selected header pressed among several: selected alone if the press ends without a drag.
    private var selectOnUp: Int?

    /// "Headers drag to a new place".
    override func mouseDragged(with event: NSEvent) {
        guard let pressed, model.editing.cannotEdit == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard reorder != nil || abs(point.x - pressed.point.x) > 5 else { return }
        let g = geometry
        let content = Double(point.x) - CueGridGeometry.channelColumn + scrollX
        let before = min(g.cues, max(0, Int((content / g.column).rounded())))
        reorder = (pressed.cue, before)
    }

    override func mouseUp(with event: NSEvent) {
        let alone = selectOnUp
        defer {
            pressed = nil
            selectOnUp = nil
        }
        guard let drop = reorder else {
            if let alone { model.editing.click(cue: alone, row: .header) }
            return
        }
        reorder = nil
        model.editing.drop(cue: drop.cue, before: drop.before)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showMenu(event)
    }

    private func showMenu(_ event: NSEvent) {
        let found = hit(event)
        // The menu acts on the selection: a cue outside it is selected first.
        switch found {
        case .cell(let cue, let row):
            if !selection.cues.contains(grid.headers[cue].uuid) || selection.row != .channel(grid.rows[row].channel) {
                model.editing.click(cue: cue, row: .channel(grid.rows[row].channel))
            }
        case .header(let cue):
            if !selection.cues.contains(grid.headers[cue].uuid) || selection.row != .header { model.editing.click(cue: cue, row: .header) }
        default:
            return
        }
        NSMenu.popUpContextMenu(menuNow, with: event, for: self)
    }

    /// "A header's menu: Fire; New Cue After; Duplicate; Duplicate Section;
    /// Move Earlier; Move Later; Delete; Open in Text Editor ... A cell's
    /// menu starts with Write…, or Edit Content… on a write, then Clear and
    /// Hold (below), then the header's items." For the selection as it stands.
    var menuNow: NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let editing = model.editing
        let cannot = editing.cannotEdit
        func add(_ key: StringKey, enabled: Bool = true, _ run: @escaping @MainActor () -> Void) {
            let item = ClosureMenuItem(title: Strings.text(key), run)
            item.isEnabled = enabled
            if !enabled, let cannot { item.toolTip = EditModeWording.readOnly(cannot) }
            menu.addItem(item)
        }
        let canEdit = cannot == nil
        if case .channel(let channel) = selection.row, !selection.isMulti {
            let says = editing.selectedCues.first.map { CueSays.about(channel, in: $0) }
            let exists = grid.row(of: channel).map { grid.rows[$0].exists } ?? false
            add(says?.writesContent == true ? .editMenuEditContent : .editMenuWrite, enabled: canEdit && exists) { [weak self] in self?.onEditContent?() }
            add(.editStateClear, enabled: canEdit && exists) { [weak editing] in editing?.set(.clear) }
            add(.editStateHold, enabled: canEdit) { [weak editing] in editing?.set(.hold) }
            menu.addItem(.separator())
        }
        var canFire = false
        if case .fires = editing.fireNote { canFire = true }
        add(.editFire, enabled: canFire) { [weak editing] in editing?.fire() }
        menu.addItem(.separator())
        add(.editMenuNewCueAfter, enabled: canEdit) { [weak editing] in editing?.newCue(atEnd: false) }
        add(.editMenuDuplicate, enabled: canEdit) { [weak editing] in editing?.duplicate() }
        add(.menuDuplicateSection, enabled: canEdit && !selection.isMulti) { [weak editing] in editing?.duplicateSection() }
        add(.editMenuMoveEarlier, enabled: canEdit) { [weak editing] in editing?.moveSelected(earlier: true) }
        add(.editMenuMoveLater, enabled: canEdit) { [weak editing] in editing?.moveSelected(earlier: false) }
        add(.editMenuDelete, enabled: canEdit) { [weak editing] in editing?.deleteCues() }
        menu.addItem(.separator())
        // "Open in Text Editor ... stays disabled until it lands" (Spec 11 §11).
        let text = ClosureMenuItem(title: Strings.text(.editCuesOpenText)) {}
        text.isEnabled = false
        text.toolTip = Strings.text(.unavailableLater)
        menu.addItem(text)
        return menu
    }

    // MARK: - Scrolling and zoom

    override func scrollWheel(with event: NSEvent) {
        let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollX -= Double(event.scrollingDeltaX) * scale
        scrollY -= Double(event.scrollingDeltaY) * scale
        clampScroll()
        rebuildAccessibility()
        needsDisplay = true
    }

    /// "a pinch on the grid does the same".
    override func magnify(with event: NSEvent) {
        model.editing.pinch(by: Double(event.magnification))
    }

    // MARK: - The keys (Spec 11 §2, "Keys")

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift)
        switch event.keyCode {
        case 123: model.editing.move(.left, extend: shift)
        case 124: model.editing.move(.right, extend: shift)
        case 126: model.editing.move(.up, extend: shift)
        case 125: model.editing.move(.down, extend: shift)
        // "Delete or Forward Delete returns the selected cells to Hold ... With the header row selected it deletes the selected cues".
        case 51, 117: model.editing.delete()
        case 36, 76:
            // ⌃Return opens the selected thing's menu, and ⌥Return activates it (Spec 10 §15).
            // Spec 11 §2 — "Return opens the selected cell's content (§4)".
            if flags.contains(.control) {
                menuNow.popUp(positioning: nil, at: selectionAnchor, in: self)
            } else if case .channel = selection.row {
                onEditContent?()
            } else {
                super.keyDown(with: event)
            }
        default: super.keyDown(with: event)
        }
    }

    /// Where the selected cell or header sits in the view, for a menu or a popover.
    var selectionAnchor: NSPoint {
        let rect = selectionRect ?? NSRect(x: CueGridGeometry.channelColumn, y: CueGridGeometry.band, width: 10, height: 10)
        return NSPoint(x: rect.minX + 8, y: rect.maxY)
    }

    /// The selected cell's rectangle, or the first selected cue's header's.
    var selectionRect: NSRect? {
        guard let uuid = selection.first(in: grid.headers.map(\.uuid)), let cue = grid.cue(of: uuid) else { return nil }
        let g = geometry
        let x = g.x(cue: cue) - scrollX
        if case .channel(let channel) = selection.row, let row = grid.row(of: channel) {
            return NSRect(x: x, y: g.y(row: row) - scrollY, width: g.column, height: g.rowHeight(row))
        }
        return NSRect(x: x, y: CueGridGeometry.band, width: g.column, height: g.header)
    }

    // MARK: - Drops (Spec 11 §4, "Drops")

    private func cell(under info: NSDraggingInfo) -> (cue: Int, row: Int)? {
        let point = convert(info.draggingLocation, from: nil)
        guard case .cell(let cue, let row) = geometry.hit(x: Double(point.x), y: Double(point.y), scrollX: scrollX, scrollY: scrollY) else { return nil }
        // "The headers and a "No channel" row take no drop."
        return grid.rows[row].exists ? (cue, row) : nil
    }

    /// Whether a cell would take what is dragged: one media item, or one file to import.
    private func takes(_ payload: DragPayload) -> Bool {
        guard model.editing.cannotEdit == nil else { return false }
        switch payload {
        case .media: return true
        case .files(let paths): return paths.count == 1 && model.cannotImport == nil
        default: return false
        }
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = Dragging.payload(from: info.draggingPasteboard), takes(payload), let cell = cell(under: info) else {
            dropCell = nil
            return []
        }
        // "The cell under the pointer is outlined while it would take the drop."
        if dropCell?.cue != cell.cue || dropCell?.row != cell.row { dropCell = cell }
        return .copy
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropCell = nil }
    override func draggingEnded(_ sender: NSDraggingInfo) { dropCell = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropCell = nil }
        guard let payload = Dragging.payload(from: sender.draggingPasteboard), let cell = cell(under: sender) else { return false }
        return accept(payload, cue: cell.cue, row: cell.row)
    }

    /// Lands a drag on a cell, as letting go of it there would.
    @discardableResult
    func accept(_ payload: DragPayload, cue: Int, row: Int) -> Bool {
        guard takes(payload), grid.headers.indices.contains(cue), grid.rows.indices.contains(row), grid.rows[row].exists else { return false }
        let channel = grid.rows[row].channel
        switch payload {
        case .media(let id):
            // "A media item dragged from the Browser onto a cell writes it there".
            model.editing.pick(media: id, cue: cue, channel: channel)
            model.editing.click(cue: cue, row: .channel(channel))
            return true
        case .files:
            // "A file from the Finder dropped on a cell is imported, then written, as on a cue in show mode ...,
            // without the channel popover, since the cell names the channel."
            guard let section = model.editing.section else { return false }
            let header = grid.headers[cue]
            guard let drop = model.land(model.plan(payload, ontoCue: header, in: section), onCue: header, in: section) else { return false }
            model.write(drop, into: header, in: section, channel: channel)
            model.editing.click(cue: cue, row: .channel(channel))
            return true
        default:
            return false
        }
    }

    // MARK: - VoiceOver (Spec 11 §10)

    /// "The cue grid is a table. Its column headers are the cues ...; its row
    /// headers are the channels ...; and a cell says what the cue does
    /// there". Each is an element of its own, in the grid's reading order.
    private func rebuildAccessibility() {
        let g = geometry
        let catalog = model.store.catalog
        var built: [NSAccessibilityElement] = []
        func element(_ label: String, _ rect: NSRect, role: NSAccessibility.Role) {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(role)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(NSRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height))
            built.append(element)
        }
        for (index, header) in grid.headers.enumerated() {
            element(EditModeWording.header(header), NSRect(x: g.x(cue: index) - scrollX, y: CueGridGeometry.band, width: g.column, height: g.header), role: .button)
        }
        for (rowIndex, row) in grid.rows.enumerated() {
            let y = g.y(row: rowIndex) - scrollY
            let eye = CueGridGeometry.eyeWidth
            element(EditModeWording.rowSpoken(row), NSRect(x: 0, y: y, width: CueGridGeometry.channelColumn - (row.exists ? eye : 0), height: g.rowHeight(rowIndex)),
                    role: .staticText)
            if row.exists {
                element(EditModeWording.eye(row), NSRect(x: CueGridGeometry.channelColumn - eye, y: y, width: eye, height: g.rowHeight(rowIndex)), role: .button)
            }
            for (cue, cell) in grid.cells[rowIndex].enumerated() {
                element(EditModeWording.cell(cell, cue: cue + 1, row: row, catalog: catalog),
                        NSRect(x: g.x(cue: cue) - scrollX, y: y, width: g.column, height: g.rowHeight(rowIndex)), role: .button)
            }
        }
        elements = built
    }

    override func accessibilityChildren() -> [Any]? { elements }

    /// What VoiceOver reads, in order, for a test.
    var spoken: [String] { elements.compactMap { $0.accessibilityLabel() } }

    // MARK: - Drawing

    private func picture(_ file: String?) -> NSImage? {
        guard let file, let root = machineRoot else { return nil }
        return PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] _ in self?.needsDisplay = true }
    }

    private func text(_ string: String, in rect: NSRect, size: CGFloat = 11, weight: NSFont.Weight = .regular, color: NSColor,
                      alignment: NSTextAlignment = .left, lines: Int = 1, mono: Bool = false) {
        guard rect.width > 4, rect.height > 4, !string.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let font: NSFont = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        let options: NSString.DrawingOptions = lines == 1 ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine] : [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        (string as NSString).draw(with: rect, options: options, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style], context: nil)
    }

    /// Draws a picture to fill `rect`, cut to its shape.
    private func fillPicture(_ image: NSImage, in rect: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let drawn = NSRect(x: rect.midX - size.width * scale / 2, y: rect.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale)
        image.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// The small mark that says a cell carries attribute writes: a diamond, so it isn't told by color alone.
    private func mark(at center: NSPoint) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x, y: center.y - 4))
        path.line(to: NSPoint(x: center.x + 4, y: center.y))
        path.line(to: NSPoint(x: center.x, y: center.y + 4))
        path.line(to: NSPoint(x: center.x - 4, y: center.y))
        path.close()
        Palette.browsing.setFill()
        path.fill()
    }

    private func drawTile(_ cell: CueGridCell, in tile: NSRect, showsText: Bool) {
        let shape = NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        var missing = false
        switch cell.content {
        case .media(_, let item)?:
            Palette.raisedHigh.setFill()
            tile.fill()
            if let image = picture(item?.tile) { fillPicture(image, in: tile) }
            if let item { missing = item.overlay != .none } else { missing = true }
            if showsText {
                let name = item?.name ?? Strings.text(.editCellMissing)
                NSColor.black.withAlphaComponent(0.45).setFill()
                NSRect(x: tile.minX, y: tile.maxY - 18, width: tile.width, height: 18).fill()
                text(name, in: NSRect(x: tile.minX + 6, y: tile.maxY - 16, width: tile.width - 12, height: 14), color: .white)
            }
        case .text(let words)?:
            NSColor.black.setFill()
            tile.fill()
            if showsText {
                text(words, in: tile.insetBy(dx: 8, dy: 6), weight: .semibold, color: .white, alignment: .center, lines: 3)
            }
        case .slide?, .input?:
            Palette.raisedHigh.setFill()
            tile.fill()
            if showsText, let content = cell.content {
                text(EditModeWording.content(content), in: NSRect(x: tile.minX + 6, y: tile.midY - 7, width: tile.width - 12, height: 14), color: Palette.dimText, alignment: .center)
            }
        case nil:
            break
        }
        NSGraphicsContext.restoreGraphicsState()
        var isText = false
        if case .text? = cell.content { isText = true }
        (missing ? Palette.live : (isText ? NSColor(white: 1, alpha: 0.3) : Palette.hairline)).setStroke()
        shape.lineWidth = 1
        if missing { shape.setLineDash([4, 3], count: 2, phase: 0) }
        shape.stroke()
        guard showsText else { return }
        // "A badge in the tile's corner gives the transition rider's duration, and a mark beside it says the write carries other riders."
        var right = tile.maxX - 4
        if let ms = cell.badgeMs {
            let words = EditModeWording.badge(ms: ms)
            let width = ceil((words as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5)]).width) + 10
            let badge = NSRect(x: right - width, y: tile.minY + 4, width: width, height: 16)
            NSColor.black.withAlphaComponent(0.65).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
            text(words, in: NSRect(x: badge.minX, y: badge.minY + 1.5, width: width, height: 13), size: 10.5, color: Palette.text, alignment: .center)
            right = badge.minX - 4
        }
        if cell.hasMark { mark(at: NSPoint(x: right - 5, y: tile.minY + 12)) }
    }

    private func drawCell(_ cell: CueGridCell, in rect: NSRect, folded: Bool, showsText: Bool) {
        let mid = rect.midY
        let bar = NSColor(white: 1, alpha: 0.17)
        switch cell.state {
        case .write:
            if cell.hasTail {
                bar.setFill()
                NSRect(x: rect.maxX - 8, y: mid - 1.5, width: 8, height: 3).fill()
            }
            if folded {
                // "In a folded row a write is a strip of its tile".
                let strip = NSRect(x: rect.minX + 5, y: mid - 6, width: rect.width - 10, height: 12)
                let path = NSBezierPath(roundedRect: strip, xRadius: 3, yRadius: 3)
                if case .text? = cell.content {
                    NSColor.black.setFill()
                    path.fill()
                    NSColor(white: 1, alpha: 0.3).setStroke()
                } else {
                    Palette.raisedHigh.setFill()
                    path.fill()
                    if case .media(_, let item)? = cell.content, let image = picture(item?.tile) {
                        NSGraphicsContext.saveGraphicsState()
                        path.addClip()
                        fillPicture(image, in: strip)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    Palette.hairline.setStroke()
                }
                path.lineWidth = 1
                path.stroke()
                if cell.hasMark { mark(at: NSPoint(x: strip.maxX - 6, y: mid)) }
            } else {
                let width = rect.width - 12
                drawTile(cell, in: NSRect(x: rect.minX + 6, y: rect.minY + 6, width: width, height: width * 9 / 16), showsText: showsText)
            }
        case .hold:
            // "a bar through the cell while the channel holds something there, and nothing while it holds nothing".
            if cell.isHolding {
                bar.setFill()
                NSRect(x: rect.minX, y: mid - 1.5, width: rect.width, height: 3).fill()
            }
            if cell.hasMark { mark(at: NSPoint(x: rect.midX, y: mid)) }
        case .clear:
            // "the bar ends at a cap in the cell's middle, with the word "Clear"".
            if cell.endsBar {
                bar.setFill()
                NSRect(x: rect.minX, y: mid - 1.5, width: rect.width / 2, height: 3).fill()
            }
            let capHeight: CGFloat = folded ? 12 : 16
            Palette.dimText.setFill()
            NSBezierPath(roundedRect: NSRect(x: rect.midX - 1, y: mid - capHeight / 2, width: 2, height: capHeight), xRadius: 1, yRadius: 1).fill()
            if !folded, showsText {
                text(Strings.text(.editCuesClear), in: NSRect(x: rect.midX + 8, y: mid - 7, width: rect.width / 2 - 10, height: 14), color: Palette.faintText)
            }
            if cell.hasMark { mark(at: NSPoint(x: rect.midX - 10, y: mid)) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let g = geometry
        let grid = self.grid
        let column = CGFloat(g.column)
        let headerTop = CGFloat(CueGridGeometry.band)
        let headerHeight = CGFloat(g.header)
        let top = headerTop + headerHeight
        let left = CGFloat(CueGridGeometry.channelColumn)
        let selected = Set(grid.headers.indices.filter { selection.cues.contains(grid.headers[$0].uuid) })
        let showsText = g.showsText
        func x(_ cue: Int) -> CGFloat { CGFloat(g.x(cue: cue) - scrollX) }
        let visible = grid.headers.indices.filter { x($0) + column > left && x($0) < bounds.width }

        // The cells, under the fixed parts.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: left, y: top, width: max(0, bounds.width - left), height: max(0, bounds.height - top))).addClip()
        for (rowIndex, row) in grid.rows.enumerated() {
            let y = CGFloat(g.y(row: rowIndex) - scrollY)
            let height = CGFloat(g.rowHeight(rowIndex))
            guard y + height > top, y < bounds.height else { continue }
            for cue in visible {
                let rect = NSRect(x: x(cue), y: y, width: column, height: height)
                if selected.contains(cue) {
                    Palette.selection.withAlphaComponent(0.06).setFill()
                    rect.fill()
                }
                drawCell(grid.cells[rowIndex][cue], in: rect, folded: row.isFolded, showsText: showsText)
                // Spec 11 §4 — a hidden row's "cells dim".
                if row.isHidden {
                    Palette.panel.withAlphaComponent(0.6).setFill()
                    rect.fill()
                }
                Palette.hairline.setFill()
                NSRect(x: rect.maxX - 1, y: y, width: 1, height: height).fill()
                NSRect(x: rect.minX, y: rect.maxY - 1, width: column, height: 1).fill()
                let isSelected = selected.contains(cue) && selection.row == .channel(row.channel)
                let isDrop = dropCell?.cue == cue && dropCell?.row == rowIndex
                if isDrop {
                    Palette.selection.withAlphaComponent(0.16).setFill()
                    rect.fill()
                }
                if isSelected || isDrop {
                    Palette.selection.setStroke()
                    let path = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                    path.lineWidth = 2 * Look.outlineScale
                    path.stroke()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // The channel column, fixed at the left.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: top, width: left, height: max(0, bounds.height - top))).addClip()
        for (rowIndex, row) in grid.rows.enumerated() {
            let y = CGFloat(g.y(row: rowIndex) - scrollY)
            let height = CGFloat(g.rowHeight(rowIndex))
            guard y + height > top, y < bounds.height else { continue }
            let rect = NSRect(x: 0, y: y, width: left, height: height)
            (selection.row == .channel(row.channel) ? Palette.raised : Palette.panel).setFill()
            rect.fill()
            // The fold control: an arrow that points across while the row is folded and down while it is open.
            let arrow = NSBezierPath()
            if row.isFolded {
                arrow.move(to: NSPoint(x: 12, y: rect.midY - 4))
                arrow.line(to: NSPoint(x: 17, y: rect.midY))
                arrow.line(to: NSPoint(x: 12, y: rect.midY + 4))
            } else {
                arrow.move(to: NSPoint(x: 10, y: rect.midY - 2.5))
                arrow.line(to: NSPoint(x: 18, y: rect.midY - 2.5))
                arrow.line(to: NSPoint(x: 14, y: rect.midY + 3))
            }
            arrow.close()
            Palette.dimText.setFill()
            arrow.fill()
            text(String(row.channel), in: NSRect(x: 24, y: rect.midY - 7, width: 18, height: 14), color: Palette.faintText, alignment: .right, mono: true)
            let eye = CGFloat(CueGridGeometry.eyeWidth)
            text(EditModeWording.row(row), in: NSRect(x: 50, y: rect.midY - 7, width: left - 58 - (row.exists ? eye - 6 : 0), height: 14),
                 color: !row.exists ? Palette.browsing : (row.isFolded || row.isHidden ? Palette.dimText : Palette.text))
            // Spec 11 §4 — "an eye that hides the channel from the Preview monitor's picture alone, as a timeline hides a track".
            if row.exists, let symbol = NSImage(systemSymbolName: row.isHidden ? "eye.slash" : "eye", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)) {
                let tint = row.isHidden ? Palette.browsing : Palette.faintText
                let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
                    symbol.draw(in: bounds)
                    tint.set()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: left - eye + (eye - symbol.size.width) / 2, y: rect.midY - symbol.size.height / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
            Palette.hairline.setFill()
            NSRect(x: 0, y: rect.maxY - 1, width: left, height: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The band and the headers, fixed at the top.
        Palette.panel.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: top).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: left, y: 0, width: max(0, bounds.width - left), height: top)).addClip()
        // "over each run of cues that share a section, the section's name under a rule of its color".
        for run in grid.runs {
            let rect = NSRect(x: x(run.first), y: 0, width: column * CGFloat(run.count), height: headerTop)
            guard rect.maxX > left, rect.minX < bounds.width else { continue }
            (Palette.section(run.hue) ?? Palette.faintText).setFill()
            NSRect(x: rect.minX, y: 0, width: rect.width - 1, height: 3).fill()
            // The name stays in view while any of its run does.
            let nameX = max(rect.minX, left) + 8
            text(run.name, in: NSRect(x: nameX, y: 7, width: max(0, rect.maxX - nameX - 6), height: 14), color: Palette.dimText)
            Palette.hairline.setFill()
            NSRect(x: rect.maxX - 1, y: 0, width: 1, height: headerTop).fill()
        }
        for cue in visible {
            let header = grid.headers[cue]
            let rect = NSRect(x: x(cue), y: headerTop, width: column, height: headerHeight)
            if selected.contains(cue) {
                Palette.selection.withAlphaComponent(0.16).setFill()
                rect.fill()
            }
            // The line with its number, the live dot and its trigger.
            let number = String(header.number)
            text(number, in: NSRect(x: rect.minX + 8, y: rect.minY + 7, width: column - 16, height: 14), color: Palette.faintText, mono: true)
            let numberWidth = ceil((number as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width)
            if header.isLive {
                Palette.live.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.minX + 8 + numberWidth + 5, y: rect.minY + 10.5, width: 7, height: 7)).fill()
            }
            if showsText {
                // The trigger takes what the number and the dot leave of the line.
                let from = rect.minX + 8 + numberWidth + (header.isLive ? 18 : 6)
                text(ShowWording.trigger(header), in: NSRect(x: from, y: rect.minY + 7, width: max(0, rect.maxX - 8 - from), height: 14),
                     color: header.isArmed ? Palette.browsing : Palette.faintText, alignment: .right)
            }
            // "the cue's thumbnail on the thumbnail stack ..., which stands where a title would".
            let thumb = NSRect(x: rect.minX + 8, y: rect.minY + 26, width: column - 16, height: (column - 16) * 9 / 16)
            let shape = NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3)
            Palette.well.setFill()
            shape.fill()
            if let image = picture(header.thumbnail) {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                let size = image.size
                let scale = min(thumb.width / max(1, size.width), thumb.height / max(1, size.height))
                image.draw(in: NSRect(x: thumb.midX - size.width * scale / 2, y: thumb.midY - size.height * scale / 2, width: size.width * scale, height: size.height * scale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                NSGraphicsContext.restoreGraphicsState()
            } else if showsText, let words = header.text {
                // Until the engine's file arrives, the cue's text on black, as the show grid shows it.
                text(words, in: thumb.insetBy(dx: 6, dy: 4), size: 10, color: Palette.dimText, alignment: .center, lines: 3)
            }
            Palette.hairline.setStroke()
            shape.lineWidth = 1
            shape.stroke()
            if showsText {
                text(header.label, in: NSRect(x: rect.minX + 8, y: thumb.maxY + 4, width: column - 16, height: 14),
                     color: selected.contains(cue) ? Palette.text : Palette.dimText)
            }
            Palette.hairline.setFill()
            NSRect(x: rect.maxX - 1, y: headerTop, width: 1, height: headerHeight).fill()
            // "The live cue's header is underlined in red; a selected cue's is underlined in blue".
            if header.isLive {
                Palette.live.setFill()
                NSRect(x: rect.minX, y: rect.maxY - (selected.contains(cue) ? 4 : 2), width: column - 1, height: 2).fill()
            }
            if selected.contains(cue) {
                Palette.selection.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: column - 1, height: 2).fill()
                if selection.row == .header, window?.firstResponder === self {
                    Palette.selection.setStroke()
                    let ring = NSBezierPath(rect: rect.insetBy(dx: 1, dy: 1))
                    ring.lineWidth = 2 * Look.outlineScale
                    ring.stroke()
                }
            }
        }
        // "After the last cue, a + header adds a cue at the end."
        let addX = x(grid.headers.count)
        if addX < bounds.width {
            let box = NSRect(x: addX + (CGFloat(CueGridGeometry.addColumn) - 36) / 2, y: headerTop + (headerHeight - 36) / 2, width: 36, height: 36)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            Palette.hairlineStrong.setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
            text("+", in: NSRect(x: box.minX, y: box.midY - 12, width: 36, height: 22), size: 18, color: Palette.faintText, alignment: .center)
        }
        // A header being dragged: where it would land.
        if let reorder {
            Palette.selection.setFill()
            NSRect(x: x(reorder.before) - 1, y: headerTop, width: 2, height: headerHeight).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The corner, and the lines where the fixed parts meet what scrolls.
        Palette.panel.setFill()
        NSRect(x: 0, y: 0, width: left, height: top).fill()
        let heading = NSAttributedString(string: Strings.text(.editCuesChannelHeading).uppercased(), attributes: [
            .kern: 0.8, .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Palette.faintText,
        ])
        heading.draw(at: NSPoint(x: 12, y: headerTop + (headerHeight - 13) / 2))
        Palette.hairline.setFill()
        NSRect(x: 0, y: headerTop - 1, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: top - 1, width: bounds.width, height: 1).fill()
        Palette.hairlineStrong.setFill()
        NSRect(x: left - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}
