import XCTest
import OCore
@testable import OEngine

/// Spec 6 §3 — "A box's offset ... At 0 the box draws its slot's channel as it
/// is now. At +K it draws the channel as it will be once the next K cues have
/// fired, in the state Spec 3 §7's lookahead folds ... past the playlist's end
/// the box draws nothing, whatever its binding ... v1 draws 0 to +3 (P4), and
/// a negative offset draws nothing until v1.5 adds the ring buffer. Outside −2
/// to +3, the reference report flags the box and it draws nothing." "An
/// offset box shows a still ... and the box cuts rather than transitions. The
/// engine rasterizes the text one cue beyond each offset box ahead of time."
/// "Fallback boxes look only at earlier boxes with the same offset." "At an
/// offset, a static box draws only while the lookahead reaches that far."
/// Spec 6 §11, Area 6: Offsets, Fallback, Static boxes, Stacks.
final class OffsetBoxTests: XCTestCase {
    typealias S = StageFixtures

    /// Spec 3 §9 row 18 — "Live: channel 2 text y; next two cues write channel
    /// 2 z then nothing. Lookahead +1, +2: both resolve to z; +3 past the end
    /// resolves to empty."
    func test_bodyBoxesAtPlusOneTwoAndThreeFoldTheNextCuesAndDrawNothingPastTheEnd() throws {
        let engine = try S.engine(preset: S.preset(8, boxes: [S.body(0, y: 0.05), S.body(1, y: 0.3), S.body(2, y: 0.55), S.body(3, y: 0.8)]))
        engine.send("list 50 cue 1")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "y", 1: "z", 2: "z"], "+3 is past the end of the list and draws nothing")
        engine.send("next")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "z", 1: "z"])
        engine.send("next")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "z"], "on the last cue only the live box draws")
    }

    func test_negativeAndOutOfRangeOffsetsDrawNothing() throws {
        let boxes = [S.pixels(-1), S.body(-1, y: 0.1), S.label("BEHIND", -2), S.body(4, y: 0.3), S.label("FAR", 5, y: 0.5),
                     S.body(0, y: 0.7), S.label("NOW", 0)]
        let engine = try S.engine(preset: S.preset(8, boxes: boxes))
        engine.send("list 50 cue 1")
        engine.tick()
        XCTAssertEqual(engine.boxes(stack: 2, channel: 2).map(\.offset), [0, 0])
        XCTAssertEqual(engine.boxes(stack: 2, channel: 2).compactMap(\.text), ["y", "NOW"])
    }

    /// "the box cuts rather than transitions", where the same box at 0 runs its transition.
    func test_anOffsetBoxCutsWhereTheBoxAtZeroDissolves() throws {
        let dissolve = BoxTransition(ref: 2, ms: 500)
        let engine = try S.engine(preset: S.preset(8, boxes: [S.body(0, y: 0.1, transition: dissolve), S.body(1, y: 0.6, transition: dissolve)]))
        engine.send("list 51 cue 1")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "a", 1: "b"])
        engine.send("next")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "b", 1: "c"])
        let live = try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first { $0.offset == 0 })
        XCTAssertEqual(live.transition?.type, .dissolve, "the live box dissolves from a to b")
        let next = try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first { $0.offset == 1 })
        XCTAssertNil(next.transition, "the +1 box cuts from b to c")
    }

    /// "At an offset, a static box draws only while the lookahead reaches that far."
    func test_aStaticBoxAtPlusOneDrawsOnlyWhileTheLookaheadReachesThatFar() throws {
        let engine = try S.engine(preset: S.preset(8, boxes: [S.label("NOW", 0, y: 0.1), S.label("NEXT", 1, y: 0.5)]))
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "NOW"], "nothing loaded: the lookahead is empty (Spec 7 §4)")
        engine.send("list 51 cue 1")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "NOW", 1: "NEXT"])
        engine.send("cue 3")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "NOW"], "past the end the +1 static box draws nothing")
    }

    /// Spec 6 §5 — "`[Popup N]` reads the state's own popup text (Spec 3 §2), so
    /// a +1 box shows a popup that the next cue sets": a static box resolves its
    /// variables in the state at its offset.
    func test_aStaticBoxAtPlusOneReadsThePopupOfTheNextState() throws {
        let popups = S.list(52, title: "Popups", cues: [[S.text("one")], [.popupSet(popup: 1, text: "Doors open", clearAfterMs: nil)]])
        let engine = try S.engine(preset: S.preset(8, boxes: [S.label("[Popup 1]", 0, y: 0.1), S.label("[Popup 1]", 1, y: 0.5)]),
                                  lists: [popups])
        engine.send("list 52 cue 1")
        engine.tick()
        XCTAssertEqual(engine.texts(), [1: "Doors open"], "only the next cue sets the popup")
        engine.send("next")
        engine.tick()
        XCTAssertEqual(engine.texts(), [0: "Doors open"])
    }

    /// Spec 6 §11 — "A fallback body box at +1 draws when the +1 pixel box draws
    /// nothing, whatever the boxes at 0 drew."
    func test_aFallbackBoxAtPlusOneLooksOnlyAtTheBoxesAtPlusOne() throws {
        let switching = S.list(53, title: "Switching", cues: [[S.media()], [S.text("words")], [S.media()]])
        let engine = try S.engine(preset: S.preset(8, boxes: [S.pixels(0), S.body(0, fallback: true), S.pixels(1), S.body(1, y: 0.6, fallback: true)]),
                                  lists: [switching])
        engine.send("list 53 cue 1")
        engine.tick()
        var boxes = engine.boxes(stack: 2, channel: 2)
        XCTAssertEqual(boxes.filter { $0.offset == 0 }.map(\.binding.kind), [.pixels], "live media: the picture, so the fallback at 0 is skipped")
        XCTAssertEqual(boxes.filter { $0.offset == 1 }.map(\.binding.kind), [.field(name: "body")], "next is text: the +1 picture draws nothing")
        XCTAssertEqual(boxes.first { $0.offset == 1 }?.text, "words")
        engine.send("next")
        engine.tick()
        boxes = engine.boxes(stack: 2, channel: 2)
        XCTAssertEqual(boxes.filter { $0.offset == 0 }.map(\.binding.kind), [.field(name: "body")], "live text: the fallback at 0 draws")
        XCTAssertEqual(boxes.filter { $0.offset == 1 }.map(\.binding.kind), [.pixels], "next is media: its poster, so the fallback at +1 is skipped")
        guard case .pixels(let quad)? = boxes.first(where: { $0.offset == 1 })?.content else { return XCTFail("the +1 poster") }
        XCTAssertEqual(quad.texture, engine.posterHandle(for: EngineFixtures.dawn))
    }

    /// Spec 6 §3 — "The engine rasterizes the text one cue beyond each offset
    /// box ahead of time ... so a `next` never waits on text."
    func test_theTextOneCueBeyondEachOffsetIsRasterizedAhead() throws {
        let engine = try S.engine(preset: S.preset(8, boxes: [S.body(0, y: 0.1, size: 0.3), S.body(1, y: 0.6, size: 0.2)]))
        let fake = try XCTUnwrap(engine.fakeText)
        fake.missAll = true
        engine.send("list 51 cue 1")
        engine.tick()
        let asked = fake.requested.map { "\($0.text)@\($0.box.height)" }
        let liveBox = Int((0.3 * 1080).rounded())
        let nextBox = Int((0.2 * 1080).rounded())
        XCTAssertTrue(asked.contains("b@\(liveBox)"), "the live box's next text: \(asked)")
        XCTAssertTrue(asked.contains("c@\(nextBox)"), "the +1 box's next text, two cues ahead: \(asked)")
    }

    /// Spec 6 §2 — "The engine uses the first slot for a channel and ignores any
    /// later one."
    func test_aSecondSlotForAChannelDrawsNothing() throws {
        let engine = try S.engine { _, machine in
            machine.stacks[0].slots.append(StackSlot(channel: 2, preset: 3))   // preset 3 draws a title box
        }
        engine.send(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .ui),
                                 commands: [GuardedCommand(S.fields(["body": "Words", "title": "A title"]))]))
        engine.tick()
        XCTAssertEqual(engine.boxes(stack: 1, channel: 2).map(\.binding.kind), [.field(name: "body")],
                       "only the first slot's preset draws; the later slot's title box does not")
    }
}
