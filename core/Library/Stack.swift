// OCore — Spec 1 §3, Stack.

import Foundation

/// Spec 1 §3 — a Stack slot: "`{channel, preset (number or null), opacity
/// (0–1), mute (bool)}`". Spec 6 §2 — "Its `offset` moves to the box ... A
/// stacks document that still has `offset` on a slot keeps it as an unknown
/// key (Spec 1 §8), which the engine ignores; an old +1 slot is then a
/// duplicate."
public struct StackSlot: Codable, Equatable, Sendable {
    public var channel: Int
    public var preset: Int?
    public var opacity: Double
    public var mute: Bool
    public var extra: [String: JSONValue]

    public init(channel: Int, preset: Int? = nil, opacity: Double = 1, mute: Bool = false,
                extra: [String: JSONValue] = [:]) {
        self.channel = channel
        self.preset = preset
        self.opacity = opacity
        self.mute = mute
        self.extra = extra
    }

    /// Spec 1 §3 — opacity runs from 0 to 1.
    public var isInRange: Bool {
        opacity >= 0 && opacity <= 1
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case channel, preset, opacity, mute }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channel = try c.decode(Int.self, forKey: .channel)
        preset = try c.decodeIfPresent(Int.self, forKey: .preset)
        opacity = try c.value(.opacity, default: 1)
        mute = try c.value(.mute, default: false)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(channel, forKey: .channel)
        try c.encodeNullable(preset, forKey: .preset)
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
/// "A channel appears at most once per stack; the engine uses the first slot
/// for a channel and reports the rest (section 8)."
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

    /// Spec 6 §2 — "The engine uses the first slot for a channel and ignores
    /// any later one": the indices of slots whose channel an earlier slot of
    /// this stack already has.
    public var duplicateSlotIndices: [Int] {
        var seen: Set<Int> = []
        var duplicates: [Int] = []
        for (i, slot) in slots.enumerated() where !seen.insert(slot.channel).inserted {
            duplicates.append(i)
        }
        return duplicates
    }

    /// Spec 6 §2 — "A later slot stays in the document as read and is reported
    /// on every load (Spec 1 §8)"; Spec 1 §8 — "A broken reference degrades to
    /// the documented default (... an empty slot)": the slots as the engine
    /// uses them, the first for each channel, without slots naming a channel
    /// the library does not have. The stack itself is kept as read.
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
