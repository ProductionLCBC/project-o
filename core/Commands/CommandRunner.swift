// OCore — Spec 2 §8, results per command: the runner.

import Foundation

/// Spec 2 §8 and §9 — one executed command: where it ran (group and
/// source), what it was, its result, the effects the projection emitted for
/// it, and the fire record when it opened a cue group. `refusal` says why a
/// `macro N` ran nothing (Spec 2 §5: it loops, nests deeper than the levels
/// left, or does not exist), for the engine's log; the command log's line is
/// the same either way.
public struct ExecutedCommand: Equatable, Sendable {
    public var group: GroupID
    public var source: CommandSource
    public var command: Command
    public var result: CommandResult
    public var effects: [Effect]
    public var fire: FireRecord?
    public var refusal: Rejection?

    public init(group: GroupID, source: CommandSource, command: Command, result: CommandResult,
                effects: [Effect], fire: FireRecord? = nil, refusal: Rejection? = nil) {
        self.group = group
        self.source = source
        self.command = command
        self.result = result
        self.effects = effects
        self.fire = fire
        self.refusal = refusal
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
            runner.run(entry.command, group: group.id, source: group.source, fire: fire, nesting: .top, makeGroupID: makeGroupID)
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

    /// One command at its place in the group (Spec 2 §5, "Macro depth"). It
    /// is folded at that same place, so the lines logged and the state that
    /// results always agree, and a cue whose commands fire cues stops at the
    /// cap rather than recursing without end.
    mutating func run(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?, nesting: Nesting,
                      makeGroupID: () -> GroupID) {
        if case .macro(let number) = command {
            runMacro(number, command: command, group: group, source: source, fire: fire, nesting: nesting, makeGroupID: makeGroupID)
            return
        }
        var projectionContext = context
        projectionContext.source = source
        let before = state
        var fold = Fold(state: before, context: projectionContext)
        fold.apply(command, source: source, nesting: nesting)
        let (after, effects) = (fold.state, fold.effects)

        if let (position, pointer) = firedCue(after: after, effects: effects, context: projectionContext, command: command),
           let cueNesting = nesting.firingCue {
            // Spec 2 §9 — the navigation's line, then the cue's commands as a
            // cue group. The navigation's line carries only its own fire's
            // effects: Spec 3 §5's boundary, with the attribute resets it
            // makes, and the pointer; cues fired deeper log their own.
            let boundary = before.pointer?.listUuid != position.list.uuid
            var replay = Fold(state: before, context: projectionContext)
            if boundary, !position.list.trackThrough { replay.resetAllAttributes() }
            var own = replay.effects
            if boundary { own.append(.boundary(list: position.list.uuid, reset: !position.list.trackThrough)) }
            own.append(pointer)
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .ok, effects: own, fire: fire))
            state = replay.state
            let cueSource = CommandSource(kind: .cue, list: position.list.uuid, cue: position.cue.uuid, playlist: position.playlist?.uuid)
            let cueGroup = makeGroupID()
            var cueFire: FireRecord? = FireRecord(listTitle: position.list.title, ccli: position.list.ccli)
            for entry in position.cue.commands {
                // Spec 1 §6 — a guard on a cue command is reserved and not run; the command runs unguarded.
                run(entry.command, group: cueGroup, source: cueSource, fire: cueFire, nesting: cueNesting, makeGroupID: makeGroupID)
                cueFire = nil
            }
            state = after
            return
        }

        state = after
        executed.append(ExecutedCommand(group: group, source: source, command: command,
                                        result: CommandRunner.result(of: effects), effects: effects, fire: fire))
    }

    /// The cue a navigation command fired and its `pointer` effect. A fire
    /// sets the pointer after its cue's commands ran, so the command's own
    /// fire is the last pointer effect; earlier ones are cues its cue fired.
    /// Only navigation fires: a `disarm` or a load moves no cue, though its
    /// `pointer` effect names the live one.
    func firedCue(after: ShowState, effects: [Effect], context: ProjectionContext, command: Command) -> (CuePosition, Effect)? {
        guard command.isNavigation,
              let last = effects.last(where: { if case .pointer = $0 { return true } else { return false } }),
              case .pointer(_, let new?, _) = last, new.cueUuid != nil,
              let position = Fold(state: after, context: context).position(of: new) else { return nil }
        return (position, last)
    }

    /// Spec 2 §3 — `macro N`; Spec 2 §5 — "A macro runs whole or not at
    /// all": one that loops, nests deeper than the levels left here, or does
    /// not exist runs nothing, its line `noop` with the refusal; Spec 2 §9 and
    /// Spec 3 §8 — the inner commands' source. The macro's own line is `ok`
    /// when any inner command did something, else `noop`.
    mutating func runMacro(_ number: Int, command: Command, group: GroupID, source: CommandSource, fire: FireRecord?,
                           nesting: Nesting, makeGroupID: () -> GroupID) {
        let refusal = MacroCalls.check(number, levels: nesting.levelsLeft, library: context.library, machine: context.machine)
        guard refusal == nil, let macro = MacroCalls.macro(number, library: context.library, machine: context.machine) else {
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .noop,
                                            effects: [.noop(command)], fire: fire, refusal: refusal))
            return
        }
        let inner = source.inMacro(number)
        let index = executed.count
        executed.append(ExecutedCommand(group: group, source: source, command: command, result: .noop, effects: [], fire: fire))
        for entry in macro.commands {
            if let condition = entry.when, !holds(condition) { continue }
            run(entry.command, group: group, source: inner, fire: nil, nesting: nesting.insideMacro, makeGroupID: makeGroupID)
        }
        let acted = executed[(index + 1)...].contains { $0.result != .noop }
        executed[index].result = acted ? .ok : .noop
    }
}
