// OAppUI — a column of labeled rows for the inspector's forms (Spec 11 §2: "Inspector: the selection's properties"),
// in a scroll view when the inspector is shorter than the form.

import AppKit
import OApp
import OCore

/// A column of rows, each a name on the left and controls across the rest, laid out top down; a row whose controls are
/// all hidden takes no room. It sits in a scroll view, which scrolls when the inspector is shorter than the form.
@MainActor
final class FormColumn: NSView {
    struct Row {
        var name: NSTextField?
        var views: [NSView]
        /// Each view's width, or nil to share what's left.
        var widths: [CGFloat?]
        var height: CGFloat
        /// A row whose views run the column's whole width, under no name.
        var wide: Bool
    }

    private(set) var rows: [Row] = []
    let scroll = NSScrollView()
    /// The names' column, as wide as the widest name up to a share of the column.
    var nameShare: CGFloat = 0.42

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.documentView = self
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A row with a name.
    @discardableResult
    func row(_ name: String?, _ views: [NSView], widths: [CGFloat?]? = nil, height: CGFloat = 24) -> NSTextField? {
        let label = name.map { Kit.label($0, size: 11.5, color: Palette.dimText) }
        if let label { addSubview(label) }
        for view in views { addSubview(view) }
        rows.append(Row(name: label, views: views, widths: widths ?? views.map { _ in nil }, height: height, wide: false))
        return label
    }

    /// A row across the column: a heading, a note, a list.
    func wide(_ view: NSView, height: CGFloat) {
        addSubview(view)
        rows.append(Row(name: nil, views: [view], widths: [nil], height: height, wide: true))
    }

    /// Changes a wide row's height, as a list's grows.
    func setHeight(_ height: CGFloat, of view: NSView) {
        guard let index = rows.firstIndex(where: { $0.views.first === view }) else { return }
        rows[index].height = height
    }

    /// Lays the rows out at the scroll view's width, and sizes itself to them.
    func place() {
        let width = max(0, scroll.contentSize.width)
        let pad: CGFloat = 14
        let inner = max(0, width - 2 * pad)
        // The names of the rows that show now, whatever showed before.
        let names = rows.filter { row in row.views.contains { !$0.isHidden } }.compactMap(\.name)
        let nameWidth = min(inner * nameShare, (names.map { Kit.width(of: $0) }.max() ?? 0) + 10)
        var y: CGFloat = 10
        for row in rows {
            let shown = row.views.contains { !$0.isHidden }
            row.name?.isHidden = !shown
            guard shown else { continue }
            if row.wide {
                row.views[0].frame = NSRect(x: pad, y: y, width: inner, height: row.height)
                y += row.height + 6
                continue
            }
            let x0 = pad + (row.name == nil ? 0 : nameWidth)
            row.name?.frame = NSRect(x: pad, y: y + (row.height - 16) / 2, width: nameWidth - 6, height: 16)
            let visible = zip(row.views, row.widths).filter { !$0.0.isHidden }
            let fixed = visible.compactMap(\.1).reduce(0, +)
            let flexible = visible.filter { $0.1 == nil }.count
            let gap: CGFloat = 6
            let share = flexible == 0 ? 0 : max(0, (pad + inner - x0 - fixed - gap * CGFloat(max(0, visible.count - 1))) / CGFloat(flexible))
            var x = x0
            for (view, width) in visible {
                let w = width ?? share
                view.frame = NSRect(x: x, y: y, width: w, height: row.height)
                x += w + gap
            }
            y += row.height + 6
        }
        frame = NSRect(x: 0, y: 0, width: width, height: max(y + 8, scroll.contentSize.height))
    }
}

/// Numbers as the forms show and take them.
@MainActor
enum FormNumber {
    /// "12", "12.5", "0.35": at most `places` decimals, no trailing zeros.
    static func text(_ value: Double, places: Int = 2) -> String {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.\(places)f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    static func value(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: "."))
    }
}

/// A color as a style holds it (Spec 1 §2: r, g, b and a from 0 to 1) and as a color well shows it.
@MainActor
enum FormColor {
    static func ns(_ color: Color) -> NSColor {
        NSColor(srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: CGFloat(color.a))
    }

    static func value(_ color: NSColor) -> JSONValue {
        let c = color.usingColorSpace(.sRGB) ?? color
        func n(_ v: CGFloat) -> JSONValue { .number((Double(v) * 10000).rounded() / 10000) }
        return .object(["r": n(c.redComponent), "g": n(c.greenComponent), "b": n(c.blueComponent), "a": n(c.alphaComponent)])
    }

    /// The same color as a style or grade holds it, rounded as `value` rounds it.
    static func color(_ color: NSColor) -> Color {
        let c = color.usingColorSpace(.sRGB) ?? color
        func n(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }
        return Color(r: n(c.redComponent), g: n(c.greenComponent), b: n(c.blueComponent), a: n(c.alphaComponent))
    }
}

/// A slider the page's redraws leave alone while it is dragged, and after it is let go until the value it sent comes
/// back from the engine (Adam, 2026-11-26: a grade's sliders "snap back" when dragged). The page redraws on every
/// event the engine sends, its live topics among them, so setting the stored value then would pull the knob from under
/// the operator's hand.
@MainActor
class HeldSlider: NSSlider {
    private(set) var isDragging = false
    /// The value sent, and when, until the model shows it.
    private var sent: (value: Double, at: TimeInterval)?
    /// How long a sent value is held before the model's is shown anyway (the engine may have refused it).
    static let holdSeconds = 2.0
    /// Spec 11 §6 and §9 (G-40) — where a double-click puts the slider back: a grade's identity, a slot's 100%.
    var resetValue: Double?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, resetValue != nil {
            reset()
            return
        }
        isDragging = true
        // AppKit tracks the drag here and returns at mouse up.
        super.mouseDown(with: event)
        isDragging = false
        dragEnded()
    }

    /// The mouse is up: a slider that says its value at the end says it here.
    func dragEnded() {}

    /// Puts the slider back, as a double-click does, and sends it.
    func reset() {
        guard let resetValue else { return }
        doubleValue = resetValue
        // Straight to the target: NSApp's sendAction goes nowhere for a slider outside a window.
        if let action, let target = target as? NSObject { target.perform(action, with: self) }
    }

    /// The value this slider has just sent.
    func noteSent(_ value: Double) {
        sent = (value, ProcessInfo.processInfo.systemUptime)
    }

    /// Shows the model's value unless the slider is being dragged or waits for its own value to come back; says
    /// whether it showed it.
    @discardableResult
    func show(_ value: Double) -> Bool {
        guard !isDragging else { return false }
        if let sent {
            let close = abs(value - sent.value) <= (maxValue - minValue) * 0.002
            let stale = ProcessInfo.processInfo.systemUptime - sent.at > Self.holdSeconds
            guard close || stale else { return false }
            self.sent = nil
        }
        if doubleValue != value { doubleValue = value }
        return true
    }
}

/// A color well that says once what the color panel chose. An NSColorWell that isn't continuous sends nothing when the
/// panel changes its color, not even when the panel lets it go (Adam, 2026-11-25: the tint and a transition's color
/// "snap back"), so the well listens to every change and says the last one when the color has rested a moment, or at
/// once when the panel lets the well go: one edit for a drag across the color wheel, not one a step.
@MainActor
final class FormColorWell: NSColorWell {
    var onChoose: ((NSColor) -> Void)?
    /// The color chosen and not said yet.
    private var pending: NSColor?
    private var rest: Timer?
    /// How long a color rests before it is said.
    static let restSeconds = 0.35

    /// Every color the panel moves through, as it moves: for a picture that follows it (Spec 11 §9, G-43).
    var onChanging: ((NSColor) -> Void)?

    convenience init(label: String) {
        self.init(frame: .zero)
        isContinuous = true
        target = self
        action = #selector(changed)
        setAccessibilityLabel(label)
    }

    @objc private func changed() {
        onChanging?(color)
        pending = color
        rest?.invalidate()
        rest = Timer.scheduledTimer(withTimeInterval: Self.restSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Says the color chosen, if there is one not said yet.
    func flush() {
        rest?.invalidate()
        rest = nil
        guard let color = pending else { return }
        pending = nil
        onChoose?(color)
    }

    /// The panel lets the well go: what it chose is said at once.
    override func deactivate() {
        super.deactivate()
        flush()
    }

    /// Chooses as the panel would, and says it at once.
    func choose(_ color: NSColor) {
        self.color = color
        changed()
        flush()
    }

    /// Whether the color panel is choosing for this well, so the model's color must wait.
    var isChoosing: Bool { isActive || choosingForTest }
    /// A test's stand-in for an open color panel, which needs a screen.
    var choosingForTest = false

    /// Shows the model's color, but not while the panel is choosing for the well: the page redraws on every change
    /// (a picture arriving, another client's edit), and setting the color then would put the panel back to the old
    /// one under the operator's hand (Adam, 2026-11-25: "it keeps resetting").
    func show(_ color: NSColor) {
        guard !isChoosing, pending == nil else { return }
        if self.color != color { self.color = color }
    }
}
