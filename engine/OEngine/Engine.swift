// OEngine — Spec 4 §14, "the engine is constructed with its backend, its clock
// and its sinks injected".

import Foundation
import IOSurface
import OCore
import OFormats
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
    /// Spec 2 §9 — the engine's own publisher: every area publishes its events and answers its queries here.
    public let publisher = EnginePublisher()
    /// Spec 10 §3 — the API's hub, which puts the publisher on the wire for every connection, in one order.
    public let api: ApiHub
    /// Spec 10 §3 — the topics this spec defines, published once a build on the control side.
    private let topics = ApiTopics()
    private let status = ApiStatus()
    /// Spec 9 §4 — what the launch made of the last state, for the `engine` topic (Spec 10 §3); nil for an engine that was only built.
    public internal(set) var launchReport: LaunchReport?
    /// The machine root this engine launched on: thumbnails and tiles are named "relative to the machine root" (Spec 10 §3).
    public internal(set) var machineRoot: URL?
    /// Spec 4 §13 — the live summary for the `metrics` topic; the process gives it, since the black box is its own.
    public var metricsSource: (@Sendable () -> MetricsSnapshot)?
    /// Spec 10 §3 — the devices this Mac has, for the `devices` query and topic.
    public var deviceLister: (any DeviceLister)?
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
    private let stopped = Atomic<Bool>(false)
    public private(set) var recoveries: Int64 = 0
    /// Spec 9 §2 — "Runs ... The engine's `start` note opens each run with
    /// the run's uuid, so a run and a `seq` name one line, whichever day's
    /// file it is in": this run's.
    public let run = UUID()
    /// Spec 9 §2 — the command log and the engine log on disk, once the
    /// engine has gone through its launch (`launch(_:)`); nil for an engine
    /// built in memory, whose lines stay in `control.commandLog` and `log`.
    public internal(set) var logs: LogWriter?
    /// Spec 9 §7 — what this engine's writers know of the disk, once it has launched.
    public internal(set) var diskStatus: DiskStatus?
    /// Spec 9 §2 — "each file is synced once a second": the threaded engine's pulse.
    private var logTimer: DispatchSourceTimer?

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
            // Spec 10 §3, the `thumbnails` topic — "A cue thumbnail written, with its stack, list, cue and file".
            thumbnails.onWritten = { [weak self] result, list in
                guard let self else { return }
                self.publisher.publish(ApiEvents.event("thumbnails", [
                    "stack": .number(Double(result.stack)), "list": .number(Double(list.number)),
                    "listUuid": .string(list.uuid.uuidString.lowercased()), "cue": .string(result.cue.uuidString.lowercased()),
                    "file": .string(ApiQueries.relative(result.url, to: self.machineRoot)),
                ], seq: self.control.commandLog.lastSeq))
            }
        }
    }
    /// Spec 10 §2 — "while any output presents it keeps the displays and the
    /// system from sleeping": told the outputs' states after every build.
    public var power: OutputPower?
    private var lastLiveList: UUID?
    private var lastLiveVersion: Int?
    /// Signalled by the control thread when it leaves its loop.
    private let controlDone = DispatchSemaphore(value: 0)

    public init(library: Library, machine: Machine, media: MediaFolders, backend: any RenderBackend, clock: any MasterClock,
                fallbackClocks: [any MasterClock] = [], sinks: [any OutputSink], sourceFactory: any SourceFactory, posters: any PosterProvider,
                text: any TextProvider, variables: VariableProvider, audio: AudioSystem? = nil, mediaCache: MediaCache = MediaCache(),
                log: EngineLog = EngineLog(category: "engine")) throws {
        self.audio = audio
        self.pacing = try Pacing(machine: machine)
        api = ApiHub(publisher: publisher, log: log)
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
        control = ControlLoop(library: library, machine: machine, pacing: pacing, media: media, backend: backend,
                              sources: sources, sourceFactory: sourceFactory, posters: posters, text: text, variables: variables,
                              encodeKinds: byOutput.mapValues(\.encode), audio: audio, mediaCache: mediaCache, log: log)
        render = RenderLoop(backend: backend, planRing: planRing, sources: sources, sinks: byOutput, metrics: metrics, pacing: pacing,
                            maxChannelPasses: max(4, library.channels.count))
        // Spec 4 §2 — "the wall clock is read only to stamp log lines": the engine's own, so its log's lines and
        // the command log's are stamped by one clock.
        log.setClock { variables.now() }
        answerMediaQueries()
        takeNotes()
        // Spec 9 §5 — "the engine sends an event when a client subscribes": both stacks start empty.
        publisher.publish(current: UndoHistory().event(seq: 0))
        // Spec 9 §7 — and the `saving` topic, "sent when a client subscribes and whenever a value changes".
        publisher.publish(current: SavingStatus().event(seq: 0))
        api.engine = self
    }

    /// Spec 9 §6, "Picking one" — the `versions` and `snapshots` queries,
    /// through the engine's own publisher until the API carries them (Area
    /// 19). They read files, on the asking thread, never the control thread.
    func answerSavingQueries(_ worker: SnapshotWorker) {
        let control = self.control
        publisher.answer("versions") { request in
            guard let number = request["list"]?.intValue else {
                return .failure(Rejection(reason: .badValue, message: "versions names its list as \"list\", by number"))
            }
            guard let list = control.publishedRoots.library.list(number: number) else {
                return .failure(Rejection(reason: .unknownObject, message: "list \(number) does not exist"))
            }
            return .success(["versions": .array(worker.versionListing(of: list.uuid, stamp: { control.variables.timestamp(at: $0) }))])
        }
        publisher.answer("snapshots") { _ in
            .success(["snapshots": .array(worker.snapshotListing())])
        }
    }

    /// Spec 9 §2 — the `note` request: "A client sends `{ "id": 31, "type":
    /// "note", "note": { … }, "text": "…" }`; the engine stamps `ts`, `seq`
    /// and the client's source, writes the line, and answers `ok` with the
    /// `seq`." An oversized note is refused with `badValue`; past ten a
    /// second from one client it "is answered `noop` and not written". Through
    /// the engine's own publisher until the API carries it (Area 19).
    private func takeNotes() {
        let control = self.control
        let clock = self.clock
        publisher.handle("note") { request, source, client in
            guard case .object(let note)? = request["note"], let text = request["text"]?.stringValue else {
                return .failure(Rejection(reason: .badValue, message: "a note carries its note as an object and its text as a string"))
            }
            switch control.commandLog.clientNote(note, text: text, source: source, client: client, now: clock.now().nanoseconds,
                                                 ts: control.variables.timestamp()) {
            case .written(let seq): return .success((result: "ok", fields: ["seq": .number(Double(seq))]))
            case .capped: return .success((result: "noop", fields: [:]))
            case .refused(let rejection): return .failure(rejection)
            }
        }
    }

    /// Spec 9 §2 — "a copy of each minute record (Spec 4 §13)" in the engine
    /// log, as the black box's recorder writes each one.
    public func recordMinute(_ record: MinuteRecord) {
        guard let logs else { return }
        let fields = (try? JSONValue.parse(BlackBox.line(for: record)))?.objectValue ?? [:]
        logs.engine(LogWriter.EngineRecord(at: control.variables.now(), kind: "minute", fields: fields))
    }

    /// Spec 8 §7 and Spec 10 §3 — the `mediaUse` and `media` queries,
    /// answered from what the last build published (Adam's answer of
    /// 2026-11-11, 4: Area 8 answers them through the engine's publisher,
    /// Area 19 puts them on the API).
    private func answerMediaQueries() {
        let control = self.control
        publisher.answer("mediaUse") { request in
            guard let id = request["media"]?.stringValue else {
                return .failure(Rejection(reason: .badValue, message: "mediaUse names its item as \"media\""))
            }
            let roots = control.publishedRoots
            guard MediaResolver.knownIds(library: roots.library.mediaIndex, machine: roots.machine.mediaLocal).contains(id) else {
                return .failure(Rejection(reason: .unknownObject, message: "\(id) isn't in either media index"))
            }
            return .success(MediaUse.of(id, library: roots.library, machine: roots.machine).fields)
        }
        publisher.answer("media") { _ in
            let roots = control.publishedRoots
            let published = control.publishedMedia
            let folder = control.mediaWorker?.tilesFolder
            let entries = MediaCatalog.entries(library: roots.library, machine: roots.machine, files: { published.files[$0] ?? .absent },
                                               tile: { entry in
                guard let name = MediaPosters.tileName(of: entry), published.tiles.contains(name), let folder else { return nil }
                return folder.appendingPathComponent(name).path
            })
            return .success(["media": .array(entries)])
        }
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
            api.buildWillStart()
            planRing.publish(control.build(for: time.tick, now: time.reference))
            finishBuild()
        }
        render.tick(time)
        // Spec 9 §2 — "each file is synced once a second", on the harness's engine time.
        logs?.pulse(now: time.reference)
    }

    /// The control side's work once a plan is published: OSC's feedback and
    /// replies, the `library` events of the build (Spec 5 §2), the thumbnail
    /// job given the edited library, the deferred releases, and the warm of a
    /// newly live list.
    func finishBuild() {
        // Spec 10 §3 — one order per connection: the results of the groups that ran, then the build's events, then
        // the answers to the requests this build took (at the end, below).
        api.deliverResults(control)
        afterBuild?(control)
        for event in control.lastLibraryEvents { publisher.publish(event.json) }
        // Spec 8 §7 — the `media` topic: jobs, the walk, and changes in missing state.
        for event in control.lastMediaEvents { publisher.publish(event) }
        // Spec 9 §5 — the `history` topic: "whenever either stack changes".
        if let history = control.lastHistoryEvent { publisher.publish(current: history) }
        // Spec 9 §7 — the `saving` topic: "whenever a value changes".
        if let saving = control.lastSavingEvent { publisher.publish(current: saving) }
        // Spec 7 §6 — "The `live` event is sent at the same moments" as the live feedback.
        if let live = control.lastLiveFeedback { publisher.publish(live.event) }
        // Spec 6 §8 — "The `timers` topic sends one event per timer on the same cadence" as `/o/timer/N`.
        for timer in control.lastTimerFeedback { publisher.publish(timer.event) }
        if control.lastRootsChanged || control.mediaFilesChanged || control.posterFilesChanged {
            thumbnails?.update(library: control.library, machine: control.machine, missing: control.missing, posters: control.posterFiles)
        }
        sweepReleases()
        warmThumbnailsIfTheListChanged()
        // Spec 10 §3 — the engine's values as this build left them: the topics' events are made from them now, and
        // the answers to the requests this build took are made from the same.
        let snapshot = ApiSnapshot(engine: self)
        topics.publish(snapshot, control: control, to: publisher)
        let now = clock.now()
        status.publish(engine: self, snapshot: snapshot, now: now)
        // Spec 10 §3 — the `preview` topic: "a JPEG of each stack the client names ..., twice a second".
        preview.publish(engine: self, snapshot: snapshot, now: now)
        power?.update(snapshot.standings)
        api.takeRequests(self, snapshot: snapshot)
    }

    /// Spec 10 §3 — the `preview` topic's own state: when it last sent.
    let preview = ApiPreview()

    /// Spec 10 §2 — whether the system is holding OSC sends back now, which the `engine` topic shows as the LAN
    /// waiting; the process sets it to its OSC server's.
    public var oscRefused: (@Sendable () -> Bool)?

    /// A test's own surfaces for the preview and picture textures; nil for the Metal backend's.
    public var surfaceSource: (@Sendable (TextureHandle) -> IOSurfaceRef?)?

    /// Spec 4 §10 — "backed by IOSurfaces": the surface behind a preview or picture texture.
    func surface(of handle: TextureHandle) -> IOSurfaceRef? {
        if let surfaceSource { return surfaceSource(handle) }
        return (backend as? MetalBackend)?.surface(of: handle)
    }

    /// Spec 10 §2 — the Mach channel, once it is open: the preview surfaces, the channel pictures and the meters.
    public private(set) var mach: MachChannel?

    /// Spec 10 §2 — "The engine registers a Mach service in the user's bootstrap namespace under the name `hello`
    /// gives": opens the Mach channel for this run. `surface` finds the IOSurface behind a preview or picture
    /// texture; it is the Metal backend's unless a test gives its own. While a client holds the channel the strip's
    /// pictures are planned (Spec 4 §2) and the render thread says which surface each frame went to.
    @discardableResult
    public func openMachChannel(service: any MachService = BootstrapMachService(), surface: (@Sendable (TextureHandle) -> IOSurfaceRef?)? = nil,
                                allows: @escaping @Sendable (uid_t) -> Bool = { $0 == geteuid() }) throws -> MachChannel {
        if let mach { return mach }
        let backend = self.backend
        if let surface { surfaceSource = surface }
        let find = surfaceSource ?? { handle in (backend as? MetalBackend)?.surface(of: handle) }
        let previews = control.previewSurfaces, pictures = control.pictureSurfaces
        @Sendable func sets(_ handles: [Int: [TextureHandle]]) -> [MachSurfaceSet] {
            handles.keys.sorted().compactMap { number in
                let surfaces = (handles[number] ?? []).compactMap(find)
                guard surfaces.count == FrameRing.depth, let first = surfaces.first else { return nil }
                return MachSurfaceSet(number: number, width: IOSurfaceGetWidth(first), height: IOSurfaceGetHeight(first), surfaces: surfaces)
            }
        }
        let audio = self.audio
        let control = self.control
        let render = self.render
        let source = MachChannel.Source(previews: { sets(previews) }, pictures: { sets(pictures) },
                                        finished: { receipt in backend.completion(of: receipt).map { !$0.failed } },
                                        meters: { audio?.takeMeters() ?? [] })
        let channel = MachChannel(service: service, name: MachServiceName.engine(run: run), notices: render.auxNotices, source: source, log: log,
                                  allows: allows, onClients: { count in
            control.picturesWanted.store(count > 0, ordering: .releasing)
            render.auxListening.store(count > 0, ordering: .releasing)
        })
        try channel.start()
        mach = channel
        return channel
    }

    /// Spec 10 §3, the `devices` topic — sent "On subscribe and when a screen, a card or an audio device comes or
    /// goes": the list is read again, off the caller's thread, and kept as the topic's current value.
    public func devicesChanged() {
        guard let deviceLister else { return }
        let publisher = self.publisher
        let control = self.control
        api.workers.async {
            publisher.publish(current: ApiEvents.event("devices", ApiQueries.devices(deviceLister), seq: control.commandLog.lastSeq))
        }
    }

    /// Spec 10 §3, the `outputs` topic — each output's state, by number:
    /// "`presenting`, `paused` while its screen or card is gone, `released`,
    /// or `absent` when its device isn't there". An output with no sink (a
    /// kind v1 doesn't present) is `absent`. Control side.
    public func outputStandings() -> [Int: OutputStanding] {
        var standings: [Int: OutputStanding] = [:]
        for output in control.machine.outputs { standings[output.number] = sinks[output.number]?.standing ?? .absent }
        return standings
    }

    /// Spec 4 §10 and the Area 5 reading approved on 2026-11-03: "when the
    /// live list changes, the engine queues that list's cues for the
    /// thumbnail stack". Control side, after a build. Spec 5 §2 — "The cue's
    /// thumbnail is redrawn because its library version changes": a write
    /// that raised the live list's version warms it again.
    func warmThumbnailsIfTheListChanged() {
        let uuid = control.model.state.pointer?.listUuid
        let list = uuid.flatMap { library.list(uuid: $0) ?? machine.localList(uuid: $0) }
        guard uuid != lastLiveList || list?.version != lastLiveVersion else { return }
        lastLiveList = uuid
        lastLiveVersion = list?.version
        guard let thumbnails, let list else { return }
        thumbnails.warm(list: list)
    }

    /// Spec 4 §10 — "those IOSurfaces are shared with it over a local Mach
    /// connection": the surfaces behind each stack's preview, by stack number,
    /// three each (Spec 10 §2).
    public var previewSurfaces: [Int: [UInt32]] {
        guard let metal = backend as? MetalBackend else { return [:] }
        return control.previewSurfaces.mapValues { $0.compactMap { metal.surfaceID(of: $0) } }
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
        // Spec 10 §2 — the surfaces are sent again "whenever they are made again, as after a GPU reset (Spec 4 §12)".
        mach?.resendSurfaces()
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
        // Spec 4 §11 and §12 — every device opens, or its fallback, or silence; the system logs each. On a thread of
        // its own: Core Audio can take seconds to open a device, and the first frame doesn't wait for it (Spec 4 §1,
        // "Every output presents a frame every refresh"; Adam's answer at Area 19's third stop). Until a device has
        // opened its outputs are silent, on a stand-in that keeps the channels' clocks moving.
        audio?.start(openingInBackground: true)
        // The first plan, so the first tick has something to render; what it
        // ran gets its feedback and its errors like any other build.
        api.buildWillStart()
        planRing.publish(control.build(for: 0, now: clock.now()))
        finishBuild()
        nextFrameToBuild.store(1, ordering: .releasing)

        let controlThread = Thread { [self] in
            defer { controlDone.signal() }
            while running.load(ordering: .relaxed) {
                controlSignal.wait()
                guard running.load(ordering: .relaxed) else { break }
                let frame = nextFrameToBuild.load(ordering: .acquiring)
                autoreleasepool {
                    recoverIfNeeded()
                    let started = MonotonicClock.now()
                    api.buildWillStart()
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
                                            sources: minuteSources, log: log, onMinute: { [weak self] record, _ in self?.recordMinute(record) })
            self.recorder = recorder
            recorder.start()
        }

        // Spec 9 §2 — "each file is synced once a second", whatever the control thread is doing.
        if let logs {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
            timer.setEventHandler { logs.pulse(now: MonotonicClock.now()) }
            timer.resume()
            logTimer = timer
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

    /// Spec 9 §4 and §7 — what a stop on request leaves: the documents the
    /// engine "still can't write", each by its root and its path in it, which
    /// "are named in its answer to the request that stopped it".
    public struct StopReport: Equatable, Sendable {
        public var unsaved: [String]

        public init(unsaved: [String] = []) {
            self.unsaved = unsaved
        }
    }

    /// Spec 9 §4 — "When the engine stops on request, such as the app's quit
    /// or the Mac shutting down": the control thread leaves its loop, every
    /// unwritten edit is written (one more try, §7), open typing runs write
    /// their lines, the `stop` note names what couldn't be written (§2), and
    /// the logs are synced. The threads and sinks then stop. The request that
    /// stops the engine (Area 19's `stop`) and a terminate signal both come
    /// here; a kill never does. Once: a second call does nothing.
    @discardableResult
    public func stop() -> StopReport {
        guard !stopped.exchange(true, ordering: .acquiringAndReleasing) else { return StopReport() }
        let threaded = running.exchange(false, ordering: .acquiringAndReleasing)
        var quiet = true
        if threaded {
            scheduler?.stop()
            controlSignal.signal()
            quiet = controlThread == nil || controlDone.wait(timeout: .now() + 2) == .success
        }
        var report = StopReport()
        // With the control thread out of its loop, its state is this thread's to use.
        if quiet {
            // Spec 9 §4 — "it runs the shutdown macro": one last build, the macro its first group (Spec 2 §5,
            // source `shutdown`), with whatever was still queued behind it.
            if let macro = control.machine.settings.shutdownMacro {
                control.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .shutdown), commands: [Command.macro(macro)]))
                api.buildWillStart()
                planRing.publish(control.build(for: control.model.frame + 1, now: clock.now()))
                finishBuild()
            }
            control.flushDocuments(now: clock.now())
            // Spec 9 §3 — a snapshot the worker has in hand is written whole before the engine goes.
            control.snapshots?.waitUntilIdle()
            // Spec 5 §5 — an open typing run writes its line before the engine stops.
            control.commandLog.flush()
            report.unsaved = control.unsavedDocuments
            control.note("stop", ["unsaved": .array(report.unsaved.map(JSONValue.string))],
                         text: report.unsaved.isEmpty ? "Engine stopped" : "Engine stopped with \(report.unsaved.count) document(s) unwritten")
            // Spec 9 §4 — "then writes the file at once with `clean: true`."
            control.endLastState(now: clock.now())
        } else {
            log.error("the control thread did not stop in time: the last edits and the stop note are not written")
        }
        if threaded {
            watchdog.stop()
            pressure.stop()
            thermal.stop()
            recorder?.stop()
            audio?.stop()
            for sink in sinks.values { sink.stop() }
            // Spec 10 §2 — nothing presents any more, so the displays and the system may sleep.
            power?.end()
            mach?.stop()
            controlThread = nil
            readbackThread = nil
        }
        logTimer?.cancel()
        logTimer = nil
        for path in report.unsaved { log.error("not written when the engine stopped: \(path)") }
        log.info("engine stopped")
        logs?.flush()
        return report
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
