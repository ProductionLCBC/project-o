// OCore — Spec 1 §2, Macro.

import Foundation

/// Spec 1 §2 — Macro: `number`, `label`, `uuid`, `commands` (array of command
/// objects, each with an optional guard, Spec 2 §7), `color`, `tileLabel`.
/// "`scope` is computed, not stored: a macro that references a stack or
/// output is machine-level and is written to the machine root instead of the
/// library."
public struct Macro: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var commands: [GuardedCommand]
    public var color: Color
    public var tileLabel: String
    public var extra: [String: JSONValue]

    public init(number: Int, commands: [GuardedCommand], label: String = "", uuid: UUID = UUID(),
                color: Color = Color(r: 0.2, g: 0.5, b: 0.9), tileLabel: String = "", extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.commands = commands
        self.color = color
        self.tileLabel = tileLabel
        self.extra = extra
    }

    /// Spec 1 §2 — the computed scope: machine-level when any command, or any
    /// guard, names a stack or an output.
    public var isMachineLevel: Bool {
        commands.contains { entry in
            var found = false
            entry.command.forEachReference(of: .stack) { _ in found = true }
            entry.command.forEachReference(of: .output) { _ in found = true }
            if let condition = entry.when {
                condition.forEachReference(of: .stack) { _ in found = true }
                condition.forEachReference(of: .output) { _ in found = true }
            }
            return found
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, commands, color, tileLabel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        commands = try GuardedCommand.decodeList(from: c, forKey: .commands)
        color = try c.value(.color, default: Color(r: 0.2, g: 0.5, b: 0.9))
        tileLabel = try c.value(.tileLabel, default: "")
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(commands, forKey: .commands)
        try c.encode(color, forKey: .color)
        try c.encode(tileLabel, forKey: .tileLabel)
    }
}
