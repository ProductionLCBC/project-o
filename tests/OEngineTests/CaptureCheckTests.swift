import XCTest
import OCore
@testable import OEngine

/// Spec 4 §15 — "Zero dropped and zero displayedLate on the DeckLink output",
/// "The DeckLink output is frame-accurate against the capture; the 1080i weave
/// ... is verified field-correct", "A/V sync within one frame on a clapper
/// fixture, measured on the capture": the capture check's judgement, frame by
/// frame, on synthetic readings.
final class CaptureCheckTests: XCTestCase {
    let p60 = CaptureExpectation.of(rate: FrameRate(num: 60, den: 1), interlaced: false, tickRate: FrameRate(num: 60, den: 1))
    let i60 = CaptureExpectation.of(rate: FrameRate(num: 30, den: 1), interlaced: true, tickRate: FrameRate(num: 60, den: 1))

    private func frame(_ tick: UInt32, field: UInt32? = nil, luma: Int = 400, audio: [Int32] = []) -> CaptureReading {
        CaptureReading(firstField: field ?? tick, secondField: tick, meanLuma: luma, audio: audio)
    }

    private func run(_ expect: CaptureExpectation, _ readings: [CaptureReading]) -> CaptureCheck {
        var check = CaptureCheck(expect: expect)
        for reading in readings { check.observe(reading) }
        return check
    }

    func testTheExpectationFollowsTheOutputAndTheTick() {
        XCTAssertEqual(p60.tickStep, 1)
        XCTAssertEqual(p60.fieldStep, 0)
        XCTAssertEqual(i60.tickStep, 2)
        XCTAssertEqual(i60.fieldStep, 1)
        let p30 = CaptureExpectation.of(rate: FrameRate(num: 30, den: 1), interlaced: false, tickRate: FrameRate(num: 60, den: 1))
        XCTAssertEqual(p30.tickStep, 2)
        XCTAssertEqual(p30.fieldStep, 0)
        XCTAssertEqual(p60.frameNs, 16_666_667)
    }

    func testAClean1080p60RunPasses() {
        let check = run(p60, (100..<400).map { frame($0) })
        XCTAssertEqual(check.stamped, 300)
        XCTAssertEqual(check.failures, [])
    }

    /// Frames before the engine starts (no signal, then the card's idle
    /// picture) and after it stops (its last frame held) aren't judged.
    func testBeforeTheFirstStampAndAfterTheLastAreNotJudged() {
        var readings = [CaptureReading(signal: false), CaptureReading(signal: false), CaptureReading(meanLuma: 64)]
        readings += (5..<50).map { frame($0) }
        readings += Array(repeating: frame(49), count: 8)   // the card holds the last frame
        readings += [CaptureReading(meanLuma: 64), CaptureReading(signal: false)]
        let check = run(p60, readings)
        XCTAssertEqual(check.failures, [])
        XCTAssertEqual(check.noSignal, 3)
    }

    func testARepeatInsideTheRunFails() {
        let check = run(p60, (0..<10).map { frame($0) } + [frame(9)] + (10..<20).map { frame($0) })
        XCTAssertEqual(check.repeats, 1)
        XCTAssertEqual(check.failures, ["1 frames shown again"])
    }

    func testASkipCountsTheMissingFrames() {
        let check = run(p60, (0..<10).map { frame($0) } + (13..<20).map { frame($0) })
        XCTAssertEqual(check.skips, 1)
        XCTAssertEqual(check.missingFrames, 3)
        XCTAssertFalse(check.failures.isEmpty)
    }

    func testOutOfOrderAndOffStepFail() {
        let backwards = run(p60, [frame(1), frame(2), frame(4), frame(3), frame(5)])
        XCTAssertEqual(backwards.backwards, 1)
        let offStep = run(i60, [frame(1, field: 0), frame(3, field: 2), frame(6, field: 5), frame(8, field: 7)])
        XCTAssertEqual(offStep.offStep, 1, "1080i60 frames come every second tick")
    }

    func testABlackOrUnstampedFrameInsideTheRunFails() {
        let check = run(p60, (0..<10).map { frame($0) } + [CaptureReading(meanLuma: 64)] + (11..<20).map { frame($0) })
        XCTAssertEqual(check.unstampedInside, 1)
        XCTAssertEqual(check.skips, 1, "the black frame stood in for tick 10")
    }

    /// Spec 4 §10 — the woven frame's first field is the first tick's, its
    /// second the next tick's: one tick apart on a 60 Hz tick.
    func testFieldsMustComeFromOnePairInOrder() {
        let good = run(i60, stride(from: UInt32(1), to: 61, by: 2).map { frame($0, field: $0 - 1) })
        XCTAssertEqual(good.failures, [])
        let swapped = run(i60, stride(from: UInt32(1), to: 61, by: 2).map { frame($0 - 1, field: $0) })
        XCTAssertEqual(swapped.fieldErrors, 30, "fields in the wrong order")
        let fromOneTick = run(i60, stride(from: UInt32(1), to: 61, by: 2).map { frame($0, field: $0) })
        XCTAssertEqual(fromOneTick.fieldErrors, 30, "both fields from one tick is no weave")
    }

    func testTheStampWrapsAt32Bits() {
        let check = run(p60, [frame(.max - 1), frame(.max), frame(0), frame(1)])
        XCTAssertEqual(check.failures, [])
    }

    // MARK: - A/V

    /// 800 samples a frame at 60p; the flash frame is the first at peak
    /// luma, the click the first loud sample after a quiet.
    private func clapRun(clickOffset: Int) -> CaptureCheck {
        var readings: [CaptureReading] = []
        let flashFrame = 30
        for index in 0..<90 {
            var audio = [Int32](repeating: 1 << 26, count: 800)   // a tone at a sixteenth of full scale
            let clickAt = flashFrame * 800 + clickOffset
            for i in 0..<800 where (index * 800 + i) >= clickAt && (index * 800 + i) < clickAt + 48 { audio[i] = Int32.max - 5 }
            let luma = (index == flashFrame || index == flashFrame + 1) ? 940 : 420
            readings.append(frame(UInt32(index), luma: luma, audio: audio))
        }
        return run(p60, readings)
    }

    func testAClickOnItsFlashFramePasses() {
        let check = clapRun(clickOffset: 30)
        XCTAssertEqual(check.flashes.count, 1, "two frames at peak are one flash")
        XCTAssertEqual(check.claps, [30])
        XCTAssertEqual(check.failures, [])
    }

    func testAClickAFrameOrMoreFromItsFlashFails() {
        XCTAssertEqual(clapRun(clickOffset: -900).failures.count, 1, "sound leading by more than a frame")
        XCTAssertEqual(clapRun(clickOffset: 1_700).failures.count, 1, "sound late by more than a frame")
        XCTAssertEqual(clapRun(clickOffset: -790).failures, [], "within a frame either way")
    }

    func testAFlashOrClickAloneIsNoClap() {
        var check = CaptureCheck(expect: p60)
        for index in 0..<200 { check.observe(frame(UInt32(index), luma: index == 20 ? 940 : 420, audio: [Int32](repeating: 0, count: 800))) }
        XCTAssertEqual(check.flashes.count, 1)
        XCTAssertEqual(check.claps, [])
        XCTAssertEqual(check.failures, [])
    }

    // MARK: - Naming a format

    /// Spec 1 §3 — `rate` is the frame rate; a bench names an interlaced
    /// format by its field rate, as broadcast does.
    func testFormatsParseAsABenchNamesThem() {
        XCTAssertEqual(CaptureFormat.parse("1920x1080p60"), VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 60, den: 1), interlaced: false))
        XCTAssertEqual(CaptureFormat.parse("1920x1080i59.94"), VideoFormat(width: 1920, height: 1080, rate: FrameRate(num: 30000, den: 1001), interlaced: true))
        XCTAssertEqual(CaptureFormat.parse("1920x1080i60")?.rate, FrameRate(num: 30, den: 1))
        XCTAssertEqual(CaptureFormat.parse("3840x2160p29.97")?.rate, FrameRate(num: 30000, den: 1001))
        XCTAssertEqual(CaptureFormat.parse("3840x2160p30000/1001")?.rate, FrameRate(num: 30000, den: 1001))
        XCTAssertNil(CaptureFormat.parse("1080p60"))
        XCTAssertNil(CaptureFormat.parse("1920x1080q60"))
        XCTAssertNil(CaptureFormat.parse("1920x1080p"))
        for name in ["1920x1080p60", "1920x1080i59.94", "1920x1080i60", "3840x2160p29.97", "1280x720p59.94"] {
            XCTAssertEqual(CaptureFormat.parse(name).map(CaptureFormat.name), name)
        }
    }

    // MARK: - Reading a frame

    func testReadingAV210FrameFindsTheStampsTheLumaAndChannelZero() {
        let width = 48, height = 16
        let rowWords = ((width + 47) / 48) * 32
        var words = [UInt32](repeating: 512 | (700 << 10) | (512 << 20), count: rowWords * height)
        for index in 0..<FrameStamp.words {
            words[index] = FrameStamp.word(tick: 41, index: index)
            words[rowWords + index] = FrameStamp.word(tick: 42, index: index)
        }
        let audio: [Int32] = [10, 20, 11, 21, 12, 22]
        let reading = words.withUnsafeBytes { raw in
            audio.withUnsafeBufferPointer { samples in
                CaptureReading.read(v210: raw.baseAddress!, rowBytes: rowWords * 4, width: width, height: height,
                                    audio: samples.baseAddress, audioFrames: 3, audioChannels: 2)
            }
        }
        XCTAssertEqual(reading.firstField, 41)
        XCTAssertEqual(reading.secondField, 42)
        XCTAssertEqual(reading.meanLuma, 700)
        XCTAssertEqual(reading.audio, [10, 11, 12])
    }
}
