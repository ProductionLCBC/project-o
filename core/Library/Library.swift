// OCore — Spec 1 §2, the portable objects the projection reads.
//
// Only the fields Spec 3 reads are here; Spec 1's area adds the rest.

import Foundation

/// Spec 1 §2 — Channel `defaults.transition`, `defaults.audioTransition`,
/// `defaults.gain`: "What tracked attributes reset to."
public struct ChannelDefaults: Codable, Equatable, Sendable {
    public var transition: Int
    public var audioTransition: Int
    public var gain: Double
    public init(transition: Int = 1, audioTransition: Int = 1, gain: Double = 0) {
        self.transition = transition
        self.audioTransition = audioTransition
        self.gain = gain
    }
}

/// Spec 1 §2 — Channel: `number`, `label`, `defaults`, `decoderCap` (2 or 3,
/// default 2).
public struct Channel: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var defaults: ChannelDefaults
    public var decoderCap: Int?
    public init(number: Int, label: String = "", defaults: ChannelDefaults = ChannelDefaults(), decoderCap: Int? = nil) {
        self.number = number
        self.label = label
        self.defaults = defaults
        self.decoderCap = decoderCap
    }
}

/// Spec 1 §2 — Transition `type` (`cut`, `dissolve`, `fadeThroughColor`).
public enum TransitionType: String, Codable, Equatable, Sendable {
    case cut, dissolve, fadeThroughColor
}

/// Spec 1 §2 — Transition: `number`, `type`, `ms`. A cut has 0 ms.
public struct Transition: Codable, Equatable, Sendable {
    public var number: Int
    public var type: TransitionType
    public var ms: Int
    public init(number: Int, type: TransitionType, ms: Int) {
        self.number = number
        self.type = type
        self.ms = ms
    }
}

/// Spec 1 §2 — Audio Transition `type` (`cut`, `crossfade`, `fadeThroughSilence`).
public enum AudioTransitionType: String, Codable, Equatable, Sendable {
    case cut, crossfade, fadeThroughSilence
}

/// Spec 1 §2 — Audio Transition: `number`, `type`, `ms`, `offsetMs`.
public struct AudioTransition: Codable, Equatable, Sendable {
    public var number: Int
    public var type: AudioTransitionType
    public var ms: Int
    public var offsetMs: Int
    public init(number: Int, type: AudioTransitionType, ms: Int, offsetMs: Int = 0) {
        self.number = number
        self.type = type
        self.ms = ms
        self.offsetMs = offsetMs
    }
}

/// Spec 1 §2 — Cue `trigger`: `{type: "go"}`, `{type: "time", ms}`, or
/// `{type: "timecode", tc}`.
public enum CueTrigger: Codable, Equatable, Sendable {
    case go
    case time(ms: Int)
    case timecode(String)

    private enum CodingKeys: String, CodingKey { case type, ms, tc }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "go": self = .go
        case "time": self = .time(ms: try c.decode(Int.self, forKey: .ms))
        case "timecode": self = .timecode(try c.decode(String.self, forKey: .tc))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown trigger \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
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

/// Spec 1 §2 — Cue: `uuid`, `label`, `section`, `trigger`, `advanceAfterMs`,
/// `commands`. "Cue numbers are positions, not stored" (Spec 1 §4).
public struct Cue: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var label: String
    public var section: String?
    public var trigger: CueTrigger
    public var advanceAfterMs: Int?
    public var commands: [Command]
    public init(uuid: UUID, label: String = "", section: String? = nil, trigger: CueTrigger = .go,
                advanceAfterMs: Int? = nil, commands: [Command] = []) {
        self.uuid = uuid
        self.label = label
        self.section = section
        self.trigger = trigger
        self.advanceAfterMs = advanceAfterMs
        self.commands = commands
    }
}

/// Spec 1 §2 — List (a master): `number`, `uuid`, `title`, `trackThrough`,
/// `cues`. A local copy has the same shape (Spec 1 §2).
public struct List: Codable, Equatable, Sendable {
    public var uuid: UUID
    public var number: Int
    public var title: String
    public var trackThrough: Bool
    public var cues: [Cue]
    public init(uuid: UUID, number: Int, title: String = "", trackThrough: Bool = false, cues: [Cue]) {
        self.uuid = uuid
        self.number = number
        self.title = title
        self.trackThrough = trackThrough
        self.cues = cues
    }
}

/// Spec 1 §2 — Macro: `number`, `commands` (each with an optional guard).
public struct Macro: Codable, Equatable, Sendable {
    public var number: Int
    public var commands: [GuardedCommand]
    public init(number: Int, commands: [GuardedCommand]) {
        self.number = number
        self.commands = commands
    }
}

/// Spec 3 §6 — the context's `library` "(channels, presets, transitions,
/// grades, lists; read only)". Presets and grades are referenced by number
/// only, so they are not needed here.
public struct Library: Codable, Equatable, Sendable {
    public var channels: [Channel]
    public var transitions: [Transition]
    public var audioTransitions: [AudioTransition]
    public var lists: [List]
    public var macros: [Macro]

    public init(channels: [Channel] = [], transitions: [Transition] = [], audioTransitions: [AudioTransition] = [],
                lists: [List] = [], macros: [Macro] = []) {
        self.channels = channels
        self.transitions = transitions
        self.audioTransitions = audioTransitions
        self.lists = lists
        self.macros = macros
    }

    public func channel(_ number: Int) -> Channel? { channels.first { $0.number == number } }
    public func transition(_ number: Int) -> Transition? { transitions.first { $0.number == number } }
    public func audioTransition(_ number: Int) -> AudioTransition? { audioTransitions.first { $0.number == number } }
    public func list(number: Int) -> List? { lists.first { $0.number == number } }
    public func list(uuid: UUID) -> List? { lists.first { $0.uuid == uuid } }
    public func macro(_ number: Int) -> Macro? { macros.first { $0.number == number } }
}
