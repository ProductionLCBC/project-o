// OEngine — Spec 4 §12, the watchdog.

import Foundation
import Synchronization

/// The state of one queue or ring at the moment of a finding: "the
/// information a Monday postmortem needs".
public struct QueueReading: Equatable, Sendable {
    public var name: String
    public var depth: Int
    public var capacity: Int

    public init(name: String, depth: Int, capacity: Int) {
        self.name = name
        self.depth = depth
        self.capacity = capacity
    }
}

/// Spec 4 §12 — what the watchdog reads every 250 ms.
public struct LivenessReading: Sendable {
    public var now: MonotonicTime
    public var tickNanoseconds: Int64
    public var lastPlanConsumed: MonotonicTime
    public var lastPlanBuilt: MonotonicTime
    public var sinkLastPresent: [Int: MonotonicTime]
    public var queues: [QueueReading]

    public init(now: MonotonicTime, tickNanoseconds: Int64, lastPlanConsumed: MonotonicTime, lastPlanBuilt: MonotonicTime,
                sinkLastPresent: [Int: MonotonicTime], queues: [QueueReading]) {
        self.now = now
        self.tickNanoseconds = tickNanoseconds
        self.lastPlanConsumed = lastPlanConsumed
        self.lastPlanBuilt = lastPlanBuilt
        self.sinkLastPresent = sinkLastPresent
        self.queues = queues
    }
}

/// Spec 4 §12 — the findings of one check.
public enum WatchdogFinding: Equatable, Sendable {
    /// "the render thread consumed a plan within the last tick" failed: counts `tickMissed`.
    case renderThreadMissedTick(sinceNs: Int64, queues: [QueueReading])
    /// "each active sink presented or scheduled within the last two frame intervals" failed.
    case sinkStalled(output: Int, sinceNs: Int64, queues: [QueueReading])
    /// "Control thread stalls: No new plan for two ticks ... watchdog logs after 500 ms".
    case controlThreadStalled(sinceNs: Int64)
}

/// Spec 4 §12 — the recoveries other threads perform; the soak rig wants zero.
public enum WatchdogRecovery: Equatable, Sendable {
    case sinkRestarted(output: Int)
    case decoderRecreated(channel: Int)
    case pipelinesRebuilt
    case clockFallback(String)
}

/// Spec 4 §12 — "A utility thread checks every 250 ms that each active sink
/// presented or scheduled within the last two frame intervals and that the
/// render thread consumed a plan within the last tick; failures are logged
/// with the state of every queue and ring at that moment". The check is a
/// pure function of a reading; the thread is a loop around it.
public final class Watchdog: @unchecked Sendable {
    public static let intervalNs: Int64 = 250_000_000
    public static let controlStallNs: Int64 = 500_000_000

    private let log: EngineLog
    private let eventCount = Atomic<Int>(0)
    private let missedCount = Atomic<Int>(0)
    private let recoveryCount = Atomic<Int>(0)
    private var thread: Thread?
    private let running = Atomic<Bool>(false)

    public init(log: EngineLog) {
        self.log = log
    }

    public static func check(_ r: LivenessReading) -> [WatchdogFinding] {
        var findings: [WatchdogFinding] = []
        let sinceRender = r.now - r.lastPlanConsumed
        if sinceRender > r.tickNanoseconds + r.tickNanoseconds / 2 {
            findings.append(.renderThreadMissedTick(sinceNs: sinceRender, queues: r.queues))
        }
        let sinceBuild = r.now - r.lastPlanBuilt
        if sinceBuild > controlStallNs {
            findings.append(.controlThreadStalled(sinceNs: sinceBuild))
        }
        for output in r.sinkLastPresent.keys.sorted() {
            guard let last = r.sinkLastPresent[output] else { continue }
            let since = r.now - last
            if since > 2 * r.tickNanoseconds {
                findings.append(.sinkStalled(output: output, sinceNs: since, queues: r.queues))
            }
        }
        return findings
    }

    /// Count and log findings.
    public func record(_ findings: [WatchdogFinding]) {
        for finding in findings {
            eventCount.add(1, ordering: .relaxed)
            switch finding {
            case .renderThreadMissedTick(let since, let queues):
                missedCount.add(1, ordering: .relaxed)
                log.error("watchdog: render thread consumed no plan for \(since / 1_000_000) ms; queues \(Watchdog.describe(queues))")
            case .sinkStalled(let output, let since, let queues):
                log.error("watchdog: output \(output) presented nothing for \(since / 1_000_000) ms; queues \(Watchdog.describe(queues))")
            case .controlThreadStalled(let since):
                log.error("watchdog: control thread built no plan for \(since / 1_000_000) ms")
            }
        }
    }

    public func recordRecovery(_ recovery: WatchdogRecovery) {
        recoveryCount.add(1, ordering: .relaxed)
        log.warning("watchdog: recovery \(recovery)")
    }

    static func describe(_ queues: [QueueReading]) -> String {
        queues.isEmpty ? "none" : queues.map { "\($0.name)=\($0.depth)/\($0.capacity)" }.joined(separator: " ")
    }

    public var events: Int { eventCount.load(ordering: .relaxed) }
    public var tickMissed: Int { missedCount.load(ordering: .relaxed) }
    public var recoveries: Int { recoveryCount.load(ordering: .relaxed) }

    /// Run the 250 ms loop on a utility thread until `stop()`.
    public func start(reading: @escaping @Sendable () -> LivenessReading) {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [weak self] in
            while let self, self.running.load(ordering: .relaxed) {
                self.record(Watchdog.check(reading()))
                Thread.sleep(forTimeInterval: Double(Watchdog.intervalNs) / 1_000_000_000)
            }
        }
        thread.name = "o.engine.watchdog"
        thread.qualityOfService = .utility
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        thread = nil
    }
}
