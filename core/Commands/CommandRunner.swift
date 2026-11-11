// OCore — Spec 2 §8, results per command: the runner.

import Foundation

/// Spec 2 §8 and §9 — one executed command: where it ran (group and
/// source), what it was, its result, the effects the projection emitted for
/// it, and the fire record when it opened a cue group. `refusal` says why a
/// `macro N` ran nothing (Spec 2 §5: it loops, nests deeper than the levels
/// left, or does not exist), or why a held edit is `blocked` (Spec 5 §2), for
/// the engine's log; the command log's line is the same either way.
///
/// An applied edit carries what Spec 5 §1 and §2 ask of it: "The engine
/// works out each edit's inverse when it runs the edit, and the log keeps
/// both (Spec 2 §9)"; what changed, for the `library` event; the file
/// operations it makes; and its result's `warnings` (Spec 5 §6).
public struct ExecutedCommand: Equatable, Sendable {
    public var group: GroupID
    public var source: CommandSource
    public var command: Command
    public var result: CommandResult
    public var effects: [Effect]
    public var fire: FireRecord?
    public var refusal: Rejection?
    public var inverse: Command?
    public var changes: [LibraryChange]
    public var structure: [StructureChange]
    public var warnings: [String]
    /// Spec 2 §9 as Spec 8 §7 adds — "A `media import` result also carries
    /// the `job` its outcomes are reported under."
    public var job: String?

    public init(group: GroupID, source: CommandSource, command: Command, result: CommandResult,
                effects: [Effect], fire: FireRecord? = nil, refusal: Rejection? = nil, inverse: Command? = nil,
                changes: [LibraryChange] = [], structure: [StructureChange] = [], warnings: [String] = [], job: String? = nil) {
        self.group = group
        self.source = source
        self.command = command
        self.result = result
        self.effects = effects
        self.fire = fire
        self.refusal = refusal
        self.inverse = inverse
        self.changes = changes
        self.structure = structure
        self.warnings = warnings
        self.job = job
    }
}

/// What a run leaves behind: the new state, every executed command in the
/// order it ran, the roots as the group's edits left them (Spec 5 §1, "An
/// edit changes the library or a machine's configuration and never
/// ShowState"), and the kept copies of the live list and playlist (Spec 7
/// §4), which the engine keeps between runs.
public struct RunOutcome: Equatable, Sendable {
    public var state: ShowState
    public var executed: [ExecutedCommand]
    public var library: Library
    public var machine: Machine
    public var kept: KeptCopies

    public init(state: ShowState, executed: [ExecutedCommand], library: Library, machine: Machine, kept: KeptCopies = KeptCopies()) {
        self.state = state
        self.executed = executed
        self.library = library
        self.machine = machine
        self.kept = kept
    }
}

/// Spec 2 §8 — "A command passes through four stages: parse, validate,
/// execute, log." The runner is the validate and execute stages for a group:
/// "A group validates as a whole, each command against the state the
/// commands before it leave ... one bad command rejects the group", so each
/// command is validated where it stands, then folded over the projection
/// (Spec 3 §6) so every command has its own effects and result ("Every
/// executed command yields one of `ok`, `blocked`, `noop` or `steppedOn`").
/// Nothing escapes a rejected run: the roots and the state are values.
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
///
/// Spec 5 §2 and §5 — edits run here, not in the projection, which passes
/// them through (Spec 3 §6). "Edits sent together ... apply in order as one
/// group. Every edit in the group is validated first, against the state the
/// earlier ones leave. If any one fails, none of them applies": an edit the
/// edit path refuses rejects a group from the UI, the API, the command bar
/// or OSC; held by a cue, macro, key binding or scheduler entry it "yields
/// `blocked` with its reason ... and the rest of the group runs". A fired
/// cue's edits apply once its fire is done (Spec 7 §4: what the fire read is
/// "the library the fire read, before any edit the fired cue holds is
/// applied"), logged in the cue's group after its other commands.
///
/// Spec 7 §4 — the kept copies start as the context's. They are taken again
/// whenever the pointer moves, from the library the fire read, and after the
/// group, from the library it leaves; each time only a version that still
/// holds what the pointer names replaces a copy.
public enum CommandRunner {
    /// Spec 2 §8 — validate and execute `group`. Spec 6 §6 and §7 — `settle`
    /// is the engine's say on a command's result where the result rests on
    /// what the engine holds outside ShowState (Spec 3 §2): a timer command
    /// that changes nothing is `noop`, and a `popup N set` that changes only
    /// the pending clear is `ok`. It is called once for each command the
    /// projection folds (a macro's own line and navigation lines aside), in
    /// the order they run, with the projection's result; a macro's line then
    /// follows what its commands did (Spec 2 §5). Spec 8 §2 — `media` is the
    /// engine's say on a media command it runs (`media import`, `media
    /// rebuild`): a refusal only the engine can make (`unreadable`), or the
    /// `job` an import's result carries (Spec 8 §7).
    public static func run(_ group: CommandGroup, state: ShowState, context: ProjectionContext, validate: Bool = true,
                           editing: EditContext = EditContext(),
                           settle: ((Command, CommandSource, CommandResult) -> CommandResult)? = nil,
                           media: ((MediaCommand, CommandSource) -> Result<String?, Rejection>)? = nil,
                           makeGroupID: () -> GroupID = { GroupID.random() },
                           makeUUID: () -> UUID = { UUID() }) -> Result<RunOutcome, Rejection> {
        var runner = Runner(state: state, context: context, editing: editing)
        runner.settle = settle
        runner.media = media
        var fire = group.fire
        for (index, entry) in group.commands.enumerated() {
            if validate {
                let validation = ValidationContext(library: runner.context.library, machine: runner.context.machine,
                                                   state: runner.state, source: group.source, kept: runner.context.kept)
                if let rejection = CommandValidator.validate(entry.command, guard: entry.when, context: validation) {
                    return .failure(rejection.naming(index, of: group.commands))
                }
            }
            // Spec 2 §7 — "the command runs only when it holds".
            if let condition = entry.when, !runner.holds(condition) { continue }
            runner.run(entry.command, group: group.id, source: group.source, fire: fire, nesting: .top,
                       makeGroupID: makeGroupID, makeUUID: makeUUID)
            if let refused = runner.refused { return .failure(refused.naming(index, of: group.commands)) }
            fire = nil
        }
        runner.refreshKept()
        return .success(RunOutcome(state: runner.state, executed: runner.executed,
                                   library: runner.context.library, machine: runner.context.machine, kept: runner.context.kept))
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
    /// The projection's context; its roots follow the group's edits.
    var context: ProjectionContext
    let editing: EditContext
    var executed: [ExecutedCommand] = []
    /// Spec 5 §2 — an edit sent directly that the edit path refused: the run
    /// stops and the group is rejected.
    var refused: Rejection?
    /// Spec 7 §4 — while a fire's cue commands replay, the edits they hold
    /// wait for the fire to finish, in the order they were reached.
    var deferring = false
    var deferred: [DeferredEdit] = []
    /// Spec 6 §6 and §7 — the engine's say on a folded command's result.
    var settle: ((Command, CommandSource, CommandResult) -> CommandResult)?
    /// Spec 8 §2 — the engine's say on a media command it runs.
    var media: ((MediaCommand, CommandSource) -> Result<String?, Rejection>)?

    struct DeferredEdit {
        var edit: EditCommand
        var group: GroupID
        var source: CommandSource
        var fire: FireRecord?
    }

    init(state: ShowState, context: ProjectionContext, editing: EditContext) {
        self.state = state
        self.context = context
        self.editing = editing
    }

    func holds(_ condition: Guard) -> Bool {
        condition.holds(actual: Fold(state: state, context: context).value(of: condition.variable))
    }

    /// Spec 7 §4 — the copies for the pointer as it is now, from the roots as
    /// they are now: "only a version that still holds what the pointer names".
    mutating func refreshKept() {
        context.kept = context.kept.refreshed(for: state.pointer, library: context.library, machine: context.machine)
    }

    /// One command at its place in the group (Spec 2 §5, "Macro depth"). It
    /// is folded at that same place, so the lines logged and the state that
    /// results always agree, and a cue whose commands fire cues stops at the
    /// cap rather than recursing without end.
    mutating func run(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?, nesting: Nesting,
                      makeGroupID: () -> GroupID, makeUUID: () -> UUID) {
        if case .macro(let number) = command {
            runMacro(number, command: command, group: group, source: source, fire: fire, nesting: nesting,
                     makeGroupID: makeGroupID, makeUUID: makeUUID)
            return
        }
        if case .edit(let edit) = command {
            if deferring {
                deferred.append(DeferredEdit(edit: edit, group: group, source: source, fire: fire))
            } else {
                runEdit(edit, group: group, source: source, fire: fire, makeUUID: makeUUID)
            }
            return
        }
        if case .media(let media) = command {
            runMedia(media, group: group, source: source, fire: fire)
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
            let outermost = !deferring
            deferring = true
            let firstDeferred = deferred.count
            for entry in position.cue.commands {
                // Spec 1 §6 — a guard on a cue command is reserved and not run; the command runs unguarded.
                if case .edit(let edit) = entry.command {
                    deferred.append(DeferredEdit(edit: edit, group: cueGroup, source: cueSource, fire: nil))
                    continue
                }
                run(entry.command, group: cueGroup, source: cueSource, fire: cueFire, nesting: cueNesting,
                    makeGroupID: makeGroupID, makeUUID: makeUUID)
                cueFire = nil
            }
            // A cue that holds only edits: the first of them opens its group.
            if let cueFire, let first = deferred[firstDeferred...].firstIndex(where: { $0.group == cueGroup }) {
                deferred[first].fire = cueFire
            }
            state = after
            if outermost {
                // Spec 7 §4 — "A fire's copies come from the library the fire read, before any edit the fired cue holds is applied".
                refreshKept()
                deferring = false
                let waiting = deferred
                deferred = []
                for entry in waiting {
                    runEdit(entry.edit, group: entry.group, source: entry.source, fire: entry.fire, makeUUID: makeUUID)
                }
            }
            return
        }

        state = after
        // Spec 7 §4 — "Whenever the pointer moves": a playlist load.
        if before.pointer != after.pointer, !deferring { refreshKept() }
        let result = CommandRunner.result(of: effects)
        executed.append(ExecutedCommand(group: group, source: source, command: command,
                                        result: settle?(command, source, result) ?? result, effects: effects, fire: fire))
    }

    /// Spec 5 §2 and §6 — one edit, checked and applied against the roots
    /// the commands before it left, with the live state for the checks that
    /// read it. Applied, each edit it makes is a line with its inverse (a
    /// section verb makes several, Spec 5 §4); "a value equal to the current
    /// one is a `noop`". Refused: held, a `blocked` line with the reason;
    /// sent directly, the group's rejection.
    mutating func runEdit(_ edit: EditCommand, group: GroupID, source: CommandSource, fire: FireRecord?,
                          makeUUID: () -> UUID) {
        var editing = self.editing
        editing.state = state
        switch LibraryEditor.apply(edit, library: context.library, machine: context.machine, context: editing, makeUUID: makeUUID) {
        case .success(let outcomes):
            var fire = fire
            for outcome in outcomes {
                context.library = outcome.library
                context.machine = outcome.machine
                executed.append(ExecutedCommand(group: group, source: source, command: .edit(outcome.logged),
                                                result: outcome.isNoop ? .noop : .ok, effects: [], fire: fire,
                                                inverse: outcome.inverse.map(Command.edit), changes: outcome.changes,
                                                structure: outcome.structure, warnings: outcome.warnings))
                fire = nil
            }
        case .failure(let rejection):
            guard source.kind.holdsEdits else {
                refused = rejection
                return
            }
            executed.append(ExecutedCommand(group: group, source: source, command: .edit(edit), result: .blocked,
                                            effects: [], fire: fire, refusal: rejection))
        }
    }

    /// Spec 8 §2 — a media command. "Operator lock refuses every media
    /// command but `media rebuild` with `operatorLock`" (Spec 5 §7);
    /// `media replace`, `media delete` and their inverses, "ordinary edits",
    /// are refused `notInV1` until the edit path applies them (Area 8, after
    /// the walk); `media import` and `media rebuild` are logged and not
    /// undoable, an import's result carrying its `job`. "Inside a cue, a
    /// macro, a key binding or a scheduler entry, any refusal of a media
    /// command is `blocked` with its reason and logged, and the rest of the
    /// group runs"; sent directly, a refusal rejects the group.
    mutating func runMedia(_ media: MediaCommand, group: GroupID, source: CommandSource, fire: FireRecord?) {
        var outcome: Result<String?, Rejection> = .success(nil)
        if context.machine.settings.operatorLock.enabled, media != .rebuild {
            outcome = .failure(Rejection(reason: .operatorLock, message: "the operator lock is on: \(media.cmd) is refused"))
        } else if media.isEdit {
            outcome = .failure(Rejection(reason: .notInV1, message: "\(media.cmd) isn't applied yet"))
        } else if let check = self.media {
            outcome = check(media, source)
        }
        switch outcome {
        case .success(let job):
            executed.append(ExecutedCommand(group: group, source: source, command: .media(media), result: .ok,
                                            effects: [.passthrough(.media(media))], fire: fire, job: job))
        case .failure(let rejection):
            guard source.kind.holdsEdits else {
                refused = rejection
                return
            }
            executed.append(ExecutedCommand(group: group, source: source, command: .media(media), result: .blocked,
                                            effects: [], fire: fire, refusal: rejection))
        }
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
                           nesting: Nesting, makeGroupID: () -> GroupID, makeUUID: () -> UUID) {
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
            run(entry.command, group: group, source: inner, fire: nil, nesting: nesting.insideMacro,
                makeGroupID: makeGroupID, makeUUID: makeUUID)
        }
        let acted = executed[(index + 1)...].contains { $0.result != .noop }
        executed[index].result = acted ? .ok : .noop
    }
}

extension Rejection {
    /// Spec 2 §8 — "the rejection names the command and the reason": its
    /// 0-based place in the group, its canonical text, and both in the message.
    func naming(_ index: Int, of commands: [GuardedCommand]) -> Rejection {
        var named = self
        named.index = index
        named.text = commands.indices.contains(index) ? CommandText.print(commands[index].command) : nil
        let name = named.text.map { " (\($0))" } ?? ""
        named.message = "command \(index + 1) of \(commands.count)\(name): " + message
        return named
    }
}
