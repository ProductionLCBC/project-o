// OCore — Spec 3 §6, the projection function.

/// Spec 3 §6 — `project(_ state: ShowState, _ commands: [Command], context:
/// ProjectionContext) -> (ShowState, [Effect])`: "a pure fold of commands
/// over state: given a state and a list of commands it returns the next
/// state and a list of effects, with no clock, no I/O and no Apple
/// frameworks."
public func project(_ state: ShowState, _ commands: [Command], context: ProjectionContext) -> (ShowState, [Effect]) {
    // Stub until the §9 tests exist; every command is a noop.
    (state, commands.map { .noop($0) })
}
