// OEngine — Spec 4 §4, "The tick, in order"; Spec 4 §3, the render thread.

import Foundation
import OCore
import Synchronization

/// Spec 4 §4 step 5 and §12 — the render thread's reading of the previous
/// tick's GPU time: skip aux passes when it left no headroom; after three
/// consecutive overruns, drop blur passes and mip generation until clear.
public struct PressureState: Equatable, Sendable {
    public var consecutiveOverruns = 0
    public var lastGPUNs: Int64 = 0
    public var skipAux = false
    public var droppingExtras = false

    public mutating func observe(_ completion: GPUCompletion, budgetNs: Int64) {
        lastGPUNs = completion.totalNs
        if completion.totalNs > budgetNs {
            consecutiveOverruns += 1
            skipAux = true
            if consecutiveOverruns >= 3 { droppingExtras = true }
        } else {
            consecutiveOverruns = 0
            skipAux = false
            droppingExtras = false
        }
    }
}

/// Spec 4 §4 — "The render thread performs no decision-making beyond step 2
/// and step 5. Everything else was decided when the plan was built." Spec 4
/// §3 — the render thread "takes no locks, allocates nothing, touches no file,
/// and reads state through a single pointer swap". Everything it touches here
/// was allocated at construction.
public final class RenderLoop: @unchecked Sendable {
    public let backend: any RenderBackend
    public let planRing: PlanRing
    public let sources: SourceTable
    public let metrics: MetricsRing
    public let pacing: Pacing
    let sinks: [Int: any OutputSink]
    let picks: PickedFrames

    public private(set) var lastPlan: FramePlan?
    public private(set) var pressure = PressureState()
    private var previousReceipt: EncodeReceipt?
    private var lastCompletion = GPUCompletion(channelNs: 0, stackNs: 0, sinkNs: 0)
    private let consumedTick = Atomic<Int64>(-1)
    private let consumedAt = Atomic<Int64>(0)
    private let ticksRun = Atomic<Int64>(0)
    private let repeats = Atomic<Int64>(0)

    public init(backend: any RenderBackend, planRing: PlanRing, sources: SourceTable, sinks: [Int: any OutputSink],
                metrics: MetricsRing, pacing: Pacing, maxChannelPasses: Int = 32) {
        self.backend = backend
        self.planRing = planRing
        self.sources = sources
        self.sinks = sinks
        self.metrics = metrics
        self.pacing = pacing
        picks = PickedFrames(capacity: maxChannelPasses * 2)
    }

    /// Spec 4 §12 — for the watchdog: when a plan was last consumed.
    public var lastConsumed: MonotonicTime { MonotonicTime(nanoseconds: consumedAt.load(ordering: .acquiring)) }
    public var lastConsumedTick: Int64 { consumedTick.load(ordering: .acquiring) }
    public var totalTicks: Int64 { ticksRun.load(ordering: .relaxed) }
    public var totalRepeats: Int64 { repeats.load(ordering: .relaxed) }

    /// Spec 4 §4 — one tick, in the spec's order.
    public func tick(_ time: TickTime) {
        let cpuStart = MonotonicClock.now()
        var record = TickRecord()
        record.frame = time.tick
        record.masterTimeNs = time.reference.nanoseconds

        // 1. Read the newest frame plan (pointer load). Spec 4 §3: with no
        //    new plan, reuse the previous with the frame counter advanced.
        var plan: FramePlan
        if let fresh = planRing.take() {
            plan = fresh
        } else if var previous = lastPlan {
            previous.frame = time.tick
            plan = previous
            record.planReused = true
        } else {
            plan = FramePlan(frame: time.tick)
        }

        // The previous tick's GPU time decides this tick's aux passes (step 5).
        if let receipt = previousReceipt, let completion = backend.completion(of: receipt) {
            lastCompletion = completion
            pressure.observe(completion, budgetNs: pacing.gpuBudgetNanoseconds)
        }

        // 2. Pick the decoded frame for this tick from each instance's queue.
        var instanceIndex = 0
        for (index, pass) in plan.channelPasses.enumerated() where index < picks.capacity / 2 {
            let incomingSlot = index * 2
            let outgoingSlot = index * 2 + 1
            picks.setResult(pick(pass.incoming.source, into: incomingSlot, record: &record, channel: pass.channel, instanceIndex: &instanceIndex), at: incomingSlot)
            if let outgoing = pass.outgoing {
                picks.setResult(pick(outgoing.source, into: outgoingSlot, record: &record, channel: pass.channel, instanceIndex: &instanceIndex), at: outgoingSlot)
            } else {
                picks.setResult(.nothing, at: outgoingSlot)
            }
        }

        // 3. Encode and commit; 5. aux only with headroom.
        let options = EncodeOptions(skipAux: pressure.skipAux, dropExtras: pressure.droppingExtras)
        let receipt = backend.encode(time, plan: plan, picks: picks, options: options)

        // 4. Publish each due output's frame into its ring; the sink presents on its own cadence.
        for sink in plan.sinkPasses {
            sinks[sink.output]?.ring.publish(CompletedFrame(tick: time.tick, stack: sink.stack, second: sink.second, mix: sink.mix,
                                                             destination: sink.destination, receipt: receipt))
        }

        // 6. Write the tick's metrics into the ring.
        let completion = backend.completion(of: receipt) ?? lastCompletion
        record.gpuChannelNs = completion.channelNs
        record.gpuStackNs = completion.stackNs
        record.gpuSinkNs = completion.sinkNs
        record.gpuFailed = completion.failed
        record.channelPasses = Int32(plan.channelPasses.count)
        record.stackPasses = Int32(plan.stackPasses.count)
        record.auxPasses = Int32(options.skipAux ? 0 : plan.auxPasses.count)
        record.auxSkipped = Int32(options.skipAux ? plan.auxPasses.count : 0)
        record.textLate = Int32(plan.stackPasses.reduce(0) { $0 + $1.boxes.filter { $0.binding.isText && $0.content.isEmpty && $0.transition == nil }.count })
        record.cpuEncodeNs = MonotonicClock.now() - cpuStart
        metrics.write(record)

        previousReceipt = receipt
        lastPlan = plan
        consumedTick.store(time.tick, ordering: .releasing)
        consumedAt.store(time.wake.nanoseconds, ordering: .releasing)
        ticksRun.add(1, ordering: .relaxed)
        picks.clearAll()
    }

    private func pick(_ source: SourceRef, into slot: Int, record: inout TickRecord, channel: Int, instanceIndex: inout Int) -> PickResult {
        guard case .instance(let handle, let mediaTime) = source, let instance = sources.source(handle) else { return .nothing }
        let result = instance.pick(mediaTimeMs: mediaTime, into: &picks[slot])
        if result == .repeated {
            record.markRepeat(channel: channel)
            repeats.add(1, ordering: .relaxed)
        }
        record.setQueueDepth(instance.queueDepth, instance: instanceIndex)
        instanceIndex += 1
        return result
    }
}
