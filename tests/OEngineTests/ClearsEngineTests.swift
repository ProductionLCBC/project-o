import XCTest
import OCore
@testable import OEngine

/// Spec 10 §7 — the Clears tab's tiles "each send one command": Blackout All
/// (`stack all blackout toggle`) and Mute All Audio (`audio all mute
/// toggle`), where "With `all`, `toggle` turns every one on unless every one
/// is already on, when it turns them all off (Spec 2 §3) ... so a stack
/// blacked out on purpose never comes back by mistake." Spec 4 §10 — "blackout
/// mixes to black over the blackout transition" at each output's sink; Spec 4
/// §11 — "`audio all mute` is one command over every device".
final class ClearsEngineTests: XCTestCase {
    var engine: HeadlessEngine!

    override func setUpWithError() throws {
        engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(),
                                    mediaRoot: EngineFixtures.mediaRoot)
    }

    private func sink(_ output: Int) throws -> SinkPass {
        try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == output })
    }

    // MARK: - Spec 2 §3, `stack all blackout`

    /// Both outputs fade to black on the same tick, each over its own blackout
    /// transition: output 1's is 3 (1000 ms), output 2's is 2.
    func test_stackAllBlackoutOnFadesEveryOutputWithItsOwnTransition() throws {
        XCTAssertNil(engine.send("stack all blackout on"))
        engine.tick()
        XCTAssertEqual(engine.state.stacks[1]?.blackout, true)
        XCTAssertEqual(engine.state.stacks[2]?.blackout, true)
        let effects = engine.lastExecuted.flatMap(\.effects)
        XCTAssertEqual(effects, [.blackout(stack: 1, old: false, new: true, transition: 3),
                                 .blackout(stack: 2, old: false, new: true, transition: 2)])
        engine.tick(count: 120)
        XCTAssertEqual(try sink(1).second, .black)
        XCTAssertEqual(try sink(1).mix, 1, accuracy: 0.0001)
        XCTAssertEqual(try sink(2).second, .black)
        XCTAssertEqual(try sink(2).mix, 1, accuracy: 0.0001)
    }

    /// With stack 1 already black, Blackout All turns on only stack 2, and the
    /// OSC feedback is one `/o/stack/2/blackout i:1`; pressed again, both off.
    func test_blackoutAllLeavesAStackBlackedOutOnPurpose() throws {
        engine.send("stack 1 blackout on")
        engine.tick()
        engine.send("stack all blackout toggle")
        engine.tick()
        XCTAssertEqual(engine.lastExecuted.flatMap(\.effects), [.blackout(stack: 2, old: false, new: true, transition: 2)])
        let feedback = OSCFeedbackDeriver.messages(for: engine.lastExecuted, state: engine.state,
                                                   library: engine.engine.library, machine: engine.engine.machine)
        XCTAssertEqual(feedback, [OSCFeedback.stackBlackout(2, on: true)])

        engine.send("stack all blackout toggle")
        engine.tick()
        XCTAssertEqual(engine.state.stacks[1]?.blackout, false)
        XCTAssertEqual(engine.state.stacks[2]?.blackout, false)
        let off = OSCFeedbackDeriver.messages(for: engine.lastExecuted, state: engine.state,
                                              library: engine.engine.library, machine: engine.engine.machine)
        XCTAssertEqual(off, [OSCFeedback.stackBlackout(1, on: false), OSCFeedback.stackBlackout(2, on: false)])
    }

    // MARK: - Spec 2 §3, `audio all mute toggle`

    /// With output 1 muted, Mute All Audio mutes both; pressed again, it
    /// unmutes both. Before Area 15 each output flipped on its own, so the
    /// first press unmuted output 1.
    func test_muteAllAudioTurnsEveryOneOnUnlessEveryOneIsOn() throws {
        XCTAssertEqual(engine.control.mutedAudioOutputs, [])
        engine.send("audio 1 mute on")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [1])
        engine.send("audio all mute toggle")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [1, 2])
        engine.send("audio all mute toggle")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [])
        engine.send("audio all mute toggle")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [1, 2])
        engine.send("audio all mute off")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [])
    }

    func test_audioMuteOfOneOutputTogglesThatOutput() throws {
        engine.send("audio 2 mute toggle")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [2])
        engine.send("audio 2 mute toggle")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [])
    }

    /// A number that is no audio output of this machine changes nothing; the
    /// validator rejects it when sent directly, so it arrives through a macro.
    func test_anUnknownAudioOutputChangesNothing() throws {
        var library = try EngineFixtures.library()
        library.macros.append(Macro(number: 40, commands: [GuardedCommand(.audioMute(audio: .number(9), state: .on))]))
        engine = try HeadlessEngine(library: library, machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        engine.send("macro 40")
        engine.tick()
        XCTAssertEqual(engine.control.mutedAudioOutputs, [])
    }
}
