// OCore — Spec 1 §3, Playlist; Spec 7 §3, its items and their uuids.

import Foundation

/// Spec 1 §3 — a Playlist item: "Every item has a `uuid`, unique within the
/// playlist, and is one of `{kind: \"header\", label}`, `{kind: \"linked\",
/// list: list number, listUuid}`, or `{kind: \"local\", localUuid}` pointing at
/// a local copy in the machine root (Spec 7 §3)."
public struct PlaylistItem: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case header(label: String)
        /// Spec 7 §3 — "A linked item finds its list by `listUuid` ... An item
        /// without a `listUuid`, from a hand-made file, finds its list by
        /// number and records that list's uuid at the next save."
        case linked(list: Int, listUuid: UUID?)
        case local(UUID)
    }

    public var uuid: UUID
    public var kind: Kind
    public var extra: [String: JSONValue]

    public init(uuid: UUID, kind: Kind, extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.kind = kind
        self.extra = extra
    }

    public static func header(label: String, uuid: UUID) -> PlaylistItem {
        PlaylistItem(uuid: uuid, kind: .header(label: label))
    }

    public static func linked(list: Int, listUuid: UUID? = nil, uuid: UUID) -> PlaylistItem {
        PlaylistItem(uuid: uuid, kind: .linked(list: list, listUuid: listUuid))
    }

    public static func local(_ localUuid: UUID, uuid: UUID) -> PlaylistItem {
        PlaylistItem(uuid: uuid, kind: .local(localUuid))
    }

    /// Spec 7 §3 — `KIND:KEY` of the name a derived uuid is made from: "KIND
    /// is `header`, `linked` or `local`; KEY is the label as written, the list
    /// number in decimal, or the local uuid in lowercase".
    public static func derivationKey(_ kind: Kind) -> String {
        switch kind {
        case .header(let label): return "header:" + label
        case .linked(let list, _): return "linked:" + String(list)
        case .local(let uuid): return "local:" + uuid.uuidString.lowercased()
        }
    }

    /// Spec 7 §3 — an item as a file or an insert writes it, its uuid perhaps
    /// missing: "An item without a uuid, from a hand-made file, gets one at
    /// load". A uuid that does not read as one counts as missing.
    public struct Draft: Codable, Equatable, Sendable {
        public var uuid: UUID?
        public var kind: Kind
        public var extra: [String: JSONValue]

        public init(uuid: UUID? = nil, kind: Kind, extra: [String: JSONValue] = [:]) {
            self.uuid = uuid
            self.kind = kind
            self.extra = extra
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uuid = (try? c.decodeIfPresent(String.self, forKey: .uuid)).flatMap { $0.flatMap(UUID.init(uuidString:)) }
            switch try c.decode(String.self, forKey: .kind) {
            case "header": kind = .header(label: try c.value(.label, default: ""))
            case "linked": kind = .linked(list: try c.decode(Int.self, forKey: .list), listUuid: try c.uuidIfPresent(.listUuid))
            case "local": kind = .local(try c.uuid(.localUuid))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown item kind \(other)")
            }
            extra = try decoder.unknownKeys(besides: CodingKeys.known)
        }

        public func encode(to encoder: Encoder) throws {
            try encoder.encode(unknownKeys: extra)
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let uuid { try c.encode(uuid: uuid, forKey: .uuid) }
            try PlaylistItem.encode(kind, into: &c)
        }
    }

    /// Spec 7 §3 — the items of a playlist with their uuids. An item keeps
    /// its own uuid unless an earlier item has it ("An item whose uuid repeats
    /// an earlier item's is treated as having none"); one without gets the
    /// UUIDv5 of `KIND:KEY:N` under the playlist's uuid, where "N counts the
    /// earlier items with the same kind and key, from 0, and counts on while
    /// the result is already in the playlist". `repeated` lists the 0-based
    /// places of the items whose uuid repeated, for the report.
    public static func assigningUuids(to drafts: [Draft], namespace: UUID) -> (items: [PlaylistItem], repeated: [Int]) {
        var used: Set<UUID> = []
        var own: [UUID?] = []
        var repeated: [Int] = []
        for (index, draft) in drafts.enumerated() {
            guard let uuid = draft.uuid else {
                own.append(nil)
                continue
            }
            if used.insert(uuid).inserted {
                own.append(uuid)
            } else {
                own.append(nil)
                repeated.append(index)
            }
        }
        var earlier: [String: Int] = [:]
        var items: [PlaylistItem] = []
        for (index, draft) in drafts.enumerated() {
            let key = derivationKey(draft.kind)
            let count = earlier[key, default: 0]
            earlier[key] = count + 1
            if let uuid = own[index] {
                items.append(PlaylistItem(uuid: uuid, kind: draft.kind, extra: draft.extra))
                continue
            }
            var n = count
            var candidate = UUID.v5(namespace: namespace, name: key + ":" + String(n))
            while used.contains(candidate) {
                n += 1
                candidate = UUID.v5(namespace: namespace, name: key + ":" + String(n))
            }
            used.insert(candidate)
            items.append(PlaylistItem(uuid: candidate, kind: draft.kind, extra: draft.extra))
        }
        return (items, repeated)
    }

    fileprivate enum CodingKeys: String, CodingKey, CaseIterable { case kind, label, list, listUuid, localUuid, uuid }

    public init(from decoder: Decoder) throws {
        let draft = try Draft(from: decoder)
        guard let uuid = draft.uuid else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "an item without a uuid"))
        }
        self.init(uuid: uuid, kind: draft.kind, extra: draft.extra)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try PlaylistItem.encode(kind, into: &c)
    }

    fileprivate static func encode(_ kind: Kind, into c: inout KeyedEncodingContainer<CodingKeys>) throws {
        switch kind {
        case .header(let label):
            try c.encode("header", forKey: .kind)
            try c.encode(label, forKey: .label)
        case .linked(let list, let listUuid):
            try c.encode("linked", forKey: .kind)
            try c.encode(list, forKey: .list)
            if let listUuid { try c.encode(uuid: listUuid, forKey: .listUuid) }
        case .local(let uuid):
            try c.encode("local", forKey: .kind)
            try c.encode(uuid: uuid, forKey: .localUuid)
        }
    }
}

/// Spec 1 §3 — Playlist: `uuid`, `title`, `serviceDate` ("ISO date or null; a
/// date is optional"), `serviceTime` ("`HH:MM` or null, in the machine's time
/// zone, read by `[Service In]`"), `archived`, `items`. "The playlist's name
/// is its title, unique on a machine ignoring case; its date is optional
/// metadata and never part of its name (Spec 7 §3)."
public struct Playlist: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var title: String
    public var serviceDate: String?
    public var serviceTime: String?
    public var archived: Bool
    public var items: [PlaylistItem]
    public var extra: [String: JSONValue]

    public init(uuid: UUID, title: String, serviceDate: String? = nil, serviceTime: String? = nil, items: [PlaylistItem],
                archived: Bool = false, extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.title = title
        self.serviceDate = serviceDate
        self.serviceTime = serviceTime
        self.archived = archived
        self.items = items
        self.extra = extra
    }

    /// Spec 1 §3 — the name a machine must keep unique: title and date, case-insensitive.
    public var nameKey: String {
        title.lowercased() + "\u{0}" + (serviceDate ?? "")
    }

    /// Spec 7 §3 — "A playlist's title is its identity on the machine:
    /// trimmed of spaces at either end, never empty, and unique without regard
    /// to case." The form two titles are compared in.
    public static func titleKey(_ title: String) -> String {
        trimmedTitle(title).lowercased()
    }

    /// Spec 7 §3 — a title "trimmed of spaces at either end".
    public static func trimmedTitle(_ title: String) -> String {
        var scalars = Substring(title).unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Spec 7 §3 — what a save writes for each linked item: the uuid of the
    /// list it finds ("records that list's uuid at the next save") and that
    /// list's number ("the number in the file is corrected at the playlist's
    /// next save"). An item whose list is missing stays as it is.
    public func recordingLinks(in library: Library) -> Playlist {
        var copy = self
        for index in copy.items.indices {
            guard case .linked = copy.items[index].kind, let list = library.list(for: copy.items[index].kind) else { continue }
            copy.items[index].kind = .linked(list: list.number, listUuid: list.uuid)
        }
        return copy
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case uuid, title, serviceDate, serviceTime, archived, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        title = try c.value(.title, default: "")
        serviceDate = try c.decodeIfPresent(String.self, forKey: .serviceDate)
        serviceTime = try c.decodeIfPresent(String.self, forKey: .serviceTime)
        archived = try c.value(.archived, default: false)
        items = PlaylistItem.assigningUuids(to: try c.value(.items, default: []), namespace: uuid).items
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(title, forKey: .title)
        try c.encodeNullable(serviceDate, forKey: .serviceDate)
        try c.encodeNullable(serviceTime, forKey: .serviceTime)
        try c.encode(archived, forKey: .archived)
        try c.encode(items, forKey: .items)
    }
}
