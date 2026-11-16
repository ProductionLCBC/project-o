// OEngine — Spec 4 §15, "a headless OEngine process driven over OSC, with
// the fixture library from Spec 1 on disk": the engine assembled from a
// library root and a machine root over the real backend, clocks, sinks and
// devices.

import AppKit
import Foundation
import OCore
import OFormats
import Synchronization

public enum ProcessError: Error, CustomStringConvertible {
    case missingArgument(String)
    case badArgument(String, String)

    public var description: String {
        switch self {
        case .missingArgument(let name): return "missing \(name)"
        case .badArgument(let name, let value): return "bad value for \(name): \(value)"
        }
    }
}

/// Spec 1 §2 — the two roots loaded through OFormats, with their reports and
/// the snapshots they were loaded from, which the writer starts from (Spec 5 §2).
public struct LoadedRoots: Sendable {
    public var library: Library
    public var machine: Machine
    public var libraryRoot: URL
    public var machineRoot: URL
    public var mediaRoot: URL
    /// Spec 8 §2 — the media root and `machine/media/`, which locations read against.
    public var media: MediaFolders
    public var libraryReport: ValidationReport
    public var machineReport: ValidationReport
    public var librarySnapshot: RootSnapshot
    public var machineSnapshot: RootSnapshot

    /// Spec 1 §5 — both roots read; Spec 8 §2 — with `places`, a media root
    /// where media may not live isn't read (the engine process gives this
    /// Mac's; tests read media wherever their copies are).
    public static func load(libraryRoot: URL, machineRoot: URL, places: MediaPlaces? = nil) throws -> LoadedRoots {
        let librarySnapshot = try LocalFiles.snapshot(ofRoot: libraryRoot)
        let machineSnapshot = try LocalFiles.snapshot(ofRoot: machineRoot)
        let (library, libraryReport) = Loader.library(from: librarySnapshot)
        let (machine, machineReport) = Loader.machine(from: machineSnapshot)
        let media = MediaFolders.of(machineRoot: machineRoot, settings: machine.settings, places: places)
        let mediaRoot = media.mediaRoot ?? URL(fileURLWithPath: machine.settings.mediaRoot, relativeTo: machineRoot).standardizedFileURL
        return LoadedRoots(library: library, machine: machine, libraryRoot: libraryRoot, machineRoot: machineRoot, mediaRoot: mediaRoot, media: media,
                           libraryReport: libraryReport, machineReport: machineReport,
                           librarySnapshot: librarySnapshot, machineSnapshot: machineSnapshot)
    }

    public var issueLines: [String] { libraryReport.lines + machineReport.lines }
    public var hasErrors: Bool { (libraryReport.issues + machineReport.issues).contains { $0.severity == .error } }
    /// Spec 2 §2 — the ids an abbreviated hash expands against: every id the
    /// two indexes name, their `replaced` maps included (Spec 8 §2).
    public var mediaIDs: Set<String> { MediaResolver.knownIds(library: library.mediaIndex, machine: machine.mediaLocal) }
}

/// Spec 4 §15 — the `oengine` process: the Metal backend, a display sink per
/// display output, on its own screen or waiting for it (Spec 10 §2), a
/// DeckLink sink per SDI output, the master clock (the DeckLink clock when
/// the card is there, else the display link of the first display output with
/// a screen, with the timer as the last fallback, Spec 4 §2), the real
/// sources, posters and text cache, the audio graph on the machine's device,
/// the OSC server on the machine's port with feedback to its targets, and the
/// black box.
public final class EngineProcess: @unchecked Sendable {
    public struct Options: Sendable {
        public var oscPort: Int?
        public var blackBoxFolder: URL?
        public var audio = true
        /// Spec 10 §2 — whether this launch is a relaunch; Area 19 sets it
        /// from `--relaunch` and from how the last run ended in this boot.
        public var relaunch = false
        /// Spec 10 §2 — "`--released display:<uuid>` for each screen [the
        /// app] has released while it runs": screens whose outputs stay
        /// closed from the start of this run.
        public var released: [String] = []

        public init() {}
    }

    public let roots: LoadedRoots
    public let options: Options
    public let log: EngineLog
    public let backend: MetalBackend
    public let engine: Engine
    public let osc: OSCServer?
    public let blackBox: BlackBox?
    public let textCache: TextCache
    public let audio: AudioSystem?
    public let displaySinks: [DisplaySink]
    public let deckLinkSinks: [DeckLinkSink]
    /// Spec 10 §3 — the devices this Mac has, for the `devices` query and topic.
    public let devices: SystemDevices
    /// Spec 10 §2 — the display outputs and the screens they wait for.
    public let displayOutputs: DisplayOutputs
    /// Spec 10 §2 — the activity and the sleep assertion.
    public let power = SystemPower()
    /// Spec 10 §2 — the local socket, once the engine takes commands.
    public private(set) var socket: LocalSocket?
    /// Spec 1 §8 — documents that change on disk under the engine are reloaded.
    public let watcher: DiskWatcher
    private let startedAt = MonotonicClock.now()

    @MainActor
    public init(roots: LoadedRoots, options: Options = Options(), log: EngineLog = EngineLog(category: "process")) throws {
        self.roots = roots
        self.options = options
        self.log = log
        let library = roots.library
        let machine = roots.machine
        backend = try MetalBackend(log: log)
        // Spec 4 §7 — the pipeline cache is built at launch, not on a tick.
        let warmStart = MonotonicClock.now()
        let pipelines = backend.warmUp()
        log.info("warm-up: \(pipelines) channel pipelines in \((MonotonicClock.now() - warmStart) / 1_000_000) ms")

        // Sinks, one per output (Spec 4 §10). Spec 10 §2 — a display output is given its own screen or none:
        // "it never falls back to another screen".
        let devices = SystemDevices()
        self.devices = devices
        let released = Set(options.released.compactMap { DetectedScreen.uuid(ofDevice: $0) })
        var sinks: [any OutputSink] = []
        var displays: [DisplaySink] = []
        var deckLinks: [DeckLinkSink] = []
        for output in machine.outputs.sorted(by: { $0.number < $1.number }) {
            switch output.kind {
            case .display:
                let sink = DisplaySink(output: output.number, device: output.device, backend: backend, log: log)
                displays.append(sink)
                sinks.append(sink)
            case .sdi:
                let id = output.device.hasPrefix("decklink:") ? String(output.device.dropFirst("decklink:".count)) : output.device
                // Spec 4 §10 — the card's embedded channel count from the Audio Outputs on this SDI output.
                let embedded = machine.audioOutputs.filter { $0.device == .sdiOutput(output.number) }.flatMap(\.channels)
                let sink = DeckLinkSink(output: output.number, persistentID: id, format: output.format,
                                        audioChannels: DeckLinkSink.embeddedChannelCount(for: embedded.isEmpty ? [0, 1] : embedded), backend: backend, log: log)
                deckLinks.append(sink)
                sinks.append(sink)
            case .ndi, .multiviewer:
                log.warning("output \(output.number) is \(output.kind.rawValue): not in the spike, skipped")
            }
        }
        displaySinks = displays
        deckLinkSinks = deckLinks
        // Spec 10 §2 — each display sink gets the screen its output names, or stays absent; the screens named
        // by `--released` keep their outputs closed. The same rule runs again at every change of screens.
        displayOutputs = DisplayOutputs(sinks: displays, outputs: machine.outputs, devices: devices, released: released, log: log)
        displayOutputs.reconcile()
        displayOutputs.watch()
        for (number, place) in OutputPlacement.places(outputs: machine.outputs, screens: devices.keptScreens, released: released).sorted(by: { $0.key < $1.key }) {
            log.info("output \(number): \(place)")
        }

        // Clocks (Spec 4 §2): DeckLink hardware when present, else the display link of the first display output
        // that has its screen, then the timer. With no output on a screen the engine runs on the timer.
        let timer = TimerClock()
        var master: any MasterClock = timer
        var fallbacks: [any MasterClock] = []
        var displayLink: DisplayLinkClock?
        if let uuid = OutputPlacement.clockScreen(outputs: machine.outputs, screens: devices.keptScreens, released: released),
           let screen = SystemDevices.screen(uuid: uuid) {
            let link = DisplayLinkClock(screen: screen)
            displayLink = link
            master = link
            fallbacks = [timer]
        }
        if DeckLinkSink.sdkAvailable, let first = deckLinks.first {
            try first.start()
            if let clock = first.clock {
                master = clock
                fallbacks = displayLink.map { [$0 as any MasterClock, timer] } ?? [timer]
            }
        }

        // Sources, posters, text, variables (Spec 4 §6, §8). Spec 6 §4 — the bundled fonts are registered "at
        // launch and before the first raster".
        let sourceFactory = MediaSourceFactory(backend: backend, log: log)
        // Spec 4 §5 — "Half the channel render size": half the largest channel's, loaded off the control thread.
        let geometry = MachineGeometry(library: library, machine: machine)
        let posters = ImagePosterProvider(backend: backend, media: roots.media,
                                          fit: ImagePosterProvider.fit(channels: library.channels.map { geometry.channelSize($0.number) }), log: log)
        FontLibrary.shared.register(log: log)
        textCache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: machine.settings.fallbackFont), backend: backend, log: log)
        let variables = VariableProvider(settings: machine.settings)

        // Audio (Spec 4 §11): one graph per distinct device over the HAL factory, and one per SDI-embedded
        // output over its DeckLink sink; a device absent at launch gets its fallback or silence (Spec 4 §12).
        var system: AudioSystem?
        if options.audio, !machine.audioOutputs.isEmpty {
            var destinations: [Int: any StreamAudioDestination] = [:]
            for sink in deckLinks { destinations[sink.output] = sink }
            system = AudioSystem(outputs: machine.audioOutputs, factory: HALAudioDeviceFactory(log: log), destinations: destinations, log: log)
        }
        audio = system

        // Spec 8 §4 — the machine's hash cache, which the launch's look at each location reads.
        let mediaCache = LocalFiles.mediaCache(machineRoot: roots.machineRoot)
        engine = try Engine(library: library, machine: machine, media: roots.media, backend: backend, clock: master,
                            fallbackClocks: fallbacks, sinks: sinks, sourceFactory: sourceFactory, posters: posters, text: textCache,
                            variables: variables, audio: system, mediaCache: mediaCache, log: log)
        // Spec 5 §2 — edits are written to the roots they were loaded from.
        engine.control.attachDocuments(libraryRoot: roots.libraryRoot, machineRoot: roots.machineRoot,
                                       librarySnapshot: roots.librarySnapshot, machineSnapshot: roots.machineSnapshot)
        let control = engine.control
        // Spec 8 §2 — the media worker; Spec 8 §3 — the app's staging folder, which the engine empties at launch.
        let staging = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Project O/Staging", isDirectory: true)
        let render = engine.render
        let worker = MediaWorker(folders: roots.media, machineRoot: roots.machineRoot, staging: staging,
                                 seams: .live(blocked: { render.isSkippingAux }), log: log)
        control.attachMedia(worker)
        let mediaFolders = [roots.media.mediaRoot, roots.media.machineMedia].compactMap { $0 }
        watcher = DiskWatcher(libraryRoot: roots.libraryRoot, machineRoot: roots.machineRoot, media: mediaFolders,
                              onChange: { control.requestScan() }, onMedia: { worker.requestWalk() })
        // Spec 4 §10 — the thumbnail job, its PNGs under the machine root (Area 5 reading: `thumbnails/`).
        do {
            engine.thumbnails = try ThumbnailService(library: library, machine: machine, media: roots.media, backend: backend, posters: posters,
                                                     variables: variables, cacheFolder: roots.machineRoot.appendingPathComponent("thumbnails"), log: log)
        } catch {
            log.error("thumbnails are off: \(error)")
        }

        // OSC (Spec 2 §6) and the black box (Spec 4 §13).
        let port = options.oscPort ?? machine.settings.network.oscInPort
        let engine = self.engine
        let server = OSCServer(port: UInt16(clamping: port), targets: machine.settings.network.oscOutTargets, mediaIDs: roots.mediaIDs,
                               log: log) { group in engine.enqueue(group) }
        osc = server
        blackBox = options.blackBoxFolder.map { BlackBox(folder: $0) }
        // Spec 9 §7 — the black box pauses its tick and present lines on a low disk and stops on a full one.
        blackBox?.status = engine.diskStatus

        server.queryHandler = { [weak self] address in self?.answer(query: address) }
        // Spec 5 §2 — feedback reads the roots as the edits left them.
        engine.afterBuild = { [server] control in
            server.afterBuild(control, library: control.library, machine: control.machine)
        }
    }

    // MARK: - Lifecycle

    public func start() {
        // Spec 10 §2 — "It holds a latency-critical activity so macOS never naps or throttles it, and while any
        // output presents it keeps the displays and the system from sleeping."
        let outputPower = OutputPower(power: power)
        outputPower.begin()
        engine.power = outputPower
        // Spec 9 §4 — the launch order, on the roots this process loaded: the logs open and the run's `start`
        // note is written before anything can send a command ("The engine takes commands from step 5 on").
        engine.launch(LaunchOptions(machineRoot: roots.machineRoot, relaunch: options.relaunch))
        // Spec 10 §3 — the `devices` topic, "On subscribe and when a screen, a card or an audio device comes or goes",
        // and the `metrics` topic's summary (Spec 4 §13), which is the process's to give.
        let listed = engine
        listed.deviceLister = devices
        listed.metricsSource = { [weak self] in self?.metricsSnapshot() ?? MetricsSnapshot(tickNanoseconds: listed.pacing.tickNanoseconds) }
        let outputs = displayOutputs
        DispatchQueue.main.async { MainActor.assumeIsolated { outputs.onChange = { listed.devicesChanged() } } }
        devices.watchAudio { listed.devicesChanged() }
        listed.devicesChanged()
        // Spec 10 §2 — "opens its local socket ... at that list's step 5, when it takes commands, so `hello` means it
        // is ready."
        openSocket()
        if let osc {
            do { try osc.start() } catch { log.error("OSC did not start: \(error)") }
        }
        // Spec 1 §8 — the watcher, and one scan for anything that changed between the load and the watch.
        if !watcher.start() { log.error("the folder watcher did not start: changes on disk are read at the next launch") }
        engine.control.requestScan()
        let engine = self.engine
        let textCache = self.textCache
        let audio = self.audio
        let deckLinks = deckLinkSinks
        // Spec 4 §13 — the minute record's breakdown: "the resource table's texture bytes, the decoder pools' bytes,
        // the text cache's bytes and the readback buffers' bytes".
        let sources = BlackBoxRecorder.MinuteSources(
            decoderSessions: { engine.sources.liveCount },
            textCacheHitRate: { textCache.statistics.hitRate },
            audioUnderruns: { Int(audio?.underruns ?? 0) },
            watchdogEvents: { engine.watchdog.events },
            watchdogRecoveries: { engine.watchdog.recoveries },
            textureBytes: { Int(engine.backend.resources.allocatedBytes) },
            decoderPoolBytes: { engine.sources.poolBytes },
            textCacheBytes: { textCache.statistics.bytes },
            readbackBytes: { ((engine.backend as? MetalBackend)?.lastGoodStagingBytes ?? 0) + deckLinks.reduce(0) { $0 + $1.readbackBytes } },
            // Spec 4 §12, §13 (Area 5) — the thumbnail cache's hit rate, the substitutions, the thermal and memory-pressure states.
            thumbnailCacheHitRate: { engine.thumbnails?.statistics.hitRate ?? 1 },
            fontSubstitutions: { textCache.statistics.substitutedFonts },
            thermalState: { engine.thermal.level },
            memoryPressure: { engine.pressure.level },
            // Spec 4 §13 (Area 16) — "audio underruns per device" and the devices' standings (Spec 4 §12).
            audioUnderrunsByDevice: { audio?.underrunsByDevice.mapValues { Int($0) } ?? [:] },
            audioDevices: { audio?.deviceStates ?? [] })
        engine.start(blackBox: blackBox, minuteSources: sources)
    }

    /// Spec 10 §2 — the local socket: each connection that passes the peer check joins the API's hub, which greets
    /// it with `hello`. Spec 10 §3 — the requests that reach past the engine: `stop` and `releaseScreen`.
    private func openSocket() {
        let hub = engine.api
        hub.identify(ApiHub.Identity(machine: roots.machine.settings.uuid, run: engine.run, mach: MachServiceName.engine(run: engine.run)))
        hub.stopEngine = { [weak self] in self?.stop() ?? Engine.StopReport() }
        let outputs = displayOutputs
        hub.releaseScreen = { uuid, done in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outputs.release(screen: uuid)) } }
        }
        let socket = LocalSocket(url: LocalSocket.url(machineRoot: roots.machineRoot), log: log) { transport in
            let connection = hub.accept(transport, origin: .local)
            transport.read(onLine: { [weak connection] line in
                if let connection { hub.receive(line, from: connection) }
            }, onClose: { [weak connection] in
                connection?.close()
            })
        }
        do {
            try socket.start()
            self.socket = socket
        } catch {
            log.error("the local socket did not open: \(error)")
        }
    }

    /// Spec 4 §13 — the live summary, now; empty before the black box starts.
    public func metricsSnapshot() -> MetricsSnapshot {
        let uptime = Int((MonotonicClock.now().nanoseconds - startedAt.nanoseconds) / 1_000_000_000)
        return engine.recorder?.snapshot(uptimeSeconds: uptime) ?? MetricsSnapshot(tickNanoseconds: engine.pacing.tickNanoseconds)
    }

    /// Spec 9 §4 — the stop on request, with what it couldn't write: the
    /// answer to the request that stopped the engine (Spec 10 §3's `stop`).
    @discardableResult
    public func stop() -> Engine.StopReport {
        watcher.stop()
        let outputs = displayOutputs
        if Thread.isMainThread {
            MainActor.assumeIsolated { outputs.stopWatching() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { outputs.stopWatching() } }
        }
        // No new connection once the stop has begun; the ones open stay, for the answer to the request that stopped it.
        socket?.stop()
        let report = engine.stop()
        osc?.stop()
        return report
    }

    /// Spec 2 §6 — "/o/query with an address": the current value of a feedback
    /// address; Spec 4 §13 — the `metrics` summary at `/o/metrics` (Area 5
    /// reading) until the API carries the topic.
    func answer(query address: String) -> OSCMessage? {
        if address == MetricsQuery.address { return MetricsQuery.answer(address, snapshot: metricsSnapshot()) }
        // Spec 7 §6 — the live position and the countdown, as the last build read them.
        let published = engine.control.publishedLive
        if let live = published.live.answer(query: address, frame: published.frame, rate: engine.pacing.masterRate) { return live }
        // Spec 6 §8 — the timers, the popups and a channel's remaining time.
        if let variable = engine.control.answerVariables(query: address) { return variable }
        let state = engine.control.publishedState
        let parts = address.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == "o", let number = Int(parts[2]) else { return nil }
        switch (parts[1], parts.count > 3 ? parts[3] : "") {
        case ("output", "stack"):
            return state.outputs[number].map { OSCFeedback.outputStack(number, stack: $0) }
        case ("stack", "blackout"):
            return state.stacks[number].map { OSCFeedback.stackBlackout(number, on: $0.blackout) }
        case ("channel", "state"):
            return state.channels[number].map { OSCFeedback.channelState(number, OSCFeedbackDeriver.feedbackState(of: $0.content)) }
        case ("channel", "content"):
            let roots = engine.control.publishedRoots
            return state.channels[number].map {
                OSCFeedback.channelContent(number, kind: $0.content.kind, label: OSCFeedbackDeriver.label(of: $0.content, library: roots.library, machine: roots.machine))
            }
        case ("lock", ""):
            return state.channels[number].map { OSCFeedback.lock(number, locked: $0.lock) }
        default:
            return nil
        }
    }

    // MARK: - Reporting

    /// What the run did, in lines: the clock, the tick totals and GPU p99, each
    /// sink, audio, the watchdog, the text cache and OSC.
    public func summary() -> String {
        var lines: [String] = []
        let seconds = Double(MonotonicClock.now().nanoseconds - startedAt.nanoseconds) / 1e9
        let rate = engine.pacing.masterRate
        lines.append("ran \(String(format: "%.0f", seconds)) s on the \(engine.scheduler?.activeClock.name ?? engine.clock.name) clock at \(rate.num)/\(rate.den)")
        if let recorder = engine.recorder {
            let s = recorder.liveSummary
            lines.append("ticks \(s.ticks), plan reused \(s.planReused), text late \(s.textLate), aux skipped \(s.auxSkipped), video repeats \(s.videoRepeats), GPU failures \(s.gpuFailures), GPU p99 \(String(format: "%.2f", Double(s.p99GPUNanoseconds) / 1e6)) ms (\(String(format: "%.0f", s.p99Fraction * 100))% of the tick), CPU encode p99 \(String(format: "%.2f", Double(s.cpuP99Nanoseconds) / 1e6)) ms")
            for output in s.outputs {
                lines.append("output \(output.output): presented \(output.presented), re-presented \(output.rePresented), dropped \(output.dropped), displayed late \(output.displayedLate), present latency p50 \(String(format: "%.2f", Double(output.latencyP50Ns) / 1e6)) ms, p99 \(String(format: "%.2f", Double(output.latencyP99Ns) / 1e6)) ms")
            }
        } else {
            lines.append("ticks \(engine.render.totalTicks), video repeats \(engine.render.totalRepeats), GPU failures \(engine.render.gpuFailures)")
        }
        for sink in displaySinks {
            let state = sink.currentState
            lines.append("display output \(sink.output): \(state.phase), presented \(state.presented), re-presented \(state.rePresented), dropped \(state.drops)\(sink.usesEightBitFallback ? ", 8-bit fallback" : "")")
        }
        for sink in deckLinkSinks {
            lines.append("DeckLink output \(sink.output) (\(sink.persistentID)): \(sink.currentPhase)")
        }
        if let audio {
            for state in audio.deviceStates {
                let standing = state.standing == .primary ? "" : (state.standIn.map { " on fallback \($0)" } ?? " silent")
                lines.append("audio device \(state.device) (outputs \(state.outputs.map(String.init).joined(separator: ", "))): \(state.standing.rawValue)\(standing), underruns \(state.underruns)")
            }
            if audio.deviceStates.isEmpty { lines.append("audio: no outputs") }
        } else {
            lines.append("audio: off")
        }
        lines.append("watchdog: events \(engine.watchdog.events), recoveries \(engine.watchdog.recoveries + Int(engine.recoveries)); clock fallbacks \(engine.scheduler?.fallbacks ?? 0), free-run ticks \(engine.scheduler?.freeRunTicks ?? 0)")
        let text = textCache.statistics
        lines.append("text cache: hit rate \(String(format: "%.3f", text.hitRate)), rasterized \(text.rasterized), evicted \(text.evicted), failed \(text.failed), shrunk \(text.shrinks) times, \(text.bytes / 1_048_576) MB" + (textCache.fontSubstitutions.isEmpty ? "" : "; font substitutions: \(textCache.fontSubstitutions.map(\.description).joined(separator: ", "))"))
        lines.append("pressure: memory \(engine.pressure.level.rawValue) (\(engine.pressure.changes) changes), thermal \(engine.thermal.level.rawValue) (\(engine.thermal.changes) changes)")
        if let thumbnails = engine.thumbnails {
            let t = thumbnails.statistics
            lines.append("thumbnails: rendered \(t.rendered), served \(t.hits) from memory and \(t.diskHits) from disk, failed \(t.failed), \(thumbnails.bytesInUse / 1_048_576) MB in memory")
        }
        if let osc {
            lines.append("osc: port \(osc.boundPort), received \(osc.received), rejected \(osc.rejected), sent \(osc.sent)")
        }
        let errors = log.recent.filter { $0.level == .error || $0.level == .severe }
        if !errors.isEmpty {
            lines.append("errors logged: \(errors.count); the last: \(errors.suffix(3).map(\.message).joined(separator: " | "))")
        }
        return lines.joined(separator: "\n")
    }
}
