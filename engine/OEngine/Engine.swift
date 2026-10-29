// OEngine — Spec 4 §14, "the engine is constructed with its backend, its clock
// and its sinks injected".

import Foundation
import OCore

/// The engine assembled from its parts. One `Engine` owns the control loop,
/// the render loop, the plan ring between them, the sinks and the metrics
/// ring. `runTick` is the synchronous path the headless harness drives; the
/// threaded path of the process wires the same two loops to a hardware clock.
public final class Engine: @unchecked Sendable {
    public let library: Library
    public let machine: Machine
    public let pacing: Pacing
    public let backend: any RenderBackend
    public let clock: any MasterClock
    public let sinks: [Int: any OutputSink]
    public let control: ControlLoop
    public let render: RenderLoop
    public let planRing = PlanRing()
    public let sources: SourceTable
    public let metrics: MetricsRing
    public let log: EngineLog
    public let watchdog: Watchdog

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: any RenderBackend, clock: any MasterClock,
                sinks: [any OutputSink], sourceFactory: any SourceFactory, posters: any PosterProvider, text: any TextProvider,
                variables: VariableProvider, log: EngineLog = EngineLog(category: "engine")) throws {
        self.library = library
        self.machine = machine
        self.pacing = try Pacing(machine: machine)
        self.backend = backend
        self.clock = clock
        self.log = log
        var byOutput: [Int: any OutputSink] = [:]
        for sink in sinks { byOutput[sink.output] = sink }
        self.sinks = byOutput
        let capacity = max(8, library.channels.count * 4)
        sources = SourceTable(capacity: capacity)
        metrics = MetricsRing(capacity: 4096)
        watchdog = Watchdog(log: log)
        control = ControlLoop(library: library, machine: machine, pacing: pacing, mediaRoot: mediaRoot, backend: backend,
                              sources: sources, sourceFactory: sourceFactory, posters: posters, text: text, variables: variables,
                              encodeKinds: byOutput.mapValues(\.encode), log: log)
        render = RenderLoop(backend: backend, planRing: planRing, sources: sources, sinks: byOutput, metrics: metrics, pacing: pacing,
                            maxChannelPasses: max(4, library.channels.count))
    }

    /// Spec 2 §8 — a group lands on the next tick boundary.
    public func enqueue(_ group: CommandGroup) {
        control.enqueue(group)
    }

    /// One tick, synchronously: the plan for this tick is built, published
    /// and rendered on the calling thread. With `buildPlan` false the control
    /// side is stalled on purpose and the render loop reuses its last plan
    /// (Spec 4 §3).
    public func runTick(_ time: TickTime, buildPlan: Bool = true) {
        if buildPlan {
            planRing.publish(control.build(for: time.tick, now: time.reference))
        }
        render.tick(time)
    }

    /// Spec 4 §12 — what the watchdog reads.
    public func livenessReading(now: MonotonicTime) -> LivenessReading {
        var queues: [QueueReading] = []
        for channel in library.channels {
            for handle in control.handles(onChannel: channel.number) {
                if let source = sources.source(handle) {
                    queues.append(QueueReading(name: "decode:\(channel.number)", depth: source.queueDepth, capacity: 4))
                }
            }
        }
        queues.append(QueueReading(name: "metrics", depth: Int(metrics.unread), capacity: metrics.capacity))
        return LivenessReading(now: now, tickNanoseconds: pacing.tickNanoseconds, lastPlanConsumed: render.lastConsumed,
                               lastPlanBuilt: control.lastBuilt, sinkLastPresent: sinks.mapValues(\.lastPresent), queues: queues)
    }
}
