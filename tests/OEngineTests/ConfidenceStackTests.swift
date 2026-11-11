import XCTest
import OCore
@testable import OEngine

/// Spec 6 §9 — "On stack 1, channels 1 and 2 resolve to Preset 1's `"*"`
/// layout through their default preset. On stack 2, channel 2 resolves to
/// Preset 1's `"2"` layout and channel 3 to the Clock preset. The confidence
/// stack therefore shows the current and next lyric with the time above them,
/// and the clock needs nothing on any channel." Spec 6 §11, Area 6: "Preset 1
/// on stack 2. The first-run confidence stack shows the current and next lyric
/// and the time. On the playlist's last cue the +1 box is empty."
final class ConfidenceStackTests: XCTestCase {
    func engine() throws -> HeadlessEngine {
        try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
    }

    func test_theFirstRunConfidenceStackShowsTheCurrentAndNextLyricAndTheTime() throws {
        let engine = try engine()
        engine.tick()
        XCTAssertEqual(engine.texts(stack: 2, channel: 3), [0: "10:00 AM"], "the clock needs nothing on any channel")
        XCTAssertEqual(engine.texts(stack: 2, channel: 2), [:])

        engine.send("playlist \"Sunday Night\"")
        engine.send("next")
        engine.tick()
        XCTAssertEqual(engine.texts(stack: 2, channel: 2), [0: "Great is Thy faithfulness,\nO God my Father", 1: "There is no shadow\nof turning with Thee"])
        XCTAssertEqual(engine.texts(stack: 2, channel: 3), [0: "10:00 AM"])
        let current = try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first { $0.offset == 0 })
        let next = try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first { $0.offset == 1 })
        let clock = try XCTUnwrap(engine.boxes(stack: 2, channel: 3).first)
        XCTAssertEqual(current.frame, PixelRect(Frame(x: 0.03, y: 0.11, w: 0.94, h: 0.56), in: PixelSize(width: 1920, height: 1080)))
        XCTAssertEqual(next.frame, PixelRect(Frame(x: 0.03, y: 0.7, w: 0.94, h: 0.27), in: PixelSize(width: 1920, height: 1080)))
        XCTAssertLessThan(clock.frame.y + clock.frame.height, current.frame.y, "the time above the lyrics")
        XCTAssertGreaterThan(clock.frame.x, 1920 / 2, "in the top right corner")

        engine.send("item 4 cue 4")
        engine.tick()
        XCTAssertEqual(engine.texts(stack: 2, channel: 2), [0: "Great is Thy faithfulness!\nGreat is Thy faithfulness!"],
                       "on the playlist's last cue the +1 box is empty")
    }

    func test_theMainStackDrawsThroughPresetOnesAnyLayout() throws {
        let engine = try engine()
        engine.send("list 42 cue 1")
        engine.tick()
        let main = engine.boxes(stack: 1)
        XCTAssertEqual(main.filter { $0.channel == 1 }.map(\.binding.kind), [.pixels], "the background fills the frame")
        XCTAssertEqual(main.filter { $0.channel == 2 }.map(\.binding.kind), [.field(name: "body")], "the fallback body box draws the lyric")
        XCTAssertTrue(main.allSatisfy { $0.offset == 0 })
    }
}
