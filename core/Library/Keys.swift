// OCore — Spec 1 §3, key bindings and the scheduler.

import Foundation

/// Spec 1 §3 — the scheduler's `when`: "`{days, time}`". Days are lowercase
/// English day names; time is `HH:MM` local to the machine's time zone.
public struct Schedule: Codable, Equatable, Sendable {
    public var days: [String]
    public var time: String
    public var extra: [String: JSONValue]

    public init(days: [String], time: String, extra: [String: JSONValue] = [:]) {
        self.days = days
        self.time = time
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case days, time }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.value(.days, default: [])
        time = try c.value(.time, default: "")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(days, forKey: .days)
        try c.encode(time, forKey: .time)
    }
}

/// Spec 1 §3 — Key bindings: "an array of `{device: \"keyboard\" or a MIDI or
/// Stream Deck device id, key, command}`; the scheduler is the same array with
/// `{when: {days, time}}` in place of `key`."
///
/// The command object's own unknown keys are kept beside it, since a
/// `Command` is a closed vocabulary (Spec 1 §8).
public struct KeyBinding: Codable, Equatable, Sendable {
    public var device: String
    public var key: String?
    public var when: Schedule?
    public var command: Command
    public var commandExtras: [String: JSONValue]
    public var extra: [String: JSONValue]

    public init(device: String, key: String? = nil, when: Schedule? = nil, command: Command,
                commandExtras: [String: JSONValue] = [:], extra: [String: JSONValue] = [:]) {
        self.device = device
        self.key = key
        self.when = when
        self.command = command
        self.commandExtras = commandExtras
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case device, key, when, command }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.value(.device, default: "keyboard")
        key = try c.decodeIfPresent(String.self, forKey: .key)
        when = try c.decodeIfPresent(Schedule.self, forKey: .when)
        let raw = try c.decode(JSONValue.self, forKey: .command)
        let decoded = try JSONCoding.decode(GuardedCommand.self, from: raw)
        command = decoded.command
        commandExtras = decoded.extra
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(device, forKey: .device)
        if let when {
            try c.encode(when, forKey: .when)
        } else {
            try c.encodeNullable(key, forKey: .key)
        }
        try c.encode(GuardedCommand(command, extra: commandExtras), forKey: .command)
    }
}
