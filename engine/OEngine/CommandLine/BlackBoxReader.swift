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
            // Spec 4 §13 — the breakdown keys are missing from files written before 2026-11-03 and read as zero.
            var byDevice: [String: Int] = [:]
            for (device, count) in object["audioUnderrunsByDevice"] as? [String: Any] ?? [:] { byDevice[device] = Int(int64(count)) }
            var record = MinuteRecord(minute: Int(int64(object["minute"])), memoryBytes: int64(object["memoryBytes"]),
                                 decoderSessions: Int(int64(object["decoderSessions"])),
                                 textCacheHitRate: (object["textCacheHitRate"] as? NSNumber)?.doubleValue ?? 1,
                                 audioUnderruns: Int(int64(object["audioUnderruns"])),
                                 watchdogEvents: Int(int64(object["watchdogEvents"])),
                                 watchdogRecoveries: Int(int64(object["watchdogRecoveries"])),
                                 footprintBytes: int64(object["footprintBytes"]),
                                 graphicsFootprintBytes: int64(object["graphicsFootprintBytes"]),
                                 heapLiveBytes: int64(object["heapLiveBytes"]), heapAllocatedBytes: int64(object["heapAllocatedBytes"]),
                                 purgeableLiveBytes: int64(object["purgeableLiveBytes"]), textureBytes: int64(object["textureBytes"]),
                                 decoderPoolBytes: int64(object["decoderPoolBytes"]), textCacheBytes: int64(object["textCacheBytes"]),
                                 readbackBytes: int64(object["readbackBytes"]),
                                 thermalState: (object["thermalState"] as? String).flatMap(ThermalLevel.init(rawValue:)) ?? .unknown,
                                 memoryPressure: (object["memoryPressure"] as? String).flatMap(MemoryPressureLevel.init(rawValue:)) ?? .unknown,
                                 thumbnailCacheHitRate: (object["thumbnailCacheHitRate"] as? NSNumber)?.doubleValue ?? 1)
            record.audioUnderrunsByDevice = byDevice
            run.add(record)
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
            // Spec 4 §13 — "present latency (tick to vsync or to scheduled slot)", over the frames that were presented, not re-presented.
            let latencies = presents.filter { !$0.rePresented && $0.completion != .dropped && $0.completion != .flushed }.map(\.latencyNs).sorted()
            var latency = ""
            if !latencies.isEmpty {
                let p50 = latencies[min(latencies.count - 1, latencies.count / 2)]
                let p99 = latencies[min(latencies.count - 1, Int(0.99 * Double(latencies.count)))]
                latency = ", present latency p50 \(String(format: "%.2f", Double(p50) / 1e6)) ms, p99 \(String(format: "%.2f", Double(p99) / 1e6)) ms"
            }
            lines.append("output \(output) (\(kind)): presented \(presents.count), re-presented \(presents.filter(\.rePresented).count), dropped \(dropped), displayed late \(late)\(latency)")
        }
        if let last = run.minutes.last {
            let underruns = run.minutes.reduce(0) { $0 + $1.audioUnderruns }
            let recoveries = run.minutes.reduce(0) { $0 + $1.watchdogRecoveries }
            let events = run.minutes.reduce(0) { $0 + $1.watchdogEvents }
            lines.append("minutes \(run.minutes.count): memory \(last.memoryBytes / 1_048_576) MB resident at the end, audio underruns \(underruns), watchdog events \(events), recoveries \(recoveries), decoder sessions \(last.decoderSessions), text cache hit rate \(String(format: "%.3f", last.textCacheHitRate)), thumbnail cache hit rate \(String(format: "%.3f", last.thumbnailCacheHitRate))")
            // Spec 4 §12 — the notes that explain a rising GPU time or a shrunk cache.
            let hot = run.minutes.filter { $0.thermalState != .nominal && $0.thermalState != .unknown }.count
            let pressed = run.minutes.filter { $0.memoryPressure != .normal && $0.memoryPressure != .unknown }.count
            if hot > 0 || pressed > 0 {
                lines.append("notes: thermal state above nominal in \(hot) minute\(hot == 1 ? "" : "s"); memory pressure above normal in \(pressed) minute\(pressed == 1 ? "" : "s")")
            }
            let settled = run.minutes.filter { $0.minute >= 10 }.sorted { $0.minute < $1.minute }
            if SoakThresholds.hasFootprint(settled) {
                // Spec 4 §13 as corrected on 2026-11-03: the footprint less its graphics-tagged part and the heap's live bytes, as sliding medians.
                let window = SoakThresholds.medianWindowMinutes
                if let medians = SoakThresholds.slidingMedians(settled.map(\.judgedFootprintBytes), window: window) {
                    lines.append("footprint less graphics after minute 10 (\(window)-minute medians): baseline \(mb(medians.baseline)) MB, highest \(mb(medians.peak)) MB (\(percent(medians.peak, of: medians.baseline)))")
                }
                if let medians = SoakThresholds.slidingMedians(settled.map(\.heapLiveBytes), window: window) {
                    lines.append("heap live after minute 10 (\(window)-minute medians): baseline \(mb(medians.baseline)) MB, highest \(mb(medians.peak)) MB (\(percent(medians.peak, of: medians.baseline)))")
                }
                if let first = settled.first, let end = settled.last {
                    let parts: [(name: String, start: Int64, end: Int64)] = [
                        ("graphics", first.graphicsFootprintBytes, end.graphicsFootprintBytes),
                        ("heap live", first.heapLiveBytes, end.heapLiveBytes),
                        ("heap allocated", first.heapAllocatedBytes, end.heapAllocatedBytes),
                        ("purgeable", first.purgeableLiveBytes, end.purgeableLiveBytes),
                        ("textures", first.textureBytes, end.textureBytes),
                        ("decoder pools", first.decoderPoolBytes, end.decoderPoolBytes),
                        ("text cache", first.textCacheBytes, end.textCacheBytes),
                        ("readback", first.readbackBytes, end.readbackBytes),
                    ]
                    var line = "parts, minute 10 to minute \(end.minute): footprint \(mb(first.footprintBytes)) to \(mb(end.footprintBytes)) MB, "
                    line += parts.map { "\($0.name) \(mb($0.start)) to \(mb($0.end)) MB" }.joined(separator: ", ")
                    if let grower = parts.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }), grower.end > grower.start {
                        line += "; largest grower: \(grower.name) (+\(mb(grower.end - grower.start)) MB)"
                    }
                    lines.append(line)
                }
            } else if let baseline = settled.first?.memoryBytes, let peak = settled.map(\.memoryBytes).max() {
                lines.append("memory after minute 10 (resident size; this record has no footprint): baseline \(mb(baseline)) MB, peak \(mb(peak)) MB (\(percent(peak, of: baseline)))")
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
        let window = SoakThresholds.medianWindowMinutes
        switch failure {
        case .sdiDroppedOrLate(let output, let count): return "SDI output \(output): \(count) dropped or displayed late"
        case .displayRePresents(let output, let count, let allowed): return "display output \(output): \(count) re-presents, \(allowed) allowed"
        case .gpuP99OverBudget(let p99, let budget): return "GPU p99 \(String(format: "%.2f", Double(p99) / 1e6)) ms over the \(String(format: "%.2f", Double(budget) / 1e6)) ms budget"
        case .textLateAfterFirstMinute(let count): return "text late \(count) times after the first minute"
        case .audioUnderruns(let count): return "audio underruns \(count)"
        case .memoryNotFlat(let baseline, let peak): return "memory (resident size) grew from \(mb(baseline)) MB to \(mb(peak)) MB after minute 10"
        case .footprintNotFlat(let baseline, let peak): return "footprint less graphics grew from \(mb(baseline)) MB to \(mb(peak)) MB after minute 10 (\(window)-minute medians)"
        case .heapNotFlat(let baseline, let peak): return "heap live bytes grew from \(mb(baseline)) MB to \(mb(peak)) MB after minute 10 (\(window)-minute medians)"
        case .watchdogRecoveries(let count): return "watchdog recoveries \(count)"
        }
    }

    static func mb(_ bytes: Int64) -> String { String(bytes / 1_048_576) }

    static func percent(_ value: Int64, of baseline: Int64) -> String {
        String(format: "%+.1f%%", (Double(value) / Double(max(1, baseline)) - 1) * 100)
    }
}
