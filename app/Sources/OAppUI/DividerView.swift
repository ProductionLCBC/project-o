// OAppUI — Spec 10 §4 and §6, the dividers between the regions; Spec 10 §8, an output's details.

import AppKit
import OApp
import OCore

/// A divider the operator drags: between two columns, or between two rows.
/// It draws nothing of its own (the regions draw the one hairline between
/// them); it is the few points either side of that line that take the drag.
@MainActor
final class DividerView: NSView {
    enum Axis {
        /// Between two columns: dragged left and right.
        case columns
        /// Between two rows: dragged up and down.
        case rows
    }

    static let thickness: CGFloat = 7
    private let axis: Axis
    var onBegin: (() -> Void)?
    /// How far the pointer is from where the drag began: to the right, or downwards, is positive.
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var origin = NSPoint.zero
    private var isDragging = false

    init(axis: Axis, label: String) {
        self.axis = axis
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .columns ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        origin = event.locationInWindow
        isDragging = true
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let point = event.locationInWindow
        // The window's own coordinates run upwards, so downwards is the origin's y less the pointer's.
        onDrag?(axis == .columns ? point.x - origin.x : origin.y - point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onEnd?()
    }

    /// Drags it by so many points and lets go, as the pointer would.
    func drag(by delta: CGFloat) {
        onBegin?()
        onDrag?(delta)
        onEnd?()
    }
}

/// Spec 10 §8 — "A click opens the output's details (its device, format,
/// reference, state, and its presented, late and dropped counts from
/// `metrics`) with a Stack ▸ menu that switches its live stack (`output N
/// stack M`), and, for an output on a screen, Release This Screen ... or Put
/// Back on This Screen while they are released" (corrected 2026-11-24).
@MainActor
final class OutputDetailsView: Surface {
    let title = Kit.content(Kit.label(size: 13, weight: .semibold))
    private(set) var rows: [(name: NSTextField, value: NSTextField)] = []
    private let stackName = Kit.label(Strings.text(.outputStack), size: 12)
    let stack = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The screen's button, under the Stack menu; nil for an output on a card or the network.
    private(set) var screenButton: FlatButton?
    private let onStack: (Int) -> Void
    static let width: CGFloat = 320

    /// `onScreen` takes the screen and whether it is put back (true) or released (false).
    init(_ details: OutputDetails, stacks: [Stack], cannotSend: Unavailable?, onStack: @escaping (Int) -> Void,
         onScreen: ((String, Bool) -> Void)? = nil) {
        self.onStack = onStack
        super.init(frame: .zero)
        if let screen = details.screen, let onScreen {
            // Release and put back are the window's, not commands: they go however the lock stands, as ⌃⌥⌘⎋ does (§9).
            let putBack = details.state == .released
            let button = FlatButton(Strings.text(putBack ? .outputPutBackScreen : .outputReleaseScreen), style: .plain)
            button.onPress = { onScreen(screen, putBack) }
            addSubview(button)
            screenButton = button
        }
        fill = Palette.panel
        title.stringValue = Strings.text(.outputTitle, details.number, details.label)
        addSubview(title)
        for row in ShowWording.rows(details) {
            let name = Kit.label(row.name, size: 12, color: Palette.dimText)
            let value = Kit.content(Kit.label(row.value, size: 12, mono: true))
            value.alignment = .right
            value.toolTip = row.value
            // VoiceOver reads a row as one thing: "Format, 1920 × 1080 · 60p".
            name.setAccessibilityLabel(row.name + ", " + row.value)
            value.setAccessibilityElement(false)
            addSubview(name)
            addSubview(value)
            rows.append((name, value))
        }
        stackName.textColor = Palette.dimText
        stack.font = .systemFont(ofSize: 12)
        for entry in stacks.sorted(by: { $0.number < $1.number }) {
            stack.addItem(withTitle: Strings.text(.previewStack, entry.number, entry.label))
            stack.lastItem?.tag = entry.number
        }
        stack.selectItem(withTag: details.stack)
        stack.isEnabled = cannotSend == nil
        stack.toolTip = ShowWording.unavailable(cannotSend)
        stack.setAccessibilityLabel(Strings.text(.outputStack))
        stack.target = self
        stack.action = #selector(picked)
        addSubview(stackName)
        addSubview(stack)
        frame = NSRect(x: 0, y: 0, width: Self.width, height: 46 + CGFloat(rows.count) * 22 + 44 + (screenButton == nil ? 0 : 38))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func picked() {
        if let number = stack.selectedItem?.tag { onStack(number) }
    }

    /// Chooses a stack, as the menu would.
    func choose(stack number: Int) {
        stack.selectItem(withTag: number)
        picked()
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 16, y: 14, width: w - 32, height: 18)
        var y: CGFloat = 44
        for (name, value) in rows {
            let nameWidth = Kit.width(of: name)
            name.frame = NSRect(x: 16, y: y, width: nameWidth, height: 16)
            value.frame = NSRect(x: 16 + nameWidth + 8, y: y, width: max(0, w - 32 - nameWidth - 8), height: 16)
            y += 22
        }
        let stackWidth = Kit.width(of: stackName)
        stackName.frame = NSRect(x: 16, y: y + 9, width: stackWidth, height: 16)
        stack.frame = NSRect(x: 16 + stackWidth + 8, y: y + 4, width: max(80, w - 32 - stackWidth - 8), height: 26)
        screenButton?.frame = NSRect(x: 16, y: y + 42, width: w - 32, height: 28)
    }
}
