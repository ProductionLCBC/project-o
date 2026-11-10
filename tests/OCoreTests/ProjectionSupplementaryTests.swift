import XCTest
@testable import OCore

/// Behaviour Spec 3 specifies outside the §9 table: macro inlining with
/// guards (§6, Spec 2 §7), lock through a macro fired by a cue (§8), output
/// and stack commands (§6 effects table), popups (§4) and pass-through.
final class ProjectionSupplementaryTests: XCTestCase {
    typealias F = Fixtures

    private func run(_ state: ShowState, _ commands: [Command], frame: Int = 100, source: SourceKind = .ui,
                     variables: @escaping @Sendable (String) -> String? = { _ in nil }) -> (ShowState, [Effect]) {
        project(state, commands, context: F.context(frame: frame, source: source, variables: variables))
    }

    private func text(_ body: String) -> ContentInstance { .text(TextInstance(fields: ["body": body])) }

    // MARK: - Macros and guards

    /// Spec 3 §6 — "`macro` by inlining the macro's commands with their guards."
    func test_macroGuardHoldsOnlyWhileChannelIsEmpty() {
        let (afterFirst, firstEffects) = run(F.fresh(), [.macro(1)])
        XCTAssertEqual(afterFirst.channels[2]?.content, text("Welcome"))
        XCTAssertEqual(firstEffects.compactMap(\.transitionEffect).map(\.channel), [2])

        let (afterSecond, secondEffects) = run(afterFirst, [.macro(1)])
        XCTAssertEqual(afterSecond, afterFirst, "the guard fails, so the inner write does not run")
        XCTAssertEqual(secondEffects, [.noop(.macro(1))])
    }

    /// Spec 2 §7 — guards compare durations as durations and read variables
    /// from the context.
    func test_macroGuardReadsVariablesFromContext() {
        let macro = Macro(number: 9, commands: [
            GuardedCommand(.channelClear(channel: .number(2)), when: Guard(variable: "Timer 1", op: .is, value: "0:00")),
        ])
        var library = F.library
        library.macros.append(macro)
        var before = F.fresh()
        before.channels[2]?.content = text("y")

        let running = project(before, [.macro(9)], context: F.context(frame: 1, library: library, variables: { $0 == "Timer 1" ? "0:30" : nil }))
        XCTAssertEqual(running.0.channels[2]?.content, text("y"))
        let elapsed = project(before, [.macro(9)], context: F.context(frame: 1, library: library, variables: { $0 == "Timer 1" ? "0" : nil }))
        XCTAssertEqual(elapsed.0.channels[2]?.content, .empty)
    }

    /// Spec 3 §8 — "A macro fired by a cue inherits `cue` as its source kind,
    /// so lock cannot be dodged by wrapping a write in a macro."
    func test_macroFiredByCueObeysLock() {
        var before = F.fresh()
        before.channels[2]?.lock = true
        before.channels[2]?.content = text("held")

        let (viaCue, cueEffects) = run(before, [.listCue(list: 7, cue: 1)])
        XCTAssertEqual(viaCue.channels[2]?.content, text("held"))
        XCTAssertTrue(cueEffects.contains(.blocked(channel: 2, command: F.write(2, text: "from macro"))), "\(cueEffects)")
        XCTAssertEqual(viaCue.pointer, F.pointer(list: 7, cue: 1), "a fired cue moves the pointer even when its writes are blocked")

        let (viaKey, _) = run(before, [.macro(2)], source: .key)
        XCTAssertEqual(viaKey.channels[2]?.content, text("from macro"))
    }

    func test_unknownMacroIsNoop() {
        let (state, effects) = run(F.fresh(), [.macro(99)])
        XCTAssertEqual(state, F.fresh())
        XCTAssertEqual(effects, [.noop(.macro(99))])
    }

    // MARK: - Outputs and stacks

    func test_outputStackSwitchCarriesTheOutputsSwitchTransition() {
        let (state, effects) = run(F.fresh(), [.outputStack(output: 1, stack: 2)])
        XCTAssertEqual(state.outputs[1], 2)
        XCTAssertEqual(effects, [.stackSwitch(output: 1, old: 1, new: 2, transition: 2)])

        let (same, sameEffects) = run(state, [.outputStack(output: 1, stack: 2)])
        XCTAssertEqual(same, state)
        XCTAssertEqual(sameEffects, [.noop(.outputStack(output: 1, stack: 2))])

        let (missing, missingEffects) = run(state, [.outputStack(output: 1, stack: 9)])
        XCTAssertEqual(missing, state, "an unknown stack is a noop, never a trap")
        XCTAssertEqual(missingEffects, [.noop(.outputStack(output: 1, stack: 9))])
    }

    func test_stackBlackoutTogglesWithTheShowingOutputsBlackoutTransition() {
        let (on, onEffects) = run(F.fresh(), [.stackBlackout(stack: .number(1), state: .toggle)])
        XCTAssertEqual(on.stacks[1]?.blackout, true)
        XCTAssertEqual(onEffects, [.blackout(stack: 1, old: false, new: true, transition: 3)])

        let (still, stillEffects) = run(on, [.stackBlackout(stack: .number(1), state: .on)])
        XCTAssertEqual(still, on)
        XCTAssertEqual(stillEffects, [.noop(.stackBlackout(stack: .number(1), state: .on))])

        let (off, offEffects) = run(on, [.stackBlackout(stack: .number(1), state: .off)])
        XCTAssertEqual(off.stacks[1]?.blackout, false)
        XCTAssertEqual(offEffects, [.blackout(stack: 1, old: true, new: false, transition: 3)])
    }

    // MARK: - Spec 2 §3, `stack all blackout` and toggle with `all`

    /// Spec 2 §3 — "With `all`, `toggle` turns every one on unless every one
    /// is already on, when it turns them all off": the rule on its own.
    func test_switchStateWithAllTurnsEveryOneOnUnlessEveryOneIsOn() {
        XCTAssertEqual(SwitchState.toggle.resolve(current: false), true)
        XCTAssertEqual(SwitchState.toggle.resolve(current: true), false)
        XCTAssertEqual(SwitchState.on.resolve(current: true), true)
        XCTAssertEqual(SwitchState.off.resolve(current: false), false)
        XCTAssertEqual(SwitchState.toggle.resolve(all: [false, false]), true)
        XCTAssertEqual(SwitchState.toggle.resolve(all: [true, false]), true, "some on: all on")
        XCTAssertEqual(SwitchState.toggle.resolve(all: [true, true]), false, "every one on: all off")
        XCTAssertEqual(SwitchState.on.resolve(all: [true, true]), true)
        XCTAssertEqual(SwitchState.off.resolve(all: [false, true]), false)
    }

    /// Spec 2 §3 — `stack all blackout toggle` with none on turns every stack
    /// on, each with the blackout transition of the output showing it.
    func test_stackAllBlackoutToggleFromNoneOn() {
        let command = Command.stackBlackout(stack: .all, state: .toggle)
        let (on, effects) = run(F.fresh(), [command])
        XCTAssertEqual(on.stacks[1]?.blackout, true)
        XCTAssertEqual(on.stacks[2]?.blackout, true)
        XCTAssertEqual(effects, [.blackout(stack: 1, old: false, new: true, transition: 3),
                                 .blackout(stack: 2, old: false, new: true, transition: 2)])
    }

    /// With some on, toggle turns all on, and only the stacks that change have
    /// an effect, so a stack blacked out on purpose is never brought back.
    func test_stackAllBlackoutToggleFromSomeOn() {
        var before = F.fresh()
        before.stacks[1]?.blackout = true
        let (after, effects) = run(before, [.stackBlackout(stack: .all, state: .toggle)])
        XCTAssertEqual(after.stacks[1]?.blackout, true)
        XCTAssertEqual(after.stacks[2]?.blackout, true)
        XCTAssertEqual(effects, [.blackout(stack: 2, old: false, new: true, transition: 2)])
    }

    /// With every one on, toggle turns them all off.
    func test_stackAllBlackoutToggleFromAllOn() {
        var before = F.fresh()
        before.stacks[1]?.blackout = true
        before.stacks[2]?.blackout = true
        let (after, effects) = run(before, [.stackBlackout(stack: .all, state: .toggle)])
        XCTAssertEqual(after.stacks[1]?.blackout, false)
        XCTAssertEqual(after.stacks[2]?.blackout, false)
        XCTAssertEqual(effects, [.blackout(stack: 1, old: true, new: false, transition: 3),
                                 .blackout(stack: 2, old: true, new: false, transition: 2)])
    }

    func test_stackAllBlackoutOnAndOffAndNoop() {
        var before = F.fresh()
        before.stacks[2]?.blackout = true
        let (on, onEffects) = run(before, [.stackBlackout(stack: .all, state: .on)])
        XCTAssertEqual(onEffects, [.blackout(stack: 1, old: false, new: true, transition: 3)])
        let (off, offEffects) = run(on, [.stackBlackout(stack: .all, state: .off)])
        XCTAssertEqual(off, F.fresh())
        XCTAssertEqual(offEffects.count, 2)
        let (same, sameEffects) = run(off, [.stackBlackout(stack: .all, state: .off)])
        XCTAssertEqual(same, off)
        XCTAssertEqual(sameEffects, [.noop(.stackBlackout(stack: .all, state: .off))], "nothing changed: one noop")
    }

    /// A stack no output shows blacks out with no transition, as `stack N` does;
    /// a machine with no stacks answers `noop`.
    func test_stackAllBlackoutCoversUnassignedStacksAndEmptyMachines() {
        var machine = F.machine
        machine.stacks.append(Stack(number: 3, slots: [StackSlot(channel: 1)]))
        let fresh = ShowState.fresh(library: F.library, machine: machine)
        let (after, effects) = project(fresh, [.stackBlackout(stack: .all, state: .on)],
                                       context: F.context(frame: 1, machine: machine))
        XCTAssertEqual(effects.last, .blackout(stack: 3, old: false, new: true, transition: nil))
        XCTAssertEqual(after.stacks.values.filter(\.blackout).count, 3)

        var bare = F.machine
        bare.stacks = []
        let empty = ShowState.fresh(library: F.library, machine: bare)
        let (_, none) = project(empty, [.stackBlackout(stack: .all, state: .toggle)], context: F.context(frame: 1, machine: bare))
        XCTAssertEqual(none, [.noop(.stackBlackout(stack: .all, state: .toggle))])
    }

    /// Spec 2 §7 — `[Stack N Blackout]` reads each stack after `stack all`.
    func test_stackBlackoutGuardReadsAfterStackAll() {
        let macro = Macro(number: 9, commands: [
            GuardedCommand(.stackBlackout(stack: .all, state: .on)),
            GuardedCommand(F.write(2, text: "dark"), when: Guard(variable: "Stack 2 Blackout", op: .is, value: "on")),
        ])
        var library = F.library
        library.macros.append(macro)
        let (after, _) = project(F.fresh(), [.macro(9)], context: F.context(frame: 1, library: library))
        XCTAssertEqual(after.channels[2]?.content, text("dark"))
    }

    /// Spec 1 §2 — "`stack all blackout` names no stack, so it leaves a macro
    /// portable"; a numbered stack makes it machine-level.
    func test_stackAllLeavesAMacroPortable() {
        XCTAssertFalse(Macro(number: 9, commands: [GuardedCommand(.stackBlackout(stack: .all, state: .toggle))]).isMachineLevel)
        XCTAssertTrue(Macro(number: 9, commands: [GuardedCommand(.stackBlackout(stack: .number(1), state: .toggle))]).isMachineLevel)
    }

    func test_stackMuteIsPerChannelSlot() {
        let (muted, effects) = run(F.fresh(), [.stackMute(stack: 1, channel: 2, state: .on)])
        XCTAssertEqual(muted.stacks[1]?.muted, [2])
        XCTAssertEqual(effects, [.mute(stack: 1, channel: 2, old: false, new: true)])
        let (unmuted, _) = run(muted, [.stackMute(stack: 1, channel: 2, state: .toggle)])
        XCTAssertEqual(unmuted.stacks[1]?.muted, [])
    }

    // MARK: - Popups, transport and pass-through

    func test_popupSetAndClearEmitVariableEffects() {
        let set = Command.popupSet(popup: 3, text: "Nursery", clearAfterMs: 30_000)
        let (afterSet, setEffects) = run(F.fresh(), [set])
        XCTAssertEqual(afterSet.popups[3], "Nursery")
        XCTAssertEqual(setEffects, [.variable(popup: 3, text: "Nursery", clearAfterMs: 30_000)])

        let (afterClear, clearEffects) = run(afterSet, [.popupClear(popup: 3)])
        XCTAssertNil(afterClear.popups[3])
        XCTAssertEqual(clearEffects, [.variable(popup: 3, text: nil, clearAfterMs: nil)])
    }

    func test_endBehaviorAndPauseOnMedia() {
        var before = F.fresh()
        before.channels[1]?.content = .media(MediaInstance(ref: F.mediaA, startedAtFrame: 10))
        let (state, effects) = run(before, [
            .channelEndBehavior(channel: .number(1), mode: .clear),
            .channelTransport(channel: .number(1), mode: .pause),
            .channelEndBehavior(channel: .number(2), mode: .loop),
        ])
        XCTAssertEqual(state.channels[1]?.content,
                       .media(MediaInstance(ref: F.mediaA, startedAtFrame: 10, transport: .paused, endBehavior: .clear)))
        XCTAssertEqual(effects, [.applied(.channelEndBehavior(channel: .number(1), mode: .clear)),
                                 .applied(.channelTransport(channel: .number(1), mode: .pause)),
                                 .noop(.channelEndBehavior(channel: .number(2), mode: .loop))])
    }

    func test_missingMediaProducesTheInstanceWithMissingSet() {
        let context = F.context(frame: 100, missing: [F.mediaB])
        let (state, _) = project(F.fresh(), [F.write(1, media: F.mediaB)], context: context)
        XCTAssertEqual(state.channels[1]?.content, .media(MediaInstance(ref: F.mediaB, startedAtFrame: 100, missing: true)))
    }

    func test_channelAllExpandsInNumberOrder() {
        var before = F.fresh()
        for n in 1...3 { before.channels[n]?.content = text("\(n)") }
        let (state, effects) = run(before, [.channelClear(channel: .all)])
        XCTAssertTrue(state.channels.values.allSatisfy { $0.content.isEmpty })
        XCTAssertEqual(effects.compactMap(\.transitionEffect).map(\.channel), [1, 2, 3])
    }

    func test_passThroughAndUnknownCommands() {
        let passing: [Command] = [.timerStart(timer: 1), .undo, .redo, .historyJump(3), .systemPreflight, .systemSnapshot,
                                  .audioMute(audio: .all, state: .on),
                                  .edit(EditCommand(.numbered(.channel, 1), .set(path: "label", value: .string("x"))))]
        let (state, effects) = run(F.fresh(), passing)
        XCTAssertEqual(state, F.fresh())
        XCTAssertEqual(effects, passing.map { .passthrough($0) })

        let unknown: [Command] = [.unknown(cmd: "channel.teleport"), .channelGrade(channel: .number(42), ref: 5, ms: nil),
                                  .channelBuild(channel: .number(1), build: 2)]
        let (state2, effects2) = run(F.fresh(), unknown)
        XCTAssertEqual(state2, F.fresh())
        XCTAssertEqual(effects2, unknown.map { .noop($0) })
    }

    func test_lockIsOperatorStateOutsideTracking() {
        var before = F.fresh()
        before.channels[1]?.lock = true
        let (afterReset, _) = run(before, [.channelReset(channel: .number(1)), .systemClearAll, .listCue(list: 2, cue: 1)], source: .cue)
        XCTAssertEqual(afterReset.channels[1]?.lock, true)
        let (unlocked, _) = run(afterReset, [.channelLock(channel: .number(1), locked: false)], source: .cue)
        XCTAssertEqual(unlocked.channels[1]?.lock, false, "lock and unlock are never blocked")
    }
}
