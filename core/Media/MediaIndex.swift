// OCore — Spec 1 §7, the media index and resolver.

import Foundation

/// Spec 1 §7 — index entry `kind`: "`video`, `image`, `audio`, `audioSet`,
/// `slide`, `template`".
public enum MediaKind: String, Codable, Equatable, Sendable {
    case video, image, audio, audioSet, slide, template
}

/// Spec 1 §7 — index entry `defaults`: "`trimInMs`, `trimOutMs`, `loop`,
/// `gain` (dB), `grade` (number or null), `syncOffsetMs` (±1000),
/// `defaultChannel` (number or null)". Null means none, which is what a media
/// write falls through to (Spec 3 §4).
public struct MediaDefaults: Codable, Equatable, Sendable {
    public var trimInMs: Int?
    public var trimOutMs: Int?
    public var loop: Bool
    public var gain: Double?
    public var grade: Int?
    public var syncOffsetMs: Int?
    public var defaultChannel: Int?
    public var extra: [String: JSONValue]

    public init(trimInMs: Int? = nil, trimOutMs: Int? = nil, loop: Bool = false, gain: Double? = nil, grade: Int? = nil,
                syncOffsetMs: Int? = nil, defaultChannel: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.trimInMs = trimInMs
        self.trimOutMs = trimOutMs
        self.loop = loop
        self.gain = gain
        self.grade = grade
        self.syncOffsetMs = syncOffsetMs
        self.defaultChannel = defaultChannel
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case trimInMs, trimOutMs, loop, gain, grade, syncOffsetMs, defaultChannel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trimInMs = try c.decodeIfPresent(Int.self, forKey: .trimInMs)
        trimOutMs = try c.decodeIfPresent(Int.self, forKey: .trimOutMs)
        loop = try c.value(.loop, default: false)
        gain = try c.decodeIfPresent(Double.self, forKey: .gain)
        grade = try c.decodeIfPresent(Int.self, forKey: .grade)
        syncOffsetMs = try c.decodeIfPresent(Int.self, forKey: .syncOffsetMs)
        defaultChannel = try c.decodeIfPresent(Int.self, forKey: .defaultChannel)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(trimInMs, forKey: .trimInMs)
        try c.encodeNullable(trimOutMs, forKey: .trimOutMs)
        try c.encode(loop, forKey: .loop)
        try c.encodeNullable(gain, forKey: .gain)
        try c.encodeNullable(grade, forKey: .grade)
        try c.encodeNullable(syncOffsetMs, forKey: .syncOffsetMs)
        try c.encodeNullable(defaultChannel, forKey: .defaultChannel)
    }
}

/// Spec 1 §7 — an index entry: `id`, `path` ("Relative to the media root,
/// forward slashes; updated when the file moves"), `kind`, `size`, `modified`
/// ("For change detection without re-hashing"), `durationMs`, `fps`, `width`,
/// `height`, `hasAudio`, `hasAlpha`, `codec`, `poster`, `defaults`, `addedAt`,
/// `folder`; for audio sets, `tracks` ("the member ids in play order") and
/// `crossfadeMs`.
public struct MediaEntry: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var kind: MediaKind
    public var size: Int
    public var modified: String?
    public var durationMs: Int?
    public var fps: FrameRate?
    public var width: Int?
    public var height: Int?
    public var hasAudio: Bool
    public var hasAlpha: Bool
    public var codec: String?
    public var poster: String?
    public var defaults: MediaDefaults
    public var addedAt: String?
    public var folder: String?
    public var tracks: [String]?
    public var crossfadeMs: Int?
    public var extra: [String: JSONValue]

    public init(id: String, path: String, kind: MediaKind, size: Int, modified: String? = nil, durationMs: Int? = nil,
                fps: FrameRate? = nil, width: Int? = nil, height: Int? = nil, hasAudio: Bool = false, hasAlpha: Bool = false,
                codec: String? = nil, poster: String? = nil, defaults: MediaDefaults = MediaDefaults(), addedAt: String? = nil,
                folder: String? = nil, tracks: [String]? = nil, crossfadeMs: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.id = id
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.durationMs = durationMs
        self.fps = fps
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.hasAlpha = hasAlpha
        self.codec = codec
        self.poster = poster
        self.defaults = defaults
        self.addedAt = addedAt
        self.folder = folder ?? MediaEntry.folder(of: path)
        self.tracks = tracks
        self.crossfadeMs = crossfadeMs
        self.extra = extra
    }

    /// The folder part of a relative path, for the folder rail.
    public static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, path, kind, size, modified, durationMs, fps, width, height, hasAudio, hasAlpha, codec, poster, defaults
        case addedAt, folder, tracks, crossfadeMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        path = try c.value(.path, default: "")
        kind = try c.value(.kind, default: .video)
        size = try c.value(.size, default: 0)
        modified = try c.decodeIfPresent(String.self, forKey: .modified)
        durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
        fps = try c.decodeIfPresent(FrameRate.self, forKey: .fps)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        hasAudio = try c.value(.hasAudio, default: false)
        hasAlpha = try c.value(.hasAlpha, default: false)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        poster = try c.decodeIfPresent(String.self, forKey: .poster)
        defaults = try c.value(.defaults, default: MediaDefaults())
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        folder = try c.decodeIfPresent(String.self, forKey: .folder)
        tracks = try c.decodeIfPresent([String].self, forKey: .tracks)
        crossfadeMs = try c.decodeIfPresent(Int.self, forKey: .crossfadeMs)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(kind, forKey: .kind)
        try c.encode(size, forKey: .size)
        try c.encodeNullable(modified, forKey: .modified)
        try c.encodeNullable(durationMs, forKey: .durationMs)
        try c.encodeNullable(fps, forKey: .fps)
        try c.encodeNullable(width, forKey: .width)
        try c.encodeNullable(height, forKey: .height)
        try c.encode(hasAudio, forKey: .hasAudio)
        try c.encode(hasAlpha, forKey: .hasAlpha)
        try c.encodeNullable(codec, forKey: .codec)
        try c.encodeNullable(poster, forKey: .poster)
        try c.encode(defaults, forKey: .defaults)
        try c.encodeNullable(addedAt, forKey: .addedAt)
        try c.encodeNullable(folder, forKey: .folder)
        // Spec 1 §7 — audio sets only.
        try c.encodeIfPresent(tracks, forKey: .tracks)
        try c.encodeIfPresent(crossfadeMs, forKey: .crossfadeMs)
    }
}

/// Spec 1 §7 — the library index (`library/media-index.json`), "synced with
/// the library, written only by machines in writable library mode", with the
/// `replaced` map `replace media` records "so re-imports of the old file
/// resolve to the new one". Entries are kept in id order.
public struct MediaIndex: Codable, Equatable, Sendable {
    public var entries: [MediaEntry]
    public var replaced: [String: String]
    public var extra: [String: JSONValue]

    public init(entries: [MediaEntry] = [], replaced: [String: String] = [:], extra: [String: JSONValue] = [:]) {
        self.entries = entries.sorted { $0.id < $1.id }
        self.replaced = replaced
        self.extra = extra
    }

    public func entry(_ id: String) -> MediaEntry? {
        entries.first { $0.id == id }
    }

    /// Spec 1 §4 — "Identical files anywhere under the root resolve to one
    /// identity." Adds the entry unless its id is already indexed; returns
    /// whether it was new.
    @discardableResult
    public mutating func add(_ entry: MediaEntry) -> Bool {
        guard self.entry(entry.id) == nil else { return false }
        entries.append(entry)
        entries.sort { $0.id < $1.id }
        return true
    }

    /// Follows the `replaced` map, at most a few steps, so a replaced id
    /// resolves to its replacement.
    public func resolveReplaced(_ id: String) -> String {
        var current = id
        var steps = 0
        while let next = replaced[current], next != current, steps < 8 {
            current = next
            steps += 1
        }
        return current
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case entries, replaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.value(.entries, default: [MediaEntry]()).sorted { $0.id < $1.id }
        replaced = try c.value(.replaced, default: [:])
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.sorted { $0.id < $1.id }, forKey: .entries)
        try c.encode(replaced, forKey: .replaced)
    }
}

/// Spec 1 §7 — the machine index (`machine/media-local.json`) "for media that
/// exists only on this machine plus any path overrides": `overrides` maps an
/// id to a local path, so "the library index is never edited" when a campus
/// relocates media.
public struct MediaLocalIndex: Codable, Equatable, Sendable {
    public var entries: [MediaEntry]
    public var overrides: [String: String]
    public var extra: [String: JSONValue]

    public init(entries: [MediaEntry] = [], overrides: [String: String] = [:], extra: [String: JSONValue] = [:]) {
        self.entries = entries.sorted { $0.id < $1.id }
        self.overrides = overrides
        self.extra = extra
    }

    public func entry(_ id: String) -> MediaEntry? {
        entries.first { $0.id == id }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case entries, overrides }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.value(.entries, default: [MediaEntry]()).sorted { $0.id < $1.id }
        overrides = try c.value(.overrides, default: [:])
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.sorted { $0.id < $1.id }, forKey: .entries)
        try c.encode(overrides, forKey: .overrides)
    }
}

/// Spec 1 §7 — what a lookup found: the entry, the path to use for it, and
/// which tier answered.
public struct ResolvedMedia: Equatable, Sendable {
    public enum Tier: Equatable, Sendable { case machine, library }

    public var entry: MediaEntry
    public var path: String
    public var tier: Tier

    public init(entry: MediaEntry, path: String, tier: Tier) {
        self.entry = entry
        self.path = path
        self.tier = tier
    }
}

/// Spec 1 §7 — the resolver. "Lookup order. Resolve an id in the machine
/// index first, then the library index... the machine index carries
/// `overrides` from id to local path". A replaced id means its replacement
/// before either index is consulted ("so re-imports of the old file resolve
/// to the new one"). Missing state is computed from the file list, never
/// stored.
public enum MediaResolver {
    public static func resolve(_ id: String, library: Library, machine: Machine?) -> ResolvedMedia? {
        let candidate = library.mediaIndex.resolveReplaced(id)
        if let entry = machine?.mediaLocal.entry(candidate) {
            return ResolvedMedia(entry: entry, path: machine?.mediaLocal.overrides[candidate] ?? entry.path, tier: .machine)
        }
        if let entry = library.mediaIndex.entry(candidate) {
            return ResolvedMedia(entry: entry, path: machine?.mediaLocal.overrides[candidate] ?? entry.path, tier: .library)
        }
        return nil
    }

    /// Spec 1 §7 — "an id whose path no longer exists stays in the index, is
    /// shown with a missing badge wherever it is referenced, and is listed by
    /// pre-flight." The ids of every indexed entry whose resolved path is not
    /// among the files that exist.
    public static func missingIds(library: Library, machine: Machine?, existingPaths: Set<String>) -> Set<String> {
        var missing: Set<String> = []
        let ids = (machine?.mediaLocal.entries.map(\.id) ?? []) + library.mediaIndex.entries.map(\.id)
        for id in ids {
            guard let resolved = resolve(id, library: library, machine: machine) else { continue }
            if !existingPaths.contains(resolved.path) { missing.insert(id) }
        }
        return missing
    }
}
