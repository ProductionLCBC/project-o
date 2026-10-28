// OCore — Spec 1 §2, Transition and Audio Transition.

import Foundation

/// Spec 1 §2 — Transition `type` (`cut`, `dissolve`, `fadeThroughColor`).
/// "Each type declares `appliesTo` (`pixels`, `text`, or both)... in v1, cut
/// and dissolve apply to both, fadeThroughColor to pixels only."
public enum TransitionType: String, Codable, Equatable, Sendable {
    case cut, dissolve, fadeThroughColor

    public var appliesToPixels: Bool { true }

    public var appliesToText: Bool {
        switch self {
        case .cut, .dissolve: return true
        case .fadeThroughColor: return false
        }
    }
}

/// Spec 1 §2 — Transition: `number`, `label`, `uuid`, `type`, `ms`, `easing`,
/// `color` ("RGBA, fade-through only"), `builtIn` ("Transitions 1–3 ship
/// built in and are editable, not deletable"). A cut has 0 ms.
public struct Transition: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var type: TransitionType
    public var ms: Int
    public var easing: Easing
    public var color: Color?
    public var builtIn: Bool
    public var extra: [String: JSONValue]

    public init(number: Int, type: TransitionType, ms: Int, label: String = "", uuid: UUID = UUID(),
                easing: Easing = .linear, color: Color? = nil, builtIn: Bool = false, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.type = type
        self.ms = ms
        self.easing = easing
        self.color = color
        self.builtIn = builtIn
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, type, ms, easing, color, builtIn }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        type = try c.decode(TransitionType.self, forKey: .type)
        ms = try c.value(.ms, default: 0)
        easing = try c.value(.easing, default: .linear)
        color = try c.decodeIfPresent(Color.self, forKey: .color)
        builtIn = try c.value(.builtIn, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(type, forKey: .type)
        try c.encode(ms, forKey: .ms)
        try c.encode(easing, forKey: .easing)
        try c.encodeNullable(color, forKey: .color)
        try c.encode(builtIn, forKey: .builtIn)
    }
}

/// Spec 1 §2 — Audio Transition `type` (`cut`, `crossfade`, `fadeThroughSilence`).
public enum AudioTransitionType: String, Codable, Equatable, Sendable {
    case cut, crossfade, fadeThroughSilence
}

/// Spec 1 §2 — Audio Transition: `number`, `label`, `uuid`, `type`, `ms`,
/// `easing`, `offsetMs` ("signed; measured from the trigger").
public struct AudioTransition: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var type: AudioTransitionType
    public var ms: Int
    public var easing: Easing
    public var offsetMs: Int
    public var extra: [String: JSONValue]

    public init(number: Int, type: AudioTransitionType, ms: Int, offsetMs: Int = 0, label: String = "",
                uuid: UUID = UUID(), easing: Easing = .linear, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.type = type
        self.ms = ms
        self.easing = easing
        self.offsetMs = offsetMs
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, type, ms, easing, offsetMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        type = try c.decode(AudioTransitionType.self, forKey: .type)
        ms = try c.value(.ms, default: 0)
        easing = try c.value(.easing, default: .linear)
        offsetMs = try c.value(.offsetMs, default: 0)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(type, forKey: .type)
        try c.encode(ms, forKey: .ms)
        try c.encode(easing, forKey: .easing)
        try c.encode(offsetMs, forKey: .offsetMs)
    }
}
