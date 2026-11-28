import XCTest
import OCore
@testable import OEngine

/// Spec 4 §9 as corrected 2026-11-25 (Adam: "Override") — a box draws a change "mixed by the transition Spec 3 §4
/// chooses for the change: the write's `once` rider, else the channel's tracked transition, else the box's own
/// transition when it sets one, else the channel's default"; "A box whose content appears from nothing mixes from
/// transparent, so a dissolve fades it in". The fixture's channel 2 defaults to transition 1, a cut; transition 2 is a
/// dissolve. Stack 2's slot for channel 2 draws the preset under test.
final class BoxTransitionChoiceTests: XCTestCase {
    typealias S = StageFixtures

    private func live(_ engine: HeadlessEngine) -> ResolvedBox? { engine.boxes(stack: 2, channel: 2).first { $0.offset == 0 } }

    /// The engine with one body box of `transition` on stack 2's slot for channel 2, cue 1 of list 51 ("a") live.
    private func engine(_ transition: BoxTransition?) throws -> HeadlessEngine {
        var body = S.body(0)
        body.transition = transition
        let engine = try S.engine(preset: S.preset(8, boxes: [body]))
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        XCTAssertEqual(engine.texts(), [0: "a"])
        return engine
    }

    func test_aBoxWithNoTransitionOfItsOwnTakesTheChannels() throws {
        let engine = try engine(nil)
        // The channel's default: a cut.
        engine.send("channel 2 write text \"b\"")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "b"])
        XCTAssertNil(live(engine)?.transition, "the channel's default cuts")
        // A cue's `once` rider: its dissolve.
        engine.send("channel 2 write text \"c\" transition 2 0.5 once")
        engine.tick()
        XCTAssertEqual(live(engine)?.transition?.type, .dissolve, "the cue's own transition, which was ignored before")
        XCTAssertEqual(engine.control.boxTransitionsStarted[2], 500, "and its length, for the strip's bar")
        // A `track` rider sets the channel's transition from here on.
        engine.tick(count: 40)
        engine.send("channel 2 write text \"d\" transition 2 0.25 track")
        engine.tick()
        XCTAssertEqual(live(engine)?.transition?.type, .dissolve)
        engine.tick(count: 40)
        engine.send("channel 2 write text \"e\"")
        engine.tick()
        XCTAssertEqual(live(engine)?.transition?.type, .dissolve, "the tracked transition holds for the next write")
        XCTAssertEqual(engine.control.boxTransitionsStarted[2], 250)
    }

    func test_aBoxsOwnTransitionOverridesOnlyTheChannelsDefault() throws {
        let engine = try engine(BoxTransition(ref: 2, ms: 500))
        // The channel's default is a cut; the box's own dissolve takes its place.
        engine.send("channel 2 write text \"b\"")
        engine.tick()
        XCTAssertEqual(live(engine)?.transition?.type, .dissolve, "the box's own, over the channel's default")
        XCTAssertEqual(engine.control.boxTransitionsStarted[2], 500)
        // A cue's `once` cut beats the box's own.
        engine.tick(count: 40)
        engine.send("channel 2 write text \"c\" transition 1 0 once")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "c"])
        XCTAssertNil(live(engine)?.transition, "never one a cue sets")
        XCTAssertNil(engine.control.boxTransitionsStarted[2])
    }

    /// "A box whose content appears from nothing mixes from transparent, so a dissolve fades it in".
    func test_textAppearingOnAnEmptyChannelFadesIn() throws {
        var body = S.body(0)
        body.transition = BoxTransition(ref: 2, ms: 500)
        let engine = try S.engine(preset: S.preset(8, boxes: [body]))
        engine.tick(count: 2)
        XCTAssertEqual(engine.texts(), [:], "nothing on channel 2")
        engine.send("channel 2 write text \"a\"")
        engine.tick()
        let box = try XCTUnwrap(live(engine))
        XCTAssertEqual(box.text, "a")
        XCTAssertEqual(box.transition?.type, .dissolve, "it fades in")
        XCTAssertEqual(box.transition?.outgoing, BoxContent.lines([]), "from nothing")
        engine.tick(count: 40)
        XCTAssertNil(live(engine)?.transition)
    }

    /// A pixel box's own transition is never read: "a pixel box always takes the channel's".
    func test_aPixelBoxRunsNoTransitionOfItsOwn() throws {
        var pixels = S.pixels(0)
        pixels.transition = BoxTransition(ref: 2, ms: 500)
        let engine = try S.engine(preset: S.preset(8, boxes: [pixels]))
        engine.send("channel 2 write media \(EngineFixtures.dawn)")
        engine.tick(count: 3)
        engine.send("channel 2 write media \(EngineFixtures.cross)")
        engine.tick()
        XCTAssertNil(live(engine)?.transition, "the channel's cut, in the channel pass")
    }
}
