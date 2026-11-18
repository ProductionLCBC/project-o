import Foundation
import XCTest
@testable import OApp

/// Spec 10 §2, choice U-7 — "The app starts it again every time it ends: at
/// once for the first three ends within two minutes, then five seconds after
/// each". Spec 10 §18 — "at once for the first three ends within two minutes
/// and five seconds after each end from the fourth". Adam's answer of
/// 2026-11-17: the two minutes slide.
final class RestartCadenceTests: XCTestCase {
    func test_theFirstThreeEndsWithinTwoMinutesRestartAtOnceAndTheFourthAfterFiveSeconds() {
        var cadence = RestartCadence()
        XCTAssertEqual(cadence.ended(at: 0), 0)
        XCTAssertEqual(cadence.ended(at: 10), 0)
        XCTAssertEqual(cadence.ended(at: 20), 0)
        XCTAssertEqual(cadence.ended(at: 30), 5, "three ends lie in the two minutes before it")
        XCTAssertEqual(cadence.ended(at: 40), 5, "and five seconds after each end from the fourth")
        XCTAssertEqual(cadence.recent(at: 40), 5)
    }

    func test_theTwoMinutesSlideSoAnEngineThatFallsOverNowAndThenIsBackAtOnce() {
        var cadence = RestartCadence()
        XCTAssertEqual(cadence.ended(at: 0), 0)
        XCTAssertEqual(cadence.ended(at: 100), 0)
        XCTAssertEqual(cadence.ended(at: 119), 0)
        // The first end is two minutes old by now, so only two lie in the two minutes before this one.
        XCTAssertEqual(cadence.ended(at: 120), 0)
        XCTAssertEqual(cadence.ended(at: 125), 5, "100, 119 and 120 lie in the two minutes before it")
        XCTAssertEqual(cadence.ended(at: 1_000), 0, "long after, an end is the first again")
        XCTAssertEqual(cadence.recent(at: 1_000), 1)
    }

    func test_itNeverGivesUp() {
        var cadence = RestartCadence()
        var waits: [TimeInterval] = []
        for index in 0..<200 { waits.append(cadence.ended(at: TimeInterval(index) * 6)) }
        XCTAssertEqual(Array(waits.prefix(3)), [0, 0, 0])
        XCTAssertTrue(waits.dropFirst(3).allSatisfy { $0 == 5 }, "however often it ends, it is started again")
    }
}
