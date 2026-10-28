// OCore — Spec 2 §5, groups and selection expansion.

import Foundation

/// Spec 2 §5 — "Commands submitted together (a cue's commands, a macro's, a
/// UI expansion) carry a shared `group` id in their log entries, so undo
/// treats them as one step." Spec 2 §9 writes it as `"group": "g-7f1a"`. The
/// engine supplies ids; `init(uuid:)` makes one with eight hex characters,
/// enough for a day of entries (the spec's four would collide).
public struct GroupID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(uuid: UUID) {
        let hex = uuid.uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        self.rawValue = "g-" + hex.prefix(8)
    }

    public static func random() -> GroupID {
        GroupID(uuid: UUID())
    }
}

/// Spec 2 §9 — `fire` "appears only on the first command of a cue group and
/// snapshots the list's title and CCLI number at fire time, since masters
/// change later; CCLI reporting is a query over these lines."
public struct FireRecord: Codable, Equatable, Sendable {
    public var listTitle: String
    public var ccli: String

    public init(listTitle: String, ccli: String) {
        self.listTitle = listTitle
        self.ccli = ccli
    }
}

/// Spec 2 §5 — a group: the commands submitted together, the source they
/// share (Spec 2 §5's table) and, for a cue group, the fire record.
public struct CommandGroup: Equatable, Sendable {
    public var id: GroupID
    public var source: CommandSource
    public var commands: [GuardedCommand]
    public var fire: FireRecord?

    public init(id: GroupID, source: CommandSource, commands: [GuardedCommand], fire: FireRecord? = nil) {
        self.id = id
        self.source = source
        self.commands = commands
        self.fire = fire
    }

    public init(id: GroupID, source: CommandSource, commands: [Command], fire: FireRecord? = nil) {
        self.init(id: id, source: source, commands: commands.map { GuardedCommand($0) }, fire: fire)
    }
}

/// Spec 2 §5 — "`selected` is a UI token, never a command argument. When the
/// operator presses a button that acts on the selection, the UI expands it to
/// one command per selected channel at that moment (`channel 2 clear`,
/// `channel 5 clear`) and submits them as a group ... Stack selection and
/// channel selection are independent tokens with the same rule."
public enum Selection {
    /// One command per selected number, in number order, each number once.
    public static func expand<S: Sequence>(_ selected: S, _ make: (Int) -> Command) -> [Command] where S.Element == Int {
        Set(selected).sorted().map(make)
    }

    /// The expansion as one group.
    public static func group<S: Sequence>(_ id: GroupID, source: CommandSource, selected: S,
                                          _ make: (Int) -> Command) -> CommandGroup where S.Element == Int {
        CommandGroup(id: id, source: source, commands: expand(selected, make))
    }
}
