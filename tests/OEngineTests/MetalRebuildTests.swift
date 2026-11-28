import XCTest
import OCore
@testable import OEngine

/// Spec 4 §1 — "Every output presents a frame every refresh. A missing frame
/// is a repeat, never black", through a rebuild (Spec 4 §5): on the GPU, with
/// the real text cache, an output goes on showing its picture on every tick
/// while the stack it shows is made again at another size, because another
/// output took the stack or left it. "The stack's text draws from its
/// previous rasters, scaled, until the new ones are ready (section 9)".
final class MetalRebuildTests: XCTestCase {
    typealias E = EngineFixtures

    var engine: HeadlessEngine!

    /// Output 1 is 480 by 270 on stack 1; output 2 is 1920 by 1080 on stack 2, and cuts between stacks.
    override func setUpWithError() throws {
        let metal = try MetalHarness.backend()
        engine = try HeadlessEngine(library: E.library(), machine: E.spikeMachine(mainSize: Size(width: 480, height: 270)), media: E.media, metal: metal)
    }

    /// The share of a captured frame that is lit. The harness captures at the stack's size, so a share is
    /// what stays the same when the stack is made again; the cue plays a clip, so it drifts a little.
    /// Ticks until cue 1's media is fully up: it fades in onto its empty channel (Spec 4 §7 as corrected 2026-11-25).
    func settle() {
        engine.tick(count: 3)
        for _ in 0..<240 where engine.lastPlan?.channelPasses.contains(where: { $0.transition != nil }) ?? false { engine.tick() }
        engine.tick(count: 2)
    }

    func lit(_ frame: CapturedFrame) -> Double {
        var count = 0
        for y in 0..<frame.height {
            for x in 0..<frame.width where frame[x, y].r + frame[x, y].g + frame[x, y].b > 0.3 { count += 1 }
        }
        return Double(count) / Double(max(1, frame.width * frame.height))
    }

    func test_anOutputKeepsItsPictureWhileItsStackIsMadeAgainAtAnotherSize() throws {
        engine.send("list 42 cue 1")
        settle()
        let small = PixelSize(width: 480, height: 270)
        let large = PixelSize(width: 1920, height: 1080)
        XCTAssertEqual(engine.control.geometry.stackSize(1), small)
        let before = lit(try XCTUnwrap(engine.captured(output: 1)))
        XCTAssertGreaterThan(before, 0.1, "the cue's picture is on output 1")
        let firstRing = try XCTUnwrap(engine.control.stackRings[1])

        // The 1920 by 1080 output takes stack 1: the stack is made again, four times the size, on that tick.
        XCTAssertNil(engine.send("output 2 stack 1"))
        var secondRing: [TextureHandle] = []
        for tick in 0..<6 {
            engine.tick()
            if tick == 0 {
                XCTAssertEqual(engine.control.lastRebuild?.stacksResized.contains(1), true)
                XCTAssertEqual(engine.control.geometry.stackSize(1), large)
                XCTAssertEqual(engine.control.textLateThisBuild, 0, "its text draws from the rasters it had")
                secondRing = engine.control.stackRings[1] ?? []
                XCTAssertTrue(Set(secondRing).isDisjoint(with: firstRing))
            }
            let main = lit(try XCTUnwrap(engine.captured(output: 1)))
            XCTAssertEqual(main, before, accuracy: 0.05, "tick \(tick) after the switch: output 1 shows what it showed")
            XCTAssertEqual(lit(try XCTUnwrap(engine.captured(output: 2))), before, accuracy: 0.05, "tick \(tick): output 2 shows stack 1 too")
        }

        // It leaves again: stack 1 goes back to output 1's size, and output 1 never blinks.
        XCTAssertNil(engine.send("output 2 stack 2"))
        for tick in 0..<6 {
            engine.tick()
            if tick == 0 { XCTAssertEqual(engine.control.geometry.stackSize(1), small) }
            let main = lit(try XCTUnwrap(engine.captured(output: 1)))
            XCTAssertEqual(main, before, accuracy: 0.05, "tick \(tick) after the switch back: output 1 shows what it showed")
        }
        engine.tick(count: 130)
        for handle in firstRing + secondRing { XCTAssertNil(engine.backend.resources.descriptor(handle), "the rings it had are freed after the grace") }
    }

    /// An edit that makes a channel and a stack, and one that removes them,
    /// with the outputs' pictures untouched throughout.
    func test_makingAndRemovingAChannelAndAStackLeavesThePictureAlone() throws {
        var machine = try E.spikeMachine(mainSize: Size(width: 480, height: 270))
        machine.settings.libraryMode = .writable
        engine = try HeadlessEngine(library: E.library(), machine: machine, media: E.media, metal: try MetalHarness.backend())
        engine.send("list 42 cue 1")
        settle()
        let before = lit(try XCTUnwrap(engine.captured(output: 1)))
        XCTAssertGreaterThan(before, 0.1)
        for edit in [["edit stack create", "edit channel create"], ["edit stack 3 delete", "edit channel 4 delete"]] {
            XCTAssertNil(engine.send(group: edit, source: .ui))
            for tick in 0..<4 {
                engine.tick()
                if tick == 0 { XCTAssertNotNil(engine.control.lastRebuild, "\(edit)") }
                XCTAssertEqual(lit(try XCTUnwrap(engine.captured(output: 1))), before, accuracy: 0.02, "\(edit), tick \(tick)")
            }
        }
        XCTAssertEqual(engine.rejections.count, 0, engine.rejections.last?.message ?? "")
    }
}
