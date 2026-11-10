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
    /// The roots as the edits so far left them (Spec 5 §2), on the control
    /// side; other threads read `control.publishedRoots`.
    public var library: Library { control.library }
    public var machine: Machine { control.machine }
    /// Spec 2 §9 — the engine's own publisher, until the API exists (Area 19).
    public let publisher = EnginePublisher()
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
    /// Spec 4 §12 — memory pressure shrinks the caches that registered here;
    /// the thermal state is logged on change. Both off the render thread.
    public let pressure: MemoryPressureMonitor
    public let thermal: ThermalMonitor
    public private(set) var scheduler: TickScheduler?
    public private(set) var recorder: BlackBoxRecorder?
    private var controlThread: Thread?
    private var readbackThread: Thread?
    private let controlSignal = DispatchSemaphore(value: 0)
    private let nextFrameToBuild = Atomic<Int64>(0)
    private let running = Atomic<Bool>(false)
    public private(set) var recoveries: Int64 = 0

    /// Spec 4 §11 — the audio system, one mix graph per device; nil runs silent.
    public let audio: AudioSystem?
    /// Called on the control thread after every plan is built: the process
    /// derives OSC feedback from what ran (Spec 2 §6).
    public var afterBuild: (@Sendable (ControlLoop) -> Void)?
    /// Spec 4 §10 — the thumbnail job, when the process or the harness built
    /// one over the Metal backend: it answers to memory pressure and waits on
    /// the render thread's pressure reading; the live list warms it.
    public var thumbnails: ThumbnailService? {
        didSet {
            guard let thumbnails else { return }
            pressure.add(thumbnails)
            let render = self.render
            thumbnails.auxBlocked = { render.isSkippingAux }
        }
    }
    private var lastLiveList: UUID?

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: any RenderBackend, clock: any MasterClock,
                fallbackClocks: [any MasterClock] = [], sinks: [any OutputSink], sourceFactory: any SourceFactory, posters: any PosterProvider,
                text: any TextProvider, variables: VariableProvider, audio: AudioSystem? = nil, log: EngineLog = EngineLog(category: "engine")) throws {
        self.audio = audio
        self.pacing = try Pacing(machine: machine)
        self.backend = backend
        self.clock = clock
        self.fallbackClocks = fallbackClocks
        self.log = log
        var byOutput: [Int: any OutputSink] = [:]
        for sink in sinks {
            byOutput[sink.output] = sink
            // Spec 4 §10 — a display sink refreshes one frame behind the master tick it can name.
            (sink as? DisplaySink)?.configure(masterRate: pacing.masterRate, ticksPerFrame: pacing.ticksPerFrame(output: sink.output))
            // Spec 4 §13 — a DeckLink sink whose clock is the master measures its latency on stream time.
            if let deckLink = sink as? DeckLinkSink, let sinkClock = deckLink.clock, sinkClock === (clock as AnyObject) {
                deckLink.referenceIsStreamTime = true
            }
        }
        self.sinks = byOutput
        let capacity = max(8, library.channels.count * 4)
        sources = SourceTable(capacity: capacity)
        metrics = MetricsRing(capacity: 4096)
        watchdog = Watchdog(log: log)
        // Spec 4 §12 — an audio device lost while running is a recovery the soak counts (Spec 4 §13).
        audio?.onRecovery = { [watchdog] recovery in watchdog.recordRecovery(recovery) }
        pressure = MemoryPressureMonitor(caches: [text as? ShrinkableCache].compactMap { $0 }, log: log)
        thermal = ThermalMonitor(log: log)
        control = ControlLoop(library: library, machine: machine, pacing: pacing, mediaRoot: mediaRoot, backend: backend,
                              sources: sources, sourceFactory: sourceFactory, posters: posters, text: text, variables: variables,
                              encodeKinds: byOutput.mapValues(\.encode), audio: audio, log: log)
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
            finishBuild()
        }
        render.tick(time)
    }

    /// The control side's work once a plan is published: OSC's feedback and
    /// replies, the `library` events of the build (Spec 5 §2), the thumbnail
    /// job given the edited library, the deferred releases, and the warm of a
    /// newly live list.
    func finishBuild() {
        afterBuild?(control)
        let events = control.lastLibraryEvents
        if !events.isEmpty {
            for event in events { publisher.publish(event.json) }
            thumbnails?.update(library: control.library, machine: control.machine)
        }
        sweepReleases()
        warmThumbnailsIfTheListChanged()
    }

    /// Spec 4 §10 and the Area 5 reading approved on 2026-11-03: "when the
    /// live list changes, the engine queues that list's cues for the
    /// thumbnail stack". Control side, after a build.
    func warmThumbnailsIfTheListChanged() {
        let uuid = control.model.state.pointer?.listUuid
        guard uuid != lastLiveList else { return }
        lastLiveList = uuid
        guard let thumbnails, let uuid, let list = library.list(uuid: uuid) ?? machine.localList(uuid: uuid) else { return }
        thumbnails.warm(list: list)
    }

    /// Spec 4 §10 — "those IOSurfaces are shared with it over a local Mach
    /// connection": the surface behind each stack's preview, by stack number.
    public var previewSurfaces: [Int: UInt32] {
        guard let metal = backend as? MetalBackend else { return [:] }
        return control.previewTargets.compactMapValues { metal.surfaceID(of: $0) }
    }

    /// Spec 4 §3 — "A released handle is not reused until the control side says
    /// the last plan that named it has been consumed": once a build, on the
    /// control side, the text cache and the resource table free what was
    /// released the ring's depth ago. The threaded engine did not do this before
    /// the first soak, so nothing deferred was ever freed.
    func sweepReleases() {
        let consumed = render.lastConsumedTick
        control.text.sweep(consumedTick: consumed)
        backend.resources.sweep(consumedTick: consumed)
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
        // Spec 4 §11 and §12 — every device opens, or its fallback, or silence; the system logs each.
        audio?.start()
        // The first plan, so the first tick has something to render; what it
        // ran gets its feedback and its errors like any other build.
        planRing.publish(control.build(for: 0, now: clock.now()))
        finishBuild()
        nextFrameToBuild.store(1, ordering: .releasing)

        let controlThread = Thread { [self] in
            while running.load(ordering: .relaxed) {
                controlSignal.wait()
                guard running.load(ordering: .relaxed) else { break }
                let frame = nextFrameToBuild.load(ordering: .acquiring)
                autoreleasepool {
                    recoverIfNeeded()
                    let started = MonotonicClock.now()
                    planRing.publish(control.build(for: frame, now: clock.now()))
                    finishBuild()
                    let took = MonotonicClock.now() - started
                    if took > pacing.tickNanoseconds {
                        // Spec 4 §3 — a build past the tick means the render thread reused a plan; say which one.
                        log.warning("control build for frame \(frame) took \(took / 1_000_000) ms")
                    }
                }
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
        // Spec 4 §12 — memory pressure and the thermal state, "detected elsewhere and never on the render thread".
        pressure.start()
        thermal.start()

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
                    // A pool per pass: the blit's command buffer and staging buffer are autoreleased
                    // (without this the first three-minute soak grew by 1.7 GB a minute).
                    autoreleasepool {
                        for (output, sink) in sinks {
                            if let frame = sink.ring.newest, metal.completion(of: frame.receipt) != nil {
                                metal.refreshLastGood(output: output, stack: frame.stack)
                            }
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
        pressure.stop()
        thermal.stop()
        recorder?.stop()
        audio?.stop()
        // Spec 5 §5 — an open typing run writes its line before the engine stops.
        control.commandLog.flush()
        for sink in sinks.values { sink.stop() }
        controlThread = nil
        readbackThread = nil
        log.info("engine stopped")
    }

    public var isRunning: Bool { running.load(ordering: .relaxed) }

    /// Spec 4 §12 — what the watchdog reads, on its own thread: atomics only,
    /// never the control thread's tables (a dictionary read during a build
    /// crashed the first three-minute soak).
    public func livenessReading(now: MonotonicTime) -> LivenessReading {
        var queues: [QueueReading] = []
        for (index, depth) in render.lastQueueDepths.enumerated() {
            queues.append(QueueReading(name: "decode:\(index + 1)", depth: depth, capacity: 4))
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
