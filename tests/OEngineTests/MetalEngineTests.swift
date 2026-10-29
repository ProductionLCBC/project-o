import XCTest
import OCore
@testable import OEngine

/// Spec 4 §15 — the engine over the Metal backend with the real sources,
/// posters and text cache, driven by the software clock: "The confidence
/// stack's +1 slot is correct on every `next`, checked by the capture against
/// the projected state."
final class MetalEngineTests: XCTestCase {
    var engine: HeadlessEngine!

    override func setUpWithError() throws {
        let metal = try MetalHarness.backend()
        engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                    mediaRoot: EngineFixtures.mediaRoot, metal: metal)
    }

    /// Where a stack's box lands, in the capture.
    func region(_ frame: CapturedFrame, _ rect: Frame) -> [LinearPixel] {
        var out: [LinearPixel] = []
        let x0 = Int(rect.x * Double(frame.width))
        let x1 = Int((rect.x + rect.w) * Double(frame.width))
        let y0 = Int(rect.y * Double(frame.height))
        let y1 = Int((rect.y + rect.h) * Double(frame.height))
        for y in max(0, y0)..<min(frame.height, y1) {
            for x in max(0, x0)..<min(frame.width, x1) { out.append(frame[x, y]) }
        }
        return out
    }

    func lit(_ pixels: [LinearPixel]) -> Int { pixels.filter { $0.r + $0.g + $0.b > 0.3 }.count }

    func test_plusOneSlotFollowsTheProjectedStateOnEveryNext() throws {
        engine.send("list 42 cue 1")
        engine.tick()
        engine.tick()   // the text rasterized on the first tick draws on the second
        var confidence = try XCTUnwrap(engine.captured(output: 2))
        XCTAssertEqual(confidence.width, 1920)
        // Preset 3's layout for stack 2 is the lower third: cue 2's text shows there while cue 1 is live.
        // The static [Time] box sits at the right end of that band, so only the left part is measured.
        let lowerThird = Frame(x: 0.03, y: 0.82, w: 0.6, h: 0.16)
        let body = Frame(x: 0.03, y: 0.05, w: 0.94, h: 0.75)
        XCTAssertGreaterThan(lit(region(confidence, lowerThird)), 50, "the +1 slot shows the next verse")
        XCTAssertGreaterThan(lit(region(confidence, body)), 50, "the live slot shows this verse")
        let plan = try XCTUnwrap(engine.lastPlan)
        let stack2 = try XCTUnwrap(plan.stackPasses.first { $0.stack == 2 })
        let projected = try XCTUnwrap(lookahead(engine.state, steps: 1, context: engine.control.projectionContext(frame: engine.frame, source: CommandSource(kind: .engine))))
        guard case .text(let next)? = projected.channels[2]?.content else { return XCTFail("the projected state has text on channel 2") }
        XCTAssertEqual(stack2.boxes.first { $0.offset == 1 }?.text, next.fields["body"], "the +1 box carries the projected text")

        for cue in 2...4 {
            engine.send("next")
            engine.tick()
            engine.tick()
            confidence = try XCTUnwrap(engine.captured(output: 2))
            let stackPass = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
            let ahead = lookahead(engine.state, steps: 1, context: engine.control.projectionContext(frame: engine.frame, source: CommandSource(kind: .engine)))
            if let ahead, case .text(let t)? = ahead.channels[2]?.content {
                XCTAssertEqual(stackPass.boxes.first { $0.offset == 1 }?.text, t.fields["body"], "cue \(cue): +1 matches the projection")
                XCTAssertGreaterThan(lit(region(confidence, lowerThird)), 50, "cue \(cue): the +1 slot is drawn")
            } else {
                XCTAssertNil(stackPass.boxes.first { $0.offset == 1 }, "cue \(cue): past the end the +1 slot is empty")
                XCTAssertEqual(lit(region(confidence, lowerThird)), 0, "cue \(cue): nothing drawn past the end")
            }
        }
        XCTAssertEqual(engine.state.pointer?.cueUuid, EngineFixtures.list42Cues[3])
        XCTAssertEqual(engine.textCache?.statistics.failed, 0)
    }

    func test_videoDecodesOntoTheMainStack() throws {
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.tick()
        var pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
        XCTAssertEqual(pass.incoming.source, .texture(engine.posterHandle(for: EngineFixtures.dawn)), "the poster lands on the tick the write lands")
        var live = false
        for _ in 0..<200 {
            engine.tick()
            pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first)
            if case .instance = pass.incoming.source {
                live = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(live, "the decoded clip replaced the poster within two seconds")
        engine.tick()
        let metal = try XCTUnwrap(engine.metal)
        let channel = try XCTUnwrap(metal.readback(engine.control.channelTextures[1] ?? .none))
        XCTAssertGreaterThan(lit(channel.pixels), 100, "the channel pass drew the decoded frame; missing pipelines \(metal.missingPipelineCount), pass \(pass)")
        let main = try XCTUnwrap(engine.captured(output: 1))
        XCTAssertGreaterThan(lit(main.pixels), 100, "the clip is on the main stack; stack boxes \(engine.lastPlan?.stackPasses.first?.boxes.map(\.content) ?? [])")
        let records = engine.drainMetrics()
        XCTAssertEqual(records.filter { $0.gpuFailed }.count, 0)
        XCTAssertEqual(records.last?.instanceQueueDepths.count, 1, "one instance is live: \(records.last.map { "\($0)" } ?? "")")
    }

    func test_timeBoxReadsTheMachineClockAndCountsNoTextLateAfterWarmUp() throws {
        engine.send("channel 2 write text \"Amen\"")
        engine.tick(count: 3)
        let records = engine.drainMetrics()
        XCTAssertEqual(records.last?.textLate, 0, "after the first tick every box has its texture")
        let stack2 = try XCTUnwrap(engine.lastPlan?.stackPasses.first { $0.stack == 2 })
        XCTAssertEqual(stack2.boxes.first { if case .static = $0.binding.kind { return true } else { return false } }?.text, "10:00 AM")
    }
}
