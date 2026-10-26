// OCore — Spec 3 §6, macros and guards. (Stub; next commit.)

extension Fold {
    mutating func runMacro(_ number: Int, command: Command, source: CommandSource, depth: Int) { effects.append(.noop(command)) }
}
