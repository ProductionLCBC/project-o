import XCTest
import OCore
@testable import OEngine

/// Spec 4 §12 — "A utility thread checks every 250 ms that each active sink
/// presented or scheduled within the last two frame intervals and that the
/// render thread consumed a plan within the last tick; failures are logged
/// with the state of every queue and ring at that moment". The checks are a
/// pure function of liveness readings so the thread is a thin loop around them.
final class WatchdogTests: XCTestCase {
    let tick: Int64 = 16_666_667

    func reading(now: Int64, lastTick: Int64, sinks: [Int: Int64], queues: [QueueReading] = []) -> LivenessReading {
        LivenessReading(now: MonotonicTime(nanoseconds: now), tickNanoseconds: tick,
                        lastPlanConsumed: MonotonicTime(nanoseconds: lastTick), lastPlanBuilt: MonotonicTime(nanoseconds: lastTick),
                        sinkLastPresent: sinks.mapValues { MonotonicTime(nanoseconds: $0) },
                        queues: queues)
    }

    func test_healthyReadingRaisesNothing() {
        let findings = Watchdog.check(reading(now: 100 * tick, lastTick: 100 * tick - tick / 2, sinks: [1: 100 * tick - tick]))
        XCTAssertEqual(findings, [])
    }

    func test_renderThreadMissingATickIsReported() {
        let findings = Watchdog.check(reading(now: 100 * tick, lastTick: 100 * tick - 3 * tick, sinks: [1: 100 * tick - tick],
                                              queues: [QueueReading(name: "decode:1", depth: 3, capacity: 4)]))
        XCTAssertEqual(findings, [.renderThreadMissedTick(sinceNs: 3 * tick, queues: [QueueReading(name: "decode:1", depth: 3, capacity: 4)])])
    }

    func test_sinkNotPresentingForTwoIntervalsIsReported() {
        let findings = Watchdog.check(reading(now: 100 * tick, lastTick: 100 * tick - tick / 2,
                                              sinks: [1: 100 * tick - tick, 2: 100 * tick - 3 * tick]))
        XCTAssertEqual(findings, [.sinkStalled(output: 2, sinceNs: 3 * tick, queues: [])])
    }

    /// Spec 4 §12 — "Control thread stalls ... watchdog logs after 500 ms".
    func test_controlStallIsReportedAfterHalfASecond() {
        var r = reading(now: 100 * tick, lastTick: 100 * tick - tick / 2, sinks: [:])
        r.lastPlanBuilt = MonotonicTime(nanoseconds: 100 * tick - 400_000_000)
        XCTAssertEqual(Watchdog.check(r), [])
        r.lastPlanBuilt = MonotonicTime(nanoseconds: 100 * tick - 600_000_000)
        XCTAssertEqual(Watchdog.check(r), [.controlThreadStalled(sinceNs: 600_000_000)])
    }

    func test_watchdogCountsEventsAndRecoveries() {
        let watchdog = Watchdog(log: EngineLog(category: "test"))
        let findings = Watchdog.check(reading(now: 100 * tick, lastTick: 100 * tick - 3 * tick, sinks: [:]))
        watchdog.record(findings)
        XCTAssertEqual(watchdog.events, 1)
        XCTAssertEqual(watchdog.tickMissed, 1)
        XCTAssertEqual(watchdog.recoveries, 0)
        watchdog.recordRecovery(.sinkRestarted(output: 1))
        XCTAssertEqual(watchdog.recoveries, 1)
    }

    func test_headlessEngineReportsItsLiveness() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(),
                                        mediaRoot: EngineFixtures.mediaRoot)
        engine.tick(count: 3)
        let reading = engine.livenessReading()
        XCTAssertEqual(reading.lastPlanConsumed, engine.clock.now())
        XCTAssertEqual(Set(reading.sinkLastPresent.keys), [1, 2])
        XCTAssertEqual(Watchdog.check(reading), [])
    }
}
