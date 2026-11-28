// OAppUI — Spec 11 §5, edit mode's Text page: the list's text on one channel as one document, and its fields beside it.

import AppKit
import OApp
import OCore

/// Spec 11 §5, "The document" — "Between chunks, a break: a rule carrying
/// the next cue's number". The rule above a chunk, with its cue's number and,
/// on the live cue's, the live dot.
@MainActor
final class BreakView: NSView {
    let number = Kit.label(size: 10.5, weight: .semibold, color: Palette.faintText, mono: true)
    let dot = Surface()
    /// Where the rule starts across the row: the text column's left edge.
    var ruleX: CGFloat = 0
    var ruleEnd: CGFloat = 0

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        number.alignment = .right
        dot.fill = Palette.live
        dot.radius = 3.5
        dot.isHidden = true
        addSubview(number)
        addSubview(dot)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Palette.hairline.withAlphaComponent(0.14).setFill()
        NSRect(x: ruleX, y: floor(bounds.midY), width: max(0, ruleEnd - ruleX), height: 1).fill()
    }

    override func layout() {
        super.layout()
        let width: CGFloat = 40
        number.frame = NSRect(x: ruleX - width - 8, y: (bounds.height - 14) / 2, width: width, height: 14)
        dot.frame = NSRect(x: ruleX - width - 22, y: (bounds.height - 7) / 2, width: 7, height: 7)
    }
}

/// Spec 11 §5 — one chunk: its rule and number, the section in the left
/// margin at the first chunk of a run, the text (or the row naming other
/// content), and the cue's thumbnail beside it.
@MainActor
final class ChunkView: NSView {
    let cue: String
    let rule = BreakView()
    let margin = Kit.content(Kit.label(size: 11.5, weight: .semibold))
    let text = ChunkTextView()
    /// "Clears", "Holds nothing", "Holds Video: Ocean loop", "Type or paste the song's text".
    let placeholder = Kit.label(size: 15, color: Palette.faintText)
    /// "a row naming it ("Video: Ocean loop"), not editable".
    let row = Kit.content(Kit.label(size: 13, color: Palette.dimText))
    /// "On the confidence screen", "Changed elsewhere", "Cue removed".
    let tags = Kit.label(size: 11, weight: .medium, color: Palette.browsing)
    let add = FlatButton(Strings.text(.textAddAsNewCue), style: .plain)
    let copy = FlatButton(Strings.text(.textCopy), style: .plain)
    let thumbnail = NSImageView()
    /// Drawn as part of the whole document's selection.
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }
    private var shownThumbnail: String?

    static let ruleHeight: CGFloat = 22
    static let marginWidth: CGFloat = 104
    static let thumbnailWidth: CGFloat = 128
    static var thumbnailHeight: CGFloat { thumbnailWidth * 9 / 16 }
    static let gap: CGFloat = 14

    override var isFlipped: Bool { true }

    init(cue: String) {
        self.cue = cue
        super.init(frame: .zero)
        text.cue = cue
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.backgroundColor = NSColor.black.cgColor
        thumbnail.layer?.cornerRadius = 3
        thumbnail.layer?.borderWidth = 1
        thumbnail.layer?.borderColor = Palette.hairline.cgColor
        thumbnail.setAccessibilityElement(false)
        placeholder.setAccessibilityElement(false)
        add.fontSize = 11.5
        copy.fontSize = 11.5
        for view in [rule, margin, text, placeholder, row, tags, add, copy, thumbnail] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        Palette.selection.withAlphaComponent(0.22).setFill()
        NSRect(x: textX - 4, y: Self.ruleHeight, width: max(0, textWidth + 8), height: max(0, bounds.height - Self.ruleHeight - 4)).fill()
    }

    var textX: CGFloat { Self.marginWidth + Self.gap }
    var textWidth: CGFloat { max(80, bounds.width - textX - Self.gap - Self.thumbnailWidth - Self.gap) }

    /// The height the row takes at `width`.
    func height(at width: CGFloat) -> CGFloat {
        let textWidth = max(80, width - textX - Self.gap - Self.thumbnailWidth - Self.gap)
        if text.frame.width != textWidth { text.frame.size.width = textWidth }
        var body = row.isHidden ? text.textHeight : 24
        if !tags.isHidden || !add.isHidden { body += 22 }
        return Self.ruleHeight + max(body, Self.thumbnailHeight) + 10
    }

    func showThumbnail(_ file: String?, root: URL?) {
        guard file != shownThumbnail else { return }
        shownThumbnail = file
        guard let file, let root else {
            thumbnail.image = nil
            return
        }
        thumbnail.image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] image in
            if self?.shownThumbnail == file { self?.thumbnail.image = image }
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        rule.frame = NSRect(x: 0, y: 0, width: width, height: Self.ruleHeight)
        rule.ruleX = textX
        rule.ruleEnd = width - Self.gap
        rule.needsLayout = true
        rule.needsDisplay = true
        let top = Self.ruleHeight
        margin.frame = NSRect(x: 8, y: top + 4, width: Self.marginWidth - 8, height: 16)
        let textHeight = row.isHidden ? text.textHeight : 24
        text.frame = NSRect(x: textX, y: top, width: textWidth, height: textHeight)
        placeholder.frame = NSRect(x: textX + 2, y: top + 3, width: textWidth, height: 20)
        row.frame = NSRect(x: textX + 2, y: top + 3, width: textWidth, height: 18)
        var y = top + textHeight + 4
        tags.frame = NSRect(x: textX + 2, y: y, width: min(textWidth, Kit.width(of: tags)), height: 15)
        var x = tags.isHidden ? textX : tags.frame.maxX + 10
        for button in [add, copy] where !button.isHidden {
            let size = button.fitting
            button.frame = NSRect(x: x, y: y - 3, width: size.width, height: 22)
            x += size.width + 6
        }
        y = top
        thumbnail.frame = NSRect(x: width - Self.gap - Self.thumbnailWidth, y: y, width: Self.thumbnailWidth, height: Self.thumbnailHeight)
    }
}

/// Spec 11 §5 — "a single scrolling document, cue breaks as rules between
/// chunks". Each chunk is a view bound to its cue's uuid: "A `library` event
/// patches the chunks it names, never moving the caret or the scroll", so the
/// page patches the views whose chunks changed and keeps the first visible
/// one where it was.
@MainActor
final class TextDocumentView: NSView {
    private let model: ShowModel
    private(set) var rows: [String: ChunkView] = [:]
    private(set) var order: [String] = []
    var machineRoot: URL?
    /// "A second ⌘A selects the whole document, for Copy only."
    private(set) var isDocumentSelected = false
    /// Where Copy puts text: the system's pasteboard, or a test's own.
    var pasteboard = NSPasteboard.general

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var editor: TextEditor { model.editing.text }

    /// The chunk views in the document's order.
    var chunkViews: [ChunkView] { order.compactMap { rows[$0] } }

    /// Brings every chunk view up to date with the editor, keeping the caret and the scroll where they are.
    func apply() {
        let editor = self.editor
        let document = editor.document
        var ids = document.chunks.map(\.cue)
        if let removed = editor.removed, !ids.contains(removed.cue) { ids.insert(removed.cue, at: min(removed.index, ids.count)) }
        if editor.isEmptyList { ids = [TextEditor.emptyChunk] }
        let anchor = firstVisible()
        for gone in Set(order).subtracting(ids) {
            if let view = rows.removeValue(forKey: gone) {
                if window?.firstResponder === view.text { window?.makeFirstResponder(nil) }
                view.removeFromSuperview()
            }
        }
        let readOnly = editor.cannotEdit != nil
        for id in ids {
            let view = rows[id] ?? make(id)
            rows[id] = view
            if let chunk = document.chunk(id) {
                fill(view, chunk: chunk, readOnly: readOnly)
            } else if let removed = editor.removed, removed.cue == id {
                fillRemoved(view, removed)
            } else {
                fillEmpty(view, readOnly: readOnly)
            }
        }
        order = ids
        setAccessibilityLabel(Strings.text(.textDocumentSpoken, document.channel))
        place(anchor: anchor)
    }

    private func make(_ id: String) -> ChunkView {
        let view = ChunkView(cue: id)
        let text = view.text
        text.onFocus = { [weak self] text in self?.focused(text) }
        text.onBlur = { [weak self] text in self?.blurred(text) }
        text.onChange = { [weak self] text, string, composing in
            self?.editor.typed(string, composing: composing)
            self?.changedHeight(of: text)
        }
        text.onEdge = { [weak self] text, edge in self?.move(from: text, edge) }
        text.onLeave = { [weak self] _ in self?.leaveEditor() }
        text.onSelectAll = { [weak self] _ in self?.selectDocument() ?? false }
        text.isDocumentSelected = { [weak self] in self?.isDocumentSelected ?? false }
        text.onCopyDocument = { [weak self] in self?.copyDocument() }
        text.onRefused = { [weak self] in self?.editor.refuseAcrossBreaks() }
        text.onSelectionMoved = { [weak self] in self?.endDocumentSelection() }
        view.add.onPress = { [weak self] in self?.editor.addRemovedAsNewCue() }
        view.copy.onPress = { [weak self] in
            guard let self, let text = self.editor.copyRemoved() else { return }
            self.pasteboard.clearContents()
            self.pasteboard.setString(text, forType: .string)
        }
        addSubview(view)
        return view
    }

    private func fill(_ view: ChunkView, chunk: TextChunk, readOnly: Bool) {
        let editor = self.editor
        let shown = editor.text(of: chunk.cue)
        let grayed = chunk.heldBody != nil && !editor.isTyped(chunk.cue)
        if window?.firstResponder !== view.text || view.text.string != shown {
            view.text.show(shown, color: grayed ? Palette.faintText : Palette.text)
        } else if grayed != (view.text.textColor == Palette.faintText) {
            view.text.show(shown, color: grayed ? Palette.faintText : Palette.text)
        }
        view.text.isEditable = chunk.isEditable && !readOnly
        view.text.isHidden = !chunk.isEditable
        view.row.isHidden = chunk.isEditable
        view.row.stringValue = TextWording.row(chunk) ?? ""
        let placeholder = TextWording.placeholder(chunk)
        view.placeholder.stringValue = placeholder ?? ""
        view.placeholder.isHidden = placeholder == nil || !shown.isEmpty
        view.rule.number.stringValue = String(chunk.number)
        view.rule.dot.isHidden = !chunk.isLive
        view.margin.stringValue = chunk.startsRun ? (chunk.section ?? "") : ""
        view.margin.textColor = Palette.section(chunk.hue) ?? Palette.dimText
        view.margin.isHidden = !chunk.startsRun
        let tags = TextWording.tags(chunk, editor: editor)
        view.tags.stringValue = tags.joined(separator: " · ")
        view.tags.isHidden = tags.isEmpty
        view.add.isHidden = true
        view.copy.isHidden = true
        view.showThumbnail(chunk.thumbnail, root: machineRoot)
        var spoken = TextWording.spoken(chunk)
        if chunk.isLive { spoken += ", " + Strings.text(.editCuesLive) }
        view.text.setAccessibilityLabel(spoken)
        view.row.setAccessibilityLabel(spoken + ", " + view.row.stringValue)
        view.isHighlighted = isDocumentSelected
    }

    private func fillRemoved(_ view: ChunkView, _ removed: RemovedChunk) {
        if window?.firstResponder !== view.text { view.text.show(removed.text, color: Palette.text) }
        view.text.isEditable = true
        view.text.isHidden = false
        view.row.isHidden = true
        view.placeholder.isHidden = true
        view.rule.number.stringValue = ""
        view.rule.dot.isHidden = true
        view.margin.isHidden = true
        view.tags.stringValue = Strings.text(.textCueRemoved)
        view.tags.textColor = Palette.live
        view.tags.isHidden = false
        view.add.isHidden = false
        view.copy.isHidden = false
        view.showThumbnail(nil, root: nil)
        view.text.setAccessibilityLabel(Strings.text(.textCueRemoved))
    }

    private func fillEmpty(_ view: ChunkView, readOnly: Bool) {
        let shown = editor.text(of: TextEditor.emptyChunk)
        if window?.firstResponder !== view.text { view.text.show(shown, color: Palette.text) }
        view.text.isEditable = !readOnly
        view.text.isHidden = false
        view.row.isHidden = true
        view.placeholder.stringValue = Strings.text(.textEmpty)
        view.placeholder.isHidden = !shown.isEmpty
        view.rule.number.stringValue = ""
        view.rule.dot.isHidden = true
        view.margin.isHidden = true
        view.tags.isHidden = true
        view.add.isHidden = true
        view.copy.isHidden = true
        view.showThumbnail(nil, root: nil)
        view.text.setAccessibilityLabel(Strings.text(.textEmpty))
    }

    // MARK: - Layout

    /// The chunk at the top of what shows, and how far it sits from the top: kept in place through a patch.
    private func firstVisible() -> (id: String, offset: CGFloat)? {
        let visible = visibleRect
        guard visible.height > 0 else { return nil }
        for id in order {
            guard let view = rows[id] else { continue }
            if view.frame.maxY > visible.minY { return (id, view.frame.minY - visible.minY) }
        }
        return nil
    }

    private func place(anchor: (id: String, offset: CGFloat)?) {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        var y: CGFloat = 4
        for id in order {
            guard let view = rows[id] else { continue }
            let height = view.height(at: width)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            view.needsLayout = true
            y += height
        }
        let height = max(y + 24, enclosingScrollView?.contentSize.height ?? 0)
        if frame.size != NSSize(width: width, height: height) { setFrameSize(NSSize(width: width, height: height)) }
        if let anchor, let view = rows[anchor.id], let clip = enclosingScrollView?.contentView {
            let target = max(0, min(view.frame.minY - anchor.offset, height - clip.bounds.height))
            if abs(clip.bounds.minY - target) > 0.5 {
                clip.scroll(to: NSPoint(x: 0, y: target))
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
    }

    /// The scroll view's width changed: every chunk lays out again.
    func relayout() {
        place(anchor: firstVisible())
    }

    private func changedHeight(of text: ChunkTextView) {
        guard let view = rows[text.cue] else { return }
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        if abs(view.height(at: width) - view.frame.height) > 0.5 { place(anchor: firstVisible()) }
        view.placeholder.isHidden = view.placeholder.stringValue.isEmpty || !text.string.isEmpty
        text.scrollToVisible(text.lineRect(at: text.selectedRange().location))
    }

    // MARK: - The caret

    private func focused(_ text: ChunkTextView) {
        endDocumentSelection()
        guard editor.document.chunk(text.cue)?.isEditable ?? true else {
            window?.makeFirstResponder(nil)
            return
        }
        editor.enter(text.cue)
    }

    private func blurred(_ text: ChunkTextView) {
        if editor.caret == text.cue { editor.leave() }
    }

    /// The editor gives the focus back to the window: Escape and ⌘Return.
    func leaveEditor() {
        endDocumentSelection()
        window?.makeFirstResponder(superview?.superview)
    }

    /// "Arrows cross chunk edges" (Area 10 reading): into the next chunk that takes typing, skipping rows of other content.
    private func move(from text: ChunkTextView, _ edge: ChunkTextView.Edge) {
        guard let index = order.firstIndex(of: text.cue) else { return }
        let forward: Bool
        switch edge {
        case .down, .right: forward = true
        case .up, .left: forward = false
        }
        let candidates = forward ? Array(order[(index + 1)...]) : Array(order[..<index].reversed())
        guard let next = candidates.compactMap({ rows[$0] }).first(where: { !$0.text.isHidden }) else { return }
        window?.makeFirstResponder(next.text)
        switch edge {
        case .down(let x): next.text.placeCaret(onFirstLine: true, x: x)
        case .up(let x): next.text.placeCaret(onFirstLine: false, x: x)
        case .right: next.text.placeCaret(at: 0)
        case .left: next.text.placeCaret(at: (next.text.string as NSString).length)
        }
        next.scrollToVisible(next.bounds)
    }

    /// Focuses a chunk, at the end of its text: Open in Text Editor on a cue, and after a split.
    func focus(_ cue: String, at location: Int? = nil) {
        guard let view = rows[cue], !view.text.isHidden else { return }
        window?.makeFirstResponder(view.text)
        view.text.placeCaret(at: location ?? (view.text.string as NSString).length)
        view.scrollToVisible(view.bounds)
    }

    // MARK: - The whole document's selection (Spec 11 §5, "Selection")

    private func selectDocument() -> Bool {
        guard !isDocumentSelected else { return true }
        isDocumentSelected = true
        for view in rows.values { view.isHighlighted = true }
        return true
    }

    func endDocumentSelection() {
        guard isDocumentSelected else { return }
        isDocumentSelected = false
        for view in rows.values { view.isHighlighted = false }
    }

    private func copyDocument() {
        pasteboard.clearContents()
        pasteboard.setString(editor.documentText(), forType: .string)
    }

    override func mouseDown(with event: NSEvent) {
        endDocumentSelection()
        super.mouseDown(with: event)
    }
}

/// Spec 11 §5 and G-46 — the Text page's workspace: the document, and "a
/// tall column at the workspace's right, between the document and the
/// monitors", with the list's fields over the caret cue's.
@MainActor
final class TextWorkspaceView: NSView {
    private let model: ShowModel
    let scroll = NSScrollView()
    let document: TextDocumentView
    let column = FormColumn()
    let listHeading = Kit.heading(Strings.text(.textColumnList))
    let titleField = EditField()
    let authorField = EditField()
    let copyrightField = EditField()
    let ccliField = EditField()
    let trackThrough = ChoiceBox(Strings.text(.textFieldTrackThrough))
    let cueHeading = Kit.heading("")
    let labelField = EditField()
    let sectionField = EditField()
    let sectionMenu = FlatButton("▾", style: .bare)
    let hold = FlatButton(Strings.text(.textHold), style: .plain)
    /// The names over the list's fields and over the cue's.
    private var names: [NSTextField] = []
    private var cueNames: [NSTextField] = []
    var machineRoot: URL? {
        get { document.machineRoot }
        set { document.machineRoot = newValue }
    }

    static let columnWidth: CGFloat = 248

    override var isFlipped: Bool { true }

    init(model: ShowModel) {
        self.model = model
        document = TextDocumentView(model: model)
        super.init(frame: .zero)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        // A tall, narrow column: each field's name over it, so a name has the column's whole width.
        func labeled(_ name: String, _ views: [NSView], widths: [CGFloat?]? = nil) -> NSTextField {
            let label = Kit.label(name, size: 11.5, color: Palette.dimText)
            column.wide(label, height: 14)
            column.row(nil, views, widths: widths)
            views.first?.setAccessibilityLabel(name)
            return label
        }
        column.wide(listHeading, height: 16)
        names = [labeled(Strings.text(.textFieldTitle), [titleField]), labeled(Strings.text(.textFieldAuthor), [authorField]),
                 labeled(Strings.text(.textFieldCopyright), [copyrightField]), labeled(Strings.text(.textFieldCCLI), [ccliField])]
        column.wide(trackThrough, height: 20)
        column.wide(cueHeading, height: 16)
        cueNames = [labeled(Strings.text(.editFieldLabel), [labelField]),
                    labeled(Strings.text(.editFieldSection), [sectionField, sectionMenu], widths: [nil, 20])]
        column.wide(hold, height: 24)
        for (field, kind) in [(titleField, TextListField.title), (authorField, .author), (copyrightField, .copyright), (ccliField, .ccli)] {
            field.onCommit = { [weak model] text in model?.editing.text.set(kind, .string(text)) }
        }
        trackThrough.onToggle = { [weak model] on in model?.editing.text.set(.trackThrough, .bool(on)) }
        labelField.setAccessibilityLabel(Strings.text(.editFieldLabel))
        labelField.onCommit = { [weak model] text in model?.editing.text.setLabel(text) }
        sectionField.setAccessibilityLabel(Strings.text(.editFieldSection))
        sectionField.onCommit = { [weak model] text in model?.editing.text.setSection(text) }
        sectionMenu.setAccessibilityLabel(Strings.text(.editFieldSection))
        sectionMenu.onPress = { [weak self] in self?.showSections() }
        hold.onPress = { [weak model] in model?.editing.text.hold() }
        addSubview(scroll)
        addSubview(column.scroll)
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.document.relayout() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// "a combo box with the list's sections and E3's names".
    private func showSections() {
        let menu = NSMenu()
        for name in model.editing.text.sectionChoices {
            menu.addItem(ClosureMenuItem(title: name) { [weak model] in model?.editing.text.setSection(name) })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sectionMenu.bounds.height + 2), in: sectionMenu)
    }

    func refresh() {
        let editor = model.editing.text
        document.apply()
        let list = model.editing.list
        let cannot = editor.cannotEdit
        let subject = list?.uuid
        titleField.show(list?.title ?? "", subject: subject)
        authorField.show(list?.author ?? "", subject: subject)
        copyrightField.show(list?.copyright ?? "", subject: subject)
        ccliField.show(list?.ccli ?? "", subject: subject)
        trackThrough.state = list?.trackThrough == true ? .on : .off
        let cue = editor.columnCue
        let number = cue.flatMap { list?.position(of: $0.uuid) }
        Kit.setHeading(cueHeading, number.map { Strings.text(.textColumnCue, $0) } ?? "")
        labelField.show(cue?.label ?? "", subject: cue?.uuid)
        sectionField.show(cue?.section ?? "", subject: cue?.uuid)
        let reason = cannot.map(EditModeWording.readOnly)
        for field in [titleField, authorField, copyrightField, ccliField] {
            field.isEditable = cannot == nil
            field.toolTip = reason
        }
        trackThrough.isEnabled = cannot == nil
        for field in [labelField, sectionField] {
            field.isEditable = cannot == nil && cue != nil
            field.toolTip = reason
        }
        sectionMenu.isEnabled = cannot == nil && cue != nil
        hold.isEnabled = cannot == nil && cue != nil
        hold.reason = reason
        for view in [cueHeading, labelField, sectionField, sectionMenu, hold] + cueNames as [NSView] { view.isHidden = cue == nil }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = Self.columnWidth
        let gap: CGFloat = 4
        scroll.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - width - gap), height: bounds.height)
        column.scroll.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        column.place()
        document.relayout()
    }
}
