import Foundation
import XCTest
@testable import OCore

/// Spec 5 §8 and Spec 9 §5 at the runner — "`undo` runs the top group's
/// logged inverses, last first, as one group with source `restore` and an
/// `undoes` field; `redo` runs an undone group's commands again with
/// `redoes`; a new edit clears the redo stack. An undo that would break a
/// rule fails with `conflict` and stays on top"; "Operator lock refuses undo
/// and redo of edits". Spec 5 §11, "Undo and redo", "Groups", "References",
/// "Lock" and "Edits held by cues", as far as the runner decides them; and
/// Spec 9 §6 and §3, the restore commands and `system snapshot` at the runner.
final class UndoRunnerTests: XCTestCase {
    typealias F = FixtureLibrary

    var library: Library!
    var machine: Machine!
    var state: ShowState!
    var history = UndoHistory()
    var groups = 0
    var uuids = 0
    var restores = RestoreInputs()
    var snapshot = SnapshotAnswer.unavailable
    var first: (library: Library, machine: Machine)!

    override func setUp() {
        let (library, machine, _) = F.load()
        self.library = library
        self.machine = machine
        self.machine.settings.libraryMode = .writable
        state = ShowState.fresh(library: library, machine: self.machine)
        history = UndoHistory()
        first = (library, self.machine)
        groups = 0
        uuids = 0
        restores = RestoreInputs()
        snapshot = .unavailable
    }

    func commands(_ texts: [String]) -> [GuardedCommand] {
        texts.compactMap { text in
            switch CommandText.parse(text, options: ParseOptions(library: library, machine: machine)) {
            case .success(let entry): return entry
            case .failure(let rejection):
                XCTFail("\(text): \(rejection.message)")
                return nil
            }
        }
    }

    /// One group through the runner, as the engine runs it: applied, its roots, state and history are kept.
    @discardableResult
    func send(_ texts: [String], source: SourceKind = .ui) -> Result<RunOutcome, Rejection> {
        groups += 1
        let group = CommandGroup(id: GroupID(String(format: "g-%08x", groups)), source: CommandSource(kind: source), commands: commands(texts))
        let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: source))
        let result = CommandRunner.run(group, state: state, context: context, editing: EditContext(today: "2026-11-08"),
                                       history: history, restores: restores, snapshot: snapshot,
                                       makeGroupID: { self.groups += 1; return GroupID(String(format: "g-%08x", self.groups)) },
                                       makeUUID: { self.uuids += 1; return F.uuid("e0e0", self.uuids) })
        if case .success(let outcome) = result {
            library = outcome.library
            machine = outcome.machine
            state = outcome.state
            history = outcome.history
        }
        return result
    }

    @discardableResult
    func send(_ text: String, source: SourceKind = .ui) -> Result<RunOutcome, Rejection> {
        send([text], source: source)
    }

    func title(_ number: Int) -> String? { library.list(number: number)?.title }

    func reason(_ result: Result<RunOutcome, Rejection>) -> RejectionReason? {
        if case .failure(let rejection) = result { return rejection.reason }
        return nil
    }

    // MARK: - Undo and redo

    /// "A sequence of groups undone back to the start returns the fixture library to its first state,
    /// apart from list versions. Redone, it returns to the end state with the same numbers and uuids."
    func test_groupsUndoneBackToTheStartAndRedoneToTheEnd() throws {
        send("edit list 42 title \"One\"")
        send(["edit list 7 title \"Two\"", "edit list 42 ccli \"99\""])
        send("edit list create {\"title\": \"A New Song\"}")
        send("edit playlist create \"Evening\"")
        let end = (library: library!, machine: machine!)
        XCTAssertEqual(history.undo.count, 4)
        let made = try XCTUnwrap(library.lists.first { $0.title == "A New Song" })

        for _ in 0..<4 { XCTAssertNil(reason(send("undo"))) }
        XCTAssertEqual(library.lists, first.library.lists)
        XCTAssertEqual(machine.playlists, first.machine.playlists)
        XCTAssertNil(history.undoTop)
        XCTAssertEqual(history.redo.count, 4)
        XCTAssertEqual(try send("undo").get().executed.map(\.result), [.noop], "nothing left to undo")

        for _ in 0..<4 { XCTAssertNil(reason(send("redo"))) }
        XCTAssertEqual(library.lists, end.library.lists)
        XCTAssertEqual(machine.playlists, end.machine.playlists)
        XCTAssertEqual(library.lists.first { $0.title == "A New Song" }?.uuid, made.uuid, "the same uuid")
        XCTAssertEqual(library.lists.first { $0.title == "A New Song" }?.number, made.number, "the same number")
        XCTAssertNil(history.redoTop)
        XCTAssertEqual(try send("redo").get().executed.map(\.result), [.noop], "nothing left to redo")
    }

    /// "Undo ... as one new group. That group is logged with source `restore` and an `undoes` field naming
    /// the group it reverses"; the command's own line comes first (the plan's reading).
    func test_anUndoIsItsOwnLineThenAGroupWithSourceRestoreAndUndoes() throws {
        let edited = try send(["edit list 42 title \"One\"", "edit list 42 ccli \"99\""]).get()
        let made = try XCTUnwrap(edited.executed.first?.group)
        let outcome = try send("undo", source: .osc).get()
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["history.undo", "edit.set", "edit.set"])
        let own = outcome.executed[0]
        XCTAssertEqual(own.result, .ok)
        XCTAssertEqual(own.source.kind, .osc)
        XCTAssertNil(own.inverse)
        XCTAssertNil(own.undoes)
        let lines = Array(outcome.executed.dropFirst())
        XCTAssertEqual(Set(lines.map(\.source.kind)), [.restore])
        XCTAssertEqual(Set(lines.map(\.group)).count, 1)
        XCTAssertNotEqual(lines[0].group, own.group, "one new group")
        XCTAssertEqual(lines.map(\.undoes), [made, made])
        XCTAssertEqual(lines.map(\.redoes), [nil, nil])
        // "last first": the ccli goes back before the title.
        XCTAssertEqual(lines[0].command, .edit(EditCommand(.list(42), .set(path: "ccli", value: .string("18723")))))
        XCTAssertEqual(lines[1].command, .edit(EditCommand(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness")))))
        XCTAssertNotNil(lines[0].inverse, "the log keeps both")
        XCTAssertEqual(AppliedEdits.groups(in: outcome.executed).map(\.cause), [.undo])
        XCTAssertEqual(LogEntry(lines[0], seq: 1, ts: "t").undoes, made)
    }

    /// "Redo runs an undone group's logged commands again as one new group ... with source `restore` and
    /// a `redoes` field". The step that comes back is the redo's group, from where the edits first came.
    func test_aRedoRunsTheCommandsAgainWithRedoes() throws {
        let edited = try send("edit list 42 title \"One\"", source: .commandbar).get()
        let made = try XCTUnwrap(edited.executed.first?.group)
        send("undo")
        let outcome = try send("redo").get()
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["history.redo", "edit.set"])
        XCTAssertEqual(outcome.executed[1].redoes, made)
        XCTAssertNil(outcome.executed[1].undoes)
        XCTAssertEqual(outcome.executed[1].source.kind, .restore)
        XCTAssertEqual(title(42), "One")
        XCTAssertEqual(AppliedEdits.groups(in: outcome.executed).map(\.cause), [.redo])
        XCTAssertEqual(history.undoTop?.group, outcome.executed[1].group)
        XCTAssertEqual(history.undoTop?.source.kind, .commandbar)
        // Undone again, the `undoes` names the group that applied it last.
        XCTAssertEqual(try send("undo").get().executed[1].undoes, outcome.executed[1].group)
        XCTAssertEqual(title(42), "Great Is Thy Faithfulness")
    }

    /// "Any new edit clears the redo stack, so history stays linear".
    func test_aNewEditClearsTheRedoStack() throws {
        send("edit list 42 title \"One\"")
        send("undo")
        XCTAssertNotNil(history.redoTop)
        send("edit list 7 title \"Two\"")
        XCTAssertNil(history.redoTop)
        XCTAssertEqual(try send("redo").get().executed.map(\.result), [.noop])
        XCTAssertEqual(title(42), "Great Is Thy Faithfulness")
    }

    /// An undo and a redo push no step of their own, and a `noop` edit none either.
    func test_onlyAppliedEditsMakeSteps() {
        send("edit list 42 title \"Great Is Thy Faithfulness\"")    // the value it has
        XCTAssertNil(history.undoTop)
        send("channel 1 clear")
        XCTAssertNil(history.undoTop)
        send("edit list 42 title \"One\"")
        send("undo")
        send("redo")
        XCTAssertEqual(history.undo.count, 1)
        XCTAssertEqual(history.redo.count, 0)
    }

    // MARK: - Groups (Spec 5 §11)

    /// "A split, a merge and each section verb make one group, one log group and one undo step." The
    /// section verbs are built (Area 9); split and merge come with the editor that sends them.
    func test_aSectionVerbIsOneUndoStep() throws {
        let cue = F.list42Cues[1].uuidString.lowercased()
        let before = library.list(number: 42)
        let section = try send("edit list 42 cue \(cue) section duplicate").get()
        XCTAssertGreaterThan(section.executed.count, 1, "one group of cue edits")
        XCTAssertEqual(Set(section.executed.map(\.group)).count, 1)
        XCTAssertEqual(history.undo.count, 1, "one undo step for the section's cue edits")
        XCTAssertEqual(history.undoTop?.commands.count, section.executed.count)
        XCTAssertNotEqual(library.list(number: 42)?.cues.count, before?.cues.count)
        send("undo")
        XCTAssertEqual(library.list(number: 42), before)
        send("redo")
        XCTAssertEqual(library.list(number: 42)?.cues.count, (before?.cues.count ?? 0) + section.executed.count)
    }

    /// "A cue holding an edit changes the library when it fires, as one undo step per fire."
    func test_aCueHoldingEditsIsOneUndoStepPerFire() throws {
        library.lists[1].cues[0].commands += [
            GuardedCommand(.edit(EditCommand(.list(7), .set(path: "ccli", value: .string("1"))))),
            GuardedCommand(.edit(EditCommand(.list(7), .set(path: "title", value: .string("Sung"))))),
        ]
        send("list 42 cue 1", source: .osc)
        XCTAssertEqual(history.undo.count, 1)
        XCTAssertEqual(history.undoTop?.commands.count, 2)
        XCTAssertEqual(history.undoTop?.source.kind, .cue)
        send("undo")
        XCTAssertEqual(library.list(number: 7), first.library.list(number: 7))
    }

    /// An `undo` inside a macro behaves as one sent alone, and the rest of the macro runs.
    func test_anUndoInAMacroBehavesAsOneSentAlone() throws {
        send("edit list 42 title \"One\"")
        machine.macros[0].commands = [GuardedCommand(.undo), GuardedCommand(.channelLock(channel: .number(1), locked: true))]
        let outcome = try send("macro \(machine.macros[0].number)", source: .key).get()
        XCTAssertEqual(title(42), "Great Is Thy Faithfulness")
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["macro.run", "history.undo", "edit.set", "channel.lock"])
        XCTAssertEqual(outcome.state.channels[1]?.lock, true)
        XCTAssertNotNil(history.redoTop)
    }

    // MARK: - Conflict (Spec 5 §8)

    /// "If an inverse would now break another rule (its number has since been taken, say), the undo is
    /// rejected with `conflict` and the group stays on the stack."
    func test_anUndoThatWouldBreakARuleIsConflictAndTheGroupStaysOnTop() throws {
        send("edit list 7 renumber 70")
        // Taken since, behind the history's back (a file that arrived, say): list 42 now holds 7.
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        library.lists[index].number = 7
        let top = history.undoTop
        let direct = send("undo")
        XCTAssertEqual(reason(direct), .conflict)
        XCTAssertEqual(history.undoTop, top, "stays on top")
        XCTAssertNil(history.redoTop)
        XCTAssertNotNil(library.list(number: 70))

        // Held, it is `blocked` with the reason and the rest of the group runs.
        let held = try send(["undo", "channel 1 lock"], source: .key).get()
        XCTAssertEqual(held.executed.map(\.result), [.blocked, .ok])
        XCTAssertEqual(held.executed[0].refusal?.reason, .conflict)
        XCTAssertEqual(history.undoTop, top)
    }

    /// All of a step applies or none of it.
    func test_aStepThatFailsPartWayChangesNothing() throws {
        send(["edit list 42 title \"One\"", "edit list 7 renumber 70"])
        let index = try XCTUnwrap(library.lists.firstIndex { $0.number == 42 })
        // The renumber's inverse (70 back to 7) is refused; the title's would have applied.
        var blocker = library.lists[index]
        blocker.uuid = UUID()
        blocker.number = 7
        library.lists.append(blocker)
        let before = library
        XCTAssertEqual(reason(send("undo")), .conflict)
        XCTAssertEqual(library, before)
        XCTAssertEqual(title(42), "One")
    }

    /// Spec 5 §11, References — "An undo that restores a broken reference succeeds, and the reference report flags it."
    func test_anUndoThatRestoresABrokenReferenceSucceeds() throws {
        let item = F.sundayItems[1].uuidString.lowercased()
        let playlist = F.playlistUuid.uuidString.lowercased()
        // The item that links list 42 goes; then the list itself goes; undoing the item's removal brings
        // back a link to a list that no longer exists.
        send("edit playlist \(playlist) item \(item) delete")
        let step = history.undoTop
        send("edit list 42 delete")
        // Undo only the first group: take the list's deletion off the stack as a reload would.
        history.drop(touching: [.list(F.listUuid(42))])
        XCTAssertEqual(history.undoTop, step)
        XCTAssertNil(reason(send("undo")))
        XCTAssertTrue(machine.playlist(uuid: F.playlistUuid)?.items.contains { $0.uuid == F.sundayItems[1] } ?? false)
        XCTAssertFalse(Validator.validate(library: library, machine: machine).issues(.missingList).isEmpty)
    }

    // MARK: - Lock (Spec 5 §7)

    /// "With operator lock on, every edit, undo, redo and restore is refused from `ui`, `api` and `osc`,
    /// while runtime commands pass."
    func test_operatorLockRefusesUndoRedoAndRestoresFromEverySource() throws {
        send("edit list 42 title \"One\"")
        send("edit list 7 title \"Two\"")
        send("undo")
        machine.settings.operatorLock.enabled = true
        for source: SourceKind in [.ui, .api, .osc] {
            XCTAssertEqual(reason(send("undo", source: source)), .operatorLock, "\(source)")
            XCTAssertEqual(reason(send("redo", source: source)), .operatorLock, "\(source)")
            XCTAssertEqual(reason(send("system restore list 42 version 16", source: source)), .operatorLock, "\(source)")
            XCTAssertEqual(reason(send("system restore snapshot \"2026-11-08-085959\"", source: source)), .operatorLock, "\(source)")
            XCTAssertNil(reason(send("channel 1 clear", source: source)), "\(source)")
        }
        XCTAssertEqual(title(42), "One")
        XCTAssertEqual(title(7), "Doxology")
        // Held, each is `blocked` and the rest of the group runs.
        let held = try send(["undo", "redo", "system restore list 42 version 16", "channel 1 lock"], source: .scheduler).get()
        XCTAssertEqual(held.executed.map(\.result), [.blocked, .blocked, .blocked, .ok])
        XCTAssertEqual(Set(held.executed.prefix(3).compactMap { $0.refusal?.reason }), [.operatorLock])
    }

    // MARK: - The restore commands (Spec 9 §6)

    func kept() throws -> List {
        var list = try XCTUnwrap(first.library.list(number: 42))
        list.title = "As It Was"
        list.version = 16
        return list
    }

    /// "In a group sent from the UI, the API, the command bar or OSC, the whole group waits and applies
    /// with it, or is rejected with it": with nothing read yet the restore passes its first checks and
    /// applies nothing; with what the worker read, it applies as one edit group with its inverse.
    func test_aListRestoreSentDirectlyAppliesOnceItsVersionIsRead() throws {
        let before = library
        let waiting = try send(["system restore list 42 version 16", "edit list 7 title \"With It\""]).get()
        XCTAssertEqual(waiting.executed.map(\.command.cmd), ["edit.set"], "the first pass: only what needs nothing read")
        // The engine keeps none of a first pass.
        library = before
        history = UndoHistory()

        restores.materials = [.version(list: F.listUuid(42), version: 16): .success(.version(try kept(), kept: [16]))]
        let outcome = try send(["system restore list 42 version 16", "edit list 7 title \"With It\""]).get()
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["system.restoreList", "edit.set"])
        XCTAssertEqual(outcome.executed[0].result, .ok)
        XCTAssertEqual(outcome.executed[0].inverse, .systemRestoreList(list: 42, version: 17))
        XCTAssertEqual(LogEntry(outcome.executed[0], seq: 1, ts: "t").kind, .edit)
        XCTAssertEqual(title(42), "As It Was")
        XCTAssertEqual(AppliedEdits.groups(in: outcome.executed).map(\.cause), [.restore], "its `library` event has cause `restore`")
        XCTAssertEqual(history.undo.count, 1, "one group, one undo step")
        XCTAssertEqual(history.undoTop?.inverses.first, .systemRestoreList(list: 42, version: 17))
    }

    /// "Held by a cue, macro, key binding or scheduler entry, the rest of the group runs at once and the
    /// restore applies after it, or is logged `blocked` if it fails".
    func test_aHeldRestoreParksAndTheRestOfTheGroupRunsAtOnce() throws {
        let outcome = try send(["system restore snapshot \"2026-11-08-085959\"", "edit list 7 title \"Later\"", "channel 1 lock"],
                               source: .key).get()
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["channel.lock"], "runtime commands run at once")
        XCTAssertEqual(outcome.parked.map(\.command.cmd), ["system.restoreSnapshot", "edit.set"], "the edits behind it wait in order")

        // The worker couldn't read it: the restore is `blocked`, and the edit behind it lands.
        restores.materials = [.snapshot("2026-11-08-085959"): .failure(Rejection(reason: .unknownObject, message: "no such file"))]
        let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: .key))
        let later = CommandRunner.runHeld(outcome.parked, state: state, context: context, moved: [:], history: history, restores: restores)
        XCTAssertEqual(later.executed.map(\.result), [.blocked, .ok])
        XCTAssertEqual(later.executed[0].refusal?.reason, .unknownObject)
        XCTAssertEqual(later.library.list(number: 7)?.title, "Later")
    }

    /// A read that failed, or a check that fails once it is read, rejects a group sent directly.
    func test_aRestoreWhoseFileIsMissingRejectsItsGroup() throws {
        restores.materials = [.version(list: F.listUuid(42), version: 3): .failure(Rejection(reason: .unknownObject, message: "list 42 has no version 3"))]
        let result = send(["edit list 7 title \"Never\"", "system restore list 42 version 3"])
        XCTAssertEqual(reason(result), .unknownObject)
        XCTAssertEqual(title(7), "Doxology")
        XCTAssertNil(history.undoTop)
    }

    /// Spec 9 §5 — "Undoing a restore runs the restore that is its inverse (§6)": it waits for its own read.
    func test_undoingARestoreNeedsItsInverseRead() throws {
        restores.materials = [.version(list: F.listUuid(42), version: 16): .success(.version(try kept(), kept: [16]))]
        send("system restore list 42 version 16")
        XCTAssertEqual(title(42), "As It Was")

        // Nothing read for the inverse yet: sent directly it passes for now; held it parks.
        restores.materials = nil
        XCTAssertEqual(try send("undo").get().executed.count, 0)
        XCTAssertEqual(title(42), "As It Was")
        XCTAssertEqual(try send("undo", source: .key).get().parked.map(\.command), [.undo])

        var before = try XCTUnwrap(first.library.list(number: 42))
        before.version = 17
        restores.materials = [.version(list: F.listUuid(42), version: 17): .success(.version(before, kept: [16, 17]))]
        let outcome = try send("undo").get()
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["history.undo", "system.restoreList"])
        XCTAssertEqual(outcome.executed[1].source.kind, .restore)
        XCTAssertNotNil(outcome.executed[1].undoes)
        XCTAssertEqual(title(42), "Great Is Thy Faithfulness", "undo brings back exactly what was replaced")
        XCTAssertEqual(library.list(number: 42)?.cues, first.library.list(number: 42)?.cues)
        XCTAssertEqual(AppliedEdits.groups(in: outcome.executed).map(\.cause), [.undo])
    }

    // MARK: - system snapshot (Spec 9 §3)

    /// "`system snapshot` always writes one; its result arrives once the file is complete and names it".
    func test_systemSnapshotIsLoggedWithItsIdOnceTheFileIsComplete() throws {
        snapshot = .pending
        let waiting = try send(["system snapshot", "channel 1 lock"], source: .key).get()
        XCTAssertEqual(waiting.executed.map(\.command.cmd), ["channel.lock"], "the rest runs at once")
        XCTAssertEqual(waiting.snapshots.map(\.command), [.systemSnapshot])

        snapshot = .taken("2026-11-08-085959")
        let outcome = try send("system snapshot").get()
        XCTAssertEqual(outcome.executed.map(\.result), [.ok])
        XCTAssertEqual(outcome.executed[0].snapshot, "2026-11-08-085959")
        XCTAssertNil(outcome.executed[0].inverse)
        XCTAssertNil(history.undoTop, "a snapshot is not an edit")
    }

    /// A write that failed rejects it (Adam's answer of 2026-11-14); a full disk is `diskFull` (Spec 9 §7);
    /// held, either is `blocked` and the rest runs.
    func test_aSnapshotThatCannotBeWrittenIsRefused() throws {
        snapshot = .failed(Rejection(reason: .conflict, message: "the folder can't be written"))
        XCTAssertEqual(reason(send("system snapshot")), .conflict)
        let held = try send(["system snapshot", "channel 1 lock"], source: .scheduler).get()
        XCTAssertEqual(held.executed.map(\.result), [.blocked, .ok])

        snapshot = .pending
        restores.diskFull = true
        XCTAssertEqual(reason(send("system snapshot")), .diskFull)
        XCTAssertEqual(reason(send("system restore snapshot \"2026-11-08-085959\"")), .diskFull)
        XCTAssertEqual(reason(send("system restore list 42 version 16")), .diskFull)

        restores.diskFull = false
        snapshot = .unavailable
        XCTAssertEqual(reason(send("system snapshot")), .conflict, "an engine with no machine root on disk")
    }
}
