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

/// Spec 1 §2 — the two roots loaded through OFormats, with their reports.
public struct LoadedRoots: Sendable {
    public var library: Library
    public var machine: Machine
    public var libraryRoot: URL
    public var machineRoot: URL
    public var mediaRoot: URL
    public var libraryReport: ValidationReport
    public var machineReport: ValidationReport

    public static func load(libraryRoot: URL, machineRoot: URL) throws -> LoadedRoots {
        let (library, libraryReport) = Loader.library(from: try LocalFiles.snapshot(ofRoot: libraryRoot))
        let (machine, machineReport) = Loader.machine(from: try LocalFiles.snapshot(ofRoot: machineRoot))
        let mediaRoot = URL(fileURLWithPath: machine.settings.mediaRoot, relativeTo: machineRoot).standardizedFileURL
        return LoadedRoots(library: library, machine: machine, libraryRoot: libraryRoot, machineRoot: machineRoot, mediaRoot: mediaRoot,
                           libraryReport: libraryReport, machineReport: machineReport)
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
    public let audio: AudioGraph?
    public let displaySinks: [DisplaySink]
    public let deckLinkSinks: [DeckLinkSink]
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
                let embedded = machine.audioOutputs.first { $0.kind == .sdiEmbedded && $0.device == .sdiOutput(output.number) }
                let sink = DeckLinkSink(output: output.number, persistentID: id, format: output.format, audioChannels: embedded?.channels.count ?? 2,
                                        backend: backend, log: log)
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

        // Audio (Spec 4 §11): one graph on the first `device` output's device; the SDI-embedded outputs belong to the DeckLink sinks.
        var graph: AudioGraph?
        let deviceOutputs = machine.audioOutputs.filter { $0.kind == .device }
        if options.audio, let first = deviceOutputs.first {
            var uid: String?
            if case .uid(let named) = first.device, !named.isEmpty { uid = named }
            if let wanted = uid, HALOutputDevice.deviceID(forUID: wanted) == nil {
                // Spec 4 §12 — "Switch to the Audio Output's configured fallback device if one is set".
                let fallback = first.fallbackDevice.flatMap { HALOutputDevice.deviceID(forUID: $0) == nil ? nil : $0 }
                log.warning("audio output \(first.number): device \(wanted) not found; using \(fallback ?? "the default device")")
                uid = fallback
            }
            graph = AudioGraph(device: HALOutputDevice(uid: uid), outputs: deviceOutputs, log: log)
        }
        audio = graph

        engine = try Engine(library: library, machine: machine, mediaRoot: roots.mediaRoot, backend: backend, clock: master,
                            fallbackClocks: fallbacks, sinks: sinks, sourceFactory: sourceFactory, posters: posters, text: textCache,
                            variables: variables, audio: graph, log: log)

        // OSC (Spec 2 §6) and the black box (Spec 4 §13).
        let port = options.oscPort ?? machine.settings.network.oscInPort
        let engine = self.engine
        let server = OSCServer(port: UInt16(clamping: port), targets: machine.settings.network.oscOutTargets, mediaIDs: roots.mediaIDs,
                               log: log) { group in engine.enqueue(group) }
        osc = server
        blackBox = options.blackBoxFolder.map { BlackBox(folder: $0) }

        server.queryHandler = { [weak self] address in self?.answer(query: address) }
        engine.afterBuild = { [server, library, machine] control in
            let executed = control.lastExecuted
            guard !executed.isEmpty else { return }
            server.feedback(OSCFeedbackDeriver.messages(for: executed, state: control.model.state, library: library, machine: machine))
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
        let engine = self.engine
        let textCache = self.textCache
        let audio = self.audio
        let sources = BlackBoxRecorder.MinuteSources(
            decoderSessions: { engine.sources.liveCount },
            textCacheHitRate: { textCache.statistics.hitRate },
            audioUnderruns: { Int(audio?.underruns ?? 0) },
            watchdogEvents: { engine.watchdog.events },
            watchdogRecoveries: { engine.watchdog.recoveries })
        engine.start(blackBox: blackBox, minuteSources: sources)
    }

    public func stop() {
        engine.stop()
        osc?.stop()
    }

    /// Spec 2 §6 — "/o/query with an address": the current value of a feedback address.
    func answer(query address: String) -> OSCMessage? {
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
            return state.channels[number].map {
                OSCFeedback.channelContent(number, kind: $0.content.kind, label: OSCFeedbackDeriver.label(of: $0.content, library: roots.library))
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
            lines.append("ticks \(s.ticks), plan reused \(s.planReused), text late \(s.textLate), aux skipped \(s.auxSkipped), video repeats \(s.videoRepeats), GPU failures \(s.gpuFailures), GPU p99 \(String(format: "%.2f", Double(s.p99GPUNanoseconds) / 1e6)) ms (\(String(format: "%.0f", s.p99Fraction * 100))% of the tick)")
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
            lines.append("audio: \(audio.device.name), underruns \(audio.underruns)")
        } else {
            lines.append("audio: off")
        }
        lines.append("watchdog: events \(engine.watchdog.events), recoveries \(engine.watchdog.recoveries + Int(engine.recoveries)); clock fallbacks \(engine.scheduler?.fallbacks ?? 0), free-run ticks \(engine.scheduler?.freeRunTicks ?? 0)")
        let text = textCache.statistics
        lines.append("text cache: hit rate \(String(format: "%.3f", text.hitRate)), rasterized \(text.rasterized), evicted \(text.evicted), failed \(text.failed), \(text.bytes / 1_048_576) MB" + (textCache.fontSubstitutions.isEmpty ? "" : "; font substitutions: \(textCache.fontSubstitutions.joined(separator: ", "))"))
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
