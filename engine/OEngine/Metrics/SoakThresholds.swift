// OEngine — Spec 4 §13, the soak thresholds as a pure function.

import Foundation

/// Spec 4 §13 — "Soak thresholds (a build fails on any)": the reasons a run
/// fails, each with the number that failed it.
public enum SoakFailure: Equatable, Sendable {
    /// "zero `dropped` or `displayedLate` on SDI over the run"
    case sdiDroppedOrLate(output: Int, count: Int)
    /// "display re-presents at or below the expected drift rate for unlocked
    /// vsync (about one per five minutes per display)"
    case displayRePresents(output: Int, count: Int, allowed: Int)
    /// "p99 GPU time under 50% of the tick"
    case gpuP99OverBudget(p99Ns: Int64, budgetNs: Int64)
    /// "zero `textLate` after the first minute"
    case textLateAfterFirstMinute(count: Int)
    /// "zero audio underruns"
    case audioUnderruns(count: Int)
    /// "memory flat to within 5% after the first ten minutes"
    case memoryNotFlat(baselineBytes: Int64, peakBytes: Int64)
    /// "zero watchdog recoveries"
    case watchdogRecoveries(count: Int)
}

/// Spec 4 §13 — one run's records, as read back from the black box.
public struct SoakRun: Sendable {
    public let tickNanoseconds: Int64
    public let sdiOutputs: Set<Int>
    public let displayOutputs: Set<Int>
    public private(set) var ticks: [TickRecord] = []
    public private(set) var presents: [PresentRecord] = []
    public private(set) var minutes: [MinuteRecord] = []

    public init(tickNanoseconds: Int64, sdiOutputs: [Int], displayOutputs: [Int]) {
        self.tickNanoseconds = tickNanoseconds
        self.sdiOutputs = Set(sdiOutputs)
        self.displayOutputs = Set(displayOutputs)
    }

    public mutating func add(_ record: TickRecord) { ticks.append(record) }
    public mutating func add(_ record: PresentRecord) { presents.append(record) }
    public mutating func add(_ record: MinuteRecord) { minutes.append(record) }

    /// The run's length from the tick records' master time.
    public var durationNs: Int64 {
        guard let first = ticks.first?.masterTimeNs, let last = ticks.last?.masterTimeNs else { return 0 }
        return max(0, last - first)
    }
}

public enum SoakThresholds {
    public static let oneMinuteNs: Int64 = 60_000_000_000

    /// Spec 4 §13 — every threshold checked; an empty result is a pass.
    public static func evaluate(_ run: SoakRun) -> [SoakFailure] {
        var failures: [SoakFailure] = []

        // SDI: zero dropped or displayedLate.
        for output in run.sdiOutputs.sorted() {
            let bad = run.presents.filter { $0.output == output && ($0.completion == .dropped || $0.completion == .displayedLate) }.count
            if bad > 0 { failures.append(.sdiDroppedOrLate(output: output, count: bad)) }
        }

        // Displays: re-presents at or below one per five minutes.
        let minutes = Int(run.durationNs / oneMinuteNs)
        let allowed = max(1, minutes / 5)
        for output in run.displayOutputs.sorted() {
            let count = run.presents.filter { $0.output == output && $0.rePresented }.count
            if count > allowed { failures.append(.displayRePresents(output: output, count: count, allowed: allowed)) }
        }

        // GPU p99 under half the tick.
        if !run.ticks.isEmpty {
            let sorted = run.ticks.map(\.gpuTotalNs).sorted()
            let p99 = sorted[min(sorted.count - 1, Int(0.99 * Double(sorted.count)))]
            let budget = run.tickNanoseconds / 2
            if p99 >= budget { failures.append(.gpuP99OverBudget(p99Ns: p99, budgetNs: budget)) }
        }

        // textLate after the first minute.
        let start = run.ticks.first?.masterTimeNs ?? 0
        let late = run.ticks.filter { $0.masterTimeNs - start >= oneMinuteNs }.reduce(0) { $0 + Int($1.textLate) }
        if late > 0 { failures.append(.textLateAfterFirstMinute(count: late)) }

        // Audio underruns.
        let underruns = run.minutes.reduce(0) { $0 + $1.audioUnderruns }
        if underruns > 0 { failures.append(.audioUnderruns(count: underruns)) }

        // Memory flat within 5% after the first ten minutes.
        let settled = run.minutes.filter { $0.minute >= 10 }
        if let baseline = settled.first?.memoryBytes {
            let peak = settled.map(\.memoryBytes).max() ?? baseline
            if Double(peak) > Double(baseline) * 1.05 { failures.append(.memoryNotFlat(baselineBytes: baseline, peakBytes: peak)) }
        }

        // Watchdog recoveries.
        let recoveries = run.minutes.reduce(0) { $0 + $1.watchdogRecoveries }
        if recoveries > 0 { failures.append(.watchdogRecoveries(count: recoveries)) }

        return failures
    }
}
