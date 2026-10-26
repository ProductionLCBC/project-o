import XCTest
@testable import OCore

/// Spec 3 §9 — the test table, one test per row, named after its row number.
/// Frames are at 60 fps; channel defaults are transition 1 (cut), no grade,
/// gain 0; `A`, `B`, `C` are media ids; `S` is a slide.
final class ProjectionTableTests: XCTestCase {
    typealias F = Fixtures

    // MARK: - Helpers

    private func run(_ state: ShowState, _ commands: [Command], frame: Int, source: SourceKind = .ui,
                     library: Library = F.library, machine: Machine = F.machine) -> (ShowState, [Effect]) {
        project(state, commands, context: F.context(frame: frame, source: source, library: library, machine: machine))
    }

    private func media(_ ref: String, startedAt frame: Int, transport: Transport = .playing) -> ContentInstance {
        .media(MediaInstance(ref: ref, startedAtFrame: frame, transport: transport))
    }

    private func text(_ body: String) -> ContentInstance {
        .text(TextInstance(fields: ["body": body]))
    }

    private func channel(_ n: Int, in state: ShowState, file: StaticString = #filePath, line: UInt = #line) -> ChannelState {
        guard let ch = state.channels[n] else {
            XCTFail("channel \(n) missing", file: file, line: line)
            return ChannelState(attributes: .defaults(for: ChannelDefaults()))
        }
        return ch
    }

    private func transitions(in effects: [Effect]) -> [TransitionEffect] {
        effects.compactMap(\.transitionEffect)
    }

    private var defaultAttributes: ChannelAttributes {
        .defaults(for: ChannelDefaults(transition: 1, audioTransition: 1, gain: 0))
    }

    /// Row 1's resulting state, reused by row 2.
    private func stateAfterRow1() -> ShowState {
        run(F.fresh(), [F.write(1, media: F.mediaA)], frame: 100).0
    }

    /// Row 4's resulting state, reused by row 5.
    private func stateAfterRow4() -> ShowState {
        run(F.fresh(), [.channelGrade(channel: .number(2), ref: 5, ms: nil), F.write(2, text: "y")], frame: 100).0
    }

    // MARK: - Rows

    /// Row 1 — Fresh state, frame 100: `channel 1 write media A`.
    /// Content A, `startedAtFrame` 100, playing; one `transition` effect
    /// empty to A, ref 1, 0 ms.
    func test_row01_writeMediaOnFreshState() {
        let (state, effects) = run(F.fresh(), [F.write(1, media: F.mediaA)], frame: 100)
        let expected = media(F.mediaA, startedAt: 100)
        XCTAssertEqual(channel(1, in: state).content, expected)
        XCTAssertEqual(channel(1, in: state).provenance, .source(.ui))
        XCTAssertEqual(effects, [.transition(TransitionEffect(
            channel: 1, from: .empty, to: expected, transition: 1, ms: 0, audioTransition: 1, audioMs: 0))])
    }

    /// Row 2 — After 1, frame 400: `channel 1 write media A`.
    /// Same ref, `startedAtFrame` 400; `transition` effect marked restart
    /// from current frame.
    func test_row02_rewriteSameMediaRestarts() {
        let before = stateAfterRow1()
        let (state, effects) = run(before, [F.write(1, media: F.mediaA)], frame: 400)
        XCTAssertEqual(channel(1, in: state).content, media(F.mediaA, startedAt: 400))
        XCTAssertEqual(channel(1, in: state).outgoing, [], "a restart keeps one decoder; nothing goes outgoing")
        XCTAssertEqual(effects, [.transition(TransitionEffect(
            channel: 1, from: media(F.mediaA, startedAt: 100), to: media(F.mediaA, startedAt: 400),
            transition: 1, ms: 0, audioTransition: 1, audioMs: 0, restart: true))])
    }

    /// Row 3 — Fresh: `channel 2 write text "x"` twice.
    /// Second command yields `noop`; one state change total.
    func test_row03_identicalTextIsNoop() {
        let write = F.write(2, text: "x")
        let (afterOne, _) = run(F.fresh(), [write], frame: 100)
        let (afterTwo, effects) = run(F.fresh(), [write, write], frame: 100)
        XCTAssertEqual(effects.count, 2)
        XCTAssertEqual(effects.last, .noop(write))
        XCTAssertNotNil(effects.first?.transitionEffect)
        XCTAssertEqual(afterTwo, afterOne, "one state change total")
        XCTAssertEqual(channel(2, in: afterTwo).content, text("x"))
    }

    /// Row 4 — Fresh: `channel 2 grade 5 track`, then `channel 2 write text "y"`.
    /// Grade 5 with origin `tracked` after both; content y.
    func test_row04_trackedGradeSurvivesContentWrite() {
        let grade = Command.channelGrade(channel: .number(2), ref: 5, ms: nil)
        let (afterGrade, gradeEffects) = run(F.fresh(), [grade], frame: 100)
        XCTAssertEqual(channel(2, in: afterGrade).attributes.grade, Tracked(value: 5, origin: .tracked, shadow: nil))
        XCTAssertEqual(gradeEffects, [.attribute(channel: 2, attribute: .grade, old: .grade(0), new: .grade(5), ms: nil)])

        let (afterWrite, _) = run(afterGrade, [F.write(2, text: "y")], frame: 101)
        XCTAssertEqual(channel(2, in: afterWrite).attributes.grade, Tracked(value: 5, origin: .tracked, shadow: nil))
        XCTAssertEqual(channel(2, in: afterWrite).content, text("y"))
    }

    /// Row 5 — After 4: `channel 2 write text "y" grade 6 once`, then
    /// `channel 2 write text "z"`. Grade 6 (`once`, shadow 5) after the
    /// first; grade 5 (`tracked`) after the second.
    func test_row05_onceGradeFallsBackToShadow() {
        let before = stateAfterRow4()
        let once = F.write(2, text: "y", riders: Riders(grade: GradeRider(ref: 6, scope: .once)))
        let (afterOnce, onceEffects) = run(before, [once], frame: 200)
        XCTAssertEqual(channel(2, in: afterOnce).attributes.grade, Tracked(value: 6, origin: .once, shadow: 5))
        XCTAssertEqual(channel(2, in: afterOnce).content, text("y"))
        XCTAssertTrue(onceEffects.contains(.attribute(channel: 2, attribute: .grade, old: .grade(5), new: .grade(6), ms: nil)))

        let (afterNext, nextEffects) = run(afterOnce, [F.write(2, text: "z")], frame: 300)
        XCTAssertEqual(channel(2, in: afterNext).attributes.grade, Tracked(value: 5, origin: .tracked, shadow: nil))
        XCTAssertEqual(channel(2, in: afterNext).content, text("z"))
        XCTAssertTrue(nextEffects.contains(.attribute(channel: 2, attribute: .grade, old: .grade(6), new: .grade(5), ms: nil)))
    }

    /// Row 6 — Fresh: `channel 2 write text "y" transition 2 500 once`, then
    /// `channel 2 write text "z"`. First effect uses ref 2, 500 ms; second
    /// effect uses ref 1, 0 ms; attribute ends at default.
    func test_row06_onceTransitionAppliesThenFallsBackToDefault() {
        let once = F.write(2, text: "y", riders: Riders(transition: TransitionRider(ref: 2, ms: 500, scope: .once)))
        let (afterOnce, onceEffects) = run(F.fresh(), [once], frame: 100)
        let first = transitions(in: onceEffects)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.transition, 2)
        XCTAssertEqual(first.first?.ms, 500)
        XCTAssertEqual(channel(2, in: afterOnce).attributes.transition,
                       Tracked(value: TransitionSetting(ref: 2, ms: 500), origin: .once, shadow: nil))

        let (afterNext, nextEffects) = run(afterOnce, [F.write(2, text: "z")], frame: 200)
        let second = transitions(in: nextEffects)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first?.transition, 1)
        XCTAssertEqual(second.first?.ms, 0)
        XCTAssertEqual(channel(2, in: afterNext).attributes.transition, .defaulted(TransitionSetting(ref: 1)))
    }

    /// Row 7 — Pointer in list L1, grade 5 tracked on channel 2. Fire a cue
    /// in list L2 (`trackThrough` false). `boundary` effect; grade default;
    /// content unchanged.
    func test_row07_listBoundaryResetsTrackedAttributes() {
        var before = F.fresh()
        before.pointer = F.pointer(list: 1, cue: 1)
        before.channels[2]?.content = text("verse 1")
        before.channels[2]?.attributes.grade = Tracked(value: 5, origin: .tracked)

        let (state, effects) = run(before, [.listCue(list: 2, cue: 2)], frame: 100)
        XCTAssertTrue(effects.contains(.boundary(list: F.listUuid(2), reset: true)), "\(effects)")
        XCTAssertEqual(channel(2, in: state).attributes.grade, .defaulted(0))
        XCTAssertEqual(channel(2, in: state).content, text("verse 1"))
        XCTAssertEqual(state.pointer, F.pointer(list: 2, cue: 2))
    }

    /// Row 8 — As 7 but L2 has `trackThrough`. Fire a cue in L2.
    /// No reset; grade 5 remains; no `boundary` reset list.
    func test_row08_trackThroughKeepsAttributesAcrossBoundary() {
        var before = F.fresh()
        before.pointer = F.pointer(list: 1, cue: 1)
        before.channels[2]?.content = text("verse 1")
        before.channels[2]?.attributes.grade = Tracked(value: 5, origin: .tracked)

        let (state, effects) = run(before, [.listCue(list: 6, cue: 2)], frame: 100)
        XCTAssertFalse(effects.contains(.boundary(list: F.listUuid(6), reset: true)))
        XCTAssertEqual(channel(2, in: state).attributes.grade, Tracked(value: 5, origin: .tracked))
        XCTAssertEqual(channel(2, in: state).content, text("verse 1"))
        XCTAssertEqual(state.pointer, F.pointer(list: 6, cue: 2))
    }

    /// Row 9 — Channel 1 playing A, grade 5 tracked: `channel 1 clear`.
    /// Content empty; grade still 5; `transition` effect to empty with the
    /// current transition.
    func test_row09_clearIsContentOnly() {
        var before = F.fresh()
        before.channels[1]?.content = media(F.mediaA, startedAt: 10)
        before.channels[1]?.attributes.grade = Tracked(value: 5, origin: .tracked)
        before.channels[1]?.attributes.transition = Tracked(value: TransitionSetting(ref: 2), origin: .tracked)

        let clear = Command.channelClear(channel: .number(1))
        let (state, effects) = run(before, [clear], frame: 100)
        XCTAssertEqual(channel(1, in: state).content, .empty)
        XCTAssertEqual(channel(1, in: state).attributes.grade, Tracked(value: 5, origin: .tracked))
        XCTAssertEqual(channel(1, in: state).attributes.transition,
                       Tracked(value: TransitionSetting(ref: 2), origin: .tracked))
        XCTAssertEqual(effects, [.transition(TransitionEffect(
            channel: 1, from: media(F.mediaA, startedAt: 10), to: .empty, transition: 2, ms: 500,
            audioTransition: 1, audioMs: 0))])
    }

    /// Row 10 — Several channels with content and tracked attributes:
    /// `system clearall`. Every channel empty, every attribute `{default, default}`.
    func test_row10_clearAllResetsEverything() {
        var before = F.fresh()
        before.channels[1]?.content = media(F.mediaA, startedAt: 10)
        before.channels[1]?.attributes.grade = Tracked(value: 5, origin: .tracked)
        before.channels[2]?.content = text("verse")
        before.channels[2]?.attributes.transition = Tracked(value: TransitionSetting(ref: 2, ms: 250), origin: .once, shadow: nil)
        before.channels[3]?.content = .slide(SlideInstance(ref: F.slideS, build: 2))
        before.channels[3]?.attributes.gain = Tracked(value: -6, origin: .tracked)

        let (state, effects) = run(before, [.systemClearAll], frame: 100)
        for n in 1...3 {
            XCTAssertEqual(channel(n, in: state).content, .empty, "channel \(n)")
            XCTAssertEqual(channel(n, in: state).attributes, defaultAttributes, "channel \(n)")
        }
        XCTAssertEqual(channel(1, in: state).outgoing, [OutgoingInstance(instance: MediaInstance(ref: F.mediaA, startedAtFrame: 10), endsAtFrame: 100)],
                       "the clear is a write of empty, so A goes outgoing until its (cut) transition ends")
        XCTAssertEqual(transitions(in: effects).map(\.channel), [1, 2, 3])
        XCTAssertFalse(effects.contains(.noop(.systemClearAll)))
    }

    /// Row 11 — Channel 1 playing A, grade 5 tracked: `channel 1 reset`.
    /// Grade default; content A unchanged, `startedAtFrame` unchanged.
    func test_row11_resetIsAttributesOnly() {
        var before = F.fresh()
        before.channels[1]?.content = media(F.mediaA, startedAt: 10)
        before.channels[1]?.attributes.grade = Tracked(value: 5, origin: .tracked)

        let (state, effects) = run(before, [.channelReset(channel: .number(1))], frame: 100)
        XCTAssertEqual(channel(1, in: state).attributes, defaultAttributes)
        XCTAssertEqual(channel(1, in: state).content, media(F.mediaA, startedAt: 10))
        XCTAssertEqual(effects, [.attribute(channel: 1, attribute: .grade, old: .grade(5), new: .grade(0), ms: nil)])
    }

    /// Row 12 — Channel 2 locked. Cue group writes channel 2.
    /// `blocked` effect; channel 2 unchanged; other channels in the group written.
    func test_row12_lockBlocksCueWrites() {
        var before = F.fresh()
        before.channels[2]?.lock = true
        before.channels[2]?.content = text("held")
        let writeTwo = F.write(2, text: "new")
        let writeThree = F.write(3, text: "also new")

        let (state, effects) = run(before, [writeTwo, writeThree], frame: 100, source: .cue)
        XCTAssertEqual(channel(2, in: state), channel(2, in: before))
        XCTAssertEqual(channel(3, in: state).content, text("also new"))
        XCTAssertEqual(effects.first, .blocked(channel: 2, command: writeTwo))
        XCTAssertEqual(transitions(in: effects).map(\.channel), [3])
    }

    /// Row 13 — Channel 2 locked. Same write with source `osc`. Write applies.
    func test_row13_lockIgnoresOtherSources() {
        var before = F.fresh()
        before.channels[2]?.lock = true
        before.channels[2]?.content = text("held")

        let (state, effects) = run(before, [F.write(2, text: "new")], frame: 100, source: .osc)
        XCTAssertEqual(channel(2, in: state).content, text("new"))
        XCTAssertTrue(channel(2, in: state).lock)
        XCTAssertEqual(transitions(in: effects).map(\.channel), [2])
    }

    /// Row 14 — Cap 2; A playing; frame 100: `write B transition 2 1000 once`
    /// at frame 100, then `write C` at frame 110. After B: outgoing A ends at
    /// frame 160. After C: `steppedOn` A; outgoing is B; content C.
    func test_row14_decoderBudgetStepsOnOldestOutgoing() {
        var before = F.fresh()
        let a = MediaInstance(ref: F.mediaA, startedAtFrame: 50)
        before.channels[1]?.content = .media(a)

        let writeB = F.write(1, media: F.mediaB, riders: Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))
        let (afterB, bEffects) = run(before, [writeB], frame: 100)
        XCTAssertEqual(channel(1, in: afterB).outgoing, [OutgoingInstance(instance: a, endsAtFrame: 160)])
        XCTAssertEqual(channel(1, in: afterB).content, media(F.mediaB, startedAt: 100))
        XCTAssertFalse(bEffects.contains { if case .steppedOn = $0 { return true } else { return false } })

        let (afterC, cEffects) = run(afterB, [F.write(1, media: F.mediaC)], frame: 110)
        XCTAssertTrue(cEffects.contains(.steppedOn(channel: 1, dropped: F.mediaA)), "\(cEffects)")
        XCTAssertEqual(channel(1, in: afterC).outgoing,
                       [OutgoingInstance(instance: MediaInstance(ref: F.mediaB, startedAtFrame: 100), endsAtFrame: 110)])
        XCTAssertEqual(channel(1, in: afterC).content, media(F.mediaC, startedAt: 110))
    }

    /// Row 15 — Tracking switch for grade off: `channel 2 grade 5`, then
    /// `channel 2 write text "y"`. Grade 5 (`once`) after the first; default
    /// after the second.
    func test_row15_trackingSwitchOffMakesWritesOnce() {
        var machine = F.machine
        machine.tracking.grade = false

        let (afterGrade, _) = run(F.fresh(), [.channelGrade(channel: .number(2), ref: 5, ms: nil)], frame: 100, machine: machine)
        XCTAssertEqual(channel(2, in: afterGrade).attributes.grade, Tracked(value: 5, origin: .once, shadow: nil))

        let (afterWrite, _) = run(afterGrade, [F.write(2, text: "y")], frame: 101, machine: machine)
        XCTAssertEqual(channel(2, in: afterWrite).attributes.grade, .defaulted(0))
    }

    /// Row 16 — Pointer on the last cue of the last item: `next`.
    /// `noop`; pointer unchanged; nothing armed.
    func test_row16_nextPastTheEndIsNoop() {
        var before = F.fresh()
        before.pointer = F.pointer(item: 5, list: 3, cue: 2)

        let (state, effects) = run(before, [.next], frame: 100)
        XCTAssertEqual(effects, [.noop(.next)])
        XCTAssertEqual(state.pointer, before.pointer)
        XCTAssertNil(state.armed)
        XCTAssertEqual(state, before)
    }

    /// Row 17 — Pointer on the last cue of item 3; item 4 is a header, item 5
    /// a different list: `next`. Pointer on item 5 cue 1; `boundary` effect;
    /// header skipped.
    func test_row17_nextCrossesItemsAndSkipsHeaders() {
        var before = F.fresh()
        before.pointer = F.pointer(item: 3, list: 2, cue: 2)
        before.channels[2]?.attributes.grade = Tracked(value: 5, origin: .tracked)

        let (state, effects) = run(before, [.next], frame: 100)
        XCTAssertEqual(state.pointer, F.pointer(item: 5, list: 3, cue: 1))
        XCTAssertTrue(effects.contains(.boundary(list: F.listUuid(3), reset: true)), "\(effects)")
        XCTAssertEqual(channel(1, in: state).content, media(F.mediaC, startedAt: 100))
        XCTAssertEqual(channel(2, in: state).attributes.grade, .defaulted(0))
        XCTAssertEqual(effects.last, .pointer(old: before.pointer, new: state.pointer, armed: nil))
    }

    /// Row 18 — Live: channel 2 text y; next two cues write channel 2 z then
    /// nothing. Lookahead +1, +2: both resolve to z; +3 past the end resolves
    /// to empty.
    func test_row18_lookaheadHoldsAndEndsEmpty() {
        var live = F.fresh()
        live.pointer = F.pointer(list: 5, cue: 1)
        live.channels[2]?.content = text("y")
        let context = F.context(frame: 1000, source: .engine)

        let plusOne = lookahead(live, steps: 1, context: context)
        XCTAssertEqual(plusOne.map { channel(2, in: $0).content }, text("z"))
        let plusTwo = lookahead(live, steps: 2, context: context)
        XCTAssertEqual(plusTwo.map { channel(2, in: $0).content }, text("z"))
        XCTAssertEqual(plusTwo.map { channel(1, in: $0).content }, media(F.mediaA, startedAt: 1000),
                       "frame held at the current frame so nothing appears to play")
        XCTAssertNil(lookahead(live, steps: 3, context: context), "past the end the slot is empty")
    }

    /// Row 19 — Fresh: `write slide S build 2`, then `write slide S build 3`,
    /// then `write slide S build 3`. `transition` then `build` 2 to 3 then `noop`.
    func test_row19_sameSlideDifferentBuildAnimates() {
        let build2 = F.write(1, slide: F.slideS, build: 2)
        let build3 = F.write(1, slide: F.slideS, build: 3)
        let (state, effects) = run(F.fresh(), [build2, build3, build3], frame: 100)
        XCTAssertEqual(effects.count, 3)
        XCTAssertEqual(effects[0].transitionEffect?.to, .slide(SlideInstance(ref: F.slideS, build: 2)))
        XCTAssertEqual(effects[1], .build(channel: 1, from: 2, to: 3))
        XCTAssertEqual(effects[2], .noop(build3))
        XCTAssertEqual(channel(1, in: state).content, .slide(SlideInstance(ref: F.slideS, build: 3)))
    }

    /// Row 20 — Cue 1 fired at frame 100; cue 2 has Time 5 s: fire cue 1,
    /// then `cue 7` manually at frame 200. After fire: `armed` {cue 2, frame
    /// 400}. After manual fire: `armed` cleared.
    func test_row20_timeTriggerArmsAndManualFireDisarms() {
        let (afterOne, oneEffects) = run(F.fresh(), [.listCue(list: 4, cue: 1)], frame: 100)
        let expectedArmed = ArmedTrigger(cueUuid: F.cueUuid(list: 4, cue: 2), atFrame: 400)
        XCTAssertEqual(afterOne.armed, expectedArmed)
        XCTAssertEqual(afterOne.pointer, F.pointer(list: 4, cue: 1))
        XCTAssertEqual(oneEffects.last, .pointer(old: nil, new: afterOne.pointer, armed: expectedArmed))

        let (afterSeven, sevenEffects) = run(afterOne, [.cue(7)], frame: 200)
        XCTAssertNil(afterSeven.armed)
        XCTAssertEqual(afterSeven.pointer, F.pointer(list: 4, cue: 7))
        XCTAssertEqual(sevenEffects.last, .pointer(old: afterOne.pointer, new: afterSeven.pointer, armed: nil))
    }

    /// Row 21 — Cue 1 has advance-after 8 s; cue 2 has Time 5 s: fire cue 1
    /// at frame 100. `armed` at frame 400 (the shorter wins).
    func test_row21_shorterOfAdvanceAfterAndTimeWins() {
        var library = F.library
        library.lists = library.lists.map { $0.number == 4 ? F.triggerList(advanceAfterMs: 8000) : $0 }
        let (state, _) = run(F.fresh(), [.listCue(list: 4, cue: 1)], frame: 100, library: library)
        XCTAssertEqual(state.armed, ArmedTrigger(cueUuid: F.cueUuid(list: 4, cue: 2), atFrame: 400))

        // And the other way round: advance-after shorter than Time.
        library.lists = library.lists.map { $0.number == 4 ? F.triggerList(advanceAfterMs: 2000) : $0 }
        let (state2, _) = run(F.fresh(), [.listCue(list: 4, cue: 1)], frame: 100, library: library)
        XCTAssertEqual(state2.armed, ArmedTrigger(cueUuid: F.cueUuid(list: 4, cue: 2), atFrame: 220))
    }

    /// Row 22 — Channel 1 playing A: `channel 1 stop`. `transport: stopped`,
    /// `startedAtFrame` = landing frame; a text channel given `stop` yields `noop`.
    func test_row22_stopRewindsAndIsNoopOnText() {
        var before = F.fresh()
        before.channels[1]?.content = media(F.mediaA, startedAt: 100)
        before.channels[2]?.content = text("y")

        let stopOne = Command.channelTransport(channel: .number(1), mode: .stop)
        let stopTwo = Command.channelTransport(channel: .number(2), mode: .stop)
        let (state, effects) = run(before, [stopOne, stopTwo], frame: 300)
        XCTAssertEqual(channel(1, in: state).content, media(F.mediaA, startedAt: 300, transport: .stopped))
        XCTAssertEqual(channel(2, in: state).content, text("y"))
        XCTAssertEqual(effects, [.applied(stopOne), .noop(stopTwo)])
    }

    /// Row 23 — Any state: `timer 1 set 5:00`. `passthrough` effect; state unchanged.
    func test_row23_timerCommandsPassThrough() {
        var before = F.fresh()
        before.channels[1]?.content = media(F.mediaA, startedAt: 100)
        let timer = Command.timerSet(timer: 1, ms: 300_000)
        let (state, effects) = run(before, [timer], frame: 500)
        XCTAssertEqual(state, before)
        XCTAssertEqual(effects, [.passthrough(timer)])
    }

    /// Row 24 — Any state and context: same inputs twice. Identical outputs.
    func test_row24_determinism() {
        var before = F.fresh()
        before.pointer = F.pointer(item: 2, list: 1, cue: 1)
        before.channels[1]?.content = media(F.mediaA, startedAt: 10)
        before.channels[2]?.attributes.grade = Tracked(value: 5, origin: .tracked)
        let commands: [Command] = [
            F.write(1, media: F.mediaB, riders: Riders(transition: TransitionRider(ref: 2, ms: nil, scope: .once))),
            .channelGrade(channel: .number(2), ref: 6, ms: 1000),
            .next,
            .stackBlackout(stack: 1, state: .toggle),
            .popupSet(popup: 1, text: "Nursery", clearAfterMs: 30_000),
            .timerSet(timer: 1, ms: 1000),
            .next,
            .macro(1),
        ]
        let first = run(before, commands, frame: 777, source: .osc)
        let second = run(before, commands, frame: 777, source: .osc)
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
    }
}
