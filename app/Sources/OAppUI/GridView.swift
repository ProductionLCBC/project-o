// OAppUI — Spec 10 §6, the cue grid.

import AppKit
import OApp
import OCore

/// Pictures the engine wrote under the machine root (cue thumbnails, pool
/// tiles), read off the main thread and kept by path, so the main thread
/// never waits on a file (Spec 10 §1).
@MainActor
final class PictureStore {
    static let shared = PictureStore()
    private var pictures: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var waiting: [String: [(NSImage) -> Void]] = [:]

    /// The picture at `url` when it has been read; otherwise nil, and `ready` is called once it has.
    func picture(at url: URL, ready: @escaping (NSImage) -> Void) -> NSImage? {
        let key = url.path
        if let picture = pictures[key] { return picture }
        waiting[key, default: []].append(ready)
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        DispatchQueue.global(qos: .userInitiated).async {
            let data = try? Data(contentsOf: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(key)
                    guard let data, let picture = NSImage(data: data) else {
                        self.waiting[key] = nil
                        return
                    }
                    self.pictures[key] = picture
                    for call in self.waiting.removeValue(forKey: key) ?? [] { call(picture) }
                }
            }
        }
        return nil
    }

    /// Forgets a file that was written again.
    func forget(_ url: URL) {
        pictures[url.path] = nil
    }
}

/// Spec 10 §6, "The chips" — "each state with its own shape: filled blue for
/// a new value, outlined grey for held, amber with a diagonal stripe for a
/// redundant write, and struck through for a clear. A dot on a chip marks
/// attribute writes, listed on hover."
@MainActor
final class ChipView: NSView {
    static let size = NSSize(width: 20, height: 16)
    private let chip: CueChip

    init(_ chip: CueChip, label: String) {
        self.chip = chip
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let words = ShowWording.chip(chip, label: label)
        toolTip = words
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5)
        var text = Palette.dimText
        switch chip.state {
        case .new:
            Palette.selection.setFill()
            path.fill()
            text = .white
        case .held:
            Palette.faintText.setStroke()
            path.lineWidth = Look.outlineScale
            path.stroke()
        case .redundant:
            Palette.browsing.withAlphaComponent(0.28).setFill()
            path.fill()
            Palette.browsing.setStroke()
            path.lineWidth = 1
            path.stroke()
            let stripe = NSBezierPath()
            stripe.move(to: NSPoint(x: rect.minX + 2, y: rect.maxY - 2))
            stripe.line(to: NSPoint(x: rect.maxX - 2, y: rect.minY + 2))
            stripe.lineWidth = 1.5
            stripe.stroke()
            text = Palette.browsing
        case .clear:
            Palette.faintText.setStroke()
            path.lineWidth = Look.outlineScale
            path.stroke()
        }
        let number = "\(chip.channel)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: text]
        let size = number.size(withAttributes: attributes)
        number.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if chip.state == .clear {
            // Struck through.
            Palette.dimText.setStroke()
            let strike = NSBezierPath()
            strike.move(to: NSPoint(x: rect.minX - 1, y: rect.midY + 3))
            strike.line(to: NSPoint(x: rect.maxX + 1, y: rect.midY - 3))
            strike.lineWidth = 1.5
            strike.stroke()
        }
        if !chip.attributes.isEmpty {
            // "A dot on a chip marks attribute writes".
            Palette.text.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 5, y: 0, width: 5, height: 5)).fill()
        }
    }
}

/// Spec 10 §6, "A cue cell".
@MainActor
final class CueCellView: Surface {
    /// Wide enough for a trigger with a time and an advance in a language 40% longer than English (Spec 10 §18).
    static let width: CGFloat = 212
    static func height(settings: ViewSettings) -> CGFloat {
        (settings.showsThumbnails ? 110 : 0) + (settings.showsChips ? 24 : 0) + 30 + (settings.showsNotes ? 16 : 0)
    }

    let cell: CueCell
    let section: GridSection
    private let model: ShowModel
    private let picture = NSImageView()
    private let text = Kit.content(Kit.label(size: 11.5, weight: .medium))
    private var chips: [NSView] = []
    let label = Kit.content(Kit.label(size: 12.5, weight: .semibold))
    let trigger = Kit.label(size: 11, mono: true)
    private let note = Kit.content(Kit.label(size: 10.5))
    private var tags: [TagView] = []
    private let settings: ViewSettings
    var onMenu: ((CueCellView, NSEvent) -> Void)?
    /// Spec 10 §6, "Double-click" — the second press of a double-click, which fired nothing.
    var onDoubleClick: ((CueCellView) -> Void)?
    /// Spec 10 §6, "Drops on the grid" — what the cell says about a drop: an import's progress with Cancel, or why nothing was written.
    let dropNote = DropNoteView()
    /// What a drag let go here would do, and doing it.
    var planDrop: ((CueCellView, DragPayload) -> DropPlan)?
    var performDrop: ((CueCellView, DropPlan) -> Void)?
    private(set) var isMarked = false { didSet { needsDisplay = true } }

    /// Where a field over the cell goes when its words are edited in place:
    /// over the picture, or over the whole cell when the grid is compact.
    var editRect: NSRect { settings.showsThumbnails ? picture.frame : bounds }

    init(cell: CueCell, section: GridSection, model: ShowModel, machineRoot: URL?) {
        self.cell = cell
        self.section = section
        self.model = model
        settings = model.settings
        super.init(frame: .zero)
        radius = 9
        fill = cell.matchesSearch ? Palette.selection.withAlphaComponent(0.20).blended(withFraction: 0.5, of: Palette.raised) : Palette.raised
        // "a red outline on the live cue, with no tag, and nothing else in the grid drawn as an outline of its weight".
        if cell.isLive {
            outline = Palette.live
            outlineWidth = 2.5
        }
        alphaValue = section.refusal != nil || section.isRemoved ? 0.5 : 1

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.backgroundColor = Palette.well.cgColor
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.setAccessibilityElement(false)
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byWordWrapping
        text.alignment = .center
        text.cell?.wraps = true
        text.cell?.truncatesLastVisibleLine = true
        text.stringValue = cell.text ?? ""
        text.setAccessibilityElement(false)
        if settings.showsThumbnails {
            addSubview(picture)
            addSubview(text)
            if let file = cell.thumbnail, let root = machineRoot {
                let shown = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] picture in
                    self?.picture.image = picture
                    self?.text.isHidden = true
                }
                picture.image = shown
                text.isHidden = shown != nil
            }
        }
        if settings.showsChips {
            let shown = cell.shownChips
            chips = shown.chips.map { ChipView($0, label: model.channelLabel($0.channel)) }
            if shown.more > 0 {
                let more = Kit.label(Strings.text(.gridMore, shown.more), size: 10, weight: .medium, color: Palette.dimText, mono: true)
                more.toolTip = ListFormatter.localizedString(byJoining: cell.chips.dropFirst(8).map { ShowWording.chip($0, label: model.channelLabel($0.channel)) })
                chips.append(more)
            }
            for chip in chips { addSubview(chip) }
        }
        label.stringValue = cell.label
        addSubview(label)
        trigger.alignment = .right
        if settings.showsTriggers { addSubview(trigger) }
        refreshTrigger()
        if settings.showsNotes, !cell.note.isEmpty {
            note.stringValue = cell.note
            note.textColor = Palette.dimText
            addSubview(note)
        } else if !cell.note.isEmpty {
            // "a note glyph, with the note on hover".
            label.stringValue = cell.label + "  ✎"
        }
        if cell.missingMedia { tags.append(TagView(Strings.text(.tagMissing), style: .dashedRed)) }
        if cell.keptUnknown { tags.append(TagView(Strings.text(.tagUnknownCommand), style: .amber)) }
        for tag in tags { addSubview(tag) }
        dropNote.onCancel = { [weak model] row in model?.imports.cancel(row: row) }
        addSubview(dropNote)
        refreshNote()
        registerForDraggedTypes(Dragging.withFiles)

        var help: [String] = []
        if let refusal = section.refusal { help.append(ShowWording.refusal(refusal)) }
        if !cell.note.isEmpty { help.append(cell.note) }
        toolTip = help.isEmpty ? nil : help.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        // Spec 10 §15 — "cells say their number, label, section, trigger, and "live" or "armed"".
        let sectionWords = (cell.section ?? "").isEmpty ? "" : Strings.text(.gridCueSection, cell.section ?? "")
        let armed = cell.isArmed ? Strings.text(.gridCueArmed) : ""
        setAccessibilityLabel(([ShowWording.cue(cell), sectionWords, trigger.stringValue, armed] + tags.map(\.text)).filter { !$0.isEmpty }.joined(separator: ", "))
        setAccessibilityHelp(help.joined(separator: ". "))
        setAccessibilityEnabled(section.refusal == nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// What the cell says about a drop on it, from the model: nothing, most of the time.
    func refreshNote() {
        let note = section.listUuid.flatMap { model.imports.cueNotes[MediaImports.key(list: $0, cue: cell.uuid)] }
        let name = note?.row.flatMap { row in model.imports.rows.first { $0.id == row }?.name } ?? ""
        dropNote.show(note.map { ImportWording.note($0) }, row: note?.row, name: name)
    }

    // MARK: Drops (Spec 10 §6, "Drops on the grid")

    /// Lands a drag here, as letting go of it would. Says whether the cell took it.
    @discardableResult
    func accept(_ payload: DragPayload) -> Bool {
        guard let plan = planDrop?(self, payload), plan != .none else { return false }
        performDrop?(self, plan)
        return true
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = Dragging.payload(from: info.draggingPasteboard), let plan = planDrop?(self, payload) else { return [] }
        isMarked = plan.isAccepted
        // A drop the cell refuses may be let go here, and the cell then says why nothing happened.
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

    /// The trigger's words; the armed cue's count down (Spec 10 §6: "Auto 0:08" in amber).
    func refreshTrigger() {
        trigger.stringValue = ShowWording.trigger(cell, armedMs: cell.isArmed ? model.countdownMs : nil)
        trigger.textColor = cell.isArmed ? Palette.browsing : Palette.faintText
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 8
        var y: CGFloat = inset
        if settings.showsThumbnails {
            picture.frame = NSRect(x: inset + 3, y: y, width: bounds.width - inset * 2 - 3, height: 96)
            // The cue's text sits in the middle of the picture's place, as it would on the screen.
            let room = picture.frame.insetBy(dx: 8, dy: 8)
            let needed = text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room.width, height: 400)).height ?? room.height
            let textHeight = min(room.height, ceil(needed))
            text.frame = NSRect(x: room.minX, y: room.minY + (room.height - textHeight) / 2, width: room.width, height: textHeight)
            for (index, tag) in tags.enumerated() {
                let size = tag.fitting
                tag.frame = NSRect(x: picture.frame.maxX - size.width - 5, y: picture.frame.minY + 5 + CGFloat(index) * 19, width: size.width, height: size.height)
            }
            y += 104
        } else {
            var right = bounds.width - inset
            for tag in tags {
                let size = tag.fitting
                tag.frame = NSRect(x: right - size.width, y: 2, width: size.width, height: size.height)
                right -= size.width + 4
            }
        }
        if settings.showsChips {
            var x = inset + 3
            for chip in chips {
                let width = chip is ChipView ? ChipView.size.width : Kit.width(of: chip as? NSTextField ?? NSTextField())
                chip.frame = NSRect(x: x, y: y + 2, width: width, height: ChipView.size.height)
                x += width + 4
            }
            y += 24
        }
        // The trigger is the app's wording and shows whole; the cue's label takes what is left.
        let triggerWidth = settings.showsTriggers ? min(Kit.width(of: trigger), bounds.width - inset * 2 - 30) : 0
        trigger.frame = NSRect(x: bounds.width - inset - triggerWidth, y: y + 2, width: triggerWidth, height: 15)
        label.frame = NSRect(x: inset + 3, y: y, width: bounds.width - inset * 2 - 3 - triggerWidth - (triggerWidth > 0 ? 6 : 0), height: 17)
        note.frame = NSRect(x: inset + 3, y: y + 18, width: bounds.width - inset * 2 - 3, height: 14)
        // The drop's word lies along the foot of the picture, or along the top of a compact cell, over the chips.
        dropNote.frame = settings.showsThumbnails ? NSRect(x: picture.frame.minX + 3, y: picture.frame.maxY - 25, width: picture.frame.width - 6, height: 22)
                                                  : NSRect(x: inset, y: 2, width: bounds.width - inset * 2, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // "the section's colour as the left edge".
        if let hue = Palette.section(cell.hue) {
            hue.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 8, width: 3, height: bounds.height - 16), xRadius: 1.5, yRadius: 1.5).fill()
        }
        // A drag the cell would take: the selection's blue, inside the live cue's red when it is that one.
        if isMarked {
            Palette.selection.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 6, yRadius: 6)
            path.lineWidth = 2
            path.stroke()
        }
    }

    // "Clicking a cue fires it, on the press".
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            _ = model.press(cue: cell, in: section, secondary: true)
            onMenu?(self, event)
            return
        }
        model.follow.buttonDown = true
        press(option: event.modifierFlags.contains(.option))
    }

    /// A press of the main button, as the pointer makes one. "Its first
    /// press has already fired the cue, as every press does; ⌥-double-click,
    /// or the cue's menu, edits without firing."
    func press(option: Bool = false) {
        if model.press(cue: cell, in: section, option: option) == .doubleClick { onDoubleClick?(self) }
    }

    override func mouseUp(with event: NSEvent) {
        model.follow.buttonDown = false
        model.pointerRested()
    }

    override func rightMouseDown(with event: NSEvent) {
        _ = model.press(cue: cell, in: section, secondary: true)
        onMenu?(self, event)
    }

    override func accessibilityPerformPress() -> Bool {
        model.press(cue: cell, in: section) == .fire
    }

    var shownTags: [String] { tags.map(\.text) }
}

/// Spec 10 §6, "A list header".
@MainActor
final class ListHeaderView: Surface {
    static let height: CGFloat = 34
    private let dot = DotView()
    let title = Kit.content(Kit.label(size: 13.5, weight: .semibold))
    let detail = Kit.label(size: 11.5)
    private var tags: [TagView] = []
    let section: GridSection
    /// Spec 10 §6, "A list header" — its menu.
    var makeMenu: (() -> NSMenu?)?

    init(_ section: GridSection) {
        self.section = section
        super.init(frame: .zero)
        dot.color = Palette.live
        dot.isHidden = !section.isLive
        title.stringValue = section.title.isEmpty && section.isMissing ? Strings.text(.tagMissing) : section.title
        title.textColor = section.isMissing ? Palette.live : (section.isRemoved ? Palette.dimText : Palette.text)
        var parts: [String] = []
        if !section.isMissing { parts.append(Strings.counted(.gridCues, section.cueCount)) }
        if !section.ccli.isEmpty { parts.append(Strings.text(.gridCcli, section.ccli)) }
        detail.stringValue = parts.joined(separator: " · ")
        detail.textColor = Palette.faintText
        if section.isRemoved { tags.append(TagView(Strings.text(.gridRemoved), style: .amber)) }
        if section.isLocal { tags.append(TagView(Strings.text(.tagLocal), style: .quiet)) }
        if section.isUpdated { tags.append(TagView(Strings.text(.tagUpdated), style: .amber)) }
        if section.isMissing, !section.title.isEmpty { tags.append(TagView(Strings.text(.tagMissing), style: .red)) }
        if let refusal = section.refusal { tags.append(TagView(ShowWording.refusal(refusal), style: .amber)) }
        for view in [dot, title, detail] as [NSView] + tags { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(([title.stringValue] + (section.isLive ? [Strings.text(.tagLive)] : []) + tags.map(\.text) + [detail.stringValue])
            .filter { !$0.isEmpty }.joined(separator: ", "))
        registerForDraggedTypes(Dragging.own)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        dot.frame = NSRect(x: x, y: 13, width: 9, height: 9)
        if section.isLive { x += 15 }
        // The tags and the count are the app's wording and show whole; the title takes what is left.
        let fixed = tags.reduce(CGFloat(0)) { $0 + $1.fitting.width + 6 } + Kit.width(of: detail) + 14
        let titleWidth = min(Kit.width(of: title), max(40, bounds.width - x - fixed))
        title.frame = NSRect(x: x, y: 9, width: titleWidth, height: 18)
        x += titleWidth + 10
        for tag in tags {
            let size = tag.fitting
            tag.frame = NSRect(x: x, y: 10, width: size.width, height: size.height)
            x += size.width + 6
        }
        detail.frame = NSRect(x: x + 2, y: 11, width: Kit.width(of: detail), height: 15)
    }

    var shownTags: [String] { tags.map(\.text) }

    // MARK: Drops (Spec 10 §6, "Drops on the grid")

    /// "A list dragged from the Library window onto a playlist's list header
    /// is inserted above it": what a drag let go here would do, and doing it.
    var planDrop: ((DragPayload) -> DropPlan)?
    var performDrop: ((DropPlan) -> Void)?
    private(set) var isMarked = false { didSet { needsDisplay = true } }

    /// Lands a drag here, as letting go of it would. Says whether the header took it.
    @discardableResult
    func accept(_ payload: DragPayload) -> Bool {
        guard let plan = planDrop?(payload), plan != .none else { return false }
        performDrop?(plan)
        return true
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let payload = Dragging.payload(from: info.draggingPasteboard), let plan = planDrop?(payload) else { return [] }
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The line the list would be inserted on: above this header.
        if isMarked {
            Palette.selection.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }

    /// The header's menu as it stands now, for a test and for ⌃Return (Spec 10 §15).
    var menuNow: NSMenu? { makeMenu?() }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = makeMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

/// The grid's scrolling content: each section's header and its cells, wrapped to the width.
@MainActor
final class GridDocument: Surface {
    private(set) var headers: [(view: NSView, section: GridSection)] = []
    private(set) var cells: [CueCellView] = []
    private var settings = ViewSettings()
    private weak var model: ShowModel?
    private var tracking: NSTrackingArea?

    /// "and below the last list when dropped past it": where the last list ends, and what a drag let go under it does.
    private var contentBottom: CGFloat = 0
    private var planPastEnd: ((DragPayload) -> DropPlan)?
    private var performDrop: ((DropPlan) -> Void)?

    /// Lands a drag on the space past the last list. Says whether it was taken.
    @discardableResult
    func acceptPastEnd(_ payload: DragPayload) -> Bool {
        guard let plan = planPastEnd?(payload), plan != .none else { return false }
        performDrop?(plan)
        return true
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        guard convert(info.draggingLocation, from: nil).y > contentBottom, let payload = Dragging.payload(from: info.draggingPasteboard),
              let plan = planPastEnd?(payload) else { return [] }
        if case .refused = plan { return .generic }
        return plan.isAccepted ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard convert(sender.draggingLocation, from: nil).y > contentBottom, let payload = Dragging.payload(from: sender.draggingPasteboard) else { return false }
        return acceptPastEnd(payload)
    }

    /// Spec 10 §15 — "The grid is a collection whose cells say their number, label, section, trigger, and "live" or "armed"."
    private func speakAsCollection() {
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(Strings.text(.gridLabel))
    }

    func set(_ grid: GridModel, model: ShowModel, machineRoot: URL?, onMenu: @escaping (CueCellView, NSEvent) -> Void,
             onDoubleClick: @escaping (CueCellView) -> Void, headerMenu: @escaping (ListHeaderView) -> NSMenu?,
             headerDrop: @escaping (DragPayload, _ item: String?) -> DropPlan, performDrop: @escaping (DropPlan) -> Void,
             cueDrop: @escaping (CueCellView, DragPayload) -> DropPlan, landOnCue: @escaping (CueCellView, DropPlan) -> Void) {
        self.model = model
        speakAsCollection()
        planPastEnd = { headerDrop($0, nil) }
        self.performDrop = performDrop
        registerForDraggedTypes(Dragging.own)
        settings = model.settings
        for (view, _) in headers { view.removeFromSuperview() }
        for cell in cells { cell.removeFromSuperview() }
        headers = []
        cells = []
        for section in grid.sections {
            switch section.kind {
            case .header:
                let heading = Kit.heading(section.title)
                addSubview(heading)
                headers.append((heading, section))
            case .list:
                let header = ListHeaderView(section)
                // Spec 10 §6, "A list header" — its menu.
                header.makeMenu = { [weak header] in header.flatMap(headerMenu) }
                // A list from the Library lands above the header it is let go on.
                if let item = section.itemUuid, !section.isRemoved {
                    header.planDrop = { headerDrop($0, item) }
                    header.performDrop = performDrop
                }
                addSubview(header)
                headers.append((header, section))
                for cell in section.cells {
                    let view = CueCellView(cell: cell, section: section, model: model, machineRoot: machineRoot)
                    view.onMenu = onMenu
                    view.onDoubleClick = onDoubleClick
                    view.planDrop = cueDrop
                    view.performDrop = landOnCue
                    addSubview(view)
                    cells.append(view)
                }
            }
        }
        arrange(width: superview?.bounds.width ?? bounds.width)
    }

    /// Lays everything out for a width and takes the height that needs.
    func arrange(width: CGFloat) {
        let margin: CGFloat = 20
        let gap: CGFloat = 12
        let cellHeight = CueCellView.height(settings: settings)
        var y: CGFloat = 12
        var index = 0
        for (view, section) in headers {
            if section.kind == .header {
                view.frame = NSRect(x: margin, y: y + 8, width: width - margin * 2, height: 14)
                y += 30
                continue
            }
            view.frame = NSRect(x: margin, y: y, width: width - margin * 2, height: ListHeaderView.height)
            y += ListHeaderView.height + 4
            var x = margin
            var placed = false
            for _ in section.cells {
                if x + CueCellView.width > width - margin + 1, x > margin {
                    x = margin
                    y += cellHeight + gap
                }
                cells[index].frame = NSRect(x: x, y: y, width: CueCellView.width, height: cellHeight)
                x += CueCellView.width + gap
                index += 1
                placed = true
            }
            y += (placed ? cellHeight : 0) + 18
        }
        contentBottom = y - 18
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, superview?.bounds.height ?? 0))
    }

    /// Where a cue's cell is, with its list's header when it is the list's first cue (Spec 10 §6: "by the least amount").
    func span(ofLiveCell grid: GridModel) -> ClosedRange<Double>? {
        guard let cell = cells.first(where: { $0.cell.isLive }) else { return nil }
        var top = cell.frame.minY
        if cell.cell.number == 1, let header = headers.first(where: { $0.section.itemUuid == cell.section.itemUuid && $0.section.listUuid == cell.section.listUuid }) {
            top = header.view.frame.minY
        }
        return Double(top - 6)...Double(cell.frame.maxY + 6)
    }

    func top(ofItem uuid: String) -> CGFloat? {
        headers.first { $0.section.itemUuid == uuid }?.view.frame.minY
    }

    /// Where a cue's cell sits, for scrolling to it: in the playlist's item, or in the one list a library context shows.
    func span(ofCue cue: String, item: String?, list: String) -> ClosedRange<Double>? {
        guard let cell = cells.first(where: { $0.cell.uuid == cue && $0.section.listUuid == list && (item == nil || $0.section.itemUuid == item) }) else { return nil }
        return Double(cell.frame.minY - 6)...Double(cell.frame.maxY + 6)
    }

    // "It never scrolls while the pointer has moved over the grid in the last second".
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let model else { return }
        model.follow.pointerMoved(inside: true, at: model.now)
    }

    override func mouseExited(with event: NSEvent) {
        guard let model else { return }
        model.follow.pointerMoved(inside: false, at: model.now)
        model.pointerRested()
    }
}

/// Spec 10 §6 — the grid: its header over its scrolling cells.
@MainActor
final class GridView: Surface {
    private let model: ShowModel
    var machineRoot: URL?
    let title = Kit.content(Kit.label(size: 17, weight: .semibold))
    let detail = Kit.label(size: 12)
    /// "From the library: Next stops at its last cue", on a line of its own.
    let fromLibrary = Kit.label(Strings.text(.gridFromLibrary), size: 11.5)
    private var browsing: TagView?
    let search = Kit.search(placeholder: Strings.text(.gridSearch))
    let view = FlatButton(Strings.text(.gridView), style: .plain)
    let scroll = NSScrollView()
    let document = GridDocument()
    let empty = Kit.label(Strings.text(.gridEmpty), size: 13)
    private var firstLine: FirstLineView?
    /// Spec 10 §14, "The last state" — the banner about what the engine put back, or didn't.
    private(set) var restoreLine: RestoreLineView?
    static let headerHeight: CGFloat = 56
    /// The window, which opens the fields in place and the small panels (Spec 10 §10).
    weak var host: ShowWindowView?
    /// What the grid says for a few seconds beside what was tried (Spec 10 §10).
    let notice = NoticeLabel()
    /// Spec 10 §15 — the keyboard's focus among the list headers and the cues: ⌥ with the arrows moves it, ⌥Return or
    /// ⌥Space presses the cue as a click does, ⌃Return opens the cue's menu or the header's.
    private(set) lazy var focus: FocusGroup = {
        let group = FocusGroup(owner: document)
        group.entries = { [weak self] in self?.focusEntries ?? [] }
        return group
    }()

    private var focusEntries: [FocusEntry] {
        var entries: [FocusEntry] = []
        var next = 0
        for (view, section) in document.headers {
            guard section.kind == .list else { continue }
            let place = section.itemUuid ?? section.listUuid ?? section.title
            if let header = view as? ListHeaderView {
                entries.append(FocusEntry(key: "h:" + place, view: header, activate: {}, menu: { [weak header] in header?.menuNow }))
            }
            for _ in section.cells where document.cells.indices.contains(next) {
                let cell = document.cells[next]
                next += 1
                entries.append(FocusEntry(key: "c:" + place + "/" + cell.cell.uuid, view: cell, activate: { [weak cell] in cell?.press() },
                                          menu: { [weak self, weak cell] in cell.flatMap { self?.cueMenu(for: $0) } }))
            }
        }
        return entries
    }

    override var acceptsFirstResponder: Bool { !document.cells.isEmpty }

    override func becomeFirstResponder() -> Bool {
        focus.became(active: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        focus.became(active: false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        if !focus.handle(event) { super.keyDown(with: event) }
    }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        fill = Palette.window
        detail.textColor = Palette.dimText
        fromLibrary.textColor = Palette.browsing
        empty.textColor = Palette.faintText
        empty.alignment = .center
        search.target = self
        search.action = #selector(searched)
        view.onPress = { [weak self] in self?.showViewMenu() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        for sub in [title, detail, fromLibrary, notice, search, view, scroll, empty] as [NSView] { addSubview(sub) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func searched() {
        model.search(grid: search.stringValue)
        // "it highlights the cues whose label or text matches and scrolls to the first".
        if let first = document.cells.first(where: { $0.cell.matchesSearch }) {
            scrollBy(FollowLive.leastScroll(toShow: Double(first.frame.minY - 8)...Double(first.frame.maxY + 8), in: visibleSpan))
        }
    }

    /// The search field takes the cursor (⌘F).
    func focusSearch() {
        window?.makeFirstResponder(search)
    }

    func refresh() {
        let grid = model.grid
        title.stringValue = grid.title
        var parts: [String] = []
        if let date = ShowWording.serviceDate(grid.serviceDate) { parts.append(date) }
        let count = ShowWording.count(grid)
        if !count.isEmpty { parts.append(count) }
        detail.stringValue = parts.joined(separator: " · ")
        fromLibrary.isHidden = !grid.isFromLibrary
        browsing?.removeFromSuperview()
        browsing = nil
        if model.isBrowsing {
            // "the grid's header says "Browsing"".
            let tag = TagView(Strings.text(.gridBrowsing), style: .amber)
            addSubview(tag)
            browsing = tag
        }
        // "the grid's edge ... turn[s] amber".
        outline = model.isBrowsing ? Palette.browsing : nil
        outlineWidth = 2
        empty.isHidden = grid.context != nil
        scroll.isHidden = grid.context == nil
        view.isHidden = grid.context == nil
        search.isHidden = grid.context == nil

        firstLine?.removeFromSuperview()
        firstLine = nil
        if let line = model.firstWindowLine {
            let view = FirstLineView(line) { [weak model] in model?.dismissFirstLine() }
            addSubview(view)
            firstLine = view
        }
        let banner = model.restoreBanner
        if banner != restoreLine?.banner {
            restoreLine?.removeFromSuperview()
            restoreLine = nil
            if let banner {
                let view = RestoreLineView(banner, model: model)
                addSubview(view)
                restoreLine = view
            }
        }
        notice.show(model.notices[.grid])
        document.set(grid, model: model, machineRoot: machineRoot,
                     onMenu: { [weak self] cell, event in self?.showCueMenu(cell, event) },
                     onDoubleClick: { [weak self] cell in self?.doubleClicked(cell) },
                     headerMenu: { [weak self] header in self?.headerMenu(for: header) },
                     headerDrop: { [weak model] payload, item in
                         // Only a playlist takes a list among its items.
                         guard let model, case .playlist(let playlist)? = model.grid.context else { return .none }
                         return model.plan(payload, onto: .listHeader(playlist: playlist, item: item))
                     },
                     performDrop: { [weak model] plan in model?.perform(plan, at: .grid) },
                     cueDrop: { [weak model] cell, payload in model?.plan(payload, ontoCue: cell.cell, in: cell.section) ?? .none },
                     landOnCue: { [weak self] cell, plan in self?.landed(plan, on: cell) })
        focus.place()
        needsLayout = true
    }

    /// The cells' words about drops changed; nothing else did.
    func refreshNotes() {
        for cell in document.cells { cell.refreshNote() }
    }

    /// Spec 10 §6, "Drops on the grid" — a drag was let go on a cue: "The
    /// channel popover opens at the drop", or the cell says why it took nothing.
    func landed(_ plan: DropPlan, on cell: CueCellView) {
        guard let drop = model.land(plan, onCue: cell.cell, in: cell.section) else { return }
        host?.chooseChannel(for: drop, cue: cell)
    }

    /// Once a second: the armed cue's countdown.
    func tick() {
        for cell in document.cells where cell.cell.isArmed { cell.refreshTrigger() }
    }

    private var visibleSpan: ClosedRange<Double> {
        let visible = scroll.contentView.bounds
        return Double(visible.minY)...Double(visible.maxY)
    }

    private func scrollBy(_ delta: Double) {
        guard delta != 0 else { return }
        let visible = scroll.contentView.bounds
        let y = min(max(0, visible.minY + CGFloat(delta)), max(0, document.frame.height - visible.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Spec 10 §6 — "The grid scrolls only when the live cue is out of view, and by the least amount."
    func scrollToLive() {
        layoutSubtreeIfNeeded()
        guard let span = document.span(ofLiveCell: model.grid) else { return }
        scrollBy(FollowLive.leastScroll(toShow: span, in: visibleSpan))
    }

    /// Spec 11 §2, "Leaving it" — "the grid browses where its list came from
    /// ... and scrolls to it, firing nothing": the cue edit mode had selected, by the least amount.
    func scrollTo(cue: String, item: String?, list: String) {
        layoutSubtreeIfNeeded()
        guard let span = document.span(ofCue: cue, item: item, list: list) else { return }
        scrollBy(FollowLive.leastScroll(toShow: span, in: visibleSpan))
    }

    /// Spec 10 §5 — "Click an item to browse its playlist and scroll the grid to that list."
    func scrollTo(item uuid: String) {
        layoutSubtreeIfNeeded()
        guard let top = document.top(ofItem: uuid) else { return }
        scrollBy(Double(top - 8) - visibleSpan.lowerBound)
    }

    /// Spec 10 §6 — "the View menu: chips, trigger glyph, notes, and Compact, which drops the thumbnails".
    private func showViewMenu() {
        let menu = NSMenu()
        func item(_ key: StringKey, _ on: Bool, _ change: @escaping (inout ViewSettings) -> Void) {
            let item = ClosureMenuItem(title: Strings.text(key)) { [weak model] in model?.change(change) }
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        let settings = model.settings
        item(.gridViewChips, settings.showsChips) { $0.showsChips.toggle() }
        item(.gridViewTriggers, settings.showsTriggers) { $0.showsTriggers.toggle() }
        item(.gridViewNotes, settings.showsNotes) { $0.showsNotes.toggle() }
        item(.gridViewCompact, settings.isCompact) { $0.showsThumbnails.toggle() }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: - A cue's menu and its edits (Spec 10 §6, §10)

    private func showCueMenu(_ cell: CueCellView, _ event: NSEvent) {
        NSMenu.popUpContextMenu(cueMenu(for: cell), with: event, for: cell)
    }

    /// Spec 10 §6, "A cue's menu".
    func cueMenu(for cell: CueCellView) -> NSMenu {
        MenuBuilder.menu(Menus.cue(model.cueContext(cell.cell, in: cell.section))) { [weak self, weak cell] entry in
            guard let cell else { return }
            self?.perform(entry, cue: cell)
        }
    }

    /// Says beside the grid why an edit wasn't sent, when it wasn't.
    private func say(_ cannot: CannotEdit?) {
        if let cannot { model.say(.notSent(cannot), at: .grid) }
    }

    private func perform(_ entry: MenuEntry, cue view: CueCellView) {
        let (cell, section) = (view.cell, view.section)
        switch entry.kind {
        case .fire:
            if let sending = model.fire(cell, in: section) { model.send(sending) }
        case .editText:
            editText(view)
        case .editCue:
            // "Edit Cue in a cue's menu, opens the Cues page on that cue" (Spec 11 §2).
            host?.enterEdit(cue: cell, in: section)
        case .note:
            host?.present(Prompts.note(cell, in: section, model: model), at: view)
        case .triggerGo:
            say(model.trigger(.go, cell: cell, in: section))
        case .triggerTime:
            host?.present(Prompts.triggerTime(cell, in: section, model: model), at: view)
        case .advanceAfter:
            host?.present(Prompts.advanceAfter(cell, in: section, model: model).panel, at: view)
        case .duplicateSection:
            say(model.duplicateSection(cell: cell, in: section))
        case .hold:
            model.send(Actions.hold())
        default:
            break
        }
    }

    /// Spec 10 §6, "Double-click" — "on a cue with a text write on the text
    /// channel ... edits that text in place (§10); on any other cue it opens
    /// edit mode's Cues page on it (Spec 11 §2)".
    private func doubleClicked(_ view: CueCellView) {
        if model.textBody(of: view.cell, in: view.section) != nil { editText(view) } else { host?.enterEdit(cue: view.cell, in: view.section) }
    }

    /// Spec 10 §10, "In-place text" — "opens a field over the cell holding
    /// the body of its text write. Return makes a new line; ⌘Return commits,
    /// and so does a click outside ... Escape cancels."
    func editText(_ view: CueCellView) {
        guard let body = model.textBody(of: view.cell, in: view.section) else { return }
        if let cannot = model.cueContext(view.cell, in: view.section).edit { return say(cannot) }
        let (cell, section) = (view.cell, view.section)
        host?.editInPlace(over: view, rect: view.editRect, text: body, kind: .inPlaceText, label: Strings.text(.fieldText, cell.number)) { [weak model] in
            model?.commitText($0, cell: cell, in: section)
        }
    }

    /// Spec 10 §6, "A list header" — its menu.
    func headerMenu(for header: ListHeaderView) -> NSMenu? {
        let section = header.section
        return MenuBuilder.menu(model.headerMenu(for: section)) { [weak self] entry in self?.perform(entry, header: section) }
    }

    private func perform(_ entry: MenuEntry, header section: GridSection) {
        switch entry.kind {
        case .removeItem:
            if case .playlist(let playlist)? = model.grid.context, let item = section.itemUuid { model.removeItem(item, from: playlist, at: .grid) }
        case .showInLibrary:
            if let list = section.listUuid { model.showInLibrary(list: list) }
        case .grade(let channel, let grade):
            say(model.grade(grade, channel: channel, in: section))
        case .restoreVersion:
            if let list = section.listUuid { host?.restoreVersion(of: list) }
        default:
            break
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        var top: CGFloat = 0
        if let firstLine {
            firstLine.frame = NSRect(x: 0, y: 0, width: w, height: FirstLineView.height)
            top = FirstLineView.height
        }
        if let restoreLine {
            let height = restoreLine.height(width: w)
            restoreLine.frame = NSRect(x: 0, y: top, width: w, height: height)
            top += height
        }
        let viewSize = view.fitting
        view.frame = NSRect(x: w - 20 - viewSize.width, y: top + 15, width: viewSize.width, height: 26)
        let searchWidth: CGFloat = min(220, max(120, w * 0.24))
        search.frame = NSRect(x: view.frame.minX - 10 - searchWidth, y: top + 16, width: searchWidth, height: 24)
        // The count and "Browsing" are the app's wording and show whole; the title takes what is left.
        let fixed = Kit.width(of: detail) + (browsing.map { $0.fitting.width + 10 } ?? 0) + 24
        let titleWidth = min(Kit.width(of: title), max(60, search.frame.minX - 20 - fixed))
        title.frame = NSRect(x: 20, y: top + 16, width: titleWidth, height: 22)
        var x = 20 + titleWidth + 12
        if let browsing {
            let size = browsing.fitting
            browsing.frame = NSRect(x: x, y: top + 20, width: size.width, height: size.height)
            x += size.width + 10
        }
        detail.frame = NSRect(x: x, y: top + 21, width: Kit.width(of: detail), height: 16)
        let noteHeight: CGFloat = fromLibrary.isHidden ? 0 : 20
        fromLibrary.frame = NSRect(x: 20, y: top + Self.headerHeight - 8, width: w - 40, height: 16)
        // What the grid says about an edit stands under its header, for its few seconds.
        let noticeHeight = notice.height(width: w - 40)
        notice.frame = NSRect(x: 20, y: top + Self.headerHeight - 8 + noteHeight, width: w - 40, height: noticeHeight)
        let headerHeight = Self.headerHeight + noteHeight + (noticeHeight > 0 ? noticeHeight + 4 : 0)
        scroll.frame = NSRect(x: 0, y: top + headerHeight, width: w, height: max(0, bounds.height - top - headerHeight))
        document.arrange(width: scroll.contentSize.width)
        empty.frame = NSRect(x: 20, y: bounds.height / 2 - 10, width: w - 40, height: 20)
    }
}

/// Spec 10 §13, "The first window" — "names each new output ("Output 1 is
/// DELL U2720Q"), with Settings ▸ Outputs a click away, beside the UX spec's
/// line that these defaults are the operator's to rename, number and extend,
/// until dismissed."
@MainActor
final class FirstLineView: Surface {
    static let height: CGFloat = 40
    let text = Kit.content(Kit.label(size: 12.5))
    let settings = FlatButton(Strings.text(.firstSettings), style: .plain)
    let dismiss = FlatButton(Strings.text(.firstDismiss), style: .bare)

    init(_ line: FirstWindowLine, onDismiss: @escaping () -> Void) {
        super.init(frame: .zero)
        fill = Palette.selection.withAlphaComponent(0.14)
        var sentences: [String] = []
        for output in line.outputs { sentences.append(Strings.text(.firstOutput, output.number, output.device)) }
        sentences.append(Strings.text(.firstDefaults))
        text.stringValue = sentences.joined(separator: "  ·  ")
        text.toolTip = text.stringValue
        // Settings is Area 17's.
        settings.isEnabled = false
        settings.reason = Strings.text(.unavailableLater)
        dismiss.onPress = onDismiss
        for view in [text, settings, dismiss] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let dismissSize = dismiss.fitting
        dismiss.frame = NSRect(x: bounds.width - 14 - dismissSize.width, y: 8, width: dismissSize.width, height: 24)
        let settingsSize = settings.fitting
        settings.frame = NSRect(x: dismiss.frame.minX - 8 - settingsSize.width, y: 8, width: settingsSize.width, height: 24)
        text.frame = NSRect(x: 20, y: 12, width: max(0, settings.frame.minX - 32), height: 16)
    }
}

/// Spec 10 §14, "The last state" — "a banner says "Picked up where the
/// engine stopped, at 09:41. Video started again from the top." It names
/// what didn't come back, and says that timers came back unset ..., with Set
/// Timers Again"; or it says why nothing was put back, and offers "Fire 3
/// Verse 2 again". "Dismissed, it stays away for that run".
@MainActor
final class RestoreLineView: Surface {
    let banner: RestoreBanner
    let text = Kit.content(Kit.label(size: 12.5))
    let setTimers = FlatButton(Strings.text(.restoreTimersAgain), style: .plain)
    let fireAgain = FlatButton(style: .plain)
    let dismiss = FlatButton(Strings.text(.firstDismiss), style: .bare)

    init(_ banner: RestoreBanner, model: ShowModel) {
        self.banner = banner
        super.init(frame: .zero)
        fill = Palette.browsing.withAlphaComponent(0.14)
        text.stringValue = StateWording.banner(banner).joined(separator: " ")
        text.maximumNumberOfLines = 3
        text.lineBreakMode = .byWordWrapping
        text.cell?.wraps = true
        text.toolTip = text.stringValue
        let away = model.store.cannotSend
        if case .setAgain = banner.timers {
            setTimers.isEnabled = away == nil
            setTimers.reason = ShowWording.unavailable(away)
            setTimers.onPress = { [weak model] in model?.setTimersAgain() }
        } else {
            setTimers.isHidden = true
        }
        if let fire = banner.fireAgain {
            fireAgain.title = StateWording.fireAgain(fire)
            // "its Make Live and the restore banner's Fire Again (§14) are disabled with "Rename to fire"" (§6).
            fireAgain.isEnabled = away == nil && fire.sending != nil
            fireAgain.reason = fire.refusal.map(ShowWording.refusal) ?? ShowWording.unavailable(away)
            fireAgain.onPress = { [weak model] in model?.fireAgain() }
        } else {
            fireAgain.isHidden = true
        }
        dismiss.onPress = { [weak model] in model?.dismissRestoreBanner() }
        for view in [text, setTimers, fireAgain, dismiss] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.text(.restoreLabel))
        // VoiceOver hears it when it appears.
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text.stringValue, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var buttonsWidth: CGFloat {
        var width = dismiss.fitting.width + 14
        for button in [setTimers, fireAgain] where !button.isHidden { width += button.fitting.width + 8 }
        return width
    }

    /// The height its words need at a width: the banner grows rather than cut a sentence short.
    func height(width: CGFloat) -> CGFloat {
        let room = max(80, width - 32 - buttonsWidth)
        let needed = ceil(text.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room, height: 200)).height ?? 16)
        return max(40, needed + 24)
    }

    override func layout() {
        super.layout()
        var right = bounds.width - 14
        for button in [dismiss, fireAgain, setTimers] where !button.isHidden {
            let size = button.fitting
            button.frame = NSRect(x: right - size.width, y: 8, width: size.width, height: 24)
            right -= size.width + 8
        }
        text.frame = NSRect(x: 20, y: 12, width: max(0, right - 26), height: max(16, bounds.height - 24))
    }
}
