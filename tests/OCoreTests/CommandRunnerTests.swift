import Foundation
import XCTest
@testable import OCore

/// Spec 2 §8 — results: "Every executed command yields one of `ok`,
/// `blocked`, `noop` or `steppedOn`; a rejected command yields `rejected`
/// with a reason". Spec 2 §10 — Lock: "A locked channel refuses `write`,
/// `clear` and tracked attribute writes from `cue` and `timeline` sources,
/// logs `blocked`, and accepts the same commands from every other source."
/// Groups: "a macro's commands run in order with each inner command logged
/// under the macro's group id." The runner folds a group one command at a
/// time over the projection so each command has its own result.
final class CommandRunnerTests: XCTestCase {
    typealias F = Fixtures

    func group(_ commands: [Command], _ source: SourceKind = .ui, id: String = "g-1",
               list: UUID? = nil, cue: UUID? = nil, playlist: UUID? = nil, fire: FireRecord? = nil) -> CommandGroup {
        var group = CommandGroup(id: GroupID(id), source: CommandSource(kind: source, list: list, cue: cue, playlist: playlist),
                                 commands: commands)
        group.fire = fire
        return group
    }

    func run(_ group: CommandGroup, state: ShowState, frame: Int = 100, library: Library = F.library,
             machine: Machine = F.machine, validate: Bool = true,
             file: StaticString = #filePath, line: UInt = #line) -> RunOutcome? {
        var counter = 1
        let context = F.context(frame: frame, source: .engine, library: library, machine: machine)
        switch CommandRunner.run(group, state: state, context: context, validate: validate, makeGroupID: {
            counter += 1
            return GroupID("g-\(counter)")
        }) {
        case .success(let outcome):
            return outcome
        case .failure(let rejection):
            XCTFail("\(rejection.reason.rawValue): \(rejection.message)", file: file, line: line)
            return nil
        }
    }

    func results(_ outcome: RunOutcome?) -> [CommandResult] { outcome?.executed.map(\.result) ?? [] }

    // MARK: - Results

    func test_okNoopAndTheEffectsOfEachCommand() throws {
        let outcome = try XCTUnwrap(run(group([F.write(1, text: "x"), .channelClear(channel: .number(2))]), state: F.fresh()))
        XCTAssertEqual(results(outcome), [.ok, .noop])
        XCTAssertEqual(outcome.executed.map(\.command), [F.write(1, text: "x"), .channelClear(channel: .number(2))])
        XCTAssertEqual(outcome.executed[0].effects.count, 1)
        XCTAssertNotNil(outcome.executed[0].effects.first?.transitionEffect)
        XCTAssertEqual(outcome.executed[1].effects, [.noop(.channelClear(channel: .number(2)))])
        XCTAssertEqual(outcome.executed.map(\.group), [GroupID("g-1"), GroupID("g-1")])
        XCTAssertEqual(outcome.executed.map(\.source.kind), [.ui, .ui])
        XCTAssertEqual(outcome.state.channels[1]?.content, .text(TextInstance(fields: ["body": "x"])))
        XCTAssertEqual(CommandResult.ok.name, "ok")
        XCTAssertEqual(CommandResult.steppedOn.name, "steppedOn")
    }

    /// Spec 3 §9 row 14's decoder budget, seen as a result.
    func test_steppedOn() throws {
        var before = F.fresh()
        before.channels[1]?.content = .media(MediaInstance(ref: F.mediaA, startedAtFrame: 50))
        let writeB = F.write(1, media: F.mediaB, riders: Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))
        let afterB = try XCTUnwrap(run(group([writeB]), state: before, frame: 100, validate: false))
        XCTAssertEqual(results(afterB), [.ok])
        let afterC = try XCTUnwrap(run(group([F.write(1, media: F.mediaC)]), state: afterB.state, frame: 110, validate: false))
        XCTAssertEqual(results(afterC), [.steppedOn])
        XCTAssertTrue(afterC.executed[0].effects.contains(.steppedOn(channel: 1, dropped: F.mediaA)))
    }

    // MARK: - Spec 2 §10, lock

    func test_lockBlocksCueAndTimelineSourcesOnly() throws {
        var locked = F.fresh()
        locked.channels[2]?.lock = true
        locked.channels[2]?.content = .text(TextInstance(fields: ["body": "held"]))
        let everySource: [SourceKind] = [.ui, .key, .osc, .midi, .streamdeck, .macro, .cue, .timeline, .scheduler,
                                         .startup, .shutdown, .commandbar, .api, .restore, .engine]
        let commands: [Command] = [F.write(2, text: "x"), .channelClear(channel: .number(2)),
                                   .channelTransition(channel: .number(2), ref: 2, ms: nil),
                                   .channelGrade(channel: .number(2), ref: 1, ms: nil),
                                   .channelGain(channel: .number(2), db: -6)]
        for source in everySource {
            for command in commands {
                let outcome = try XCTUnwrap(run(group([command], source), state: locked, validate: false))
                let expected: CommandResult = source.isSubjectToLock ? .blocked : .ok
                XCTAssertEqual(results(outcome), [expected], "\(source) \(command)")
                if source.isSubjectToLock {
                    XCTAssertEqual(outcome.executed[0].effects, [.blocked(channel: 2, command: command)])
                    XCTAssertEqual(outcome.state, locked, "\(source) \(command) changed state")
                }
            }
            // Lock and unlock are never blocked (Spec 3 §8).
            let unlock = try XCTUnwrap(run(group([.channelLock(channel: .number(2), locked: false)], source), state: locked, validate: false))
            XCTAssertEqual(results(unlock), [.ok], "\(source)")
            XCTAssertEqual(unlock.state.channels[2]?.lock, false)
        }
    }

    /// `channel all` with one locked channel from a cue: the others run, the
    /// blocked one shows in the effects, and the command is `ok`.
    func test_allWithOneLockedChannelFromACue() throws {
        var locked = F.fresh()
        locked.channels[2]?.lock = true
        let command = Command.channelWrite(ChannelWrite(channel: .all, content: .text(fields: ["body": "x"])))
        let outcome = try XCTUnwrap(run(group([command], .cue), state: locked, validate: false))
        XCTAssertEqual(results(outcome), [.ok])
        XCTAssertTrue(outcome.executed[0].effects.contains(.blocked(channel: 2, command: command)))
        XCTAssertEqual(outcome.state.channels[1]?.content, .text(TextInstance(fields: ["body": "x"])))
        XCTAssertEqual(outcome.state.channels[2]?.content, .empty)
    }

    // MARK: - Spec 2 §5 and §10, groups and macros

    func test_aMacroLogsItselfAndEachInnerCommandUnderItsGroup() throws {
        let outcome = try XCTUnwrap(run(group([.macro(1)]), state: F.fresh()))
        XCTAssertEqual(outcome.executed.map(\.command), [.macro(1), F.write(2, text: "Welcome")])
        XCTAssertEqual(results(outcome), [.ok, .ok])
        XCTAssertEqual(outcome.executed.map(\.group), [GroupID("g-1"), GroupID("g-1")])
        XCTAssertEqual(outcome.executed[0].source, CommandSource(kind: .ui))
        XCTAssertEqual(outcome.executed[1].source, CommandSource(kind: .macro, macro: 1))
        XCTAssertEqual(outcome.executed[0].effects, [])
        XCTAssertNotNil(outcome.executed[1].effects.first?.transitionEffect)
        XCTAssertEqual(outcome.state.channels[2]?.content, .text(TextInstance(fields: ["body": "Welcome"])))

        // Spec 2 §7 — the guard fails against the state as it now is: nothing inner runs.
        let again = try XCTUnwrap(run(group([.macro(1)]), state: outcome.state))
        XCTAssertEqual(again.executed.map(\.command), [.macro(1)])
        XCTAssertEqual(results(again), [.noop])
        XCTAssertEqual(again.state, outcome.state)
    }

    /// Spec 3 §8 — "A macro fired by a cue inherits `cue` as its source kind,
    /// so lock cannot be dodged by wrapping a write in a macro."
    func test_aMacroFiredByACueInheritsTheCueSource() throws {
        var locked = F.fresh()
        locked.channels[2]?.lock = true
        let list = F.listUuid(7), cue = F.cueUuid(list: 7, cue: 1)
        let outcome = try XCTUnwrap(run(group([.macro(2)], .cue, list: list, cue: cue, playlist: F.playlistUuid), state: locked))
        XCTAssertEqual(outcome.executed.map(\.command), [.macro(2), F.write(2, text: "from macro")])
        XCTAssertEqual(results(outcome), [.ok, .blocked])
        XCTAssertEqual(outcome.executed[1].source, CommandSource(kind: .cue, list: list, cue: cue, playlist: F.playlistUuid))
        XCTAssertEqual(outcome.state.channels[2]?.content, .empty)

        let fromKey = try XCTUnwrap(run(group([.macro(2)], .key), state: locked))
        XCTAssertEqual(results(fromKey), [.ok, .ok])
        XCTAssertEqual(fromKey.executed[1].source, CommandSource(kind: .macro, macro: 2))
    }

    /// Spec 2 §5 — "depth is capped at 8": a macro that calls itself stops.
    func test_macroDepthIsCapped() throws {
        var library = F.library
        library.macros.append(Macro(number: 3, commands: [GuardedCommand(.macro(3))]))
        let outcome = try XCTUnwrap(run(group([.macro(3)]), state: F.fresh(), library: library, validate: false))
        XCTAssertEqual(outcome.executed.count, 9)
        XCTAssertTrue(outcome.executed.allSatisfy { $0.command == .macro(3) && $0.result == .noop })
        XCTAssertEqual(outcome.state, F.fresh())
    }

    func test_anUnknownMacroIsANoop() throws {
        let outcome = try XCTUnwrap(run(group([.macro(99)]), state: F.fresh(), validate: false))
        XCTAssertEqual(results(outcome), [.noop])
        XCTAssertEqual(outcome.executed[0].effects, [.noop(.macro(99))])
    }

    /// A guard on a command submitted outside a macro is honoured too: a
    /// failing guard skips the command and logs nothing (Spec 2 §7, "the
    /// command runs only when it holds").
    func test_guardsOnSubmittedCommands() throws {
        let guarded = CommandGroup(id: GroupID("g-1"), source: CommandSource(kind: .ui), commands: [
            GuardedCommand(F.write(2, text: "a"), when: Guard(variable: "Channel 2 Content", op: .isEmpty)),
            GuardedCommand(F.write(3, text: "b"), when: Guard(variable: "Channel 2 Content", op: .isNotEmpty)),
        ])
        let outcome = try XCTUnwrap(run(guarded, state: F.fresh()))
        XCTAssertEqual(outcome.executed.map(\.command), [F.write(2, text: "a"), F.write(3, text: "b")])
        XCTAssertEqual(results(outcome), [.ok, .ok])
        let again = try XCTUnwrap(run(guarded, state: outcome.state))
        XCTAssertEqual(again.executed.map(\.command), [F.write(3, text: "b")])
        XCTAssertEqual(results(again), [.noop])
    }

    /// Spec 2 §9 — `fire` "appears only on the first command of a cue group".
    func test_aCueGroupCarriesFireOnItsFirstCommand() throws {
        let fire = FireRecord(listTitle: "Hymn one", ccli: "18723")
        let outcome = try XCTUnwrap(run(group([F.write(1, text: "x"), F.write(2, text: "y")], .cue,
                                              list: F.listUuid(1), cue: F.cueUuid(list: 1, cue: 1), fire: fire), state: F.fresh()))
        XCTAssertEqual(outcome.executed.map(\.fire), [fire, nil])
    }

    /// A navigation command that fires a cue logs the navigation, then the
    /// cue's commands as their own cue group with `fire` on the first.
    func test_navigationThatFiresACueLogsTheCueGroup() throws {
        var loaded = F.fresh()
        loaded.pointer = LivePointer(playlist: F.playlistUuid)
        let outcome = try XCTUnwrap(run(group([.next], .key), state: loaded))
        XCTAssertEqual(outcome.executed.map(\.command), [.next, F.write(1, media: F.mediaA), F.write(2, text: "verse 1")])
        XCTAssertEqual(results(outcome), [.ok, .ok, .ok])
        XCTAssertEqual(outcome.executed.map(\.group), [GroupID("g-1"), GroupID("g-2"), GroupID("g-2")])
        let cueSource = CommandSource(kind: .cue, list: F.listUuid(1), cue: F.cueUuid(list: 1, cue: 1), playlist: F.playlistUuid)
        XCTAssertEqual(outcome.executed.map(\.source), [CommandSource(kind: .key), cueSource, cueSource])
        XCTAssertEqual(outcome.executed.map(\.fire), [nil, FireRecord(listTitle: "Hymn one", ccli: ""), nil])
        XCTAssertEqual(outcome.state.pointer, F.pointer(item: 2, list: 1, cue: 1))
        // The navigation's own effects are the pointer and boundary; the cue's effects go with the cue's commands.
        XCTAssertTrue(outcome.executed[0].effects.contains { if case .pointer = $0 { return true } else { return false } })
        XCTAssertFalse(outcome.executed[0].effects.contains { $0.transitionEffect != nil })
        XCTAssertNotNil(outcome.executed[1].effects.first?.transitionEffect)

        // A cue command blocked by lock is `blocked` in the cue group.
        var locked = loaded
        locked.channels[2]?.lock = true
        let blocked = try XCTUnwrap(run(group([.next], .key), state: locked))
        XCTAssertEqual(results(blocked), [.ok, .ok, .blocked])

        // Past the end nothing fires and `next` is a noop.
        var atEnd = F.fresh()
        atEnd.pointer = F.pointer(item: 5, list: 3, cue: 2)
        let noop = try XCTUnwrap(run(group([.next], .key), state: atEnd))
        XCTAssertEqual(results(noop), [.noop])
        XCTAssertEqual(noop.executed.count, 1)
    }

    /// The runner reaches the same state as the projection for the same group.
    func test_runnerAgreesWithTheProjection() throws {
        var onCue = F.fresh()
        onCue.pointer = F.pointer(item: 2, list: 1, cue: 1)
        let cases: [(ShowState, [Command], SourceKind)] = [
            (F.fresh(), [.macro(1)], .ui),
            (F.fresh(), [.macro(2), .macro(1)], .key),
            (F.fresh(), [.listCue(list: 1, cue: 1), .next, .next], .ui),
            (onCue, [.next, .channelGrade(channel: .number(2), ref: 1, ms: nil), .previous], .osc),
            (onCue, [.itemCue(item: 3, cue: 1), .systemClearAll], .ui),
            (F.fresh(), [.playlistLoad(title: "Sunday", date: nil), .next, .next, .next], .ui),
        ]
        for (state, commands, source) in cases {
            let outcome = try XCTUnwrap(run(group(commands, source), state: state, validate: false))
            let (projected, _) = project(state, commands, context: F.context(frame: 100, source: source))
            XCTAssertEqual(outcome.state, projected, "\(commands)")
        }
    }

    // MARK: - Spec 2 §8, "A command either runs or is rejected with a reason before anything changes."

    func test_aRejectedGroupChangesNothing() {
        let state = F.fresh()
        let bad = group([F.write(1, text: "x"), .channelClear(channel: .number(9))])
        let context = F.context(frame: 100, source: .ui)
        switch CommandRunner.run(bad, state: state, context: context) {
        case .success(let outcome):
            XCTFail("ran: \(outcome.executed)")
        case .failure(let rejection):
            XCTAssertEqual(rejection.reason, .noSuchTarget)
            XCTAssertEqual(rejection.index, 1)
            XCTAssertEqual(rejection.text, "channel 9 clear")
        }
        // With validation off the projection's own guard answers `noop` for the bad one.
        switch CommandRunner.run(bad, state: state, context: context, validate: false) {
        case .success(let outcome):
            XCTAssertEqual(outcome.executed.map(\.result), [.ok, .noop])
        case .failure(let rejection):
            XCTFail("\(rejection)")
        }
    }
}
