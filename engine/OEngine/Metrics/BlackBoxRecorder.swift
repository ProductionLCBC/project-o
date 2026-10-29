// OEngine — Spec 4 §13, "a utility thread drains the ring into the black box".

import Foundation
import Darwin
import Synchronization

/// Spec 4 §13 — the measurement thread: every 100 ms it drains the tick ring
/// and every sink's presentation ring into the black box and the live
/// summary; once a minute it writes the minute record (memory, decoder
/// sessions, cache hit rate, audio underruns, watchdog events).
public final class BlackBoxRecorder: @unchecked Sendable {
    public struct MinuteSources: Sendable {
        public var decoderSessions: @Sendable () -> Int
        public var textCacheHitRate: @Sendable () -> Double
        public var audioUnderruns: @Sendable () -> Int
        public var watchdogEvents: @Sendable () -> Int
        public var watchdogRecoveries: @Sendable () -> Int

        public init(decoderSessions: @escaping @Sendable () -> Int = { 0 }, textCacheHitRate: @escaping @Sendable () -> Double = { 1 },
                    audioUnderruns: @escaping @Sendable () -> Int = { 0 }, watchdogEvents: @escaping @Sendable () -> Int = { 0 },
                    watchdogRecoveries: @escaping @Sendable () -> Int = { 0 }) {
            self.decoderSessions = decoderSessions
            self.textCacheHitRate = textCacheHitRate
            self.audioUnderruns = audioUnderruns
            self.watchdogEvents = watchdogEvents
            self.watchdogRecoveries = watchdogRecoveries
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
        lock.lock()
        for record in records {
            summary.add(record)
            lines.append(BlackBox.line(for: record))
        }
        lock.unlock()
        for ring in presents {
            ring.drain { lines.append(BlackBox.line(for: $0)) }
        }
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
        let underruns = sources.audioUnderruns()
        let record = MinuteRecord(minute: minute, memoryBytes: BlackBoxRecorder.residentMemoryBytes(), decoderSessions: sources.decoderSessions(),
                                  textCacheHitRate: sources.textCacheHitRate(), audioUnderruns: max(0, underruns - lastUnderruns),
                                  watchdogEvents: sources.watchdogEvents(), watchdogRecoveries: sources.watchdogRecoveries())
        lastUnderruns = underruns
        minute += 1
        do { try box.append(record, at: now) } catch { log.error("black box: \(error)") }
    }

    /// Spec 4 §13 — "memory in use": the process's resident size.
    public static func residentMemoryBytes() -> Int64 {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, rebound)
            }
        }
        return result == 0 ? Int64(usage.ri_resident_size) : 0
    }

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
