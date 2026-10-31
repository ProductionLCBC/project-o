// OEngine — Spec 4 §13, the black box and the live summary.

import Foundation

/// Spec 4 §13 — "a utility thread drains the ring into the black box (JSON
/// lines, rotated daily) and into a live summary the API exposes under the
/// `metrics` topic. The soak rig reads the same files." Privacy: "Metrics
/// contain numbers and ids, never text content or file names beyond hashes".
/// Logs "rotate daily and are capped by total size, oldest first."
public final class BlackBox: @unchecked Sendable {
    public let folder: URL
    public let maximumBytes: Int
    private let lock = NSLock()
    private var currentDay = ""
    private var handle: FileHandle?
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public init(folder: URL, maximumBytes: Int = 512 * 1024 * 1024) {
        self.folder = folder
        self.maximumBytes = maximumBytes
    }

    deinit {
        try? handle?.close()
    }

    // MARK: - Lines

    /// One tick as a JSON line: sorted keys, no spaces, numbers and ids only.
    public static func line(for record: TickRecord) -> String {
        var fields: [(String, String)] = [
            ("auxSkipped", String(record.auxSkipped)),
            ("channelPasses", String(record.channelPasses)),
            ("cpuEncodeNs", String(record.cpuEncodeNs)),
            ("frame", String(record.frame)),
            ("gpuChannelNs", String(record.gpuChannelNs)),
            ("gpuSinkNs", String(record.gpuSinkNs)),
            ("gpuStackNs", String(record.gpuStackNs)),
            ("kind", "\"tick\""),
            ("masterTimeNs", String(record.masterTimeNs)),
            ("planReused", record.planReused ? "true" : "false"),
            ("queueDepths", "[" + record.instanceQueueDepths.map(String.init).joined(separator: ",") + "]"),
            ("stackPasses", String(record.stackPasses)),
            ("textLate", String(record.textLate)),
            ("videoRepeat", "[" + record.videoRepeat.map(String.init).joined(separator: ",") + "]"),
        ]
        if record.gpuFailed { fields.append(("gpuFailed", "true")) }
        return json(fields)
    }

    public static func line(for record: PresentRecord) -> String {
        var fields: [(String, String)] = []
        if let completion = record.completion { fields.append(("completion", "\"\(completion.rawValue)\"")) }
        fields += [
            ("dropsSinceStart", String(record.dropsSinceStart)),
            ("frame", String(record.frame)),
            ("kind", "\"present\""),
            ("latencyNs", String(record.latencyNs)),
            ("output", String(record.output)),
            ("rePresented", record.rePresented ? "true" : "false"),
        ]
        return json(fields)
    }

    public static func line(for record: MinuteRecord) -> String {
        json([
            ("audioUnderruns", String(record.audioUnderruns)),
            ("decoderSessions", String(record.decoderSessions)),
            ("kind", "\"minute\""),
            ("memoryBytes", String(record.memoryBytes)),
            ("minute", String(record.minute)),
            ("textCacheHitRate", String(format: "%.4f", record.textCacheHitRate)),
            ("watchdogEvents", String(record.watchdogEvents)),
            ("watchdogRecoveries", String(record.watchdogRecoveries)),
        ])
    }

    static func json(_ fields: [(String, String)]) -> String {
        "{" + fields.sorted { $0.0 < $1.0 }.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}\n"
    }

    // MARK: - Files

    public func append(_ record: TickRecord, at date: Date = Date()) throws {
        try append(line: BlackBox.line(for: record), at: date)
    }

    public func append(_ record: PresentRecord, at date: Date = Date()) throws {
        try append(line: BlackBox.line(for: record), at: date)
    }

    public func append(_ record: MinuteRecord, at date: Date = Date()) throws {
        try append(line: BlackBox.line(for: record), at: date)
    }

    /// Append one line to the day's file, rotating by UTC day and trimming
    /// the oldest files past the cap.
    public func append(line: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let day = BlackBox.dayFormatter.string(from: date)
        if day != currentDay || handle == nil {
            try? handle?.close()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("blackbox-\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle?.seekToEnd()
            currentDay = day
        }
        try handle?.write(contentsOf: Data(line.utf8))
        try trim()
    }

    /// Spec 4 §13 — "capped by total size, oldest first": never the current day.
    private func trim() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("blackbox-") && $0.hasSuffix(".jsonl") }
            .sorted()
        var sizes: [(String, Int)] = names.map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0
            return (name, size)
        }
        var total = sizes.reduce(0) { $0 + $1.1 }
        while total > maximumBytes, sizes.count > 1 {
            let oldest = sizes.removeFirst()
            try FileManager.default.removeItem(at: folder.appendingPathComponent(oldest.0))
            total -= oldest.1
        }
    }
}

/// Spec 4 §13 — "a live summary the API exposes under the `metrics` topic":
/// totals since start and the GPU p99 over the last minute of ticks.
public struct MetricsSummary: Sendable {
    public let tickNanoseconds: Int64
    public private(set) var ticks: Int64 = 0
    public private(set) var planReused: Int64 = 0
    public private(set) var textLate: Int64 = 0
    public private(set) var auxSkipped: Int64 = 0
    public private(set) var videoRepeats: Int64 = 0
    public private(set) var gpuFailures: Int64 = 0
    private var window: [Int64] = []
    private var windowIndex = 0
    private let windowSize: Int

    public init(tickNanoseconds: Int64, windowSize: Int = 3600) {
        self.tickNanoseconds = tickNanoseconds
        self.windowSize = max(1, windowSize)
    }

    public mutating func add(_ record: TickRecord) {
        ticks += 1
        if record.planReused { planReused += 1 }
        textLate += Int64(record.textLate)
        auxSkipped += Int64(record.auxSkipped)
        videoRepeats += Int64(record.videoRepeat.count)
        if record.gpuFailed { gpuFailures += 1 }
        if window.count < windowSize {
            window.append(record.gpuTotalNs)
        } else {
            window[windowIndex] = record.gpuTotalNs
            windowIndex = (windowIndex + 1) % windowSize
        }
    }

    /// The 99th percentile of GPU time over the window, as the soak rig
    /// measures it: the value at rank floor(0.99 × n), so it never flatters.
    public var p99GPUNanoseconds: Int64 {
        guard !window.isEmpty else { return 0 }
        let sorted = window.sorted()
        return sorted[min(sorted.count - 1, Int(0.99 * Double(sorted.count)))]
    }

    public var p99Fraction: Double {
        tickNanoseconds > 0 ? Double(p99GPUNanoseconds) / Double(tickNanoseconds) : 0
    }
}
