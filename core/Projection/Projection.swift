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

/// Spec 3 §7 — "Lookahead for offset slots. Start from the live ShowState and
/// fold the next K cues from the pointer, crossing item boundaries and
/// applying list boundaries exactly as a real fire would, with `frame` held
/// at the current frame so nothing appears to play." Returns nil past the end
/// of the playlist, which is what an empty `+K` slot shows.
public func lookahead(_ state: ShowState, steps: Int, context: ProjectionContext) -> ShowState? {
    // Stub until the §9 tests exist.
    nil
}
