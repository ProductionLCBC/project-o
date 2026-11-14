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
    /// Spec 5 §8 — on a line of an undo's group, "the group it reverses".
    public var undoes: GroupID?
    /// Spec 5 §8 — on a line of a redo's group, the undone group it runs again.
    public var redoes: GroupID?

    public init(group: GroupID, source: CommandSource, command: Command, result: CommandResult,
                effects: [Effect], fire: FireRecord? = nil, refusal: Rejection? = nil, inverse: Command? = nil,
                changes: [LibraryChange] = [], structure: [StructureChange] = [], warnings: [String] = [], job: String? = nil,
                undoes: GroupID? = nil, redoes: GroupID? = nil) {
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
        self.undoes = undoes
        self.redoes = redoes
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
    /// Spec 8 §6 and Adam's answer of 2026-11-11 (7) — held edits that wait
    /// behind a parked delete, in the order they arrived: from a held delete
    /// whose files must move first, or every held edit while a delete is
    /// parked. The engine runs them once the files have moved.
    public var parked: [HeldEdit]

    public init(state: ShowState, executed: [ExecutedCommand], library: Library, machine: Machine, kept: KeptCopies = KeptCopies(),
                parked: [HeldEdit] = []) {
        self.state = state
        self.executed = executed
        self.library = library
        self.machine = machine
        self.kept = kept
        self.parked = parked
    }
}

/// Spec 5 §2 and Spec 8 §2 — an edit a cue, macro, key binding or scheduler
/// entry holds: an `edit` or a media edit, with the group, source and fire it
/// is logged under.
public struct HeldEdit: Equatable, Sendable {
    public var command: Command
    public var group: GroupID
    public var source: CommandSource
    public var fire: FireRecord?

    public init(command: Command, group: GroupID, source: CommandSource, fire: FireRecord?) {
        self.command = command
        self.group = group
        self.source = source
        self.fire = fire
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
                           moved: [String: Result<[MediaTrashedFile], Rejection>]? = nil, parking: Bool = false,
                           makeGroupID: () -> GroupID = { GroupID.random() },
                           makeUUID: () -> UUID = { UUID() }) -> Result<RunOutcome, Rejection> {
        var runner = Runner(state: state, context: context, editing: editing)
        runner.settle = settle
        runner.media = media
        runner.moved = moved
        runner.parking = parking
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
                                   library: runner.context.library, machine: runner.context.machine, kept: runner.context.kept,
                                   parked: runner.parked))
    }

    /// Spec 8 §6 and Adam's answer of 2026-11-11 (7) — held edits that waited
    /// behind a parked delete, run now in the order they arrived, against
    /// the roots as they are now: a delete whose files moved applies with
    /// them (`moved`), one whose move failed is `blocked` with the reason,
    /// and a delete still to move parks the rest again.
    public static func runHeld(_ held: [HeldEdit], state: ShowState, context: ProjectionContext, editing: EditContext = EditContext(),
                               media: ((MediaCommand, CommandSource) -> Result<String?, Rejection>)? = nil,
                               moved: [String: Result<[MediaTrashedFile], Rejection>], makeUUID: () -> UUID = { UUID() }) -> RunOutcome {
        var runner = Runner(state: state, context: context, editing: editing)
        runner.media = media
        runner.moved = moved
        for entry in held { runner.runDeferred(entry, makeUUID: makeUUID) }
        return RunOutcome(state: runner.state, executed: runner.executed, library: runner.context.library, machine: runner.context.machine,
                          kept: runner.context.kept, parked: runner.parked)
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
    /// Spec 8 §6 — what the worker did for each delete and undelete, by id:
    /// the files it moved, or why it couldn't. Nil on the first check, before
    /// any file moves.
    var moved: [String: Result<[MediaTrashedFile], Rejection>]?
    /// Spec 8 §6 and Adam's answer of 2026-11-11 (7) — a delete is parked:
    /// held edits wait behind it, in `parked`.
    var parking = false
    var parked: [HeldEdit] = []

    typealias DeferredEdit = HeldEdit

    /// Runs a held edit once the fire that reached it is done.
    mutating func runDeferred(_ entry: DeferredEdit, makeUUID: () -> UUID) {
        switch entry.command {
        case .edit(let edit): runEdit(edit, group: entry.group, source: entry.source, fire: entry.fire, makeUUID: makeUUID)
        case .media(let media): runMedia(media, group: entry.group, source: entry.source, fire: entry.fire)
        default: break
        }
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
                deferred.append(DeferredEdit(command: command, group: group, source: source, fire: fire))
            } else {
                runEdit(edit, group: group, source: source, fire: fire, makeUUID: makeUUID)
            }
            return
        }
        if case .media(let media) = command {
            // Spec 8 §2 — replace, delete and their inverses are "ordinary edits": held, they wait for the fire as edits do.
            if deferring, media.isEdit {
                deferred.append(DeferredEdit(command: command, group: group, source: source, fire: fire))
            } else {
                runMedia(media, group: group, source: source, fire: fire)
            }
            return
        }
        if case .historyJump = command {
            // Spec 5 §8 — "`history jump N` is rejected with `notInV1`": the history view is v1.5.
            refuse(command, Rejection(reason: .notInV1, message: "history jump comes with the history view, after v1"),
                   group: group, source: source, fire: fire)
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
                if case .edit = entry.command {
                    deferred.append(DeferredEdit(command: entry.command, group: cueGroup, source: cueSource, fire: nil))
                    continue
                }
                if case .media(let media) = entry.command, media.isEdit {
                    deferred.append(DeferredEdit(command: entry.command, group: cueGroup, source: cueSource, fire: nil))
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
                for entry in waiting { runDeferred(entry, makeUUID: makeUUID) }
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

    /// Spec 5 §2 — a command the edit path refuses: held by a cue, macro, key
    /// binding or scheduler entry it "yields `blocked` with its reason ...
    /// and the rest of the group runs"; sent from the UI, the API, the
    /// command bar or OSC, the group is rejected.
    mutating func refuse(_ command: Command, _ rejection: Rejection, group: GroupID, source: CommandSource, fire: FireRecord?) {
        guard source.kind.holdsEdits else {
            refused = rejection
            return
        }
        executed.append(ExecutedCommand(group: group, source: source, command: command, result: .blocked,
                                        effects: [], fire: fire, refusal: rejection))
    }

    /// Spec 5 §2 and §6 — one edit, checked and applied against the roots
    /// the commands before it left, with the live state for the checks that
    /// read it. Applied, each edit it makes is a line with its inverse (a
    /// section verb makes several, Spec 5 §4); "a value equal to the current
    /// one is a `noop`". Refused: held, a `blocked` line with the reason;
    /// sent directly, the group's rejection.
    mutating func runEdit(_ edit: EditCommand, group: GroupID, source: CommandSource, fire: FireRecord?,
                          makeUUID: () -> UUID) {
        // Spec 8 §6, Adam's answer 7 — behind a parked delete, held edits wait in the order they arrived.
        if parking, source.kind.holdsEdits {
            parked.append(HeldEdit(command: .edit(edit), group: group, source: source, fire: fire))
            return
        }
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
        if parking, media.isEdit, source.kind.holdsEdits {
            parked.append(HeldEdit(command: .media(media), group: group, source: source, fire: fire))
            return
        }
        var outcome: Result<String?, Rejection> = .success(nil)
        if context.machine.settings.operatorLock.enabled, media != .rebuild {
            outcome = .failure(Rejection(reason: .operatorLock, message: "the operator lock is on: \(media.cmd) is refused"))
        } else if media.movesFiles {
            guard let rejection = runMove(media, group: group, source: source, fire: fire) else { return }
            outcome = .failure(rejection)
        } else if media.isEdit {
            switch applyMediaEdit(media) {
            case .success(let applied):
                // Spec 8 §2 — "ordinary edits": the roots the group's later commands read, a line with its inverse.
                context.library = applied.library
                context.machine = applied.machine
                executed.append(ExecutedCommand(group: group, source: source, command: .media(applied.logged),
                                                result: applied.isNoop ? .noop : .ok, effects: [], fire: fire,
                                                inverse: applied.inverse.map(Command.media), changes: applied.changes))
                return
            case .failure(let rejection):
                outcome = .failure(rejection)
            }
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

    /// Spec 8 §6 — `media delete` and `media undelete`: "Checks", here and the
    /// engine's (`onAir`), against the roots and state the group's earlier
    /// commands left. Held, one that passes parks: it applies once its files
    /// have moved, after the rest of its group, which runs at once (§2).
    /// Sent directly, the group is validated whole first, the delete applied
    /// without files so what follows sees it; the engine moves the files,
    /// then runs the group again, the checks with it, the delete applying
    /// with the files the worker moved ("the group applies in one step").
    /// Returns the refusal, if any.
    mutating func runMove(_ media: MediaCommand, group: GroupID, source: CommandSource, fire: FireRecord?) -> Rejection? {
        guard let id = media.ids.first else { return nil }
        switch MediaEdits.check(media, library: context.library, machine: context.machine) {
        case .failure(let rejection):
            return rejection
        case .success(false):
            // Deleting an item already deleted changes nothing.
            executed.append(ExecutedCommand(group: group, source: source, command: .media(media), result: .noop, effects: [], fire: fire))
            return nil
        case .success(true):
            break
        }
        if let check = self.media, case .failure(let rejection) = check(media, source) { return rejection }
        let resolved = moved?[id]
        if source.kind.holdsEdits, resolved == nil {
            parking = true
            parked.append(HeldEdit(command: .media(media), group: group, source: source, fire: fire))
            return nil
        }
        var files: [MediaTrashedFile] = []
        switch resolved {
        case .failure(let rejection)?: return rejection
        case .success(let done)?: files = done
        case nil: break
        }
        let applied: Result<MediaEdits.Outcome, Rejection>
        switch media {
        case .delete(let id, _):
            applied = MediaEdits.delete(id: id, files: files, at: editing.timestamp, library: context.library, machine: context.machine)
        case .undelete(let id, let sent):
            applied = MediaEdits.undelete(id: id, files: sent, restored: files, library: context.library, machine: context.machine)
        default:
            return nil
        }
        switch applied {
        case .failure(let rejection):
            return rejection
        case .success(let outcome):
            context.library = outcome.library
            context.machine = outcome.machine
            executed.append(ExecutedCommand(group: group, source: source, command: .media(outcome.logged),
                                            result: outcome.isNoop ? .noop : .ok, effects: [], fire: fire,
                                            inverse: outcome.inverse.map(Command.media), changes: outcome.changes))
            return nil
        }
    }

    /// Spec 8 §6 — a media edit against the roots the group's earlier
    /// commands left. `media delete` and `undelete` move files, so the engine
    /// applies them once its worker has; until then they are refused here.
    func applyMediaEdit(_ media: MediaCommand) -> Result<MediaEdits.Outcome, Rejection> {
        switch media {
        case .replace(let old, let new, _):
            return MediaEdits.replace(old: old, new: new, library: context.library, machine: context.machine)
        case .unreplace(let old, let new, let record):
            return MediaEdits.unreplace(old: old, new: new, record: record, library: context.library, machine: context.machine)
        default:
            return .failure(Rejection(reason: .notInV1, message: "\(media.cmd) isn't applied yet"))
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
