// OEngine — Spec 4 §3 and §4, the control thread: commands in, frame plans out.

import Foundation
import OCore
import OFormats
import Synchronization

/// Spec 4 §3 — the control thread "Owns: The live ShowState, the command
/// queue, the projection, timers, OSC and API I/O. Hands over: A new immutable
/// ShowState plus the frame plan for the next tick, via one atomic pointer
/// swap." Spec 4 §14 — "The control thread's frame-plan builder is the only
/// code that reads both ShowState and the library, and it lives in OEngine."
///
/// `build(for:now:)` is the whole job for one tick: engine-issued commands
/// (armed triggers, end-of-media clears), then the queued groups through the
/// runner (Spec 2 §8), then the effects applied to the runtimes, then the
/// plan. In production it runs on the control thread while the render thread
/// encodes the previous tick; the harness calls it synchronously.
public final class ControlLoop: @unchecked Sendable {
    public let library: Library
    public let machine: Machine
    public let pacing: Pacing
    public let geometry: MachineGeometry
    let backend: any RenderBackend
    let sources: SourceTable
    let sourceFactory: any SourceFactory
    let posters: any PosterProvider
    let text: any TextProvider
    public let variables: VariableProvider
    let log: EngineLog
    let encodeKinds: [Int: EncodeKind]
    let mediaRoot: URL?
    /// Spec 3 §6 — "the set of media ids the resolver cannot find".
    public let missing: Set<String>
    public private(set) var model: ControlModel
    let queue = CommandQueue()
    private var handlePool: [Int32]
    private var pendingSourceRemovals: [(handle: InstanceHandle, afterFrame: Int64)] = []
    public let channelTextures: [Int: TextureHandle]
    public let channelSnapshots: [Int: TextureHandle]
    public let stackRings: [Int: [TextureHandle]]
    public let previewTargets: [Int: TextureHandle]
    public private(set) var lastExecuted: [ExecutedCommand] = []
    public private(set) var lastPlan: FramePlan?
    public private(set) var rejections: [Rejection] = []
    public private(set) var textLateThisBuild = 0
    private let builtAt = Atomic<Int64>(0)
    private var pendingSnapshotWhenReady: Set<Int> = []
    private var slideWarned = false

    public init(library: Library, machine: Machine, pacing: Pacing, mediaRoot: URL?, backend: any RenderBackend,
                sources: SourceTable, sourceFactory: any SourceFactory, posters: any PosterProvider, text: any TextProvider,
                variables: VariableProvider, encodeKinds: [Int: EncodeKind], log: EngineLog) {
        self.library = library
        self.machine = machine
        self.pacing = pacing
        self.geometry = MachineGeometry(library: library, machine: machine)
        self.backend = backend
        self.sources = sources
        self.sourceFactory = sourceFactory
        self.posters = posters
        self.text = text
        self.variables = variables
        self.encodeKinds = encodeKinds
        self.mediaRoot = mediaRoot
        self.log = log
        // Spec 1 §7 — "Missing state is computed, never stored".
        if let mediaRoot, let existing = try? LocalFiles.existingMediaPaths(mediaRoot: mediaRoot) {
            missing = MediaResolver.missingIds(library: library, machine: machine, existingPaths: existing)
        } else {
            missing = Set((machine.mediaLocal.entries + library.mediaIndex.entries).map(\.id))
        }
        // Spec 3 §2 — "A fresh ShowState has every channel empty ... every output on its default stack".
        model = ControlModel(state: ShowState.fresh(library: library, machine: machine))
        handlePool = (0..<Int32(sources.capacity)).reversed()
        // Spec 4 §5 — allocation at show load: one texture and one snapshot per channel, three per stack, a preview per stack.
        var channelTextures: [Int: TextureHandle] = [:]
        var channelSnapshots: [Int: TextureHandle] = [:]
        for channel in library.channels {
            let size = geometry.channelSize(channel.number)
            channelTextures[channel.number] = backend.makeTexture(TextureDescriptor(role: .channel, size: size, mipmapped: true, label: "channel \(channel.number)"))
            channelSnapshots[channel.number] = backend.makeTexture(TextureDescriptor(role: .channel, size: size, label: "channel \(channel.number) snapshot"))
        }
        var stackRings: [Int: [TextureHandle]] = [:]
        var previewTargets: [Int: TextureHandle] = [:]
        for stack in machine.stacks {
            let size = geometry.stackSize(stack.number)
            stackRings[stack.number] = (0..<FrameRing.depth).map { backend.makeTexture(TextureDescriptor(role: .stack, size: size, label: "stack \(stack.number) slot \($0)")) }
            let preview = PixelSize(width: max(16, size.width / 4), height: max(9, size.height / 4))
            previewTargets[stack.number] = backend.makeTexture(TextureDescriptor(role: .preview, size: preview, label: "stack \(stack.number) preview"))
        }
        self.channelTextures = channelTextures
        self.channelSnapshots = channelSnapshots
        self.stackRings = stackRings
        self.previewTargets = previewTargets
    }

    /// Spec 4 §12 — for the watchdog: when a plan was last built.
    public var lastBuilt: MonotonicTime { MonotonicTime(nanoseconds: builtAt.load(ordering: .acquiring)) }

    /// Spec 2 §8 — groups land on the next tick boundary.
    public func enqueue(_ group: CommandGroup) {
        queue.enqueue(group)
    }

    public var queuedGroups: Int { queue.count }

    /// The instance handles a channel holds: its live media and an outgoing one.
    public func handles(onChannel channel: Int) -> [InstanceHandle] {
        guard let rt = model.channels[channel] else { return [] }
        var out: [InstanceHandle] = []
        if let m = rt.live.media, m.source != nil { out.append(m.handle) }
        if case .content(let c)? = rt.outgoing, let m = c.media, m.source != nil { out.append(m.handle) }
        return out
    }

    // MARK: - One tick

    /// Spec 4 §3 — build the plan for `frame`: engine-issued commands, then the
    /// queued groups, then the runtimes advanced, then the plan.
    public func build(for frame: Int64, now: MonotonicTime) -> FramePlan {
        model.frame = frame
        sweepReleases(before: frame)
        advanceRuntimes(frame)
        var groups = engineGroups(frame)
        groups += queue.drain()
        lastExecuted = []
        for group in groups { run(group, frame: frame) }
        syncTransports(frame)
        reconcileGrades(frame)
        let plan = buildPlan(frame)
        for channel in model.channels.keys { model.channels[channel]?.snapshotPending = false }
        lastPlan = plan
        builtAt.store(now.nanoseconds, ordering: .releasing)
        return plan
    }

    /// Spec 4 §3 — a source's slot is reused only after every plan that could
    /// name it was consumed; two ticks is the plan ring's depth of slack.
    private func sweepReleases(before frame: Int64) {
        var keep: [(handle: InstanceHandle, afterFrame: Int64)] = []
        for entry in pendingSourceRemovals {
            if entry.afterFrame <= frame {
                sources.remove(entry.handle)
                handlePool.append(entry.handle.rawValue)
            } else {
                keep.append(entry)
            }
        }
        pendingSourceRemovals = keep
    }

    /// Spec 4 §6 — readiness of cold writes; Spec 4 §7 — transitions and grades ending.
    private func advanceRuntimes(_ frame: Int64) {
        for channel in model.channels.keys.sorted() {
            guard var rt = model.channels[channel] else { continue }
            if case .media(var m) = rt.live, !m.missing, !m.ready, let source = m.source, source.isReady {
                m.ready = true
                m.clock = MediaClock(anchorFrame: frame, anchorMs: m.inMs, playing: m.transport == .playing)
                rt.live = .media(m)
                if var t = rt.transition, t.startFrame == nil {
                    // Spec 4 §6 — "starts its transition when the first decoded frame arrives".
                    if pendingSnapshotWhenReady.remove(channel) != nil {
                        if case .content(let c)? = rt.outgoing { release(c, frame: frame) }
                        rt.outgoing = .snapshot
                        rt.snapshotPending = true
                    }
                    t.startFrame = frame
                    rt.transition = t
                }
            }
            if let t = rt.transition, t.isComplete(at: frame) {
                if case .content(let c)? = rt.outgoing { release(c, frame: frame) }
                rt.outgoing = nil
                rt.transition = nil
                rt.snapshotPending = false
            }
            if rt.grade.isComplete(at: frame), rt.grade.durationFrames > 0 {
                rt.grade = GradeRun(targetRef: rt.grade.targetRef, from: rt.grade.to, to: rt.grade.to, startFrame: frame, durationFrames: 0)
            }
            model.channels[channel] = rt
        }
        for output in model.outputs.keys {
            guard var ort = model.outputs[output] else { continue }
            if let run = ort.switchRun, run.isComplete(at: frame) { ort.switchRun = nil }
            if let run = ort.blackout, run.isComplete(at: frame) {
                ort.blackoutMix = run.toBlack ? 1 : 0
                ort.blackout = nil
            }
            model.outputs[output] = ort
        }
    }

    /// Spec 3 §5 — the armed trigger fires `next` from the scheduler when the
    /// clock reaches it; Spec 4 §6 — end of media with `clear` "asks the
    /// control thread to issue `channel N clear` with source `engine`".
    private func engineGroups(_ frame: Int64) -> [CommandGroup] {
        var groups: [CommandGroup] = []
        if let armed = model.state.armed, Int64(armed.atFrame) <= frame {
            groups.append(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .scheduler), commands: [Command.next]))
        }
        for channel in model.channels.keys.sorted() {
            guard var rt = model.channels[channel], case .media(var m) = rt.live, !m.missing, m.ready,
                  m.transport == .playing, !m.loops, m.outMs.isFinite, !m.isStill else { continue }
            let raw = m.clock.mediaTime(at: frame, millisecondsPerTick: pacing.millisecondsPerTick)
            guard raw >= m.outMs else { continue }
            if m.endBehavior == .clear, !m.clearIssued {
                m.clearIssued = true
                rt.live = .media(m)
                model.channels[channel] = rt
                groups.append(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .engine),
                                           commands: [Command.channelClear(channel: .number(channel))]))
            }
        }
        return groups
    }

    func projectionContext(frame: Int64, source: CommandSource) -> ProjectionContext {
        let state = model.state
        let variables = self.variables
        return ProjectionContext(frame: Int(frame), rate: pacing.masterRate, library: library, machine: machine, missing: missing,
                                 source: source, variables: { name in variables.value(name, state: state) })
    }

    /// Spec 2 §8 — "parse, validate, execute, log": the runner validates and
    /// folds the group; every effect then reaches the runtimes.
    private func run(_ group: CommandGroup, frame: Int64) {
        let context = projectionContext(frame: frame, source: group.source)
        switch CommandRunner.run(group, state: model.state, context: context) {
        case .failure(let rejection):
            rejections.append(rejection)
            log.warning("rejected \(group.source.kind.rawValue) group: \(rejection.message)")
        case .success(let outcome):
            model.state = outcome.state
            lastExecuted.append(contentsOf: outcome.executed)
            for executed in outcome.executed {
                for effect in executed.effects { apply(effect, frame: frame) }
            }
        }
    }

    // MARK: - Effects to runtimes (Spec 3 §6, "Who acts": the engine)

    private func apply(_ effect: Effect, frame: Int64) {
        switch effect {
        case .transition(let e):
            handleTransition(e, frame: frame)
        case .steppedOn(let channel, let dropped):
            // Spec 3 §4 — "the engine cuts that content out immediately".
            guard var rt = model.channels[channel] else { return }
            if case .content(let c)? = rt.outgoing, c.media?.ref == dropped {
                release(c, frame: frame)
                rt.outgoing = nil
                model.channels[channel] = rt
            }
        case .attribute(let channel, let attribute, _, let new, let ms):
            switch (attribute, new) {
            case (.grade, .grade(let ref)):
                startGrade(channel: channel, ref: ref, ms: ms, frame: frame)
            case (.gain, .gain(let db)):
                model.channels[channel, default: ChannelRuntime()].gainDb = db
            default:
                break
            }
        case .stackSwitch(let output, let old, let new, let transition):
            let object = transition.flatMap { library.transition($0) }
            let frames = object.map { pacing.frames(forMs: $0.ms) } ?? 0
            var ort = model.outputs[output] ?? OutputRuntime()
            ort.switchRun = frames > 0 && object?.type != .cut
                ? SwitchRun(oldStack: old, newStack: new, easing: object?.easing ?? .linear, startFrame: frame, durationFrames: frames)
                : nil
            model.outputs[output] = ort
        case .blackout(let stack, _, let new, let transition):
            let object = transition.flatMap { library.transition($0) }
            let frames = object.map { pacing.frames(forMs: $0.ms) } ?? 0
            for output in machine.outputs where (model.state.outputs[output.number] ?? output.defaultStack) == stack {
                var ort = model.outputs[output.number] ?? OutputRuntime()
                let from = ort.blackout.map { $0.mix(at: frame) } ?? ort.blackoutMix
                if frames > 0 {
                    ort.blackout = BlackoutRun(toBlack: new, easing: object?.easing ?? .linear, startFrame: frame, durationFrames: frames, fromMix: from)
                } else {
                    ort.blackout = nil
                    ort.blackoutMix = new ? 1 : 0
                }
                model.outputs[output.number] = ort
            }
        case .build:
            if !slideWarned {
                slideWarned = true
                log.warning("designed slides are v2; a slide write renders nothing")
            }
        case .passthrough(let command):
            log.info("passthrough \(command.cmd) (handled outside the spike)")
        case .mute, .variable, .boundary, .pointer, .blocked, .applied, .noop:
            break
        }
    }

    /// Spec 3 §4 and Spec 4 §7 — a write: the new instance becomes the live
    /// runtime; the previous one becomes the outgoing of the transition, still
    /// playing, unless the transition was interrupted or the write restarts
    /// the same media, in which case the outgoing is a snapshot of the channel
    /// texture as it was. Text has no channel pass (Spec 4 §7), so a write to
    /// text replaces the picture at once and the boxes transition instead.
    private func handleTransition(_ e: TransitionEffect, frame: Int64) {
        let object = library.transition(e.transition)
        let type = object?.type ?? .cut
        let durationFrames = e.ms > 0 ? pacing.frames(forMs: e.ms) : 0
        let easing = object?.easing ?? .linear
        let color = object?.color.map(ColorValue.init)
        var rt = model.channels[e.channel] ?? ChannelRuntime()
        let previous = rt.live
        let interrupted = rt.transition.map { $0.isRunning(at: frame) } ?? false
        if case .content(let c)? = rt.outgoing { release(c, frame: frame) }
        rt.outgoing = nil
        rt.snapshotPending = false
        pendingSnapshotWhenReady.remove(e.channel)

        let incoming = makeRuntime(for: e.to, channel: e.channel, frame: frame)
        let cutLike = type == .cut || durationFrames <= 0
        let previousHasPicture = previous.hasPixels

        if case .text = incoming {
            release(previous, frame: frame)
            rt.live = incoming
            rt.transition = nil
            model.channels[e.channel] = rt
            return
        }

        if case .media(let m) = incoming, !m.missing, !m.ready {
            // Spec 4 §6 — a cold write: "shows the item's poster frame on the
            // tick it lands and starts its transition when the first decoded
            // frame arrives"; with no poster, the previous picture holds.
            if !m.poster.isNone {
                release(previous, frame: frame)
                if !cutLike { pendingSnapshotWhenReady.insert(e.channel) }
            } else if previousHasPicture, !cutLike {
                rt.outgoing = .content(previous)
            } else {
                release(previous, frame: frame)
            }
            rt.live = incoming
            rt.transition = TransitionRun(type: type, easing: easing, color: color, durationFrames: cutLike ? 0 : durationFrames, startFrame: nil)
            model.channels[e.channel] = rt
            return
        }

        if cutLike || !previousHasPicture {
            release(previous, frame: frame)
        } else if interrupted || e.restart {
            rt.outgoing = .snapshot
            rt.snapshotPending = true
            release(previous, frame: frame)
        } else {
            rt.outgoing = .content(previous)
        }
        rt.live = incoming
        rt.transition = TransitionRun(type: type, easing: easing, color: color,
                                      durationFrames: (cutLike || !previousHasPicture) ? 0 : durationFrames, startFrame: frame)
        model.channels[e.channel] = rt
    }

    /// Spec 3 §4 — a grade write "carries an optional duration: with none it
    /// applies on the next frame; with one, the engine interpolates".
    private func startGrade(channel: Int, ref: Int, ms: Int?, frame: Int64) {
        var rt = model.channels[channel] ?? ChannelRuntime()
        let to = ref == 0 ? GradeParameters.identity : (library.grade(ref).map(GradeParameters.init) ?? .identity)
        let from = rt.grade.current(at: frame)
        rt.grade = GradeRun(targetRef: ref, from: from, to: to, startFrame: frame, durationFrames: ms.map { pacing.frames(forMs: $0) } ?? 0)
        model.channels[channel] = rt
    }

    /// Spec 3 §3 rule 4 and others reset attributes without an effect per
    /// channel; the runtime follows the state's grade whenever they differ.
    private func reconcileGrades(_ frame: Int64) {
        for (number, channel) in model.state.channels {
            let ref = channel.attributes.grade.value
            if (model.channels[number]?.grade.targetRef ?? 0) != ref {
                startGrade(channel: number, ref: ref, ms: nil, frame: frame)
            }
        }
    }

    /// Spec 3 §4 — transport: "`pause` stops consuming the ring and holds the
    /// media time; `stop` flushes the ring and resets to the in-point; `play`
    /// resumes." (Spec 4 §11.) The clock follows the state's transport.
    private func syncTransports(_ frame: Int64) {
        for channel in model.channels.keys {
            guard var rt = model.channels[channel], case .media(var m) = rt.live,
                  let instance = model.state.channels[channel]?.content.media, instance.ref == m.ref else { continue }
            if instance.transport != m.transport {
                switch instance.transport {
                case .paused:
                    m.clock.pause(at: frame, millisecondsPerTick: pacing.millisecondsPerTick)
                case .playing:
                    if m.transport == .stopped {
                        m.clock = MediaClock(anchorFrame: frame, anchorMs: m.inMs, playing: true)
                        m.clearIssued = false
                    } else {
                        m.clock.resume(at: frame)
                    }
                case .stopped:
                    m.clock = MediaClock(anchorFrame: frame, anchorMs: m.inMs, playing: false)
                }
                m.transport = instance.transport
            }
            m.endBehavior = instance.endBehavior
            rt.live = .media(m)
            model.channels[channel] = rt
        }
    }

    // MARK: - Runtimes

    private func allocateHandle() -> InstanceHandle? {
        guard let raw = handlePool.popLast() else { return nil }
        return InstanceHandle(rawValue: raw)
    }

    /// Spec 4 §6 — open the content's source: media through the factory
    /// (adopting a prefetched one), with its poster; missing media keeps its
    /// instance and renders nothing (Spec 3 §4).
    private func makeRuntime(for content: ContentInstance, channel: Int, frame: Int64) -> ContentRuntime {
        switch content {
        case .empty:
            return .empty
        case .text(let t):
            return .text(t.fields)
        case .slide(let s):
            return .slide(s.ref)
        case .input(let i):
            return .input(i.input)
        case .media(let m):
            let resolved = MediaResolver.resolve(m.ref, library: library, machine: machine)
            let entry = resolved?.entry
            let inMs = Double(m.inMs ?? 0)
            let duration = entry?.durationMs.map(Double.init) ?? .infinity
            let outMs = m.outMs.map(Double.init) ?? duration
            var runtime = MediaRuntime(
                ref: m.ref, handle: InstanceHandle(rawValue: -1), source: nil,
                poster: entry.map { posters.poster(for: $0) } ?? .none, entry: entry,
                layout: .nv12, size: PixelSize(width: entry?.width ?? 0, height: entry?.height ?? 0), matrix: .bt709, range: .limited,
                inMs: inMs, outMs: outMs, clock: MediaClock(anchorFrame: frame, anchorMs: inMs, playing: true),
                ready: false, missing: m.missing || resolved == nil || mediaRoot == nil, clearIssued: false,
                transport: m.transport, endBehavior: m.endBehavior)
            guard !runtime.missing, let entry, let resolved, let mediaRoot else { return .media(runtime) }
            guard let handle = allocateHandle() else {
                log.error("no free instance slot for \(m.ref) on channel \(channel)")
                runtime.missing = true
                return .media(runtime)
            }
            let request = SourceRequest(url: mediaRoot.appendingPathComponent(resolved.path), entry: entry, inMs: inMs,
                                        outMs: outMs.isFinite ? outMs : nil, loop: m.endBehavior == .loop, handle: handle)
            let source = sourceFactory.adoptPrefetched(request) ?? sourceFactory.open(request)
            sources.install(source, at: handle)
            runtime.handle = handle
            runtime.source = source
            runtime.layout = source.layout
            runtime.size = source.size
            runtime.matrix = (runtime.size.width <= 720 && runtime.size.height <= 576) ? .bt601 : .bt709
            runtime.range = source.layout.isYCbCr ? .limited : .full
            runtime.ready = source.isReady
            return .media(runtime)
        }
    }

    private func release(_ content: ContentRuntime, frame: Int64) {
        guard case .media(let m) = content, let source = m.source else { return }
        source.release()
        pendingSourceRemovals.append((m.handle, frame + 2))
    }

    // MARK: - Media time (Spec 4 §2, §6)

    /// Spec 4 §2 — "Instances without audio run a media clock derived from the
    /// tick"; Spec 4 §6 — loops wrap, `hold` keeps the last frame, `stop`
    /// shows the poster.
    func mediaTime(_ m: MediaRuntime, at frame: Int64) -> Double {
        guard m.ready, m.transport != .stopped, !m.isStill else { return m.inMs }
        let raw = m.clock.mediaTime(at: frame, millisecondsPerTick: pacing.millisecondsPerTick)
        guard m.outMs.isFinite else { return raw }
        if m.loops {
            let length = m.outMs - m.inMs
            guard length > 0 else { return m.inMs }
            return m.inMs + (raw - m.inMs).truncatingRemainder(dividingBy: length)
        }
        return min(raw, m.outMs)
    }

    func binding(for content: ContentRuntime, at frame: Int64) -> SourceBinding? {
        guard case .media(let m) = content, !m.missing else { return nil }
        if m.transport == .stopped || !m.ready {
            guard !m.poster.isNone else { return nil }
            let size = m.size.pixelCount > 0 ? m.size : PixelSize(.hd)
            return SourceBinding(source: .texture(m.poster), layout: .bgra8sRGB, matrix: .bt709, range: .full, size: size)
        }
        return SourceBinding(source: .instance(m.handle, mediaTimeMs: mediaTime(m, at: frame)), layout: m.layout,
                             matrix: m.matrix, range: m.range, size: m.size)
    }

    // MARK: - The plan (Spec 4 §4)

    private struct BuildScratch {
        var channelPasses: [Int: ChannelPass?] = [:]
        var lookahead: [Int: ShowState?] = [:]
        var jobs: [TextJob] = []
        var dueStackSizes: [Int: [PixelSize]] = [:]
    }

    /// Spec 4 §2 — "Render only what is due"; Spec 4 §4 — the plan.
    private func buildPlan(_ frame: Int64) -> FramePlan {
        textLateThisBuild = 0
        var scratch = BuildScratch()
        // Due outputs and the stacks they consume, including the old stack of a running switch.
        var dueStacks: Set<Int> = []
        for output in machine.outputs where pacing.isStackDue(output: output.number, tick: frame) {
            let live = model.state.outputs[output.number] ?? output.defaultStack
            dueStacks.insert(live)
            if let run = model.outputs[output.number]?.switchRun, !run.isComplete(at: frame) { dueStacks.insert(run.oldStack) }
        }
        // Which stacks sample each channel, for mip generation below half scale.
        for stack in machine.stacks where dueStacks.contains(stack.number) {
            let size = geometry.stackSize(stack.number)
            for slot in stack.effectiveSlots(library: library) where slot.offset == 0 {
                scratch.dueStackSizes[slot.channel, default: []].append(size)
            }
        }

        var plan = FramePlan(frame: frame)
        for stack in machine.stacks where dueStacks.contains(stack.number) {
            plan.stackPasses.append(stackPass(stack, frame: frame, scratch: &scratch))
        }
        plan.channelPasses = scratch.channelPasses.keys.sorted().compactMap { scratch.channelPasses[$0] ?? nil }
        plan.textJobs = scratch.jobs
        for output in machine.outputs where pacing.isSinkDue(output: output.number, tick: frame) {
            if let pass = sinkPass(output, frame: frame) { plan.sinkPasses.append(pass) }
        }
        // Spec 4 §10 — previews "at most 30 times a second".
        let previewEvery = max(1, Int64((pacing.masterRate.perSecond / 30).rounded()))
        if frame % previewEvery == 0 {
            for stack in machine.stacks where dueStacks.contains(stack.number) {
                if let target = previewTargets[stack.number] { plan.auxPasses.append(AuxPass(kind: .preview, stack: stack.number, target: target)) }
            }
        }
        return plan
    }

    /// Spec 4 §7 — the channel pass, once per channel per tick, or nil when the
    /// channel has nothing to draw (text, empty, missing media).
    private func channelPass(_ channel: Int, frame: Int64, scratch: inout BuildScratch) -> ChannelPass? {
        if let cached = scratch.channelPasses[channel] { return cached }
        let pass = makeChannelPass(channel, frame: frame, dueStackSizes: scratch.dueStackSizes[channel] ?? [])
        scratch.channelPasses[channel] = pass
        return pass
    }

    private func makeChannelPass(_ channel: Int, frame: Int64, dueStackSizes: [PixelSize]) -> ChannelPass? {
        guard let rt = model.channels[channel], let target = channelTextures[channel] else { return nil }
        let size = geometry.channelSize(channel)
        var incoming = binding(for: rt.live, at: frame)
        var outgoing: SourceBinding?
        switch rt.outgoing {
        case .content(let c)?:
            outgoing = binding(for: c, at: frame)
        case .snapshot?:
            if let snapshot = channelSnapshots[channel] {
                outgoing = SourceBinding(source: .texture(snapshot), layout: .linearRGBA16, matrix: .bt709, range: .full, size: size)
            }
        case nil:
            break
        }
        let transition = rt.transition?.state(at: frame)
        if transition == nil {
            // Not running (or waiting on a cold write): hold the previous picture if there is nothing new.
            if incoming == nil, let held = outgoing { incoming = held }
            outgoing = nil
        } else if transition?.type == .cut {
            outgoing = nil
        }
        guard incoming != nil || outgoing != nil else { return nil }
        let mips = dueStackSizes.contains { $0.height * 2 < size.height }
        return ChannelPass(channel: channel, target: target, size: size,
                           incoming: incoming ?? SourceBinding(source: .none, layout: .linearRGBA16, matrix: .bt709, range: .full, size: size),
                           outgoing: outgoing, transition: transition, grade: rt.grade.current(at: frame),
                           generateMips: mips, snapshotOutgoing: rt.snapshotPending)
    }

    /// Spec 4 §7 — "The source is drawn into the channel's render size
    /// preserving its aspect ratio, letterboxed with transparent pixels": the
    /// part of the channel texture the content occupies, normalized.
    static func contentRect(source: PixelSize, channel: PixelSize) -> UVRect {
        guard source.width > 0, source.height > 0, channel.width > 0, channel.height > 0 else { return .full }
        let scale = min(Double(channel.width) / Double(source.width), Double(channel.height) / Double(source.height))
        let w = Double(source.width) * scale / Double(channel.width)
        let h = Double(source.height) * scale / Double(channel.height)
        return UVRect(u: Float((1 - w) / 2), v: Float((1 - h) / 2), width: Float(w), height: Float(h))
    }

    /// Spec 4 §9 — "A quad placing the channel texture in the box frame by fit
    /// mode: `fit` letterboxes, `fill` crops to cover, `stretch` ignores aspect,
    /// `crop` centers at 1:1". The modes act on the content inside the texture
    /// (Area 4 reading), so a 4:3 clip with `fill` really fills.
    static func fitQuad(texture: TextureHandle, content: UVRect, contentPixels: PixelSize, into frame: PixelRect, fit: PixelFit) -> PixelQuad {
        let aspect = contentPixels.height > 0 ? Float(contentPixels.width) / Float(contentPixels.height) : 1
        let frameAspect = frame.height > 0 ? frame.width / frame.height : 1
        switch fit {
        case .stretch:
            return PixelQuad(texture: texture, frame: frame, uv: content)
        case .fit:
            var w = frame.width
            var h = frame.height
            if aspect > frameAspect { h = frame.width / aspect } else { w = frame.height * aspect }
            let rect = PixelRect(x: frame.x + (frame.width - w) / 2, y: frame.y + (frame.height - h) / 2, width: w, height: h)
            return PixelQuad(texture: texture, frame: rect, uv: content)
        case .fill:
            var uv = content
            if aspect > frameAspect {
                let keep = frameAspect / aspect
                uv = UVRect(u: content.u + content.width * (1 - keep) / 2, v: content.v, width: content.width * keep, height: content.height)
            } else {
                let keep = aspect / frameAspect
                uv = UVRect(u: content.u, v: content.v + content.height * (1 - keep) / 2, width: content.width, height: content.height * keep)
            }
            return PixelQuad(texture: texture, frame: frame, uv: uv)
        case .crop:
            let cw = Float(contentPixels.width)
            let ch = Float(contentPixels.height)
            let w = min(cw, frame.width)
            let h = min(ch, frame.height)
            let rect = PixelRect(x: frame.x + (frame.width - w) / 2, y: frame.y + (frame.height - h) / 2, width: w, height: h)
            let uv = UVRect(u: content.u + content.width * (cw - w) / (2 * max(1, cw)), v: content.v + content.height * (ch - h) / (2 * max(1, ch)),
                            width: content.width * w / max(1, cw), height: content.height * h / max(1, ch))
            return PixelQuad(texture: texture, frame: rect, uv: uv)
        }
    }

    /// Spec 3 §7 — lookahead for offset slots, once per offset per build.
    private func lookaheadState(_ steps: Int, frame: Int64, scratch: inout BuildScratch) -> ShowState? {
        if let cached = scratch.lookahead[steps] { return cached }
        let context = projectionContext(frame: frame, source: CommandSource(kind: .engine))
        let state = lookahead(model.state, steps: steps, context: context)
        scratch.lookahead[steps] = state
        return state
    }

    /// Spec 4 §9 — one stack pass: "compositing its slots bottom to top".
    private func stackPass(_ stack: Stack, frame: Int64, scratch: inout BuildScratch) -> StackPass {
        let size = geometry.stackSize(stack.number)
        let target = stackRings[stack.number]?[Int(frame % Int64(FrameRing.depth))] ?? .none
        var boxes: [ResolvedBox] = []
        for (slotIndex, slot) in stack.effectiveSlots(library: library).enumerated() {
            let content: ContentInstance?
            if slot.offset == 0 {
                content = model.state.channels[slot.channel]?.content
                // Spec 4 §8 — "Lookahead pre-rasterizes the next cue's text for every due stack".
                if let next = lookaheadState(1, frame: frame, scratch: &scratch), case .text(let t)? = next.channels[slot.channel]?.content {
                    prefetchText(stack: stack, slot: slot, fields: t.fields, size: size)
                }
            } else if slot.offset > 0 {
                content = lookaheadState(slot.offset, frame: frame, scratch: &scratch)?.channels[slot.channel]?.content
            } else {
                content = nil   // negative offsets are v1.5
            }
            resolveSlot(stack: stack, slotIndex: slotIndex, slot: slot, content: content, size: size, frame: frame, into: &boxes, scratch: &scratch)
        }
        return StackPass(stack: stack.number, target: target, size: size, base: stack.base, gammaBlend: stack.gammaBlend, boxes: boxes)
    }

    private func preset(for slot: StackSlot, stack: Stack) -> Preset {
        // Spec 4 §9 — "the preset is the slot's, else the stack default, else the channel default, else Preset 1".
        library.resolvedPreset(slot.preset ?? stack.defaultPreset ?? library.channel(slot.channel)?.defaultPreset)
    }

    private func prefetchText(stack: Stack, slot: StackSlot, fields: [String: String], size: PixelSize) {
        guard let layout = preset(for: slot, stack: stack).layout(for: stack.number) else { return }
        for box in layout.boxes {
            guard case .field(let name) = box.binding.kind, let value = fields[name], !value.isEmpty else { continue }
            let job = textJob(value, box: box, frame: PixelRect(box.frame, in: size), outputHeight: size.height)
            if text.entry(for: job) == nil { text.request(job) }
        }
    }

    private func textJob(_ value: String, box: Box, frame: PixelRect, outputHeight: Int) -> TextJob {
        let style = box.textStyle ?? BoxTextStyle()
        let fit = box.fit.textFit ?? TextFit()
        let boxSize = PixelSize(width: Int(frame.width.rounded()), height: Int(frame.height.rounded()))
        return TextJob(key: TextKey.make(text: value, style: style, box: boxSize, fit: fit, outputHeight: outputHeight),
                       text: value, style: style, box: boxSize, fit: fit, outputHeight: outputHeight)
    }

    /// Spec 4 §9 — resolve one slot's boxes and bind each to its source;
    /// "Fallback boxes draw only if no earlier box in the same channel's group
    /// drew anything"; "A slot's effective opacity is its opacity times zero
    /// when muted".
    private func resolveSlot(stack: Stack, slotIndex: Int, slot: StackSlot, content: ContentInstance?, size: PixelSize, frame: Int64,
                             into boxes: inout [ResolvedBox], scratch: inout BuildScratch) {
        guard let layout = preset(for: slot, stack: stack).layout(for: stack.number) else { return }
        let muted = model.state.stacks[stack.number]?.muted.contains(slot.channel) ?? false
        let opacity = Float(slot.opacity) * (muted ? 0 : 1)
        var drew = false
        for (boxIndex, box) in layout.boxes.enumerated() {
            let key = BoxKey(stack: stack.number, slot: slotIndex, box: boxIndex)
            if box.fallback && drew {
                endBox(key, frame: frame, box: box, opacity: opacity, slot: slot, size: size, into: &boxes)
                continue
            }
            let frameRect = PixelRect(box.frame, in: size)
            var resolved: ResolvedBox?
            var transitionAllowed = true
            switch box.binding.kind {
            case .pixels:
                let fit = box.fit.pixelFit ?? .fit
                if slot.offset == 0 {
                    if let pass = channelPass(slot.channel, frame: frame, scratch: &scratch) {
                        let bound = pass.incoming.source == .none ? (pass.outgoing ?? pass.incoming) : pass.incoming
                        let content = ControlLoop.contentRect(source: bound.size, channel: pass.size)
                        let quad = ControlLoop.fitQuad(texture: pass.target, content: content, contentPixels: bound.size, into: frameRect, fit: fit)
                        resolved = ResolvedBox(channel: slot.channel, frame: frameRect, content: .pixels(quad), opacity: opacity,
                                               grade: boxGrade(box), offset: slot.offset, binding: box.binding)
                    }
                } else if let media = content?.media, !media.missing,
                          let entry = MediaResolver.resolve(media.ref, library: library, machine: machine)?.entry {
                    // Spec 4 §9 — "a pixel box points at the pool item's poster frame texture".
                    let poster = posters.poster(for: entry)
                    if !poster.isNone {
                        let pixels = PixelSize(width: entry.width ?? 16, height: entry.height ?? 9)
                        let quad = ControlLoop.fitQuad(texture: poster, content: .full, contentPixels: pixels, into: frameRect, fit: fit)
                        resolved = ResolvedBox(channel: slot.channel, frame: frameRect, content: .pixels(quad), opacity: opacity,
                                               grade: boxGrade(box), offset: slot.offset, binding: box.binding)
                    }
                }
            case .field(let name):
                if case .text(let t)? = content, let value = t.fields[name], !value.isEmpty {
                    resolved = textBox(value, box: box, frame: frameRect, size: size, slot: slot, opacity: opacity, scratch: &scratch)
                }
            case .static(let raw):
                let value = variables.resolve(raw, state: model.state)
                transitionAllowed = box.transitionOnVariableChange || !VariableProvider.containsVariables(raw)
                if !value.isEmpty {
                    resolved = textBox(value, box: box, frame: frameRect, size: size, slot: slot, opacity: opacity, scratch: &scratch)
                }
            }
            guard var result = resolved else {
                endBox(key, frame: frame, box: box, opacity: opacity, slot: slot, size: size, into: &boxes)
                continue
            }
            drew = true
            result.transition = boxTransition(key, content: result.content, text: result.text, box: box, offset: slot.offset,
                                              allowed: transitionAllowed, frame: frame)
            boxes.append(result)
        }
    }

    private func boxGrade(_ box: Box) -> GradeParameters? {
        guard let ref = box.grade, ref != 0, let grade = library.grade(ref) else { return nil }
        let parameters = GradeParameters(grade)
        return parameters.isIdentity ? nil : parameters
    }

    /// Spec 4 §9 — "field: The cached line textures ... a missing cache entry
    /// draws nothing this tick and counts `textLate`".
    private func textBox(_ value: String, box: Box, frame: PixelRect, size: PixelSize, slot: StackSlot, opacity: Float,
                         scratch: inout BuildScratch) -> ResolvedBox {
        let job = textJob(value, box: box, frame: frame, outputHeight: size.height)
        var lines: [TextLine] = []
        if let entry = text.entry(for: job) {
            lines = entry.lines.map { line in
                TextLine(texture: line.texture, frame: PixelRect(x: frame.x + line.frame.x, y: frame.y + line.frame.y,
                                                                 width: line.frame.width, height: line.frame.height))
            }
        } else {
            text.request(job)
            scratch.jobs.append(job)
            textLateThisBuild += 1
        }
        return ResolvedBox(channel: slot.channel, frame: frame, content: .lines(lines), opacity: opacity, grade: boxGrade(box),
                           offset: slot.offset, binding: box.binding, text: value)
    }

    /// Spec 4 §9 — box transitions; "Offset slots ... cut rather than transition".
    private func boxTransition(_ key: BoxKey, content: BoxContent, text: String?, box: Box, offset: Int, allowed: Bool,
                               frame: Int64) -> BoxTransitionState? {
        var run = model.boxRuns[key] ?? BoxRun()
        defer { model.boxRuns[key] = run }
        guard offset == 0 else {
            run.previousContent = content
            run.previousText = text
            run.outgoing = nil
            return nil
        }
        if run.previousText != nil, run.previousText != text {
            startBoxRun(&run, from: run.previousContent, box: box, allowed: allowed, frame: frame)
        }
        run.previousContent = content
        run.previousText = text
        return run.state(at: frame)
    }

    private func startBoxRun(_ run: inout BoxRun, from previous: BoxContent?, box: Box, allowed: Bool, frame: Int64) {
        let object = library.transition(box.transition.ref)
        let ms = box.transition.ms ?? object?.ms ?? 0
        let type = object?.type ?? .cut
        if allowed, type != .cut, ms > 0, let previous, !previous.isEmpty {
            run.type = type
            run.easing = object?.easing ?? .linear
            run.startFrame = frame
            run.durationFrames = pacing.frames(forMs: ms)
            run.outgoing = previous
        } else {
            run.outgoing = nil
            run.durationFrames = 0
        }
    }

    /// A box that no longer draws: if it drew before, its content transitions out.
    private func endBox(_ key: BoxKey, frame: Int64, box: Box, opacity: Float, slot: StackSlot, size: PixelSize, into boxes: inout [ResolvedBox]) {
        guard var run = model.boxRuns[key] else { return }
        defer { model.boxRuns[key] = run }
        if run.previousText != nil {
            startBoxRun(&run, from: run.previousContent, box: box, allowed: slot.offset == 0, frame: frame)
            run.previousContent = nil
            run.previousText = nil
        }
        if let state = run.state(at: frame) {
            boxes.append(ResolvedBox(channel: slot.channel, frame: PixelRect(box.frame, in: size), content: .lines([]), opacity: opacity,
                                     transition: state, grade: boxGrade(box), offset: slot.offset, binding: box.binding))
        }
    }

    /// Spec 4 §10 — the sink pass with its output transition: "the previous
    /// stack for a switch, black for blackout".
    private func sinkPass(_ output: Output, frame: Int64) -> SinkPass? {
        let live = model.state.outputs[output.number] ?? output.defaultStack
        guard let ring = stackRings[live] else { return nil }
        let slot = Int(frame % Int64(FrameRing.depth))
        var second: SecondTexture = .none
        var mix: Float = 0
        let ort = model.outputs[output.number] ?? OutputRuntime()
        if let run = ort.switchRun, !run.isComplete(at: frame), let oldRing = stackRings[run.oldStack] {
            second = .stack(oldRing[slot])
            mix = run.oldMix(at: frame)
        }
        let black = ort.blackout.map { $0.mix(at: frame) } ?? ort.blackoutMix
        if black > 0 {
            second = .black
            mix = black
        }
        let encode = encodeKinds[output.number] ?? (output.kind == .sdi ? .v210 : .display10Bit)
        return SinkPass(output: output.number, stack: ring[slot], second: second, mix: mix, encode: encode, destination: slot)
    }
}
