// OCore — Spec 5 §8 and Spec 9 §5, undo and redo; Spec 9 §6, the restore
// commands; Spec 9 §3, `system snapshot`: their place in the runner.

import Foundation

extension Command {
    /// Spec 5 §2 — "Every input path can send an edit, an undo, a redo or a
    /// restore": the three that aren't edits themselves but run through the
    /// edit path, in the order they arrived with the edits around them.
    public var isHistoryOrRestore: Bool {
        switch self {
        case .undo, .redo, .systemRestoreList, .systemRestoreSnapshot: return true
        default: return false
        }
    }
}

extension DocumentChanges {
    /// Spec 5 §8 — "every undo and redo step that touches it": the documents
    /// an applied edit changed, with those whose files it moved, removed or
    /// kept a version of.
    public static func touched(_ old: (library: Library, machine: Machine), _ new: (library: Library, machine: Machine),
                               structure: [StructureChange]) -> Set<DocumentRef> {
        var refs = Set(between(old, new))
        for change in structure {
            switch change {
            case .moveList(let uuid, _, _), .removeList(let uuid, _), .keepVersion(let uuid, _, _): refs.insert(.list(uuid))
            case .removePlaylist(let uuid, _): refs.insert(.playlist(uuid))
            case .removeDocument(let ref, _): refs.insert(ref)
            case .makeFolder, .renameFolder, .removeFolder: break
            }
        }
        return refs
    }
}

extension Runner {
    // MARK: - system snapshot (Spec 9 §3)

    /// Spec 9 §3 — "`system snapshot` always writes one; its result arrives
    /// once the file is complete and names it". The engine writes the file;
    /// here the command is refused (a full disk, Spec 9 §7; no snapshots
    /// here; a write that failed), waits for its file, or is logged with the
    /// id of the file that is complete.
    mutating func runSnapshot(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?) {
        if restores.diskFull {
            refuse(command, Rejection(reason: .diskFull, message: "the disk is full: no snapshot can be written until there is space"),
                   group: group, source: source, fire: fire)
            return
        }
        switch snapshot {
        case .unavailable:
            refuse(command, Rejection(reason: .conflict, message: "no snapshots are written here: the engine has no machine root on disk"),
                   group: group, source: source, fire: fire)
        case .pending:
            snapshots.append(HeldEdit(command: command, group: group, source: source, fire: fire))
        case .taken(let id):
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .ok, effects: [], fire: fire, snapshot: id))
        case .failed(let rejection):
            refuse(command, rejection, group: group, source: source, fire: fire)
        }
    }

    // MARK: - The restore commands (Spec 9 §6)

    /// Spec 9 §6 — "the restore is validated, the reading, checking and
    /// writing happen on a worker, and then the checks run again and the
    /// restore applies in one step". The first checks run here; then, with
    /// nothing read yet, a restore held by a cue, macro, key binding or
    /// scheduler entry parks ("the rest of the group runs at once and the
    /// restore applies after it"), and one sent directly passes for now (the
    /// engine reads, then runs its group again). With what was read, the
    /// checks run again and it applies: one line with its inverse, one undo
    /// step. A refusal is `blocked` when held and rejects the group when not.
    mutating func runRestore(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?) {
        // Behind a parked delete or restore, held ones wait in the order they arrived.
        if parking, source.kind.holdsEdits {
            parked.append(HeldEdit(command: command, group: group, source: source, fire: fire))
            return
        }
        switch applyRestore(command, group: group, source: source, fire: fire) {
        case .success(let line?):
            executed.append(line)
        case .success(nil):
            if source.kind.holdsEdits {
                parking = true
                parked.append(HeldEdit(command: command, group: group, source: source, fire: fire))
            } else if restores.materials != nil {
                refuse(command, Rejection(reason: .conflict, message: "what \(command.cmd) names changed while it was read"),
                       group: group, source: source, fire: fire)
            }
        case .failure(let rejection):
            refuse(command, rejection, group: group, source: source, fire: fire)
        }
    }

    /// One restore against the roots as they are: its line when it applied
    /// (and its undo step, unless an undo or redo is running it), nil when
    /// what it needs hasn't been read, or its refusal.
    mutating func applyRestore(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?) -> Result<ExecutedCommand?, Rejection> {
        let key: RestoreKey
        switch Restores.check(command, library: context.library, machine: context.machine, inputs: restores) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let needed): key = needed
        }
        guard let read = restores.materials?[key] else { return .success(nil) }
        let material: RestoreMaterial
        switch read {
        case .failure(let rejection): return .failure(rejection)
        case .success(let found): material = found
        }
        switch Restores.apply(command, material: material, library: context.library, machine: context.machine, state: state, inputs: restores) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let outcome):
            let before = (library: context.library, machine: context.machine)
            adopt(outcome.library, outcome.machine)
            let line = ExecutedCommand(group: group, source: source, command: outcome.logged, result: outcome.isNoop ? .noop : .ok,
                                       effects: [], fire: fire, inverse: outcome.inverse, changes: outcome.changes,
                                       structure: outcome.structure, warnings: outcome.warnings)
            remember(line, before: before)
            return .success(line)
        }
    }

    // MARK: - undo and redo (Spec 5 §8, Spec 9 §5)

    /// Spec 5 §8 — "Undo takes the top group and runs its inverses, last
    /// first, as one new group. That group is logged with source `restore`
    /// and an `undoes` field naming the group it reverses ... The undone
    /// group moves to the redo stack. Redo runs an undone group's logged
    /// commands again as one new group ... logged with source `restore` and a
    /// `redoes` field". The command's own line comes first, as a navigation
    /// line comes before its cue's group (the plan's reading): `ok` when the
    /// step ran, `noop` with nothing to undo or redo.
    ///
    /// "An undo is validated like any edit, except that it puts references
    /// back exactly as they were (§6). If an inverse would now break another
    /// rule ..., the undo is rejected with `conflict` and the group stays on
    /// the stack": all of the step applies or none of it. "Operator lock
    /// refuses undo and redo of edits (Spec 5 §7)". A step that holds a
    /// restore or moves a media file waits for the engine's worker as those
    /// commands do (Spec 9 §5).
    mutating func runHistory(_ command: Command, group: GroupID, source: CommandSource, fire: FireRecord?,
                             makeGroupID: () -> GroupID, makeUUID: () -> UUID) {
        let redo = command == .redo
        let word = redo ? "redo" : "undo"
        if parking, source.kind.holdsEdits {
            parked.append(HeldEdit(command: command, group: group, source: source, fire: fire))
            return
        }
        if context.machine.settings.operatorLock.enabled {
            refuse(command, Rejection(reason: .operatorLock, message: "the station is locked: \(word) waits until it is unlocked"),
                   group: group, source: source, fire: fire)
            return
        }
        guard let step = redo ? history.redoTop : history.undoTop else {
            executed.append(ExecutedCommand(group: group, source: source, command: command, result: .noop, effects: [], fire: fire))
            return
        }
        let commands = redo ? step.commands : Array(step.inverses.reversed())
        if needsWork(commands) {
            if source.kind.holdsEdits {
                parking = true
                parked.append(HeldEdit(command: command, group: group, source: source, fire: fire))
            } else if moved != nil || restores.materials != nil {
                refuse(command, Rejection(reason: .conflict, message: "what the \(word) needs changed while it was read"),
                       group: group, source: source, fire: fire)
            }
            // Sent directly with nothing read yet: the engine reads or moves, then runs the group again.
            return
        }

        let before = (library: context.library, machine: context.machine)
        // A step that fails partway leaves the state as it found it too: an entry a first command dropped comes back whole.
        let stateBefore = state
        let ran = makeGroupID()
        var lines: [ExecutedCommand] = []
        replaying = true
        for inner in commands {
            switch replay(inner, group: ran, source: CommandSource(kind: .restore), makeUUID: makeUUID) {
            case .success(let made):
                lines += made
            case .failure(let rejection):
                replaying = false
                context.library = before.library
                context.machine = before.machine
                state = stateBefore
                // What the machine can't do now keeps its own reason; a rule the step would break is `conflict`.
                let own: Set<RejectionReason> = [.diskFull, .noTrash, .onAir]
                let refusal = own.contains(rejection.reason) ? rejection : Rejection(
                    reason: .conflict,
                    message: "the \(word) would break a rule, so its group stays on the stack: \(rejection.reason.rawValue): \(rejection.message)")
                refuse(command, refusal, group: group, source: source, fire: fire)
                return
            }
        }
        replaying = false

        executed.append(ExecutedCommand(group: group, source: source, command: command, result: .ok, effects: [], fire: fire))
        var structure: [StructureChange] = []
        var again = UndoStep(group: ran, source: step.source)
        for var line in lines {
            if redo { line.redoes = step.group } else { line.undoes = step.group }
            executed.append(line)
            structure += line.structure
            if line.result == .ok, let inverse = line.inverse {
                again.commands.append(line.command)
                again.inverses.append(inverse)
            }
        }
        if redo {
            again.documents = DocumentChanges.touched(before, (context.library, context.machine), structure: structure)
            history.redone(as: again)
        } else {
            history.undone()
        }
    }

    /// Whether a step's commands need something the engine's worker hasn't
    /// done: a restore's file read, or a media file moved (Spec 8 §6).
    func needsWork(_ commands: [Command]) -> Bool {
        for command in commands {
            switch command {
            case .media(let media) where media.movesFiles:
                if let id = media.ids.first, moved?[id] == nil { return true }
            case .systemRestoreList, .systemRestoreSnapshot:
                // A restore its first checks refuse needs nothing read: running it says why.
                guard case .success(let key) = Restores.check(command, library: context.library, machine: context.machine, inputs: restores) else {
                    continue
                }
                if restores.materials?[key] == nil { return true }
            default:
                break
            }
        }
        return false
    }

    /// One command of an undo's or a redo's group against the roots as they
    /// are, through the same checks an edit meets, with references put back
    /// "exactly as they were" (`EditContext.restoring`). Its lines, or the
    /// refusal; nothing changes when it is refused.
    mutating func replay(_ command: Command, group: GroupID, source: CommandSource, makeUUID: () -> UUID) -> Result<[ExecutedCommand], Rejection> {
        switch command {
        case .edit(let edit):
            var editing = self.editing
            editing.state = state
            editing.restoring = true
            switch LibraryEditor.apply(edit, library: context.library, machine: context.machine, context: editing, makeUUID: makeUUID) {
            case .failure(let rejection):
                return .failure(rejection)
            case .success(let outcomes):
                var lines: [ExecutedCommand] = []
                for outcome in outcomes {
                    adopt(outcome.library, outcome.machine)
                    lines.append(ExecutedCommand(group: group, source: source, command: .edit(outcome.logged),
                                                 result: outcome.isNoop ? .noop : .ok, effects: [], inverse: outcome.inverse.map(Command.edit),
                                                 changes: outcome.changes, structure: outcome.structure, warnings: outcome.warnings))
                }
                return .success(lines)
            }
        case .media(let media) where media.isEdit:
            return replayMedia(media, group: group, source: source)
        case .systemRestoreList, .systemRestoreSnapshot:
            switch applyRestore(command, group: group, source: source, fire: nil) {
            case .failure(let rejection): return .failure(rejection)
            case .success(let line?): return .success([line])
            case .success(nil):
                return .failure(Rejection(reason: .conflict, message: "what \(command.cmd) names wasn't read"))
            }
        default:
            return .failure(Rejection(reason: .conflict, message: "\(command.cmd) is not an edit, so it can't be run again"))
        }
    }

    /// Spec 8 §6 — a media edit of an undo's or redo's group: `replace` and
    /// `unreplace` against the indexes, `delete` and `undelete` with the
    /// files the engine's worker moved for them.
    mutating func replayMedia(_ media: MediaCommand, group: GroupID, source: CommandSource) -> Result<[ExecutedCommand], Rejection> {
        let applied: Result<MediaEdits.Outcome, Rejection>
        if media.movesFiles {
            guard let id = media.ids.first else { return .success([]) }
            switch MediaEdits.check(media, library: context.library, machine: context.machine) {
            case .failure(let rejection): return .failure(rejection)
            case .success(false):
                return .success([ExecutedCommand(group: group, source: source, command: .media(media), result: .noop, effects: [])])
            case .success(true): break
            }
            if let check = self.media, case .failure(let rejection) = check(media, source) { return .failure(rejection) }
            let files: [MediaTrashedFile]
            switch moved?[id] {
            case .failure(let rejection)?: return .failure(rejection)
            case .success(let done)?: files = done
            case nil: return .failure(Rejection(reason: .conflict, message: "the files of \(id) weren't moved"))
            }
            switch media {
            case .delete(let id, _):
                applied = MediaEdits.delete(id: id, files: files, at: editing.timestamp, library: context.library, machine: context.machine)
            case .undelete(let id, let sent):
                applied = MediaEdits.undelete(id: id, files: sent, restored: files, library: context.library, machine: context.machine)
            default:
                return .success([])
            }
        } else {
            applied = applyMediaEdit(media)
        }
        switch applied {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let outcome):
            adopt(outcome.library, outcome.machine)
            return .success([ExecutedCommand(group: group, source: source, command: .media(outcome.logged),
                                             result: outcome.isNoop ? .noop : .ok, effects: [], inverse: outcome.inverse.map(Command.media),
                                             changes: outcome.changes)])
        }
    }
}
