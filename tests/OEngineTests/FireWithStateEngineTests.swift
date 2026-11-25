import XCTest
import OCore
@testable import OEngine

/// Spec 3 §5 as corrected 2026-11-24, through the engine — "Firing with
/// `state` ... takes up ... the state its list leaves before it ... so what
/// is on air is what its thumbnail shows": a background held from an earlier
/// cue comes up on air, decoded, when the editor jumps into the middle of the
/// list (Adam's try of edit mode's Live, 2026-11-24).
final class FireWithStateEngineTests: XCTestCase {
    typealias E = EngineFixtures

    func test_aJumpWithStatePutsTheHeldBackgroundOnAir() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: E.library(), machine: E.spikeMachine(), media: E.media, metal: metal)
        engine.send("system clearall")
        engine.tick(count: 4)
        XCTAssertNil(engine.state.channels[1]?.content.media, "nothing on channel 1 after Clear All")
        // List 42: cue 1 writes the dawn background on channel 1, cues 2 and 3 write text on channel 2.
        engine.send("list 42 cue 3 state")
        XCTAssertTrue(waitUntil(5) { engine.tick(); return engine.control.model.channels[1]?.live.media?.ready == true },
                      "cue 1's background, held to cue 3, is decoded and on air")
        XCTAssertEqual(engine.state.channels[1]?.content.media?.ref, E.dawn)
        XCTAssertNotNil(engine.state.channels[2]?.content, "cue 3's own text")

        // A plain fire of the same cue runs its own commands alone.
        engine.send("system clearall")
        engine.tick(count: 4)
        engine.send("list 42 cue 3")
        engine.tick(count: 10)
        XCTAssertNil(engine.state.channels[1]?.content.media)
    }
}
