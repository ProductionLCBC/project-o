import XCTest
import OCore
@testable import OEngine

/// Spec 4 §13 — "Every tick writes one record into a preallocated ring; a
/// utility thread drains the ring into the black box (JSON lines, rotated
/// daily)"; the soak thresholds; privacy ("numbers and ids, never text content").
final class MetricsTests: XCTestCase {
    func test_ringWritesAndDrainsInOrderWithoutAllocatingOnWrite() {
        let ring = MetricsRing(capacity: 4)
        for i in 0..<3 {
            var record = TickRecord()
            record.frame = Int64(i)
            XCTAssertTrue(ring.write(record))
        }
        var drained: [TickRecord] = []
        ring.drain { drained.append($0) }
        XCTAssertEqual(drained.map(\.frame), [0, 1, 2])
        ring.drain { _ in XCTFail("nothing left") }
    }

    func test_ringCountsOverflowInsteadOfBlocking() {
        let ring = MetricsRing(capacity: 2)
        XCTAssertTrue(ring.write(TickRecord()))
        XCTAssertTrue(ring.write(TickRecord()))
        XCTAssertFalse(ring.write(TickRecord()), "a full ring drops the record and counts it; the render thread never waits")
        XCTAssertEqual(ring.dropped, 1)
    }

    func test_blackBoxLineIsSortedNumbersAndIdsOnly() throws {
        var record = TickRecord()
        record.frame = 42
        record.masterTimeNs = 700_000
        record.cpuEncodeNs = 1_200_000
        record.gpuChannelNs = 3_000_000
        record.gpuStackNs = 1_000_000
        record.gpuSinkNs = 500_000
        record.channelPasses = 2
        record.stackPasses = 2
        record.auxSkipped = 1
        record.planReused = true
        record.textLate = 1
        record.videoRepeatChannels = 0b10
        record.queueDepths = 0x34
        let line = BlackBox.line(for: record)
        XCTAssertTrue(line.hasPrefix("{\"auxSkipped\":1,\"channelPasses\":2,\"cpuEncodeNs\":1200000"), line)
        XCTAssertTrue(line.hasSuffix("}\n"))
        XCTAssertFalse(line.contains(" "))
        XCTAssertTrue(line.contains("\"kind\":\"tick\""))
        XCTAssertTrue(line.contains("\"videoRepeat\":[2]"), "channel numbers, from the bitmask")
        XCTAssertTrue(line.contains("\"queueDepths\":[4,3]"), "per instance, from the packed nibbles")
        XCTAssertTrue(line.contains("\"planReused\":true"))
    }

    func test_presentRecordLine() {
        let record = PresentRecord(output: 2, frame: 10, rePresented: true, latencyNs: 4_000_000, completion: .displayedLate, dropsSinceStart: 3)
        let line = BlackBox.line(for: record)
        XCTAssertEqual(line, "{\"completion\":\"displayedLate\",\"dropsSinceStart\":3,\"frame\":10,\"kind\":\"present\",\"latencyNs\":4000000,\"output\":2,\"rePresented\":true}\n")
    }

    func test_blackBoxRotatesDailyAndCapsTotalSize() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blackbox-\(UUID().uuidString)")
        let box = BlackBox(folder: folder, maximumBytes: 2000)
        var day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 11, day: 1).date!
        for i in 0..<12 {
            var record = TickRecord()
            record.frame = Int64(i)
            try box.append(record, at: day)
            if i == 5 { day = day.addingTimeInterval(86_400) }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(files, ["blackbox-2026-11-02.jsonl"], "the cap removed the oldest day first")
        let bytes = try files.map { try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size] as? Int ?? 0 }.reduce(0, +)
        XCTAssertLessThanOrEqual(bytes, 2000)
    }

    func test_summaryTracksP99AndTotals() {
        var summary = MetricsSummary(tickNanoseconds: 16_666_667)
        for i in 0..<100 {
            var record = TickRecord()
            record.frame = Int64(i)
            record.gpuChannelNs = Int64(i) * 100_000   // 0 ... 9.9 ms
            record.textLate = i == 3 ? 1 : 0
            summary.add(record)
        }
        XCTAssertEqual(summary.ticks, 100)
        XCTAssertEqual(summary.p99GPUNanoseconds, 9_900_000)
        XCTAssertEqual(summary.textLate, 1)
        XCTAssertEqual(summary.planReused, 0)
    }
}

/// Spec 4 §13 — "Soak thresholds (a build fails on any)". The evaluator is a
/// pure function over black-box records so `scripts/soak.sh` and this test
/// share it.
final class SoakThresholdTests: XCTestCase {
    func clean(minutes: Int) -> SoakRun {
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [2], displayOutputs: [1])
        let ticks = minutes * 60 * 60
        for i in 0..<ticks {
            var record = TickRecord()
            record.frame = Int64(i)
            record.masterTimeNs = Int64(i) * 16_666_667
            record.gpuChannelNs = 3_000_000
            run.add(record)
        }
        for minute in 0..<minutes {
            run.add(MinuteRecord(minute: minute, memoryBytes: 800_000_000, decoderSessions: 2, textCacheHitRate: 0.99,
                                 audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0))
        }
        return run
    }

    func test_cleanRunPasses() {
        XCTAssertEqual(SoakThresholds.evaluate(clean(minutes: 12)), [])
    }

    func test_eachThresholdFailsOnItsOwn() {
        var run = clean(minutes: 12)
        run.add(PresentRecord(output: 2, frame: 5, rePresented: false, latencyNs: 0, completion: .dropped, dropsSinceStart: 1))
        XCTAssertEqual(SoakThresholds.evaluate(run), [.sdiDroppedOrLate(output: 2, count: 1)])

        run = clean(minutes: 12)
        run.add(PresentRecord(output: 2, frame: 5, rePresented: false, latencyNs: 0, completion: .displayedLate, dropsSinceStart: 0))
        XCTAssertEqual(SoakThresholds.evaluate(run), [.sdiDroppedOrLate(output: 2, count: 1)])

        run = clean(minutes: 12)
        for frame in 0..<4 { run.add(PresentRecord(output: 1, frame: Int64(frame), rePresented: true, latencyNs: 0, completion: nil, dropsSinceStart: 0)) }
        XCTAssertEqual(SoakThresholds.evaluate(run), [.displayRePresents(output: 1, count: 4, allowed: 2)])

        run = clean(minutes: 12)
        var slow = TickRecord()
        slow.frame = 99_999
        slow.gpuStackNs = 9_000_000
        for _ in 0..<500 { run.add(slow) }
        XCTAssertEqual(SoakThresholds.evaluate(run), [.gpuP99OverBudget(p99Ns: 9_000_000, budgetNs: 8_333_333)])

        run = clean(minutes: 12)
        var late = TickRecord()
        late.frame = 5000
        late.masterTimeNs = 5000 * 16_666_667
        late.textLate = 1
        run.add(late)
        XCTAssertEqual(SoakThresholds.evaluate(run), [.textLateAfterFirstMinute(count: 1)])

        run = clean(minutes: 12)
        var early = TickRecord()
        early.frame = 100
        early.masterTimeNs = 100 * 16_666_667
        early.textLate = 1
        run.add(early)
        XCTAssertEqual(SoakThresholds.evaluate(run), [], "the first minute is warm-up")

        run = clean(minutes: 12)
        run.add(MinuteRecord(minute: 12, memoryBytes: 800_000_000, decoderSessions: 2, textCacheHitRate: 1, audioUnderruns: 2, watchdogEvents: 0, watchdogRecoveries: 0))
        XCTAssertEqual(SoakThresholds.evaluate(run), [.audioUnderruns(count: 2)])

        run = clean(minutes: 12)
        run.add(MinuteRecord(minute: 12, memoryBytes: 900_000_000, decoderSessions: 2, textCacheHitRate: 1, audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0))
        XCTAssertEqual(SoakThresholds.evaluate(run), [.memoryNotFlat(baselineBytes: 800_000_000, peakBytes: 900_000_000)])

        run = clean(minutes: 12)
        run.add(MinuteRecord(minute: 12, memoryBytes: 800_000_000, decoderSessions: 2, textCacheHitRate: 1, audioUnderruns: 0, watchdogEvents: 1, watchdogRecoveries: 1))
        XCTAssertEqual(SoakThresholds.evaluate(run), [.watchdogRecoveries(count: 1)])
    }

    func test_memoryBaselineIsTheTenthMinute() {
        var run = clean(minutes: 12)
        run.add(MinuteRecord(minute: 3, memoryBytes: 2_000_000_000, decoderSessions: 2, textCacheHitRate: 1, audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0))
        XCTAssertEqual(SoakThresholds.evaluate(run), [], "growth in the first ten minutes is start-up")
    }
}
