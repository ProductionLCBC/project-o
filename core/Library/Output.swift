// OCore — Spec 1 §3, Output.

import Foundation

/// Spec 1 §3 — Output `kind`: "`sdi`, `display`, `ndi`, `multiviewer`".
public enum OutputKind: String, Codable, Equatable, Sendable {
    case sdi, display, ndi, multiviewer
}

/// Spec 1 §3 — Output `genlock`: "`reference`, `freeRun`. SDI only."
public enum Genlock: String, Codable, Equatable, Sendable {
    case reference, freeRun
}

/// Spec 1 §3 — "keyMode is shaped (premultiplied fill, the default) or unshaped".
public enum KeyMode: String, Codable, Equatable, Sendable {
    case shaped, unshaped
}

/// Spec 1 §3 — Output `transitions`: "`{switch: transition number, blackout:
/// transition number}`. Output-level: stack switches, blackout, per-slot mute."
public struct OutputTransitions: Codable, Equatable, Sendable {
    public var `switch`: Int
    public var blackout: Int
    public var extra: [String: JSONValue]

    public init(switch switchRef: Int, blackout: Int, extra: [String: JSONValue] = [:]) {
        self.switch = switchRef
        self.blackout = blackout
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case `switch`, blackout }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.switch = try c.value(.switch, default: 1)
        blackout = try c.value(.blackout, default: 1)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.switch, forKey: .switch)
        try c.encode(blackout, forKey: .blackout)
    }
}

/// Spec 1 §3 — Output: `number`, `label`, `uuid`, `kind`, `device` ("A
/// stable hardware identifier"), `format`, `colorRange` ("Default full for
/// displays, limited for SDI"), `genlock` ("SDI only"), `defaultStack`
/// ("Loaded at launch"), `keyFillPartner`, `keyMode`, `transitions`.
///
/// Every key is written on every output; `genlock` is null off SDI.
public struct Output: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var kind: OutputKind
    public var device: String
    public var format: VideoFormat
    public var colorRange: ColorRange
    public var genlock: Genlock?
    public var defaultStack: Int
    public var keyFillPartner: Int?
    public var keyMode: KeyMode
    public var transitions: OutputTransitions
    public var extra: [String: JSONValue]

    public init(number: Int, defaultStack: Int, transitions: OutputTransitions = OutputTransitions(switch: 1, blackout: 1),
                label: String = "", uuid: UUID = UUID(), kind: OutputKind = .display, device: String = "",
                format: VideoFormat = VideoFormat(), colorRange: ColorRange? = nil, genlock: Genlock? = nil,
                keyFillPartner: Int? = nil, keyMode: KeyMode = .shaped, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.kind = kind
        self.device = device
        self.format = format
        self.colorRange = colorRange ?? (kind == .sdi ? .limited : .full)
        self.genlock = genlock
        self.defaultStack = defaultStack
        self.keyFillPartner = keyFillPartner
        self.keyMode = keyMode
        self.transitions = transitions
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case number, label, uuid, kind, device, format, colorRange, genlock, defaultStack, keyFillPartner, keyMode, transitions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        kind = try c.value(.kind, default: .display)
        device = try c.value(.device, default: "")
        format = try c.value(.format, default: VideoFormat())
        colorRange = try c.value(.colorRange, default: kind == .sdi ? .limited : .full)
        genlock = try c.decodeIfPresent(Genlock.self, forKey: .genlock)
        defaultStack = try c.value(.defaultStack, default: 1)
        keyFillPartner = try c.decodeIfPresent(Int.self, forKey: .keyFillPartner)
        keyMode = try c.value(.keyMode, default: .shaped)
        transitions = try c.value(.transitions, default: OutputTransitions(switch: 1, blackout: 1))
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(kind, forKey: .kind)
        try c.encode(device, forKey: .device)
        try c.encode(format, forKey: .format)
        try c.encode(colorRange, forKey: .colorRange)
        try c.encodeNullable(genlock, forKey: .genlock)
        try c.encode(defaultStack, forKey: .defaultStack)
        try c.encodeNullable(keyFillPartner, forKey: .keyFillPartner)
        try c.encode(keyMode, forKey: .keyMode)
        try c.encode(transitions, forKey: .transitions)
    }
}
