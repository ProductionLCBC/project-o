// OEngine — Spec 4 §3 and §4, the control thread: commands in, frame plans out.

import Foundation
import OCore
import OFormats
import Synchronization

/// Spec 7 §6 — what one build sends about the live position and the
/// countdown: the OSC messages in order, and the `live` event.
public struct LiveFeedback: Sendable {
    public var messages: [OSCMessage]
    public var event: JSONValue
}

/// Spec 2 §8 — a group the runner rejected before anything ran: its id, its
/// source and "the rejection [that] names the command and the reason".
public struct RejectedGroup: Equatable, Sendable {
    public var id: GroupID
    public var source: CommandSource
    public var rejection: Rejection

    public init(id: GroupID, source: CommandSource, rejection: Rejection) {
        self.id = id
        self.source = source
        self.rejection = rejection
    }
}

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
    /// Spec 5 §2 — "The engine holds the loaded documents of both roots ...
    /// An edit changes the document in memory". The control thread's own;
    /// other threads read `publishedRoots`.
    public private(set) var library: Library
    public private(set) var machine: Machine
    /// Spec 5 §2 — "The engine keeps one library revision per run. It starts
    /// at 1 at launch and goes up by one for every applied edit group, every
    /// reload from disk and every unlock".
    public private(set) var revision = 1
    /// Spec 2 §9 — every executed command's line, in memory (Area 12 writes
    /// the day's file); Spec 5 §5 — typing's runs.
    public let commandLog = CommandLog()
    /// Spec 5 §2 — the `library` events of this build, in order, for the
    /// engine to publish once the plan is built. Reset every build.
    public private(set) var lastLibraryEvents: [LibraryEvent] = []
    /// Whether this build changed the roots: an edit, a reload, or a write
    /// that raised a list's version or renamed a file.
    public private(set) var lastRootsChanged = false
    /// Spec 7 §4 — the kept copies of the live list and playlist, engine
    /// memory between builds: the runner takes them at fires and after
    /// groups, and a reload refreshes them.
    public private(set) var kept = KeptCopies()
    /// Spec 7 §6 — the live reading last sent, and what this build sends:
    /// the `/o/live/…` messages and the `live` event, or nil when nothing
    /// they carry changed.
    public private(set) var lastLive: LiveSnapshot
    public private(set) var lastLiveFeedback: LiveFeedback?
    /// Spec 5 §2 — writing, when the engine runs over roots on disk; nil for
    /// roots built in memory, whose edits are never written.
    private(set) var documents: DocumentStore?
    public let pacing: Pacing
    public let geometry: MachineGeometry
    let backend: any RenderBackend
    let sources: SourceTable
    let sourceFactory: any SourceFactory
    let posters: any PosterProvider
    let text: any TextProvider
    public let variables: VariableProvider
    /// Spec 4 §11 — the audio system, one mix graph per device; nil runs silent.
    public let audio: AudioSystem?
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
    /// Spec 2 §8 — the groups this build rejected, with their ids and
    /// sources, so OSC can answer whoever sent them (Spec 2 §6, "Errors go
    /// back to the sender"). Reset every build, like `lastExecuted`.
    public private(set) var lastRejected: [RejectedGroup] = []
    public private(set) var lastPlan: FramePlan?
    public private(set) var rejections: [Rejection] = []
    public private(set) var textLateThisBuild = 0
    private let builtAt = Atomic<Int64>(0)
    private var pendingSnapshotWhenReady: Set<Int> = []
    private var slideWarned = false
    /// Spec 2 §3 and Spec 4 §11 — the audio outputs `audio N mute` has muted.
    /// Engine state, not ShowState (Spec 3 §2); the control thread's own.
    public private(set) var mutedAudioOutputs: Set<Int> = []

    public init(library: Library, machine: Machine, pacing: Pacing, mediaRoot: URL?, backend: any RenderBackend,
                sources: SourceTable, sourceFactory: any SourceFactory, posters: any PosterProvider, text: any TextProvider,
                variables: VariableProvider, encodeKinds: [Int: EncodeKind], audio: AudioSystem? = nil, log: EngineLog) {
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
        self.audio = audio
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
        lastLive = LiveSnapshot.reading(state: model.state, library: library, machine: machine, kept: KeptCopies())
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

    private let stateLock = NSLock()
    private var stateSnapshot = ShowState()
    private var rootsSnapshot: (library: Library, machine: Machine)?
    private var liveSnapshot: (live: LiveSnapshot, frame: Int)?

    /// Spec 2 §6 — "Any client may ask for a current value with `/o/query`":
    /// the live reading after the last build, and that build's frame, for
    /// readers on other threads.
    public var publishedLive: (live: LiveSnapshot, frame: Int) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return liveSnapshot ?? (lastLive, 0)
    }

    /// The state after the last build, for readers on other threads (the OSC
    /// query reply, the process summary). `model.state` itself belongs to the
    /// control thread.
    public var publishedState: ShowState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateSnapshot
    }

    /// The roots after the last build, for readers on other threads.
    public var publishedRoots: (library: Library, machine: Machine) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return rootsSnapshot ?? (library, machine)
    }

    /// Spec 2 §8 — groups land on the next tick boundary.
    public func enqueue(_ group: CommandGroup) {
        queue.enqueue(group)
    }

    /// Spec 5 §2 — "The engine writes a changed document": the roots the
    /// library and machine were loaded from, with the snapshots they were
    /// loaded from, so the writer knows what the files hold. Called once,
    /// before the engine starts.
    public func attachDocuments(libraryRoot: URL, machineRoot: URL, librarySnapshot: RootSnapshot, machineSnapshot: RootSnapshot) {
        let variables = self.variables
        let writer = DocumentWriter(libraryRoot: libraryRoot, machineRoot: machineRoot, librarySnapshot: librarySnapshot,
                                    machineSnapshot: machineSnapshot, fileStamp: { variables.fileStamp() })
        let reload = ReloadState.loaded(library: library, machine: machine, librarySnapshot: librarySnapshot, machineSnapshot: machineSnapshot)
        documents = DocumentStore(writer: writer, library: library, machine: machine, kept: KeptVersions.reading(librarySnapshot.versions),
                                  reload: reload, log: log, wallMilliseconds: { variables.wallMilliseconds })
    }

    /// Spec 5 §10 — look for changes that arrived on disk: the folder
    /// watcher asks, from its own thread, and so does the engine at start.
    public func requestScan() {
        documents?.writer.requestScan()
    }

    /// Spec 9 §4 — before the engine stops, every unwritten edit is written,
    /// and the writer finishes. On the control side, with the control thread
    /// stopped.
    public func flushDocuments(now: MonotonicTime) {
        guard let documents else { return }
        documents.writeDue(library: &library, machine: &machine, now: now, everything: true)
        documents.writer.waitUntilIdle()
        _ = documents.absorbReports(library: &library, machine: &machine, now: now)
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
        lastRejected = []
        lastLibraryEvents = []
        lastRootsChanged = false
        // Spec 5 §5 — a typing run "closes one second later": its one line.
        commandLog.closeRuns(now: now)
        if let documents {
            let changes = documents.absorbReports(library: &library, machine: &machine, now: now)
            if !changes.isEmpty {
                reloaded(changes)
                // Spec 7 §4 — "after every applied edit group, reload or library restore".
                kept = kept.refreshed(for: model.state.pointer, library: library, machine: machine)
            }
        }
        for group in groups { run(group, frame: frame, now: now) }
        // Spec 5 §2 — the writes that are due, planned here and carried out on the writer's queue.
        if let documents, documents.writeDue(library: &library, machine: &machine, now: now) {
            lastRootsChanged = true
            kept = kept.refreshed(for: model.state.pointer, library: library, machine: machine)
        }
        updateLive(frame: frame)
        syncTransports(frame)
        reconcileGrades(frame)
        let plan = buildPlan(frame)
        backend.prepare(plan)
        for channel in model.channels.keys { model.channels[channel]?.snapshotPending = false }
        lastPlan = plan
        stateLock.lock()
        stateSnapshot = model.state
        if lastRootsChanged || rootsSnapshot == nil { rootsSnapshot = (library, machine) }
        liveSnapshot = (lastLive, Int(frame))
        stateLock.unlock()
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
                // The decoder knows the stream now: its layout and size replace the index's guess.
                m.layout = source.layout
                m.size = source.size.pixelCount > 0 ? source.size : m.size
                m.matrix = (m.size.width <= 720 && m.size.height <= 576) ? .bt601 : .bt709
                m.range = source.layout.isYCbCr ? .limited : .full
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

    /// Spec 7 §4 — "When the engine clock reaches `atFrame`, the engine sends
    /// `next` if the trigger is live and `disarm` if it isn't, both with
    /// source `scheduler` ... the engine disarms it at its time with a log
    /// line, and the operator fires on by hand." Spec 4 §6 — end of media
    /// with `clear` "asks the control thread to issue `channel N clear` with
    /// source `engine`".
    private func engineGroups(_ frame: Int64) -> [CommandGroup] {
        var groups: [CommandGroup] = []
        if let armed = model.state.armed, Int64(armed.atFrame) <= frame {
            let live = model.state.liveArmed(library: library, machine: machine, kept: kept) != nil
            if !live {
                log.warning("the countdown to cue \(armed.cueUuid.uuidString.lowercased()) lapsed: an edit means it is no longer the cue next would fire, so it is disarmed and the operator fires on")
            }
            groups.append(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .scheduler), commands: [live ? Command.next : Command.disarm]))
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
                                 source: source, variables: { name in variables.value(name, state: state) }, kept: kept)
    }

    /// Spec 7 §6 — "The engine sends them on a fire, a load, an arm and a
    /// disarm, and after any applied edit group or reload that changes what
    /// they carry". The reading after this build against the last one sent;
    /// a pointer effect is a fire, a load or a disarm.
    private func updateLive(frame: Int64) {
        lastLiveFeedback = nil
        guard !lastExecuted.isEmpty || lastRootsChanged else { return }
        let live = LiveSnapshot.reading(state: model.state, library: library, machine: machine, kept: kept)
        var moved = false
        var boundary: Bool?
        for line in lastExecuted {
            for effect in line.effects {
                switch effect {
                case .pointer: moved = true
                case .boundary(_, let reset): boundary = reset
                default: break
                }
            }
        }
        let send = LiveSnapshot.feedback(from: lastLive, to: live, moved: moved, frame: Int(frame), rate: pacing.masterRate)
        lastLive = live
        guard send.event else { return }
        lastLiveFeedback = LiveFeedback(messages: send.messages,
                                        event: live.event(frame: Int(frame), rate: pacing.masterRate, seq: commandLog.lastSeq, boundary: boundary))
    }

    /// Spec 2 §8 — "parse, validate, execute, log": the runner validates and
    /// folds the group; every effect then reaches the runtimes. Spec 5 §2 —
    /// the edits it applied change the roots the next group reads, and each
    /// log group of applied edits raises the revision by one and makes one
    /// `library` event carrying the `seq` of its last line.
    private func run(_ group: CommandGroup, frame: Int64, now: MonotonicTime) {
        let context = projectionContext(frame: frame, source: group.source)
        // Spec 7 §5 — archive's dated title is "the day it runs in the machine's time zone".
        let editing = EditContext(today: variables.today())
        switch CommandRunner.run(group, state: model.state, context: context, editing: editing) {
        case .failure(let rejection):
            // Spec 5 §5 — "any other command from that client closes the run early".
            if let client = group.client { commandLog.closeRun(of: client) }
            rejections.append(rejection)
            lastRejected.append(RejectedGroup(id: group.id, source: group.source, rejection: rejection))
            log.warning("rejected \(group.source.kind.rawValue) group: \(rejection.message)")
        case .success(let outcome):
            model.state = outcome.state
            kept = outcome.kept
            lastExecuted.append(contentsOf: outcome.executed)
            let logged = commandLog.record(outcome.executed, client: group.client, now: now, ts: variables.timestamp())
            let applied = AppliedEdits.groups(in: logged.map(\.executed))
            if !applied.isEmpty {
                let before = (library: library, machine: machine)
                library = outcome.library
                machine = outcome.machine
                lastRootsChanged = true
                documents?.noteEdits(before: before, library: library, machine: machine, executed: outcome.executed, now: now)
                for edits in applied {
                    revision += 1
                    let seq = logged.filter { $0.executed.group == edits.group }.map(\.seq).max() ?? commandLog.lastSeq
                    lastLibraryEvents.append(LibraryEvent(rev: revision, cause: .edit, group: edits.group, source: edits.source,
                                                          changed: edits.changed, seq: seq))
                }
            }
            for executed in outcome.executed {
                for effect in executed.effects { apply(effect, frame: frame) }
                // Spec 2 §5 — a macro that cannot run whole "runs nothing and is logged `noop`";
                // the engine log says why (CLAUDE.md: unknown input is a noop and a log line).
                if case .macro(let number) = executed.command, let refusal = executed.refusal {
                    log.warning("macro \(number) ran nothing: \(refusal.message)")
                }
                // Spec 5 §2 — a held edit that was refused "yields `blocked` with its reason".
                if case .edit = executed.command, executed.result == .blocked, let refusal = executed.refusal {
                    let text = CommandText.print(executed.command) ?? executed.command.cmd
                    log.warning("blocked \(executed.source.kind.rawValue) edit \(text): \(refusal.reason.rawValue): \(refusal.message)")
                }
            }
        }
    }

    /// Spec 5 §2 — "goes up by one for every ... reload from disk", and one
    /// `library` event with cause `file`, no group and no source, carrying
    /// the `seq` of the last line logged before it (Spec 2 §9).
    private func reloaded(_ changes: [LibraryChange]) {
        revision += 1
        lastRootsChanged = true
        lastLibraryEvents.append(LibraryEvent(rev: revision, cause: .file, changed: changes, seq: commandLog.lastSeq))
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
                // Spec 4 §11 — "the channel's tracked gain plus any override".
                model.channels[channel, default: ChannelRuntime()].gainDb = db
                if let audio, let m = model.channels[channel]?.live.media, let attachment = m.audio {
                    audio.setGain(db + (m.gainOverride ?? 0), for: attachment)
                }
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
            if case .audioMute(let target, let switchState) = command {
                audioMute(target, switchState)
            } else {
                log.info("passthrough \(command.cmd) (handled outside the spike)")
            }
        case .mute, .variable, .boundary, .pointer, .blocked, .applied, .noop:
            break
        }
    }

    /// Spec 2 §3 — `audio N mute on | off | toggle`: "Mutes a numbered audio
    /// output; `audio all` for every one", and "With `all`, `toggle` turns
    /// every one on unless every one is already on, when it turns them all
    /// off" (Spec 10 §7). Spec 4 §11 — "`audio all mute` is one command over
    /// every device". A number that is not an audio output of this machine
    /// changes nothing; the muted set is kept with or without an audio system.
    private func audioMute(_ target: Target, _ switchState: SwitchState) {
        let numbers: [Int]
        let muted: Bool
        switch target {
        case .number(let n):
            guard machine.audioOutput(n) != nil else { return }
            numbers = [n]
            muted = switchState.resolve(current: mutedAudioOutputs.contains(n))
        case .all:
            numbers = machine.audioOutputs.map(\.number).sorted()
            muted = switchState.resolve(all: numbers.map { mutedAudioOutputs.contains($0) })
        }
        for number in numbers {
            if muted { mutedAudioOutputs.insert(number) } else { mutedAudioOutputs.remove(number) }
            audio?.setMuted(muted, output: number)
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

        // Spec 4 §11 — the audio transition "between the outgoing and incoming instance of a channel, with its offset".
        if let audio, previous.media?.audio != nil || incoming.media?.audio != nil {
            let object = library.audioTransition(e.audioTransition)
            audio.startTransition(outgoing: previous.media?.audio, incoming: incoming.media?.audio, type: object?.type ?? .cut,
                                  ms: e.audioMs, offsetMs: e.audioOffsetMs)
        }

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
                    if let a = m.audio { audio?.setPlaying(false, for: a) }
                case .playing:
                    if m.transport == .stopped {
                        m.clock = MediaClock(anchorFrame: frame, anchorMs: m.inMs, playing: true)
                        m.clearIssued = false
                        // Spec 4 §11 — after `stop`, play resumes from the in-point: a fresh decoder.
                        releaseAudio(of: &m)
                        attachAudio(to: &m, channel: channel, instance: instance)
                    } else {
                        m.clock.resume(at: frame)
                        if let a = m.audio { audio?.setPlaying(true, for: a) }
                    }
                case .stopped:
                    m.clock = MediaClock(anchorFrame: frame, anchorMs: m.inMs, playing: false)
                    // Spec 4 §11 — "stop flushes the ring".
                    releaseAudio(of: &m)
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
            runtime.syncOffsetMs = m.syncOffsetMs ?? 0
            runtime.gainOverride = m.gainOverride
            attachAudio(to: &runtime, channel: channel, instance: m)
            return .media(runtime)
        }
    }

    /// Spec 4 §11 — "Each channel's content may carry sound; the engine
    /// decodes it, applies the channel's gain and audio transition, and routes
    /// it to the numbered audio outputs the channel names." One ring per
    /// device those outputs reach; a channel naming no output on this machine
    /// gets no decoder.
    private func attachAudio(to runtime: inout MediaRuntime, channel: Int, instance: MediaInstance) {
        guard let audio, let entry = runtime.entry, entry.hasAudio, entry.kind != .image, let mediaRoot,
              let resolved = MediaResolver.resolve(instance.ref, library: library, machine: machine) else { return }
        let outputs = library.channel(channel)?.audioOutputs ?? []
        let rings = audio.ringCount(forOutputs: outputs)
        guard rings > 0 else { return }
        let decoder = AudioFileDecoder(url: mediaRoot.appendingPathComponent(resolved.path), inMs: runtime.inMs,
                                       outMs: runtime.outMs.isFinite ? runtime.outMs : nil, loop: instance.endBehavior == .loop, channels: 2,
                                       ringCount: rings, log: log)
        decoder.start()
        let gain = (model.channels[channel]?.gainDb ?? model.state.channels[channel]?.attributes.gain.value ?? 0) + (instance.gainOverride ?? 0)
        guard let attachment = audio.attach(handle: runtime.handle, rings: decoder.rings, outputs: outputs, inMs: runtime.inMs,
                                            syncOffsetMs: instance.syncOffsetMs ?? 0, gainDb: gain, playing: instance.transport == .playing,
                                            channel: channel) else {
            decoder.stop()
            return
        }
        runtime.audio = attachment
        runtime.audioDecoder = decoder
    }

    private func releaseAudio(of runtime: inout MediaRuntime) {
        if let attachment = runtime.audio { audio?.detach(attachment) }
        runtime.audioDecoder?.stop()
        for ring in runtime.audioDecoder?.rings ?? [] { ring.flush() }
        runtime.audio = nil
        runtime.audioDecoder = nil
    }

    private func release(_ content: ContentRuntime, frame: Int64) {
        guard case .media(var m) = content else { return }
        releaseAudio(of: &m)
        guard let source = m.source else { return }
        source.release()
        pendingSourceRemovals.append((m.handle, frame + 2))
    }

    // MARK: - Media time (Spec 4 §2, §6)

    /// Spec 4 §2 — "Instances without audio run a media clock derived from the
    /// tick"; Spec 4 §6 — loops wrap, `hold` keeps the last frame, `stop`
    /// shows the poster.
    func mediaTime(_ m: MediaRuntime, at frame: Int64) -> Double {
        guard m.ready, m.transport != .stopped, !m.isStill else { return m.inMs }
        var raw = m.clock.mediaTime(at: frame, millisecondsPerTick: pacing.millisecondsPerTick)
        if let audio, let attachment = m.audio {
            // Spec 4 §2 — "A/V sync is anchored to the audio device clock"; Spec 4 §11 — a
            // negative sync offset "delays video ... by advancing the instance's media time reference".
            raw = audio.mediaTimeMs(of: attachment) + Double(min(0, m.syncOffsetMs))
        }
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
        /// The channels a stack that is not aux-only asked a pass for (Spec 4 §4 step 5).
        var liveChannels: Set<Int> = []
        /// Spec 3 §7 — the states after the next 1, 2, … cues, each folded from
        /// the one before; nil from the first step past the end.
        var lookahead: [ShowState?] = []
        var jobs: [TextJob] = []
        var dueStackSizes: [Int: [PixelSize]] = [:]
    }

    /// Spec 4 §2 — "Render only what is due"; Spec 4 §4 — the plan; Spec 4
    /// §10 — previews "at most 30 times a second". Area 5 reading, approved on
    /// 2026-11-03: the preview is a consumer at the preview rate, so a stack
    /// no output feeds renders on preview ticks as aux-only work, with the
    /// channels only it samples, all of it skipped first under pressure
    /// (Spec 4 §4 step 5).
    private func buildPlan(_ frame: Int64) -> FramePlan {
        textLateThisBuild = 0
        var scratch = BuildScratch()
        // Due outputs and the stacks they consume, including the old stack of a running switch.
        var dueStacks: Set<Int> = []
        var assignedStacks: Set<Int> = []
        for output in machine.outputs {
            let live = model.state.outputs[output.number] ?? output.defaultStack
            assignedStacks.insert(live)
            var switching: Int?
            if let run = model.outputs[output.number]?.switchRun, !run.isComplete(at: frame) {
                switching = run.oldStack
                assignedStacks.insert(run.oldStack)
            }
            guard pacing.isStackDue(output: output.number, tick: frame) else { continue }
            dueStacks.insert(live)
            if let switching { dueStacks.insert(switching) }
        }
        let previewEvery = max(1, Int64((pacing.masterRate.perSecond / 30).rounded()))
        let previewTick = frame % previewEvery == 0
        var auxOnlyStacks: Set<Int> = []
        if previewTick {
            for stack in machine.stacks where !assignedStacks.contains(stack.number) { auxOnlyStacks.insert(stack.number) }
        }
        let rendering = dueStacks.union(auxOnlyStacks)
        // Which stacks sample each channel, for mip generation below half scale: the slots whose
        // layout has a pixel box at offset 0, the only box that samples the channel texture (Spec 6 §3).
        for stack in machine.stacks where rendering.contains(stack.number) {
            let size = geometry.stackSize(stack.number)
            for slot in stack.effectiveSlots(library: library) {
                let layout = SlotResolver.layout(for: slot, stack: stack, library: library)
                guard layout?.boxes.contains(where: { $0.offset == 0 && !$0.binding.isText }) == true else { continue }
                scratch.dueStackSizes[slot.channel, default: []].append(size)
            }
        }

        // Spec 6 §5 — "[Time], [Date], [Timer N] and [Service In] read the same in every state": read once per
        // build, with [Service In] from the live playlist; the thumbnail job reads what this build publishes.
        let livePlaylist = model.state.livePlaylist(library: library, machine: machine, kept: kept)
        let timers = timerReadings(at: frame)
        let resolving = Resolving(roots: VariableRoots(library: library, machine: machine, kept: kept),
                                  clock: variables.clock(livePlaylist: livePlaylist, timers: timers))
        variables.publish(livePlaylist: livePlaylist, timers: timers)

        var plan = FramePlan(frame: frame)
        for stack in machine.stacks where rendering.contains(stack.number) {
            plan.stackPasses.append(stackPass(stack, frame: frame, auxOnly: auxOnlyStacks.contains(stack.number), resolving: resolving,
                                              scratch: &scratch))
        }
        plan.channelPasses = scratch.channelPasses.keys.sorted().compactMap { channel in
            guard var pass = scratch.channelPasses[channel] ?? nil else { return nil }
            pass.auxOnly = !scratch.liveChannels.contains(channel)
            return pass
        }
        plan.textJobs = scratch.jobs
        for output in machine.outputs where pacing.isSinkDue(output: output.number, tick: frame) {
            if let pass = sinkPass(output, frame: frame) { plan.sinkPasses.append(pass) }
        }
        // Spec 4 §10 — previews "at most 30 times a second": this tick's stack texture into the stack's preview texture.
        if previewTick {
            for stack in machine.stacks where rendering.contains(stack.number) {
                guard let target = previewTargets[stack.number], let ring = stackRings[stack.number] else { continue }
                plan.auxPasses.append(AuxPass(kind: .preview, stack: stack.number, source: ring[Int(frame % Int64(FrameRing.depth))], target: target))
            }
        }
        return plan
    }

    /// Spec 4 §7 — the channel pass, once per channel per tick, or nil when the
    /// channel has nothing to draw (text, empty, missing media). A stack that
    /// is not aux-only asking for it makes it live work.
    private func channelPass(_ channel: Int, frame: Int64, auxOnly: Bool, scratch: inout BuildScratch) -> ChannelPass? {
        if !auxOnly { scratch.liveChannels.insert(channel) }
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
                outgoing = SourceBinding(source: .texture(snapshot), layout: .finished, matrix: .bt709, range: .full, size: size)
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
    static func fitQuad(texture: TextureHandle, content: UVRect, contentPixels: PixelSize, into frame: PixelRect, fit: PixelFit,
                        mips: Bool = false) -> PixelQuad {
        let aspect = contentPixels.height > 0 ? Float(contentPixels.width) / Float(contentPixels.height) : 1
        let frameAspect = frame.height > 0 ? frame.width / frame.height : 1
        switch fit {
        case .stretch:
            return PixelQuad(texture: texture, frame: frame, uv: content, mips: mips)
        case .fit:
            var w = frame.width
            var h = frame.height
            if aspect > frameAspect { h = frame.width / aspect } else { w = frame.height * aspect }
            let rect = PixelRect(x: frame.x + (frame.width - w) / 2, y: frame.y + (frame.height - h) / 2, width: w, height: h)
            return PixelQuad(texture: texture, frame: rect, uv: content, mips: mips)
        case .fill:
            var uv = content
            if aspect > frameAspect {
                let keep = frameAspect / aspect
                uv = UVRect(u: content.u + content.width * (1 - keep) / 2, v: content.v, width: content.width * keep, height: content.height)
            } else {
                let keep = aspect / frameAspect
                uv = UVRect(u: content.u, v: content.v + content.height * (1 - keep) / 2, width: content.width, height: content.height * keep)
            }
            return PixelQuad(texture: texture, frame: frame, uv: uv, mips: mips)
        case .crop:
            let cw = Float(contentPixels.width)
            let ch = Float(contentPixels.height)
            let w = min(cw, frame.width)
            let h = min(ch, frame.height)
            let rect = PixelRect(x: frame.x + (frame.width - w) / 2, y: frame.y + (frame.height - h) / 2, width: w, height: h)
            let uv = UVRect(u: content.u + content.width * (cw - w) / (2 * max(1, cw)), v: content.v + content.height * (ch - h) / (2 * max(1, ch)),
                            width: content.width * w / max(1, cw), height: content.height * h / max(1, ch))
            return PixelQuad(texture: texture, frame: rect, uv: uv, mips: mips)
        }
    }

    /// Spec 3 §7 — "Lookahead for offset boxes. Start from the live ShowState
    /// and fold the next K cues from the pointer": the state a box at +K
    /// draws, nil past the end of the playlist. Folded once per build, each
    /// step from the one before, only as far as a due box asks (+3, and +4 for
    /// the text one cue beyond, Spec 6 §3).
    private func lookaheadState(_ steps: Int, frame: Int64, scratch: inout BuildScratch) -> ShowState? {
        guard steps > 0 else { return model.state }
        if steps <= scratch.lookahead.count { return scratch.lookahead[steps - 1] }
        let context = projectionContext(frame: frame, source: CommandSource(kind: .engine))
        while scratch.lookahead.count < steps {
            let previous: ShowState? = scratch.lookahead.isEmpty ? model.state : scratch.lookahead[scratch.lookahead.count - 1]
            scratch.lookahead.append(previous.flatMap { lookahead($0, steps: 1, context: context) })
        }
        return scratch.lookahead[steps - 1]
    }

    /// Spec 6 §5 — what one build resolves variables with: the roots a
    /// context value is read through, and the readings that "read the same in
    /// every state".
    struct Resolving {
        var roots: VariableRoots
        var clock: VariableClock
    }

    /// Spec 6 §6 — the timers as they read at `frame` (Area 11's timers come
    /// with its fourth step; until then every timer is unset).
    func timerReadings(at frame: Int64) -> [Int: TimerReading] {
        [:]
    }

    /// Spec 6 §5 — a text box's variables resolved in the state being drawn,
    /// each format outside the set logged once per box.
    private func resolveText(_ template: SlotResolver.BoxTemplate, key: BoxKey, state: ShowState, resolving: Resolving) -> ResolvedText {
        let resolved = variables.resolve(template.raw, state: state, scope: template.scope, roots: resolving.roots, clock: resolving.clock)
        if !resolved.issues.isEmpty { variables.log(resolved.issues, box: key, to: log) }
        return resolved
    }

    /// Spec 4 §9 — one stack pass: "compositing its slots bottom to top". The
    /// slots resolve through `SlotResolver`, shared with the thumbnail job;
    /// the box transitions, the variable gate and the lookahead are the live
    /// plan's own.
    private func stackPass(_ stack: Stack, frame: Int64, auxOnly: Bool, resolving: Resolving, scratch: inout BuildScratch) -> StackPass {
        let size = geometry.stackSize(stack.number)
        let target = stackRings[stack.number]?[Int(frame % Int64(FrameRing.depth))] ?? .none
        let inputs = SlotResolver.Inputs(library: library, machine: machine, kept: kept, stack: stack, size: size,
                                         muted: model.state.stacks[stack.number]?.muted ?? [], text: text)
        var boxes: [ResolvedBox] = []
        for (slotIndex, slot) in stack.effectiveSlots(library: library).enumerated() {
            // Spec 4 §8 — "Lookahead pre-rasterizes, for every due stack, the next cue's text and, for each
            // offset box, the text one cue beyond its offset".
            for offset in SlotResolver.offsets(of: inputs.layout(for: slot)) where Box.drawnOffsets.contains(offset) {
                if let after = lookaheadState(offset + 1, frame: frame, scratch: &scratch) {
                    prefetchText(inputs: inputs, slot: slot, offset: offset, state: after, resolving: resolving)
                }
            }
            let results = SlotResolver.resolve(
                inputs, slotIndex: slotIndex, slot: slot,
                // Spec 6 §3 — "At 0 the box draws its slot's channel as it is now. At +K it draws the channel as
                // it will be once the next K cues have fired"; the resolver draws nothing outside 0 to +3.
                state: { offset in lookaheadState(offset, frame: frame, scratch: &scratch) },
                pixels: { slot, offset, content in pixelSource(for: slot, offset: offset, content: content, frame: frame, auxOnly: auxOnly, scratch: &scratch) },
                text: { key, box, template, shown in
                    // Spec 6 §5 — the values read the state being drawn: the live state, or the lookahead state
                    // of an offset box. Spec 6 §4 — tabular digits for a clock, a timer or a popup that names one.
                    let resolved = resolveText(template, key: key, state: shown, resolving: resolving)
                    let now = SlotResolver.BoxText(text: resolved.text, tabular: resolved.tabular)
                    guard resolved.hasVariables, case .static = box.binding.kind else { return now }
                    return adoptedVariableValue(key, resolved: now, box: box, frame: frame, frameRect: PixelRect(box.frame, in: size), size: size)
                },
                onTextMiss: { job in
                    scratch.jobs.append(job)
                    textLateThisBuild += 1
                })
            for result in results {
                guard var box = result.resolved else {
                    endBox(result.key, frame: frame, box: result.box, slot: slot, inputs: inputs, into: &boxes)
                    continue
                }
                box.transition = boxTransition(result.key, content: box.content, text: box.text, box: result.box, offset: result.box.offset,
                                               allowed: result.transitionAllowed, frame: frame)
                boxes.append(box)
            }
        }
        return StackPass(stack: stack.number, target: target, size: size, base: stack.base, gammaBlend: stack.gammaBlend, boxes: boxes, auxOnly: auxOnly)
    }

    /// Spec 4 §9 — what a pixel box draws: at offset 0 the channel texture
    /// through its pass; for an offset box "a pixel box points at the pool
    /// item's poster frame texture" (Spec 6 §3, "An offset box shows a still").
    private func pixelSource(for slot: StackSlot, offset: Int, content: ContentInstance?, frame: Int64, auxOnly: Bool,
                             scratch: inout BuildScratch) -> SlotResolver.PixelSource? {
        if offset == 0 {
            guard let pass = channelPass(slot.channel, frame: frame, auxOnly: auxOnly, scratch: &scratch) else { return nil }
            let bound = pass.incoming.source == .none ? (pass.outgoing ?? pass.incoming) : pass.incoming
            return SlotResolver.PixelSource(texture: pass.target, content: ControlLoop.contentRect(source: bound.size, channel: pass.size),
                                            contentPixels: bound.size, mips: pass.generateMips)
        }
        guard let media = content?.media, !media.missing,
              let entry = MediaResolver.resolve(media.ref, library: library, machine: machine)?.entry else { return nil }
        let poster = posters.poster(for: entry)
        guard !poster.isNone else { return nil }
        return SlotResolver.PixelSource(texture: poster, content: .full, contentPixels: PixelSize(width: entry.width ?? 16, height: entry.height ?? 9))
    }

    /// Spec 6 §3 — "The engine rasterizes the text one cue beyond each offset
    /// box ahead of time ... so a `next` never waits on text": the text boxes
    /// at `offset` with the text they will draw one cue later, in `state`, its
    /// variables resolved there (Spec 6 §5). A static box without variables
    /// draws the same text in every state, already cached.
    private func prefetchText(inputs: SlotResolver.Inputs, slot: StackSlot, offset: Int, state: ShowState, resolving: Resolving) {
        guard let layout = inputs.layout(for: slot) else { return }
        for box in layout.boxes where box.offset == offset {
            let template: SlotResolver.BoxTemplate
            switch box.binding.kind {
            case .field(let name):
                guard let raw = SlotResolver.fieldValue(name, channel: slot.channel, state: state, inputs: inputs), !raw.isEmpty else { continue }
                template = SlotResolver.BoxTemplate(raw: raw, scope: .content(channel: slot.channel))
            case .static(let raw):
                guard VariableText.parse(raw).hasVariables else { continue }
                template = SlotResolver.BoxTemplate(raw: raw, scope: .pointer)
            case .pixels:
                continue
            }
            // The box logs its own formats outside the set when it draws (Spec 6 §5).
            let resolved = variables.resolve(template.raw, state: state, scope: template.scope, roots: resolving.roots, clock: resolving.clock)
            guard !resolved.text.isEmpty else { continue }
            let job = SlotResolver.textJob(resolved.text, box: box, frame: PixelRect(box.frame, in: inputs.size), outputHeight: inputs.size.height,
                                           tabular: resolved.tabular)
            if text.entry(for: job) == nil { text.request(job) }
        }
    }

    /// Spec 4 §8 — "A box whose text contains variables is re-laid-out only
    /// when its resolved text changes, and no more than once a second; the
    /// result replaces the cache entry." The box keeps the value it adopted
    /// until the resolved text differs and the wall-clock second has moved on
    /// (Area 5 reading, approved 2026-11-03: the second is the one the variable
    /// provider reads for `[Time]`, so a seconds clock never skips a value on a
    /// fractional master rate). A first value and a clear are not re-layouts
    /// and show at once. The previous raster goes when a value is adopted, its
    /// textures freed once any box transition between the two has run.
    private func adoptedVariableValue(_ key: BoxKey, resolved: SlotResolver.BoxText, box: Box, frame: Int64, frameRect: PixelRect,
                                      size: PixelSize) -> SlotResolver.BoxText {
        var run = model.boxRuns[key] ?? BoxRun()
        defer { model.boxRuns[key] = run }
        let second = variables.currentSecond
        // Spec 6 §4 — the flag goes with the text it was adopted with, so the raster drawn and the one released
        // are the ones the cache holds.
        guard let adopted = run.adoptedText else {
            run.adoptedText = resolved.text
            run.adoptedTabular = resolved.tabular
            run.adoptedSecond = second
            return resolved
        }
        let held = SlotResolver.BoxText(text: adopted, tabular: run.adoptedTabular)
        guard held != resolved else { return held }
        if !adopted.isEmpty, !resolved.text.isEmpty, second == run.adoptedSecond { return held }
        if !adopted.isEmpty {
            let ms = box.transition.ms ?? library.transition(box.transition.ref)?.ms ?? 0
            text.release(SlotResolver.textJob(adopted, box: box, frame: frameRect, outputHeight: size.height, tabular: run.adoptedTabular).key,
                         afterTick: frame + pacing.frames(forMs: ms) + Int64(PlanRing.depth))
        }
        run.adoptedText = resolved.text
        run.adoptedTabular = resolved.tabular
        run.adoptedSecond = second
        return resolved
    }

    /// Spec 4 §9 — box transitions; "Offset boxes ... cut rather than
    /// transition" (Spec 6 §3, "the box cuts rather than transitions").
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

    /// A box that no longer draws: if it drew before, its content transitions
    /// out, unless it is a variable box without `transitionOnVariableChange`
    /// (Spec 4 §8: "the rest swap").
    private func endBox(_ key: BoxKey, frame: Int64, box: Box, slot: StackSlot, inputs: SlotResolver.Inputs, into boxes: inout [ResolvedBox]) {
        guard var run = model.boxRuns[key] else { return }
        defer { model.boxRuns[key] = run }
        if run.previousText != nil {
            startBoxRun(&run, from: run.previousContent, box: box, allowed: box.offset == 0 && SlotResolver.transitionAllowed(for: box), frame: frame)
            run.previousContent = nil
            run.previousText = nil
        }
        if let state = run.state(at: frame) {
            let opacity = Float(slot.opacity) * (inputs.muted.contains(slot.channel) ? 0 : 1)
            boxes.append(ResolvedBox(channel: slot.channel, frame: PixelRect(box.frame, in: inputs.size), content: .lines([]), opacity: opacity,
                                     transition: state, grade: SlotResolver.boxGrade(box, library: library), offset: box.offset, binding: box.binding))
        }
    }

    /// Spec 4 §10 — the sink pass with its output transition: "the previous
    /// stack for a switch, black for blackout". An interlaced output's pass
    /// also names the previous tick's stack texture as the first field (and
    /// the old stack's texture of that tick during a switch), with this
    /// tick's mix for both fields (Area 5 reading, approved 2026-11-03).
    private func sinkPass(_ output: Output, frame: Int64) -> SinkPass? {
        let live = model.state.outputs[output.number] ?? output.defaultStack
        guard let ring = stackRings[live] else { return nil }
        let slot = Int(frame % Int64(FrameRing.depth))
        let previousSlot = Int((frame + Int64(FrameRing.depth) - 1) % Int64(FrameRing.depth))
        var second: SecondTexture = .none
        var firstFieldSecond: SecondTexture = .none
        var mix: Float = 0
        let ort = model.outputs[output.number] ?? OutputRuntime()
        if let run = ort.switchRun, !run.isComplete(at: frame), let oldRing = stackRings[run.oldStack] {
            second = .stack(oldRing[slot])
            firstFieldSecond = .stack(oldRing[previousSlot])
            mix = run.oldMix(at: frame)
        }
        let black = ort.blackout.map { $0.mix(at: frame) } ?? ort.blackoutMix
        if black > 0 {
            second = .black
            firstFieldSecond = .black
            mix = black
        }
        let interlaced = pacing.isInterlaced(output: output.number)
        var encode = encodeKinds[output.number] ?? (output.kind == .sdi ? .v210 : .display10Bit)
        if interlaced, encode == .v210 { encode = .v210Interlaced }
        let firstField = interlaced && frame > 0 ? FieldSources(stack: ring[previousSlot], second: firstFieldSecond) : nil
        return SinkPass(output: output.number, stack: ring[slot], second: second, mix: mix, encode: encode, destination: slot, firstField: firstField)
    }
}
