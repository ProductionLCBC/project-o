// OAppUI — Spec 11 §5, "The sheet view" (G-50): the Text page's document as one field of text.

import AppKit
import OApp
import OCore

/// Spec 11 §5, "The sheet view" (Adam, 2026-11-28, G-50) — "the same
/// document as one field of text, as a printed lyric sheet reads: no
/// thumbnails; each cue's lines one after another, its number in the margin
/// at its first line and the live dot by the live cue's; a faint dashed line
/// under each cue, an empty cue's included; a cue that clears or holds the
/// channel as a blank line with its number; other content as a grayed line
/// naming it, not editable; and a section's label in the margin at its first
/// cue, with a blank line before each new section."
///
/// One text view holds the whole text; `TextSheet` says where each cue's text
/// lies in it, so every edit is read as one cue's (typing), a merge (Backspace
/// or forward Delete at a dashed line), or nothing ("Select within one cue.").
/// The editor sends exactly what the chunked document's would.
@MainActor
final class SheetTextView: NSTextView, TextEditorField {
    private let model: ShowModel
    private(set) var sheet = TextSheet()
    var machineRoot: URL?
    /// Where Copy puts text: the system's pasteboard, or a test's own.
    var pasteboard = NSPasteboard.general
    /// Whether the last key down was a key held: "A merge takes a fresh press".
    var lastKeyWasRepeat = false
    /// The break being dragged, by the cue below it, and how many lines it would move; and where it lands.
    private(set) var dragging: (cue: String, lines: Int)?
    private(set) var dropY: CGFloat?

    /// The margin: the section's label, then the cue's number.
    static let sectionWidth: CGFloat = 96
    static let numberWidth: CGFloat = 34
    static var margin: CGFloat { sectionWidth + numberWidth }
    static let font = NSFont.systemFont(ofSize: 15)
    static var lineHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 4 }

    /// The segment whose text an edit under way changes.
    private var pending: Int?
    /// Set while the page puts text or a selection in, which is no typing and no move of the operator's.
    private var isApplying = false

    init(model: ShowModel) {
        self.model = model
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        font = Self.font
        textColor = Palette.text
        insertionPointColor = Palette.text
        typingAttributes = Self.attributes(color: Palette.text, gap: false)
        selectedTextAttributes = [.backgroundColor: Palette.selection.withAlphaComponent(0.45), .foregroundColor: Palette.text]
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 0, height: 16)
        isContinuousSpellCheckingEnabled = true
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false
        focusRingType = .none
        setAccessibilityRole(.textArea)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private var editor: TextEditor { model.editing.text }

    /// "a section's label in the margin": the text starts after it, on the left only.
    override var textContainerOrigin: NSPoint { NSPoint(x: Self.margin, y: textContainerInset.height) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = max(80, newSize.width - Self.margin - 24)
        if textContainer?.size.width != width { textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
    }

    private static func attributes(color: NSColor, gap: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        // "with a blank line before each new section".
        style.paragraphSpacingBefore = gap ? lineHeight : 0
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    // MARK: - The text (Spec 11 §5, "The sheet view")

    /// What the field shows of a chunk: its own text, the caret's as typed (G-50: "a held text shows as a blank line").
    private func newSheet() -> TextSheet {
        let editor = self.editor
        let empty = editor.isEmptyList ? (editor.caret == TextEditor.emptyChunk ? editor.caretText : "") : nil
        return TextSheet.make(document: editor.document, text: { editor.ownText($0.cue) }, row: { TextWording.row($0) ?? "" },
                              empty: empty, removed: editor.removed)
    }

    /// Brings the field up to date with the editor: cues whose text changed
    /// elsewhere are replaced where they lie, never moving the caret's text or
    /// the scroll; cues made, removed or moved lay the whole field out again.
    func apply() {
        // Mid-edit, the field holds text the sheet doesn't yet: `sync` brings them together first.
        guard pending == nil else { return }
        let next = newSheet()
        isEditable = editor.cannotEdit == nil
        setAccessibilityLabel(Strings.text(.textDocumentSpoken, editor.document.channel))
        let caret = caretPlace()
        isApplying = true
        defer { isApplying = false }
        let storage = textStorage ?? NSTextStorage()
        // Nothing to change: the field, its look and the selection stay as they are, a selection across cues included.
        if next == sheet, storage.string == next.string {
            needsDisplay = true
            return
        }
        if next.segments.map(\.cue) != sheet.segments.map(\.cue) || storage.length != (sheet.string as NSString).length {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: next.string)
        } else {
            for index in next.segments.indices.reversed() where next.segments[index].text != sheet.segments[index].text {
                // The caret's cue keeps what is being composed in it.
                if hasMarkedText(), next.segments[index].cue == caret?.cue { continue }
                storage.replaceCharacters(in: sheet.segments[index].range, with: next.segments[index].text)
            }
        }
        sheet = next
        if let current = textStorage?.string, current != sheet.string {
            // The caret's cue kept its composing text: what the field holds is what the sheet holds.
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: sheet.string)
        }
        restyle()
        if let caret, let index = sheet.index(of: caret.cue) {
            let segment = sheet.segments[index]
            setSelectedRange(NSRange(location: segment.location + min(caret.offset, segment.length), length: 0))
        }
        needsDisplay = true
    }

    /// The caret's cue and its place in that cue's text, before the field changes.
    private func caretPlace() -> (cue: String, offset: Int)? {
        let at = selectedRange().location
        guard let index = sheet.index(at: at) else { return nil }
        return (sheet.segments[index].cue, at - sheet.segments[index].location)
    }

    /// Sets each cue's look: its color, grayed for other content, and the blank line before a new section.
    private func restyle() {
        guard let storage = textStorage, !hasMarkedText() else { return }
        storage.beginEditing()
        for segment in sheet.segments {
            let range = NSRange(location: segment.location, length: min(segment.length + 1, storage.length - segment.location))
            guard range.length > 0 else { continue }
            storage.setAttributes(Self.attributes(color: segment.isEditable ? Palette.text : Palette.faintText, gap: false), range: range)
            if segment.gapBefore {
                let first = (segment.text as NSString).range(of: "\n").location
                let length = first == NSNotFound ? range.length : min(first + 1, range.length)
                storage.setAttributes(Self.attributes(color: segment.isEditable ? Palette.text : Palette.faintText, gap: true),
                                      range: NSRange(location: segment.location, length: length))
            }
        }
        storage.endEditing()
        typingAttributes = Self.attributes(color: Palette.text, gap: false)
    }

    // MARK: - Editing (Spec 11 §5, "The sheet view")

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard !isApplying, let replacement = replacementString else { return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) }
        switch sheet.change(in: affectedCharRange, with: replacement) {
        case .edit(let index, _):
            pending = index
            return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        case .refused, .merge:
            // "typing, Delete, Cut or Paste over a selection that crosses a cue's dashed line does nothing and says
            // "Select within one cue.""; Backspace and forward Delete at a dashed line merge, below.
            editor.refuseAcrossBreaks()
            return false
        case .ignored:
            return false
        }
    }

    override func didChangeText() {
        super.didChangeText()
        guard let index = pending else { return }
        pending = nil
        sync(index)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let target = replacementRange.location != NSNotFound ? replacementRange : (hasMarkedText() ? markedRange() : self.selectedRange())
        guard case .edit(let index, _) = sheet.change(in: target, with: text) else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        pending = nil
        sync(index)
    }

    override func unmarkText() {
        super.unmarkText()
        if let index = sheet.index(at: selectedRange().location) { sync(index) }
    }

    /// One cue's text changed in the field: the sheet follows, and the editor hears it as typing.
    private func sync(_ index: Int) {
        guard sheet.segments.indices.contains(index), let storage = textStorage else { return }
        let segment = sheet.segments[index]
        let delta = storage.length - (sheet.string as NSString).length
        let length = max(0, min(segment.length + delta, storage.length - segment.location))
        let text = (storage.string as NSString).substring(with: NSRange(location: segment.location, length: length))
        sheet.apply(index: index, text: text)
        if editor.caret != segment.cue { editor.enter(segment.cue, sheet: true) }
        editor.typed(text, composing: hasMarkedText())
        restyle()
        needsDisplay = true
    }

    // MARK: - The caret

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { caretMoved() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        if hasMarkedText() { unmarkText() }
        let resigned = super.resignFirstResponder()
        if resigned { editor.leave() }
        return resigned
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        // An edit under way moves the caret before it says what changed; the cue it is in is the edit's (`sync`).
        if !stillSelectingFlag, !isApplying, pending == nil, window?.firstResponder === self { caretMoved() }
    }

    /// The caret moved: into a cue's text, which the editor enters; across cues or onto other content, which it leaves.
    private func caretMoved() {
        let range = selectedRange()
        guard let first = sheet.index(at: range.location), sheet.index(at: range.location + range.length) == first,
              sheet.segments[first].isEditable else {
            editor.leave()
            return
        }
        editor.enter(sheet.segments[first].cue, sheet: true)
    }

    /// Puts the caret in a cue's text: after a split, a merge or a moved line.
    func focus(_ cue: String, at location: Int) {
        guard let index = sheet.index(of: cue) else { return }
        let segment = sheet.segments[index]
        isApplying = true
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        setSelectedRange(NSRange(location: segment.location + max(0, min(location, segment.length)), length: 0))
        isApplying = false
        scrollRangeToVisible(selectedRange())
    }

    /// The caret's cue and its place in that cue's text, for the Edit menu.
    var caretInCue: (cue: String, location: Int)? {
        guard window?.firstResponder === self, let place = caretPlace(), let index = sheet.index(of: place.cue),
              sheet.segments[index].isEditable else { return nil }
        return (place.cue, place.offset)
    }

    // MARK: - Breaks (Spec 11 §5)

    /// "⌥Return ... at the caret".
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        guard isEditable, let place = caretInCue else { return }
        editor.split(at: place.location)
    }

    /// "Backspace or forward Delete at a dashed line merges, as at a chunk's edge", on a fresh press only.
    override func deleteBackward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, let index = sheet.index(at: range.location), index > 0, range.location == sheet.segments[index].location {
            if isEditable, !lastKeyWasRepeat, sheet.segments[index].isEditable, sheet.segments[index - 1].isEditable {
                editor.enter(sheet.segments[index].cue, sheet: true)
                editor.mergeUp()
            }
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0, let index = sheet.index(at: range.location), index + 1 < sheet.segments.count, range.location == sheet.segments[index].end {
            if isEditable, !lastKeyWasRepeat, sheet.segments[index].isEditable, sheet.segments[index + 1].isEditable {
                editor.enter(sheet.segments[index].cue, sheet: true)
                editor.mergeDown()
            }
            return
        }
        super.deleteForward(sender)
    }

    override func keyDown(with event: NSEvent) {
        lastKeyWasRepeat = event.isARepeat
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            leaveEditor()
            return
        }
        super.keyDown(with: event)
    }

    /// "Escape leaves the editor and keeps what was typed".
    override func cancelOperation(_ sender: Any?) { leaveEditor() }

    override func complete(_ sender: Any?) { leaveEditor() }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }

    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }

    private func leaveEditor() {
        window?.makeFirstResponder(enclosingScrollView?.superview?.superview)
    }

    // MARK: - Copy (Spec 11 §5, "The sheet view")

    /// "A selection may run across cues, for copying": a blank line where it
    /// crosses a cue's dashed line; the whole field, as the chunked document's
    /// second ⌘A copies it.
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let whole = range.location == 0 && range.length >= (string as NSString).length
        pasteboard.clearContents()
        pasteboard.setString(whole ? editor.documentText() : sheet.copied(range), forType: .string)
    }

    /// "Text can't be dragged".
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    // MARK: - Lines

    /// The line fragment that the character at `index` sits on, in this view's coordinates; the last empty line at the end.
    func lineRect(at index: Int) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let length = (string as NSString).length
        var rect: NSRect
        if index >= length {
            if layout.extraLineFragmentTextContainer != nil {
                rect = layout.extraLineFragmentUsedRect
            } else if length > 0 {
                rect = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
            } else {
                rect = NSRect(x: 0, y: 0, width: 1, height: Self.lineHeight)
            }
        } else {
            rect = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: max(0, index)), effectiveRange: nil)
        }
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// The first line of a cue, and its last.
    private func firstLine(_ segment: TextSheet.Segment) -> NSRect { lineRect(at: segment.location) }

    private func lastLine(_ segment: TextSheet.Segment) -> NSRect {
        lineRect(at: segment.length == 0 || segment.text.hasSuffix("\n") ? segment.end : segment.end - 1)
    }

    /// "a faint dashed line under each cue": where the line under a cue lies.
    func ruleY(after index: Int) -> CGFloat? {
        guard sheet.segments.indices.contains(index) else { return nil }
        return floor(lastLine(sheet.segments[index]).maxY + 2) + 0.5
    }

    /// The paragraphs of a cue's own text, in this view's coordinates.
    private func paragraphs(_ index: Int) -> [NSRect] {
        let segment = sheet.segments[index]
        guard segment.isEditable, !segment.text.isEmpty else { return [] }
        var rects: [NSRect] = []
        var start = segment.location
        for line in TextBreaks.lines(segment.text) {
            let length = (line as NSString).length
            let top = lineRect(at: start)
            let bottom = lineRect(at: length == 0 ? start : start + length - 1)
            rects.append(NSRect(x: top.minX, y: top.minY, width: max(top.width, bottom.width), height: bottom.maxY - top.minY))
            start += length + 1
        }
        return rects
    }

    // MARK: - Drawing (Spec 11 §5, "The sheet view")

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                                                               .foregroundColor: Palette.faintText]
        let right = bounds.width - 16
        for (index, segment) in sheet.segments.enumerated() {
            let first = firstLine(segment)
            // "its number in the margin at its first line and the live dot by the live cue's".
            if segment.number > 0 {
                let number = NSAttributedString(string: String(segment.number), attributes: numberAttributes)
                let size = number.size()
                number.draw(at: NSPoint(x: Self.margin - 10 - size.width, y: first.midY - size.height / 2))
                if segment.isLive {
                    Palette.live.setFill()
                    NSBezierPath(ovalIn: NSRect(x: Self.margin - 10 - size.width - 11, y: first.midY - 3.5, width: 7, height: 7)).fill()
                }
            }
            // "a section's label in the margin at its first cue".
            if let section = segment.section {
                let label = NSAttributedString(string: section, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                                                                              .foregroundColor: Palette.section(segment.hue) ?? Palette.dimText])
                let size = label.size()
                let width = min(size.width, Self.sectionWidth - 14)
                label.draw(with: NSRect(x: Self.sectionWidth - 6 - width, y: first.midY - size.height / 2, width: width, height: size.height),
                           options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            // "a faint dashed line under each cue, an empty cue's included".
            if index + 1 < sheet.segments.count, let y = ruleY(after: index) {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: Self.margin, y: y))
                path.line(to: NSPoint(x: right, y: y))
                path.lineWidth = 1
                path.setLineDash([4, 3], count: 2, phase: 0)
                NSColor(white: 1, alpha: 0.18).setStroke()
                path.stroke()
            }
        }
        if string.isEmpty, editor.isEmptyList {
            let placeholder = NSAttributedString(string: Strings.text(.textEmpty), attributes: [.font: Self.font, .foregroundColor: Palette.faintText])
            placeholder.draw(at: NSPoint(x: Self.margin + 2, y: textContainerInset.height))
        }
        // Spec 11 §5, "Moving a break" — where a dragged break would land.
        if let dropY {
            Palette.selection.setFill()
            NSRect(x: Self.margin - 4, y: dropY - 1, width: right - Self.margin + 4, height: 2).fill()
        }
    }

    // MARK: - A dragged break (Spec 11 §5, "Moving a break")

    /// The break under the pointer: the cue below the dashed line at `point`, when a line can move across it.
    private func breakAt(_ point: NSPoint) -> Int? {
        guard isEditable, point.x >= Self.margin else { return nil }
        for index in sheet.segments.indices.dropLast() {
            guard let y = ruleY(after: index), abs(point.y - y) <= 4 else { continue }
            let lower = sheet.segments[index + 1]
            guard sheet.segments[index].isEditable, lower.isEditable, editor.breakRange(above: lower.cue) != 0...0 else { return nil }
            return index + 1
        }
        return nil
    }

    /// How far the break above segment `lower` moves for the pointer at `y`.
    private func lines(above lower: Int, at y: CGFloat) -> Int {
        let range = editor.breakRange(above: sheet.segments[lower].cue)
        guard let rule = ruleY(after: lower - 1) else { return 0 }
        if y >= rule { return min(range.upperBound, paragraphs(lower).filter { $0.midY < y }.count) }
        return -min(-range.lowerBound, paragraphs(lower - 1).filter { $0.midY > y }.count)
    }

    private func landing(above lower: Int, lines: Int) -> CGFloat? {
        if lines == 0 { return ruleY(after: lower - 1) }
        if lines > 0 {
            let below = paragraphs(lower)
            return below.indices.contains(lines - 1) ? below[lines - 1].maxY + 2 : nil
        }
        let above = paragraphs(lower - 1)
        return above.indices.contains(above.count + lines) ? above[above.count + lines].minY - 2 : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let lower = breakAt(point) else { return super.mouseDown(with: event) }
        dragging = (sheet.segments[lower].cue, 0)
        dropY = ruleY(after: lower - 1)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = dragging, let lower = sheet.index(of: current.cue) else { return super.mouseDragged(with: event) }
        let y = convert(event.locationInWindow, from: nil).y
        let lines = lines(above: lower, at: y)
        dragging = (current.cue, lines)
        dropY = landing(above: lower, lines: lines)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let current = dragging, let lower = sheet.index(of: current.cue) else { return super.mouseUp(with: event) }
        let lines = lines(above: lower, at: convert(event.locationInWindow, from: nil).y)
        dragging = nil
        dropY = nil
        needsDisplay = true
        if lines != 0 { editor.moveBreak(above: current.cue, by: lines) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEditable else { return }
        for index in sheet.segments.indices.dropLast() {
            guard let y = ruleY(after: index), sheet.segments[index].isEditable, sheet.segments[index + 1].isEditable,
                  editor.breakRange(above: sheet.segments[index + 1].cue) != 0...0 else { continue }
            addCursorRect(NSRect(x: Self.margin, y: y - 4, width: max(0, bounds.width - Self.margin - 16), height: 8), cursor: .resizeUpDown)
        }
    }
}
