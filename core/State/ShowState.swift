// OCore — Spec 3 §2, ShowState.

import Foundation

/// Spec 3 §5 — "The pointer is `{playlist, itemUuid, listUuid, cueUuid}`,
/// where `itemUuid` is the playlist item's uuid, or, when a master was fired
/// directly from the library, `{listUuid, cueUuid}` with no playlist (Spec 7
/// §4). It names the last cue fired, not a cursor."
///
/// Reading of the spec: `playlist.load` makes a playlist live "with no cue
/// fired", which is a pointer with the playlist set and no list or cue, so the
/// first `next` fires its first cue and is a boundary. Spec 7 §4 — the item
/// is named "under the new key `itemUuid` so that an older state file can't be
/// misread": an older file's `item`, a position, is not read.
public struct LivePointer: Codable, Equatable, Sendable {
    public var playlist: UUID?
    public var itemUuid: UUID?
    public var listUuid: UUID?
    public var cueUuid: UUID?

    public init(playlist: UUID? = nil, itemUuid: UUID? = nil, listUuid: UUID? = nil, cueUuid: UUID? = nil) {
        self.playlist = playlist
        self.itemUuid = itemUuid
        self.listUuid = listUuid
        self.cueUuid = cueUuid
    }

    private enum CodingKeys: String, CodingKey { case playlist, itemUuid, listUuid, cueUuid }

    /// Spec 1 §9 — UUIDs are written lowercase.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(playlist?.uuidString.lowercased(), forKey: .playlist)
        try c.encodeIfPresent(itemUuid?.uuidString.lowercased(), forKey: .itemUuid)
        try c.encodeIfPresent(listUuid?.uuidString.lowercased(), forKey: .listUuid)
        try c.encodeIfPresent(cueUuid?.uuidString.lowercased(), forKey: .cueUuid)
    }
}

/// Spec 3 §5 — "`armed = {item, cue: next, at: fireFrame + ms}`"; Spec 7 §4 —
/// "The armed trigger gains the item's uuid beside the cue's, `{itemUuid,
/// cueUuid, atFrame}`, so a song linked twice arms the right copy." No item
/// when a library list is live.
public struct ArmedTrigger: Codable, Equatable, Sendable {
    public var itemUuid: UUID?
    public var cueUuid: UUID
    public var atFrame: Int
    public init(itemUuid: UUID?, cueUuid: UUID, atFrame: Int) {
        self.itemUuid = itemUuid
        self.cueUuid = cueUuid
        self.atFrame = atFrame
    }

    private enum CodingKeys: String, CodingKey { case itemUuid, cueUuid, atFrame }

    /// Spec 1 §9 — UUIDs are written lowercase.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(itemUuid?.uuidString.lowercased(), forKey: .itemUuid)
        try c.encode(cueUuid.uuidString.lowercased(), forKey: .cueUuid)
        try c.encode(atFrame, forKey: .atFrame)
    }
}

/// Spec 3 §2 — `stacks` "(blackout flag and per-slot mutes)". Mutes are keyed
/// by channel number and encoded as a sorted array.
public struct StackState: Codable, Equatable, Sendable {
    public var blackout: Bool
    public var muted: Set<Int>

    public init(blackout: Bool = false, muted: Set<Int> = []) {
        self.blackout = blackout
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey { case blackout, muted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blackout = try c.decode(Bool.self, forKey: .blackout)
        muted = Set(try c.decodeIfPresent([Int].self, forKey: .muted) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(blackout, forKey: .blackout)
        try c.encode(muted.sorted(), forKey: .muted)
    }
}

/// Spec 3 §2 and §10 — `ShowState`: "one value holding everything the
/// projection reads or writes: `channels`, `outputs` (live stack per output),
/// `stacks`, `pointer`, `armed`, and `popups`." Timers are not in ShowState.
public struct ShowState: Codable, Equatable, Sendable {
    public var channels: [Int: ChannelState]
    /// Output number to the number of its live stack.
    public var outputs: [Int: Int]
    public var stacks: [Int: StackState]
    public var pointer: LivePointer?
    public var armed: ArmedTrigger?
    public var popups: [Int: String]

    public init(channels: [Int: ChannelState] = [:], outputs: [Int: Int] = [:],
                stacks: [Int: StackState] = [:], pointer: LivePointer? = nil,
                armed: ArmedTrigger? = nil, popups: [Int: String] = [:]) {
        self.channels = channels
        self.outputs = outputs
        self.stacks = stacks
        self.pointer = pointer
        self.armed = armed
        self.popups = popups
    }

    /// Spec 3 §2 — "A fresh ShowState has every channel `empty` with every
    /// attribute at `{default value, origin: default}`, every output on its
    /// default stack, nothing blacked out, and no live pointer."
    public static func fresh(library: Library, machine: Machine) -> ShowState {
        var state = ShowState()
        for channel in library.channels {
            state.channels[channel.number] = .fresh(for: channel)
        }
        for output in machine.outputs {
            state.outputs[output.number] = output.defaultStack
        }
        for stack in machine.stacks {
            state.stacks[stack.number] = StackState()
        }
        return state
    }

    private enum CodingKeys: String, CodingKey { case channels, outputs, stacks, pointer, armed, popups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let path = c.codingPath
        channels = try IntKeyedCoding.intKeyed(try c.decode([String: ChannelState].self, forKey: .channels), at: path)
        outputs = try IntKeyedCoding.intKeyed(try c.decode([String: Int].self, forKey: .outputs), at: path)
        stacks = try IntKeyedCoding.intKeyed(try c.decode([String: StackState].self, forKey: .stacks), at: path)
        pointer = try c.decodeIfPresent(LivePointer.self, forKey: .pointer)
        armed = try c.decodeIfPresent(ArmedTrigger.self, forKey: .armed)
        popups = try IntKeyedCoding.intKeyed(try c.decodeIfPresent([String: String].self, forKey: .popups) ?? [:], at: path)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(IntKeyedCoding.stringKeyed(channels), forKey: .channels)
        try c.encode(IntKeyedCoding.stringKeyed(outputs), forKey: .outputs)
        try c.encode(IntKeyedCoding.stringKeyed(stacks), forKey: .stacks)
        try c.encodeIfPresent(pointer, forKey: .pointer)
        try c.encodeIfPresent(armed, forKey: .armed)
        try c.encode(IntKeyedCoding.stringKeyed(popups), forKey: .popups)
    }
}
