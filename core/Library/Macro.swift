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

/// Spec 2 §5 — "Macro depth": the macros of both roots by number, and the
/// one check that decides whether a macro can run whole. The validator calls
/// it with all the levels for a `macro N` submitted directly (§8); the
/// projection and the runner call it with the levels left wherever a macro is
/// entered, so a macro runs whole or not at all from every source.
public enum MacroCalls {
    /// Spec 2 §5 — "A macro can call another macro up to 8 deep."
    public static let maxDepth = 8

    /// Spec 1 §2 — a macro lives in the library or, when it names a stack or
    /// an output, in the machine root; one number names one macro. The
    /// library's is taken first, then the machine's, and within a root the
    /// first with that number (Spec 1 §8 reports the duplicate).
    public static func macro(_ number: Int, library: Library, machine: Machine) -> Macro? {
        library.macro(number) ?? machine.macro(number)
    }

    /// Spec 2 §5 — "A macro runs whole or not at all: ... one that loops or
    /// nests too deep is rejected; ... reached where fewer levels are left, it
    /// runs nothing". Nil when macro `number` exists and its calls fit in
    /// `levels`; otherwise why not: `noSuchTarget`, `macroCycle` naming the
    /// loop, or `macroDepth`. Every `macro N` a macro holds counts, whatever
    /// its guard says; a call to a macro that does not exist counts no level
    /// (it runs as a `noop`). Each macro's depth is worked out once, so the
    /// cost grows with the number of macros, not the number of paths.
    public static func check(_ number: Int, levels: Int, library: Library, machine: Machine) -> Rejection? {
        guard macro(number, library: library, machine: machine) != nil else {
            return Rejection(reason: .noSuchTarget, message: "macro \(number) does not exist")
        }
        var heights: [Int: Int] = [:]
        var path: [Int] = []
        func height(_ n: Int) throws -> Int {
            if let at = path.firstIndex(of: n) {
                let loop = (path[at...] + [n]).map { "macro \($0)" }.joined(separator: " → ")
                throw Rejection(reason: .macroCycle, message: "macros call each other in a loop: \(loop)")
            }
            if let known = heights[n] { return known }
            guard let found = macro(n, library: library, machine: machine) else { return 0 }
            path.append(n)
            var deepest = 0
            for entry in found.commands {
                if case .macro(let inner) = entry.command { deepest = max(deepest, try height(inner)) }
            }
            path.removeLast()
            heights[n] = deepest + 1
            return deepest + 1
        }
        do {
            let depth = try height(number)
            guard depth > levels else { return nil }
            let left = max(0, levels)
            let room = levels >= maxDepth ? "the cap is \(maxDepth)"
                : left == 1 ? "1 level of the \(maxDepth) is left here" : "\(left) levels of the \(maxDepth) are left here"
            return Rejection(reason: .macroDepth, message: "macro \(number) nests \(depth) macros deep; \(room)")
        } catch let rejection as Rejection {
            return rejection
        } catch {
            return Rejection(reason: .macroCycle, message: "\(error)")
        }
    }
}
