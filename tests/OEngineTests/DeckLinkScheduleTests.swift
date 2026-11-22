import XCTest
import OCore
import ODeckLink
@testable import OEngine

/// Spec 4 §10 — "Frames are scheduled two to three ahead on the card's stream
/// time"; Spec 1 §3 — an output's `format` names `rate: {num, den}`, the frame
/// rate, with `interlaced` beside it (Spec 4 §2 counts an interlaced output's
/// fields as twice that rate). The loopback test of 2026-11-22 showed a 1080i
/// output scheduled for two frame periods per frame: every frame shown twice,
/// at half rate.
final class DeckLinkScheduleTests: XCTestCase {
    private func format(_ width: Int, _ height: Int, _ num: Int, _ den: Int, interlaced: Bool) -> VideoFormat {
        VideoFormat(width: width, height: height, rate: FrameRate(num: num, den: den), interlaced: interlaced)
    }

    func testAnInterlacedFrameLastsOneFrameOfItsRate() {
        // 1080i59.94 is 30000/1001 frames a second, 60000/1001 fields.
        let i5994 = format(1920, 1080, 30000, 1001, interlaced: true)
        XCTAssertEqual(DeckLinkSink.streamTime(start: 0, frame: 1, rate: i5994.rate), 33_366_667)
        XCTAssertEqual(DeckLinkSink.frameDuration(frame: 0, rate: i5994.rate), 33_366_667)
        let i60 = format(1920, 1080, 30, 1, interlaced: true)
        XCTAssertEqual(DeckLinkSink.frameDuration(frame: 0, rate: i60.rate), 33_333_333)
        XCTAssertEqual(DeckLinkSink.streamTime(start: 0, frame: 30, rate: i60.rate), 1_000_000_000, "thirty frames of 1080i60 are one second")
    }

    func testAProgressiveFrameLastsOneFrame() {
        let p60 = format(1920, 1080, 60, 1, interlaced: false)
        XCTAssertEqual(DeckLinkSink.streamTime(start: 0, frame: 60, rate: p60.rate), 1_000_000_000)
        let p2997 = format(3840, 2160, 30000, 1001, interlaced: false)
        XCTAssertEqual(DeckLinkSink.streamTime(start: 0, frame: 30000, rate: p2997.rate), 1_001_000_000_000)
    }

    /// The stream times are computed from the frame count, so three hours (or
    /// three days) of 59.94 never drift off the card's frame grid.
    func testStreamTimesNeverDrift() {
        let rate = FrameRate(num: 60000, den: 1001)
        let start: Int64 = 123_456_789
        // Every 60000 frames is exactly 1001 seconds.
        for blocks in [1, 10, 648, 5_184] {
            let frame = Int64(blocks) * 60000
            XCTAssertEqual(DeckLinkSink.streamTime(start: start, frame: frame, rate: rate), start + Int64(blocks) * 1_001_000_000_000)
        }
        // Consecutive durations add up to the whole: no frame gained or lost.
        var sum: Int64 = 0
        for frame in Int64(0)..<60000 { sum += DeckLinkSink.frameDuration(frame: frame, rate: rate) }
        XCTAssertEqual(sum, 1_001_000_000_000)
        // Each duration is within a nanosecond of the exact 16 683 333.33.
        XCTAssertTrue((16_683_333...16_683_334).contains(DeckLinkSink.frameDuration(frame: 1, rate: rate)))
    }

    /// Spec 4 §10 — embedded audio "scheduled against the same stream time as
    /// the video": the audio lead is the video's, three frames, not six fields.
    func testTheAudioLeadIsThreeFramesInterlacedOrNot() {
        XCTAssertEqual(DeckLinkSink.audioLead(rate: FrameRate(num: 30000, den: 1001)), 100_100_000)
        XCTAssertEqual(DeckLinkSink.audioLead(rate: FrameRate(num: 60, den: 1)), 50_000_000)
    }

    /// Spec 10 §3, the `devices` query — a port's modes as `{num, den}` in
    /// lowest terms, the form outputs.json holds (`{num: 30, den: 1}`), not the
    /// card's own `30000/1000`.
    func testAPortsModesAreInLowestTerms() {
        let mode = odl_mode_t(width: 1920, height: 1080, rate_num: 30000, rate_den: 1000, interlaced: true)
        XCTAssertEqual(SystemDevices.format(of: mode), VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 30, den: 1), interlaced: true))
        let fractional = odl_mode_t(width: 3840, height: 2160, rate_num: 30000, rate_den: 1001, interlaced: false)
        XCTAssertEqual(SystemDevices.format(of: fractional).rate, FrameRate(num: 30000, den: 1001))
        let p60 = odl_mode_t(width: 1920, height: 1080, rate_num: 60000, rate_den: 1000, interlaced: false)
        XCTAssertEqual(SystemDevices.format(of: p60).rate, FrameRate(num: 60, den: 1))
    }
}
