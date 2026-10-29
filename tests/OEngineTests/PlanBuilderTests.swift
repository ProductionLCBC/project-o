import XCTest
import OCore
@testable import OEngine

/// Spec 4 §4 — the frame plan "built on the control thread from the ShowState,
/// the library and the machine configuration"; §9 — resolving a slot; §2 —
/// render only what is due; §7 — transition progress; §6 — end of media.
final class PlanBuilderTests: XCTestCase {
    var library: Library!
    var machine: Machine!
    var engine: HeadlessEngine!

    override func setUpWithError() throws {
        library = try EngineFixtures.library()
        machine = try EngineFixtures.spikeMachine()
        engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
    }

    // MARK: - Due passes (§2)

    func test_freshStateRendersBothStacksAndNoChannels() throws {
        engine.tick()
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.frame, 0)
        XCTAssertEqual(plan.channelPasses, [], "empty channels have no channel pass")
        XCTAssertEqual(plan.stackPasses.map(\.stack), [1, 2])
        XCTAssertEqual(plan.sinkPasses.map(\.output), [1, 2])
        XCTAssertEqual(plan.stackPasses[0].size, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(plan.stackPasses[0].base, .black)
    }

    func test_textContentHasNoChannelPass() throws {
        engine.send("channel 2 write text \"Verse one\"")
        engine.tick()
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.channelPasses, [])
        let main = try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 })
        // Preset 1 on the main stack: the pixels box draws nothing for text, the fallback body box draws the text.
        XCTAssertEqual(main.boxes.count, 1)
        XCTAssertEqual(main.boxes[0].channel, 2)
        guard case .lines(let lines) = main.boxes[0].content else { return XCTFail("expected text lines") }
        XCTAssertFalse(lines.isEmpty)
    }

    func test_mediaContentRendersOneChannelPassSampledByDueStacks() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.channelPasses.map(\.channel), [1])
        let pass = plan.channelPasses[0]
        XCTAssertEqual(pass.size, PixelSize(width: 1920, height: 1080), "renderSize largest: the largest output size among stacks that include the channel")
        guard case .instance(_, let mediaTime) = pass.incoming.source else { return XCTFail("expected a decoded instance") }
        XCTAssertEqual(mediaTime, 0, accuracy: 0.001, "the write landed on this frame, so media time is the in-point")
        let main = try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(main.boxes.count, 1, "the pixels box drew, so the fallback body box does not")
        guard case .pixels(let quad) = main.boxes[0].content else { return XCTFail("expected a pixels quad") }
        XCTAssertEqual(quad.texture, pass.target)
    }

    func test_channelPassRunsOnlyWhenADueStackSamplesIt() throws {
        // A 30p main output: its stack, and so channel 1, are due every second tick.
        machine = try EngineFixtures.spikeMachine()
        machine.outputs[0].format.rate = FrameRate(num: 30)
        engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        var channelPassesPerTick: [Int] = []
        var stackPassesPerTick: [[Int]] = []
        for _ in 0..<4 {
            engine.tick()
            let plan = try XCTUnwrap(engine.lastPlan)
            channelPassesPerTick.append(plan.channelPasses.count)
            stackPassesPerTick.append(plan.stackPasses.map(\.stack))
        }
        XCTAssertEqual(stackPassesPerTick, [[1, 2], [2], [1, 2], [2]])
        XCTAssertEqual(channelPassesPerTick, [1, 0, 1, 0])
    }

    /// Spec 2 §8 — "Commands take effect on the next engine frame boundary after
    /// they are accepted, so a group of writes lands on the same frame."
    func test_commandsLandOnTheNextTickBoundary() throws {
        engine.tick()   // frame 0
        engine.tick()   // frame 1
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.send("channel 2 write text \"x\"")
        engine.tick()   // frame 2: the plan for this frame carries both writes
        XCTAssertEqual(engine.state.channels[1]?.content.media?.startedAtFrame, 2)
        XCTAssertEqual(engine.state.channels[2]?.content.kind, "text")
        XCTAssertEqual(engine.lastPlan?.channelPasses.map(\.channel), [1])
    }

    // MARK: - Slot resolution (§9)

    func test_slotPresetOutranksStackDefaultOutranksChannelDefault() throws {
        engine.send("list 42 cue 1")   // channel 1 gets dawn, channel 2 the first verse; cue 2 is next
        engine.tick()
        let plan = try XCTUnwrap(engine.lastPlan)
        let confidence = try XCTUnwrap(plan.stackPasses.first { $0.stack == 2 })
        // Stack 2 default preset is 2 (Confidence): a body box and a static [Time] box for the offset-0 slot.
        let liveBoxes = confidence.boxes.filter { $0.offset == 0 }
        XCTAssertEqual(liveBoxes.map(\.binding), [.field(name: "body"), .static(text: "[Time]")])
        XCTAssertEqual(liveBoxes.last?.text, "10:00 AM", "the static box resolves [Time] with the machine's format and zone")
        // The +1 slot names preset 3 (Lower third), whose layout for stack 2 is one body box.
        let offsetBoxes = confidence.boxes.filter { $0.offset == 1 }
        XCTAssertEqual(offsetBoxes.map(\.binding), [.field(name: "body")])
        XCTAssertEqual(offsetBoxes.first?.frame, PixelRect(x: 0.03 * 1920, y: 0.82 * 1080, width: 0.94 * 1920, height: 0.16 * 1080))
        // The main stack has no default preset: channel 2's default preset 1 applies, and its body box draws for text.
        let main = try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(main.boxes.filter { $0.channel == 2 }.map(\.binding), [.field(name: "body")])
    }

    func test_plusOneSlotIsEmptyWithNoListLive() throws {
        engine.send("channel 2 write text \"Title here\"")
        engine.tick()
        let confidence = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        XCTAssertEqual(confidence.boxes.filter { $0.offset == 0 }.map(\.binding), [.field(name: "body"), .static(text: "[Time]")])
        XCTAssertTrue(confidence.boxes.filter { $0.offset == 1 }.isEmpty, "nothing is next, so the slot is empty")
    }

    func test_fallbackBoxDrawsOnlyWhenNoEarlierBoxDrew() throws {
        engine.send("channel 2 write media \(EngineFixtures.dawn)")
        engine.tick()
        let main = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(main.boxes.filter { $0.channel == 2 }.map(\.binding), [.pixels])
    }

    func test_mutedSlotResolvesWithZeroOpacityAndIsSkipped() throws {
        engine.send("channel 2 write text \"x\"")
        engine.send("stack 1 mute 2 on")
        engine.tick()
        let main = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(main.boxes.filter { $0.channel == 2 }.map(\.opacity), [0])
        XCTAssertEqual(main.drawnBoxes.count, 0, "a box with alpha zero is skipped by the pass")
        engine.send("stack 1 mute 2 off")
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.stackPasses.first { $0.stack == 1 }?.drawnBoxes.count, 1, "unmuting is instant")
    }

    func test_slotOpacityMultiplies() throws {
        machine.stacks[0].slots[1].opacity = 0.25
        engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
        engine.send("channel 2 write text \"x\"")
        engine.tick()
        let main = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(main.boxes.first { $0.channel == 2 }?.opacity, 0.25)
    }

    // MARK: - Offset slots (§9, Spec 3 §7)

    func test_plusOneSlotShowsTheNextCuesTextAndEmptyPastTheEnd() throws {
        engine.send("list 42 cue 1")
        engine.tick()
        var confidence = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        XCTAssertEqual(confidence.boxes.first { $0.offset == 0 }?.text, "Great is Thy faithfulness,\nO God my Father")
        XCTAssertEqual(confidence.boxes.first { $0.offset == 1 }?.text, "There is no shadow\nof turning with Thee")
        engine.send("cue 4")
        engine.tick()
        confidence = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        XCTAssertEqual(confidence.boxes.first { $0.offset == 0 }?.text, "Great is Thy faithfulness!\nGreat is Thy faithfulness!")
        XCTAssertNil(confidence.boxes.first { $0.offset == 1 }, "past the end the slot is empty")
    }

    func test_plusOneSlotShowsAPosterFrameForMedia() throws {
        // Cue 1 of list 42 writes dawn to channel 1; a confidence slot for channel 1 at +1 shows its poster.
        machine.stacks[1].slots.append(StackSlot(channel: 1, preset: 1, offset: 1))
        engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
        engine.send("playlist \"Sunday\" 2026-11-01")
        engine.tick()
        let confidence = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        let box = try XCTUnwrap(confidence.boxes.first { $0.channel == 1 && $0.offset == 1 })
        guard case .pixels(let quad) = box.content else { return XCTFail("expected the poster quad") }
        XCTAssertEqual(quad.texture, engine.posterHandle(for: EngineFixtures.dawn))
        XCTAssertEqual(engine.lastPlan?.channelPasses, [], "an offset slot never costs a channel pass")
    }

    // MARK: - Transitions and grades (§7)

    func test_dissolveProgressIsEasedPerTick() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()  // frame 0: landed
        engine.send("channel 1 write media \(EngineFixtures.cross) transition 2 1.0 once")
        engine.tick()  // frame 1: the dissolve lands; 1000 ms = 60 frames
        var pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.transition?.type, .dissolve)
        XCTAssertEqual(pass.transition?.progress ?? -1, 0, accuracy: 0.0001)
        XCTAssertNotNil(pass.outgoing)
        engine.tick(count: 30)  // frame 31: halfway
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.transition?.progress ?? -1, 0.5, accuracy: 0.0001, "easeInOut is symmetric at the midpoint")
        engine.tick(count: 15)  // frame 46: three quarters through, eased
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.transition?.progress ?? -1, Easing.easeInOut.apply(0.75), accuracy: 0.0001)
        engine.tick(count: 15)  // frame 61: done
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertNil(pass.transition)
        XCTAssertNil(pass.outgoing)
    }

    func test_cutHasAZeroDurationTransitionOnTheLandingFrameOnly() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        engine.send("channel 1 write media \(EngineFixtures.cross)")
        engine.tick()
        var pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.transition, TransitionState(type: .cut, progress: 1, color: nil))
        XCTAssertNil(pass.outgoing, "a cut never samples the outgoing content")
        engine.tick()
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertNil(pass.transition)
    }

    func test_fadeThroughColorCarriesItsColour() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        engine.send("channel 1 write media \(EngineFixtures.cross) transition 3 once")
        engine.tick()
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.transition?.type, .fadeThroughColor)
        XCTAssertEqual(pass.transition?.color, ColorValue(r: 0, g: 0, b: 0, a: 1))
    }

    func test_gradeInterpolatesOverItsDuration() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.channelPasses.first?.grade, .identity)
        engine.send("channel 1 grade 1 2.0")   // Warm: hue 8, saturation 1.15, over 120 frames
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.channelPasses.first?.grade.hue ?? -1, 0, accuracy: 0.0001)
        engine.tick(count: 60)
        let halfway = try XCTUnwrap(engine.lastPlan?.channelPasses.first?.grade)
        XCTAssertEqual(halfway.hue, 4, accuracy: 0.001)
        XCTAssertEqual(halfway.saturation, 1.075, accuracy: 0.001)
        XCTAssertEqual(halfway.tint.a, 0.06, accuracy: 0.001)
        engine.tick(count: 60)
        let done = try XCTUnwrap(engine.lastPlan?.channelPasses.first?.grade)
        XCTAssertEqual(done.hue, 8, accuracy: 0.001)
        XCTAssertEqual(done.contrast, 1.1, accuracy: 0.001)
    }

    func test_gradeWithoutDurationAppliesOnTheNextFrame() throws {
        XCTAssertNil(engine.send("channel 1 write media \(EngineFixtures.dawn) grade 1 once"))
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.channelPasses.first?.grade.hue ?? 0, 8, accuracy: 0.001)
    }

    func test_outputSwitchMixesOldAndNewStackAtTheSink() throws {
        engine.send("output 1 stack 2")    // output 1's switch transition is 2: a 500 ms dissolve
        engine.tick()
        var sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.mix, 1, accuracy: 0.0001, "the mix is the amount of the second texture: all of the old stack at the start")
        guard case .stack(let old) = sink.second else { return XCTFail("the old stack is the second texture") }
        XCTAssertEqual(engine.lastPlan?.stackPasses.map(\.stack), [1, 2], "both stacks render during the switch")
        XCTAssertNotEqual(old, sink.stack)
        engine.tick(count: 15)
        sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.mix, 0.5, accuracy: 0.0001)
        engine.tick(count: 15)
        sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.second, .none)
        XCTAssertEqual(engine.lastPlan?.stackPasses.map(\.stack), [2], "stack 1 is no longer due once the switch ends")
    }

    func test_blackoutMixesToBlackAtTheSink() throws {
        engine.send("stack 1 blackout on")    // output 1's blackout transition is 3: 1000 ms fade through black
        engine.tick()
        engine.tick(count: 30)
        var sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.second, .black)
        XCTAssertEqual(sink.mix, 0.5, accuracy: 0.0001)
        engine.tick(count: 30)
        sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.second, .black)
        XCTAssertEqual(sink.mix, 1, accuracy: 0.0001, "blackout holds at full mix")
        engine.send("stack 1 blackout off")
        engine.tick()
        engine.tick(count: 60)
        sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.second, .none)
    }

    // MARK: - Media time and end of media (§6, §2)

    func test_mediaTimeAdvancesWithTheTickForSilentMedia() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn) in 0.5")
        engine.tick()
        engine.tick(count: 30)
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance(_, let mediaTime) = pass.incoming.source else { return XCTFail() }
        XCTAssertEqual(mediaTime, 500 + 30 * 1000.0 / 60, accuracy: 0.01)
    }

    func test_pauseHoldsMediaTimeAndPlayResumes() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        engine.tick(count: 6)
        engine.send("channel 1 pause")
        engine.tick()
        engine.tick(count: 12)
        var pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance(_, let paused) = pass.incoming.source else { return XCTFail() }
        XCTAssertEqual(paused, 7 * 1000.0 / 60, accuracy: 0.01)
        engine.send("channel 1 play")
        engine.tick()
        engine.tick(count: 6)
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance(_, let resumed) = pass.incoming.source else { return XCTFail() }
        XCTAssertEqual(resumed, 13 * 1000.0 / 60, accuracy: 0.01)
    }

    func test_stopShowsThePosterFrame() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        engine.send("channel 1 stop")
        engine.tick()
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.incoming.source, .texture(engine.posterHandle(for: EngineFixtures.dawn)))
    }

    func test_loopingMediaWrapsItsMediaTime() throws {
        // dawn is 2000 ms long and loops by its pool default.
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        engine.tick(count: 150)   // 2500 ms in
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance(_, let mediaTime) = pass.incoming.source else { return XCTFail() }
        XCTAssertEqual(mediaTime, 500, accuracy: 0.01)
    }

    func test_endBehaviourHoldKeepsTheLastFrame() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        XCTAssertNil(engine.send("channel 1 end hold"))
        engine.tick()
        engine.tick(count: 150)
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance(_, let mediaTime) = pass.incoming.source else { return XCTFail() }
        XCTAssertEqual(mediaTime, 2000, accuracy: 0.01, "held at the out-point")
    }

    /// Spec 4 §6 — "`clear` asks the control thread to issue `channel N clear`
    /// with source `engine`".
    func test_endBehaviourClearIssuesAClearFromTheEngine() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        XCTAssertNil(engine.send("channel 1 end clear"))
        engine.tick()
        engine.tick(count: 121)
        XCTAssertTrue(engine.state.channels[1]?.content.isEmpty ?? false)
        XCTAssertEqual(engine.state.channels[1]?.provenance, .source(.engine))
        XCTAssertEqual(engine.lastPlan?.channelPasses, [])
    }

    /// Spec 3 §5 — "The engine clock reaches `at`" fires the armed trigger.
    func test_armedTriggerFiresNextWhenTheClockReachesIt() throws {
        engine.send("list 42 cue 2")   // cue 3 has a Time trigger of 8 s: armed at frame + 480
        engine.tick()
        let armed = try XCTUnwrap(engine.state.armed)
        XCTAssertEqual(armed.cueUuid, EngineFixtures.list42Cues[2])
        engine.tick(count: Int(armed.atFrame) - Int(engine.frame) - 1)
        XCTAssertEqual(engine.state.pointer?.cueUuid, EngineFixtures.list42Cues[1])
        engine.tick()
        XCTAssertEqual(engine.state.pointer?.cueUuid, EngineFixtures.list42Cues[2])
        XCTAssertEqual(engine.lastExecuted.first?.source.kind, .scheduler, "the navigation is logged first, then the cue's commands")
        XCTAssertEqual(engine.lastExecuted.first?.command, .next)
    }

    // MARK: - Decoder budget (Spec 3 §4, Spec 4 §16)

    func test_steppedOnCutsTheDroppedInstanceOut() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        let first = try XCTUnwrap(engine.sources(onChannel: 1).first)
        engine.send("channel 1 write media \(EngineFixtures.cross) transition 2 1.0 once")
        engine.tick()
        XCTAssertEqual(engine.sources(onChannel: 1).count, 2, "the outgoing keeps its decoder through the dissolve")
        XCTAssertTrue(engine.sources(onChannel: 1).contains(first))
        engine.send("channel 1 write media \(EngineFixtures.dawn) transition 2 1.0 once")
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.last?.result, .steppedOn)
        let held = engine.sources(onChannel: 1)
        XCTAssertFalse(held.contains(first), "the stepped-on instance was cut out")
        XCTAssertLessThanOrEqual(held.count, 2, "the cap holds")
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.outgoing?.layout, .linearRGBA16, "the interrupted dissolve continues from a snapshot of the picture")
        XCTAssertTrue(pass.snapshotOutgoing)
        guard case .instance(let live, _) = pass.incoming.source else { return XCTFail("the new instance is live") }
        XCTAssertNotEqual(live, first)
    }

    // MARK: - Missing media and cold writes (§6)

    func test_missingMediaRendersNothing() throws {
        engine.send("channel 1 write media \(EngineFixtures.mountains)")
        engine.tick()
        XCTAssertEqual(engine.state.channels[1]?.content.media?.missing, true)
        XCTAssertEqual(engine.lastPlan?.channelPasses, [])
    }

    func test_coldWriteShowsThePosterUntilTheFirstFrameThenStartsItsTransition() throws {
        engine.sourceFactory.readyAfterTicks = 3
        engine.send("channel 1 write media \(EngineFixtures.cross)")
        engine.tick()
        engine.send("channel 1 write media \(EngineFixtures.dawn) transition 2 1.0 once")
        engine.tick()
        var pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.incoming.source, .texture(engine.posterHandle(for: EngineFixtures.dawn)), "the poster lands on the tick")
        XCTAssertNil(pass.transition, "the dissolve waits for the first decoded frame")
        engine.tick(count: 3)
        pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        guard case .instance = pass.incoming.source else { return XCTFail("decoded frames now") }
        XCTAssertEqual(pass.transition?.progress ?? -1, 0, accuracy: 0.0001, "and the dissolve starts now")
    }
}
