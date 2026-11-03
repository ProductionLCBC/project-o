// OEngine — Spec 4 §13, "a utility thread drains the ring into the black box".

import Foundation
import Darwin
import Synchronization

/// Spec 4 §13 — the measurement thread: every 100 ms it drains the tick ring
/// and every sink's presentation ring into the black box and the live
/// summary; once a minute it writes the minute record (memory, decoder
/// sessions, cache hit rate, audio underruns, watchdog events).
public final class BlackBoxRecorder: @unchecked Sendable {
    /// Spec 4 §13 — what the engine tells the minute record; the process-level
    /// figures (`ProcessMemory`) the recorder reads itself. The byte sources
    /// are "the resource table's texture bytes, the decoder pools' bytes, the
    /// text cache's bytes and the readback buffers' bytes".
    public struct MinuteSources: Sendable {
        public var decoderSessions: @Sendable () -> Int
        public var textCacheHitRate: @Sendable () -> Double
        public var audioUnderruns: @Sendable () -> Int
        public var watchdogEvents: @Sendable () -> Int
        public var watchdogRecoveries: @Sendable () -> Int
        public var textureBytes: @Sendable () -> Int
        public var decoderPoolBytes: @Sendable () -> Int
        public var textCacheBytes: @Sendable () -> Int
        public var readbackBytes: @Sendable () -> Int
        /// Spec 4 §12 and §13 (Area 5) — the thumbnail cache's hit rate, the
        /// font substitutions, the thermal and memory-pressure states.
        public var thumbnailCacheHitRate: @Sendable () -> Double
        public var fontSubstitutions: @Sendable () -> Int
        public var thermalState: @Sendable () -> ThermalLevel
        public var memoryPressure: @Sendable () -> MemoryPressureLevel

        public init(decoderSessions: @escaping @Sendable () -> Int = { 0 }, textCacheHitRate: @escaping @Sendable () -> Double = { 1 },
                    audioUnderruns: @escaping @Sendable () -> Int = { 0 }, watchdogEvents: @escaping @Sendable () -> Int = { 0 },
                    watchdogRecoveries: @escaping @Sendable () -> Int = { 0 },
                    textureBytes: @escaping @Sendable () -> Int = { 0 }, decoderPoolBytes: @escaping @Sendable () -> Int = { 0 },
                    textCacheBytes: @escaping @Sendable () -> Int = { 0 }, readbackBytes: @escaping @Sendable () -> Int = { 0 },
                    thumbnailCacheHitRate: @escaping @Sendable () -> Double = { 1 }, fontSubstitutions: @escaping @Sendable () -> Int = { 0 },
                    thermalState: @escaping @Sendable () -> ThermalLevel = { .unknown },
                    memoryPressure: @escaping @Sendable () -> MemoryPressureLevel = { .unknown }) {
            self.decoderSessions = decoderSessions
            self.textCacheHitRate = textCacheHitRate
            self.audioUnderruns = audioUnderruns
            self.watchdogEvents = watchdogEvents
            self.watchdogRecoveries = watchdogRecoveries
            self.textureBytes = textureBytes
            self.decoderPoolBytes = decoderPoolBytes
            self.textCacheBytes = textCacheBytes
            self.readbackBytes = readbackBytes
            self.thumbnailCacheHitRate = thumbnailCacheHitRate
            self.fontSubstitutions = fontSubstitutions
            self.thermalState = thermalState
            self.memoryPressure = memoryPressure
        }
    }

    public let box: BlackBox
    private let ticks: MetricsRing
    private let presents: [PresentRing]
    private let sources: MinuteSources
    private let log: EngineLog
    private let lock = NSLock()
    private var summary: MetricsSummary
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private var minute = 0
    private var lastMinuteAt = MonotonicClock.now()
    private var lastUnderruns = 0
    private var lastEvents = 0
    private var lastRecoveries = 0
    private var lastMinute: MinuteRecord?
    private var totalUnderruns = 0

    public init(box: BlackBox, ticks: MetricsRing, presents: [PresentRing], tickNanoseconds: Int64, sources: MinuteSources, log: EngineLog) {
        self.box = box
        self.ticks = ticks
        self.presents = presents
        self.sources = sources
        self.log = log
        summary = MetricsSummary(tickNanoseconds: tickNanoseconds)
    }

    public var liveSummary: MetricsSummary {
        lock.lock()
        defer { lock.unlock() }
        return summary
    }

    /// One drain, synchronously (the thread's body and the harness's call).
    public func drain(now: Date = Date()) {
        var lines: [String] = []
        var records: [TickRecord] = []
        ticks.drain { records.append($0) }
        var presented: [PresentRecord] = []
        for ring in presents {
            ring.drain { presented.append($0) }
        }
        lock.lock()
        for record in records {
            summary.add(record)
            lines.append(BlackBox.line(for: record))
        }
        // Spec 4 §13 — "Per output, per presented frame" into the live summary too.
        for record in presented {
            summary.add(record)
            lines.append(BlackBox.line(for: record))
        }
        lock.unlock()
        for line in lines {
            do { try box.append(line: line, at: now) } catch { log.error("black box: \(error)") }
        }
        let since = MonotonicClock.now() - lastMinuteAt
        if since >= 60_000_000_000 {
            lastMinuteAt = MonotonicClock.now()
            writeMinute(now: now)
        }
    }

    /// Spec 4 §13 — the per-minute record.
    public func writeMinute(now: Date = Date()) {
        // Spec 4 §13 — a minute record carries what happened in that minute; the sources count since start.
        let underruns = sources.audioUnderruns()
        let events = sources.watchdogEvents()
        let recoveries = sources.watchdogRecoveries()
        // Spec 4 §13 — "memory in use, as the process footprint ... beside the resident size, and its parts".
        let memory = ProcessMemory.current()
        let record = MinuteRecord(minute: minute, memoryBytes: memory.residentBytes, decoderSessions: sources.decoderSessions(),
                                  textCacheHitRate: sources.textCacheHitRate(), audioUnderruns: max(0, underruns - lastUnderruns),
                                  watchdogEvents: max(0, events - lastEvents), watchdogRecoveries: max(0, recoveries - lastRecoveries),
                                  footprintBytes: memory.footprintBytes, graphicsFootprintBytes: memory.graphicsFootprintBytes,
                                  heapLiveBytes: memory.heapLiveBytes, heapAllocatedBytes: memory.heapAllocatedBytes,
                                  purgeableLiveBytes: memory.purgeableLiveBytes, textureBytes: Int64(sources.textureBytes()),
                                  decoderPoolBytes: Int64(sources.decoderPoolBytes()), textCacheBytes: Int64(sources.textCacheBytes()),
                                  readbackBytes: Int64(sources.readbackBytes()),
                                  // Spec 4 §12, §13 — the notes: the states in this minute and the thumbnail cache's hit rate.
                                  thermalState: sources.thermalState(), memoryPressure: sources.memoryPressure(),
                                  thumbnailCacheHitRate: sources.thumbnailCacheHitRate())
        lastUnderruns = underruns
        lastEvents = events
        lastRecoveries = recoveries
        minute += 1
        lock.lock()
        lastMinute = record
        totalUnderruns = underruns
        lock.unlock()
        do { try box.append(record, at: now) } catch { log.error("black box: \(error)") }
    }

    /// Spec 4 §13 — "a live summary the API exposes under the `metrics`
    /// topic": the snapshot of everything the recorder knows now.
    public func snapshot(uptimeSeconds: Int) -> MetricsSnapshot {
        lock.lock()
        let summary = self.summary
        let minute = lastMinute
        lock.unlock()
        var snapshot = MetricsSnapshot(tickNanoseconds: summary.tickNanoseconds)
        snapshot.uptimeSeconds = uptimeSeconds
        snapshot.ticks = summary.ticks
        snapshot.planReused = summary.planReused
        snapshot.textLate = summary.textLate
        snapshot.auxSkipped = summary.auxSkipped
        snapshot.videoRepeats = summary.videoRepeats
        snapshot.gpuFailures = summary.gpuFailures
        snapshot.gpuP99Ns = summary.p99GPUNanoseconds
        snapshot.cpuP99Ns = summary.cpuP99Nanoseconds
        snapshot.outputs = summary.outputs.map {
            MetricsSnapshot.OutputSnapshot(output: $0.output, presented: $0.presented, rePresented: $0.rePresented, dropped: $0.dropped,
                                           displayedLate: $0.displayedLate, latencyP50Ns: $0.latencyP50Ns, latencyP99Ns: $0.latencyP99Ns)
        }
        snapshot.memory = minute.map(MetricsSnapshot.MemorySnapshot.init)
        snapshot.decoderSessions = sources.decoderSessions()
        snapshot.textCacheHitRate = sources.textCacheHitRate()
        snapshot.thumbnailCacheHitRate = sources.thumbnailCacheHitRate()
        snapshot.fontSubstitutions = sources.fontSubstitutions()
        snapshot.thermalState = sources.thermalState()
        snapshot.memoryPressure = sources.memoryPressure()
        snapshot.watchdogEvents = sources.watchdogEvents()
        snapshot.watchdogRecoveries = sources.watchdogRecoveries()
        snapshot.audioUnderruns = sources.audioUnderruns()
        return snapshot
    }

    /// The process's resident size (`ProcessMemory.residentSize`).
    public static func residentMemoryBytes() -> Int64 { ProcessMemory.residentSize() }

    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in
            while running.load(ordering: .relaxed) {
                autoreleasepool { drain() }
                Thread.sleep(forTimeInterval: 0.1)
            }
            autoreleasepool { drain() }
        }
        thread.name = "o.engine.blackbox"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        thread = nil
    }
}
