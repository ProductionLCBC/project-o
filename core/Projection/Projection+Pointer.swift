// OCore — Spec 3 §5, the live pointer and triggers. (Stub; next commit.)

extension Fold {
    mutating func fireFollowing(command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func firePreceding(command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func fireCue(_ position: Int, command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func fireItem(_ item: Int, cue: Int, command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func fireSection(_ item: Int, _ section: String, command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func fireList(_ list: Int, cue: Int, command: Command, depth: Int) { effects.append(.noop(command)) }
    mutating func loadPlaylist(_ title: String, date: String?, command: Command) { effects.append(.noop(command)) }
}
