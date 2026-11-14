// OEngine — Spec 4 §13, the black box and the live summary.

import Foundation

/// Spec 4 §13 as Spec 9 §9 corrected it — "a utility thread drains the ring
/// into the black box (JSON lines in `machine/blackbox/`, a file an hour,
/// with the minute records copied to the engine log, Spec 9 §2) and into a
/// live summary the API exposes under the `metrics` topic. The soak rig reads
/// the same files." Privacy: "Metrics contain numbers and ids, never text
/// content or file names beyond hashes".
///
/// Spec 9 §2 — `blackbox-YYYY-MM-DD-HH.jsonl`, split "By UTC hour ... The
/// black box writes about 100 MB an hour, so its size cap keeps only hours of
/// it (§7). It has its own folder and a file an hour so the cap holds within
/// a day". Spec 9 §8 — "with the same line repair and sync" as the logs: a
/// file whose last byte isn't a newline is ended on opening, and the file is
/// synced once a second, by the times its lines are given. Spec 9 §7 — "512
/// MB in all, oldest first; only the current hour's file is spared".
public final class BlackBox: @unchecked Sendable {
    /// Spec 9 §7 — "The black box | 512 MB in all".
    public static let defaultMaximumBytes = 512 * 1024 * 1024

    public let folder: URL
    public let maximumBytes: Int
    private let lock = NSLock()
    private let journal: JournalFile
    /// The files of earlier hours, oldest first, with their sizes: listed
    /// when an hour's file starts, so no line waits on a look at the folder.
    private var earlier: [(name: String, bytes: Int64)] = []
    private var lastSyncMs: Int64?
    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd-HH"
        return f
    }()

    public init(folder: URL, maximumBytes: Int = BlackBox.defaultMaximumBytes, disk: Disk = .live) {
        self.folder = folder
        self.maximumBytes = maximumBytes
        journal = JournalFile(folder: folder, prefix: "blackbox-", disk: disk)
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

    /// Spec 4 §13 — the minute record with its memory breakdown; a reader of
    /// an older file finds the breakdown keys missing and reads zeros.
    public static func line(for record: MinuteRecord) -> String {
        json([
            ("audioUnderruns", String(record.audioUnderruns)),
            // Spec 4 §13 — "audio underruns per device" (Area 16), an object with sorted keys.
            ("audioUnderrunsByDevice", "{" + record.audioUnderrunsByDevice.keys.sorted().map { "\"\($0)\":\(record.audioUnderrunsByDevice[$0] ?? 0)" }.joined(separator: ",") + "}"),
            ("decoderPoolBytes", String(record.decoderPoolBytes)),
            ("decoderSessions", String(record.decoderSessions)),
            ("footprintBytes", String(record.footprintBytes)),
            ("graphicsFootprintBytes", String(record.graphicsFootprintBytes)),
            ("heapAllocatedBytes", String(record.heapAllocatedBytes)),
            ("heapLiveBytes", String(record.heapLiveBytes)),
            ("kind", "\"minute\""),
            ("memoryBytes", String(record.memoryBytes)),
            ("memoryPressure", "\"\(record.memoryPressure.rawValue)\""),
            ("minute", String(record.minute)),
            ("purgeableLiveBytes", String(record.purgeableLiveBytes)),
            ("readbackBytes", String(record.readbackBytes)),
            ("textCacheBytes", String(record.textCacheBytes)),
            ("textCacheHitRate", String(format: "%.4f", record.textCacheHitRate)),
            ("textureBytes", String(record.textureBytes)),
            ("thermalState", "\"\(record.thermalState.rawValue)\""),
            ("thumbnailCacheHitRate", String(format: "%.4f", record.thumbnailCacheHitRate)),
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

    /// Append one line (ending in its newline) to the file of `date`'s UTC
    /// hour, trimming the oldest hours past the cap and syncing once a second.
    public func append(line: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let hour = BlackBox.hourFormatter.string(from: date)
        try journal.append(line, key: hour)
        // Spec 9 §7 — the pass runs "when ... an hour's file starts": the earlier hours, with their sizes.
        if !journal.takeStarted().isEmpty { earlier = earlierFiles(than: journal.url(for: hour).lastPathComponent) }
        trim()
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        if let last = lastSyncMs {
            if ms - last >= 1000 {
                journal.sync()
                lastSyncMs = ms
            }
        } else {
            lastSyncMs = ms
        }
    }

    /// Everything appended reaches the disk: the recorder stops.
    public func sync() {
        lock.lock()
        journal.sync()
        lock.unlock()
    }

    /// The black box files in the folder other than `current`, oldest first.
    private func earlierFiles(than current: String) -> [(name: String, bytes: Int64)] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("blackbox-") && $0.hasSuffix(".jsonl") && $0 != current }
            .sorted()
        return names.map { name in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value ?? 0
            return (name, size)
        }
    }

    /// Spec 9 §7 — "512 MB in all, oldest first; only the current hour's
    /// file is spared, so the cap holds within a day".
    private func trim() {
        var total = earlier.reduce(Int64(0)) { $0 + $1.bytes } + (journal.currentFile?.bytes ?? 0)
        while total > Int64(maximumBytes), let oldest = earlier.first {
            earlier.removeFirst()
            try? journal.disk.remove(folder.appendingPathComponent(oldest.name))
            total -= oldest.bytes
        }
    }
}

/// Spec 4 §13 — the per-output part of the live summary: "presented or
/// re-presented, present latency (tick to vsync or to scheduled slot),
/// DeckLink completion result, drop count since start", with the latency as
/// p50 and p99 over the last minute of presents.
public struct OutputSummary: Equatable, Sendable {
    public let output: Int
    public private(set) var presented: Int64 = 0
    public private(set) var rePresented: Int64 = 0
    public private(set) var completed: Int64 = 0
    public private(set) var displayedLate: Int64 = 0
    public private(set) var dropped: Int64 = 0
    public private(set) var flushed: Int64 = 0
    public private(set) var dropsSinceStart: Int64 = 0
    private var window: [Int64] = []
    private var windowIndex = 0
    private let windowSize: Int

    public init(output: Int, windowSize: Int = 3600) {
        self.output = output
        self.windowSize = max(1, windowSize)
    }

    public mutating func add(_ record: PresentRecord) {
        dropsSinceStart = max(dropsSinceStart, record.dropsSinceStart)
        if record.rePresented {
            rePresented += 1
            return
        }
        switch record.completion {
        case .completed?: completed += 1
        case .displayedLate?: displayedLate += 1
        case .dropped?: dropped += 1
        case .flushed?: flushed += 1
        case nil: break
        }
        // A DeckLink completion arrives as its own record, after the schedule; only the schedule and a display's present count as presented.
        guard record.completion != .dropped, record.completion != .flushed else { return }
        if record.completion == nil || record.latencyNs > 0 || window.isEmpty {
            presented += 1
            if window.count < windowSize {
                window.append(record.latencyNs)
            } else {
                window[windowIndex] = record.latencyNs
                windowIndex = (windowIndex + 1) % windowSize
            }
        }
    }

    public var latencyP50Ns: Int64 { percentile(0.5) }
    public var latencyP99Ns: Int64 { percentile(0.99) }

    private func percentile(_ p: Double) -> Int64 {
        guard !window.isEmpty else { return 0 }
        let sorted = window.sorted()
        return sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))]
    }
}

/// Spec 4 §13 — "a live summary the API exposes under the `metrics` topic":
/// totals since start, the GPU and CPU p99 over the last minute of ticks,
/// and each output's presentation figures.
public struct MetricsSummary: Sendable {
    public let tickNanoseconds: Int64
    public private(set) var ticks: Int64 = 0
    public private(set) var planReused: Int64 = 0
    public private(set) var textLate: Int64 = 0
    public private(set) var auxSkipped: Int64 = 0
    public private(set) var videoRepeats: Int64 = 0
    public private(set) var gpuFailures: Int64 = 0
    private var window: [Int64] = []
    private var cpuWindow: [Int64] = []
    private var windowIndex = 0
    private let windowSize: Int
    private var byOutput: [Int: OutputSummary] = [:]

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
            cpuWindow.append(record.cpuEncodeNs)
        } else {
            window[windowIndex] = record.gpuTotalNs
            cpuWindow[windowIndex] = record.cpuEncodeNs
            windowIndex = (windowIndex + 1) % windowSize
        }
    }

    /// Spec 4 §13 — "Per output, per presented frame".
    public mutating func add(_ record: PresentRecord) {
        var summary = byOutput[record.output] ?? OutputSummary(output: record.output, windowSize: windowSize)
        summary.add(record)
        byOutput[record.output] = summary
    }

    public func output(_ number: Int) -> OutputSummary? { byOutput[number] }

    /// Every output seen, in number order.
    public var outputs: [OutputSummary] { byOutput.keys.sorted().compactMap { byOutput[$0] } }

    /// The 99th percentile of GPU time over the window, as the soak rig
    /// measures it: the value at rank floor(0.99 × n), so it never flatters.
    public var p99GPUNanoseconds: Int64 { MetricsSummary.p99(window) }

    /// Spec 4 §2 — "CPU encode under 2 ms": its p99 over the same window.
    public var cpuP99Nanoseconds: Int64 { MetricsSummary.p99(cpuWindow) }

    static func p99(_ values: [Int64]) -> Int64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(0.99 * Double(sorted.count)))]
    }

    public var p99Fraction: Double {
        tickNanoseconds > 0 ? Double(p99GPUNanoseconds) / Double(tickNanoseconds) : 0
    }
}
