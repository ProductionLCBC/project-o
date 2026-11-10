import Foundation
import XCTest
@testable import OCore

/// Spec 5 §2 and §5 at the runner, with Spec 2 §8's group rule. "Groups.
/// Edits sent together ... apply in order as one group. Every edit in the
/// group is validated first, against the state the earlier ones leave. If any
/// one fails, none of them applies"; "A failing edit doesn't stop the cue":
/// held by a cue, a macro, a key binding or the scheduler, a refused edit
/// "yields `blocked` with its reason ... and the rest of the group runs";
/// "Lookahead never edits". Spec 5 §11 — "Edits held by cues. A cue holding an
/// edit changes the library when it fires ... Under operator lock that edit
/// is `blocked` and the rest of the cue runs. Lookahead and thumbnails never
/// run it."
final class EditGroupTests: XCTestCase {
    typealias F = FixtureLibrary

    static func u(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    var library: Library!
    var machine: Machine!

    override func setUp() {
        let (library, machine, _) = F.load()
        self.library = library
        self.machine = machine
        self.machine.settings.libraryMode = .writable
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

    func run(_ texts: [String], source: SourceKind = .ui, state: ShowState? = nil) -> Result<RunOutcome, Rejection> {
        var ids = 0
        var uuids = 0
        let group = CommandGroup(id: GroupID("g-00000000"), source: CommandSource(kind: source), commands: commands(texts))
        let context = ProjectionContext(frame: 100, library: library, machine: machine, source: CommandSource(kind: source))
        return CommandRunner.run(group, state: state ?? ShowState.fresh(library: library, machine: machine), context: context,
                                 editing: EditContext(today: "2026-11-08"),
                                 makeGroupID: { ids += 1; return GroupID(String(format: "g-%08x", ids)) },
                                 makeUUID: { uuids += 1; return F.uuid("e0e0", uuids) })
    }

    // MARK: - Groups

    /// Spec 2 §8 — "each command against the state the commands before it
    /// leave": an edit's change is there for the commands after it.
    func test_editsApplyInOrderAndLaterCommandsSeeThem() throws {
        let outcome = try run(["edit playlist create \"Easter\"", "playlist \"easter\"",
                               "edit list 57 create", "edit list 57 title \"Be Thou My Vision\""]).get()
        XCTAssertEqual(outcome.machine.playlist(titled: "Easter")?.uuid, F.uuid("e0e0", 1))
        XCTAssertEqual(outcome.state.pointer?.playlist, F.uuid("e0e0", 1), "the playlist the group made is the one it loads")
        XCTAssertEqual(outcome.library.list(number: 57)?.title, "Be Thou My Vision")
        XCTAssertEqual(outcome.executed.map(\.result), [.ok, .ok, .ok, .ok])
        XCTAssertEqual(Set(outcome.executed.map(\.group)), [GroupID("g-00000000")], "one group")
        XCTAssertEqual(outcome.executed[0].inverse, .edit(EditCommand(.playlist(F.uuid("e0e0", 1)), .delete)))
        XCTAssertEqual(outcome.executed[2].command, .edit(EditCommand(.list(57), .create(
            body: .object(["uuid": .string(Self.u(F.uuid("e0e0", 2)))]), folder: nil, title: nil))), "what the engine picked")
    }

    /// Spec 2 §8 — "A group validates as a whole, each command against the
    /// state the commands before it leave, so `playlist "TITLE"` then `item N
    /// cue M` fires a cue of that playlist (Spec 10 §6)".
    func test_eachCommandIsValidatedAgainstTheStateTheOnesBeforeItLeave() throws {
        let outcome = try run(["playlist \"Sunday Night\"", "item 2 cue 1"]).get()
        XCTAssertEqual(outcome.state.pointer?.playlist, F.sundayNightUuid)
        XCTAssertEqual(outcome.state.pointer?.cueUuid, F.list42Cues[0])
        if case .success = run(["item 2 cue 1", "playlist \"Sunday Night\""]) {
            XCTFail("before the load no playlist is live")
        }
    }

    /// "If any one fails, none of them applies (Spec 2 §8)"; Spec 5 §6 —
    /// rejected, "answered at the API or the command bar only".
    func test_aGroupWithOneRefusedEditAppliesNothing() {
        for source in [SourceKind.ui, .api, .osc, .commandbar] {
            switch run(["channel 2 clear", "edit list 42 title \"New\"", "edit list 99 title \"x\""], source: source) {
            case .success: XCTFail("\(source): a refused edit rejects the group")
            case .failure(let rejection):
                XCTAssertEqual(rejection.reason, .unknownObject, "\(source)")
                XCTAssertEqual(rejection.index, 2)
                XCTAssertTrue(rejection.message.hasPrefix("command 3 of 3 (edit list 99 title \"x\"): "), rejection.message)
            }
        }
    }

    /// "A cue, macro, key binding or scheduler entry may run an edit that
    /// lock, library mode or a since-changed library refuses. That edit yields
    /// `blocked` with its reason, like a write to a locked channel ..., and
    /// the rest of the group runs".
    func test_aHeldEditThatIsRefusedIsBlockedAndTheRestRuns() throws {
        for source in [SourceKind.key, .scheduler, .startup] {
            let outcome = try run(["edit list 99 title \"x\"", "edit list 42 title \"New\""], source: source).get()
            XCTAssertEqual(outcome.executed.map(\.result), [.blocked, .ok], "\(source)")
            XCTAssertEqual(outcome.executed[0].refusal?.reason, .unknownObject)
            XCTAssertNil(outcome.executed[0].inverse)
            XCTAssertEqual(outcome.library.list(number: 42)?.title, "New")
        }
        // A macro's edit is held whatever entered the macro (Spec 2 §5).
        library.macros[0].commands = [GuardedCommand(.edit(EditCommand(.list(99), .set(path: "title", value: .string("x"))))),
                                      GuardedCommand(.channelClear(channel: .number(2)))]
        let outcome = try run(["macro 1"], source: .ui).get()
        XCTAssertEqual(outcome.executed.map(\.result), [.ok, .blocked, .noop])
        XCTAssertEqual(outcome.executed[1].source.kind, .macro)
    }

    /// Spec 2 §8 — validation still rejects a runtime command that names
    /// nothing, from any source; only an edit's refusal is held.
    func test_aBadRuntimeCommandStillRejectsAHeldGroup() {
        if case .success = run(["edit list 42 title \"New\"", "channel 9 clear"], source: .key) {
            XCTFail("channel 9 does not exist")
        }
    }

    // MARK: - Edits held by cues

    /// "An edit in a cue is permanent. Firing it changes the library for
    /// good" — after the cue's commands, which read the library the fire read
    /// (Spec 7 §4: copies "from the library the fire read, before any edit
    /// the fired cue holds is applied").
    func test_aCueHoldingAnEditChangesTheLibraryWhenItFiresAfterItsCommands() throws {
        library.lists[1].cues[0].commands.insert(
            GuardedCommand(.edit(EditCommand(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness (sung)"))))), at: 0)
        let outcome = try run(["list 42 cue 1"], source: .osc).get()
        XCTAssertEqual(outcome.library.list(number: 42)?.title, "Great Is Thy Faithfulness (sung)")
        let cue = outcome.executed.filter { $0.source.kind == .cue }
        XCTAssertEqual(cue.map(\.command.cmd), ["channel.write", "channel.write", "edit.set"], "the edit runs after the cue's commands")
        XCTAssertEqual(cue.first?.fire, FireRecord(listTitle: "Great Is Thy Faithfulness", ccli: "18723"), "the fire record reads the fire's library")
        XCTAssertNil(cue.last?.fire)
        XCTAssertEqual(cue.last?.inverse, .edit(EditCommand(.list(42), .set(path: "title", value: .string("Great Is Thy Faithfulness")))))
        XCTAssertEqual(Set(cue.map(\.group)).count, 1, "the cue's own group")
        XCTAssertEqual(outcome.state.channels[2]?.content, .text(TextInstance(fields: ["body": "Great is Thy faithfulness,\nO God my Father"])))
    }

    /// "Under operator lock that edit is `blocked` and the rest of the cue runs."
    func test_underOperatorLockACuesEditIsBlockedAndTheCueStillRuns() throws {
        library.lists[1].cues[0].commands.append(
            GuardedCommand(.edit(EditCommand(.list(42), .set(path: "title", value: .string("x"))))))
        machine.settings.operatorLock.enabled = true
        let outcome = try run(["list 42 cue 1"], source: .ui).get()
        XCTAssertEqual(outcome.library.list(number: 42)?.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(outcome.executed.last?.result, .blocked)
        XCTAssertEqual(outcome.executed.last?.refusal?.reason, .operatorLock)
        XCTAssertEqual(outcome.state.pointer?.cueUuid, F.list42Cues[0], "the cue still counts as fired")
        XCTAssertNotEqual(outcome.state.channels[2]?.content, .empty, "and its writes ran")
    }

    /// A cue holding only an edit carries the fire record on that line.
    func test_aCueHoldingOnlyAnEditCarriesTheFireRecord() throws {
        library.lists[1].cues[1].commands = [GuardedCommand(.edit(EditCommand(.list(7), .set(path: "ccli", value: .string("1")))))]
        let outcome = try run(["list 42 cue 2"], source: .ui).get()
        XCTAssertEqual(outcome.executed.last?.command.cmd, "edit.set")
        XCTAssertEqual(outcome.executed.last?.fire?.listTitle, "Great Is Thy Faithfulness")
    }

    /// "Lookahead never edits. The projection passes edits through untouched".
    func test_lookaheadNeverEdits() {
        library.lists[1].cues[1].commands.append(GuardedCommand(.edit(EditCommand(.list(42), .delete))))
        var state = ShowState.fresh(library: library, machine: machine)
        state.pointer = LivePointer(listUuid: F.listUuid(42), cueUuid: F.list42Cues[0])
        let context = ProjectionContext(frame: 0, library: library, machine: machine, source: CommandSource(kind: .engine))
        let ahead = lookahead(state, steps: 1, context: context)
        XCTAssertEqual(ahead?.pointer?.cueUuid, F.list42Cues[1])
        XCTAssertNotNil(context.library.list(number: 42), "the context is a value; nothing reaches the library")
        let (_, effects) = project(state, [.edit(EditCommand(.list(42), .delete))], context: context)
        XCTAssertEqual(effects, [.passthrough(.edit(EditCommand(.list(42), .delete)))])
    }

    // MARK: - Results and the log

    /// Spec 5 §6 — results: `ok` with its inverse, `noop` (logged), a section
    /// verb as the cue edits it runs, one group.
    func test_resultsAndTheLogEntriesTheyMake() throws {
        let c1 = Self.u(F.list42Cues[0])
        let outcome = try run(["edit list 42 title \"Great Is Thy Faithfulness\"", "edit list 42 cue \(c1) section remove"]).get()
        XCTAssertEqual(outcome.executed.map(\.result), [.noop, .ok, .ok, .ok])
        XCTAssertEqual(outcome.executed.map(\.command.cmd), ["edit.set", "edit.remove", "edit.remove", "edit.remove"])
        let entries = LogEntry.entries(for: outcome, firstSeq: 10, ts: "2026-11-08T08:41:12.004-05:00")
        XCTAssertEqual(entries.map(\.kind), [.edit, .edit, .edit, .edit])
        XCTAssertEqual(entries.map(\.undo), [.edit, .edit, .edit, .edit])
        XCTAssertNil(entries[0].inverse)
        XCTAssertEqual(entries[1].inverse?.cmd, "edit.insert")
        XCTAssertEqual(entries[1].text, "edit list 42 cue \(c1) remove")
    }
}
