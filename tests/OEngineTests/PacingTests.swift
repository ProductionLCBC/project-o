import XCTest
import OCore
@testable import OEngine

/// Spec 4 §2 — "One master tick ... whose rate is the highest output rate on
/// the machine, counting fields for interlaced outputs"; "One rate family per
/// machine"; "Render only what is due".
final class PacingTests: XCTestCase {
    func test_masterRateIsTheHighestOutputRateCountingFields() throws {
        let pacing = try Pacing(machine: EngineFixtures.pacingMachine())
        XCTAssertEqual(pacing.masterRate, FrameRate(num: 60, den: 1))
        XCTAssertEqual(pacing.tickNanoseconds, 1_000_000_000 / 60)
    }

    func test_interlacedOutputCountsFields() throws {
        var machine = try EngineFixtures.pacingMachine()
        machine.outputs = [machine.outputs[2]]   // 1080i30 alone: 60 fields a second
        let pacing = try Pacing(machine: machine)
        XCTAssertEqual(pacing.masterRate, FrameRate(num: 60, den: 1))
    }

    func test_fractionalFamilyIsOneFamily() throws {
        var machine = try EngineFixtures.pacingMachine()
        machine.outputs[0].format.rate = FrameRate(num: 60000, den: 1001)
        machine.outputs[1].format.rate = FrameRate(num: 30000, den: 1001)
        machine.outputs[2].format.rate = FrameRate(num: 30000, den: 1001)
        let pacing = try Pacing(machine: machine)
        XCTAssertEqual(pacing.masterRate, FrameRate(num: 60000, den: 1001))
    }

    /// Spec 4 §2 — "A machine with a 30 fps output and a 59.94 output cannot be
    /// paced from one clock". The fixture machine root pairs 60p with 29.97i.
    func test_mixedRateFamilyIsRefused() throws {
        XCTAssertThrowsError(try Pacing(machine: EngineFixtures.fixtureMachine())) { error in
            guard case PacingError.mixedRateFamily(let outputs) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(outputs, [1, 2])
        }
    }

    func test_dueOutputsPerTick() throws {
        let pacing = try Pacing(machine: EngineFixtures.pacingMachine())
        // Output 1 at 60p is due every tick.
        XCTAssertTrue((0..<8).allSatisfy { pacing.isSinkDue(output: 1, tick: $0) })
        // Output 2 at 30p is due every second tick.
        XCTAssertEqual((0..<8).map { pacing.isSinkDue(output: 2, tick: $0) }, [true, false, true, false, true, false, true, false])
        // Output 3 at 1080i30 consumes a stack frame every tick (one per field) and schedules a frame every second tick.
        XCTAssertTrue((0..<8).allSatisfy { pacing.isStackDue(output: 3, tick: $0) })
        XCTAssertEqual((0..<8).map { pacing.isSinkDue(output: 3, tick: $0) }, [true, false, true, false, true, false, true, false])
        XCTAssertEqual(pacing.ticksPerFrame(output: 2), 2)
        XCTAssertEqual(pacing.ticksPerFrame(output: 3), 2)
        XCTAssertEqual(pacing.ticksPerStackFrame(output: 3), 1)
    }

    func test_unknownOutputIsNeverDue() throws {
        let pacing = try Pacing(machine: EngineFixtures.pacingMachine())
        XCTAssertFalse(pacing.isSinkDue(output: 9, tick: 0))
        XCTAssertFalse(pacing.isStackDue(output: 9, tick: 0))
    }
}
