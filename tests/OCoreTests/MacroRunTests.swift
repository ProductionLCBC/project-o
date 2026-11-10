import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — Groups: "a macro's commands run in order with each inner
/// command logged under the macro's group id"; Log: "Every executed command
/// produces one line with the fields in section 9". Spec 2 §9 — "A macro's
/// own line is logged with `undo: "none"`, followed by each inner command
/// under the same group with source `macro` and the macro's number (with the
/// cue's source and the macro's number when a cue ran the macro, so lock
/// still applies, Spec 3 §8)". Spec 2 §3 — `macro N` "Runs the macro's
/// commands in order; each inner command is logged and judged on its own."
/// Area 15: the machine-level and library macros run the same from a key,
/// OSC and a cue.
final class MacroRunTests: XCTestCase {
    typealias F = Fixtures

    static let ts = "2026-11-10T09:00:00.000-05:00"

    /// List 8: cue 1 runs macro 31, which runs macro 2; cue 2 runs the
    /// machine macro 30.
    static let list8 = List(uuid: F.listUuid(8), number: 8, title: "Macro list", cues: [
        F.cue(list: 8, 1, commands: [.macro(31)]),
        F.cue(list: 8, 2, commands: [.macro(30)]),
    ])

    static var library: Library {
        var library = F.library
        library.lists.append(list8)
        // Macro 31, portable: runs macro 2.
        library.macros.append(Macro(number: 31, commands: [GuardedCommand(.macro(2))]))
        return library
    }

    static var machine: Machine {
        var machine = F.machine
        // Macro 30, machine-level (it names a stack): blacks out stack 1 and writes channel 3.
        machine.macros.append(Macro(number: 30, commands: [
            GuardedCommand(.stackBlackout(stack: .number(1), state: .on)),
            GuardedCommand(F.write(3, text: "machine")),
        ]))
        return machine
    }

    func group(_ commands: [Command], _ source: SourceKind) -> CommandGroup {
        CommandGroup(id: GroupID("g-1"), source: CommandSource(kind: source), commands: commands)
    }

    func run(_ group: CommandGroup, state: ShowState = F.fresh(), library: Library = MacroRunTests.library,
             machine: Machine = MacroRunTests.machine, validate: Bool = true,
             file: StaticString = #filePath, line: UInt = #line) -> RunOutcome? {
        var counter = 1
        let context = F.context(frame: 100, source: .engine, library: library, machine: machine)
        switch CommandRunner.run(group, state: state, context: context, validate: validate, makeGroupID: {
            counter += 1
            return GroupID("g-\(counter)")
        }) {
        case .success(let outcome): return outcome
        case .failure(let rejection):
            XCTFail("\(rejection.reason.rawValue): \(rejection.message)", file: file, line: line)
            return nil
        }
    }

    func entries(_ outcome: RunOutcome?) -> [LogEntry] {
        outcome.map { LogEntry.entries(for: $0, firstSeq: 1, ts: Self.ts) } ?? []
    }

    // MARK: - From a key, OSC and the UI

    /// A library macro and a machine macro, each from `key`, `osc` and `ui`:
    /// the macro's own line with the submitter's source and `undo: "none"`,
    /// then each inner line under the same group with source `macro` and the
    /// macro's number.
    func test_libraryAndMachineMacrosRunTheSameFromEverySource() throws {
        for kind: SourceKind in [.key, .osc, .ui] {
            let library = entries(run(group([.macro(2)], kind)))
            XCTAssertEqual(library.map(\.text), ["macro 2", "channel 2 write text \"from macro\""], "\(kind)")
            XCTAssertEqual(library.map(\.source), [CommandSource(kind: kind), CommandSource(kind: .macro, macro: 2)])
            XCTAssertEqual(library.map(\.undo), [.none, .runtime])
            XCTAssertEqual(library.map(\.result), [.ok, .ok])
            XCTAssertEqual(Set(library.map(\.group.rawValue)), ["g-1"])

            let machine = entries(run(group([.macro(30)], kind)))
            XCTAssertEqual(machine.map(\.text), ["macro 30", "stack 1 blackout on", "channel 3 write text \"machine\""], "\(kind)")
            XCTAssertEqual(machine.map(\.source), [CommandSource(kind: kind), CommandSource(kind: .macro, macro: 30),
                                                   CommandSource(kind: .macro, macro: 30)])
            XCTAssertEqual(machine.map(\.undo), [.none, .runtime, .runtime])
            XCTAssertEqual(Set(machine.map(\.group.rawValue)), ["g-1"])
        }
    }

    /// Nested macros: every line in the outer group, each inner line naming
    /// the innermost macro that ran it.
    func test_nestedMacrosNameTheInnermostMacro() throws {
        let lines = entries(run(group([.macro(31)], .key)))
        XCTAssertEqual(lines.map(\.text), ["macro 31", "macro 2", "channel 2 write text \"from macro\""])
        XCTAssertEqual(lines.map(\.source), [CommandSource(kind: .key), CommandSource(kind: .macro, macro: 31),
                                             CommandSource(kind: .macro, macro: 2)])
        XCTAssertEqual(lines.map(\.undo), [.none, .none, .runtime])
        XCTAssertEqual(lines.map(\.result), [.ok, .ok, .ok])
        XCTAssertEqual(Set(lines.map(\.group.rawValue)), ["g-1"])
    }

    // MARK: - Spec 2 §5, whole or not at all

    /// Macros 60 → … → 67 nest 8 deep and write channel 3; 70 → … → 78 nest
    /// 9; 80 and 81 call each other; 85 calls macro 99, which does not exist,
    /// then writes channel 1; 90 fires list 12's cue 3. List 12: cue 1 runs
    /// macro 70, cue 2 macro 80, cue 3 macro 60, cue 4 macro 85.
    static var wholeLibrary: Library {
        var library = Self.library
        for n in 60...67 { library.macros.append(Macro(number: n, commands: [GuardedCommand(n == 67 ? F.write(3, text: "eight") : .macro(n + 1))])) }
        for n in 70...78 { library.macros.append(Macro(number: n, commands: [GuardedCommand(n == 78 ? F.write(3, text: "nine") : .macro(n + 1))])) }
        library.macros.append(Macro(number: 80, commands: [GuardedCommand(F.write(1, text: "loop")), GuardedCommand(.macro(81))]))
        library.macros.append(Macro(number: 81, commands: [GuardedCommand(.macro(80))]))
        library.macros.append(Macro(number: 85, commands: [GuardedCommand(.macro(99)), GuardedCommand(F.write(1, text: "after"))]))
        library.macros.append(Macro(number: 90, commands: [GuardedCommand(.listCue(list: 12, cue: 3))]))
        library.lists.append(List(uuid: F.listUuid(12), number: 12, title: "Depth", cues: [
            F.cue(list: 12, 1, commands: [.macro(70)]),
            F.cue(list: 12, 2, commands: [.macro(80)]),
            F.cue(list: 12, 3, commands: [.macro(60)]),
            F.cue(list: 12, 4, commands: [.macro(85)]),
        ]))
        return library
    }

    private func rejection(_ commands: [Command], _ source: SourceKind) -> Rejection? {
        let context = F.context(frame: 100, library: Self.wholeLibrary, machine: Self.machine)
        if case .failure(let rejection) = CommandRunner.run(group(commands, source), state: F.fresh(), context: context) { return rejection }
        return nil
    }

    /// From a key or OSC a macro that nests too deep, or loops, is rejected
    /// before anything runs (Spec 2 §8); one that fits runs to its end.
    func test_submittedDirectlyAMacroThatCannotRunWholeIsRejected() throws {
        for kind: SourceKind in [.key, .osc] {
            XCTAssertEqual(rejection([.macro(70)], kind)?.reason, .macroDepth, "\(kind)")
            XCTAssertEqual(rejection([.macro(80)], kind)?.reason, .macroCycle, "\(kind)")
            let eight = try XCTUnwrap(run(group([.macro(60)], kind), library: Self.wholeLibrary))
            XCTAssertEqual(eight.executed.count, 9)
            XCTAssertEqual(eight.executed.last?.command, F.write(3, text: "eight"))
        }
    }

    /// Held by a cue, the same macros run nothing: the macro's line is `noop`
    /// and says why, and nothing inner is logged.
    func test_heldByACueAMacroThatCannotRunWholeRunsNothing() throws {
        let deep = try XCTUnwrap(run(group([.listCue(list: 12, cue: 1)], .key), library: Self.wholeLibrary))
        XCTAssertEqual(deep.executed.map(\.command), [.listCue(list: 12, cue: 1), .macro(70)])
        XCTAssertEqual(deep.executed.map(\.result), [.ok, .noop])
        XCTAssertEqual(deep.executed[1].refusal?.reason, .macroDepth)
        XCTAssertEqual(deep.executed[1].refusal?.message, "macro 70 nests 9 macros deep; the cap is 8")
        XCTAssertEqual(deep.state.channels[3]?.content, .empty)

        let loop = try XCTUnwrap(run(group([.listCue(list: 12, cue: 2)], .key), library: Self.wholeLibrary))
        XCTAssertEqual(loop.executed.map(\.command), [.listCue(list: 12, cue: 2), .macro(80)])
        XCTAssertEqual(loop.executed[1].refusal?.reason, .macroCycle)
        XCTAssertEqual(loop.executed[1].refusal?.message, "macros call each other in a loop: macro 80 → macro 81 → macro 80")
        XCTAssertEqual(loop.state.channels[1]?.content, .empty, "not even the write before the loop")

        let eight = try XCTUnwrap(run(group([.listCue(list: 12, cue: 3)], .key), library: Self.wholeLibrary))
        XCTAssertEqual(eight.executed.last?.command, F.write(3, text: "eight"), "a cue the operator fired leaves all 8 levels")
        XCTAssertEqual(eight.executed.last?.source, CommandSource(kind: .cue, list: F.listUuid(12), cue: F.cueUuid(list: 12, cue: 3), macro: 67))

        let (projected, _) = project(F.fresh(), [.listCue(list: 12, cue: 2)],
                                     context: F.context(frame: 100, source: .key, library: Self.wholeLibrary, machine: Self.machine))
        XCTAssertEqual(loop.state, projected, "the projection refuses it the same way")
    }

    /// Spec 2 §5 — a cue fired from inside a macro gets only the levels left:
    /// macro 90 (a level) fires cue 3 (a level), so its 8-deep chain has 6.
    func test_inACueAMacroFiredTheChainHasOnlyTheLevelsLeft() throws {
        let outcome = try XCTUnwrap(run(group([.macro(90)], .key), library: Self.wholeLibrary))
        XCTAssertEqual(outcome.executed.map(\.command), [.macro(90), .listCue(list: 12, cue: 3), .macro(60)])
        XCTAssertEqual(outcome.executed.last?.result, .noop)
        XCTAssertEqual(outcome.executed.last?.refusal?.message, "macro 60 nests 8 macros deep; 6 levels of the 8 are left here")
        let (projected, _) = project(F.fresh(), [.macro(90)],
                                     context: F.context(frame: 100, source: .key, library: Self.wholeLibrary, machine: Self.machine))
        XCTAssertEqual(outcome.state, projected)
    }

    /// A call to a macro that does not exist is one `noop` line with its
    /// reason, and the rest of the macro runs (Spec 1 §8, a broken reference).
    func test_aCallToAMissingMacroIsOneNoopLine() throws {
        let outcome = try XCTUnwrap(run(group([.listCue(list: 12, cue: 4)], .key), library: Self.wholeLibrary))
        XCTAssertEqual(outcome.executed.map(\.command), [.listCue(list: 12, cue: 4), .macro(85), .macro(99), F.write(1, text: "after")])
        XCTAssertEqual(outcome.executed.map(\.result), [.ok, .ok, .noop, .ok])
        XCTAssertEqual(outcome.executed[2].refusal?.reason, .noSuchTarget)
        XCTAssertNil(outcome.executed[1].refusal)
    }

    // MARK: - Spec 2 §5, the one check

    private func validate(_ number: Int, library: Library, machine: Machine = F.machine) -> Rejection? {
        CommandValidator.validate(.macro(number), context: ValidationContext(library: library, machine: machine))
    }

    /// One number names one macro: the library's before the machine's, and
    /// within a root the first with that number, as the runner looks it up.
    func test_theCheckLooksMacrosUpAsTheRunnerDoes() {
        var library = F.library
        library.macros.append(Macro(number: 7, commands: [GuardedCommand(.macro(7))]))
        library.macros.append(Macro(number: 7, commands: [GuardedCommand(F.write(1, text: "second"))]))
        XCTAssertEqual(validate(7, library: library)?.reason, .macroCycle, "the first macro 7 is the one that runs")
        XCTAssertEqual(MacroCalls.macro(7, library: library, machine: F.machine)?.commands.first?.command, .macro(7))

        var machine = F.machine
        machine.macros.append(Macro(number: 8, commands: [GuardedCommand(.macro(8))]))
        library.macros.append(Macro(number: 8, commands: [GuardedCommand(F.write(1, text: "library"))]))
        XCTAssertNil(validate(8, library: library, machine: machine), "the library's macro 8 runs, not the machine's")
    }

    /// The check works each macro's depth out once: a chain where every macro
    /// calls the next twice costs as many steps as it has macros, not 2^n.
    func test_theCheckCostsOneStepPerMacro() {
        var library = F.library
        for n in 100...130 {
            let next = GuardedCommand(n == 130 ? F.write(1, text: "end") : .macro(n + 1))
            library.macros.append(Macro(number: n, commands: [next, next]))
        }
        let started = Date()
        XCTAssertEqual(MacroCalls.check(100, levels: 8, library: library, machine: F.machine)?.reason, .macroDepth)
        XCTAssertEqual(MacroCalls.check(123, levels: 8, library: library, machine: F.machine), nil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    /// The messages name the loop and the depth; a call to a macro that does
    /// not exist counts no level.
    func test_theCheckNamesTheLoopAndTheDepth() {
        var library = F.library
        library.macros.append(Macro(number: 40, commands: [GuardedCommand(.macro(41))]))
        library.macros.append(Macro(number: 41, commands: [GuardedCommand(.macro(42))]))
        library.macros.append(Macro(number: 42, commands: [GuardedCommand(.macro(40))]))
        library.macros.append(Macro(number: 43, commands: [GuardedCommand(.macro(99)), GuardedCommand(F.write(1, text: "x"))]))
        let loop = MacroCalls.check(40, levels: 8, library: library, machine: F.machine)
        XCTAssertEqual(loop?.reason, .macroCycle)
        XCTAssertEqual(loop?.message, "macros call each other in a loop: macro 40 → macro 41 → macro 42 → macro 40")
        XCTAssertNil(MacroCalls.check(43, levels: 1, library: library, machine: F.machine), "macro 99 counts no level")
        XCTAssertEqual(MacroCalls.check(99, levels: 8, library: library, machine: F.machine)?.reason, .noSuchTarget)
        let deep = MacroCalls.check(31, levels: 1, library: Self.library, machine: F.machine)
        XCTAssertEqual(deep?.reason, .macroDepth)
        XCTAssertEqual(deep?.message, "macro 31 nests 2 macros deep; 1 level of the 8 is left here")
        XCTAssertEqual(MacroCalls.check(31, levels: 0, library: Self.library, machine: F.machine)?.reason, .macroDepth)
        XCTAssertNil(MacroCalls.check(31, levels: 2, library: Self.library, machine: F.machine))
    }

    // MARK: - From a cue

    /// A cue fired by `list N cue M` or `next`: the navigation's line, then the
    /// cue group with `fire` on its first line; the macro's line and its inner
    /// lines carry the cue's source, and the inner lines the macro's number.
    func test_aMacroInACueCarriesTheCueSourceAndTheMacroNumber() throws {
        let cueSource = CommandSource(kind: .cue, list: F.listUuid(8), cue: F.cueUuid(list: 8, cue: 1))
        let lines = entries(run(group([.listCue(list: 8, cue: 1)], .key)))
        XCTAssertEqual(lines.map(\.text), ["list 8 cue 1", "macro 31", "macro 2", "channel 2 write text \"from macro\""])
        XCTAssertEqual(lines.map(\.source), [
            CommandSource(kind: .key), cueSource, cueSource.inMacro(31), cueSource.inMacro(2),
        ])
        XCTAssertEqual(lines[3].source, CommandSource(kind: .cue, list: F.listUuid(8), cue: F.cueUuid(list: 8, cue: 1), macro: 2))
        XCTAssertEqual(lines.map(\.group.rawValue), ["g-1", "g-2", "g-2", "g-2"])
        XCTAssertEqual(lines.map(\.fire), [nil, FireRecord(listTitle: "Macro list", ccli: ""), nil, nil])
        XCTAssertEqual(lines.map(\.undo), [.runtime, .none, .none, .runtime])
        XCTAssertEqual(lines.map(\.result), [.ok, .ok, .ok, .ok])

        // The cue's second cue, by `next`: the machine macro, under the cue's source.
        let first = try XCTUnwrap(run(group([.listCue(list: 8, cue: 1)], .key)))
        let next = entries(run(group([.next], .osc), state: first.state))
        let second = CommandSource(kind: .cue, list: F.listUuid(8), cue: F.cueUuid(list: 8, cue: 2))
        XCTAssertEqual(next.map(\.text), ["next", "macro 30", "stack 1 blackout on", "channel 3 write text \"machine\""])
        XCTAssertEqual(next.map(\.source), [CommandSource(kind: .osc), second, second.inMacro(30), second.inMacro(30)])
    }

    /// Spec 3 §8 — lock still applies inside a macro a cue runs, and the
    /// write's provenance names the cue (Spec 3 §2).
    func test_lockAppliesInsideAMacroACueRuns() throws {
        var locked = F.fresh()
        locked.channels[2]?.lock = true
        let blocked = entries(run(group([.listCue(list: 8, cue: 1)], .key), state: locked))
        // A macro's own line is `ok` when an inner command did something; the write is `blocked`.
        XCTAssertEqual(blocked.map(\.result), [.ok, .ok, .ok, .blocked])
        XCTAssertEqual(blocked[3].source, CommandSource(kind: .cue, list: F.listUuid(8), cue: F.cueUuid(list: 8, cue: 1), macro: 2))

        let open = try XCTUnwrap(run(group([.listCue(list: 8, cue: 1)], .key)))
        XCTAssertEqual(open.state.channels[2]?.provenance, .cue(F.cueUuid(list: 8, cue: 1), list: F.listUuid(8)),
                       "a write by a macro that a cue ran records that cue and its list (Spec 6 §5)")
    }
}
