// OApp — Spec 10 §3, what the queries answer, read into OCore's own document types.

import Foundation
import OCore

/// Reads what it can of an array of documents and says what it couldn't:
/// "Unknown input is a `noop` effect and a log line" (CLAUDE.md), so one
/// document a newer engine wrote doesn't cost the operator the rest.
private func documents<T: Decodable>(_ type: T.Type, _ value: JSONValue?, _ name: String, issues: inout [String]) -> [T] {
    guard let items = value?.arrayValue else {
        if value != nil { issues.append("\(name) isn't a list") }
        return []
    }
    var out: [T] = []
    for (index, item) in items.enumerated() {
        if let decoded = try? JSONCoding.decode(T.self, from: item) {
            out.append(decoded)
        } else {
            issues.append("\(name) \(index + 1) of \(items.count) couldn't be read")
        }
    }
    return out
}

/// OCore's `Transition`, under a name SwiftUI's own `Transition` can't hide
/// in the views. (The module's name can't qualify it: OCore holds an enum
/// called `OCore`.)
public typealias LibraryTransition = Transition

/// Spec 10 §3, the `catalog` query — a summary of one list: "number, uuid,
/// title, author, copyright, ccli, `trackThrough`, version, folder, cue
/// count, and whether it is a local copy", and whether its number names it.
public struct ListSummary: Equatable, Sendable {
    public var number: Int
    public var uuid: String
    public var title: String
    public var author: String
    public var copyright: String
    public var ccli: String
    public var trackThrough: Bool
    public var version: Int
    public var folder: String
    public var cues: Int
    public var local: Bool
    /// Spec 7 §2 — whether `list N` fires this one: false only for the one a
    /// twin with the same number hides, and for a local copy, which is
    /// fired through its playlist item.
    public var named: Bool

    public init(number: Int, uuid: String, title: String, author: String = "", copyright: String = "", ccli: String = "",
                trackThrough: Bool = false, version: Int = 1, folder: String = "", cues: Int = 0, local: Bool = false, named: Bool = true) {
        self.number = number
        self.uuid = uuid
        self.title = title
        self.author = author
        self.copyright = copyright
        self.ccli = ccli
        self.trackThrough = trackThrough
        self.version = version
        self.folder = folder
        self.cues = cues
        self.local = local
        self.named = named
    }

    init?(_ value: JSONValue) {
        guard let members = value.objectValue, let number = members.integer("number"), let uuid = members.text("uuid") else { return nil }
        self.init(number: number, uuid: uuid, title: members.text("title") ?? "", author: members.text("author") ?? "",
                  copyright: members.text("copyright") ?? "", ccli: members.text("ccli") ?? "", trackThrough: members.flag("trackThrough") ?? false,
                  version: members.integer("version") ?? 1, folder: members.text("folder") ?? "", cues: members.integer("cues") ?? 0,
                  local: members.flag("local") ?? false, named: members.flag("named") ?? true)
    }
}

/// Spec 10 §3, the `catalog` query — a playlist with its items, and whether
/// its title loads it: "where two playlists share a title ..., it says which
/// one the title ... names (Spec 7 §2–§3)".
public struct CatalogPlaylist: Equatable, Sendable {
    public var playlist: Playlist
    public var named: Bool

    public init(playlist: Playlist, named: Bool = true) {
        self.playlist = playlist
        self.named = named
    }
}

/// Spec 10 §3, the `catalog` query — "Both roots' documents except the
/// lists' cues and the media indexes: `library.json`, channels, text styles,
/// grades, transitions, audio transitions, presets, macros, the machine
/// settings, stacks, outputs, audio outputs, inputs, key bindings, every
/// playlist with its items, the library's folders, and a summary of each
/// list".
public struct Catalog: Equatable, Sendable {
    /// Spec 5 §2 — the library revision this catalog reflects.
    public var rev: Int
    public var info: LibraryInfo?
    public var channels: [Channel] = []
    public var textStyles: [TextStyle] = []
    public var grades: [Grade] = []
    public var transitions: [LibraryTransition] = []
    public var audioTransitions: [AudioTransition] = []
    public var presets: [Preset] = []
    public var libraryMacros: [Macro] = []
    public var folders: [String] = []
    public var settings: MachineSettings?
    public var stacks: [Stack] = []
    public var outputs: [Output] = []
    public var audioOutputs: [AudioOutput] = []
    public var inputs: [Input] = []
    public var keys: [KeyBinding] = []
    public var machineMacros: [Macro] = []
    public var playlists: [CatalogPlaylist] = []
    public var lists: [ListSummary] = []
    /// What couldn't be read, for the log.
    public var issues: [String] = []

    public init(rev: Int = 0) {
        self.rev = rev
    }

    /// Reads a `catalog` answer; nil when it has neither root in it.
    public init?(answer: [String: JSONValue]) {
        guard let library = answer.members("library"), let machine = answer.members("machine") else { return nil }
        rev = answer.integer("rev") ?? 0
        var issues: [String] = []
        info = library["info"].flatMap { try? JSONCoding.decode(LibraryInfo.self, from: $0) }
        channels = documents(Channel.self, library["channels"], "channel", issues: &issues)
        textStyles = documents(TextStyle.self, library["textStyles"], "text style", issues: &issues)
        grades = documents(Grade.self, library["grades"], "grade", issues: &issues)
        transitions = documents(LibraryTransition.self, library["transitions"], "transition", issues: &issues)
        audioTransitions = documents(AudioTransition.self, library["audioTransitions"], "audio transition", issues: &issues)
        presets = documents(Preset.self, library["presets"], "preset", issues: &issues)
        libraryMacros = documents(Macro.self, library["macros"], "macro", issues: &issues)
        folders = (library.items("folders") ?? []).compactMap(\.stringValue)
        settings = machine["settings"].flatMap { try? JSONCoding.decode(MachineSettings.self, from: $0) }
        if settings == nil { issues.append("the machine settings couldn't be read") }
        stacks = documents(Stack.self, machine["stacks"], "stack", issues: &issues)
        outputs = documents(Output.self, machine["outputs"], "output", issues: &issues)
        audioOutputs = documents(AudioOutput.self, machine["audioOutputs"], "audio output", issues: &issues)
        inputs = documents(Input.self, machine["inputs"], "input", issues: &issues)
        keys = documents(KeyBinding.self, machine["keys"], "key binding", issues: &issues)
        machineMacros = documents(Macro.self, machine["macros"], "machine macro", issues: &issues)
        for (index, value) in (machine.items("playlists") ?? []).enumerated() {
            guard let playlist = try? JSONCoding.decode(Playlist.self, from: value) else {
                issues.append("playlist \(index + 1) couldn't be read")
                continue
            }
            playlists.append(CatalogPlaylist(playlist: playlist, named: value.objectValue?.flag("named") ?? true))
        }
        for (index, value) in (answer.items("lists") ?? []).enumerated() {
            if let summary = ListSummary(value) {
                lists.append(summary)
            } else {
                issues.append("list summary \(index + 1) couldn't be read")
            }
        }
        self.issues = issues
    }

    /// Spec 1 §2 — a macro by number, "from the library root or the machine root".
    public var macros: [Macro] {
        (libraryMacros + machineMacros).sorted { $0.number < $1.number }
    }

    public func list(uuid: String) -> ListSummary? {
        lists.first { $0.uuid == uuid }
    }

    public func playlist(uuid: String) -> CatalogPlaylist? {
        playlists.first { $0.playlist.uuid.uuidString.lowercased() == uuid }
    }

    /// Spec 5 §7 — "On a `readOnlyMasters` machine it refuses edits of library objects".
    public var mastersAreReadOnly: Bool { settings?.libraryMode == .readOnlyMasters }
}

/// Spec 10 §3, the `list` query — "One list whole ..., with its folder".
public struct ListDocument: Equatable, Sendable {
    public var list: List
    public var folder: String
    public var local: Bool

    public init(list: List, folder: String = "", local: Bool = false) {
        self.list = list
        self.folder = folder
        self.local = local
    }

    public init?(answer: [String: JSONValue]) {
        guard let value = answer["list"], let list = try? JSONCoding.decode(List.self, from: value) else { return nil }
        self.init(list: list, folder: answer.text("folder") ?? "", local: answer.flag("local") ?? false)
    }

    public var uuid: String { list.uuid.uuidString.lowercased() }
}

/// Spec 10 §3, the `media` query — one entry of either index, "with its
/// index, its presence (`ok`, `missing` or `deleted`), what replaced it, its
/// uses as `mediaUse` counts them in all, and its tile's file".
public struct MediaItem: Equatable, Sendable {
    public var entry: MediaEntry
    /// `library` or `machine`.
    public var index: String
    public var presence: String
    public var replacedBy: String?
    public var uses: Int
    /// The pool tile's file, relative to the machine root; nil until one is written, and for audio.
    public var tile: String?

    public init(entry: MediaEntry, index: String = "library", presence: String = "ok", replacedBy: String? = nil, uses: Int = 0, tile: String? = nil) {
        self.entry = entry
        self.index = index
        self.presence = presence
        self.replacedBy = replacedBy
        self.uses = uses
        self.tile = tile
    }

    init?(_ value: JSONValue) {
        guard let members = value.objectValue, let entry = try? JSONCoding.decode(MediaEntry.self, from: value) else { return nil }
        self.init(entry: entry, index: members.text("index") ?? "library", presence: members.text("presence") ?? "ok",
                  replacedBy: members.text("replacedBy"), uses: members.integer("uses") ?? 0, tile: members.text("tile"))
    }

    public var id: String { entry.id }
    public var isMissing: Bool { presence == "missing" }
    public var isDeleted: Bool { presence == "deleted" }

    /// Reads a `media` answer, in the engine's order, with what couldn't be read.
    public static func items(answer: [String: JSONValue]) -> (items: [MediaItem], issues: [String]) {
        var items: [MediaItem] = []
        var issues: [String] = []
        for (index, value) in (answer.items("media") ?? []).enumerated() {
            if let item = MediaItem(value) {
                items.append(item)
            } else {
                issues.append("media entry \(index + 1) couldn't be read")
            }
        }
        return (items, issues)
    }
}

/// Spec 8 §7, the `mediaUse` query — "`{"cues": 12, "macros": 1, "presets":
/// 0, "keys": 2}`, counted over the library and machine documents on this
/// machine".
public struct MediaUseCount: Equatable, Sendable {
    public var cues: Int
    public var macros: Int
    public var presets: Int
    public var keys: Int

    public init(cues: Int = 0, macros: Int = 0, presets: Int = 0, keys: Int = 0) {
        self.cues = cues
        self.macros = macros
        self.presets = presets
        self.keys = keys
    }

    public init(answer: [String: JSONValue]) {
        self.init(cues: answer.integer("cues") ?? 0, macros: answer.integer("macros") ?? 0, presets: answer.integer("presets") ?? 0,
                  keys: answer.integer("keys") ?? 0)
    }

    public var total: Int { cues + macros + presets + keys }
}

/// Spec 10 §3, the `listUse` query — "the playlists that link it, archived ones marked".
public struct ListUse: Equatable, Sendable {
    public struct Linking: Equatable, Sendable {
        public var uuid: String
        public var title: String
        public var archived: Bool
    }

    public var playlists: [Linking]

    public init(answer: [String: JSONValue]) {
        playlists = (answer.items("playlists") ?? []).compactMap { value in
            guard let members = value.objectValue, let uuid = members.text("uuid") else { return nil }
            return Linking(uuid: uuid, title: members.text("title") ?? "", archived: members.flag("archived") ?? false)
        }
    }
}

/// Spec 9 §6, the `versions` query — a list's kept versions, "newest first,
/// each with `version`, `keptAt` (the file's date), `title` and `cues`".
public struct KeptVersion: Equatable, Sendable {
    public var version: Int
    public var keptAt: String
    public var title: String
    public var cues: Int

    public static func all(answer: [String: JSONValue]) -> [KeptVersion] {
        (answer.items("versions") ?? []).compactMap { value in
            guard let members = value.objectValue, let version = members.integer("version") else { return nil }
            return KeptVersion(version: version, keptAt: members.text("keptAt") ?? "", title: members.text("title") ?? "", cues: members.integer("cues") ?? 0)
        }
    }
}

/// Spec 9 §6, the `snapshots` query — "newest first, each with `id`,
/// `takenAt`, `reason`, `bytes`, and `machine` and `campus` from its
/// manifest".
public struct SnapshotSummary: Equatable, Sendable {
    public var id: String
    public var takenAt: String
    public var reason: String
    public var bytes: Int
    public var machine: String
    public var campus: String

    public static func all(answer: [String: JSONValue]) -> [SnapshotSummary] {
        (answer.items("snapshots") ?? []).compactMap { value in
            guard let members = value.objectValue, let id = members.text("id") else { return nil }
            return SnapshotSummary(id: id, takenAt: members.text("takenAt") ?? "", reason: members.text("reason") ?? "",
                                   bytes: members.integer("bytes") ?? 0, machine: members.text("machine") ?? "", campus: members.text("campus") ?? "")
        }
    }
}

/// Spec 10 §3, the `thumbnails` query — "For a list ... and `stack` S, each
/// cue's thumbnail file or null."
public struct CueThumbnails: Equatable, Sendable {
    public var stack: Int
    /// By cue uuid; a cue with no file yet isn't in it.
    public var files: [String: String]

    public init(answer: [String: JSONValue]) {
        stack = answer.integer("stack") ?? 0
        files = [:]
        for value in answer.items("thumbnails") ?? [] {
            guard let members = value.objectValue, let cue = members.text("cue"), let file = members.text("file") else { continue }
            files[cue] = file
        }
    }
}
