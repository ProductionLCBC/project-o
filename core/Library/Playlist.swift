// OCore — Spec 1 §3, Playlist.

import Foundation

/// Spec 1 §3 — a Playlist item: "`{kind: \"header\", label}`, `{kind:
/// \"linked\", list: list number}`, or `{kind: \"local\", localUuid}` pointing
/// at a local copy in the machine root."
public struct PlaylistItem: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case header(label: String)
        case linked(list: Int)
        case local(UUID)
    }

    public var kind: Kind
    public var extra: [String: JSONValue]

    public init(kind: Kind, extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.extra = extra
    }

    public static func header(label: String) -> PlaylistItem { PlaylistItem(kind: .header(label: label)) }
    public static func linked(list: Int) -> PlaylistItem { PlaylistItem(kind: .linked(list: list)) }
    public static func local(_ uuid: UUID) -> PlaylistItem { PlaylistItem(kind: .local(uuid)) }

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, label, list, localUuid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "header": kind = .header(label: try c.value(.label, default: ""))
        case "linked": kind = .linked(list: try c.decode(Int.self, forKey: .list))
        case "local": kind = .local(try c.uuid(.localUuid))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown item kind \(other)")
        }
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .header(let label):
            try c.encode("header", forKey: .kind)
            try c.encode(label, forKey: .label)
        case .linked(let list):
            try c.encode("linked", forKey: .kind)
            try c.encode(list, forKey: .list)
        case .local(let uuid):
            try c.encode("local", forKey: .kind)
            try c.encode(uuid: uuid, forKey: .localUuid)
        }
    }
}

/// Spec 1 §3 — Playlist: `uuid`, `title`, `serviceDate` ("ISO date or null"),
/// `archived`, `items`. "Playlists carry no cues of their own. The playlist's
/// name is its title; the pair of title and date must be unique on a machine
/// (case-insensitive)."
public struct Playlist: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var title: String
    public var serviceDate: String?
    public var archived: Bool
    public var items: [PlaylistItem]
    public var extra: [String: JSONValue]

    public init(uuid: UUID, title: String, serviceDate: String? = nil, items: [PlaylistItem], archived: Bool = false,
                extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.title = title
        self.serviceDate = serviceDate
        self.archived = archived
        self.items = items
        self.extra = extra
    }

    /// Spec 1 §3 — the name a machine must keep unique: title and date, case-insensitive.
    public var nameKey: String {
        title.lowercased() + "\u{0}" + (serviceDate ?? "")
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case uuid, title, serviceDate, archived, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        title = try c.value(.title, default: "")
        serviceDate = try c.decodeIfPresent(String.self, forKey: .serviceDate)
        archived = try c.value(.archived, default: false)
        items = try c.value(.items, default: [])
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(title, forKey: .title)
        try c.encodeNullable(serviceDate, forKey: .serviceDate)
        try c.encode(archived, forKey: .archived)
        try c.encode(items, forKey: .items)
    }
}
