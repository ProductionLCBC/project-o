// OCore — Spec 3 §2, ChannelState.

import Foundation

/// Spec 3 §4 — a transition attribute value: the Transition object's number
/// and an optional duration override (`channel N transition R [DURATION]`).
public struct TransitionSetting: Codable, Equatable, Sendable {
    public var ref: Int
    public var ms: Int?
    public init(ref: Int, ms: Int? = nil) {
        self.ref = ref
        self.ms = ms
    }
}

/// Spec 3 §2 — the tracked attribute group: "`grade`, `transition`,
/// `audioTransition`, `gain`, `chase` (reserved)". Each holds until written
/// again or until a list boundary resets it to the channel default.
///
/// Reading of the spec: `build` is kept on the slide instance (§3 rule 8,
/// "Build is an attribute of slide content") rather than here. A grade of 0
/// means none (Spec 2 §3, "`grade 0` means none").
public struct ChannelAttributes: Codable, Equatable, Sendable {
    public var grade: Tracked<Int>
    public var transition: Tracked<TransitionSetting>
    public var audioTransition: Tracked<TransitionSetting>
    public var gain: Tracked<Double>
    public var chase: Tracked<Bool>

    public init(grade: Tracked<Int>, transition: Tracked<TransitionSetting>,
                audioTransition: Tracked<TransitionSetting>, gain: Tracked<Double>, chase: Tracked<Bool>) {
        self.grade = grade
        self.transition = transition
        self.audioTransition = audioTransition
        self.gain = gain
        self.chase = chase
    }

    /// Spec 3 §2 — "Defaults come from the Channel object: `defaults.transition`,
    /// `defaults.audioTransition`, `defaults.gain`; the default grade is none;
    /// `chase` defaults to off."
    public static func defaults(for defaults: ChannelDefaults) -> ChannelAttributes {
        ChannelAttributes(
            grade: .defaulted(0),
            transition: .defaulted(TransitionSetting(ref: defaults.transition)),
            audioTransition: .defaulted(TransitionSetting(ref: defaults.audioTransition)),
            gain: .defaulted(defaults.gain),
            chase: .defaulted(false))
    }
}

/// Spec 3 §2 — `provenance`: "the cue uuid that wrote it and the uuid of the
/// list it was fired from, also for a write by a macro the cue ran; or
/// `restored`, keeping the cue and list it had; or the source kind, such as
/// `ui`". Spec 3's `ui` is `.source(.ui)`.
///
/// The list is optional so a state written before Spec 6 (a cue with no list)
/// still reads; Spec 6 §5's "the list" then falls back to the pointer's.
public enum Provenance: Codable, Equatable, Sendable {
    case cue(UUID, list: UUID?)
    case restored(cue: UUID?, list: UUID?)
    case source(SourceKind)

    /// Spec 3 §2 — the cue that wrote the content, if a cue did (kept through
    /// a restore).
    public var cue: UUID? {
        switch self {
        case .cue(let cue, _): return cue
        case .restored(let cue, _): return cue
        case .source: return nil
        }
    }

    /// Spec 3 §2 — "the uuid of the list it was fired from" (kept through a
    /// restore).
    public var list: UUID? {
        switch self {
        case .cue(_, let list): return list
        case .restored(_, let list): return list
        case .source: return nil
        }
    }

    /// Spec 3 §8 — "marks every restored channel's `provenance` as
    /// `restored`, keeping the cue and list it had". Content no cue wrote is
    /// restored with neither.
    public static func restored(from previous: Provenance?) -> Provenance {
        .restored(cue: previous?.cue, list: previous?.list)
    }

    private enum CodingKeys: String, CodingKey { case kind, cue, list, source }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "cue": self = .cue(try c.decode(UUID.self, forKey: .cue), list: try c.decodeIfPresent(UUID.self, forKey: .list))
        case "restored":
            self = .restored(cue: try c.decodeIfPresent(UUID.self, forKey: .cue), list: try c.decodeIfPresent(UUID.self, forKey: .list))
        case "source": self = .source(try c.decode(SourceKind.self, forKey: .source))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown provenance \(kind)")
        }
    }

    /// Spec 1 §9 — UUIDs are written lowercase; the cue and list are written
    /// only when known, so `{"kind": "restored"}` and an older
    /// `{"cue": …, "kind": "cue"}` keep their shape.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cue(let cue, let list):
            try c.encode("cue", forKey: .kind)
            try c.encode(cue.uuidString.lowercased(), forKey: .cue)
            if let list { try c.encode(list.uuidString.lowercased(), forKey: .list) }
        case .restored(let cue, let list):
            try c.encode("restored", forKey: .kind)
            if let cue { try c.encode(cue.uuidString.lowercased(), forKey: .cue) }
            if let list { try c.encode(list.uuidString.lowercased(), forKey: .list) }
        case .source(let s):
            try c.encode("source", forKey: .kind)
            try c.encode(s, forKey: .source)
        }
    }
}

/// Spec 3 §2 — "outgoing (the previous instance and the frame its transition
/// ends, kept for the decoder budget) lives here too."
public struct OutgoingInstance: Codable, Equatable, Sendable {
    public var instance: MediaInstance
    public var endsAtFrame: Int
    public init(instance: MediaInstance, endsAtFrame: Int) {
        self.instance = instance
        self.endsAtFrame = endsAtFrame
    }
}

/// Spec 3 §2 and §10 — `ChannelState`: the content group, the tracked
/// attribute group and the operator state (`lock`), with their three
/// lifetimes.
public struct ChannelState: Codable, Equatable, Sendable {
    public var content: ContentInstance
    public var provenance: Provenance?
    public var outgoing: [OutgoingInstance]
    public var attributes: ChannelAttributes
    /// Spec 3 §3 rule 9 — "Lock is not tracked."
    public var lock: Bool

    public init(content: ContentInstance = .empty, provenance: Provenance? = nil,
                outgoing: [OutgoingInstance] = [], attributes: ChannelAttributes, lock: Bool = false) {
        self.content = content
        self.provenance = provenance
        self.outgoing = outgoing
        self.attributes = attributes
        self.lock = lock
    }

    /// Spec 3 §2 — "A fresh ShowState has every channel `empty` with every
    /// attribute at `{default value, origin: default}`."
    public static func fresh(for channel: Channel) -> ChannelState {
        ChannelState(attributes: .defaults(for: channel.defaults))
    }
}
