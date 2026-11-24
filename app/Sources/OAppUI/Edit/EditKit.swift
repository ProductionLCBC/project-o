// OAppUI — Spec 11 §2, the pieces edit mode's regions are drawn from: a panel, a segmented control, a pill.

import AppKit
import OApp

extension Palette {
    /// Spec 11 §2 — "three more fills of the same family: #060708 between the panels".
    static let gut = NSColor(srgbRed: 0x06 / 255, green: 0x07 / 255, blue: 0x08 / 255, alpha: 1)
    /// The line where a region's fixed part meets what scrolls under it.
    static let hairlineStrong = NSColor(white: 1, alpha: 0.13)
}

/// Spec 11 §2, "Keys" — a view that, with the focus, takes the arrows and
/// the delete keys in edit mode: "a focused cue grid, canvas, or list in the
/// workspace or the inspector". `KeyTap` reads it.
@MainActor
protocol EditFocus: NSView {}

/// Spec 11 §2 — one of edit mode's regions: "panels on a darker ground",
/// each with a header 36 points high over its body.
@MainActor
class PanelView: Surface {
    static let headerHeight = CGFloat(EditFrame.panelHeader)

    let title = Kit.label(size: 12, weight: .semibold)
    /// Whether the panel has a header at all; a panel without one is all body.
    var hasHeader = true { didSet { needsLayout = true; needsDisplay = true } }

    init(title text: String = "") {
        super.init(frame: .zero)
        fill = Palette.panel
        radius = 6
        outline = Palette.hairline
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        title.stringValue = text
        title.isHidden = text.isEmpty
        addSubview(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Where the body sits, under the header.
    var body: NSRect {
        let top = hasHeader ? Self.headerHeight : 0
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 12, y: (Self.headerHeight - 16) / 2, width: min(Kit.width(of: title), max(0, bounds.width - 24)), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard hasHeader else { return }
        Palette.hairline.setFill()
        NSRect(x: 0, y: Self.headerHeight - 1, width: bounds.width, height: 1).fill()
    }
}

/// A segmented control in edit mode's look: a well with its segments in it,
/// the chosen one raised. Each segment is a button of its own, so each takes
/// the keyboard focus and says whether it is chosen (Spec 10 §15).
@MainActor
final class SegmentedView: Surface {
    private(set) var segments: [FlatButton] = []
    /// The chosen segment, or nil for none.
    var selected: Int? { didSet { mark() } }
    var onSelect: ((Int) -> Void)?
    /// Segments of equal width across the whole control, or each as wide as its title.
    var fills = false { didSet { needsLayout = true } }
    private let segmentHeight: CGFloat

    init(_ titles: [String], small: Bool = false) {
        segmentHeight = small ? 20 : 24
        super.init(frame: .zero)
        fill = Palette.well
        radius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        set(titles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func set(_ titles: [String]) {
        guard titles != segments.map(\.title) else { return }
        segments.forEach { $0.removeFromSuperview() }
        segments = titles.enumerated().map { index, title in
            let button = FlatButton(title, style: .bare)
            button.fontSize = 12
            button.onPress = { [weak self] in self?.onSelect?(index) }
            addSubview(button)
            return button
        }
        mark()
        needsLayout = true
    }

    private func mark() {
        for (index, button) in segments.enumerated() {
            button.isOn = index == selected
            button.fontWeight = index == selected ? .semibold : .medium
            button.setAccessibilityRole(.radioButton)
            button.setAccessibilityValue(index == selected ? 1 : 0)
        }
    }

    /// Disables a segment, with why.
    func disable(_ index: Int, reason: String?) {
        guard segments.indices.contains(index) else { return }
        segments[index].isEnabled = reason == nil
        segments[index].reason = reason
    }

    var fitting: NSSize {
        NSSize(width: segments.reduce(4) { $0 + $1.fitting.width + 2 } - 2 + 0, height: segmentHeight + 4)
    }

    override func layout() {
        super.layout()
        guard !segments.isEmpty else { return }
        var x: CGFloat = 2
        let equal = (bounds.width - 4 - CGFloat(segments.count - 1) * 2) / CGFloat(segments.count)
        for button in segments {
            let width = fills ? equal : button.fitting.width
            button.frame = NSRect(x: x, y: 2, width: width, height: bounds.height - 4)
            x += width + 2
        }
    }
}

/// A pill: a short word in a capsule, with a dot before it where it reports
/// a state, as edit mode's top bar and the Program monitor carry (Spec 11
/// §2). It is a button where it opens something.
@MainActor
final class PillButton: NSControl {
    enum Style {
        /// A quiet grey pill: "Saved", "Engine", "Preview only".
        case quiet
        /// The live red: "On air · Out 1, 2".
        case live
        /// Amber, for something waiting or a warning.
        case amber
        /// Red, for something wrong.
        case red
        /// Dashed and faint: something that can be added.
        case add
        /// Raised, with the text's full colour: a value that is set.
        case set
    }

    /// The dot's look: none, filled, or hollow (and square where something is wrong), so its state isn't told by colour alone.
    enum Dot {
        case none
        case filled(NSColor)
        case hollow(NSColor, square: Bool)
    }

    static let height: CGFloat = 20

    var title = "" { didSet { refresh() } }
    var style = Style.quiet { didSet { needsDisplay = true } }
    var dot = Dot.none { didSet { needsDisplay = true } }
    var onPress: (() -> Void)? { didSet { refresh() } }
    private var isDown = false
    private var spoken: String?

    init(_ title: String = "", style: Style = .quiet, onPress: (() -> Void)? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.style = style
        self.onPress = onPress
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { onPress != nil && isEnabled }

    private var font_: NSFont { .systemFont(ofSize: 11, weight: .medium) }

    private var hasDot: Bool {
        if case .none = dot { return false }
        return true
    }

    var fitting: NSSize {
        let width = ceil((title as NSString).size(withAttributes: [.font: font_]).width)
        return NSSize(width: width + 16 + (hasDot ? 12 : 0), height: Self.height)
    }

    override func setAccessibilityLabel(_ label: String?) {
        spoken = label
        super.setAccessibilityLabel(label)
    }

    private func refresh() {
        setAccessibilityElement(true)
        setAccessibilityRole(onPress == nil ? .staticText : .button)
        super.setAccessibilityLabel(spoken ?? title)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard onPress != nil, isEnabled else { return super.mouseDown(with: event) }
        isDown = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDown else { return }
        isDown = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        press()
        return onPress != nil
    }

    override func keyDown(with event: NSEvent) {
        let optionReturn = (event.keyCode == 36 || event.keyCode == 76) && event.modifierFlags.contains(.option)
        if event.charactersIgnoringModifiers == " " || optionReturn { press() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        var fill: NSColor? = Palette.raised
        var text = Palette.dimText
        var dashed = false
        switch style {
        case .quiet: break
        case .set: text = Palette.text
        case .live:
            fill = Palette.live.withAlphaComponent(0.14)
            text = NSColor(srgbRed: 1, green: 0x8D / 255, blue: 0x87 / 255, alpha: 1)
        case .amber:
            fill = Palette.browsing.withAlphaComponent(0.16)
            text = Palette.browsing
        case .red:
            fill = Palette.live.withAlphaComponent(0.18)
            text = Palette.live
        case .add:
            fill = nil
            text = Palette.faintText
            dashed = true
        }
        if isDown, let base = fill { fill = base.blended(withFraction: 0.15, of: .white) }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if dashed {
            Palette.hairlineStrong.setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
        }
        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            Palette.selection.setStroke()
            ring.lineWidth = 2 * Look.outlineScale
            ring.stroke()
        }
        var x: CGFloat = 8
        let mark = NSRect(x: x, y: (bounds.height - 7) / 2, width: 7, height: 7)
        switch dot {
        case .none: break
        case .filled(let color):
            color.setFill()
            NSBezierPath(ovalIn: mark).fill()
            x += 12
        case .hollow(let color, let square):
            color.setStroke()
            let shape = square ? NSBezierPath(roundedRect: mark.insetBy(dx: 0.5, dy: 0.5), xRadius: 1.5, yRadius: 1.5) : NSBezierPath(ovalIn: mark.insetBy(dx: 0.5, dy: 0.5))
            shape.lineWidth = 1.5
            shape.stroke()
            x += 12
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font_, .foregroundColor: text]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }

    /// Whether the title fits the pill as it is laid out; the clipping test reads it (Spec 10 §18).
    var titleFits: Bool { bounds.width >= fitting.width - 0.5 }
}
