import XCTest
import CoreVideo
import OCore
@testable import OEngine

/// Spec 4 §13 as corrected on 2026-11-03 after the attribution run: the minute
/// record carries "memory in use, as the process footprint ... beside the
/// resident size, and its parts: the malloc zones' live and allocated bytes
/// with the purgeable zone on its own, the resource table's texture bytes, the
/// decoder pools' bytes, the text cache's bytes and the readback buffers'
/// bytes"; the threshold is "judged on the footprint's sliding per-minute
/// median ... against the median of the first window after minute ten, and
/// the same rule on the heap's live bytes ...; a record without the footprint
/// is judged on resident size as before."

// MARK: - The minute record carries the breakdown

final class MinuteBreakdownRecordTests: XCTestCase {
    func test_minuteRecordRoundTripsTheBreakdown() {
        let record = MinuteRecord(minute: 12, memoryBytes: 270_000_000, decoderSessions: 1, textCacheHitRate: 0.9995,
                                  audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0,
                                  footprintBytes: 590_000_000, graphicsFootprintBytes: 330_000_000, heapLiveBytes: 78_000_000,
                                  heapAllocatedBytes: 92_000_000, purgeableLiveBytes: 7_000_000, textureBytes: 120_000_000,
                                  decoderPoolBytes: 24_883_200, textCacheBytes: 52_000_000, readbackBytes: 35_000_000)
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        BlackBoxReader.add(line: BlackBox.line(for: record), to: &run)
        XCTAssertEqual(run.minutes, [record])
        XCTAssertEqual(record.judgedFootprintBytes, 260_000_000, "the footprint less its graphics-tagged part")
    }

    func test_olderMinuteLineReadsZerosForTheBreakdown() {
        // A line as the engine wrote it before the breakdown existed (the three-hour runs of 2026-11-01 and 2026-11-02).
        let line = "{\"audioUnderruns\":0,\"decoderSessions\":2,\"kind\":\"minute\",\"memoryBytes\":268943360,\"minute\":10,\"textCacheHitRate\":0.9997,\"watchdogEvents\":0,\"watchdogRecoveries\":0}\n"
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        BlackBoxReader.add(line: line, to: &run)
        XCTAssertEqual(run.minutes.count, 1)
        XCTAssertEqual(run.minutes[0].memoryBytes, 268_943_360)
        XCTAssertEqual(run.minutes[0].footprintBytes, 0)
        XCTAssertEqual(run.minutes[0].heapLiveBytes, 0)
        XCTAssertEqual(run.minutes[0].purgeableLiveBytes, 0)
        XCTAssertEqual(run.minutes[0].textureBytes, 0)
    }

    func test_recorderFillsTheBreakdownFromTheProcessAndItsSources() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-breakdown-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: MetricsRing(capacity: 16), presents: [],
                                        tickNanoseconds: 16_666_667,
                                        sources: BlackBoxRecorder.MinuteSources(textureBytes: { 123 }, decoderPoolBytes: { 456 },
                                                                                textCacheBytes: { 789 }, readbackBytes: { 1011 }),
                                        log: EngineLog(category: "test"))
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        XCTAssertEqual(run.minutes.count, 1)
        let minute = try XCTUnwrap(run.minutes.first)
        XCTAssertEqual(minute.textureBytes, 123)
        XCTAssertEqual(minute.decoderPoolBytes, 456)
        XCTAssertEqual(minute.textCacheBytes, 789)
        XCTAssertEqual(minute.readbackBytes, 1011)
        XCTAssertGreaterThan(minute.memoryBytes, 0, "the resident size stays, for older readers")
        XCTAssertGreaterThan(minute.footprintBytes, 0, "the kernel's phys_footprint")
        XCTAssertGreaterThan(minute.heapLiveBytes, 0, "the malloc zones' bytes in use")
    }

    func test_processMemoryReadsPlausibleFigures() {
        let memory = ProcessMemory.current()
        XCTAssertGreaterThan(memory.residentBytes, 0)
        XCTAssertGreaterThan(memory.footprintBytes, 0)
        XCTAssertGreaterThan(memory.heapLiveBytes, 0)
        XCTAssertGreaterThanOrEqual(memory.heapAllocatedBytes, memory.heapLiveBytes, "a zone holds at least what is in use")
        XCTAssertGreaterThanOrEqual(memory.purgeableLiveBytes, 0)
        XCTAssertGreaterThanOrEqual(memory.graphicsFootprintBytes, 0)
        XCTAssertLessThanOrEqual(memory.graphicsFootprintBytes, memory.footprintBytes, "the graphics-tagged part is part of the footprint")
    }
}

// MARK: - The engine's own accounts

final class MemoryAccountTests: XCTestCase {
    func test_textureDescriptorBytesFollowTheRoleAndTheMipChain() {
        // Spec 4 §5: RGBA16Float for channel and stack textures (70.8 MB at 4096×2160), BGRA8 for text lines and posters.
        XCTAssertEqual(TextureDescriptor(role: .channel, size: PixelSize(width: 1920, height: 1080)).bytes, 16_588_800)
        XCTAssertEqual(TextureDescriptor(role: .stack, size: PixelSize(width: 4096, height: 2160)).bytes, 70_778_880)
        XCTAssertEqual(TextureDescriptor(role: .textLine, size: PixelSize(width: 1000, height: 100)).bytes, 400_000)
        XCTAssertEqual(TextureDescriptor(role: .poster, size: PixelSize(width: 960, height: 540)).bytes, 2_073_600)
        XCTAssertEqual(TextureDescriptor(role: .still, size: PixelSize(width: 1920, height: 1080), mipmapped: true).bytes,
                       16_588_800 + 16_588_800 / 3, "a mip chain adds a third")
    }

    func test_resourceTableSumsTheBytesOfLiveTextures() {
        let table = ResourceTable(capacity: 8)
        let channel = table.allocate(nil, descriptor: TextureDescriptor(role: .channel, size: PixelSize(width: 1920, height: 1080)))
        let line = table.allocate(nil, descriptor: TextureDescriptor(role: .textLine, size: PixelSize(width: 1000, height: 100)))
        XCTAssertEqual(table.allocatedBytes, 16_588_800 + 400_000)
        table.release(line, afterTick: 10)
        XCTAssertEqual(table.allocatedBytes, 16_588_800 + 400_000, "a deferred release still holds its texture")
        table.sweep(consumedTick: 10)
        XCTAssertEqual(table.allocatedBytes, 16_588_800)
        table.release(channel, afterTick: 11)
        table.sweep(consumedTick: 11)
        XCTAssertEqual(table.allocatedBytes, 0)
    }

    func test_decoderPoolBytesFollowTheOutputFormatAndTheSpecDepth() {
        // Spec 4 §5: "Decoder pool of 8 per session: 4 queued, 1 on screen, headroom for the outgoing instance".
        XCTAssertEqual(VideoFileSource.poolDepth, 8)
        XCTAssertEqual(VideoFileSource.poolBytes(pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: 1920, height: 1080),
                       1920 * 1080 * 3 / 2 * 8, "NV12: a byte of luma and half a byte of chroma per pixel")
        XCTAssertEqual(VideoFileSource.poolBytes(pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 1920, height: 1080),
                       1920 * 1080 * 3 * 8, "P010: 16-bit samples")
        XCTAssertEqual(VideoFileSource.poolBytes(pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, width: 1920, height: 1080),
                       1920 * 1080 * 4 * 8, "4:2:2 10-bit: two 16-bit samples per pixel")
        XCTAssertEqual(VideoFileSource.poolBytes(pixelFormat: kCVPixelFormatType_64RGBAHalf, width: 1920, height: 1080),
                       1920 * 1080 * 8 * 8, "16-bit RGBA")
    }

    func test_sourceTableSumsThePoolBytesOfLiveSources() {
        let table = SourceTable(capacity: 4)
        let a = PooledSource(poolBytes: 24_883_200)
        let b = PooledSource(poolBytes: 1_000)
        table.install(a, at: InstanceHandle(rawValue: 0))
        table.install(b, at: InstanceHandle(rawValue: 1))
        XCTAssertEqual(table.poolBytes, 24_884_200)
        table.remove(InstanceHandle(rawValue: 0))
        XCTAssertEqual(table.poolBytes, 1_000)
        table.remove(InstanceHandle(rawValue: 1))
        XCTAssertEqual(table.poolBytes, 0)
    }
}

/// A source that owns a pool of a known size and nothing else.
private final class PooledSource: ContentSource, @unchecked Sendable {
    let layout: SourceLayout = .nv12
    let size = PixelSize(width: 1920, height: 1080)
    let isReady = true
    let queueDepth = 0
    let poolBytes: Int

    init(poolBytes: Int) { self.poolBytes = poolBytes }
    func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult { .nothing }
    func release() {}
}

// MARK: - Spec 4 §13 — the footprint's sliding median and the heap's live bytes

final class MemoryThresholdTests: XCTestCase {
    let mb: Int64 = 1_048_576

    func run(minutes: Int, footprint: (Int) -> Int64, graphics: (Int) -> Int64 = { _ in 0 }, heap: (Int) -> Int64 = { _ in 75 * 1_048_576 },
             resident: (Int) -> Int64 = { _ in 260 * 1_048_576 }) -> SoakRun {
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        for minute in 0..<minutes {
            run.add(MinuteRecord(minute: minute, memoryBytes: resident(minute), decoderSessions: 1, textCacheHitRate: 1,
                                 audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0,
                                 footprintBytes: footprint(minute), graphicsFootprintBytes: graphics(minute), heapLiveBytes: heap(minute),
                                 heapAllocatedBytes: heap(minute) + 10 * mb, purgeableLiveBytes: 0, textureBytes: 0, decoderPoolBytes: 0,
                                 textCacheBytes: 0, readbackBytes: 0))
        }
        return run
    }

    func test_theWindowIsFiveMinutesUntilTheBenchRecordSetsIt() {
        XCTAssertEqual(SoakThresholds.medianWindowMinutes, 5)
    }

    func test_theGPUSwingDoesNotFailTheSlidingMedian() {
        // The attribution run: the GPU-owned part swung between 173 MB and 213 MB while nothing else moved. The swing is the
        // graphics-tagged part of the footprint, which the rule leaves out; on the whole footprint it would fail at random.
        let graphics: (Int) -> Int64 = { minute in Int64((minute / 3) % 2 == 1 ? 213 : 173) * self.mb }
        let run = run(minutes: 40, footprint: { minute in 387 * self.mb + graphics(minute) }, graphics: graphics)
        XCTAssertEqual(SoakThresholds.evaluate(run), [])
        XCTAssertNotEqual(SoakThresholds.slidingMedians(run.minutes.filter { $0.minute >= 10 }.map(\.footprintBytes), window: 5)?.peak,
                          SoakThresholds.slidingMedians(run.minutes.filter { $0.minute >= 10 }.map(\.footprintBytes), window: 5)?.baseline,
                          "the whole footprint's medians do swing")
    }

    func test_warmUpBeforeMinuteTenIsNotJudged() {
        let run = run(minutes: 40, footprint: { minute in Int64(min(580, 400 + minute * 30)) * self.mb })
        XCTAssertEqual(SoakThresholds.evaluate(run), [])
    }

    func test_aSteadyFootprintClimbFailsOnTheMedians() {
        let run = run(minutes: 40, footprint: { minute in Int64(560 + max(0, minute - 10) * 2) * self.mb })
        let failures = SoakThresholds.evaluate(run)
        guard case .footprintNotFlat(let baseline, let peak)? = failures.first else { return XCTFail("\(failures)") }
        XCTAssertEqual(baseline, 564 * mb, "the median of minutes 10 to 14")
        XCTAssertEqual(peak, 614 * mb, "the median of minutes 35 to 39")
    }

    func test_aHeapClimbFailsOnItsOwn() {
        let run = run(minutes: 40, footprint: { _ in 580 * self.mb }, heap: { minute in Int64(75 + max(0, minute - 10)) * self.mb })
        let failures = SoakThresholds.evaluate(run)
        guard case .heapNotFlat(let baseline, let peak)? = failures.first else { return XCTFail("\(failures)") }
        XCTAssertEqual(baseline, 77 * mb)
        XCTAssertEqual(peak, 102 * mb)
    }

    func test_recordsWithoutTheFootprintAreJudgedOnResidentSizeAsBefore() {
        let flat = run(minutes: 20, footprint: { _ in 0 }, heap: { _ in 0 }, resident: { _ in 800_000_000 })
        XCTAssertEqual(SoakThresholds.evaluate(flat), [])
        let grown = run(minutes: 20, footprint: { _ in 0 }, heap: { _ in 0 }, resident: { minute in minute >= 15 ? 900_000_000 : 800_000_000 })
        XCTAssertEqual(SoakThresholds.evaluate(grown), [.memoryNotFlat(baselineBytes: 800_000_000, peakBytes: 900_000_000)])
    }

    func test_fewerSettledMinutesThanTheWindowCannotFailOnMemory() {
        let run = run(minutes: 13, footprint: { minute in Int64(560 + minute * 10) * self.mb })
        XCTAssertEqual(SoakThresholds.evaluate(run), [])
    }

    func test_theReportNamesTheLargestGrower() {
        // The attribution run's shape: purgeable memory up 14 MB, textures up 2 MB, the rest flat.
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        for minute in 0..<35 {
            let settled = Int64(max(0, minute - 10))
            run.add(MinuteRecord(minute: minute, memoryBytes: (255 + settled) * mb, decoderSessions: 1, textCacheHitRate: 1,
                                 audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0,
                                 footprintBytes: 580 * mb, heapLiveBytes: 75 * mb, heapAllocatedBytes: 90 * mb,
                                 purgeableLiveBytes: (7 + settled * 14 / 24) * mb, textureBytes: (115 + min(2, settled)) * mb,
                                 decoderPoolBytes: 24 * mb, textCacheBytes: 50 * mb, readbackBytes: 35 * mb))
        }
        let report = BlackBoxReader.report(run: run, failures: SoakThresholds.evaluate(run))
        XCTAssertTrue(report.contains("largest grower: purgeable"), report)
        XCTAssertTrue(report.contains("footprint"), report)
        XCTAssertTrue(report.contains("PASS"), report)
    }
}
