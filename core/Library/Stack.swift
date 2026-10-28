// OCore — Spec 1 §3, Stack.

import Foundation

/// Spec 1 §3 — a Stack slot: "`{channel, preset (number or null), offset
/// (integer, -2 to +3), opacity (0–1), mute (bool)}`".
public struct StackSlot: Codable, Equatable, Sendable {
    public var channel: Int
    public var preset: Int?
    public var offset: Int
    public var opacity: Double
    public var mute: Bool
    public var extra: [String: JSONValue]

    public init(channel: Int, preset: Int? = nil, offset: Int = 0, opacity: Double = 1, mute: Bool = false,
                extra: [String: JSONValue] = [:]) {
        self.channel = channel
        self.preset = preset
        self.offset = offset
        self.opacity = opacity
        self.mute = mute
        self.extra = extra
    }

    /// Spec 1 §3 — offsets run from -2 to +3 and opacity from 0 to 1.
    public var isInRange: Bool {
        offset >= -2 && offset <= 3 && opacity >= 0 && opacity <= 1
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case channel, preset, offset, opacity, mute }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(Int.self, forKey: .channel)
        preset = try c.decodeIfPresent(Int.self, forKey: .preset)
        offset = try c.value(.offset, default: 0)
        opacity = try c.value(.opacity, default: 1)
        mute = try c.value(.mute, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channel, forKey: .channel)
        try c.encodeNullable(preset, forKey: .preset)
        try c.encode(offset, forKey: .offset)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(mute, forKey: .mute)
    }
}

/// Spec 1 §3 — Stack `base`: "`black` or `transparent`".
public enum StackBase: String, Codable, Equatable, Sendable {
    case black, transparent
}

/// Spec 1 §3 — Stack: `number`, `label`, `uuid`, `slots` ("ordered array,
/// bottom to top"), `base`, `defaultPreset`, `gammaBlend` ("default false").
/// Spec 1 §9: "a channel appears at most once per stack at each offset, and
/// the loader enforces that form."
public struct Stack: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var slots: [StackSlot]
    public var base: StackBase
    public var defaultPreset: Int?
    public var gammaBlend: Bool
    public var extra: [String: JSONValue]

    public init(number: Int, slots: [StackSlot] = [], label: String = "", uuid: UUID = UUID(), base: StackBase = .black,
                defaultPreset: Int? = nil, gammaBlend: Bool = false, extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.slots = slots
        self.base = base
        self.defaultPreset = defaultPreset
        self.gammaBlend = gammaBlend
        self.extra = extra
    }

    /// Spec 1 §9 — the indices of slots that repeat an earlier slot's
    /// channel-and-offset pair.
    public var duplicateSlotIndices: [Int] {
        var seen: Set<String> = []
        var duplicates: [Int] = []
        for (i, slot) in slots.enumerated() {
            let key = "\(slot.channel)@\(slot.offset)"
            if !seen.insert(key).inserted { duplicates.append(i) }
        }
        return duplicates
    }

    /// Spec 1 §8 — "A broken reference degrades to the documented default
    /// (... an empty slot)": the slots as the engine should use them, without
    /// duplicates (the first wins) and without slots naming a channel the
    /// library does not have. The stack itself is kept as read.
    public func effectiveSlots(library: Library) -> [StackSlot] {
        let duplicates = Set(duplicateSlotIndices)
        return slots.enumerated().compactMap { i, slot in
            guard !duplicates.contains(i), library.channel(slot.channel) != nil else { return nil }
            return slot
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, slots, base, defaultPreset, gammaBlend }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        slots = try c.value(.slots, default: [])
        base = try c.value(.base, default: .black)
        defaultPreset = try c.decodeIfPresent(Int.self, forKey: .defaultPreset)
        gammaBlend = try c.value(.gammaBlend, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(slots, forKey: .slots)
        try c.encode(base, forKey: .base)
        try c.encodeNullable(defaultPreset, forKey: .defaultPreset)
        try c.encode(gammaBlend, forKey: .gammaBlend)
    }
}
