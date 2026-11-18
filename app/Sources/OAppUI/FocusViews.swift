// OAppUI — Spec 10 §15, "Keyboard navigation": the keyboard's focus inside a list, a tree, the grid and a tile set, and keeping it while a region is drawn again.

import AppKit
import OApp
import OCore

/// One thing a region's keyboard focus can rest on: a row, a cue, a tile, a
/// channel's cell.
@MainActor
struct FocusEntry {
    /// What it is, so the focus stays on it when the region is drawn again.
    let key: String
    let view: NSView
    /// "⌥Return or ⌥Space presses or activates whatever has the focus".
    let activate: () -> Void
    /// "⌃Return opens the focused item's menu, which holds what a right-click offers."
    let menu: () -> NSMenu?
}

/// The outline on what has the keyboard's focus. It takes no click.
@MainActor
final class FocusRingView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Palette.selection.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 7, yRadius: 7)
        path.lineWidth = 2 * Look.outlineScale
        path.stroke()
    }
}

/// How the app's own drawing follows the system's accessibility settings.
@MainActor
enum Look {
    /// Spec 10 §15 — "Increase Contrast thickens borders and outlines."
    static var increasesContrast = false
    static var outlineScale: CGFloat { increasesContrast ? 1.5 : 1 }
}

/// Spec 10 §15 — "Arrows, Space and Return belong to the show keys (§9), so
/// in a focused list, tree, grid or tile set ⌥ with the arrows moves the
/// selection; ⌥Return or ⌥Space presses or activates whatever has the focus,
/// a button, a tile, a cue or a row; and ⌃Return opens the focused item's
/// menu".
///
/// The region itself holds the keys, and this holds which of its items the
/// focus rests on, by what the item is rather than by its view: the regions
/// draw their items again whenever the engine says something changed, and
/// the focus must outlast that.
@MainActor
final class FocusGroup {
    enum Direction {
        case left, right, up, down
    }

    private weak var owner: NSView?
    /// The region's items, in their order, as they stand now.
    var entries: () -> [FocusEntry] = { [] }
    private(set) var key: String?
    private(set) var isActive = false
    private let ring = FocusRingView()
    /// How a menu is shown; a test reads the menu in its place.
    var popUp: (NSMenu, NSView) -> Void = { menu, view in
        menu.popUp(positioning: nil, at: NSPoint(x: 8, y: view.isFlipped ? view.bounds.height : 0), in: view)
    }

    init(owner: NSView) {
        self.owner = owner
    }

    /// The item the focus rests on: the one it was left on, or the first.
    var focused: FocusEntry? {
        let all = entries()
        return all.first { $0.key == key } ?? all.first
    }

    /// The region took the keyboard's focus, or gave it up.
    func became(active: Bool) {
        isActive = active
        if active, let entry = focused { key = entry.key }
        place()
    }

    /// Puts the focus on an item, as a click on it does.
    func focus(_ key: String) {
        self.key = key
        place()
    }

    /// Draws the outline on the focused item, or takes it away. Called again whenever the region draws its items again.
    func place() {
        guard isActive, let entry = focused else {
            ring.removeFromSuperview()
            return
        }
        if ring.superview !== entry.view { entry.view.addSubview(ring) }
        ring.frame = entry.view.bounds
        ring.autoresizingMask = [.width, .height]
        ring.needsDisplay = true
    }

    /// The item the outline is on, for a test.
    var ringedView: NSView? { ring.superview }

    private func frame(_ entry: FocusEntry) -> NSRect {
        guard let owner else { return .zero }
        return owner.convert(entry.view.bounds, from: entry.view)
    }

    /// Moves the focus: to the item before or after in the region's order,
    /// or to the nearest one in the row above or below. It stops at the ends.
    func move(_ direction: Direction) {
        let all = entries()
        guard !all.isEmpty else { return }
        guard let index = all.firstIndex(where: { $0.key == key }) else {
            key = all[0].key
            return moved(all[0])
        }
        var target: Int?
        switch direction {
        case .left: target = index > 0 ? index - 1 : nil
        case .right: target = index + 1 < all.count ? index + 1 : nil
        case .up, .down:
            let here = frame(all[index])
            // In the owner's coordinates, which grow downward where it is flipped.
            let downIsGreater = owner?.isFlipped ?? true
            let wantsGreater = (direction == .down) == downIsGreater
            var best: (index: Int, rows: CGFloat, across: CGFloat)?
            for (other, entry) in all.enumerated() where other != index {
                let there = frame(entry)
                let distance = there.midY - here.midY
                guard wantsGreater ? distance > here.height / 2 : distance < -here.height / 2 else { continue }
                let candidate = (other, abs(distance), abs(there.midX - here.midX))
                // The nearest row first; within it, the item most nearly above or below.
                if let now = best {
                    if candidate.1 < now.rows - 1 || (abs(candidate.1 - now.rows) <= 1 && candidate.2 < now.across) { best = candidate }
                } else {
                    best = candidate
                }
            }
            target = best?.index
        }
        guard let target else { return }
        key = all[target].key
        moved(all[target])
    }

    private func moved(_ entry: FocusEntry) {
        place()
        entry.view.scrollToVisible(entry.view.bounds)
        // VoiceOver follows the keyboard's focus.
        NSAccessibility.post(element: entry.view, notification: .focusedUIElementChanged)
    }

    /// "⌥Return or ⌥Space presses or activates whatever has the focus".
    func activate() {
        focused?.activate()
    }

    /// "⌃Return opens the focused item's menu". Says whether there was one.
    @discardableResult
    func openMenu() -> Bool {
        guard let entry = focused, let menu = entry.menu(), !menu.items.isEmpty else { return false }
        popUp(menu, entry.view)
        return true
    }

    /// A key-down the region was handed. Says whether it was the focus's.
    func handle(_ event: NSEvent) -> Bool {
        let stroke = KeyTap.stroke(event)
        guard !stroke.command, let name = stroke.name else { return false }
        if name.alt, !name.ctrl, !name.shift {
            switch name.key {
            case "left": move(.left)
            case "right": move(.right)
            case "up": move(.up)
            case "down": move(.down)
            case "return", "space": activate()
            default: return false
            }
            return true
        }
        if name.ctrl, !name.alt, !name.shift, name.key == "return" { return openMenu() }
        return false
    }
}

/// Spec 10 §15 — "each button takes the keyboard focus like any other". A
/// region that draws its controls again whenever the engine says something
/// changed would drop the keyboard's focus each time; this puts the focus
/// back on the control at the same place in what was drawn again.
@MainActor
enum FocusKeeper {
    private static func path(from container: NSView, to view: NSView) -> [Int]? {
        var path: [Int] = []
        var at = view
        while at !== container {
            guard let parent = at.superview, let index = parent.subviews.firstIndex(where: { $0 === at }) else { return nil }
            path.insert(index, at: 0)
            at = parent
        }
        return path
    }

    private static func view(at path: [Int], in container: NSView) -> NSView? {
        var at = container
        for index in path {
            guard at.subviews.indices.contains(index) else { return nil }
            at = at.subviews[index]
        }
        return at
    }

    /// Runs `redraw`, and afterwards gives the focus back to the control that stands where the focused one stood.
    static func keeping(in container: NSView, _ redraw: () -> Void) {
        guard let window = container.window, let focused = window.firstResponder as? NSView, focused !== container, focused.isDescendant(of: container),
              !(focused is NSText), let path = path(from: container, to: focused) else { return redraw() }
        let kind = type(of: focused)
        redraw()
        if window.firstResponder === focused, focused.window === window { return }
        if let again = view(at: path, in: container), type(of: again) == kind, again.acceptsFirstResponder { window.makeFirstResponder(again) }
    }
}
