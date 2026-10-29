import XCTest
@testable import OEngine

/// Spec 4 §16, Frame selection — "A scripted queue with jittered presentation
/// times yields the right frame per tick and counts repeats correctly".
final class FrameQueueTests: XCTestCase {
    func frame(_ ms: Double) -> DecodedFrame {
        DecodedFrame(presentationMs: ms, durationMs: 33.3, layout: .nv12)
    }

    func test_newestFrameAtOrBeforeMediaTimeAndRepeats() {
        let queue = FrameQueue(capacity: 6)
        for ms in [0, 31, 68, 99] { queue.push(frame(Double(ms))) }
        var picked = PickedFrame()
        var results: [(PickResult, Double)] = []
        for t in [0.0, 16.7, 33.3, 50, 66.7, 83.3, 100] {
            let r = queue.pick(mediaTimeMs: t, into: &picked)
            results.append((r, picked.presentationMs))
        }
        XCTAssertEqual(results.map(\.0), [.frame, .repeated, .frame, .repeated, .repeated, .frame, .frame])
        XCTAssertEqual(results.map(\.1), [0, 0, 31, 31, 31, 68, 99])
        XCTAssertEqual(queue.repeats, 3)
    }

    func test_nothingBeforeTheFirstFrameAndNothingWhenEmpty() {
        let queue = FrameQueue(capacity: 4)
        var picked = PickedFrame()
        XCTAssertEqual(queue.pick(mediaTimeMs: 10, into: &picked), .nothing)
        queue.push(frame(50))
        XCTAssertEqual(queue.pick(mediaTimeMs: 10, into: &picked), .nothing, "no frame at or before 10 yet, and nothing displayed")
        XCTAssertEqual(queue.pick(mediaTimeMs: 50, into: &picked), .frame)
        XCTAssertEqual(queue.pick(mediaTimeMs: 10, into: &picked), .repeated, "once something is displayed, it repeats")
    }

    func test_fullQueueRefusesUntilTheConsumerMovesOn() {
        let queue = FrameQueue(capacity: 3)
        XCTAssertTrue(queue.push(frame(0)))
        XCTAssertTrue(queue.push(frame(33)))
        XCTAssertTrue(queue.push(frame(66)))
        XCTAssertFalse(queue.push(frame(99)), "three slots hold three frames")
        XCTAssertEqual(queue.depth, 3)
        var picked = PickedFrame()
        XCTAssertEqual(queue.pick(mediaTimeMs: 40, into: &picked), .frame)
        XCTAssertEqual(picked.presentationMs, 33)
        XCTAssertTrue(queue.hasRoom, "the frame before the displayed one can be reused")
        XCTAssertTrue(queue.push(frame(99)))
        XCTAssertEqual(queue.depth, 2, "66 and 99 are ahead of the displayed 33")
    }

    func test_skippingAheadReleasesOlderFrames() {
        let queue = FrameQueue(capacity: 4)
        for ms in [0, 33, 66, 99] { queue.push(frame(Double(ms))) }
        var picked = PickedFrame()
        XCTAssertEqual(queue.pick(mediaTimeMs: 1000, into: &picked), .frame)
        XCTAssertEqual(picked.presentationMs, 99, "the newest frame at or before the media time, skipping the rest")
        XCTAssertEqual(queue.depth, 0)
        XCTAssertTrue(queue.hasRoom)
    }

    func test_flushAndEnd() {
        let queue = FrameQueue(capacity: 4)
        queue.push(frame(0))
        var picked = PickedFrame()
        XCTAssertEqual(queue.pick(mediaTimeMs: 0, into: &picked), .frame)
        queue.markEnded()
        XCTAssertTrue(queue.isEnded)
        queue.flush()
        XCTAssertFalse(queue.isEnded)
        XCTAssertEqual(queue.depth, 0)
        XCTAssertEqual(queue.pick(mediaTimeMs: 0, into: &picked), .nothing, "after a flush nothing is displayed")
    }
}
