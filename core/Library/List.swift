// OCore — Spec 1 §2, List and Cue.

import Foundation

/// Spec 1 §2 — Cue `trigger`: `{type: "go"}`, `{type: "time", ms}`, or
/// `{type: "timecode", tc}`.
public struct CueTrigger: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case go
        case time(ms: Int)
        case timecode(String)
    }

    public var kind: Kind
    public var extra: [String: JSONValue]

    public init(kind: Kind, extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.extra = extra
    }

    public static let go = CueTrigger(kind: .go)
    public static func time(ms: Int) -> CueTrigger { CueTrigger(kind: .time(ms: ms)) }
    public static func timecode(_ tc: String) -> CueTrigger { CueTrigger(kind: .timecode(tc)) }

    private enum CodingKeys: String, CodingKey, CaseIterable { case type, ms, tc }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "go": kind = .go
        case "time": kind = .time(ms: try c.decode(Int.self, forKey: .ms))
        case "timecode": kind = .timecode(try c.decode(String.self, forKey: .tc))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown trigger \(other)")
        }
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .go: try c.encode("go", forKey: .type)
        case .time(let ms):
            try c.encode("time", forKey: .type)
            try c.encode(ms, forKey: .ms)
        case .timecode(let tc):
            try c.encode("timecode", forKey: .type)
            try c.encode(tc, forKey: .tc)
        }
    }
}

/// Spec 1 §2 — Cue (child of List): `uuid`, `label`, `section`, `note`,
/// `trigger`, `advanceAfterMs`, `commands`. "Cue numbers are positions, not
/// stored; see section 4." Each command may carry a `when` guard, "reserved
/// on cues" (Spec 1 §6), kept and flagged but never run.
public struct Cue: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var label: String
    public var section: String?
    public var note: String
    public var trigger: CueTrigger
    public var advanceAfterMs: Int?
    public var commands: [GuardedCommand]
    public var extra: [String: JSONValue]

    public init(uuid: UUID, label: String = "", section: String? = nil, note: String = "", trigger: CueTrigger = .go,
                advanceAfterMs: Int? = nil, commands: [GuardedCommand] = [], extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.label = label
        self.section = section
        self.note = note
        self.trigger = trigger
        self.advanceAfterMs = advanceAfterMs
        self.commands = commands
        self.extra = extra
    }

    /// A cue from plain commands, none guarded.
    public init(uuid: UUID, label: String = "", section: String? = nil, note: String = "", trigger: CueTrigger = .go,
                advanceAfterMs: Int? = nil, commands: [Command]) {
        self.init(uuid: uuid, label: label, section: section, note: note, trigger: trigger, advanceAfterMs: advanceAfterMs,
                  commands: commands.map { GuardedCommand($0) })
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case uuid, label, section, note, trigger, advanceAfterMs, commands }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        label = try c.value(.label, default: "")
        section = try c.decodeIfPresent(String.self, forKey: .section)
        note = try c.value(.note, default: "")
        trigger = try c.value(.trigger, default: .go)
        advanceAfterMs = try c.decodeIfPresent(Int.self, forKey: .advanceAfterMs)
        commands = try GuardedCommand.decodeList(from: c, forKey: .commands)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(label, forKey: .label)
        try c.encodeNullable(section, forKey: .section)
        try c.encode(note, forKey: .note)
        try c.encode(trigger, forKey: .trigger)
        try c.encodeNullable(advanceAfterMs, forKey: .advanceAfterMs)
        try c.encode(commands, forKey: .commands)
    }
}

/// Spec 1 §2 — "A local copy is the same document with `provenance`
/// `{masterUuid, masterVersion, detachedAt}` and lives in the machine root."
public struct LocalProvenance: Codable, Equatable, Sendable {
    public var masterUuid: UUID
    public var masterVersion: Int
    public var detachedAt: String
    public var extra: [String: JSONValue]

    public init(masterUuid: UUID, masterVersion: Int, detachedAt: String, extra: [String: JSONValue] = [:]) {
        self.masterUuid = masterUuid
        self.masterVersion = masterVersion
        self.detachedAt = detachedAt
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case masterUuid, masterVersion, detachedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterUuid = try c.uuid(.masterUuid)
        masterVersion = try c.decode(Int.self, forKey: .masterVersion)
        detachedAt = try c.value(.detachedAt, default: "")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: masterUuid, forKey: .masterUuid)
        try c.encode(masterVersion, forKey: .masterVersion)
        try c.encode(detachedAt, forKey: .detachedAt)
    }
}

/// Spec 1 §2 — List (a master): `number`, `uuid`, `title`, `author`,
/// `copyright`, `ccli`, `trackThrough`, `version` ("incremented on every
/// save"), `cues`, `timeline` (reserved, kept as read). A local copy is the
/// same document with `provenance`.
public struct List: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var number: Int
    public var title: String
    public var author: String
    public var copyright: String
    public var ccli: String
    public var trackThrough: Bool
    public var version: Int
    public var cues: [Cue]
    public var timeline: JSONValue
    public var provenance: LocalProvenance?
    public var extra: [String: JSONValue]

    public init(uuid: UUID, number: Int, title: String = "", trackThrough: Bool = false, cues: [Cue],
                author: String = "", copyright: String = "", ccli: String = "", version: Int = 1,
                timeline: JSONValue = .null, provenance: LocalProvenance? = nil, extra: [String: JSONValue] = [:]) {
        self.uuid = uuid
        self.number = number
        self.title = title
        self.author = author
        self.copyright = copyright
        self.ccli = ccli
        self.trackThrough = trackThrough
        self.version = version
        self.cues = cues
        self.timeline = timeline
        self.provenance = provenance
        self.extra = extra
    }

    /// True for a local copy (Spec 1 §2).
    public var isLocalCopy: Bool { provenance != nil }

    // MARK: - Spec 1 §4, cue addressing

    /// Spec 1 §4 — "A cue's number is its 1-based position in its list."
    public func cue(at position: Int) -> Cue? {
        guard position >= 1, position <= cues.count else { return nil }
        return cues[position - 1]
    }

    /// The 1-based position of a cue by its stable `uuid`.
    public func position(of uuid: UUID) -> Int? {
        cues.firstIndex { $0.uuid == uuid }.map { $0 + 1 }
    }

    /// Spec 1 §4 — positions are "recomputed whenever cues are inserted,
    /// removed or reordered". Inserting past the end appends.
    public mutating func insert(_ cue: Cue, at position: Int) {
        let index = min(max(position - 1, 0), cues.count)
        cues.insert(cue, at: index)
    }

    @discardableResult
    public mutating func removeCue(at position: Int) -> Cue? {
        guard position >= 1, position <= cues.count else { return nil }
        return cues.remove(at: position - 1)
    }

    /// Moves the cue at one position to another; out-of-range positions do nothing.
    public mutating func moveCue(from: Int, to: Int) {
        guard from >= 1, from <= cues.count, to >= 1, to <= cues.count, from != to else { return }
        let cue = cues.remove(at: from - 1)
        cues.insert(cue, at: to - 1)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case uuid, number, title, author, copyright, ccli, trackThrough, version, cues, timeline, provenance
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.uuid(.uuid)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.value(.title, default: "")
        author = try c.value(.author, default: "")
        copyright = try c.value(.copyright, default: "")
        ccli = try c.value(.ccli, default: "")
        trackThrough = try c.value(.trackThrough, default: false)
        version = try c.value(.version, default: 1)
        cues = try c.value(.cues, default: [])
        timeline = try c.value(.timeline, default: .null)
        provenance = try c.decodeIfPresent(LocalProvenance.self, forKey: .provenance)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(number, forKey: .number)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encode(copyright, forKey: .copyright)
        try c.encode(ccli, forKey: .ccli)
        try c.encode(trackThrough, forKey: .trackThrough)
        try c.encode(version, forKey: .version)
        try c.encode(cues, forKey: .cues)
        try c.encode(timeline, forKey: .timeline)
        // Spec 1 §2 — provenance belongs to local copies only; a master has no key for it.
        try c.encodeIfPresent(provenance, forKey: .provenance)
    }
}
