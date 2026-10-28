// OCore — Spec 2 §8, results per command: the runner.

import Foundation

/// Spec 2 §8 and §9 — one executed command: where it ran (group and
/// source), what it was, its result, the effects the projection emitted for
/// it, and the fire record when it opened a cue group.
public struct ExecutedCommand: Equatable, Sendable {
    public var group: GroupID
    public var source: CommandSource
    public var command: Command
    public var result: CommandResult
    public var effects: [Effect]
    public var fire: FireRecord?

    public init(group: GroupID, source: CommandSource, command: Command, result: CommandResult,
                effects: [Effect], fire: FireRecord? = nil) {
        self.group = group
        self.source = source
        self.command = command
        self.result = result
        self.effects = effects
        self.fire = fire
    }
}

/// What a run leaves behind: the new state and every executed command in
/// the order it ran.
public struct RunOutcome: Equatable, Sendable {
    public var state: ShowState
    public var executed: [ExecutedCommand]

    public init(state: ShowState, executed: [ExecutedCommand]) {
        self.state = state
        self.executed = executed
    }
}

/// Spec 2 §8 — "A command passes through four stages: parse, validate,
/// execute, log." The runner is the execute stage for a group: it validates
/// the group whole, then folds it one command at a time over the projection
/// (Spec 3 §6) so every command has its own effects and result ("Every
/// executed command yields one of `ok`, `blocked`, `noop` or `steppedOn`").
///
/// Spec 2 §3 — `macro N` "Runs the macro's commands in order; each inner
/// command is logged and judged on its own": the runner expands a macro
/// itself, evaluating each guard against the state as earlier commands left
/// it (Spec 2 §7), under the macro's group (Spec 2 §10). Spec 3 §8 — a macro
/// fired by a cue inherits the cue source.
///
/// Navigation that fires a cue (`next`, `cue N`, `item N cue M`, `list N cue
/// M`, sections) is logged as the navigation, then the cue's commands as
/// their own cue group with `fire` on the first (Spec 2 §9). The projection's
/// fold of the whole command is the state that results; the replay of the
/// cue's commands one at a time only attributes effects and results.
public enum CommandRunner {
    public static func run(_ group: CommandGroup, state: ShowState, context: ProjectionContext, validate: Bool = true,
                           makeGroupID: () -> GroupID = { GroupID.random() }) -> Result<RunOutcome, Rejection> {
        if validate {
            let validation = ValidationContext(library: context.library, machine: context.machine, state: state, source: group.source)
            if let rejection = CommandValidator.validate(group, context: validation) {
                return .failure(rejection)
            }
        }
        var runner = Runner(state: state, context: context)
        var fire = group.fire
        for entry in group.commands {
            // Spec 2 §7 — "the command runs only when it holds".
            if let condition = entry.when, !runner.holds(condition) { continue }
            runner.run(entry.command, group: group.id, source: group.source, fire: fire, depth: 0, makeGroupID: makeGroupID)
            fire = nil
        }
        return .success(RunOutcome(state: runner.state, executed: runner.executed))
    }

    /// Spec 2 §8 — the result a command's effects add up to: `steppedOn` when
    /// the write stepped on a decoder, `blocked` when lock refused everything
    /// it would have done, `noop` when nothing changed, else `ok`.
    public static func result(of effects: [Effect]) -> CommandResult {
        var blocked = false
        var changed = false
        for effect in effects {
            switch effect {
            case .steppedOn: return .steppedOn
            case .blocked: blocked = true
            case .noop: break
            default: changed = true
            }
        }
        if changed { return .ok }
        return blocked ? .blocked : .noop
    }
}

struct Runner {
    var state: ShowState
    let context: ProjectionContext
    var executed: [ExecutedCommand] = []

    func holds(_ condition: Guard) -> Bool {
        condition.holds(actual: Fold(state: state, context: context).value(of: condition.variable))
    }

    mutating func run(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?, depth: Int,
                      makeGroupID: () -> GroupID) {
        if case .macro(let number) = command {
            runMacro(number, command: command, group: group, source: source, fire: fire, depth: depth, makeGroupID: makeGroupID)
            return
        }
        var projectionContext = context
        projectionContext.source = source
        let before = state
        let (after, effects) = project(before, [command], context: projectionContext)

        if let position = firedPosition(after: after, effects: effects, context: projectionContext) {
            // Spec 2 §9 — the navigation, then the cue's commands as a cue group.
            let own = effects.filter { effect in
                switch effect {
                case .boundary, .pointer: return true
                default: return false
                }
            }
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .ok, effects: own, fire: fire))
            var replay = Fold(state: before, context: projectionContext)
            if effects.contains(where: { if case .boundary(_, let reset) = $0 { return reset } else { return false } }) {
                replay.resetAllAttributes()
            }
            state = replay.state
            let cueSource = CommandSource(kind: .cue, list: position.list.uuid, cue: position.cue.uuid, playlist: position.playlist?.uuid)
            let cueGroup = makeGroupID()
            var cueFire: FireRecord? = FireRecord(listTitle: position.list.title, ccli: position.list.ccli)
            for entry in position.cue.commands {
                // Spec 1 §6 — a guard on a cue command is reserved and not run; the command runs unguarded.
                run(entry.command, group: cueGroup, source: cueSource, fire: cueFire, depth: depth + 1, makeGroupID: makeGroupID)
                cueFire = nil
            }
            state = after
            return
        }

        state = after
        executed.append(ExecutedCommand(group: group, source: source, command: command,
                                        result: CommandRunner.result(of: effects), effects: effects, fire: fire))
    }

    /// The cue a navigation command fired, read from its `pointer` effect.
    func firedPosition(after: ShowState, effects: [Effect], context: ProjectionContext) -> CuePosition? {
        for effect in effects {
            if case .pointer(_, let new?, _) = effect, new.cueUuid != nil {
                return Fold(state: after, context: context).position(of: new)
            }
        }
        return nil
    }

    /// Spec 2 §3 — `macro N`; Spec 2 §5 — "depth is capped at 8"; Spec 3 §8
    /// — the cue source is inherited. The macro's own line is `ok` when any
    /// inner command did something, else `noop`; an unknown macro is `noop`.
    mutating func runMacro(_ number: Int, command: Command, group: GroupID, source: CommandSource, fire: FireRecord?,
                           depth: Int, makeGroupID: () -> GroupID) {
        guard depth < Fold.maxDepth, let macro = context.library.macro(number) ?? context.machine.macro(number) else {
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .noop,
                                            effects: [.noop(command)], fire: fire))
            return
        }
        let inner = source.kind.isSubjectToLock
            ? source
            : CommandSource(kind: .macro, list: source.list, cue: source.cue, playlist: source.playlist, macro: number)
        let index = executed.count
        executed.append(ExecutedCommand(group: group, source: source, command: command, result: .noop, effects: [], fire: fire))
        for entry in macro.commands {
            if let condition = entry.when, !holds(condition) { continue }
            run(entry.command, group: group, source: inner, fire: nil, depth: depth + 1, makeGroupID: makeGroupID)
        }
        let acted = executed[(index + 1)...].contains { $0.result != .noop }
        executed[index].result = acted ? .ok : .noop
    }
}
