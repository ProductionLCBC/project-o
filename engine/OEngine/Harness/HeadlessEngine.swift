// OEngine — Spec 4 §14 and §16, the headless harness.

import Foundation
import OCore

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
    public convenience init(library: Library, machine: Machine, mediaRoot: URL?, backend: RecordingBackend = RecordingBackend(),
                            wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock) throws {
        try self.init(library: library, machine: machine, mediaRoot: mediaRoot, backend: backend, sourceFactory: FakeSourceFactory(),
                      posters: FakePosterProvider(backend: backend), text: FakeTextProvider(backend: backend), wallClock: wallClock)
    }

    /// The harness over a Metal backend with the real sources, posters and
    /// text cache (rasterizing synchronously), so a tick renders for real and
    /// the capturing sinks read the pixels back.
    public convenience init(library: Library, machine: Machine, mediaRoot: URL, metal: MetalBackend,
                            wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock) throws {
        let log = EngineLog(category: "harness")
        let renderer = CoreTextLineRasterizer(fallbackFont: machine.settings.fallbackFont)
        try self.init(library: library, machine: machine, mediaRoot: mediaRoot, backend: metal,
                      sourceFactory: MediaSourceFactory(backend: metal, log: log), posters: ImagePosterProvider(backend: metal, mediaRoot: mediaRoot, log: log),
                      text: TextCache(renderer: renderer, backend: metal, synchronous: true, log: log), wallClock: wallClock)
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

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: any RenderBackend, sourceFactory: any SourceFactory,
                posters: any PosterProvider, text: any TextProvider,
                wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock) throws {
        self.backend = backend
        self.sourceFactory = sourceFactory
        self.posters = posters
        self.textProvider = text
        variables = VariableProvider(settings: machine.settings, wallClock: wallClock)
        var sinks: [Int: CapturingSink] = [:]
        for output in machine.outputs { sinks[output.number] = CapturingSink(output: output.number) }
        self.sinks = sinks
        engine = try Engine(library: library, machine: machine, mediaRoot: mediaRoot, backend: backend, clock: clock,
                            sinks: sinks.values.map { $0 }, sourceFactory: sourceFactory, posters: posters, text: text,
                            variables: variables, log: EngineLog(category: "harness"))
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
        textCache?.sweep(consumedTick: time.tick)
        ticksRun += 1
    }

    // MARK: - Driving

    /// Spec 2 §8 — a command in its text form, landing on the next tick.
    /// Rejections are kept, never trapped on (CLAUDE.md).
    @discardableResult
    public func send(_ text: String, source: SourceKind = .osc) -> Rejection? {
        let ids = Set(engine.library.mediaIndex.entries.map(\.id) + engine.machine.mediaLocal.entries.map(\.id))
        switch CommandText.parse(text, options: ParseOptions(mediaIDs: ids)) {
        case .success(let guarded):
            engine.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: source), commands: [guarded]))
            return nil
        case .failure(let rejection):
            log.warning("harness: could not parse '\(text)': \(rejection.message)")
            return rejection
        }
    }

    public func send(_ group: CommandGroup) {
        engine.enqueue(group)
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

    /// The metrics written since the last drain.
    public func drainMetrics() -> [TickRecord] {
        var records: [TickRecord] = []
        engine.metrics.drain { records.append($0) }
        return records
    }

    public func posterHandle(for ref: String) -> TextureHandle {
        guard let entry = MediaResolver.resolve(ref, library: engine.library, machine: engine.machine)?.entry else { return .none }
        return posters.poster(for: entry)
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
}
