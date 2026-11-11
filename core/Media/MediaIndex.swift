// OCore — Spec 1 §7, the media index; Spec 8 §2 and §6, deletedAt and the machine replaced map.

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

/// Spec 1 §7 — an index entry: `id`, `path` ("Relative to the media root, or
/// to `machine/media/` for a machine-index entry; forward slashes; updated
/// when the file moves, and empty once another file took its place or the
/// item was deleted"), `kind`, `size`, `modified` ("For change detection
/// without re-hashing"), `durationMs`, `fps`, `width`, `height`, `hasAudio`,
/// `hasAlpha`, `codec`, `poster`, `defaults`, `addedAt`, `folder`,
/// `deletedAt` ("Set when `media delete` trashed the file; the entry stays,
/// so references show missing", Spec 8 §6); for audio sets, `tracks` ("the
/// member ids in play order") and `crossfadeMs`. `deletedAt`, like `tracks`,
/// is written only when it is set, so the indexes written before Spec 8 read
/// and write back unchanged.
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
    public var deletedAt: String?
    public var tracks: [String]?
    public var crossfadeMs: Int?
    public var extra: [String: JSONValue]

    public init(id: String, path: String, kind: MediaKind, size: Int, modified: String? = nil, durationMs: Int? = nil,
                fps: FrameRate? = nil, width: Int? = nil, height: Int? = nil, hasAudio: Bool = false, hasAlpha: Bool = false,
                codec: String? = nil, poster: String? = nil, defaults: MediaDefaults = MediaDefaults(), addedAt: String? = nil,
                folder: String? = nil, deletedAt: String? = nil, tracks: [String]? = nil, crossfadeMs: Int? = nil,
                extra: [String: JSONValue] = [:]) {
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
        self.deletedAt = deletedAt
        self.tracks = tracks
        self.crossfadeMs = crossfadeMs
        self.extra = extra
    }

    /// The folder part of a relative path, for the folder rail.
    public static func folder(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Spec 8 §6 — "the entry stays, with `deletedAt` set and its `path` empty".
    public var isDeleted: Bool { deletedAt != nil }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, path, kind, size, modified, durationMs, fps, width, height, hasAudio, hasAlpha, codec, poster, defaults
        case addedAt, folder, deletedAt, tracks, crossfadeMs
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
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
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
        // Spec 8 §6 — only once `media delete` trashed the file.
        try c.encodeIfPresent(deletedAt, forKey: .deletedAt)
        // Spec 1 §7 — audio sets only.
        try c.encodeIfPresent(tracks, forKey: .tracks)
        try c.encodeIfPresent(crossfadeMs, forKey: .crossfadeMs)
    }
}

/// Entries are kept in id order (Spec 1 §7, "`entries` (in id order)"), so a
/// lookup is a binary search: lookahead resolves media on every build.
enum MediaEntries {
    /// The position of `id`, or of the first entry after it.
    static func lowerBound(_ id: String, in entries: [MediaEntry]) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].id < id { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func position(of id: String, in entries: [MediaEntry]) -> Int? {
        let at = lowerBound(id, in: entries)
        return at < entries.count && entries[at].id == id ? at : nil
    }

    static func isSorted(_ entries: [MediaEntry]) -> Bool {
        zip(entries, entries.dropFirst()).allSatisfy { $0.id <= $1.id }
    }

    static func sorted(_ entries: [MediaEntry]) -> [MediaEntry] {
        isSorted(entries) ? entries : entries.sorted { $0.id < $1.id }
    }
}

/// Spec 1 §7 — the library index (`library/media-index.json`), "synced with
/// the library, written only by machines in writable library mode", holding
/// `entries` (in id order) and "the `replaced` map that `media replace` and
/// the walk record (Spec 8 §4 and §6)".
public struct MediaIndex: Codable, Equatable, Sendable {
    public var entries: [MediaEntry] {
        didSet { if !MediaEntries.isSorted(entries) { entries.sort { $0.id < $1.id } } }
    }
    public var replaced: [String: String]
    public var extra: [String: JSONValue]

    public init(entries: [MediaEntry] = [], replaced: [String: String] = [:], extra: [String: JSONValue] = [:]) {
        self.entries = MediaEntries.sorted(entries)
        self.replaced = replaced
        self.extra = extra
    }

    /// Spec 1 §7 — the entry for `id` in this index, if it holds one.
    public func entry(_ id: String) -> MediaEntry? {
        MediaEntries.position(of: id, in: entries).map { entries[$0] }
    }

    /// The position of `id`'s entry, for an edit that changes it in place.
    public func position(of id: String) -> Int? {
        MediaEntries.position(of: id, in: entries)
    }

    /// Spec 1 §4 — "Identical files anywhere under the root resolve to one
    /// identity." Adds the entry unless its id is already indexed; returns
    /// whether it was new.
    @discardableResult
    public mutating func add(_ entry: MediaEntry) -> Bool {
        let at = MediaEntries.lowerBound(entry.id, in: entries)
        guard at == entries.count || entries[at].id != entry.id else { return false }
        entries.insert(entry, at: at)
        return true
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case entries, replaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = MediaEntries.sorted(try c.value(.entries, default: [MediaEntry]()))
        replaced = try c.value(.replaced, default: [:])
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(MediaEntries.sorted(entries), forKey: .entries)
        try c.encode(replaced, forKey: .replaced)
    }
}

/// Spec 1 §7 — the machine index (`machine/media-local.json`) "for media that
/// exists only on this machine plus any path overrides (that media lives in
/// the machine's own folder, `machine/media/`, Spec 8 §2)": `entries`,
/// `overrides` ("id to a path relative to `machine/media/`, or absolute") and
/// "its own `replaced` map". The map is written only while it holds a
/// mapping, so machine indexes written before Spec 8 read and write back
/// unchanged.
public struct MediaLocalIndex: Codable, Equatable, Sendable {
    public var entries: [MediaEntry] {
        didSet { if !MediaEntries.isSorted(entries) { entries.sort { $0.id < $1.id } } }
    }
    public var overrides: [String: String]
    public var replaced: [String: String]
    public var extra: [String: JSONValue]

    public init(entries: [MediaEntry] = [], overrides: [String: String] = [:], replaced: [String: String] = [:],
                extra: [String: JSONValue] = [:]) {
        self.entries = MediaEntries.sorted(entries)
        self.overrides = overrides
        self.replaced = replaced
        self.extra = extra
    }

    /// Spec 1 §7 — the entry for `id` in this index, if it holds one.
    public func entry(_ id: String) -> MediaEntry? {
        MediaEntries.position(of: id, in: entries).map { entries[$0] }
    }

    /// The position of `id`'s entry, for an edit that changes it in place.
    public func position(of id: String) -> Int? {
        MediaEntries.position(of: id, in: entries)
    }

    /// Spec 1 §4 — one entry per identity; returns whether it was new.
    @discardableResult
    public mutating func add(_ entry: MediaEntry) -> Bool {
        let at = MediaEntries.lowerBound(entry.id, in: entries)
        guard at == entries.count || entries[at].id != entry.id else { return false }
        entries.insert(entry, at: at)
        return true
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case entries, overrides, replaced }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = MediaEntries.sorted(try c.value(.entries, default: [MediaEntry]()))
        overrides = try c.value(.overrides, default: [:])
        replaced = try c.value(.replaced, default: [:])
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(MediaEntries.sorted(entries), forKey: .entries)
        try c.encode(overrides, forKey: .overrides)
        if !replaced.isEmpty { try c.encode(replaced, forKey: .replaced) }
    }
}
