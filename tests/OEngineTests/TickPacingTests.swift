import XCTest
import OCore
@testable import OEngine

/// Spec 4 §16, pacing — "With a software clock, a 60 Hz tick driving a 30 fps
/// and an interlaced output renders exactly the expected passes per tick,
/// reuses the plan on a simulated control stall, and skips aux passes under
/// simulated GPU pressure." Spec 4 §3 — frame plan lifetime; §4 — the tick in
/// order; §13 — every tick writes one record.
final class TickPacingTests: XCTestCase {
    var engine: HeadlessEngine!
    var backend: RecordingBackend!

    override func setUpWithError() throws {
        engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.pacingMachine(),
                                    mediaRoot: EngineFixtures.mediaRoot)
        backend = try XCTUnwrap(engine.recording)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.send("channel 2 write text \"x\"")
    }

    func test_expectedPassesPerTick() throws {
        var rows: [(channels: Int, stacks: [Int], sinks: [Int])] = []
        for _ in 0..<4 {
            engine.tick()
            let encoded = try XCTUnwrap(backend.encoded.last)
            rows.append((encoded.channelPasses, encoded.stackPasses, encoded.sinkOutputs))
        }
        // Stack 1 feeds the 60p output and the interlaced output: due every tick. Stack 2 feeds the 30p output: every second tick.
        XCTAssertEqual(rows.map(\.stacks), [[1, 2], [1], [1, 2], [1]])
        XCTAssertEqual(rows.map(\.channels), [1, 1, 1, 1], "channel 1 is sampled by stack 1 every tick")
        XCTAssertEqual(rows.map(\.sinks), [[1, 2, 3], [1], [1, 2, 3], [1]])
    }

    func test_everyTickWritesOneMetricsRecord() throws {
        engine.tick(count: 5)
        let records = engine.drainMetrics()
        XCTAssertEqual(records.map(\.frame), [0, 1, 2, 3, 4])
        XCTAssertEqual(records.map(\.channelPasses), [1, 1, 1, 1, 1])
        XCTAssertEqual(records.map(\.stackPasses), [2, 1, 2, 1, 2])
        XCTAssertTrue(records.allSatisfy { !$0.planReused })
    }

    /// Spec 4 §3 — "If no new plan is ready at a tick (the control thread
    /// stalled), the render thread reuses the previous plan with the frame
    /// counter advanced, so video keeps playing and the stall is logged".
    func test_controlStallReusesThePlanWithTheFrameAdvanced() throws {
        engine.tick(count: 2)
        engine.stallControl(ticks: 2)
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.frame, 2)
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.frame, 3)
        let records = engine.drainMetrics()
        XCTAssertEqual(records.map(\.planReused), [false, false, true, true])
        XCTAssertEqual(backend.encoded.last?.channelPasses, 1, "video keeps playing on the reused plan")
        engine.tick()
        XCTAssertEqual(engine.lastPlan?.frame, 4)
        XCTAssertEqual(engine.drainMetrics().map(\.planReused), [false])
    }

    /// Spec 4 §4 step 5 — "Encode aux passes only if the previous tick's GPU
    /// time left headroom; otherwise skip them and count the skip." Previews
    /// are due every second tick at 60 Hz (Spec 4 §10, at most 30 a second).
    func test_auxPassesSkipUnderGPUPressure() throws {
        engine.tick(count: 3)
        XCTAssertEqual(backend.encoded.last?.auxPasses, 2)
        XCTAssertEqual(backend.encoded.last?.auxSkipped, 0)
        backend.simulatedGPUMilliseconds = 12   // over the 8 ms budget at 60 Hz
        engine.tick()                           // frame 3: measured at 12 ms
        engine.tick()                           // frame 4: an aux frame, skipped
        XCTAssertEqual(backend.encoded.last?.auxPasses, 0)
        XCTAssertEqual(backend.encoded.last?.auxSkipped, 2)
        XCTAssertEqual(engine.drainMetrics().last?.auxSkipped, 2)
        backend.simulatedGPUMilliseconds = 3
        engine.tick(count: 2)                   // frame 6 sees frame 5 within budget
        XCTAssertEqual(backend.encoded.last?.auxSkipped, 0)
        XCTAssertEqual(backend.encoded.last?.auxPasses, 2)
    }

    /// Spec 4 §12 — "GPU over budget ... if three consecutive ticks overrun,
    /// drop blur passes and mip generation until clear".
    func test_threeOverrunsDropBlurAndMips() throws {
        engine.tick()
        backend.simulatedGPUMilliseconds = 12
        engine.tick(count: 3)
        XCTAssertFalse(engine.renderLoop.pressure.droppingExtras)
        engine.tick()
        XCTAssertTrue(engine.renderLoop.pressure.droppingExtras)
        XCTAssertTrue(backend.encoded.last?.dropExtras ?? false)
        backend.simulatedGPUMilliseconds = 2
        engine.tick(count: 2)
        XCTAssertFalse(engine.renderLoop.pressure.droppingExtras)
    }

    /// Spec 4 §4 — the frame counter advances once per tick and the plan's
    /// frame is the tick (Spec 3 §6: "the engine frame the group lands on").
    func test_frameCounterIsTheTick() throws {
        engine.tick(count: 3)
        XCTAssertEqual(engine.frame, 2)
        XCTAssertEqual(engine.lastPlan?.frame, 2)
    }
}
