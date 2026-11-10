// OCore — Spec 1 §2 and §5, the library root in memory.

import Foundation

/// Spec 1 §5 — `library.json`: "schema, library uuid, name". Spec 1 §4:
/// "Machines and libraries each have a `uuid`, generated on first run and
/// never changed."
public struct LibraryInfo: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var name: String
    public var extra: [String: JSONValue]

    public init(uuid: UUID = UUID(), name: String = "", extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.name = name
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case uuid, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        name = try c.value(.name, default: "")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(name, forKey: .name)
    }
}

/// Spec 1 §5 — the library root: "portable, synced down to campuses". Every
/// portable object of §2 in number order, the library index of §7, and what
/// the loader needs to write each document back where it found it. Spec 3 §6
/// reads it as the context's `library`.
public struct Library: Equatable, Sendable {
    public var info: LibraryInfo
    public var channels: [Channel]
    public var textStyles: [TextStyle]
    public var grades: [Grade]
    public var transitions: [Transition]
    public var audioTransitions: [AudioTransition]
    public var presets: [Preset]
    public var macros: [Macro]
    public var lists: [List]
    public var mediaIndex: MediaIndex
    /// Spec 1 §8 — unknown top-level keys of the single-document catalogs, by kind.
    public var documentExtras: [DocumentKind: [String: JSONValue]]
    /// Spec 1 §5 — where each per-object document was loaded from, keyed by
    /// `FileLayout.documentKey`, so a save can rename the file to match.
    /// Spec 7 §2 — a list's folder is the folder its path is in.
    public var documentPaths: [String: String]
    /// Spec 7 §2 — "The Library window's folder tree is the tree of folders
    /// under `lists/`": every folder, empty ones included, as its path under
    /// `lists/` ("Worship/Hymns"), in the case it was made with.
    public var folders: [String]
    /// Spec 7 §2 — the visible files under `lists/` that aren't loaded lists
    /// (a note, a list file that didn't read, the other of two files holding
    /// one list), by path: they keep a folder from being empty, and no save
    /// or move ever replaces one ("Other files are never replaced").
    public var otherFiles: Set<String>

    public init(channels: [Channel] = [], transitions: [Transition] = [], audioTransitions: [AudioTransition] = [],
                lists: [List] = [], macros: [Macro] = [], info: LibraryInfo = LibraryInfo(), textStyles: [TextStyle] = [],
                grades: [Grade] = [], presets: [Preset] = [], mediaIndex: MediaIndex = MediaIndex(),
                documentExtras: [DocumentKind: [String: JSONValue]] = [:], documentPaths: [String: String] = [:],
                folders: [String] = [], otherFiles: Set<String> = []) {
        self.info = info
        self.channels = channels
        self.textStyles = textStyles
        self.grades = grades
        self.transitions = transitions
        self.audioTransitions = audioTransitions
        self.presets = presets
        self.macros = macros
        self.lists = lists
        self.mediaIndex = mediaIndex
        self.documentExtras = documentExtras
        self.documentPaths = documentPaths
        self.folders = folders
        self.otherFiles = otherFiles
    }

    /// Spec 7 §2 — the folder a master's file is in, under `lists/` ("" at
    /// the top), or nil for a list the library doesn't hold.
    public func folder(ofList uuid: UUID) -> String? {
        guard let path = documentPaths[FileLayout.documentKey(list: uuid)] else {
            return list(uuid: uuid) == nil ? nil : ""
        }
        return FileLayout.folder(ofListPath: path)
    }

    // MARK: - Lookups by number (Spec 1 §4: "A reference ... is the target's number")

    public func channel(_ number: Int) -> Channel? { channels.first { $0.number == number } }
    public func textStyle(_ number: Int) -> TextStyle? { textStyles.first { $0.number == number } }
    public func grade(_ number: Int) -> Grade? { grades.first { $0.number == number } }
    public func transition(_ number: Int) -> Transition? { transitions.first { $0.number == number } }
    public func audioTransition(_ number: Int) -> AudioTransition? { audioTransitions.first { $0.number == number } }
    public func preset(_ number: Int) -> Preset? { presets.first { $0.number == number } }
    public func macro(_ number: Int) -> Macro? { macros.first { $0.number == number } }
    /// Spec 7 §2 — "Anything that names the number alone ... gets the one that
    /// comes first" of two lists sharing it, in the order they loaded in.
    public func list(number: Int) -> List? { lists.first { $0.number == number } }
    public func list(uuid: UUID) -> List? { lists.first { $0.uuid == uuid } }

    /// Spec 7 §3 — the master a linked item names: "A linked item finds its
    /// list by `listUuid` ... When no list has that uuid, the item is missing,
    /// even if another list now has its number. An item without a `listUuid`,
    /// from a hand-made file, finds its list by number." Headers name none; a
    /// local item's copy lives in the machine root (`CueAddressing`), so here
    /// it finds only a master with that uuid.
    public func list(for kind: PlaylistItem.Kind) -> List? {
        switch kind {
        case .header: return nil
        case .linked(let number, let listUuid):
            if let listUuid { return list(uuid: listUuid) }
            return list(number: number)
        case .local(let uuid): return list(uuid: uuid)
        }
    }

    /// Spec 1 §2 and §8 — "Falls back to Preset 1 if missing"; a library
    /// without a preset 1 on disk falls back to the built-in one. The degrade
    /// happens here, at use; the object that named the missing preset is
    /// kept as read (Area 2 plan, reading 2).
    public func resolvedPreset(_ number: Int?) -> Preset {
        if let number, let found = preset(number) { return found }
        return preset(1) ?? Preset.builtInDefault
    }

    /// Replace the list with the same `uuid`, or append it.
    public mutating func replace(list: List) {
        if let index = lists.firstIndex(where: { $0.uuid == list.uuid }) {
            lists[index] = list
        } else {
            lists.append(list)
            lists.sort { $0.number < $1.number }
        }
    }
}
