import XCTest
import OCore
@testable import OEngine

/// Spec 4 §10 — "Interlaced modes weave on the GPU: the encode pass takes two
/// consecutive stack frames and writes a single frame whose first field is
/// the first tick's even lines and second field the next tick's odd lines,
/// top field first as 1080i SDI expects." Spec 4 §2 — "the sides consume two
/// ticks per frame (one per field)". Spec 4 §16 — the weave among the goldens;
/// "verified field-correct on a motion fixture". Area 5 reading, approved on
/// 2026-11-03: the interlaced sink is due on the second field's tick, the
/// earliest tick at which both fields exist.
final class WeavePlanTests: XCTestCase {
    func test_theInterlacedSinkIsDueOnTheSecondFieldsTickAndNamesBothFields() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.pacingMachine(), media: EngineFixtures.media)
        engine.send("channel 2 write text \"x\"")
        engine.tick()   // tick 0: the first field
        var plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.sinkPasses.map(\.output), [1, 2], "output 3's frame cannot be woven yet")
        let firstFieldStack = try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 }).target
        engine.tick()   // tick 1: the second field, and the frame
        plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.sinkPasses.map(\.output), [1, 3])
        let woven = try XCTUnwrap(plan.sinkPasses.first { $0.output == 3 })
        XCTAssertEqual(woven.stack, try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 }).target, "this tick's stack texture is the second field")
        let first = try XCTUnwrap(woven.firstField, "the previous tick's stack texture is the first field")
        XCTAssertEqual(first.stack, firstFieldStack)
        XCTAssertNotEqual(first.stack, woven.stack, "the ring of three keeps both")
        XCTAssertEqual(first.second, .none)
        XCTAssertNil(plan.sinkPasses.first { $0.output == 1 }?.firstField, "a progressive output has no first field")
        engine.tick()   // tick 2
        XCTAssertEqual(engine.lastPlan?.sinkPasses.map(\.output), [1, 2])
        engine.tick()   // tick 3
        XCTAssertEqual(engine.lastPlan?.sinkPasses.map(\.output), [1, 3])
    }

    /// During a blackout both fields mix with black at this tick's mix, each
    /// field from its own tick's stack texture.
    func test_anOutputTransitionWeavesBothFieldsWithThisTicksMix() throws {
        var machine = try EngineFixtures.pacingMachine()
        // Spec 3: the blackout runs over the blackout transition of the first output showing the stack, so every output gets the fade.
        for index in machine.outputs.indices { machine.outputs[index].transitions = OutputTransitions(switch: 2, blackout: 3) }
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: machine, media: EngineFixtures.media)
        engine.send("stack 1 blackout on")
        engine.tick()            // tick 0: the fade starts
        engine.tick(count: 31)   // tick 31: a second field's tick, part way through the 1000 ms fade
        let woven = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 3 })
        XCTAssertEqual(woven.second, .black)
        XCTAssertEqual(woven.mix, Easing.easeInOut.apply(31 / 60), accuracy: 0.001, "this tick's mix")
        XCTAssertEqual(woven.firstField?.second, .black, "the first field mixes with black too")
    }
}

final class WeaveTests: XCTestCase {
    var backend: MetalBackend!

    override func setUpWithError() throws {
        backend = try MetalHarness.backend()
    }

    /// A 24×8 picture, black with a white bar at the given columns.
    func bar(at columns: Range<Int>) -> CapturedFrame {
        var frame = CapturedFrame(width: 24, height: 8)
        for y in 0..<8 {
            for x in 0..<24 { frame[x, y] = columns.contains(x) ? LinearPixel(r: 1, g: 1, b: 1, a: 1) : .black }
        }
        return frame
    }

    /// The Y codes of one row of v210 words (Spec 4 §10's packing).
    func lumaRow(_ words: [UInt32], row: Int, width: Int) -> [Int] {
        let rowWords = ((width + 47) / 48) * 32
        var out: [Int] = []
        for group in 0..<((width + 5) / 6) {
            let base = row * rowWords + group * 4
            let w = words[base..<(base + 4)].map { Int($0) }
            out += [(w[0] >> 10) & 0x3FF, w[1] & 0x3FF, (w[1] >> 20) & 0x3FF, (w[2] >> 10) & 0x3FF, w[3] & 0x3FF, (w[3] >> 20) & 0x3FF]
        }
        return Array(out.prefix(width))
    }

    /// Spec 4 §10 — the v210 weave: even lines from the first tick's frame,
    /// odd lines from the next tick's, top field first.
    func test_v210WeaveTakesEvenLinesFromTheFirstFieldAndOddFromTheSecond() throws {
        let first = backend.makeStill(bar(at: 4..<8), label: "first field")
        let second = backend.makeStill(bar(at: 12..<16), label: "second field")
        let words = try XCTUnwrap(backend.v210Words(stack: second, firstField: FieldSources(stack: first, second: .none), width: 24, height: 8))
        let white = ColorMath.encodeV210(LinearPixel(r: 1, g: 1, b: 1, a: 1)).c0
        let black = ColorMath.encodeV210(.black).c0
        for row in 0..<8 {
            let luma = lumaRow(words, row: row, width: 24)
            let lit = Set(luma.enumerated().filter { abs($0.element - white) <= 1 }.map(\.offset))
            if row % 2 == 0 {
                XCTAssertEqual(lit, Set(4..<8), "row \(row) is the first field: \(luma)")
            } else {
                XCTAssertEqual(lit, Set(12..<16), "row \(row) is the second field: \(luma)")
            }
            XCTAssertTrue(luma.enumerated().filter { !lit.contains($0.offset) }.allSatisfy { abs($0.element - black) <= 1 }, "the rest is black")
        }
        // Without a first field the frame is progressive: every row from the one texture.
        let plain = try XCTUnwrap(backend.v210Words(stack: second, width: 24, height: 8))
        for row in 0..<8 {
            let lit = Set(lumaRow(plain, row: row, width: 24).enumerated().filter { abs($0.element - white) <= 1 }.map(\.offset))
            XCTAssertEqual(lit, Set(12..<16), "row \(row)")
        }
    }

    /// Spec 4 §16 — the weave among the goldens: the harness's capture encode
    /// weaves the same way, so a woven frame can be compared as pixels.
    func test_captureWeaveInterleavesTheFieldsAndMatchesTheGolden() throws {
        let goldens = MetalHarness.goldens("encode")
        let a = MetalHarness.gradient(width: 64, height: 36, from: LinearPixel(r: 1, g: 0.2, b: 0.1, a: 1), to: LinearPixel(r: 0.1, g: 0.2, b: 1, a: 1))
        let b = MetalHarness.gradient(width: 64, height: 36, from: LinearPixel(r: 0, g: 0.8, b: 0.2, a: 1), to: LinearPixel(r: 0.9, g: 0.9, b: 0, a: 1))
        let first = backend.makeStill(a, label: "first field")
        let second = backend.makeStill(b, label: "second field")
        let pass = SinkPass(output: 9, stack: second, second: .none, mix: 0, encode: .capture, destination: 0, firstField: FieldSources(stack: first, second: .none))
        let plan = FramePlan(frame: 1, sinkPasses: [pass])
        backend.prepare(plan)
        let receipt = backend.encode(TickTime(tick: 1, reference: .zero, wake: .zero), plan: plan, picks: PickedFrames(capacity: 4), options: EncodeOptions())
        backend.waitForCompletion(of: receipt)
        let woven = try XCTUnwrap(backend.readbackCapture(output: 9))
        for y in 0..<36 {
            let expected = y % 2 == 0 ? a : b
            MetalHarness.assertPixel(woven[20, y], expected[20, y], accuracy: 0.004, "row \(y)")
        }
        try MetalHarness.assertGolden(goldens, "weave-fields", woven)
    }

    /// Spec 4 §16 — "verified field-correct on a motion fixture": through the
    /// engine on the pacing machine, the 60p output's two consecutive frames
    /// are the two fields of the 1080i output's woven frame, row for row,
    /// while a box dissolve moves the picture every tick.
    func test_theWovenOutputIsTheTwoProgressiveFramesInterleavedThroughTheEngine() throws {
        var machine = try EngineFixtures.pacingMachine()
        for index in machine.outputs.indices {
            machine.outputs[index].format.width = 480
            machine.outputs[index].format.height = 270
        }
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: machine, media: EngineFixtures.media, metal: backend)
        engine.send("channel 2 write text \"Weave\"")
        engine.tick(count: 21)                // tick 20
        engine.send("channel 2 write text \"Woven\"")   // preset 1's body box dissolves over 250 ms: the picture changes every tick
        engine.tick()                         // tick 21: the dissolve starts
        XCTAssertEqual(engine.frame, 21)
        engine.tick()                         // tick 22: the first field of the next woven frame
        let firstField = try XCTUnwrap(engine.captured(output: 1))
        engine.tick()                         // tick 23: the second field; output 3 weaves
        let secondField = try XCTUnwrap(engine.captured(output: 1))
        let woven = try XCTUnwrap(engine.captured(output: 3))
        XCTAssertEqual(woven.width, 480)
        XCTAssertEqual(woven.height, 270)
        XCTAssertGreaterThan(GoldenImage.compare(firstField, secondField).maxCodeDifference, 0, "the dissolve moved between the two ticks")
        var evenRowsMatch = 0
        var oddRowsMatch = 0
        for y in 0..<270 {
            var matches = true
            for x in stride(from: 0, to: 480, by: 7) {
                let expected = y % 2 == 0 ? firstField[x, y] : secondField[x, y]
                let got = woven[x, y]
                if abs(expected.r - got.r) > 0.004 || abs(expected.g - got.g) > 0.004 || abs(expected.b - got.b) > 0.004 { matches = false }
            }
            if matches { if y % 2 == 0 { evenRowsMatch += 1 } else { oddRowsMatch += 1 } }
        }
        XCTAssertEqual(evenRowsMatch, 135, "every even row is the first tick's frame")
        XCTAssertEqual(oddRowsMatch, 135, "every odd row is the next tick's frame")
    }
}
