import XCTest
import OCore
@testable import OEngine

/// Spec 4 §15 — "The DeckLink output is frame-accurate against the capture;
/// the 1080i weave ... is verified field-correct ... the same way": the stamp
/// a capture run's v210 encode writes into the first line of each field, and
/// that it changes nothing else (Area 7, Adam's answer of 2026-11-22).
final class FrameStampTests: XCTestCase {
    func testAStampReadsBackItsTick() {
        for tick: UInt32 in [0, 1, 2, 59, 60, 1_000_003, 0x8000_0001, .max] {
            let words = (0..<FrameStamp.words).map { FrameStamp.word(tick: tick, index: $0) }
            XCTAssertEqual(FrameStamp.read(words), tick)
        }
    }

    func testEveryComponentIsLegalBlackOrPeakWhite() {
        for index in 0..<FrameStamp.words {
            let word = FrameStamp.word(tick: 0xA5A5_5A5A, index: index)
            for k in 0..<3 {
                let value = (word >> UInt32(10 * k)) & 0x3FF
                XCTAssertTrue(value == 64 || value == 940, "word \(index) component \(k): \(value)")
            }
            XCTAssertEqual(word >> 30, 0, "the top two bits of a v210 word stay clear")
        }
    }

    /// Anything that isn't exactly a stamp reads as none: a picture, black, a
    /// stamp without its marker, a damaged component.
    func testAnythingElseReadsAsNoStamp() {
        let black = [UInt32](repeating: 512 | (64 << 10) | (512 << 20), count: FrameStamp.words)
        XCTAssertNil(FrameStamp.read(black))
        var unmarked = (0..<FrameStamp.words).map { FrameStamp.word(tick: 7, index: $0) }
        unmarked[10] = 64 | (64 << 10) | (64 << 20)
        XCTAssertNil(FrameStamp.read(unmarked), "component 32 is the marker")
        var damaged = (0..<FrameStamp.words).map { FrameStamp.word(tick: 7, index: $0) }
        damaged[3] = (damaged[3] & ~0x3FF) | 65
        XCTAssertNil(FrameStamp.read(damaged))
        XCTAssertNil(FrameStamp.read([UInt32](repeating: 0, count: 4)), "too short")
    }

    // MARK: - In the plan

    /// The control loop stamps only the outputs a capture run names, with each
    /// field's tick: a woven frame's first field is the previous tick's.
    func testThePlanStampsOnlyTheNamedOutputWithEachFieldsTick() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.pacingMachine(), media: EngineFixtures.media)
        engine.engine.control.stampedOutputs = [3]
        engine.send("channel 2 write text \"x\"")
        engine.tick()   // tick 0: the first field
        XCTAssertNil(engine.lastPlan?.sinkPasses.first { $0.output == 1 }?.stamp, "output 1 isn't named")
        engine.tick()   // tick 1: the woven frame
        let woven = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 3 })
        XCTAssertEqual(woven.stamp, SinkStamp(firstField: 0, secondField: 1))
        engine.tick(count: 2)   // tick 3
        XCTAssertEqual(engine.lastPlan?.sinkPasses.first { $0.output == 3 }?.stamp, SinkStamp(firstField: 2, secondField: 3))
        let plain = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.pacingMachine(), media: EngineFixtures.media)
        plain.tick(count: 2)
        XCTAssertNil(plain.lastPlan?.sinkPasses.first { $0.output == 3 }?.stamp, "a show never stamps")
    }

    // MARK: - On the GPU

    private func backendOrSkip() throws -> MetalBackend { try MetalHarness.backend() }

    /// The v210 encode with a stamp writes it into rows 0 and 1 and leaves
    /// every other word as the unstamped encode wrote it.
    func testTheEncodeStampsBothRowsAndNothingElse() throws {
        let backend = try backendOrSkip()
        var frame = CapturedFrame(width: 48, height: 4)
        for y in 0..<4 { for x in 0..<48 { frame[x, y] = LinearPixel(r: Float(x) / 48, g: Float(y) / 4, b: 0.25, a: 1) } }
        let stack = backend.makeStill(frame, label: "stack")
        let plain = try XCTUnwrap(backend.v210Words(stack: stack, width: 48, height: 4))
        let stamped = try XCTUnwrap(backend.v210Words(stack: stack, stamp: SinkStamp(firstField: 1234, secondField: 1234), width: 48, height: 4))
        let rowWords = ((48 + 47) / 48) * 32
        XCTAssertEqual(FrameStamp.read(stamped, offset: 0), 1234)
        XCTAssertEqual(FrameStamp.read(stamped, offset: rowWords), 1234)
        XCTAssertNil(FrameStamp.read(plain, offset: 0), "no stamp unless asked")
        for index in stamped.indices {
            let row = index / rowWords
            let column = index % rowWords
            if row < 2, column < FrameStamp.words { continue }
            XCTAssertEqual(stamped[index], plain[index], "word \(column) of row \(row) is the picture's")
        }
    }

    /// Spec 4 §10 — the woven frame's "first field is the first tick's even
    /// lines and second field the next tick's odd lines": row 0 carries the
    /// first field's tick and row 1 the second's.
    func testAWovenFrameStampsEachFieldWithItsOwnTick() throws {
        let backend = try backendOrSkip()
        // At least 18 pixels wide: the stamp's eleven words are three groups of six pixels.
        let first = backend.makeStill(MetalHarness.solid(width: 48, height: 4, LinearPixel(r: 0, g: 0, b: 0, a: 1)), label: "first")
        let second = backend.makeStill(MetalHarness.solid(width: 48, height: 4, LinearPixel(r: 1, g: 1, b: 1, a: 1)), label: "second")
        let words = try XCTUnwrap(backend.v210Words(stack: second, firstField: FieldSources(stack: first, second: .none),
                                                    stamp: SinkStamp(firstField: 600, secondField: 601), width: 48, height: 4))
        let rowWords = ((48 + 47) / 48) * 32
        // Word 4 of a row (the second group's first) holds a luma in its middle ten bits.
        XCTAssertEqual(words[rowWords * 2 + 4] >> 10 & 0x3FF, 64, "row 2, the first field's, is the black frame's")
        XCTAssertEqual(words[rowWords * 3 + 4] >> 10 & 0x3FF, 940, "row 3, the second field's, is the white frame's")
        XCTAssertEqual(FrameStamp.read(words, offset: 0), 600)
        XCTAssertEqual(FrameStamp.read(words, offset: rowWords), 601)
    }
}
