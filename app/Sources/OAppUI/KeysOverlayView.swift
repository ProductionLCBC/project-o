// OAppUI — Spec 10 §9, the keys overlay and the command bar.

import AppKit
import OApp

/// A key as a keycap: its drawing on a raised, rounded box.
@MainActor
final class KeyCapView: Surface {
    let label = Kit.label(size: 12, weight: .medium)

    init(_ text: String) {
        super.init(frame: .zero)
        fill = Palette.raisedHigh
        radius = 5
        label.stringValue = text
        label.alignment = .center
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var fitting: NSSize { NSSize(width: Kit.width(of: label) + 16, height: 22) }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 4, y: 3, width: bounds.width - 8, height: 16)
    }
}

/// Spec 10 §9, "The keys overlay" — "(Help ▸ Keys, ⌘/, or ? in the top bar)
/// lists every binding as its key, drawn as the current keyboard layout
/// labels it, and its command's plain name (§15), then the fixed keys and
/// ⌥-double-click (§6). ... Escape or a click closes it."
///
/// It lies over the whole window and takes every press, so a click that
/// closes it does nothing else. The show keys keep firing under it: looking
/// at the keys doesn't stop the show (Area 13 reading).
@MainActor
final class KeysOverlayView: Surface {
    var onClose: (() -> Void)?
    private let panel = Surface()
    private let scroll = NSScrollView()
    private let document = Surface()
    private let title = Kit.label(Strings.text(.menuKeys), size: 17, weight: .semibold)
    private let close = Kit.label(Strings.text(.keysClose), size: 11.5)
    /// What the document holds, top to bottom.
    private enum Item {
        case heading(NSTextField)
        case row(KeyCapView, NSTextField)
        case line(NSTextField)
        case gap(CGFloat)
    }
    private var items: [Item] = []
    private var contentHeight: CGFloat = 0
    private(set) var overlay: KeysOverlay

    static let panelWidth: CGFloat = 620

    init(_ overlay: KeysOverlay) {
        self.overlay = overlay
        super.init(frame: .zero)
        fill = Palette.well.withAlphaComponent(0.78)
        panel.fill = Palette.panel
        panel.radius = 12
        panel.outline = Palette.hairline
        close.textColor = Palette.faintText
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        addSubview(panel)
        for view in [title, close, scroll] as [NSView] { panel.addSubview(view) }
        // VoiceOver stays in the overlay while it is up, and reads it as one group named Keys.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Strings.text(.menuKeys))
        setAccessibilityModal(true)
        show(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    private func paragraph(_ text: String, color: NSColor, size: CGFloat = 12.5) -> NSTextField {
        let label = Kit.label(text, size: size, color: color)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        return label
    }

    /// Lists a table's keys.
    func show(_ overlay: KeysOverlay) {
        self.overlay = overlay
        document.subviews.forEach { $0.removeFromSuperview() }
        items = []
        func add(_ rows: [KeysOverlay.Row]) {
            for row in rows {
                let cap = KeyCapView(row.key)
                let what = paragraph(row.what, color: Palette.text)
                // The key and what it does read as one line.
                what.setAccessibilityLabel(row.key + ": " + row.what)
                items.append(.row(cap, what))
            }
        }
        // "warn when nothing is bound to `next` or to `system clearall`": first, where it is seen.
        for warning in overlay.warnings { items.append(.line(paragraph(warning, color: Palette.browsing))) }
        if !overlay.warnings.isEmpty { items.append(.gap(8)) }
        items.append(.heading(Kit.heading(Strings.text(.keysBindings))))
        if overlay.bindings.isEmpty { items.append(.line(paragraph(Strings.text(.keysNone), color: Palette.dimText))) }
        add(overlay.bindings)
        for ignored in overlay.ignored { items.append(.line(paragraph(ignored, color: Palette.browsing))) }
        items.append(.gap(10))
        items.append(.heading(Kit.heading(Strings.text(.keysFixed))))
        add(overlay.fixed)
        items.append(.gap(10))
        for note in overlay.notes { items.append(.line(paragraph(note, color: Palette.dimText))) }
        for item in items {
            switch item {
            case .heading(let label), .line(let label): document.addSubview(label)
            case .row(let cap, let what):
                document.addSubview(cap)
                document.addSubview(what)
            case .gap: break
            }
        }
        needsLayout = true
    }

    private func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        guard let cell = label.cell else { return 17 }
        return ceil(cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height)
    }

    override func layout() {
        super.layout()
        let width = min(Self.panelWidth, bounds.width - 48)
        let inner = width - 48
        // The keys' column is as wide as the widest key, and never more than two fifths of the panel.
        var caps: CGFloat = 0
        for case .row(let cap, _) in items { caps = max(caps, cap.fitting.width) }
        caps = min(caps, inner * 0.4)
        var y: CGFloat = 0
        for item in items {
            switch item {
            case .heading(let label):
                label.frame = NSRect(x: 0, y: y + 6, width: inner, height: 14)
                y += 26
            case .line(let label):
                let h = height(of: label, width: inner)
                label.frame = NSRect(x: 0, y: y, width: inner, height: h)
                y += h + 6
            case .row(let cap, let what):
                let capWidth = min(cap.fitting.width, caps)
                let whatWidth = inner - caps - 14
                let h = max(22, height(of: what, width: whatWidth))
                cap.frame = NSRect(x: caps - capWidth, y: y, width: capWidth, height: 22)
                what.frame = NSRect(x: caps + 14, y: y + (h > 22 ? 0 : 3), width: whatWidth, height: h > 22 ? h : 17)
                y += h + 6
            case .gap(let gap):
                y += gap
            }
        }
        contentHeight = y
        let chrome: CGFloat = 20 + 24 + 14 + 16 + 16 + 18
        let height = min(contentHeight + chrome, bounds.height - 48)
        panel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        title.frame = NSRect(x: 24, y: 20, width: inner, height: 24)
        scroll.frame = NSRect(x: 24, y: 20 + 24 + 14, width: inner, height: max(0, height - chrome + 0))
        document.frame = NSRect(x: 0, y: 0, width: inner, height: max(contentHeight, scroll.frame.height))
        close.frame = NSRect(x: 24, y: height - 18 - 16, width: inner, height: 16)
    }

    /// "Escape or a click closes it."
    override func mouseDown(with event: NSEvent) { onClose?() }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
    /// Nothing under the overlay is dragged or scrolled through it.
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    /// What the overlay shows, for a test: each row's key and what it does, and every other line.
    var shownRows: [(key: String, what: String)] {
        items.compactMap { item in
            if case .row(let cap, let what) = item { return (cap.label.stringValue, what.stringValue) }
            return nil
        }
    }

    var shownLines: [String] {
        items.compactMap { item in
            if case .line(let label) = item { return label.stringValue }
            return nil
        }
    }
}

/// Spec 10 §9, "The command bar" — "a field across the top of the center
/// when on. ⌘K focuses it. As the operator types, it shows the canonical
/// form, or the error, from OCore's parser (Spec 2 §4); Return sends the
/// command with source `commandbar` and shows the result or the rejection
/// beside it; ↑ and ↓ recall the last fifty commands of the run."
@MainActor
final class CommandBarView: Surface, NSTextFieldDelegate {
    static let height: CGFloat = 54

    private let keys: KeysModel
    let field = ShowField(kind: .commandBar)
    /// The canonical form or the parser's error, under the field.
    let preview = Kit.content(Kit.label(size: 11.5, mono: true))
    /// What became of the last command sent, beside it.
    let outcome = Kit.content(Kit.label(size: 11.5))

    init(keys: KeysModel) {
        self.keys = keys
        super.init(frame: .zero)
        fill = Palette.panel
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.placeholderString = Strings.text(.commandBarPlaceholder)
        field.setAccessibilityLabel(Strings.text(.commandBarLabel))
        field.delegate = self
        field.target = self
        field.action = #selector(returned)
        outcome.alignment = .right
        for view in [field, preview, outcome] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let bar = keys.bar
        if field.stringValue != bar.text { field.stringValue = bar.text }
        switch bar.preview {
        case .empty:
            preview.stringValue = ""
        case .canonical(let text):
            preview.stringValue = text
            preview.textColor = Palette.dimText
        case .error(let message):
            preview.stringValue = message
            preview.textColor = Palette.live
        }
        outcome.stringValue = KeyWording.outcome(of: bar) ?? ""
        switch bar.outcome {
        case .rejected, .engineAway, .result(.rejected), .result(.blocked): outcome.textColor = Palette.live
        default: outcome.textColor = Palette.dimText
        }
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) {
        keys.typeInBar(field.stringValue)
    }

    @objc private func returned() {
        // The bar keeps the focus: "Search fields and the command bar keep the focus until Escape or a click elsewhere."
        keys.submitBar()
    }

    /// ↑ and ↓ recall what was sent.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveUp(_:)) {
            recall(earlier: true)
            return true
        }
        if selector == #selector(NSResponder.moveDown(_:)) {
            recall(earlier: false)
            return true
        }
        return false
    }

    func recall(earlier: Bool) {
        keys.recallInBar(earlier: earlier)
        field.stringValue = keys.bar.text
        // The cursor goes to the end of what was recalled.
        field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    /// Types a line and presses Return, as the operator would.
    func enter(_ text: String) {
        field.stringValue = text
        keys.typeInBar(text)
        returned()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        field.frame = NSRect(x: 16, y: 8, width: w - 32, height: 24)
        let outcomeWidth = min(Kit.width(of: outcome), (w - 32) * 0.5)
        outcome.frame = NSRect(x: w - 16 - outcomeWidth, y: 35, width: outcomeWidth, height: 15)
        preview.frame = NSRect(x: 18, y: 35, width: max(0, w - 36 - outcomeWidth - 12), height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Palette.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }
}
