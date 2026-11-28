// OAppUI — Spec 11 §8, "The canvas": the engine's picture of the layout with the sample, and over it each box's
// outline and handles, which drag, resize, nudge and snap.

import AppKit
import OApp
import OCore

/// Spec 11 §8, "Frame" (G-34) — the box's reference point, "picked from nine: a corner, the middle of an edge, or the
/// center": a square of nine dots, the chosen one filled. The choice is the app's, kept in `view.json`.
@MainActor
final class AnchorPicker: NSView {
    static let size: CGFloat = 42
    private let model: ShowModel

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(Strings.text(.editPresetAnchor))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        setAccessibilityValue(Strings.text(Self.word(model.settings.boxAnchor)))
        needsDisplay = true
    }

    static func word(_ anchor: FrameAnchor) -> StringKey {
        switch anchor {
        case .topLeft: .editPresetAnchorTopLeft
        case .top: .editPresetAnchorTop
        case .topRight: .editPresetAnchorTopRight
        case .left: .editPresetAnchorLeft
        case .center: .editPresetAnchorCenter
        case .right: .editPresetAnchorRight
        case .bottomLeft: .editPresetAnchorBottomLeft
        case .bottom: .editPresetAnchorBottom
        case .bottomRight: .editPresetAnchorBottomRight
        }
    }

    /// The center of a point's dot.
    private func center(of anchor: FrameAnchor) -> NSPoint {
        let inset: CGFloat = 7
        let step = (min(bounds.width, bounds.height) - 2 * inset) / 2
        return NSPoint(x: inset + CGFloat(anchor.rawValue % 3) * step, y: inset + CGFloat(anchor.rawValue / 3) * step)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 7, y: 7, width: min(bounds.width, bounds.height) - 14, height: min(bounds.width, bounds.height) - 14)
        Palette.hairline.setStroke()
        NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let chosen = model.settings.boxAnchor
        for anchor in FrameAnchor.allCases {
            let at = center(of: anchor)
            let dot = NSRect(x: at.x - 3.5, y: at.y - 3.5, width: 7, height: 7)
            if anchor == chosen {
                Palette.selection.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -1, dy: -1)).fill()
            } else {
                Palette.dimText.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: 1, dy: 1)).fill()
            }
        }
    }

    /// Picks the point nearest a press.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let nearest = FrameAnchor.allCases.min(by: { hypot(center(of: $0).x - point.x, center(of: $0).y - point.y) < hypot(center(of: $1).x - point.x, center(of: $1).y - point.y) }) else { return }
        choose(nearest)
    }

    /// The arrows move the choice by keyboard.
    override func keyDown(with event: NSEvent) {
        let at = model.settings.boxAnchor.rawValue
        let (column, row) = (at % 3, at / 3)
        switch event.keyCode {
        case 123: choose(FrameAnchor(rawValue: row * 3 + max(0, column - 1)) ?? .topLeft)
        case 124: choose(FrameAnchor(rawValue: row * 3 + min(2, column + 1)) ?? .topLeft)
        case 125: choose(FrameAnchor(rawValue: min(2, row + 1) * 3 + column) ?? .topLeft)
        case 126: choose(FrameAnchor(rawValue: max(0, row - 1) * 3 + column) ?? .topLeft)
        default: super.keyDown(with: event)
        }
    }

    func choose(_ anchor: FrameAnchor) {
        model.change { $0.boxAnchor = anchor }
    }
}

/// Spec 11 §8 — "The canvas is the layout at its stack's size (§3) ... Its picture is the engine's (choice A-1) ...
/// Over it the app draws each box's outline and handles, labeled with its binding ("body", "pixels", "static") and
/// its offset when it isn't 0 ("+1")."
@MainActor
final class LayoutCanvasView: NSView, EditFocus {
    private let model: ShowModel
    var machineRoot: URL?
    private(set) var image: NSImage?
    private var shownFile: String?
    /// While a drag or a nudge is under way: the box and the frame it has so far, drawn before any edit is sent.
    private(set) var moving: (index: Int, frame: Frame)?
    private var press: (point: NSPoint, handle: CanvasHandle, start: Frame, index: Int)?
    private var snapLines: (xs: [Double], ys: [Double]) = ([], [])
    /// Arrow keys held: the nudge is sent once, when they are released.
    private var nudging = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: ShowModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        // A layout area, whose boxes are its elements (Spec 11 §10).
        setAccessibilityRole(.layoutArea)
        setAccessibilityLabel(Strings.text(.editPresetCanvas))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        let state = model.editing.presetState
        if state.picture.file != shownFile {
            shownFile = state.picture.file
            if let file = state.picture.file, let root = machineRoot {
                image = PictureStore.shared.picture(at: root.appendingPathComponent(file)) { [weak self] image in
                    guard self?.shownFile == file else { return }
                    self?.image = image
                    self?.needsDisplay = true
                }
            } else {
                image = nil
            }
        }
        // A frame sent stays drawn where it was dropped until the engine's copy has it, or refuses it.
        if let moving, press == nil, !nudging {
            let boxes = model.editing.presetPage.layout?.boxes ?? []
            let want = LayoutCanvasMath.kept(moving.frame)
            if !boxes.indices.contains(moving.index) {
                self.moving = nil
            } else if case .rejected? = model.editing.notice {
                self.moving = nil
            } else {
                let now = boxes[moving.index].frame
                if abs(now.x - want.x) < 0.0002, abs(now.y - want.y) < 0.0002, abs(now.w - want.w) < 0.0002, abs(now.h - want.h) < 0.0002 { self.moving = nil }
            }
        }
        needsDisplay = true
    }

    // MARK: - Geometry

    /// Where the stack's picture sits: its shape, as large as fits.
    var stackRect: NSRect {
        let size = model.editing.canvasSize
        let aspect = CGFloat(size.width) / CGFloat(max(1, size.height))
        let pad: CGFloat = 14
        var width = max(0, bounds.width - 2 * pad)
        var height = width / aspect
        if height > bounds.height - 2 * pad {
            height = max(0, bounds.height - 2 * pad)
            width = height * aspect
        }
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    func rect(of frame: Frame) -> NSRect {
        let r = stackRect
        return NSRect(x: r.minX + CGFloat(frame.x) * r.width, y: r.minY + CGFloat(frame.y) * r.height,
                      width: CGFloat(frame.w) * r.width, height: CGFloat(frame.h) * r.height)
    }

    /// A point of the view as fractions of the stack.
    func fraction(_ point: NSPoint) -> (x: Double, y: Double) {
        let r = stackRect
        return (Double((point.x - r.minX) / max(1, r.width)), Double((point.y - r.minY) / max(1, r.height)))
    }

    /// The frames as drawn: the layout's, with the one under a drag or a nudge where the pointer has it.
    var frames: [Frame] {
        var frames = model.editing.presetPage.layout?.boxes.map(\.frame) ?? []
        if let moving, frames.indices.contains(moving.index) { frames[moving.index] = moving.frame }
        return frames
    }

    private func handles(of rect: NSRect) -> [(CanvasHandle, NSPoint)] {
        [(.topLeft, NSPoint(x: rect.minX, y: rect.minY)), (.top, NSPoint(x: rect.midX, y: rect.minY)), (.topRight, NSPoint(x: rect.maxX, y: rect.minY)),
         (.right, NSPoint(x: rect.maxX, y: rect.midY)), (.bottomRight, NSPoint(x: rect.maxX, y: rect.maxY)), (.bottom, NSPoint(x: rect.midX, y: rect.maxY)),
         (.bottomLeft, NSPoint(x: rect.minX, y: rect.maxY)), (.left, NSPoint(x: rect.minX, y: rect.midY))]
    }

    override func layout() {
        super.layout()
        // "at its stack's size": asked for at the canvas's width in pixels.
        let scale = window?.backingScaleFactor ?? 2
        if stackRect.width > 0 { model.editing.canvasWidth(Int((stackRect.width * scale).rounded())) }
    }

    // MARK: - VoiceOver (Spec 11 §10)

    /// "On a canvas each box is an element that says its binding, offset and frame in percent, with actions to move
    /// and resize it by 1% of the stack": the boxes, top first, while the tab's layout is its own.
    override func accessibilityChildren() -> [Any]? {
        let page = model.editing.presetPage
        guard page.ownsLayout, let boxes = page.layout?.boxes else { return [] }
        return boxes.indices.reversed().map { element(for: $0, boxes[$0]) }
    }

    /// What a box says: "body +1, x 5%, y 10%, width 90%, height 80%".
    static func spoken(_ box: Box) -> String {
        let offset = box.offset == 0 ? "" : (box.offset > 0 ? " +\(box.offset)" : " \(box.offset)")
        func percent(_ value: Double) -> String { FormNumber.text(value * 100, places: 1) }
        return tag(of: box.binding.kind) + offset + ", "
            + Strings.text(.editCanvasBoxFrame, percent(box.frame.x), percent(box.frame.y), percent(box.frame.w), percent(box.frame.h))
    }

    private func element(for index: Int, _ box: Box) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(.group)
        // "an overflowing box's red outline with how many lines were cut" (color is never alone).
        let overflow = model.editing.presetState.overflow.first { $0.box == index }
        element.setAccessibilityLabel(Self.spoken(box) + (overflow.map { ", " + Strings.text(.editPresetLinesCut, $0.linesCut) } ?? ""))
        element.setAccessibilityFrameInParentSpace(rect(of: box.frame))
        element.setAccessibilitySelected(index == model.editing.presetState.box)
        let step = 0.01
        let changes: [(StringKey, (inout Frame) -> Void)] = [
            (.editCanvasMoveLeft, { $0.x -= step }), (.editCanvasMoveRight, { $0.x += step }),
            (.editCanvasMoveUp, { $0.y -= step }), (.editCanvasMoveDown, { $0.y += step }),
            (.editCanvasWider, { $0.w += step }), (.editCanvasNarrower, { $0.w -= step }),
            (.editCanvasTaller, { $0.h += step }), (.editCanvasShorter, { $0.h -= step }),
        ]
        element.setAccessibilityCustomActions(changes.map { key, change in
            NSAccessibilityCustomAction(name: Strings.text(key)) { [weak self] in
                MainActor.assumeIsolated { self?.change(box: index, by: change) ?? false }
            }
        })
        return element
    }

    /// One action's change of a box's frame, sent as a nudge is: one `edit.set` of `frame`.
    @discardableResult
    func change(box index: Int, by change: (inout Frame) -> Void) -> Bool {
        let page = model.editing.presetPage
        guard page.ownsLayout, let boxes = page.layout?.boxes, boxes.indices.contains(index) else { return false }
        var frame = boxes[index].frame
        change(&frame)
        model.editing.setFrame(LayoutCanvasMath.kept(frame), of: index)
        return true
    }

    // MARK: - Drawing

    static func tag(of binding: Binding.Kind) -> String {
        switch binding {
        case .pixels: Strings.text(.editPresetPixelsTag)
        case .field(let name): name
        case .static: Strings.text(.editPresetStaticTag)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = stackRect
        NSColor.black.setFill()
        r.fill()
        image?.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        let editing = model.editing
        let page = editing.presetPage
        let state = editing.presetState
        let boxes = page.layout?.boxes ?? []
        let frames = self.frames
        let font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        for (index, box) in boxes.enumerated() where frames.indices.contains(index) {
            let rect = self.rect(of: frames[index]).insetBy(dx: 0.5, dy: 0.5)
            let selected = page.ownsLayout && index == state.box
            let overflow = state.overflow.first { $0.box == index }
            let path = NSBezierPath(rect: rect)
            if selected {
                Palette.selection.setStroke()
                path.lineWidth = 2
            } else if overflow != nil {
                // "A text box whose sample text overflows has a red outline".
                Palette.live.setStroke()
                path.lineWidth = 1.5
            } else {
                NSColor.white.withAlphaComponent(page.ownsLayout ? 0.55 : 0.3).setStroke()
                path.lineWidth = 1
                path.setLineDash([4, 3], count: 2, phase: 0)
            }
            path.stroke()
            // The binding and the offset, in a small tag at the box's top left.
            var words = Self.tag(of: box.binding.kind)
            if box.offset != 0 { words += " " + (box.offset > 0 ? "+\(box.offset)" : "\(box.offset)") }
            var notes: [String] = []
            if let overflow { notes.append(Strings.text(.editPresetLinesCut, overflow.linesCut)) }
            if let fallback = state.fallbackFonts[index] { notes.append(Strings.text(.editPresetFallbackFont, fallback)) }
            var y = rect.minY + 3
            for (line, color) in [(words, selected ? Palette.selection : NSColor.black.withAlphaComponent(0.65))] + notes.map({ ($0, Palette.live) }) {
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let size = (line as NSString).size(withAttributes: attributes)
                let pill = NSRect(x: rect.minX + 3, y: y, width: min(size.width + 8, max(0, rect.width - 6)), height: size.height + 2)
                color.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 3, yRadius: 3).fill()
                (line as NSString).draw(in: pill.insetBy(dx: 4, dy: 1), withAttributes: attributes)
                y += pill.height + 2
            }
            if selected {
                Palette.selection.setFill()
                for (_, point) in handles(of: rect) {
                    NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7).fill()
                }
            }
        }
        // The lines a drag snapped to.
        Palette.selection.withAlphaComponent(0.8).setFill()
        for x in snapLines.xs { NSRect(x: r.minX + CGFloat(x) * r.width - 0.5, y: r.minY, width: 1, height: r.height).fill() }
        for y in snapLines.ys { NSRect(x: r.minX, y: r.minY + CGFloat(y) * r.height - 0.5, width: r.width, height: 1).fill() }
        if window?.firstResponder === self {
            Palette.selection.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 5, yRadius: 5)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    // MARK: - The pointer (Spec 11 §8, "Selecting" and "Moving")

    /// What a press at a point of the view takes hold of: the selected box's handle, else the topmost box's body.
    func hit(_ point: NSPoint) -> (index: Int, handle: CanvasHandle)? {
        let editing = model.editing
        let frames = self.frames
        if let selected = editing.presetState.box, frames.indices.contains(selected) {
            for (handle, at) in handles(of: rect(of: frames[selected])) where abs(point.x - at.x) <= 6 && abs(point.y - at.y) <= 6 {
                return (selected, handle)
            }
        }
        let at = fraction(point)
        return LayoutCanvasMath.box(at: at.x, at.y, in: frames).map { ($0, .move) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        press(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: convert(event.locationInWindow, from: nil), snapping: !event.modifierFlags.contains(.command))
    }

    override func mouseUp(with event: NSEvent) { release() }

    /// A press: it selects the box it lands on, or nothing.
    func press(at point: NSPoint) {
        let editing = model.editing
        guard let (index, handle) = hit(point) else {
            editing.selectBox(nil)
            press = nil
            return
        }
        editing.selectBox(index)
        guard editing.presetPage.ownsLayout, let frame = editing.presetPage.layout?.boxes[index].frame else { return }
        press = (point, handle, frame, index)
    }

    /// "The outline follows the pointer".
    func drag(to point: NSPoint, snapping: Bool) {
        guard let press else { return }
        let r = stackRect
        let dx = Double((point.x - press.point.x) / max(1, r.width))
        let dy = Double((point.y - press.point.y) / max(1, r.height))
        var frame = LayoutCanvasMath.dragged(press.start, handle: press.handle, dx: dx, dy: dy)
        snapLines = ([], [])
        if snapping {
            let others = (model.editing.presetPage.layout?.boxes ?? []).enumerated().filter { $0.offset != press.index }.map(\.element.frame)
            let snapped = LayoutCanvasMath.snapped(frame, handle: press.handle, others: others, threshold: Double(6 / max(1, r.width)))
            frame = snapped.frame
            snapLines = (snapped.xs, snapped.ys)
        }
        moving = (press.index, frame)
        needsDisplay = true
    }

    /// "when the drag or the nudge ends, one `edit.set` of the box's `frame`".
    func release() {
        defer {
            press = nil
            snapLines = ([], [])
            needsDisplay = true
        }
        guard let press, let moving, moving.frame != press.start else {
            self.moving = nil
            return
        }
        model.editing.setFrame(LayoutCanvasMath.kept(moving.frame), of: moving.index)
    }

    // MARK: - Keys (Spec 11 §8, §2)

    override func keyDown(with event: NSEvent) {
        let editing = model.editing
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        let size = editing.canvasSize
        func nudge(_ dx: Int, _ dy: Int) {
            guard editing.presetPage.ownsLayout, let index = editing.presetState.box, let box = editing.selectedBox else { return }
            let from = moving?.index == index ? moving?.frame ?? box.frame : box.frame
            moving = (index, LayoutCanvasMath.nudged(from, dx: dx, dy: dy, width: size.width, height: size.height))
            nudging = true
            needsDisplay = true
        }
        switch event.keyCode {
        case 123: nudge(-step, 0)
        case 124: nudge(step, 0)
        case 125: nudge(0, step)
        case 126: nudge(0, -step)
        case 51, 117:
            if let index = editing.presetState.box { editing.removeBox(index) }
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        default:
            super.keyDown(with: event)
        }
    }

    /// "a held nudge sends one edit, when the key is released".
    override func keyUp(with event: NSEvent) {
        guard [123, 124, 125, 126].contains(event.keyCode) else { return super.keyUp(with: event) }
        endNudge()
    }

    func endNudge() {
        guard nudging else { return }
        nudging = false
        if let moving { model.editing.setFrame(LayoutCanvasMath.kept(moving.frame), of: moving.index) }
        moving = nil
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        endNudge()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
}
