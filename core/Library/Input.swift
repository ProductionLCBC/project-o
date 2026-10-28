// OCore — Spec 1 §3, Input.

import Foundation

/// Spec 1 §3 — Input `kind`: "`sdi`, `ndi`, `camera`, `screen`".
public enum InputKind: String, Codable, Equatable, Sendable {
    case sdi, ndi, camera, screen
}

/// Spec 1 §3 — Input: `number`, `label`, `uuid`, `kind`, `device`, `format`,
/// `deinterlace`, `colorRange`, `audioMap`, `bufferingMs`, `expected` ("for
/// pre-flight").
public struct Input: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var kind: InputKind
    public var device: String
    public var format: VideoFormat
    public var deinterlace: Bool
    public var colorRange: ColorRange
    public var audioMap: [Int]
    public var bufferingMs: Int
    public var expected: Bool
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", uuid: UUID = UUID(), kind: InputKind = .sdi, device: String = "",
                format: VideoFormat = VideoFormat(), deinterlace: Bool = false, colorRange: ColorRange = .limited,
                audioMap: [Int] = [], bufferingMs: Int = 0, expected: Bool = false, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.kind = kind
        self.device = device
        self.format = format
        self.deinterlace = deinterlace
        self.colorRange = colorRange
        self.audioMap = audioMap
        self.bufferingMs = bufferingMs
        self.expected = expected
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case number, label, uuid, kind, device, format, deinterlace, colorRange, audioMap, bufferingMs, expected
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        kind = try c.value(.kind, default: .sdi)
        device = try c.value(.device, default: "")
        format = try c.value(.format, default: VideoFormat())
        deinterlace = try c.value(.deinterlace, default: false)
        colorRange = try c.value(.colorRange, default: .limited)
        audioMap = try c.value(.audioMap, default: [])
        bufferingMs = try c.value(.bufferingMs, default: 0)
        expected = try c.value(.expected, default: false)
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
        try c.encode(deinterlace, forKey: .deinterlace)
        try c.encode(colorRange, forKey: .colorRange)
        try c.encode(audioMap, forKey: .audioMap)
        try c.encode(bufferingMs, forKey: .bufferingMs)
        try c.encode(expected, forKey: .expected)
    }
}
