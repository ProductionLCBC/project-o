import XCTest
import OCore
@testable import OEngine

/// Spec 4 §13 — "Per minute: ... audio underruns per device"; the live
/// summary under the `metrics` topic. Area 16 reading, approved 2026-11-03:
/// `audioUnderrunsByDevice` beside the total, keyed by the graph's primary
/// device, and the device states as the badge until the app exists.
final class AudioMetricsTests: XCTestCase {
    func test_minuteRecordCarriesUnderrunsPerDeviceAndOldLinesReadAsEmpty() {
        var record = MinuteRecord(minute: 3, memoryBytes: 270_000_000, decoderSessions: 1, textCacheHitRate: 0.99, audioUnderruns: 3,
                                  watchdogEvents: 0, watchdogRecoveries: 0, footprintBytes: 590_000_000)
        record.audioUnderrunsByDevice = ["sdi:2": 1, "BlackHole2ch_UID": 2]
        let line = BlackBox.line(for: record)
        XCTAssertTrue(line.contains("\"audioUnderrunsByDevice\":{\"BlackHole2ch_UID\":2,\"sdi:2\":1}"), line)
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [2], displayOutputs: [1])
        BlackBoxReader.add(line: line, to: &run)
        XCTAssertEqual(run.minutes, [record])
        let old = "{\"audioUnderruns\":0,\"decoderSessions\":2,\"kind\":\"minute\",\"memoryBytes\":268943360,\"minute\":10,\"textCacheHitRate\":0.9997,\"watchdogEvents\":0,\"watchdogRecoveries\":0}\n"
        BlackBoxReader.add(line: old, to: &run)
        XCTAssertEqual(run.minutes.last?.audioUnderrunsByDevice, [:], "a line from before the key reads as empty")
    }

    func test_recorderWritesPerMinuteDeltasPerDevice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-audio-minutes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let counts = SettableCounts()
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: MetricsRing(capacity: 16), presents: [], tickNanoseconds: 16_666_667,
                                        sources: BlackBoxRecorder.MinuteSources(audioUnderruns: { counts.value.values.reduce(0, +) },
                                                                                audioUnderrunsByDevice: { counts.value }),
                                        log: EngineLog(category: "test"))
        counts.set(["A": 100, "B": 0])
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        counts.set(["A": 100, "B": 5])
        recorder.writeMinute(now: Date(timeIntervalSince1970: 1_793_368_800))
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        XCTAssertEqual(run.minutes.map(\.audioUnderrunsByDevice), [["A": 100, "B": 0], ["A": 0, "B": 5]], "what happened in that minute, per device")
        XCTAssertEqual(run.minutes.map(\.audioUnderruns), [100, 5])
        XCTAssertEqual(SoakThresholds.evaluate(run), [.audioUnderruns(count: 105)])
        XCTAssertEqual(recorder.snapshot(uptimeSeconds: 120).audioUnderrunsByDevice, ["A": 100, "B": 5], "the snapshot carries the totals since start")
    }

    func test_snapshotCarriesTheDeviceStates() throws {
        var snapshot = MetricsSnapshot(tickNanoseconds: 16_666_667)
        snapshot.audioUnderruns = 2
        snapshot.audioUnderrunsByDevice = ["A": 2]
        snapshot.audioDevices = [AudioDeviceSnapshot(device: "A", outputs: [1, 3], standing: .fallback, standIn: "C", underruns: 2),
                                 AudioDeviceSnapshot(device: "sdi:2", outputs: [2], standing: .silent, standIn: nil, underruns: 0)]
        let text = String(decoding: try snapshot.json(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"audioDevices\":[{\"device\":\"A\",\"outputs\":[1,3],\"standIn\":\"C\",\"standing\":\"fallback\",\"underruns\":2},"), String(text.prefix(120)))
        XCTAssertTrue(text.contains("{\"device\":\"sdi:2\",\"outputs\":[2],\"standing\":\"silent\",\"underruns\":0}"), text)
        XCTAssertTrue(text.contains("\"audioUnderrunsByDevice\":{\"A\":2}"), text)
        XCTAssertEqual(try MetricsSnapshot.decode(try snapshot.json()), snapshot)
    }

    func test_recorderFillsTheDeviceStatesFromItsSource() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-audio-states-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let states = [AudioDeviceSnapshot(device: "default", outputs: [1], standing: .primary, standIn: nil, underruns: 0)]
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: MetricsRing(capacity: 16), presents: [], tickNanoseconds: 16_666_667,
                                        sources: BlackBoxRecorder.MinuteSources(audioDevices: { states }), log: EngineLog(category: "test"))
        XCTAssertEqual(recorder.snapshot(uptimeSeconds: 1).audioDevices, states)
    }
}

/// A settable per-device count for test sources.
final class SettableCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func set(_ value: [String: Int]) { lock.lock(); counts = value; lock.unlock() }
    var value: [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
}
