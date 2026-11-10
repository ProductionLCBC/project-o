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
        XCTAssertEqual(open.state.channels[2]?.provenance, .cue(F.cueUuid(list: 8, cue: 1)))
    }
}
