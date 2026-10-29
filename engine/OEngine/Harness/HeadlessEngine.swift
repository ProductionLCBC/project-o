// OEngine — Spec 4 §14 and §16, the headless harness.

import Foundation
import OCore

/// Spec 4 §14 — "the engine is constructed with its backend, its clock and its
/// sinks injected, so tests can run it headless with a software clock and a
/// texture-capturing sink." The harness assembles an engine over the software
/// clock, one capturing sink per output, and the fakes of `Fakes.swift`, and
/// drives it one tick at a time on the test's thread.
public final class HeadlessEngine: @unchecked Sendable {
    public let clock = SoftwareClock()
    public let backend: any RenderBackend
    public let sourceFactory = FakeSourceFactory()
    public let posters: FakePosterProvider
    public let textProvider: FakeTextProvider
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

    /// A fixed wall clock so `[Time]` resolves the same in every run.
    public static let fixedWallClock: @Sendable () -> Date = {
        Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-26, 10:00:00 America/New_York (14:00 UTC)
    }

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: any RenderBackend = RecordingBackend(),
                wallClock: @escaping @Sendable () -> Date = HeadlessEngine.fixedWallClock) throws {
        self.backend = backend
        posters = FakePosterProvider(backend: backend)
        textProvider = FakeTextProvider(backend: backend)
        variables = VariableProvider(settings: machine.settings, wallClock: wallClock)
        var sinks: [Int: CapturingSink] = [:]
        for output in machine.outputs { sinks[output.number] = CapturingSink(output: output.number) }
        self.sinks = sinks
        engine = try Engine(library: library, machine: machine, mediaRoot: mediaRoot, backend: backend, clock: clock,
                            sinks: sinks.values.map { $0 }, sourceFactory: sourceFactory, posters: posters, text: textProvider,
                            variables: variables, log: EngineLog(category: "harness"))
        let backendRef = backend
        for sink in sinks.values {
            sink.isComplete = { receipt in backendRef.completion(of: receipt) != nil }
        }
        clock.start(rate: engine.pacing.masterRate) { [weak self] time in self?.handleTick(time) }
    }

    private func handleTick(_ time: TickTime) {
        sourceFactory.advance()
        let build = stallTicks == 0
        if !build { stallTicks -= 1 }
        engine.runTick(time, buildPlan: build)
        for sink in sinks.values { sink.present(now: time.wake) }
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
}
