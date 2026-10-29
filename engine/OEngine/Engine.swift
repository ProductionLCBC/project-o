// OEngine — Spec 4 §14, "the engine is constructed with its backend, its clock
// and its sinks injected".

import Foundation
import OCore
import Synchronization

/// The engine assembled from its parts. One `Engine` owns the control loop,
/// the render loop, the plan ring between them, the sinks and the metrics
/// ring. `runTick` is the synchronous path the headless harness drives;
/// `start()` runs the threaded path of Spec 4 §3: the render thread on the
/// master clock, the control thread building the next plan, the sinks on
/// their own cadence, the watchdog and the black box on utility threads.
public final class Engine: @unchecked Sendable {
    public let library: Library
    public let machine: Machine
    public let pacing: Pacing
    public let backend: any RenderBackend
    public let clock: any MasterClock
    public let fallbackClocks: [any MasterClock]
    public let sinks: [Int: any OutputSink]
    public let control: ControlLoop
    public let render: RenderLoop
    public let planRing = PlanRing()
    public let sources: SourceTable
    public let metrics: MetricsRing
    public let log: EngineLog
    public let watchdog: Watchdog
    public private(set) var scheduler: TickScheduler?
    public private(set) var recorder: BlackBoxRecorder?
    private var controlThread: Thread?
    private var readbackThread: Thread?
    private let controlSignal = DispatchSemaphore(value: 0)
    private let nextFrameToBuild = Atomic<Int64>(0)
    private let running = Atomic<Bool>(false)
    public private(set) var recoveries: Int64 = 0

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: any RenderBackend, clock: any MasterClock,
                fallbackClocks: [any MasterClock] = [], sinks: [any OutputSink], sourceFactory: any SourceFactory, posters: any PosterProvider,
                text: any TextProvider, variables: VariableProvider, log: EngineLog = EngineLog(category: "engine")) throws {
        self.library = library
        self.machine = machine
        self.pacing = try Pacing(machine: machine)
        self.backend = backend
        self.clock = clock
        self.fallbackClocks = fallbackClocks
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
            recoverIfNeeded()
            planRing.publish(control.build(for: time.tick, now: time.reference))
        }
        render.tick(time)
    }

    /// Spec 4 §12 — "Metal device lost or command buffer error ... rebuild
    /// pipelines and heaps; resume; log as a severe event." Detected by the
    /// render thread, performed here on the control side.
    func recoverIfNeeded() {
        guard render.takeGPUFailure() else { return }
        backend.rebuild()
        recoveries += 1
        watchdog.recordRecovery(.pipelinesRebuilt)
        log.severe("GPU work of a tick failed; sinks hold their last good frame; pipelines rebuilt")
    }

    // MARK: - The threaded engine (Spec 4 §3)

    /// Start the sinks, the control thread, the render thread on the master
    /// clock, the watchdog, the black box and the last-good-frame readback.
    public func start(blackBox: BlackBox? = nil, minuteSources: BlackBoxRecorder.MinuteSources = BlackBoxRecorder.MinuteSources()) {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        for output in sinks.keys.sorted() {
            do { try sinks[output]?.start() } catch { log.error("output \(output) did not start: \(error)") }
        }
        // The first plan, so the first tick has something to render.
        planRing.publish(control.build(for: 0, now: clock.now()))
        nextFrameToBuild.store(1, ordering: .releasing)

        let controlThread = Thread { [self] in
            while running.load(ordering: .relaxed) {
                controlSignal.wait()
                guard running.load(ordering: .relaxed) else { break }
                let frame = nextFrameToBuild.load(ordering: .acquiring)
                recoverIfNeeded()
                planRing.publish(control.build(for: frame, now: clock.now()))
            }
        }
        controlThread.name = "o.engine.control"
        controlThread.qualityOfService = .userInteractive
        self.controlThread = controlThread
        controlThread.start()

        let scheduler = TickScheduler(clocks: [clock] + fallbackClocks, rate: pacing.masterRate, log: log,
                                      onFallback: { [watchdog] name in watchdog.recordRecovery(.clockFallback(name)) }) { [self] time in
            render.tick(time)
            // Spec 4 §3 — "The control thread builds the frame plan for tick N+1 while the render thread encodes tick N".
            nextFrameToBuild.store(time.tick + 1, ordering: .releasing)
            controlSignal.signal()
        }
        self.scheduler = scheduler
        scheduler.start()

        watchdog.start { [self] in livenessReading(now: MonotonicClock.now()) }

        if let blackBox {
            let presentRings = sinks.values.compactMap { sink -> PresentRing? in
                (sink as? DisplaySink)?.presents ?? (sink as? DeckLinkSink)?.presents ?? (sink as? CapturingSink)?.presents
            }
            let recorder = BlackBoxRecorder(box: blackBox, ticks: metrics, presents: presentRings, tickNanoseconds: pacing.tickNanoseconds,
                                            sources: minuteSources, log: log)
            self.recorder = recorder
            recorder.start()
        }

        if let metal = backend as? MetalBackend {
            // Spec 4 §12 — the readback thread refreshes each output's CPU copy about once a second.
            let readback = Thread { [self] in
                while running.load(ordering: .relaxed) {
                    for (output, sink) in sinks {
                        if let frame = sink.ring.newest, metal.completion(of: frame.receipt) != nil {
                            metal.refreshLastGood(output: output, stack: frame.stack)
                        }
                    }
                    Thread.sleep(forTimeInterval: 1)
                }
            }
            readback.name = "o.engine.readback"
            readback.qualityOfService = .utility
            readbackThread = readback
            readback.start()
        }
        log.info("engine started: master \(clock.name) at \(pacing.masterRate.num)/\(pacing.masterRate.den), outputs \(sinks.keys.sorted())")
    }

    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        scheduler?.stop()
        controlSignal.signal()
        watchdog.stop()
        recorder?.stop()
        for sink in sinks.values { sink.stop() }
        controlThread = nil
        readbackThread = nil
        log.info("engine stopped")
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

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
        // Spec 4 §12 — a paused or unavailable sink is not expected to present.
        var presenting: [Int: MonotonicTime] = [:]
        for (output, sink) in sinks {
            if let deckLink = sink as? DeckLinkSink, deckLink.currentPhase != .running { continue }
            if let display = sink as? DisplaySink, display.currentState.phase != .running { continue }
            presenting[output] = sink.lastPresent
        }
        return LivenessReading(now: now, tickNanoseconds: pacing.tickNanoseconds, lastPlanConsumed: render.lastConsumed,
                               lastPlanBuilt: control.lastBuilt, sinkLastPresent: presenting, queues: queues)
    }
}
