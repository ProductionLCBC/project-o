// OEngine — Spec 4 §13, "The soak rig reads the same files": the black box
// read back into a run, and the run's report.

import Foundation

/// Spec 4 §13 — reads every `blackbox-*.jsonl` of a folder, oldest first,
/// into a `SoakRun` for the thresholds.
public enum BlackBoxReader {
    public static func load(folder: URL, tickNanoseconds: Int64, sdiOutputs: [Int], displayOutputs: [Int]) throws -> SoakRun {
        var run = SoakRun(tickNanoseconds: tickNanoseconds, sdiOutputs: sdiOutputs, displayOutputs: displayOutputs)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("blackbox-") && $0.hasSuffix(".jsonl") }
            .sorted()
        for name in names {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                add(line: String(line), to: &run)
            }
        }
        return run
    }

    /// One line, as `BlackBox.line(for:)` wrote it. Lines that do not parse are skipped.
    public static func add(line: String, to run: inout SoakRun) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = object["kind"] as? String else { return }
        switch kind {
        case "tick":
            var record = TickRecord()
            record.frame = int64(object["frame"])
            record.masterTimeNs = int64(object["masterTimeNs"])
            record.cpuEncodeNs = int64(object["cpuEncodeNs"])
            record.gpuChannelNs = int64(object["gpuChannelNs"])
            record.gpuStackNs = int64(object["gpuStackNs"])
            record.gpuSinkNs = int64(object["gpuSinkNs"])
            record.channelPasses = Int32(clamping: int64(object["channelPasses"]))
            record.stackPasses = Int32(clamping: int64(object["stackPasses"]))
            record.auxSkipped = Int32(clamping: int64(object["auxSkipped"]))
            record.textLate = Int32(clamping: int64(object["textLate"]))
            record.planReused = object["planReused"] as? Bool ?? false
            record.gpuFailed = object["gpuFailed"] as? Bool ?? false
            for channel in object["videoRepeat"] as? [Int] ?? [] { record.markRepeat(channel: channel) }
            for (index, depth) in (object["queueDepths"] as? [Int] ?? []).enumerated() { record.setQueueDepth(depth, instance: index) }
            run.add(record)
        case "present":
            let completion = (object["completion"] as? String).flatMap(SinkCompletion.init(rawValue:))
            run.add(PresentRecord(output: Int(int64(object["output"])), frame: int64(object["frame"]),
                                  rePresented: object["rePresented"] as? Bool ?? false, latencyNs: int64(object["latencyNs"]),
                                  completion: completion, dropsSinceStart: int64(object["dropsSinceStart"])))
        case "minute":
            run.add(MinuteRecord(minute: Int(int64(object["minute"])), memoryBytes: int64(object["memoryBytes"]),
                                 decoderSessions: Int(int64(object["decoderSessions"])),
                                 textCacheHitRate: (object["textCacheHitRate"] as? NSNumber)?.doubleValue ?? 1,
                                 audioUnderruns: Int(int64(object["audioUnderruns"])),
                                 watchdogEvents: Int(int64(object["watchdogEvents"])),
                                 watchdogRecoveries: Int(int64(object["watchdogRecoveries"]))))
        default:
            break
        }
    }

    static func int64(_ value: Any?) -> Int64 {
        (value as? NSNumber)?.int64Value ?? 0
    }

    /// Spec 4 §13 and §15 — the run against every threshold, as text: one line
    /// per number the criteria name, then the verdict.
    public static func report(run: SoakRun, failures: [SoakFailure]) -> String {
        var lines: [String] = []
        let seconds = Double(run.durationNs) / 1e9
        lines.append("ticks \(run.ticks.count) over \(String(format: "%.0f", seconds)) s at \(String(format: "%.3f", Double(run.tickNanoseconds) / 1e6)) ms per tick")
        if !run.ticks.isEmpty {
            let gpu = run.ticks.map(\.gpuTotalNs).sorted()
            let p99 = gpu[min(gpu.count - 1, Int(0.99 * Double(gpu.count)))]
            let cpu = run.ticks.map(\.cpuEncodeNs).sorted()
            let cpuP99 = cpu[min(cpu.count - 1, Int(0.99 * Double(cpu.count)))]
            lines.append("GPU p99 \(String(format: "%.2f", Double(p99) / 1e6)) ms (budget \(String(format: "%.2f", Double(run.tickNanoseconds / 2) / 1e6)) ms); CPU encode p99 \(String(format: "%.2f", Double(cpuP99) / 1e6)) ms")
            lines.append("plan reused \(run.ticks.filter(\.planReused).count), video repeats \(run.ticks.reduce(0) { $0 + $1.videoRepeat.count }), text late \(run.ticks.reduce(0) { $0 + Int($1.textLate) }), aux skipped \(run.ticks.reduce(0) { $0 + Int($1.auxSkipped) }), GPU failures \(run.ticks.filter(\.gpuFailed).count)")
        }
        for output in (run.sdiOutputs.union(run.displayOutputs)).sorted() {
            let presents = run.presents.filter { $0.output == output }
            let kind = run.sdiOutputs.contains(output) ? "SDI" : "display"
            let dropped = presents.filter { $0.completion == .dropped }.count
            let late = presents.filter { $0.completion == .displayedLate }.count
            lines.append("output \(output) (\(kind)): presented \(presents.count), re-presented \(presents.filter(\.rePresented).count), dropped \(dropped), displayed late \(late)")
        }
        if let last = run.minutes.last {
            let underruns = run.minutes.reduce(0) { $0 + $1.audioUnderruns }
            let recoveries = run.minutes.reduce(0) { $0 + $1.watchdogRecoveries }
            let events = run.minutes.reduce(0) { $0 + $1.watchdogEvents }
            lines.append("minutes \(run.minutes.count): memory \(last.memoryBytes / 1_048_576) MB at the end, audio underruns \(underruns), watchdog events \(events), recoveries \(recoveries), decoder sessions \(last.decoderSessions), text cache hit rate \(String(format: "%.3f", last.textCacheHitRate))")
            let settled = run.minutes.filter { $0.minute >= 10 }
            if let baseline = settled.first?.memoryBytes, let peak = settled.map(\.memoryBytes).max() {
                lines.append("memory after minute 10: baseline \(baseline / 1_048_576) MB, peak \(peak / 1_048_576) MB (\(String(format: "%+.1f", (Double(peak) / Double(max(1, baseline)) - 1) * 100))%)")
            }
        }
        if failures.isEmpty {
            lines.append("PASS: every Spec 4 §13 threshold held")
        } else {
            lines.append("FAIL:")
            for failure in failures { lines.append("  - \(describe(failure))") }
        }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ failure: SoakFailure) -> String {
        switch failure {
        case .sdiDroppedOrLate(let output, let count): return "SDI output \(output): \(count) dropped or displayed late"
        case .displayRePresents(let output, let count, let allowed): return "display output \(output): \(count) re-presents, \(allowed) allowed"
        case .gpuP99OverBudget(let p99, let budget): return "GPU p99 \(String(format: "%.2f", Double(p99) / 1e6)) ms over the \(String(format: "%.2f", Double(budget) / 1e6)) ms budget"
        case .textLateAfterFirstMinute(let count): return "text late \(count) times after the first minute"
        case .audioUnderruns(let count): return "audio underruns \(count)"
        case .memoryNotFlat(let baseline, let peak): return "memory grew from \(baseline / 1_048_576) MB to \(peak / 1_048_576) MB after minute 10"
        case .watchdogRecoveries(let count): return "watchdog recoveries \(count)"
        }
    }
}
