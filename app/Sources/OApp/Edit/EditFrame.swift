// OApp — Spec 11 §2, the edit-mode frame: the window's two modes, the pages and where the regions sit.

import Foundation

/// Spec 10 §4, the Mode menu — "Show ⌘1; Edit ⌘2 (choice U-13)".
public enum WindowMode: String, Sendable {
    case show
    case edit
}

/// Spec 11 §2 — "One window, six pages", "picked in the top bar's page
/// picker, and in the View menu with ⌥⌘1 to ⌥⌘6".
public enum EditPage: String, Codable, CaseIterable, Sendable {
    case cues, text, stacks, channels, presets, objects

    /// The digit of its View menu shortcut, with ⌥⌘.
    public var shortcut: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// "Text is disabled until Area 10 lands (§11)."
    public var isBuilt: Bool { self != .text }

    /// Spec 11 §2, "Where a page's parts sit" — "The Cues and Text pages keep the Browser ...; The Stacks, Channels,
    /// Presets and Objects pages put their own list in its place".
    public var usesBrowser: Bool { self == .cues || self == .text }

    /// "the Cues and Presets pages keep the inspector under the workspace and the monitors; the Stacks and Channels
    /// pages have none". The Objects page's is settled with its stage (§9).
    public var hasInspector: Bool { self == .cues || self == .text || self == .presets }
}

/// Spec 11 §2, "The Browser" — "Three tabs: Playlists, Library and Media".
public enum BrowserTab: String, Codable, CaseIterable, Sendable {
    case playlists, library, media
}

/// Spec 11 §2, the Media tab — "Grid, two tiles to a row, or List, a small
/// tile beside the item's name with its kind and duration under it".
public enum MediaListView: String, Codable, CaseIterable, Sendable {
    case grid, list
}

/// Spec 11 §2 — where edit mode's regions sit in the window: "panels on a
/// darker ground, 4 points apart", at sizes that "are fixed in v1: edit mode
/// has no dividers". Measured from the window's top left, down and across.
public struct EditFrame: Equatable, Sendable {
    /// A region's place, in points.
    public struct Box: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// "Top bar ... 44 points high".
    public static let topBarHeight: Double = 44
    /// "Browser ... 260 points wide".
    public static let browserWidth: Double = 260
    /// "Inspector ... 250 points high".
    public static let inspectorHeight: Double = 250
    /// "4 points apart".
    public static let gap: Double = 4
    /// A panel's header, and the padding round a monitor's picture, as drawn.
    public static let panelHeader: Double = 36
    public static let padding: Double = 12

    /// "Monitors ... A quarter of the window's width, from 300 to 380 points".
    public static func monitorsWidth(window: Double) -> Double {
        min(380, max(300, window / 4))
    }

    public var topBar: Box
    public var browser: Box
    public var workspace: Box
    public var preview: Box
    public var program: Box
    public var inspector: Box

    /// Spec 11 §2 — "the Browser from 200 to 420 points wide, the monitors
    /// from 260 to 560, the inspector from 180 to 420 points high, the
    /// workspace keeping at least 360 by 200" (corrected 2026-11-24).
    public static let browserRange: ClosedRange<Double> = 200...420
    public static let monitorsRange: ClosedRange<Double> = 260...560
    public static let inspectorRange: ClosedRange<Double> = 180...420
    public static let workspaceMinimum = (width: 360.0, height: 200.0)

    /// The regions of a window `width` by `height`, with `top` points taken
    /// above the top bar by the banner (Spec 10 §2), at the sizes the
    /// operator dragged the panels to: each held to its limits, then the
    /// monitors giving way to the workspace's width before the Browser, and
    /// the inspector to its height. Nil monitors are a quarter of the window.
    public static func make(width: Double, height: Double, top: Double = 0, browser: Double = browserWidth, monitors: Double? = nil,
                            inspector: Double = inspectorHeight, hasInspector: Bool = true) -> EditFrame {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(range.upperBound, max(range.lowerBound, value)) }
        let gap = Self.gap
        let bodyTop = top + topBarHeight + gap
        let bottom = height - gap
        var browserWidth = clamp(browser, browserRange)
        var monitors = clamp(monitors ?? monitorsWidth(window: width), monitorsRange)
        var short = workspaceMinimum.width - (width - 4 * gap - browserWidth - monitors)
        if short > 0 {
            let given = min(short, monitors - monitorsRange.lowerBound)
            monitors -= given
            short -= given
            browserWidth -= max(0, min(short, browserWidth - browserRange.lowerBound))
        }
        var inspectorHeight = clamp(inspector, inspectorRange)
        let low = workspaceMinimum.height - (bottom - inspectorHeight - gap - bodyTop)
        if low > 0 { inspectorHeight -= max(0, min(low, inspectorHeight - inspectorRange.lowerBound)) }
        let centerX = gap + browserWidth + gap
        let monitorsX = width - gap - monitors
        // A page with no inspector gives its height to the workspace and the monitors.
        if !hasInspector { inspectorHeight = 0 }
        let inspectorY = bottom - inspectorHeight
        let upperBottom = hasInspector ? inspectorY - gap : bottom
        // "Preview over Program": Preview holds its header and a 16 by 9 picture; Program takes the rest.
        let previewHeight = min(panelHeader + padding + (monitors - 2 * padding) * 9 / 16 + padding, max(0, upperBottom - bodyTop))
        let programY = bodyTop + previewHeight + gap
        return EditFrame(
            topBar: Box(x: 0, y: top, width: width, height: topBarHeight),
            browser: Box(x: gap, y: bodyTop, width: browserWidth, height: max(0, bottom - bodyTop)),
            workspace: Box(x: centerX, y: bodyTop, width: max(0, monitorsX - gap - centerX), height: max(0, upperBottom - bodyTop)),
            preview: Box(x: monitorsX, y: bodyTop, width: monitors, height: previewHeight),
            program: Box(x: monitorsX, y: programY, width: monitors, height: max(0, upperBottom - programY)),
            inspector: Box(x: centerX, y: inspectorY, width: max(0, width - gap - centerX), height: inspectorHeight))
    }
}
