// OAppUI — Spec 11 §5, one chunk's text: a text view that takes typing for one cue and never reaches past its break.

import AppKit
import OApp
import OCore

/// Marks the text editor's views for the keys: "The editor is a text field
/// (Spec 10 §9): it takes every key but ⇧⎋, a binding that includes `ctrl`,
/// and the function keys", and the top bar says "Editing text: ⌥Return
/// splits · Esc leaves" while it has the focus (Spec 11 §5, "Keys").
@MainActor
protocol TextEditorField: AnyObject {}

/// Spec 11 §5 — one chunk's text view. "Selection stays within one chunk, so
/// no keystroke ever reaches two cues": each cue's chunk is a text view of its
/// own, so a selection can't cross a break, and the page moves the caret from
/// one to the next at their edges. "The text itself is plain, in the system
/// font ... Spelling is underlined but never corrected, and text replacement
/// is off, so "Thee" stays "Thee"." "The text view keeps no undo of its own,
/// so its text never parts from the library's."
@MainActor
final class ChunkTextView: NSTextView, TextEditorField {
    /// Where the caret goes out of the chunk, at the caret's place across the line for up and down.
    enum Edge: Equatable {
        case up(x: CGFloat)
        case down(x: CGFloat)
        case left
        case right
    }

    /// The cue whose chunk this is, by its uuid in lower case.
    var cue = ""
    var onFocus: ((ChunkTextView) -> Void)?
    var onBlur: ((ChunkTextView) -> Void)?
    /// The whole text, and whether an input method is still composing part of it.
    var onChange: ((ChunkTextView, String, Bool) -> Void)?
    var onEdge: ((ChunkTextView, Edge) -> Void)?
    /// Escape and ⌘Return: "Escape leaves the editor and keeps what was typed"; "⌘Return leaves the editor".
    var onLeave: ((ChunkTextView) -> Void)?
    /// ⌘A on a chunk already selected whole: true when the page took it, as the whole document's selection.
    var onSelectAll: ((ChunkTextView) -> Bool)?
    /// Whether the whole document is selected, which takes Copy only.
    var isDocumentSelected: () -> Bool = { false }
    /// Copy while the whole document is selected.
    var onCopyDocument: (() -> Void)?
    /// Typing, Delete, Cut or Paste met the whole document's selection.
    var onRefused: (() -> Void)?
    /// Anything that moves the caret or the selection while the whole document is selected ends that selection.
    var onSelectionMoved: (() -> Void)?
    /// Whether the last key down was a key held: "A merge takes a fresh press: a held key stops at the chunk's edge."
    private(set) var lastKeyWasRepeat = false
    /// Set while the page puts text or a selection in, which is no typing and no move of the operator's.
    private var isSettingProgrammatically = false

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 2
        layout.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 24), textContainer: container)
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        font = Self.font
        textColor = Palette.text
        insertionPointColor = Palette.text
        typingAttributes = [.font: Self.font, .foregroundColor: Palette.text]
        selectedTextAttributes = [.backgroundColor: Palette.selection.withAlphaComponent(0.45), .foregroundColor: Palette.text]
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 0, height: 3)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    /// "in the system font".
    static let font = NSFont.systemFont(ofSize: 15)

    // MARK: - Text the page puts in

    /// Shows `text` in `color` without it counting as typing; the caret stays at its place where it can.
    func show(_ text: String, color: NSColor) {
        let changed = string != text
        let recolor = textColor != color
        guard changed || recolor else { return }
        isSettingProgrammatically = true
        defer { isSettingProgrammatically = false }
        let place = selectedRange()
        if changed { string = text }
        textColor = color
        typingAttributes = [.font: Self.font, .foregroundColor: color]
        if changed {
            let length = (string as NSString).length
            setSelectedRange(NSRange(location: min(place.location, length), length: 0))
        }
    }

    /// Puts the caret at a place in the text, from the page.
    func placeCaret(at location: Int) {
        isSettingProgrammatically = true
        defer { isSettingProgrammatically = false }
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: max(0, min(location, length)), length: 0))
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(self) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        // Text being composed is entered as the caret leaves: what the operator sees is what is sent.
        if hasMarkedText() { unmarkText() }
        let resigned = super.resignFirstResponder()
        if resigned { onBlur?(self) }
        return resigned
    }

    // MARK: - Typing (Spec 11 §5, "Typing")

    override func didChangeText() {
        super.didChangeText()
        guard !isSettingProgrammatically else { return }
        onChange?(self, string, hasMarkedText())
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onChange?(self, self.string, hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        onChange?(self, string, false)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isDocumentSelected() {
            onRefused?()
            return false
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    // MARK: - Selection (Spec 11 §5)

    /// "A second ⌘A selects the whole document, for Copy only."
    override func selectAll(_ sender: Any?) {
        let whole = NSRange(location: 0, length: (string as NSString).length)
        if selectedRange() == whole || whole.length == 0, onSelectAll?(self) == true { return }
        super.selectAll(sender)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        if !isSettingProgrammatically, isDocumentSelected() { onSelectionMoved?() }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
    }

    override func copy(_ sender: Any?) {
        if isDocumentSelected() {
            onCopyDocument?()
            return
        }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if isDocumentSelected() {
            onRefused?()
            return
        }
        super.cut(sender)
    }

    /// "Text can't be dragged".
    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool { false }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }

    // MARK: - Keys (Spec 11 §5, "Keys")

    override func keyDown(with event: NSEvent) {
        lastKeyWasRepeat = event.isARepeat
        if Self.isCommandReturn(event) {
            onLeave?(self)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.isCommandReturn(event), window?.firstResponder === self {
            onLeave?(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isCommandReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    /// "Escape leaves the editor and keeps what was typed, which has already been sent".
    override func cancelOperation(_ sender: Any?) {
        onLeave?(self)
    }

    /// Escape is completion in a plain text view; here it leaves, as everywhere in the app.
    override func complete(_ sender: Any?) {
        onLeave?(self)
    }

    /// "Tab and ⇧Tab move the focus on (Spec 10 §15)."
    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(self)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }

    override func moveUp(_ sender: Any?) {
        if selectedRange().length == 0, isOnFirstLine {
            onEdge?(self, .up(x: caretX))
            return
        }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if selectedRange().length == 0, isOnLastLine {
            onEdge?(self, .down(x: caretX))
            return
        }
        super.moveDown(sender)
    }

    override func moveLeft(_ sender: Any?) {
        if selectedRange() == NSRange(location: 0, length: 0) {
            onEdge?(self, .left)
            return
        }
        super.moveLeft(sender)
    }

    override func moveRight(_ sender: Any?) {
        let length = (string as NSString).length
        if selectedRange() == NSRange(location: length, length: 0) {
            onEdge?(self, .right)
            return
        }
        super.moveRight(sender)
    }

    // MARK: - Lines

    /// The line fragment a character sits on, laid out now; the line after a last newline for the end.
    func lineRect(at index: Int) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let length = (string as NSString).length
        if index >= length {
            if layout.extraLineFragmentTextContainer != nil { return layout.extraLineFragmentRect }
            guard length > 0 else { return .zero }
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
        }
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: max(0, index)), effectiveRange: nil)
    }

    var isOnFirstLine: Bool {
        lineRect(at: selectedRange().location).minY <= lineRect(at: 0).minY + 0.5
    }

    var isOnLastLine: Bool {
        lineRect(at: selectedRange().location).maxY >= lineRect(at: (string as NSString).length).maxY - 0.5
    }

    /// The caret's place across its line, in the view's own coordinates.
    var caretX: CGFloat {
        guard let layout = layoutManager else { return 0 }
        let index = selectedRange().location
        let length = (string as NSString).length
        guard length > 0 else { return textContainerOrigin.x }
        if index >= length {
            let glyph = layout.glyphIndexForCharacter(at: length - 1)
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer ?? NSTextContainer())
            return textContainerOrigin.x + (string.hasSuffix("\n") ? line.minX : bounds.maxX)
        }
        let glyph = layout.glyphIndexForCharacter(at: index)
        return textContainerOrigin.x + layout.location(forGlyphAt: glyph).x + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
    }

    /// Puts the caret on the first or the last line, nearest to `x` across it.
    func placeCaret(onFirstLine first: Bool, x: CGFloat) {
        let length = (string as NSString).length
        let line = first ? lineRect(at: 0) : lineRect(at: length)
        let point = NSPoint(x: x, y: textContainerOrigin.y + line.midY)
        placeCaret(at: characterIndexForInsertion(at: point))
    }

    /// The height the text takes at the view's width.
    var textHeight: CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 24 }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height + 2 * textContainerInset.height)
    }
}
