// OCore — Spec 1 §2, Channel.

import Foundation

/// Spec 1 §2 — Channel `defaults.transition`, `defaults.audioTransition`,
/// `defaults.gain`: "What tracked attributes reset to." Gain defaults to 0.
public struct ChannelDefaults: Codable, Equatable, Sendable {
    public var transition: Int
    public var audioTransition: Int
    public var gain: Double
    public var extra: [String: JSONValue]

    public init(transition: Int = 1, audioTransition: Int = 1, gain: Double = 0, extra: [String: JSONValue] = [:]) {
        self.transition = transition
        self.audioTransition = audioTransition
        self.gain = gain
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case transition, audioTransition, gain }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transition = try c.value(.transition, default: 1)
        audioTransition = try c.value(.audioTransition, default: 1)
        gain = try c.value(.gain, default: 0)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transition, forKey: .transition)
        try c.encode(audioTransition, forKey: .audioTransition)
        try c.encode(gain, forKey: .gain)
    }
}

/// Spec 1 §2 — Channel `renderSize`: "`\"largest\"` or `{width, height}`.
/// Default largest; the largest output size among stacks that include the
/// channel."
public enum RenderSize: Codable, Equatable, Sendable {
    case largest
    case size(width: Int, height: Int)

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let word = try? single.decode(String.self) {
            guard word == "largest" else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "renderSize must be \"largest\" or {width, height}")
            }
            self = .largest
            return
        }
        let size = try single.decode(Size.self)
        self = .size(width: size.width, height: size.height)
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .largest: try single.encode("largest")
        case .size(let width, let height): try single.encode(Size(width: width, height: height))
        }
    }
}

/// Spec 1 §2 — Channel `textThumbnail`: "enum: `body`, `firstLine`".
public enum TextThumbnail: String, Codable, Equatable, Sendable {
    case body, firstLine
}

/// Spec 1 §2 — Channel `usualContent`: "enum: `media`, `text`, `slide`,
/// `live`, `any`. Hint for the cue picker."
public enum UsualContent: String, Codable, Equatable, Sendable {
    case media, text, slide, live, any
}

/// Spec 1 §2 — Channel: `number`, `label`, `uuid`, `defaultPreset` ("Falls
/// back to Preset 1 if missing"), `defaults`, `decoderCap` ("2 or 3, Default
/// 2"), `audioOutputs` ("Machine-level numbers, met by number"), `renderSize`,
/// `textThumbnail`, `usualContent`.
///
/// Reading of the spec: `decoderCap` is nullable; null means the machine's
/// `decoderCapDefault` applies (Spec 1 §3), which is how a beefier machine
/// can raise the cap for a portable channel.
public struct Channel: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var defaultPreset: Int
    public var defaults: ChannelDefaults
    public var decoderCap: Int?
    public var audioOutputs: [Int]
    public var renderSize: RenderSize
    public var textThumbnail: TextThumbnail
    public var usualContent: UsualContent
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", defaults: ChannelDefaults = ChannelDefaults(), decoderCap: Int? = nil,
                uuid: UUID = UUID(), defaultPreset: Int = 1, audioOutputs: [Int] = [], renderSize: RenderSize = .largest,
                textThumbnail: TextThumbnail = .body, usualContent: UsualContent = .any, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.defaultPreset = defaultPreset
        self.defaults = defaults
        self.decoderCap = decoderCap
        self.audioOutputs = audioOutputs
        self.renderSize = renderSize
        self.textThumbnail = textThumbnail
        self.usualContent = usualContent
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case number, label, uuid, defaultPreset, defaults, decoderCap, audioOutputs, renderSize, textThumbnail, usualContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        defaultPreset = try c.value(.defaultPreset, default: 1)
        defaults = try c.value(.defaults, default: ChannelDefaults())
        decoderCap = try c.decodeIfPresent(Int.self, forKey: .decoderCap)
        audioOutputs = try c.value(.audioOutputs, default: [])
        renderSize = try c.value(.renderSize, default: .largest)
        textThumbnail = try c.value(.textThumbnail, default: .body)
        usualContent = try c.value(.usualContent, default: .any)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(defaultPreset, forKey: .defaultPreset)
        try c.encode(defaults, forKey: .defaults)
        try c.encodeNullable(decoderCap, forKey: .decoderCap)
        try c.encode(audioOutputs, forKey: .audioOutputs)
        try c.encode(renderSize, forKey: .renderSize)
        try c.encode(textThumbnail, forKey: .textThumbnail)
        try c.encode(usualContent, forKey: .usualContent)
    }
}
