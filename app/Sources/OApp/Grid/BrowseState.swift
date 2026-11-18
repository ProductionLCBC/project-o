// OApp — Spec 10 §6, what the grid shows against what is live, and the rules for its scrolling and its presses.

import Foundation
import OCore

/// Spec 10 §6 — what the grid shows: a playlist, or a list opened from the
/// library. Uuids as the engine sends them, in lower case.
public enum GridContext: Hashable, Sendable {
    case playlist(String)
    case list(String)
}

/// Spec 10 §6, "Browsing and live" (S10) — "The live context is the live
/// playlist, or the list fired from the library when that is live. While
/// the grid shows anything else, it is browsing".
public struct BrowseState: Equatable, Sendable {
    /// What the grid shows; nil until it shows anything.
    public private(set) var shown: GridContext?

    public init(shown: GridContext? = nil) {
        self.shown = shown
    }

    /// "The live context is the live playlist, or the list fired from the library when that is live."
    public static func liveContext(_ live: LiveStatus) -> GridContext? {
        if let playlist = live.playlist { return .playlist(playlist) }
        if let list = live.listUuid { return .list(list) }
        return nil
    }

    /// Whether the grid is browsing: "the top bar, the grid's edge and Back
    /// to Live turn amber". "With nothing live there is no amber." A fire
    /// from the grid makes what it fired the live context, so this turns
    /// false when its `live` event arrives; a fire from anywhere else leaves
    /// `shown` where it is, so this may turn true.
    public func isBrowsing(live: LiveStatus) -> Bool {
        guard let shown, let context = Self.liveContext(live) else { return false }
        return shown != context
    }

    /// "Click a playlist to browse it"; "Click a list to browse it in the grid" (Spec 10 §5).
    public mutating func browse(_ context: GridContext) {
        shown = context
    }

    /// "Back to Live (⌘L, or the button) returns the grid to the live context".
    public mutating func backToLive(live: LiveStatus) {
        if let context = Self.liveContext(live) { shown = context }
    }

    /// Area 13 reading — at a connection, a grid that shows nothing yet
    /// takes the live context when something is live, else the last thing
    /// browsed (Spec 10 §4's view settings); one that shows something stays.
    public mutating func connected(live: LiveStatus, lastBrowsed: GridContext?) {
        guard shown == nil else { return }
        shown = Self.liveContext(live) ?? lastBrowsed
    }
}

/// Spec 10 §6, "Following the live cue" — "The grid scrolls only when the
/// live cue is out of view, and by the least amount. It never scrolls while
/// the pointer has moved over the grid in the last second, while a mouse
/// button is down or while a drag is under way; it catches up when the
/// pointer leaves the grid or rests, so a press never lands on a cue the
/// grid moved under it."
public struct FollowLive: Equatable, Sendable {
    /// "in the last second".
    public static let rest: TimeInterval = 1

    public var buttonDown = false
    public var dragging = false
    private var pointerInside = false
    private var movedAt: TimeInterval?

    public init() {}

    /// The pointer moved, over the grid or off it, at `now` on the app's clock.
    public mutating func pointerMoved(inside: Bool, at now: TimeInterval) {
        pointerInside = inside
        movedAt = inside ? now : nil
    }

    private func isResting(at now: TimeInterval) -> Bool {
        guard pointerInside, let movedAt else { return true }
        return now - movedAt >= Self.rest
    }

    /// Whether the grid may scroll to the live cue now.
    public func mayScroll(at now: TimeInterval) -> Bool {
        !buttonDown && !dragging && isResting(at: now)
    }

    /// When to look again for a scroll owed, if only the pointer's last move
    /// holds it back; nil when it may scroll now, or waits for a button or a drag.
    public func catchUpAt(now: TimeInterval) -> TimeInterval? {
        guard !buttonDown, !dragging, !isResting(at: now), let movedAt else { return nil }
        return movedAt + Self.rest
    }

    /// "by the least amount": how far to scroll so `span` is in `visible`,
    /// positive towards the end; zero when it is in view. A span taller than
    /// the view is shown from its start.
    public static func leastScroll(toShow span: ClosedRange<Double>, in visible: ClosedRange<Double>) -> Double {
        if span.lowerBound >= visible.lowerBound, span.upperBound <= visible.upperBound { return 0 }
        let height = visible.upperBound - visible.lowerBound
        if span.upperBound - span.lowerBound > height || span.lowerBound < visible.lowerBound {
            return span.lowerBound - visible.lowerBound
        }
        return span.upperBound - visible.upperBound
    }
}

/// Spec 10 §6 — what a press on a cue does.
public enum CuePress: Equatable, Sendable {
    /// "Clicking a cue fires it, on the press".
    case fire
    /// The second press of a double-click: it fires nothing, and the cue's
    /// double-click action runs (Spec 10 §6, "Double-click").
    case doubleClick
    /// A press that does nothing: with ⌥ held, or a third press in a row.
    case nothing
    /// "A secondary click ... opens the cue's menu and never fires."
    case menu
}

/// Spec 10 §6, "Clicking" — "A second press on the same cue within the
/// double-click interval doesn't fire again, since a refire restarts media
/// (Spec 3 §4). With ⌥ held, a press doesn't fire."
public struct CuePressGate: Equatable, Sendable {
    private var lastCue: String?
    private var lastAt: TimeInterval = 0
    /// Presses in a row on one cue, each within the interval of the one before.
    private var run = 0

    public init() {}

    /// A press on `cue` at `now` on the app's clock; `interval` is the system's double-click interval.
    public mutating func press(cue: String, at now: TimeInterval, interval: TimeInterval, option: Bool = false, secondary: Bool = false) -> CuePress {
        if secondary {
            lastCue = nil
            run = 0
            return .menu
        }
        if cue == lastCue, now - lastAt <= interval {
            run += 1
        } else {
            run = 1
        }
        lastCue = cue
        lastAt = now
        switch run {
        case 1: return option ? .nothing : .fire
        case 2: return .doubleClick
        default: return .nothing
        }
    }
}
