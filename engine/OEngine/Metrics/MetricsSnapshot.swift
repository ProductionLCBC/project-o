// OEngine — Spec 4 §13, "a live summary the API exposes under the `metrics`
// topic".

import Foundation
import OCore

/// Spec 4 §12 — where an audio device's graph is playing: on its own device,
/// on an output's fallback device, or silent on the stand-in (Area 16).
public enum AudioDeviceStanding: String, Codable, Equatable, Sendable {
    case primary, fallback, silent
}

/// Spec 4 §12 and §13 (Area 16) — one audio device in the live summary: the
/// badge for a lost device until the app exists. `device` is the graph's
/// primary device key (a UID, `default`, `sdi:N`); `standIn` the fallback in
/// use; `underruns` since start.
public struct AudioDeviceSnapshot: Codable, Equatable, Sendable {
    public var device: String
    public var outputs: [Int]
    public var standing: AudioDeviceStanding
    public var standIn: String?
    public var underruns: Int

    public init(device: String, outputs: [Int], standing: AudioDeviceStanding, standIn: String?, underruns: Int) {
        self.device = device
        self.outputs = outputs
        self.standing = standing
        self.standIn = standIn
        self.underruns = underruns
    }
}

/// Spec 4 §13 — the live summary as one value: the tick totals and the GPU
/// and CPU p99 over the last minute, each output's presentation counts with
/// its present latency, the latest minute's memory figures, decoder
/// sessions, both cache hit rates, the font substitutions, the thermal and
/// memory-pressure states (Spec 4 §12) and the watchdog counts. "Metrics
/// contain numbers and ids, never text content or file names beyond hashes."
/// The API's `metrics` topic carries this value; until the API exists,
/// `/o/query` at `/o/metrics` answers it (Area 5 reading, approved 2026-11-03).
public struct MetricsSnapshot: Codable, Equatable, Sendable {
    public struct OutputSnapshot: Codable, Equatable, Sendable {
        public var output: Int
        public var presented: Int64
        public var rePresented: Int64
        public var dropped: Int64
        public var displayedLate: Int64
        public var latencyP50Ns: Int64
        public var latencyP99Ns: Int64

        public init(output: Int, presented: Int64, rePresented: Int64, dropped: Int64, displayedLate: Int64, latencyP50Ns: Int64, latencyP99Ns: Int64) {
            self.output = output
            self.presented = presented
            self.rePresented = rePresented
            self.dropped = dropped
            self.displayedLate = displayedLate
            self.latencyP50Ns = latencyP50Ns
            self.latencyP99Ns = latencyP99Ns
        }
    }

    /// Spec 4 §13 — the per-minute memory figures, from the latest minute record.
    public struct MemorySnapshot: Codable, Equatable, Sendable {
        public var footprintBytes: Int64
        public var graphicsFootprintBytes: Int64
        public var heapLiveBytes: Int64
        public var heapAllocatedBytes: Int64
        public var purgeableLiveBytes: Int64
        public var residentBytes: Int64
        public var textureBytes: Int64
        public var decoderPoolBytes: Int64
        public var textCacheBytes: Int64
        public var readbackBytes: Int64

        public init(footprintBytes: Int64, graphicsFootprintBytes: Int64, heapLiveBytes: Int64, heapAllocatedBytes: Int64, purgeableLiveBytes: Int64,
                    residentBytes: Int64, textureBytes: Int64, decoderPoolBytes: Int64, textCacheBytes: Int64, readbackBytes: Int64) {
            self.footprintBytes = footprintBytes
            self.graphicsFootprintBytes = graphicsFootprintBytes
            self.heapLiveBytes = heapLiveBytes
            self.heapAllocatedBytes = heapAllocatedBytes
            self.purgeableLiveBytes = purgeableLiveBytes
            self.residentBytes = residentBytes
            self.textureBytes = textureBytes
            self.decoderPoolBytes = decoderPoolBytes
            self.textCacheBytes = textCacheBytes
            self.readbackBytes = readbackBytes
        }

        public init(_ record: MinuteRecord) {
            self.init(footprintBytes: record.footprintBytes, graphicsFootprintBytes: record.graphicsFootprintBytes, heapLiveBytes: record.heapLiveBytes,
                      heapAllocatedBytes: record.heapAllocatedBytes, purgeableLiveBytes: record.purgeableLiveBytes, residentBytes: record.memoryBytes,
                      textureBytes: record.textureBytes, decoderPoolBytes: record.decoderPoolBytes, textCacheBytes: record.textCacheBytes,
                      readbackBytes: record.readbackBytes)
        }
    }

    public var tickNanoseconds: Int64
    public var uptimeSeconds: Int = 0
    public var ticks: Int64 = 0
    public var planReused: Int64 = 0
    public var textLate: Int64 = 0
    public var auxSkipped: Int64 = 0
    public var videoRepeats: Int64 = 0
    public var gpuFailures: Int64 = 0
    public var gpuP99Ns: Int64 = 0
    public var cpuP99Ns: Int64 = 0
    public var outputs: [OutputSnapshot] = []
    public var memory: MemorySnapshot?
    public var decoderSessions: Int = 0
    public var textCacheHitRate: Double = 1
    public var thumbnailCacheHitRate: Double = 1
    public var fontSubstitutions: Int = 0
    public var thermalState: ThermalLevel = .unknown
    public var memoryPressure: MemoryPressureLevel = .unknown
    public var watchdogEvents: Int = 0
    public var watchdogRecoveries: Int = 0
    public var audioUnderruns: Int = 0
    /// Spec 4 §13 — "audio underruns per device", since start (Area 16).
    public var audioUnderrunsByDevice: [String: Int] = [:]
    /// Spec 4 §12 — the audio devices' standings: the badge (Area 16).
    public var audioDevices: [AudioDeviceSnapshot] = []

    public init(tickNanoseconds: Int64) {
        self.tickNanoseconds = tickNanoseconds
    }

    /// One line of JSON with sorted keys (CLAUDE.md), as the OSC answer and
    /// the API topic carry it.
    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> MetricsSnapshot {
        try JSONDecoder().decode(MetricsSnapshot.self, from: data)
    }
}

/// Area 5 reading, approved 2026-11-03 — "the snapshot answered to
/// `/o/query` at `/o/metrics`, a Spec 2 §6 addition": the reply is the
/// snapshot's JSON as the message's one string argument.
public enum MetricsQuery {
    public static let address = "/o/metrics"

    public static func answer(_ address: String, snapshot: MetricsSnapshot) -> OSCMessage? {
        guard address == MetricsQuery.address, let data = try? snapshot.json() else { return nil }
        return OSCMessage(MetricsQuery.address, [.string(String(decoding: data, as: UTF8.self))])
    }
}
