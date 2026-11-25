// OAppUI — the few pieces every region is drawn from: a label, a tag, a flat button, a dot.

import AppKit
import OApp

/// A view whose origin is its top-left corner, with a filled, rounded background: what every region is laid out in.
@MainActor
class Surface: NSView {
    override var isFlipped: Bool { true }

    var fill: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    /// An outline drawn inside the bounds, and how heavy it is.
    var outline: NSColor? { didSet { needsDisplay = true } }
    var outlineWidth: CGFloat = 1 { didSet { needsDisplay = true } }
    var isDashed = false { didSet { needsDisplay = true } }

    /// The outline as it is drawn: Spec 10 §15 — "Increase Contrast thickens borders and outlines."
    var drawnOutlineWidth: CGFloat { outlineWidth * Look.outlineScale }

    override func draw(_ dirtyRect: NSRect) {
        let width = drawnOutlineWidth
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: outline == nil ? 0 : width / 2, dy: outline == nil ? 0 : width / 2),
                                xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let outline {
            outline.setStroke()
            path.lineWidth = width
            if isDashed { path.setLineDash([4, 3], count: 2, phase: 0) }
            path.stroke()
        }
    }
}

@MainActor
enum Kit {
    /// A line of text that never takes typing. With no colour given it is the
    /// palette's text colour. (The default is resolved in here and not in
    /// the signature: Swift 6.0.3's compiler crashes on a main-actor default
    /// argument reached from a stored property's initializer.)
    static func label(_ text: String = "", size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor? = nil, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        field.textColor = color ?? Palette.text
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.isSelectable = false
        return field
    }

    /// A section's heading: small capitals, spaced, quiet (Spec 10 §5: "headers in small capitals").
    static func heading(_ text: String) -> NSTextField {
        let field = label("", size: 10.5, weight: .semibold, color: Palette.faintText)
        setHeading(field, text)
        return field
    }

    static func setHeading(_ field: NSTextField, _ text: String) {
        field.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .kern: 0.8, .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: Palette.faintText,
        ])
        field.setAccessibilityLabel(text)
    }

    /// The width a single line of this field's text needs, as the cell that
    /// draws it measures it now. (Not `intrinsicContentSize`, which AppKit
    /// keeps from before the text last changed; and not the attributed
    /// string's own size, which comes out narrower than the cell draws a
    /// centred line: the countdown read "…" on a real run for that.)
    static func width(of field: NSTextField) -> CGFloat {
        guard !field.stringValue.isEmpty, let cell = field.cell else { return 0 }
        let measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 200)).width
        return ceil(max(measured, field.attributedStringValue.size().width + 4)) + 2
    }

    /// Marks a label that holds what the operator or the library wrote (a
    /// title, a cue's label, a file's name), which may be cut short with an
    /// ellipsis where space runs out. Every other label is the app's own
    /// wording and must fit (Spec 10 §18: "nothing is clipped").
    static let mayTruncate = 1

    @discardableResult
    static func content(_ field: NSTextField) -> NSTextField {
        field.tag = mayTruncate
        return field
    }

    /// Whether a label shows all of its text in the frame it has.
    static func fits(_ field: NSTextField) -> Bool {
        field.stringValue.isEmpty || field.frame.width >= width(of: field) - 0.5
    }

    /// A search field in the window's look, which says it is one (Spec 10 §9, "A text field").
    static func search(placeholder: String) -> NSSearchField {
        let field = ShowSearchField(frame: .zero)
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.focusRingType = .default
        field.setAccessibilityLabel(placeholder)
        field.sendsSearchStringImmediately = true
        return field
    }
}

/// A small word on something: "local", "missing", "updated".
@MainActor
final class TagView: Surface {
    enum Style {
        case quiet, red, amber, dashedRed
    }

    private let label = Kit.label(size: 10, weight: .medium)

    init(_ text: String, style: Style = .quiet) {
        super.init(frame: .zero)
        radius = 4
        addSubview(label)
        set(text, style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(_ text: String, style: Style) {
        label.stringValue = text
        switch style {
        case .quiet:
            fill = Palette.raisedHigh
            outline = nil
            label.textColor = Palette.dimText
        case .red:
            fill = Palette.live.withAlphaComponent(0.18)
            outline = nil
            label.textColor = Palette.live
        case .amber:
            fill = Palette.browsing.withAlphaComponent(0.18)
            outline = nil
            label.textColor = Palette.browsing
        case .dashedRed:
            fill = Palette.live.withAlphaComponent(0.10)
            outline = Palette.live
            isDashed = true
            label.textColor = Palette.live
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        frame.size = fitting
    }

    var text: String { label.stringValue }

    var fitting: NSSize {
        NSSize(width: Kit.width(of: label) + 10, height: 16)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 5, y: 1, width: bounds.width - 10, height: 14)
    }
}

/// A button drawn flat in the window's look. It acts on the press where the
/// spec says so (`actsOnPress`), and is its own VoiceOver button with a
/// label and, when disabled, the reason (Spec 10 §1, §15).
@MainActor
final class FlatButton: NSControl {
    enum Style {
        /// A raised grey button.
        case plain
        /// The large Next.
        case primary
        /// Red and filled: the panic button, and a lit tile.
        case danger
        /// Amber: Back to Live.
        case amber
        /// No background until the pointer is over it.
        case bare
        /// Red in a tint with a red edge: edit mode's Clear All and Fire, "red and set apart" among quiet controls (Spec 11 §2).
        case dangerTint
    }

    var style = Style.plain { didSet { needsDisplay = true } }
    /// Drawn as a small tag, in that tag's colours: a tag that opens
    /// something is a button like any other (Spec 10 §8).
    var tagStyle: TagView.Style? { didSet { refresh() } }
    var title = "" { didSet { refresh() } }
    var fontSize: CGFloat = 12 { didSet { refresh() } }
    var fontWeight = NSFont.Weight.medium { didSet { refresh() } }
    /// Spec 10 §7 — a tile "lights red while all its targets are on, and shows a red outline while only some are".
    var lit = ClearsTile.Lit.off { didSet { needsDisplay = true } }
    /// Selected, as one of a set: a tab, a segment.
    var isOn = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?
    /// Whether it sits on a raised surface, a cell, and so is drawn one step lighter to stand off it.
    var isOnRaised = false { didSet { needsDisplay = true } }
    /// Why it is disabled, shown as its tooltip and read by VoiceOver.
    var reason: String? { didSet { refresh() } }
    private var isDown = false
    private var isHovered = false
    private var tracking: NSTrackingArea?

    init(_ title: String = "", style: Style = .plain, onPress: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.style = style
        self.title = title
        self.onPress = onPress
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var isEnabled: Bool { didSet { refresh() } }

    private var font_: NSFont { .systemFont(ofSize: fontSize, weight: fontWeight) }

    var fitting: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: font_]).width)
        if tagStyle != nil { return NSSize(width: width + 10, height: 16) }
        return NSSize(width: width + 22, height: max(24, fontSize + 12))
    }

    private func drawAsTag(_ tag: TagView.Style) {
        var fill = Palette.raisedHigh
        var text = Palette.dimText
        switch tag {
        case .quiet:
            if isDown || isHovered { fill = fill.blended(withFraction: 0.12, of: .white) ?? fill }
        case .red, .dashedRed:
            fill = Palette.live.withAlphaComponent(isDown || isHovered ? 0.30 : 0.18)
            text = Palette.live
        case .amber:
            fill = Palette.browsing.withAlphaComponent(isDown || isHovered ? 0.30 : 0.18)
            text = Palette.browsing
        }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        fill.setFill()
        path.fill()
        if window?.firstResponder === self {
            Palette.selection.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font_, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// What VoiceOver reads when that isn't the title: a dot's state in words, a glyph's meaning.
    private var spoken: String?

    override func setAccessibilityLabel(_ label: String?) {
        spoken = label
        super.setAccessibilityLabel(label)
    }

    private func refresh() {
        // A disabled control shows why; an enabled one keeps whatever tip its owner gave it.
        if !isEnabled { toolTip = reason } else if toolTip == reason { toolTip = nil }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        super.setAccessibilityLabel(spoken ?? title)
        setAccessibilityEnabled(isEnabled)
        setAccessibilityHelp(isEnabled ? nil : reason)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isDown = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDown else { return }
        isDown = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    /// Presses it, as a click or VoiceOver would.
    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return isEnabled
    }

    /// Spec 10 §15 — "⌥Return or ⌥Space presses or activates whatever has
    /// the focus". Space alone presses too, where no binding holds it (§9).
    override func keyDown(with event: NSEvent) {
        let optionReturn = (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.option)
        if event.charactersIgnoringModifiers == " " || optionReturn { press() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tagStyle { return drawAsTag(tagStyle) }
        var fill: NSColor?
        var text = Palette.text
        var outline: NSColor?
        switch style {
        case .plain:
            let rest = isOnRaised ? Palette.raisedHigh : Palette.raised
            fill = isDown || isHovered ? rest.blended(withFraction: 0.12, of: .white) : rest
        case .primary: fill = Palette.selection.blended(withFraction: isDown ? 0.2 : 0, of: .black)
        case .danger: fill = Palette.live.blended(withFraction: isDown ? 0.2 : 0, of: .black)
        case .amber:
            fill = Palette.browsing.withAlphaComponent(isDown ? 0.32 : 0.2)
            text = Palette.browsing
        case .bare: fill = isHovered || isDown ? Palette.raised : nil
        case .dangerTint:
            fill = Palette.live.withAlphaComponent(isDown ? 0.30 : (isHovered ? 0.22 : 0.14))
            text = NSColor(srgbRed: 1, green: 0x8D / 255, blue: 0x87 / 255, alpha: 1)
            outline = Palette.live.withAlphaComponent(0.5)
        }
        if isOn {
            // Blue for selection (Spec 10 §4) on a cell; a step lighter for the chosen one of a set.
            fill = isOnRaised ? Palette.selection : Palette.raisedHigh
            if isOnRaised { text = .white }
        }
        switch lit {
        case .off: break
        case .some: outline = Palette.live
        case .all:
            fill = Palette.live
            text = .white
        }
        if style == .primary || style == .danger { text = .white }
        if !isEnabled {
            fill = style == .bare ? nil : Palette.raised.withAlphaComponent(0.6)
            text = Palette.faintText
            outline = nil
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let outline {
            outline.setStroke()
            path.lineWidth = 1.5 * Look.outlineScale
            path.stroke()
        }
        if window?.firstResponder === self {
            Palette.selection.setStroke()
            path.lineWidth = 2 * Look.outlineScale
            path.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font_, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attributes)
        let x = leading ? 8 : (bounds.width - size.width) / 2
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// Whether the title starts at the left, as a row of a list does, rather than in the middle.
    var leading = false { didSet { needsDisplay = true } }

    /// Whether the title fits the button as it is laid out; the clipping test reads it (Spec 10 §18).
    var titleFits: Bool {
        (title as NSString).size(withAttributes: [.font: font_]).width <= bounds.width - 8
    }
}

/// A dot: filled, or hollow (Spec 10 §8: "filled green while presenting,
/// and otherwise a hollow red shape"), so its state isn't told by colour alone.
@MainActor
final class DotView: NSView {
    var color = Palette.live { didSet { needsDisplay = true } }
    var isHollow = false { didSet { needsDisplay = true } }
    /// A square in place of a circle: the shape of something wrong (Spec 10 §15).
    var isSquare = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = isSquare ? NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2) : NSBezierPath(ovalIn: rect)
        if isHollow {
            color.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        } else {
            color.setFill()
            path.fill()
        }
    }
}
