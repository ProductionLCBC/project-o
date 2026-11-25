// OApp — Spec 10 §8, the top bar; §4, the view settings; §6, the media pool; §13, the first window's line.

import Foundation
import OCore

// MARK: - The top bar (Spec 10 §8)

/// Spec 10 §8, "Left" — "the live position as text".
public enum LivePosition: Equatable, Sendable {
    /// "Sunday · Great Is Thy Faithfulness · 3 Verse 2".
    case cue(playlist: String, list: String, number: Int, label: String)
    /// "Sunday · ready" with a playlist loaded and no cue fired.
    case ready(playlist: String)
    /// "Library · Great Is Thy Faithfulness · 3 Verse 2" for a list fired from the library.
    case library(list: String, number: Int, label: String)
    /// "Nothing live", followed by "Click a cue, or choose Make Live" while a playlist is browsed (§7).
    case nothing(hint: Bool)

    public static func make(live: LiveStatus, shown: GridContext?) -> LivePosition {
        if live.playlist != nil {
            guard live.cue != nil else { return .ready(playlist: live.playlistTitle) }
            return .cue(playlist: live.playlistTitle, list: live.listTitle, number: live.cuePosition, label: live.label)
        }
        if live.listUuid != nil {
            return .library(list: live.listTitle, number: live.cuePosition, label: live.label)
        }
        if case .playlist = shown { return .nothing(hint: true) }
        return .nothing(hint: false)
    }
}

/// Spec 10 §8, "Right" — "one dot per output with its number, label and
/// live stack, "1 Main · stack 1": filled green while presenting, and
/// otherwise a hollow red shape with its state in a word, "1 Main · lost"
/// (paused), "· released" or "· absent"; a blacked-out stack adds
/// "· Blackout" with a hollow dot."
public struct OutputDot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case presenting
        /// The engine's `paused`.
        case lost
        case released
        case absent
    }

    public var number: Int
    public var label: String
    public var stack: Int
    public var state: State
    public var isBlackedOut: Bool

    /// One per output, in number order. An output the engine hasn't
    /// reported yet reads absent, on its default stack.
    public static func all(outputs: [Output], status: [Int: OutputStatus], stackStatus: [Int: StackStatus]) -> [OutputDot] {
        outputs.sorted { $0.number < $1.number }.map { output in
            let reported = status[output.number]
            let stack = reported?.stack ?? output.defaultStack
            let state: State
            switch reported?.state {
            case "presenting": state = .presenting
            case "paused": state = .lost
            case "released": state = .released
            default: state = .absent
            }
            return OutputDot(number: output.number, label: output.label, stack: stack, state: state, isBlackedOut: stackStatus[stack]?.blackout ?? false)
        }
    }
}

/// Spec 10 §8 — "Then the tags, each shown only while it applies".
public enum TopBarTag: Equatable, Sendable {
    /// ""Audio muted" or "Audio lost" (the `audio` topic)".
    case audioMuted
    case audioLost
    /// ""Popup 1" while a slot is set, which opens the Popups tab".
    case popup(Int)
    /// "the engine tag while a badge stands, which lists them (§14)".
    case engine(badges: Int)
    /// "the saving tag (§14)".
    case saving(SavingTag)

    /// The tags that apply, in the spec's order.
    ///
    /// Area 13 reading — "Audio lost" is for an audio output a channel
    /// routes to that has gone silent; an embedded output nothing feeds is
    /// always silent and says nothing.
    public static func all(channels: [Channel], audio: [Int: AudioStatus], popups: [Int: PopupStatus], engine: EngineStatus, saving: SavingTag?) -> [TopBarTag] {
        var tags: [TopBarTag] = []
        let routed = Set(channels.flatMap(\.audioOutputs))
        if audio.values.contains(where: { routed.contains($0.number) && $0.state == "silent" }) {
            tags.append(.audioLost)
        } else if audio.values.contains(where: \.muted) {
            tags.append(.audioMuted)
        }
        for slot in popups.keys.sorted() where popups[slot]?.isSet == true { tags.append(.popup(slot)) }
        if !engine.badges.isEmpty { tags.append(.engine(badges: engine.badges.count)) }
        if let saving { tags.append(.saving(saving)) }
        return tags
    }
}

/// Spec 10 §8 — "With no outputs the dots' place says "No outputs" and opens
/// Settings ▸ Outputs; with the screens mirrored it says "Screens are
/// mirrored: the room sees this window"."
public enum OutputsNote: Equatable, Sendable {
    case noOutputs
    case mirrored

    public static func make(outputs: [Output], screensAreMirrored: Bool) -> OutputsNote? {
        guard outputs.isEmpty else { return nil }
        return screensAreMirrored ? .mirrored : .noOutputs
    }
}

/// Spec 10 §8 — "the remote dot, lit while remote commands arrive
/// (`remote`)": lit for two seconds after each (Area 13 reading).
public struct RemoteDot: Equatable, Sendable {
    public static let glow: TimeInterval = 2
    private var until: TimeInterval?
    public private(set) var sources: [String] = []

    public init() {}

    public mutating func arrived(from sources: [String], at now: TimeInterval) {
        until = now + Self.glow
        self.sources = sources
    }

    public func isLit(at now: TimeInterval) -> Bool {
        until.map { now < $0 } ?? false
    }
}

/// Spec 10 §6 and §8 — the armed countdown, "counted on the app's clock from
/// `inMs` (Spec 7 §6)": the milliseconds left, `elapsedMs` after the `live`
/// event that named them arrived.
public enum Countdown {
    public static func remainingMs(_ armed: LiveStatus.Armed?, elapsedMs: Int) -> Int? {
        armed.map { max(0, $0.inMs - max(0, elapsedMs)) }
    }
}

// MARK: - View settings (Spec 10 §4)

/// Spec 10 §4, "View settings" (S8) — what `machine/view.json` holds, with
/// "the UX spec's first-run layout" as the defaults: "the divider at
/// default, the panel open, the grid showing thumbnails, chips, labels and
/// triggers with notes off, the multiviewer off, the preview on the
/// thumbnail stack, and the strip showing all channels."
///
/// Kept in memory until the file is written (the edits' stage); Codable now
/// so the file is this struct and nothing else.
public struct ViewSettings: Codable, Equatable, Sendable {
    /// Spec 10 §6, "The divider" — "collapsed, ... default, about a third of the center; and expanded".
    public enum PanelState: String, Codable, Sendable {
        case collapsed
        case `default`
        case expanded
    }

    public enum PoolSort: String, Codable, Sendable {
        case name
        case dateAdded
    }

    public enum PoolKind: String, Codable, Sendable {
        case all, video, image, audio
    }

    public enum TileSize: String, Codable, Sendable {
        case small, medium, large
    }

    /// Spec 10 §4 — "Left column ... 248 points wide by default, 200 to 360"; "Right column ... 380 points wide by default, 340 to 480".
    public static let leftWidth = (min: 200.0, standard: 248.0, max: 360.0)
    public static let rightWidth = (min: 340.0, standard: 380.0, max: 480.0)

    public var leftColumnWidth = ViewSettings.leftWidth.standard
    public var rightColumnWidth = ViewSettings.rightWidth.standard
    /// The Playlists window's share of the left column.
    public var leftSplit = 0.5
    public var panel = PanelState.default
    public var tabbedPanelCollapsed = false
    /// Nil for the machine's thumbnail stack.
    public var previewStack: Int?
    public var multiviewer = false
    public var showsThumbnails = true
    public var showsChips = true
    public var showsTriggers = true
    public var showsNotes = false
    public var poolFolder: String?
    public var poolSort = PoolSort.name
    public var poolKind = PoolKind.all
    public var poolTileSize = TileSize.medium
    /// Nil for all channels; a stack's number for that stack's.
    public var stripStack: Int?
    public var showsArchivedPlaylists = false
    public var openFolders: [String] = []
    public var recentMedia: [String] = []
    /// "the window's frame": x, y, width and height on the Mac's screens; nil until the window has been moved or sized.
    public var windowFrame: [Double]?
    /// "the last thing browsed": a playlist's uuid or a list's, whichever the grid last showed.
    public var lastBrowsedPlaylist: String?
    public var lastBrowsedList: String?
    /// "the run whose restore banner was dismissed (§14)".
    public var dismissedRestoreRun: String?
    /// Spec 11 §2 — "`view.json` (Spec 10 §4) also keeps the last page, each
    /// page's selection, the Browser's tab and its media view, and the cue
    /// grid's zoom and folded rows (§4), so edit mode reopens where it was left."
    public var editPage = EditPage.cues
    /// The Cues page's selection: where its list came from (a playlist and
    /// its item, or neither for the Library window), the list, the cue and
    /// the channel's row.
    public var editPlaylist: String?
    public var editItem: String?
    public var editList: String?
    public var editCue: String?
    public var editChannel: Int?
    /// The Stacks page's selection (Spec 11 §6): the stack, and the output whose properties show.
    public var editStack: Int?
    public var editOutput: Int?
    /// The Channels page's selection (Spec 11 §7): the channel whose form shows.
    public var editSheetChannel: Int?
    /// The Presets page's selection (Spec 11 §8): the preset, and its layout's tab, a stack's number or nil for `*`.
    public var editPreset: Int?
    public var editLayout: Int?
    /// Spec 11 §8, "Frame" (G-34) — the box's reference point the Frame fields read, "kept in `view.json`".
    public var boxAnchor = FrameAnchor.topLeft
    public var browserTab = BrowserTab.playlists
    public var mediaView = MediaListView.grid
    /// Spec 11 §4, "Zoom" — "The zoom is one setting for every list".
    public var gridZoom = CueGridZoom.standard
    /// Spec 11 §4 — "a row the operator folds or opens stays so for every list, by channel number".
    public var foldedRows: [Int: Bool] = [:]
    /// Spec 11 §4 — "Hidden rows are kept by channel number for every list, in `view.json`, as folded ones are"
    /// (corrected 2026-11-24); in number order.
    public var hiddenRows: [Int] = []
    /// Spec 11 §2 — "The gaps beside the Browser, the monitors and the
    /// inspector drag to resize them ... `view.json` keeps the sizes"
    /// (corrected 2026-11-24). Nil monitors are "a quarter of the window's
    /// width, from 300 to 380 points".
    public var editBrowserWidth = EditFrame.browserWidth
    public var editMonitorsWidth: Double?
    public var editInspectorHeight = EditFrame.inspectorHeight

    public init() {}

    /// Spec 10 §4 — "It isn't a document of Spec 1 §5: it carries no header
    /// and no schema promises, unknown keys are ignored, a file that doesn't
    /// read means defaults". Each key that reads is taken and each that
    /// doesn't keeps its default (Area 13 reading), so a file from an older
    /// build, or one with a value this build doesn't know, still gives back
    /// what it can.
    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T) {
            if let found = try? c.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        func read<T: Decodable>(_ key: CodingKeys, into value: inout T?) {
            if let found = try? c.decodeIfPresent(T.self, forKey: key) { value = found }
        }
        read(.leftColumnWidth, into: &leftColumnWidth)
        read(.rightColumnWidth, into: &rightColumnWidth)
        read(.leftSplit, into: &leftSplit)
        read(.panel, into: &panel)
        read(.tabbedPanelCollapsed, into: &tabbedPanelCollapsed)
        read(.previewStack, into: &previewStack)
        read(.multiviewer, into: &multiviewer)
        read(.showsThumbnails, into: &showsThumbnails)
        read(.showsChips, into: &showsChips)
        read(.showsTriggers, into: &showsTriggers)
        read(.showsNotes, into: &showsNotes)
        read(.poolFolder, into: &poolFolder)
        read(.poolSort, into: &poolSort)
        read(.poolKind, into: &poolKind)
        read(.poolTileSize, into: &poolTileSize)
        read(.stripStack, into: &stripStack)
        read(.showsArchivedPlaylists, into: &showsArchivedPlaylists)
        read(.openFolders, into: &openFolders)
        read(.recentMedia, into: &recentMedia)
        read(.windowFrame, into: &windowFrame)
        read(.lastBrowsedPlaylist, into: &lastBrowsedPlaylist)
        read(.lastBrowsedList, into: &lastBrowsedList)
        read(.dismissedRestoreRun, into: &dismissedRestoreRun)
        read(.editPage, into: &editPage)
        read(.editPlaylist, into: &editPlaylist)
        read(.editItem, into: &editItem)
        read(.editList, into: &editList)
        read(.editCue, into: &editCue)
        read(.editChannel, into: &editChannel)
        read(.editStack, into: &editStack)
        read(.editOutput, into: &editOutput)
        read(.editSheetChannel, into: &editSheetChannel)
        read(.editPreset, into: &editPreset)
        read(.editLayout, into: &editLayout)
        read(.boxAnchor, into: &boxAnchor)
        read(.browserTab, into: &browserTab)
        read(.mediaView, into: &mediaView)
        read(.gridZoom, into: &gridZoom)
        read(.foldedRows, into: &foldedRows)
        read(.hiddenRows, into: &hiddenRows)
        hiddenRows = Array(Set(hiddenRows)).sorted()
        read(.editBrowserWidth, into: &editBrowserWidth)
        read(.editMonitorsWidth, into: &editMonitorsWidth)
        read(.editInspectorHeight, into: &editInspectorHeight)
        gridZoom = CueGridZoom.clamped(gridZoom)
        clampEditSizes()
        // What was read is held to what the window allows.
        leftColumnWidth = Self.clampedLeft(leftColumnWidth)
        rightColumnWidth = Self.clampedRight(rightColumnWidth)
        leftSplit = min(0.8, max(0.2, leftSplit))
        if recentMedia.count > 20 { recentMedia.removeLast(recentMedia.count - 20) }
        if let frame = windowFrame, frame.count != 4 || frame.contains(where: { !$0.isFinite }) || frame[2] <= 0 || frame[3] <= 0 { windowFrame = nil }
    }

    /// Edit mode's sizes held to Spec 11 §2's limits.
    public mutating func clampEditSizes() {
        func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound }
        editBrowserWidth = clamp(editBrowserWidth, EditFrame.browserRange)
        editMonitorsWidth = editMonitorsWidth.map { clamp($0, EditFrame.monitorsRange) }
        editInspectorHeight = clamp(editInspectorHeight, EditFrame.inspectorRange)
    }

    /// "the last thing browsed", as the grid names what it shows.
    public var lastBrowsed: GridContext? {
        get {
            if let playlist = lastBrowsedPlaylist { return .playlist(playlist) }
            return lastBrowsedList.map(GridContext.list)
        }
        set {
            lastBrowsedPlaylist = nil
            lastBrowsedList = nil
            switch newValue {
            case .playlist(let uuid)?: lastBrowsedPlaylist = uuid
            case .list(let uuid)?: lastBrowsedList = uuid
            case nil: break
            }
        }
    }

    /// "Compact, which drops the thumbnails" (Spec 10 §6).
    public var isCompact: Bool { !showsThumbnails }

    /// A column's width, held inside the spec's limits.
    public static func clampedLeft(_ width: Double) -> Double { min(max(width, leftWidth.min), leftWidth.max) }
    public static func clampedRight(_ width: Double) -> Double { min(max(width, rightWidth.min), rightWidth.max) }

    /// Spec 10 §6 — "one strip of the twenty most recently used items": an
    /// item written live or into a cue from this app goes to the front.
    public mutating func used(media id: String) {
        recentMedia.removeAll { $0 == id }
        recentMedia.insert(id, at: 0)
        if recentMedia.count > 20 { recentMedia.removeLast(recentMedia.count - 20) }
    }
}

/// Spec 10 §4 — "While it is less than 1000 points high the tabbed panel
/// collapses to its tab bar, at launch and on resize, whatever `view.json`
/// says, and the strip takes the space; above that, `view.json`'s state
/// applies."
public enum PanelCollapseRule {
    public static let height = 1000.0

    public static func isCollapsed(windowHeight: Double, setting: Bool) -> Bool {
        windowHeight < height ? true : setting
    }
}

// MARK: - The media pool (Spec 10 §6)

/// Spec 10 §6, "Tiles" — one item of the pool as its tile shows it.
public struct PoolTile: Equatable, Sendable {
    public enum Overlay: Equatable, Sendable {
        case none
        /// "A missing item keeps its place with a striped, red-dashed overlay."
        case missing
        /// "A deleted item shows the same overlay with "deleted" while anything still uses it".
        case deleted
    }

    public var id: String
    public var name: String
    public var kind: MediaKind
    public var durationMs: Int?
    /// The pool tile's file, relative to the machine root.
    public var tile: String?
    public var overlay: Overlay
    public var isOnThisMac: Bool
}

/// Spec 10 §6, "The Media pool panel".
public enum MediaPool {
    /// What the header's controls ask for.
    public struct Filter: Equatable, Sendable {
        public var search = ""
        public var kind = ViewSettings.PoolKind.all
        public var sort = ViewSettings.PoolSort.name
        /// Nil for every folder.
        public var folder: String?
        /// "a "used in this list" filter over the browsed list's references": those ids, or nil for no filter.
        public var usedIn: Set<String>?
        /// "a Replaced filter, which shows the items `media replace` replaced so they can be deleted (Spec 8 §6)".
        public var replacedOnly = false

        public init() {}
    }

    /// An item's name: its file's name.
    public static func name(of entry: MediaEntry) -> String {
        entry.path.split(separator: "/").last.map(String.init) ?? entry.path
    }

    /// The tiles to show, in the header's order. A deleted item "is hidden
    /// once nothing does [use it]"; a replaced one shows only under the
    /// Replaced filter. The search looks "across every folder", so it sets
    /// the folder aside; a folder shows what is in it and below it (Area 13 reading).
    public static func tiles(_ media: [MediaItem], filter: Filter) -> [PoolTile] {
        let needle = filter.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = media.filter { item in
            if item.isDeleted, item.uses == 0 { return false }
            if filter.replacedOnly != (item.replacedBy != nil) { return false }
            switch filter.kind {
            case .all: break
            case .video: if item.entry.kind != .video { return false }
            case .image: if item.entry.kind != .image { return false }
            case .audio: if item.entry.kind != .audio && item.entry.kind != .audioSet { return false }
            }
            if let used = filter.usedIn, !used.contains(item.id) { return false }
            if !needle.isEmpty { return GridModel.matches(name(of: item.entry), needle) }
            if let folder = filter.folder {
                let own = item.entry.folder ?? ""
                return own == folder || own.hasPrefix(folder + "/")
            }
            return true
        }
        let sorted: [MediaItem]
        switch filter.sort {
        case .name: sorted = kept.sorted { finderOrder(name(of: $0.entry), name(of: $1.entry)) }
        case .dateAdded: sorted = kept.sorted { ($0.entry.addedAt ?? "") > ($1.entry.addedAt ?? "") }
        }
        return sorted.map(tile)
    }

    public static func tile(_ item: MediaItem) -> PoolTile {
        PoolTile(id: item.id, name: name(of: item.entry), kind: item.entry.kind, durationMs: item.entry.durationMs, tile: item.tile,
                 overlay: item.isDeleted ? .deleted : (item.isMissing ? .missing : .none), isOnThisMac: item.index == "machine")
    }

    /// Spec 10 §6, "The folder rail" — "the default import folder pinned at
    /// the top, then the media root's folders as a tree": every folder an
    /// item is in, and each one above it, in the Finder's order.
    public static func folders(_ media: [MediaItem]) -> [String] {
        var all: Set<String> = []
        for item in media {
            var parts: [String] = []
            for part in (item.entry.folder ?? "").split(separator: "/") {
                parts.append(String(part))
                all.insert(parts.joined(separator: "/"))
            }
        }
        return all.sorted(by: finderOrder)
    }

    /// Spec 10 §6 — an item's drop channel: "its `defaults.defaultChannel`,
    /// else the machine's `dropChannels` for its kind (Spec 8 §8), asking
    /// for a channel when that is "Ask"" (nil).
    public static func dropChannel(for entry: MediaEntry, settings: MachineSettings?) -> Int? {
        if let own = entry.defaults.defaultChannel { return own }
        let drops = settings?.dropChannels
        switch entry.kind {
        case .video: return drops?.video
        case .image: return drops?.image
        case .audio, .audioSet: return drops?.audio
        default: return nil
        }
    }

    /// The recently used strip: those of `recent` the pool still shows, newest first.
    public static func recents(_ media: [MediaItem], recent: [String]) -> [PoolTile] {
        recent.compactMap { id in media.first { $0.id == id && !($0.isDeleted && $0.uses == 0) } }.map(tile)
    }
}

// MARK: - The first window (Spec 10 §13)

/// Spec 10 §13, "The first window" — "names each new output ("Output 1 is
/// DELL U2720Q"), with Settings ▸ Outputs a click away, beside the UX spec's
/// line that these defaults are the operator's to rename, number and extend,
/// until dismissed."
public struct FirstWindowLine: Equatable, Sendable {
    /// Each new output's number and its device's name; at first run an output's label is its device's name.
    public var outputs: [(number: Int, device: String)]

    public static func == (a: FirstWindowLine, b: FirstWindowLine) -> Bool {
        a.outputs.map(\.number) == b.outputs.map(\.number) && a.outputs.map(\.device) == b.outputs.map(\.device)
    }

    /// The line for a first run's catalog, or nil when the app didn't make
    /// this run's library or the line was dismissed.
    public static func make(firstRun: Bool, dismissed: Bool, outputs: [Output]) -> FirstWindowLine? {
        guard firstRun, !dismissed else { return nil }
        return FirstWindowLine(outputs: outputs.sorted { $0.number < $1.number }.map { ($0.number, $0.label) })
    }
}
