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
    case noScreens
    case missingArgument(String)
    case badArgument(String, String)

    public var description: String {
        switch self {
        case .noScreens: return "no screens: a display output needs one"
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
    public var libraryReport: ValidationReport
    public var machineReport: ValidationReport
    public var librarySnapshot: RootSnapshot
    public var machineSnapshot: RootSnapshot

    public static func load(libraryRoot: URL, machineRoot: URL) throws -> LoadedRoots {
        let librarySnapshot = try LocalFiles.snapshot(ofRoot: libraryRoot)
        let machineSnapshot = try LocalFiles.snapshot(ofRoot: machineRoot)
        let (library, libraryReport) = Loader.library(from: librarySnapshot)
        let (machine, machineReport) = Loader.machine(from: machineSnapshot)
        let mediaRoot = URL(fileURLWithPath: machine.settings.mediaRoot, relativeTo: machineRoot).standardizedFileURL
        return LoadedRoots(library: library, machine: machine, libraryRoot: libraryRoot, machineRoot: machineRoot, mediaRoot: mediaRoot,
                           libraryReport: libraryReport, machineReport: machineReport,
                           librarySnapshot: librarySnapshot, machineSnapshot: machineSnapshot)
    }

    public var issueLines: [String] { libraryReport.lines + machineReport.lines }
    public var hasErrors: Bool { (libraryReport.issues + machineReport.issues).contains { $0.severity == .error } }
    public var mediaIDs: Set<String> { Set(library.mediaIndex.entries.map(\.id) + machine.mediaLocal.entries.map(\.id)) }
}

/// Spec 4 §15 — the `oengine` process: the Metal backend, a display sink per
/// display output on its screen, a DeckLink sink per SDI output, the master
/// clock (the DeckLink clock when the card is there, else the display link,
/// with the timer as the last fallback, Spec 4 §2), the real sources, posters
/// and text cache, the audio graph on the machine's device, the OSC server on
/// the machine's port with feedback to its targets, and the black box.
public final class EngineProcess: @unchecked Sendable {
    public struct Options: Sendable {
        public var oscPort: Int?
        public var blackBoxFolder: URL?
        public var audio = true

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

        // Sinks, one per output (Spec 4 §10).
        let screens = NSScreen.screens
        var sinks: [any OutputSink] = []
        var displays: [DisplaySink] = []
        var deckLinks: [DeckLinkSink] = []
        var displayIndex = 0
        for output in machine.outputs.sorted(by: { $0.number < $1.number }) {
            switch output.kind {
            case .display:
                guard !screens.isEmpty else { throw ProcessError.noScreens }
                let screen = EngineProcess.screen(for: output, index: displayIndex, screens: screens)
                displayIndex += 1
                let sink = DisplaySink(output: output.number, screen: screen, backend: backend, log: log)
                displays.append(sink)
                sinks.append(sink)
                log.info("output \(output.number) (\(output.label)) on screen \(screen.localizedName)")
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

        // Clocks (Spec 4 §2): DeckLink hardware when present, else the display link, then the timer.
        let timer = TimerClock()
        var master: any MasterClock = timer
        var fallbacks: [any MasterClock] = []
        if let screen = screens.first {
            let displayLink = DisplayLinkClock(screen: screen)
            master = displayLink
            fallbacks = [timer]
            if DeckLinkSink.sdkAvailable, let first = deckLinks.first {
                try first.start()
                if let clock = first.clock {
                    master = clock
                    fallbacks = [displayLink, timer]
                }
            }
        }

        // Sources, posters, text, variables (Spec 4 §6, §8).
        let sourceFactory = MediaSourceFactory(backend: backend, log: log)
        let posters = ImagePosterProvider(backend: backend, mediaRoot: roots.mediaRoot, log: log)
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

        engine = try Engine(library: library, machine: machine, mediaRoot: roots.mediaRoot, backend: backend, clock: master,
                            fallbackClocks: fallbacks, sinks: sinks, sourceFactory: sourceFactory, posters: posters, text: textCache,
                            variables: variables, audio: system, log: log)
        // Spec 5 §2 — edits are written to the roots they were loaded from.
        engine.control.attachDocuments(libraryRoot: roots.libraryRoot, machineRoot: roots.machineRoot,
                                       librarySnapshot: roots.librarySnapshot, machineSnapshot: roots.machineSnapshot)
        let control = engine.control
        watcher = DiskWatcher(libraryRoot: roots.libraryRoot, machineRoot: roots.machineRoot) { control.requestScan() }
        // Spec 4 §10 — the thumbnail job, its PNGs under the machine root (Area 5 reading: `thumbnails/`).
        do {
            engine.thumbnails = try ThumbnailService(library: library, machine: machine, mediaRoot: roots.mediaRoot, backend: backend, posters: posters,
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

        server.queryHandler = { [weak self] address in self?.answer(query: address) }
        // Spec 5 §2 — feedback reads the roots as the edits left them.
        engine.afterBuild = { [server] control in
            server.afterBuild(control, library: control.library, machine: control.machine)
        }
    }

    /// The screen an output names (`display:<uuid>`), else the next screen in
    /// order; with fewer screens than display outputs the last ones share.
    @MainActor
    static func screen(for output: Output, index: Int, screens: [NSScreen]) -> NSScreen {
        if output.device.hasPrefix("display:") {
            let wanted = String(output.device.dropFirst("display:".count)).uppercased()
            if let match = screens.first(where: { displayUUID(of: $0)?.uppercased() == wanted }) { return match }
        }
        return screens[min(index, screens.count - 1)]
    }

    @MainActor
    static func displayUUID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    // MARK: - Lifecycle

    public func start() {
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

    /// Spec 4 §13 — the live summary, now; empty before the black box starts.
    public func metricsSnapshot() -> MetricsSnapshot {
        let uptime = Int((MonotonicClock.now().nanoseconds - startedAt.nanoseconds) / 1_000_000_000)
        return engine.recorder?.snapshot(uptimeSeconds: uptime) ?? MetricsSnapshot(tickNanoseconds: engine.pacing.tickNanoseconds)
    }

    public func stop() {
        watcher.stop()
        engine.stop()
        osc?.stop()
    }

    /// Spec 2 §6 — "/o/query with an address": the current value of a feedback
    /// address; Spec 4 §13 — the `metrics` summary at `/o/metrics` (Area 5
    /// reading) until the API carries the topic.
    func answer(query address: String) -> OSCMessage? {
        if address == MetricsQuery.address { return MetricsQuery.answer(address, snapshot: metricsSnapshot()) }
        // Spec 7 §6 — the live position and the countdown, as the last build read them.
        let published = engine.control.publishedLive
        if let live = published.live.answer(query: address, frame: published.frame, rate: engine.pacing.masterRate) { return live }
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
            let library = engine.control.publishedRoots.library
            return state.channels[number].map {
                OSCFeedback.channelContent(number, kind: $0.content.kind, label: OSCFeedbackDeriver.label(of: $0.content, library: library))
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
