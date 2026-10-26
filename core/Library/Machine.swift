// OCore — Spec 1 §3, the machine-level objects the projection reads.
//
// Only the fields Spec 3 reads are here; Spec 1's area adds the rest.

import Foundation

/// Spec 1 §3 — a Stack slot: `{channel, preset, offset, opacity, mute}`.
public struct StackSlot: Codable, Equatable, Sendable {
    public var channel: Int
    public var offset: Int
    public var mute: Bool
    public init(channel: Int, offset: Int = 0, mute: Bool = false) {
        self.channel = channel
        self.offset = offset
        self.mute = mute
    }
}

/// Spec 1 §3 — Stack: `number`, `slots` (ordered, bottom to top).
public struct Stack: Codable, Equatable, Sendable {
    public var number: Int
    public var slots: [StackSlot]
    public init(number: Int, slots: [StackSlot] = []) {
        self.number = number
        self.slots = slots
    }
}

/// Spec 1 §3 — Output `transitions`: `{switch: transition number, blackout:
/// transition number}`.
public struct OutputTransitions: Codable, Equatable, Sendable {
    public var `switch`: Int
    public var blackout: Int
    public init(switch switchRef: Int, blackout: Int) {
        self.switch = switchRef
        self.blackout = blackout
    }
}

/// Spec 1 §3 — Output: `number`, `defaultStack` ("Loaded at launch"),
/// `transitions`.
public struct Output: Codable, Equatable, Sendable {
    public var number: Int
    public var defaultStack: Int
    public var transitions: OutputTransitions
    public init(number: Int, defaultStack: Int, transitions: OutputTransitions = OutputTransitions(switch: 1, blackout: 1)) {
        self.number = number
        self.defaultStack = defaultStack
        self.transitions = transitions
    }
}

/// Spec 1 §3 — a Playlist item: `{kind: "header", label}`, `{kind: "linked",
/// list}`, or `{kind: "local", localUuid}`.
public enum PlaylistItem: Codable, Equatable, Sendable {
    case header(label: String)
    case linked(list: Int)
    case local(UUID)

    private enum CodingKeys: String, CodingKey { case kind, label, list, localUuid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "header": self = .header(label: try c.decodeIfPresent(String.self, forKey: .label) ?? "")
        case "linked": self = .linked(list: try c.decode(Int.self, forKey: .list))
        case "local": self = .local(try c.decode(UUID.self, forKey: .localUuid))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown item kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .header(let label):
            try c.encode("header", forKey: .kind)
            try c.encode(label, forKey: .label)
        case .linked(let list):
            try c.encode("linked", forKey: .kind)
            try c.encode(list, forKey: .list)
        case .local(let uuid):
            try c.encode("local", forKey: .kind)
            try c.encode(uuid, forKey: .localUuid)
        }
    }
}

/// Spec 1 §3 — Playlist: `uuid`, `title`, `serviceDate`, `items`.
public struct Playlist: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var title: String
    public var serviceDate: String?
    public var items: [PlaylistItem]
    public init(uuid: UUID, title: String, serviceDate: String? = nil, items: [PlaylistItem]) {
        self.uuid = uuid
        self.title = title
        self.serviceDate = serviceDate
        self.items = items
    }
}

/// Spec 1 §3 — machine settings `tracking` (per-attribute booleans). Spec 3
/// §3 rule 7: "With tracking off, every write of that attribute behaves as
/// `once` regardless of its stored scope."
public struct TrackingSwitches: Codable, Equatable, Sendable {
    public var grade: Bool
    public var transition: Bool
    public var audioTransition: Bool
    public var gain: Bool
    public var chase: Bool
    public init(grade: Bool = true, transition: Bool = true, audioTransition: Bool = true, gain: Bool = true, chase: Bool = true) {
        self.grade = grade
        self.transition = transition
        self.audioTransition = audioTransition
        self.gain = gain
        self.chase = chase
    }
}

/// Spec 3 §6 — the context's `machine` "(stacks, outputs, tracking
/// switches)", plus the playlists and local list copies the pointer walks
/// (Spec 1 §3) and `decoderCapDefault`.
public struct Machine: Codable, Equatable, Sendable {
    public var stacks: [Stack]
    public var outputs: [Output]
    public var playlists: [Playlist]
    public var localLists: [List]
    public var tracking: TrackingSwitches
    public var decoderCapDefault: Int

    public init(stacks: [Stack] = [], outputs: [Output] = [], playlists: [Playlist] = [], localLists: [List] = [],
                tracking: TrackingSwitches = TrackingSwitches(), decoderCapDefault: Int = 2) {
        self.stacks = stacks
        self.outputs = outputs
        self.playlists = playlists
        self.localLists = localLists
        self.tracking = tracking
        self.decoderCapDefault = decoderCapDefault
    }

    public func stack(_ number: Int) -> Stack? { stacks.first { $0.number == number } }
    public func output(_ number: Int) -> Output? { outputs.first { $0.number == number } }
    public func playlist(uuid: UUID) -> Playlist? { playlists.first { $0.uuid == uuid } }
    public func localList(uuid: UUID) -> List? { localLists.first { $0.uuid == uuid } }
}
