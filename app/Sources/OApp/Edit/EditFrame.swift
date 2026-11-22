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

    /// The regions of a window `width` by `height`, with `top` points taken
    /// above the top bar by the banner (Spec 10 §2).
    public static func make(width: Double, height: Double, top: Double = 0) -> EditFrame {
        let gap = Self.gap
        let bodyTop = top + topBarHeight + gap
        let bottom = height - gap
        let monitors = monitorsWidth(window: width)
        let centerX = gap + browserWidth + gap
        let monitorsX = width - gap - monitors
        let inspectorY = bottom - inspectorHeight
        let upperBottom = inspectorY - gap
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
