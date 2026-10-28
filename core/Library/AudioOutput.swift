// OCore — Spec 1 §3, Audio Output.

import Foundation

/// Spec 1 §3 — Audio Output `kind`: "`device` or `sdiEmbedded`".
public enum AudioOutputKind: String, Codable, Equatable, Sendable {
    case device, sdiEmbedded
}

/// Spec 1 §3 — Audio Output `device`: "Core Audio device UID, or the SDI
/// output number". A string or a number on disk.
public enum AudioDevice: Codable, Equatable, Sendable {
    case uid(String)
    case sdiOutput(Int)

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let number = try? single.decode(Int.self) {
            self = .sdiOutput(number)
        } else {
            self = .uid(try single.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .uid(let uid): try single.encode(uid)
        case .sdiOutput(let number): try single.encode(number)
        }
    }
}

/// Spec 1 §3 — Audio Output: `number`, `label`, `uuid`, `kind`, `device`,
/// `channels` ("array of device channel indices"), `delayMs` ("0–1000, for
/// downstream video latency"), `fallbackDevice` ("used only while the primary
/// device is absent, otherwise the output is silent until it returns").
public struct AudioOutput: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var kind: AudioOutputKind
    public var device: AudioDevice
    public var channels: [Int]
    public var delayMs: Int
    public var fallbackDevice: String?
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", uuid: UUID = UUID(), kind: AudioOutputKind = .device,
                device: AudioDevice = .uid(""), channels: [Int] = [0, 1], delayMs: Int = 0, fallbackDevice: String? = nil,
                extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.kind = kind
        self.device = device
        self.channels = channels
        self.delayMs = delayMs
        self.fallbackDevice = fallbackDevice
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, kind, device, channels, delayMs, fallbackDevice }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        kind = try c.value(.kind, default: .device)
        device = try c.value(.device, default: .uid(""))
        channels = try c.value(.channels, default: [0, 1])
        delayMs = try c.value(.delayMs, default: 0)
        fallbackDevice = try c.decodeIfPresent(String.self, forKey: .fallbackDevice)
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
        try c.encode(channels, forKey: .channels)
        try c.encode(delayMs, forKey: .delayMs)
        try c.encodeNullable(fallbackDevice, forKey: .fallbackDevice)
    }
}
