// OEngine — Spec 4 §14 and §16, the headless harness.

import Foundation
import OCore
import OFormats

/// Spec 4 §14 — "the engine is constructed with its backend, its clock and its
/// sinks injected, so tests can run it headless with a software clock and a
/// texture-capturing sink." The harness assembles an engine over the software
/// clock, one capturing sink per output, and either the fakes of `Fakes.swift`
/// or the real providers over a Metal backend, and drives it one tick at a
/// time on the test's thread.
public final class HeadlessEngine: @unchecked Sendable {
    public let clock = SoftwareClock()
    public let backend: any RenderBackend
    public let sourceFactory: any SourceFactory
    public let posters: any PosterProvider
    public let textProvider: any TextProvider
    public let variables: VariableProvider
    public let engine: Engine
    public let sinks: [Int: CapturingSink]
    private var stallTicks = 0
    private var ticksRun = 0

    public var control: ControlLoop { engine.control }
    public var renderLoop: RenderLoop { engine.render }
    public var log: EngineLog { engine.log }
    /// The backend as the recording one, when the harness was built with it.
    public var recording: RecordingBackend? { backend as? RecordingBackend }
    public var metal: MetalBackend? { backend as? MetalBackend }
    /// The fakes, when the harness was built with them.
    public var fakeSources: FakeSourceFactory? { sourceFactory as? FakeSourceFactory }
    public var fakePosters: FakePosterProvider? { posters as? FakePosterProvider }
    public var fakeText: FakeTextProvider? { textProvider as? FakeTextProvider }
    public var textCache: TextCache? { textProvider as? TextCache }

    /// A fixed wall clock so `[Time]` resolves the same in every run.
    public static let fixedWallClock: @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-26, 10:00:00 America/New_York (14:00 UTC)
    }

    /// The harness over the recording backend and the fakes: no GPU, no decoder.
    public convenience init(library: Library, machine: Machine, media: MediaFolders, backend: RecordingBackend = RecordingBackend(),
                            wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock) throws {
        try self.init(library: library, machine: machine, media: media, backend: backend, sourceFactory: FakeSourceFactory(),
                      posters: FakePosterProvider(backend: backend), text: FakeTextProvider(backend: backend), wallClock: wallClock)
    }

    /// The harness over a Metal backend with the real sources, posters and
    /// text cache (rasterizing synchronously), so a tick renders for real and
    /// the capturing sinks read the pixels back.
    public convenience init(library: Library, machine: Machine, media: MediaFolders, metal: MetalBackend,
                            wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock, thumbnailFolder: URL? = nil) throws {
        let log = EngineLog(category: "harness")
        // Spec 6 §4 — the bundled fonts, registered before the first raster as the engine process does.
        FontLibrary.shared.register(log: log)
        let renderer = CoreTextLineRasterizer(fallbackFont: machine.settings.fallbackFont)
        // Spec 4 §11 — one graph per device: the software factory hands out a pullable
        // device per key; an `sdiEmbedded` output's feed has no card here and consumes silently.
        let factory = SoftwareAudioDeviceFactory()
        let posters = ImagePosterProvider(backend: metal, media: media, log: log)
        try self.init(library: library, machine: machine, media: media, backend: metal,
                      sourceFactory: MediaSourceFactory(backend: metal, log: log), posters: posters,
                      text: TextCache(renderer: renderer, backend: metal, synchronous: true, log: log),
                      audio: AudioSystem(outputs: machine.audioOutputs, factory: factory, log: log), wallClock: wallClock, log: log)
        audioFactory = factory
        // Spec 4 §10 — the thumbnail job over the same posters and variables, its cache in a folder of the test's choosing.
        let folder = thumbnailFolder ?? FileManager.default.temporaryDirectory.appendingPathComponent("oengine-thumbnails-\(UUID().uuidString)")
        engine.thumbnails = try ThumbnailService(library: library, machine: machine, media: media, backend: metal, posters: posters,
                                                 variables: variables, cacheFolder: folder, log: log)
        engine.audio?.start()
        for sink in sinks.values {
            // The harness presents on the test's thread, so it can wait for the GPU here.
            sink.isComplete = { [metal] receipt in
                metal.waitForCompletion(of: receipt)
                return metal.completion(of: receipt).map { !$0.failed } ?? false
            }
            sink.capture = { [metal] frame in
                metal.readbackCapture(output: sink.output)
            }
        }
    }

    public init(library: Library, machine: Machine, media: MediaFolders, backend: any RenderBackend, sourceFactory: any SourceFactory,
                posters: any PosterProvider, text: any TextProvider, audio: AudioSystem? = nil,
                wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock, log: EngineLog = EngineLog(category: "harness")) throws {
        self.backend = backend
        self.sourceFactory = sourceFactory
        self.posters = posters
        self.textProvider = text
        variables = VariableProvider(settings: machine.settings, wallClock: wallClock)
        var sinks: [Int: CapturingSink] = [:]
        for output in machine.outputs { sinks[output.number] = CapturingSink(output: output.number) }
        self.sinks = sinks
        engine = try Engine(library: library, machine: machine, media: media, backend: backend, clock: clock,
                            sinks: sinks.values.map { $0 }, sourceFactory: sourceFactory, posters: posters, text: text,
                            variables: variables, audio: audio, log: log)
        let backendRef = backend
        for sink in sinks.values {
            // Spec 4 §12 — a frame whose GPU work failed is never presented; the previous one holds.
            sink.isComplete = { receipt in backendRef.completion(of: receipt).map { !$0.failed } ?? false }
        }
        clock.start(rate: engine.pacing.masterRate) { [weak self] time in self?.handleTick(time) }
    }

    private func handleTick(_ time: TickTime) {
        fakeSources?.advance()
        let build = stallTicks == 0
        if !build { stallTicks -= 1 }
        engine.runTick(time, buildPlan: build)
        for sink in sinks.values { sink.present(now: time.wake) }
        ticksRun += 1
    }

    // MARK: - Driving

    /// Spec 2 §8 — a command in its text form, landing on the next tick.
    /// Rejections are kept, never trapped on (CLAUDE.md). Spec 5 §3 — the
    /// harness, like the command bar, expands an edit's short forms against
    /// the library as it is now; `client` names the sender for typing (§5).
    @discardableResult
    public func send(_ text: String, source: SourceKind = .osc, client: String? = nil) -> Rejection? {
        let ids = MediaResolver.knownIds(library: engine.library.mediaIndex, machine: engine.machine.mediaLocal)
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: ids, library: engine.library, machine: engine.machine)) {
        case .success(let guarded):
            engine.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: source), commands: [guarded], client: client))
            return nil
        case .failure(let rejection):
            log.warning("harness: could not parse '\(text)': \(rejection.message)")
            return rejection
        }
    }

    /// Several commands in their text forms as one group (Spec 2 §8, Spec 5 §5).
    @discardableResult
    public func send(group texts: [String], source: SourceKind = .osc, client: String? = nil) -> Rejection? {
        let ids = MediaResolver.knownIds(library: engine.library.mediaIndex, machine: engine.machine.mediaLocal)
        var commands: [GuardedCommand] = []
        for text in texts {
            switch CommandText.parse(text, options: ParseOptions(mediaIDs: ids, library: engine.library, machine: engine.machine)) {
            case .success(let guarded): commands.append(guarded)
            case .failure(let rejection):
                log.warning("harness: could not parse '\(text)': \(rejection.message)")
                return rejection
            }
        }
        engine.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: source), commands: commands, client: client))
        return nil
    }

    public func send(_ group: CommandGroup) {
        engine.enqueue(group)
    }

    /// Spec 5 §2 — write edits to the roots on disk the library and machine
    /// were loaded from (`LoadedRoots`), as the engine process does.
    public func attachDocuments(_ roots: LoadedRoots) {
        control.attachDocuments(libraryRoot: roots.libraryRoot, machineRoot: roots.machineRoot,
                                librarySnapshot: roots.librarySnapshot, machineSnapshot: roots.machineSnapshot)
    }

    /// The writer's queue has done everything queued so far; the next tick
    /// reads what it reported.
    public func waitForWrites() {
        control.documents?.writer.waitUntilIdle()
    }

    /// Spec 5 §10 — what the folder watcher does when a file changes: a scan
    /// after everything queued, then a tick that reloads what it found.
    public func scanDisk() {
        control.requestScan()
        waitForWrites()
        tick()
    }

    /// One master tick.
    public func tick() {
        clock.advance()
    }

    public func tick(count: Int) {
        for _ in 0..<max(0, count) { clock.advance() }
    }

    /// Spec 4 §3 — the control thread stalls for the next `ticks` ticks.
    public func stallControl(ticks: Int) {
        stallTicks = max(0, ticks)
    }

    // MARK: - Reading

    /// The frame of the last tick run, or -1 before the first.
    public var frame: Int64 { clock.currentTick }
    public var state: ShowState { control.model.state }
    public var lastPlan: FramePlan? { renderLoop.lastPlan }
    public var lastExecuted: [ExecutedCommand] { control.lastExecuted }
    public var rejections: [Rejection] { control.rejections }
    public var lastRejected: [RejectedGroup] { control.lastRejected }

    /// The metrics written since the last drain.
    public func drainMetrics() -> [TickRecord] {
        var records: [TickRecord] = []
        engine.metrics.drain { records.append($0) }
        return records
    }

    public func posterHandle(for ref: String) -> TextureHandle {
        guard let resolved = MediaResolver.resolve(ref, library: engine.library, machine: engine.machine) else { return .none }
        return posters.poster(for: resolved.entry, tier: resolved.tier)
    }

    public func sources(onChannel channel: Int) -> [InstanceHandle] {
        control.handles(onChannel: channel)
    }

    public func livenessReading() -> LivenessReading {
        engine.livenessReading(now: clock.now())
    }

    /// The last frame the capturing sink of `output` read back (Metal harness).
    public func captured(output: Int) -> CapturedFrame? {
        sinks[output]?.lastCaptured
    }

    /// The software device factory of the Metal harness: every device by key,
    /// and the keys a test marks absent (Spec 4 §12).
    public private(set) var audioFactory: SoftwareAudioDeviceFactory?

    /// The software audio device of the first graph of the Metal harness, for pulling sound.
    public var audioDevice: SoftwareAudioDevice? { engine.audio?.device as? SoftwareAudioDevice }

    /// Pull `frames` frames of the device mix (Metal harness).
    @discardableResult
    public func pullAudio(frames: Int) -> [Float] {
        audioDevice?.pull(frames: frames) ?? []
    }
}
