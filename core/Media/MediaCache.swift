// OCore — Spec 8 §4, the machine's hash cache (`machine/media-cache.json`).

import Foundation

/// Spec 8 §4 — one record of the cache: "its folder (the media root or
/// `machine/media/`), path, size, modification date and hash". `modified` is
/// the file's modification date as the engine reads it, written at the
/// precision the file system gives (ISO 8601, Spec 1 §5); the cache compares
/// it as written. `hash` is the file's identity: its `sha256:` id, or a
/// slide's or template's `slide:` id (Spec 8 §2).
public struct MediaCacheRecord: Codable, Equatable, Sendable {
    public var location: MediaLocation
    public var size: Int
    public var modified: String
    public var hash: String
    public var extra: [String: JSONValue]

    public init(location: MediaLocation, size: Int, modified: String, hash: String, extra: [String: JSONValue] = [:]) {
        self.location = location
        self.size = size
        self.modified = modified
        self.hash = hash
        self.extra = extra
    }

    /// Spec 8 §4 — "A file whose size and date match its record isn't hashed again".
    public func matches(size: Int, modified: String) -> Bool {
        self.size == size && self.modified == modified
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case folder, path, size, modified, hash }

    public init(from decoder: Decoder) throws {
        location = try MediaLocation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decode(Int.self, forKey: .size)
        modified = try c.decode(String.self, forKey: .modified)
        hash = try c.decode(String.self, forKey: .hash)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        try location.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(size, forKey: .size)
        try c.encode(modified, forKey: .modified)
        try c.encode(hash, forKey: .hash)
    }
}

/// Spec 8 §4 — "The cache. `machine/media-cache.json` holds a record for
/// every file the engine has hashed ... It starts with the header every
/// document has (Spec 1 §5), with kind `mediaCache`, and the loader leaves it
/// alone." It is also "what it found last time", which the walk compares
/// with: a record per file the last walk found, by location, so "the same
/// path in both folders keeps two records" (Spec 8 §11). Records are kept in
/// location order.
public struct MediaCache: Codable, Equatable, Sendable {
    public private(set) var records: [MediaCacheRecord]
    public var extra: [String: JSONValue]

    public init(records: [MediaCacheRecord] = [], extra: [String: JSONValue] = [:]) {
        var byLocation: [MediaLocation: MediaCacheRecord] = [:]
        for record in records { byLocation[record.location] = record }
        self.records = byLocation.values.sorted { $0.location < $1.location }
        self.extra = extra
    }

    /// The record for a location, if the cache holds one.
    public func record(at location: MediaLocation) -> MediaCacheRecord? {
        var low = 0
        var high = records.count
        while low < high {
            let mid = (low + high) / 2
            if records[mid].location < location { low = mid + 1 } else { high = mid }
        }
        return low < records.count && records[low].location == location ? records[low] : nil
    }

    /// Spec 8 §4 — "what it found last time": each location's identity.
    public var lastSeen: [MediaLocation: String] {
        Dictionary(records.map { ($0.location, $0.hash) }, uniquingKeysWith: { first, _ in first })
    }

    /// The hash the cache knows for a file of this size and date at a
    /// location, if its record matches them.
    public func hash(at location: MediaLocation, size: Int, modified: String) -> String? {
        guard let record = record(at: location), record.matches(size: size, modified: modified) else { return nil }
        return record.hash
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case records }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(records: try c.decodeIfPresent([MediaCacheRecord].self, forKey: .records) ?? [],
                  extra: try decoder.unknownKeys(besides: CodingKeys.known))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(records, forKey: .records)
    }
}
