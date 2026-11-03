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
    /// "memory flat to within 5% after the first ten minutes", on the resident
    /// size: "a record without the footprint is judged on resident size as
    /// before" (the black boxes of 2026-11-01 and 2026-11-02).
    case memoryNotFlat(baselineBytes: Int64, peakBytes: Int64)
    /// "judged on the footprint's sliding per-minute median ... against the
    /// median of the first window after minute ten", the footprint less its
    /// graphics-tagged part; the numbers are the two medians.
    case footprintNotFlat(baselineBytes: Int64, peakBytes: Int64)
    /// "and the same rule on the heap's live bytes, where a Swift-side leak
    /// shows first"
    case heapNotFlat(baselineBytes: Int64, peakBytes: Int64)
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

        // Memory flat within 5% after the first ten minutes (§13 as corrected on 2026-11-03).
        let settled = run.minutes.filter { $0.minute >= 10 }.sorted { $0.minute < $1.minute }
        if hasFootprint(settled) {
            // "judged on the footprint's sliding per-minute median ... against the median of the first window after minute ten"
            if let medians = slidingMedians(settled.map(\.judgedFootprintBytes), window: medianWindowMinutes),
               Double(medians.peak) > Double(medians.baseline) * 1.05 {
                failures.append(.footprintNotFlat(baselineBytes: medians.baseline, peakBytes: medians.peak))
            }
            // "and the same rule on the heap's live bytes"
            if settled.allSatisfy({ $0.heapLiveBytes > 0 }),
               let medians = slidingMedians(settled.map(\.heapLiveBytes), window: medianWindowMinutes),
               Double(medians.peak) > Double(medians.baseline) * 1.05 {
                failures.append(.heapNotFlat(baselineBytes: medians.baseline, peakBytes: medians.peak))
            }
        } else if let baseline = settled.first?.memoryBytes {
            // "a record without the footprint is judged on resident size as before"
            let peak = settled.map(\.memoryBytes).max() ?? baseline
            if Double(peak) > Double(baseline) * 1.05 { failures.append(.memoryNotFlat(baselineBytes: baseline, peakBytes: peak)) }
        }

        // Watchdog recoveries.
        let recoveries = run.minutes.reduce(0) { $0 + $1.watchdogRecoveries }
        if recoveries > 0 { failures.append(.watchdogRecoveries(count: recoveries)) }

        return failures
    }

    /// Spec 4 §13 — "a five-minute window until the first three-hour record
    /// with the breakdown sets it".
    public static let medianWindowMinutes = 5

    /// True when every settled minute carries the footprint, which the records
    /// written before 2026-11-03 do not.
    public static func hasFootprint(_ minutes: [MinuteRecord]) -> Bool {
        !minutes.isEmpty && minutes.allSatisfy { $0.footprintBytes > 0 }
    }

    /// The sliding per-minute medians of a series: the baseline is the median
    /// of the first window, the peak the highest median of any window. A
    /// series shorter than the window is one window, so it cannot fail.
    public static func slidingMedians(_ series: [Int64], window: Int) -> (baseline: Int64, peak: Int64)? {
        guard !series.isEmpty else { return nil }
        let width = max(1, min(window, series.count))
        var medians: [Int64] = []
        for end in (width - 1)..<series.count {
            medians.append(median(Array(series[(end - width + 1)...end])))
        }
        guard let baseline = medians.first, let peak = medians.max() else { return nil }
        return (baseline, peak)
    }

    static func median(_ values: [Int64]) -> Int64 {
        let sorted = values.sorted()
        let count = sorted.count
        return count % 2 == 1 ? sorted[count / 2] : (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }
}
