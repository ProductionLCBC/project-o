import XCTest
import OCore
@testable import OEngine

/// Spec 4 §13 — "Per output, per presented frame: presented or re-presented,
/// present latency (tick to vsync or to scheduled slot), DeckLink completion
/// result, drop count since start." "a live summary the API exposes under
/// the `metrics` topic". "Per minute: ... cache hit rates ... watchdog
/// events" with the notes of §12: "thermal throttling is logged from the
/// process thermal state so a rising GPU time has an explanation"; memory
/// pressure. Area 5 readings, approved on 2026-11-03: the minute record
/// gains the thermal state, the memory-pressure state and the thumbnail
/// cache's hit rate; the snapshot answers `/o/query` at `/o/metrics` until
/// the API carries the topic.
final class PresentLatencyTests: XCTestCase {
    /// Spec 4 §13 — "present latency (tick to vsync or to scheduled slot)":
    /// every completed frame carries its tick's reference time; the capturing
    /// sink's latency is the present time minus it.
    func test_completedFramesCarryTheirTicksReferenceAndTheCapturingSinkMeasuresFromIt() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        engine.tick(count: 3)
        let sink = try XCTUnwrap(engine.sinks[1])
        let newest = try XCTUnwrap(sink.ring.newest)
        XCTAssertEqual(newest.referenceNs, engine.clock.now().nanoseconds, "the frame of tick 2 carries tick 2's reference")
        var records: [PresentRecord] = []
        sink.presents.drain { records.append($0) }
        XCTAssertEqual(records.map(\.frame), [0, 1, 2])
        XCTAssertEqual(records.map(\.latencyNs), [0, 0, 0], "the harness presents on the tick itself")
        sink.present(now: engine.clock.now().advanced(by: 4_000_000))   // a refresh with nothing new: a re-present, no latency
        sink.presents.drain { records.append($0) }
        XCTAssertEqual(records.last?.rePresented, true)
    }

    /// Spec 4 §13 — the DeckLink sink's latency is the scheduled slot minus
    /// the tick's reference when the card's clock is the master, else the
    /// time to the slot.
    func test_deckLinkLatencyIsSlotMinusReferenceWhenTheCardIsTheMaster() {
        XCTAssertEqual(DeckLinkSink.presentLatency(scheduledNs: 1_050_000_000, referenceNs: 1_000_000_000, nowNs: 1_030_000_000, referenceIsStreamTime: true), 50_000_000)
        XCTAssertEqual(DeckLinkSink.presentLatency(scheduledNs: 1_050_000_000, referenceNs: 7, nowNs: 1_030_000_000, referenceIsStreamTime: false), 20_000_000,
                       "another master: the time from now to the slot")
        XCTAssertEqual(DeckLinkSink.presentLatency(scheduledNs: 900, referenceNs: 1000, nowNs: 950, referenceIsStreamTime: true), 0, "never negative")
    }

    /// Spec 4 §10 and §13 — the display sink's latency is the vsync it targets minus the tick's reference.
    func test_displayLatencyIsTheTargetVsyncMinusTheTicksReference() {
        XCTAssertEqual(DisplaySink.presentLatency(targetNs: 2_016_666_667, referenceNs: 2_000_000_000), 16_666_667)
        XCTAssertEqual(DisplaySink.presentLatency(targetNs: 5, referenceNs: 9), 0)
    }
}

final class MetricsSummaryTests: XCTestCase {
    func present(_ output: Int, _ frame: Int64, latency: Int64, rePresented: Bool = false, completion: SinkCompletion? = .completed) -> PresentRecord {
        PresentRecord(output: output, frame: frame, rePresented: rePresented, latencyNs: latency, completion: completion, dropsSinceStart: 0)
    }

    /// Spec 4 §13 — the live summary per output: presented, re-presented,
    /// the DeckLink completion results, and the present latency as p50 and p99.
    func test_summaryCarriesPerOutputLatencyPercentilesAndCompletions() {
        var summary = MetricsSummary(tickNanoseconds: 16_666_667)
        for i in 0..<100 {
            summary.add(present(1, Int64(i), latency: Int64(i + 1) * 100_000))              // 0.1 ... 10 ms
            summary.add(present(2, Int64(i), latency: 2_000_000, completion: i == 7 ? .displayedLate : .completed))
        }
        summary.add(present(1, 100, latency: 0, rePresented: true, completion: nil))
        summary.add(present(2, 100, latency: 0, completion: .dropped))
        let one = summary.output(1)
        XCTAssertEqual(one?.presented, 100)
        XCTAssertEqual(one?.rePresented, 1)
        XCTAssertEqual(one?.latencyP50Ns, 5_100_000)
        XCTAssertEqual(one?.latencyP99Ns, 10_000_000, "the rank floor(0.99 × n), as the GPU p99 is taken")
        let two = summary.output(2)
        XCTAssertEqual(two?.displayedLate, 1)
        XCTAssertEqual(two?.dropped, 1)
        XCTAssertEqual(two?.completed, 99)
        XCTAssertEqual(two?.latencyP50Ns, 2_000_000)
        XCTAssertEqual(summary.outputs.map(\.output), [1, 2], "in output order")
        var tick = TickRecord()
        tick.cpuEncodeNs = 1_200_000
        tick.gpuChannelNs = 3_000_000
        summary.add(tick)
        XCTAssertEqual(summary.cpuP99Nanoseconds, 1_200_000)
    }
}

final class MetricsSnapshotTests: XCTestCase {
    func sample() -> MetricsSnapshot {
        var snapshot = MetricsSnapshot(tickNanoseconds: 16_666_667)
        snapshot.uptimeSeconds = 125
        snapshot.ticks = 7500
        snapshot.planReused = 1
        snapshot.textLate = 2
        snapshot.auxSkipped = 3
        snapshot.videoRepeats = 4
        snapshot.gpuFailures = 0
        snapshot.gpuP99Ns = 4_100_000
        snapshot.cpuP99Ns = 900_000
        snapshot.outputs = [MetricsSnapshot.OutputSnapshot(output: 1, presented: 7400, rePresented: 1, dropped: 0, displayedLate: 0, latencyP50Ns: 16_000_000, latencyP99Ns: 17_000_000),
                            MetricsSnapshot.OutputSnapshot(output: 2, presented: 7400, rePresented: 0, dropped: 0, displayedLate: 0, latencyP50Ns: 33_000_000, latencyP99Ns: 34_000_000)]
        snapshot.memory = MetricsSnapshot.MemorySnapshot(footprintBytes: 590_000_000, graphicsFootprintBytes: 330_000_000, heapLiveBytes: 78_000_000,
                                                         heapAllocatedBytes: 92_000_000, purgeableLiveBytes: 7_000_000, residentBytes: 270_000_000,
                                                         textureBytes: 120_000_000, decoderPoolBytes: 24_883_200, textCacheBytes: 52_000_000, readbackBytes: 35_000_000)
        snapshot.decoderSessions = 2
        snapshot.textCacheHitRate = 0.9995
        snapshot.thumbnailCacheHitRate = 0.5
        snapshot.fontSubstitutions = 1
        snapshot.thermalState = .fair
        snapshot.memoryPressure = .warning
        snapshot.watchdogEvents = 3
        snapshot.watchdogRecoveries = 0
        snapshot.audioUnderruns = 0
        return snapshot
    }

    /// Spec 4 §13 — "Metrics contain numbers and ids, never text content or
    /// file names beyond hashes"; CLAUDE.md — JSON with sorted keys.
    func test_snapshotJSONIsSortedNumbersAndIdsAndRoundTrips() throws {
        let snapshot = sample()
        let data = try snapshot.json()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"audioUnderruns\":0,\"auxSkipped\":3,\"cpuP99Ns\":900000,"), String(text.prefix(60)))
        XCTAssertFalse(text.contains("\n"), "one line, for an OSC string")
        XCTAssertTrue(text.contains("\"thermalState\":\"fair\""))
        XCTAssertTrue(text.contains("\"memoryPressure\":\"warning\""))
        XCTAssertTrue(text.contains("\"outputs\":[{"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys.sorted()
        XCTAssertEqual(keys.first, "audioUnderruns")
        XCTAssertEqual(try MetricsSnapshot.decode(data), snapshot)
    }

    /// Area 5 reading — until the API exists, `/o/query` at `/o/metrics`
    /// answers the snapshot as one string (a Spec 2 §6 addition).
    func test_theMetricsQueryAnswersWithTheSnapshotAsOneString() throws {
        let snapshot = sample()
        let message = try XCTUnwrap(MetricsQuery.answer("/o/metrics", snapshot: snapshot))
        XCTAssertEqual(message.address, "/o/metrics")
        XCTAssertEqual(message.arguments.count, 1)
        guard case .string(let json)? = message.arguments.first else { return XCTFail("one string argument") }
        XCTAssertEqual(try MetricsSnapshot.decode(Data(json.utf8)), snapshot)
        XCTAssertNil(MetricsQuery.answer("/o/metrics/other", snapshot: snapshot))
        XCTAssertNil(MetricsQuery.answer("/o/output/1/stack", snapshot: snapshot), "every other address is someone else's")
    }

    /// The answer over the socket, through the server's query handler.
    func test_theQueryReachesAClientOverUDP() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        let server = OSCServer(port: 0, targets: [], mediaIDs: [], log: engine.log) { _ in }
        try server.start()
        defer { server.stop() }
        let snapshot = sample()
        server.queryHandler = { @Sendable address in MetricsQuery.answer(address, snapshot: snapshot) }
        let client = try UDPTestClient()
        defer { client.close() }
        try client.send(OSCMessage("/o/query", [.string("/o/metrics")]).encoded(), to: server.boundPort)
        let reply = try XCTUnwrap(client.receive(timeout: 5))
        guard case .success(.message(let message)) = OSCPacket.decode(reply), case .string(let json)? = message.arguments.first else { return XCTFail() }
        XCTAssertEqual(message.address, "/o/metrics")
        XCTAssertEqual(try MetricsSnapshot.decode(Data(json.utf8)).ticks, 7500)
    }
}

final class MinuteNotesTests: XCTestCase {
    /// Spec 4 §13 and §12 — the minute record carries the thermal state, the
    /// memory-pressure state and the thumbnail cache's hit rate; a line
    /// written before these keys existed reads as unknown.
    func test_minuteRecordCarriesTheStatesAndTheThumbnailHitRate() {
        var record = MinuteRecord(minute: 12, memoryBytes: 270_000_000, decoderSessions: 1, textCacheHitRate: 0.9995, audioUnderruns: 0,
                                  watchdogEvents: 0, watchdogRecoveries: 0, footprintBytes: 590_000_000)
        record.thermalState = .serious
        record.memoryPressure = .warning
        record.thumbnailCacheHitRate = 0.75
        let line = BlackBox.line(for: record)
        XCTAssertTrue(line.contains("\"thermalState\":\"serious\""), line)
        XCTAssertTrue(line.contains("\"memoryPressure\":\"warning\""), line)
        XCTAssertTrue(line.contains("\"thumbnailCacheHitRate\":0.7500"), line)
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        BlackBoxReader.add(line: line, to: &run)
        XCTAssertEqual(run.minutes, [record])
        let old = "{\"audioUnderruns\":0,\"decoderSessions\":2,\"kind\":\"minute\",\"memoryBytes\":268943360,\"minute\":10,\"textCacheHitRate\":0.9997,\"watchdogEvents\":0,\"watchdogRecoveries\":0}\n"
        BlackBoxReader.add(line: old, to: &run)
        XCTAssertEqual(run.minutes.last?.thermalState, .unknown)
        XCTAssertEqual(run.minutes.last?.memoryPressure, .unknown)
        XCTAssertEqual(run.minutes.last?.thumbnailCacheHitRate, 1, "nothing was asked of a cache that did not exist")
    }

    func test_recorderFillsTheNotesFromItsSourcesAndBuildsTheSnapshot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let ticks = MetricsRing(capacity: 64)
        let presents = PresentRing(capacity: 64)
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: ticks, presents: [presents], tickNanoseconds: 16_666_667,
                                        sources: BlackBoxRecorder.MinuteSources(decoderSessions: { 2 }, textCacheHitRate: { 0.99 },
                                                                                thumbnailCacheHitRate: { 0.5 }, fontSubstitutions: { 1 },
                                                                                thermalState: { .fair }, memoryPressure: { .critical }),
                                        log: EngineLog(category: "test"))
        for frame in 0..<10 {
            var record = TickRecord()
            record.frame = Int64(frame)
            record.gpuChannelNs = 2_000_000
            record.cpuEncodeNs = 500_000
            ticks.write(record)
            presents.write(PresentRecord(output: 1, frame: Int64(frame), rePresented: frame == 4, latencyNs: 16_000_000, completion: .completed, dropsSinceStart: 0))
        }
        recorder.drain(now: Date(timeIntervalSince1970: 1_793_368_800))
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        let minute = try XCTUnwrap(run.minutes.first)
        XCTAssertEqual(minute.thermalState, .fair)
        XCTAssertEqual(minute.memoryPressure, .critical)
        XCTAssertEqual(minute.thumbnailCacheHitRate, 0.5)
        let snapshot = recorder.snapshot(uptimeSeconds: 61)
        XCTAssertEqual(snapshot.ticks, 10)
        XCTAssertEqual(snapshot.gpuP99Ns, 2_000_000)
        XCTAssertEqual(snapshot.cpuP99Ns, 500_000)
        XCTAssertEqual(snapshot.outputs.map(\.output), [1])
        XCTAssertEqual(snapshot.outputs.first?.presented, 9)
        XCTAssertEqual(snapshot.outputs.first?.rePresented, 1)
        XCTAssertEqual(snapshot.outputs.first?.latencyP50Ns, 16_000_000)
        XCTAssertEqual(snapshot.memory?.footprintBytes, minute.footprintBytes, "the latest minute's memory figures")
        XCTAssertEqual(snapshot.decoderSessions, 2)
        XCTAssertEqual(snapshot.thumbnailCacheHitRate, 0.5)
        XCTAssertEqual(snapshot.fontSubstitutions, 1)
        XCTAssertEqual(snapshot.thermalState, .fair)
        XCTAssertEqual(snapshot.memoryPressure, .critical)
        XCTAssertEqual(snapshot.uptimeSeconds, 61)
        let report = BlackBoxReader.report(run: run, failures: SoakThresholds.evaluate(run))
        XCTAssertTrue(report.contains("present latency p50 16.00 ms"), report)
        XCTAssertTrue(report.contains("thermal state above nominal in 1 minute"), report)
        XCTAssertTrue(report.contains("memory pressure above normal in 1 minute"), report)
    }
}
