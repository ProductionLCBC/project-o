// OApp — Spec 10 §6, what the cue grid shows, worked out from what the store holds.

import Foundation
import OCore

/// Spec 10 §6, "The edge and the tags" — "the section's colour as the left
/// edge, from a fixed palette of eight hues that are neither the live red
/// nor the browse amber, common section names (Verse, Chorus, Bridge,
/// Pre-chorus, Tag, Intro, Outro) always taking the same hue and other names
/// a hue by a hash of the name".
public enum SectionHue {
    /// "a fixed palette of eight hues".
    public static let count = 8

    private static let common: [String: Int] = ["verse": 0, "chorus": 1, "bridge": 2, "prechorus": 3, "tag": 4, "intro": 5, "outro": 6]

    /// Area 13 reading — a section's name is compared without its case, its
    /// spaces and hyphens, or a number after it: "Verse 2", "VERSE" and
    /// "verse" are one section, and so are "Pre-Chorus" and "prechorus".
    public static func key(_ name: String) -> String {
        var letters = name.lowercased().filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        while let last = letters.last, last.isNumber { letters.removeLast() }
        return letters
    }

    /// The hue's place in the palette. A name that isn't one of the common
    /// seven takes its hue from a hash that is the same on every Mac and at
    /// every launch (FNV-1a over the key's UTF-8), which Swift's own hash is not.
    public static func index(for name: String) -> Int {
        let key = key(name)
        if let fixed = common[key] { return fixed }
        var hash: UInt32 = 2_166_136_261
        for byte in key.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(count))
    }
}

/// Spec 10 §15 — times as the window shows them. Numbers use the system's
/// formatter, so a decimal comma comes where the Mac's language has one.
public enum TimeText {
    /// "0:08", "1:23", "1:02:03". A countdown rounds up, so it never reads
    /// 0:00 before it is over (Area 13 reading).
    public static func clock(ms: Int, roundUp: Bool = false) -> String {
        let clamped = max(0, ms)
        let seconds = roundUp ? (clamped + 999) / 1000 : clamped / 1000
        let (hours, minutes, rest) = (seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        let two = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(rest))" : "\(minutes):\(two(rest))"
    }

    /// A span under a minute as a number of seconds with one decimal at
    /// most, "8" or "2.5", for a sentence that adds the unit; nil from a
    /// minute on, which reads better as a clock (Area 13 reading).
    public static func shortSeconds(ms: Int, locale: Locale = .current) -> String? {
        guard ms < 60_000 else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(max(0, ms)) / 1000))
    }
}

/// Spec 10 §6, "The chips" — "from the app's own fold of the list, made with
/// OCore's projection over the documents it holds (Spec 3 §7's cue-view
/// base, as the engine's thumbnail job does)".
public enum CueFold {
    /// OCore's library and machine, as far as a fold reads them, from the
    /// `catalog` and `media` answers.
    public static func roots(catalog: Catalog, media: [MediaItem], lists: [List] = []) -> (library: Library, machine: Machine) {
        var libraryReplaced: [String: String] = [:]
        var machineReplaced: [String: String] = [:]
        for item in media {
            guard let by = item.replacedBy else { continue }
            if item.index == "machine" { machineReplaced[item.id] = by } else { libraryReplaced[item.id] = by }
        }
        let library = Library(channels: catalog.channels, transitions: catalog.transitions, audioTransitions: catalog.audioTransitions,
                              lists: lists.filter { $0.provenance == nil }, macros: catalog.libraryMacros, info: catalog.info ?? LibraryInfo(),
                              textStyles: catalog.textStyles, grades: catalog.grades, presets: catalog.presets,
                              mediaIndex: MediaIndex(entries: media.filter { $0.index != "machine" }.map(\.entry), replaced: libraryReplaced),
                              folders: catalog.folders)
        let settings = catalog.settings ?? MachineSettings()
        let machine = Machine(stacks: catalog.stacks, outputs: catalog.outputs, playlists: catalog.playlists.map(\.playlist),
                              localLists: lists.filter { $0.provenance != nil }, tracking: settings.tracking,
                              decoderCapDefault: settings.decoderCapDefault, settings: settings, audioOutputs: catalog.audioOutputs,
                              inputs: catalog.inputs, keys: catalog.keys,
                              mediaLocal: MediaLocalIndex(entries: media.filter { $0.index == "machine" }.map(\.entry), replaced: machineReplaced),
                              macros: catalog.machineMacros)
        return (library, machine)
    }

    /// The ids a fold reads as missing: Spec 3 §4's "set of missing ids", from each item's presence.
    public static func missing(_ media: [MediaItem]) -> Set<String> {
        Set(media.filter { $0.isMissing || $0.isDeleted }.map(\.id))
    }

    /// One list folded from its top: the state after each cue, and its chips.
    public static func steps(of list: List, catalog: Catalog, media: [MediaItem]) -> [CueView.Step] {
        let roots = roots(catalog: catalog, media: media, lists: [list])
        return CueView.fold(list, library: roots.library, machine: roots.machine, missing: missing(media))
    }
}

/// Spec 10 §6, "A cue cell" — what one cell shows, before any wording.
public struct CueCell: Equatable, Sendable {
    /// The cue's uuid, in lower case, and its number in the list.
    public var uuid: String
    public var number: Int
    public var label: String
    /// "a note glyph, with the note on hover"; empty for none.
    public var note: String
    public var section: String?
    /// The section's place in the palette of eight; nil for a cue with no section, which has a plain edge.
    public var hue: Int?
    public var trigger: CueTrigger.Kind
    public var advanceAfterMs: Int?
    /// One per channel, in number order.
    public var chips: [CueChip]
    /// "Until a file arrives, the cell shows the cue's text, if it has any, on black."
    public var text: String?
    /// The thumbnail's file, relative to the machine root.
    public var thumbnail: String?
    /// "a red outline on the live cue".
    public var isLive: Bool
    /// "on the cue armed to fire next, "Auto 0:08" in amber".
    public var isArmed: Bool
    /// "a red "missing" tag when media it writes is missing or deleted".
    public var missingMedia: Bool
    /// "a warning tag when it holds a command kept verbatim because it is unknown (Spec 1 §6)".
    public var keptUnknown: Bool
    /// The search field "highlights the cues whose label or text matches".
    public var matchesSearch: Bool

    /// "Past eight channels the row ends with "+N"": the chips shown, and how many are left over.
    public var shownChips: (chips: [CueChip], more: Int) {
        chips.count > 8 ? (Array(chips.prefix(8)), chips.count - 8) : (chips, 0)
    }
}

/// Spec 10 §6 — one row of the grid's outline: a playlist's header, or a list with its cues.
public struct GridSection: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "headers in small capitals" (Spec 10 §5).
        case header
        case list
    }

    public var kind: Kind
    /// The playlist item's number, from 1, and its uuid; nil for a list opened from the library.
    public var item: Int?
    public var itemUuid: String?
    public var listUuid: String?
    public var listNumber: Int?
    /// A header's label, or the list's title.
    public var title: String
    /// "a "local" tag for a local copy".
    public var isLocal = false
    /// "the live dot on the live item".
    public var isLive = false
    public var cueCount = 0
    public var ccli = ""
    /// "It shows "updated" after its master reloads from disk (Spec 1 §8) until the list is next fired".
    public var isUpdated = false
    /// ""missing" in red, with no cues, when its list is gone".
    public var isMissing = false
    /// "dimmed and labelled "Removed: finishing", with the live cue marked, until the pointer leaves it (Spec 7 §4)".
    public var isRemoved = false
    /// Why its cues can't be fired, or nil when they can (Spec 10 §6, "Clicking").
    public var refusal: FireRefusal?
    /// The list's cues; empty until the app holds the list.
    public var cells: [CueCell] = []
}

/// Spec 10 §6 — the grid: its header and its sections.
public struct GridModel: Equatable, Sendable {
    public var context: GridContext?
    /// "the title (a playlist's with its date, or a list's)".
    public var title = ""
    public var serviceDate: String?
    public var serviceTime: String?
    /// "the number of lists or of cues".
    public var listCount: Int?
    public var cueCount: Int?
    /// "A list from the library is headed "From the library: Next stops at its last cue"."
    public var isFromLibrary = false
    public var sections: [GridSection] = []

    public init() {}

    /// The cell of the live cue and where it is, for scrolling to it.
    public var liveCell: (section: Int, cell: Int)? {
        for (s, section) in sections.enumerated() {
            if let c = section.cells.firstIndex(where: \.isLive) { return (s, c) }
        }
        return nil
    }
}

/// What the grid's model is built from: a copy of what the store holds, and what the window knows.
public struct GridInputs: Sendable {
    public var context: GridContext?
    public var catalog: Catalog?
    public var lists: [String: ListDocument] = [:]
    public var thumbnails: [String: [String: String]] = [:]
    public var media: [MediaItem] = []
    public var live = LiveStatus()
    /// The search field's text; empty for none.
    public var search = ""
    /// The lists whose master reloaded from disk and hasn't been fired since.
    public var updated: Set<String> = []
    /// The live item's section as it was before the item was removed, and where it stood (Spec 7 §4).
    public var removed: (index: Int, section: GridSection)?

    public init(context: GridContext?, catalog: Catalog?) {
        self.context = context
        self.catalog = catalog
    }
}

extension GridModel {
    /// The lists the app should hold whole: "the lists of the browsed and
    /// the live contexts" (Area 13 reading of Spec 10 §3).
    public static func listsNeeded(shown: GridContext?, live: LiveStatus, catalog: Catalog?) -> Set<String> {
        guard let catalog else { return [] }
        var needed: Set<String> = []
        for context in [shown, BrowseState.liveContext(live)].compactMap({ $0 }) {
            switch context {
            case .list(let uuid):
                needed.insert(uuid)
            case .playlist(let uuid):
                guard let playlist = catalog.playlist(uuid: uuid)?.playlist else { continue }
                for item in playlist.items {
                    if let list = listUuid(of: item, catalog: catalog) { needed.insert(list) }
                }
            }
        }
        if let live = live.listUuid { needed.insert(live) }
        return needed
    }

    /// The uuid of the list an item shows: the one it names, or for an item
    /// from before uuids were recorded, the master its number names.
    static func listUuid(of item: PlaylistItem, catalog: Catalog) -> String? {
        switch item.kind {
        case .header:
            return nil
        case .linked(let number, let uuid):
            if let uuid { return uuid.uuidString.lowercased() }
            return catalog.lists.first { $0.number == number && !$0.local && $0.named }?.uuid
        case .local(let uuid):
            return uuid.uuidString.lowercased()
        }
    }

    /// Builds the grid from what the store holds.
    public static func make(_ inputs: GridInputs) -> GridModel {
        var model = GridModel()
        model.context = inputs.context
        guard let context = inputs.context, let catalog = inputs.catalog else { return model }
        let missing = CueFold.missing(inputs.media)
        let textChannel = catalog.channels.sorted { $0.number < $1.number }.first { $0.usualContent == .text }?.number

        func cells(of document: ListDocument, section: GridSection) -> [CueCell] {
            let steps = CueFold.steps(of: document.list, catalog: catalog, media: inputs.media)
            let files = inputs.thumbnails[document.uuid] ?? [:]
            let needle = inputs.search.trimmingCharacters(in: .whitespacesAndNewlines)
            return document.list.cues.enumerated().map { index, cue in
                let uuid = cue.uuid.uuidString.lowercased()
                let commands = cue.commands.map(\.command)
                let texts = Self.texts(written: commands)
                let isLive = inputs.live.cue == uuid && inputs.live.listUuid == section.listUuid
                    && (section.itemUuid == nil || inputs.live.item == section.itemUuid)
                let isArmed = inputs.live.armed?.cue == uuid && (section.itemUuid == nil || inputs.live.armed?.item == section.itemUuid)
                    && (section.itemUuid != nil || inputs.live.listUuid == section.listUuid)
                return CueCell(uuid: uuid, number: index + 1, label: cue.label, note: cue.note, section: cue.section,
                               hue: cue.section.flatMap { $0.isEmpty ? nil : SectionHue.index(for: $0) },
                               trigger: cue.trigger.kind, advanceAfterMs: cue.advanceAfterMs,
                               chips: index < steps.count ? steps[index].chips : [],
                               text: texts.first { $0.channel == textChannel }?.text ?? texts.first?.text,
                               thumbnail: files[uuid], isLive: isLive, isArmed: isArmed,
                               missingMedia: Self.refs(written: commands).contains { missing.contains($0) },
                               keptUnknown: commands.contains { $0.isUnknown },
                               matchesSearch: !needle.isEmpty && ([cue.label] + texts.map(\.text)).contains { Self.matches($0, needle) })
            }
        }

        switch context {
        case .list(let uuid):
            model.isFromLibrary = true
            let summary = catalog.list(uuid: uuid)
            let document = inputs.lists[uuid]
            model.title = document?.list.title ?? summary?.title ?? ""
            model.cueCount = document?.list.cues.count ?? summary?.cues
            var section = GridSection(kind: .list, listUuid: uuid, listNumber: summary?.number ?? document?.list.number, title: model.title)
            section.isLocal = summary?.local ?? document?.local ?? false
            section.isLive = inputs.live.isLibraryList && inputs.live.listUuid == uuid
            section.cueCount = model.cueCount ?? 0
            section.ccli = document?.list.ccli ?? summary?.ccli ?? ""
            section.isUpdated = inputs.updated.contains(uuid)
            section.isMissing = summary == nil && document == nil
            if let summary, case .failure(let refusal) = GridFire.libraryCue(summary, cue: 1) { section.refusal = refusal }
            if let document { section.cells = cells(of: document, section: section) }
            model.sections = [section]

        case .playlist(let uuid):
            guard let entry = catalog.playlist(uuid: uuid) else { return model }
            let playlist = entry.playlist
            model.title = playlist.title
            model.serviceDate = playlist.serviceDate
            model.serviceTime = playlist.serviceTime
            let isLivePlaylist = inputs.live.playlist == uuid
            var lists = 0
            for (index, item) in playlist.items.enumerated() {
                let itemUuid = item.uuid.uuidString.lowercased()
                switch item.kind {
                case .header(let label):
                    model.sections.append(GridSection(kind: .header, item: index + 1, itemUuid: itemUuid, title: label))
                case .linked, .local:
                    lists += 1
                    let listUuid = Self.listUuid(of: item, catalog: catalog)
                    let summary = listUuid.flatMap { catalog.list(uuid: $0) }
                    let document = listUuid.flatMap { inputs.lists[$0] }
                    var section = GridSection(kind: .list, item: index + 1, itemUuid: itemUuid, listUuid: listUuid,
                                              listNumber: summary?.number ?? document?.list.number,
                                              title: document?.list.title ?? summary?.title ?? "")
                    if case .local = item.kind { section.isLocal = true }
                    section.isLive = isLivePlaylist && inputs.live.item == itemUuid
                    section.cueCount = document?.list.cues.count ?? summary?.cues ?? 0
                    section.ccli = document?.list.ccli ?? summary?.ccli ?? ""
                    section.isUpdated = listUuid.map { inputs.updated.contains($0) } ?? false
                    section.isMissing = summary == nil
                    if !isLivePlaylist, !entry.named { section.refusal = .renameToFire }
                    if let document, !section.isMissing { section.cells = cells(of: document, section: section) }
                    model.sections.append(section)
                }
            }
            model.listCount = lists
            // Spec 7 §4 — "While the live item is removed (the `live` event's `gone`), its list stays at its old place".
            if isLivePlaylist, inputs.live.gone.contains("item"), var kept = inputs.removed?.section, let at = inputs.removed?.index,
               !model.sections.contains(where: { $0.itemUuid == kept.itemUuid }) {
                kept.isRemoved = true
                kept.isLive = true
                if let listUuid = kept.listUuid, let document = inputs.lists[listUuid] { kept.cells = cells(of: document, section: kept) }
                model.sections.insert(kept, at: min(at, model.sections.count))
            }
        }
        return model
    }

    /// The text each text write of a cue's own commands carries: the body, or its fields in order.
    static func texts(written commands: [Command]) -> [(channel: Int?, text: String)] {
        commands.compactMap { command in
            guard case .channelWrite(let write) = command, case .text(let fields) = write.content else { return nil }
            let text = fields["body"] ?? fields.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
            guard !text.isEmpty else { return nil }
            if case .number(let channel) = write.channel { return (channel, text) }
            return (nil, text)
        }
    }

    /// The media and slide ids a cue's own commands write.
    static func refs(written commands: [Command]) -> [String] {
        commands.compactMap { command in
            guard case .channelWrite(let write) = command else { return nil }
            switch write.content {
            case .media(let media): return media.ref
            case .slide(let ref, _): return ref
            default: return nil
            }
        }
    }

    /// Area 13 reading — the search ignores case and accents, anywhere in the text.
    static func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
