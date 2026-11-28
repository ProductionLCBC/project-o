import Foundation
import OCore
import XCTest
@testable import OEngine

/// Spec 4 §11, "Transport" — "Looping audio uses the same two-reader hand-off as video so loops are gapless." Found
/// on the soak of 2026-11-27: the decoder opened a loop's next reader only once the current one had run out, so a
/// reopen slower than the ring's 250 ms (a busy disk, a busy Mac) left the device short of samples at the loop point.
/// Here every reopen is made 400 ms slow, and a one-second loop is pulled at the device's pace across three loop
/// points: the next reader, opened while the current one still decodes, keeps the ring from running dry.
final class AudioLoopHandOffTests: XCTestCase {
    func test_aLoopsNextReaderIsReadyBeforeTheRingRunsDry() throws {
        let clip = try ClipFixtures.url(for: ClipFixtures.clapper)
        let decoder = AudioFileDecoder(url: clip, inMs: 0, outMs: 1000, loop: true, reopenDelay: 0.4)
        decoder.start()
        defer { decoder.stop() }
        let ring = decoder.ring
        XCTAssertTrue(waitUntil(5) { ring.framesAvailable >= AudioGraph.prerollFrames }, "the first reader fills the ring")
        // The device's pace: 480 frames every 10 ms, for 3.5 seconds.
        var scratch = [Float](repeating: 0, count: 2)
        var underruns = 0
        var read = 0
        let start = Date()
        for block in 0..<350 {
            for _ in 0..<480 {
                if scratch.withUnsafeMutableBufferPointer({ ring.readFrame(into: $0.baseAddress!) }) {
                    read += 1
                } else if !ring.isEnded {
                    underruns += 1
                }
            }
            let due = start.addingTimeInterval(Double(block + 1) * 0.01)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        XCTAssertGreaterThan(read, 48_000 * 3, "three passes of the loop were heard")
        XCTAssertEqual(underruns, 0, "no sample missing at a loop point")
    }
}
