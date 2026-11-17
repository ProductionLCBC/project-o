// OApp — Spec 10 §2, the engine found, started, watched and started again.

import Foundation
import OCore

/// Spec 10 §2, "The app and the engine" — "Each outlives the other's crash:
/// if the app dies, the outputs keep running, and if the engine dies, the
/// app shows it and starts it again (Spec 4 §12)."
///
/// The supervisor is the app's whole dealing with the engine as a process:
/// it connects to an engine that answers, "whoever started it", or starts
/// one; waits for the socket and for `hello`; watches the process and the
/// connection; pings; starts the engine again when it ends (choice U-7); and
/// ends it only when the operator says so. It lives on the main thread and
/// never waits there (Spec 10 §1): every wait is work scheduled on the
/// clock, and every report from another thread arrives through the hop.
@MainActor
public final class EngineSupervisor {
    /// What the supervisor is told once and doesn't change.
    public struct Settings: Sendable {
        /// Spec 10 §2 — "the engine is `oengine`, inside it at `Contents/Helpers/oengine`".
        public var executable: URL
        /// The app's version, for the `appStarted` note and to tell another build's engine (Spec 10 §2, "Versions").
        public var appVersion: String

        public init(executable: URL, appVersion: String = OCore.appVersion) {
            self.executable = executable
            self.appVersion = appVersion
        }
    }

    /// Where the app stands with the engine; the window shows each as Spec 10 §2 words it.
    public enum Phase: Equatable, Sendable {
        /// Not started yet.
        case idle
        /// "Starting the engine…": waiting for the socket, up to fifteen seconds, or for `hello`.
        case starting
        /// `hello` has come and the app drives the engine.
        case connected
        /// "The engine isn't responding": no answer to a ping within five seconds. Offers Restart the engine.
        case notResponding
        /// "When `api` differs, the app can't drive the engine and asks to restart it".
        case wrongAPI(engine: String)
        /// "If no socket has come up after those 15 seconds, the app shows the console log's last lines and offers Restart the engine".
        case noSocket(console: [String])
        /// "An app that gets no `hello`, from an engine holding the root ..., offers the same restart".
        case noHello
        /// "The engine stopped. Restarting…", with how many ends there have been and, from the third, the console log's last lines.
        case restarting(ends: Int, console: [String])
        /// The engine refused a first run (exit status 2): nothing is tried again, and the first-run sheet is shown.
        case firstRunRefused(console: [String])
        /// The app is quitting; nothing that happens to the engine now is an end.
        case quitting
    }

    /// Spec 10 §2 — "The app waits up to 15 seconds for the socket".
    public static let socketWait: TimeInterval = 15
    /// Spec 10 §2 (Area 13 reading) — how long a socket that is there may stay silent before "no `hello`": as long as a ping.
    public static let helloWait: TimeInterval = 5
    /// Spec 10 §2 — "The app sends `ping` every two seconds."
    public static let pingEvery: TimeInterval = 2
    /// Spec 10 §2 — "With no answer within five seconds".
    public static let pingPatience: TimeInterval = 5
    /// Spec 10 §2, "Quitting" — "waits up to ten seconds for its answer".
    public static let stopWait: TimeInterval = 10
    /// How often the socket is tried while one is expected, and afterwards.
    static let connectEvery: TimeInterval = 0.1
    static let connectSlowly: TimeInterval = 1
    /// Spec 10 §2 — "From the third such end the banner says how many there have been and shows the console log's last lines".
    static let endsBeforeConsole = 3

    public let store: ShowStore
    public private(set) var session: EngineSession?
    public private(set) var phase: Phase = .idle {
        didSet {
            if phase != oldValue { onPhase?(phase) }
        }
    }
    /// Called on every change of phase.
    public var onPhase: ((Phase) -> Void)?
    /// Spec 10 §2 — "`--operator-screen` names the screen holding the app's window", as `display:<uuid>`.
    public var operatorScreen: () -> String? = { nil }
    /// Spec 10 §9 — the screens the app released while it runs, named "with `--released` to each engine it starts".
    public var releasedScreens: () -> [String] = { [] }
    /// Spec 10 §13 — the campus name, given as `--campus` at first run.
    public var campus: () -> String? = { nil }
    /// Called when a session has started, so what the app must send each engine it connects to can be sent (Spec 10 §9: `releaseScreen` again).
    public var onConnected: ((EngineSession) -> Void)?

    private let roots: EngineRoots
    private let launcher: any EngineLauncher
    private let connector: any EngineConnector
    private let clock: any AppClock
    private let hop: MainHop
    private let settings: Settings

    /// Counts connections, so a report from an earlier one is told from the present one's.
    private var generation = 0
    private var link: EngineLink?
    /// The engine process this app started or found: nil when none is known to be running.
    private var enginePID: Int32?
    private var startedByApp = false
    private var watch: (any ProcessWatch)?
    /// The last `hello`, kept while the engine is away for its process id.
    private var lastHello: Hello?
    /// When this app last started an engine that hasn't said `hello` yet; nil when it hasn't started one in this try.
    private var launchedAt: TimeInterval?
    private var launchedThisEngine = false
    private var nextLaunchIsRelaunch = false
    /// The kill the operator asked for is on its way; the end it causes is no end to count.
    private var operatorRestart = false
    /// The ends of the last two minutes: how soon the engine is started again, and the number the banner shows.
    private var cadence = RestartCadence()
    /// Spec 10 §3, `engineEnded` — "sent to the next engine it connects to, the one thing the app holds back (§1)".
    private var pendingEnd: (status: Int32?, restart: Bool, count: Int)?
    private var connectTask: (any ClockTask)?
    private var helloTask: (any ClockTask)?
    private var pingTask: (any ClockTask)?
    private var restartTask: (any ClockTask)?
    private var stopTask: (any ClockTask)?

    public init(roots: EngineRoots, store: ShowStore, launcher: any EngineLauncher, connector: any EngineConnector, clock: any AppClock,
                settings: Settings, hop: @escaping MainHop = MainHops.live) {
        self.roots = roots
        self.store = store
        self.launcher = launcher
        self.connector = connector
        self.clock = clock
        self.settings = settings
        self.hop = hop
    }

    // MARK: - Starting (Spec 10 §2, "Starting")

    /// Spec 10 §2 — "The app connects to the engine's local socket ... If an
    /// engine answers, the app uses it, whoever started it. Otherwise the
    /// app starts `oengine run ...`".
    public func start() {
        guard phase == .idle || isStopped else { return }
        phase = .starting
        launchedAt = nil
        tryConnect()
    }

    private var isStopped: Bool {
        if case .firstRunRefused = phase { return true }
        return false
    }

    /// Whether the app is still after an engine at all.
    private var isSeeking: Bool {
        switch phase {
        case .idle, .quitting, .firstRunRefused: return false
        default: return true
        }
    }

    private func tryConnect() {
        connectTask?.cancel()
        connectTask = nil
        guard link == nil, isSeeking else { return }
        switch connector.connect(to: roots.socket) {
        case .success(let transport):
            adopt(transport)
            return
        case .failure(.pathTooLong):
            // Spec 10 §2 — "The socket's path must fit macOS's limit of 103 bytes, so first run refuses a location
            // that would make it longer (§13)"; roots that got past that can't be driven, and no engine would open there.
            phase = .noSocket(console: ["The machine root's path is too long for the engine's socket: \(roots.socket.path)"])
            return
        case .failure:
            break
        }
        // Nothing answers. An engine is started unless one of ours is on its way up, or one is known to be running.
        if launchedAt == nil, enginePID == nil {
            guard launch() else { return }
        }
        let waited = launchedAt.map { clock.now - $0 } ?? Self.socketWait
        if waited >= Self.socketWait {
            switch phase {
            case .starting, .restarting: phase = .noSocket(console: roots.consoleTail())
            default: break
            }
            // "never killed without it": the engine may yet come up, so the socket is still tried, at leisure.
            connectTask = clock.after(Self.connectSlowly) { [weak self] in self?.tryConnect() }
        } else {
            connectTask = clock.after(Self.connectEvery) { [weak self] in self?.tryConnect() }
        }
    }

    /// Starts the engine. False when it couldn't be started at all, which is handled as an end.
    private func launch() -> Bool {
        var arguments = ["run", "--library", roots.library.path, "--machine", roots.machine.path]
        if let screen = operatorScreen() { arguments += ["--operator-screen", screen] }
        // "at first run the app adds `--campus "NAME"`".
        if roots.isFirstRun, let name = campus(), !name.isEmpty { arguments += ["--campus", name] }
        for screen in releasedScreens() { arguments += ["--released", screen] }
        // "When the app starts an engine after the last one ended, it adds `--relaunch`". A flag with no value goes
        // last: the engine reads a word that follows a flag as its value.
        if nextLaunchIsRelaunch { arguments.append("--relaunch") }
        do {
            try roots.prepareConsoleLog()
            let pid = try launcher.start(EngineLaunch(executable: settings.executable, arguments: arguments, consoleLog: roots.consoleLog))
            launchedAt = clock.now
            launchedThisEngine = true
            watchEngine(pid, startedByApp: true)
            return true
        } catch {
            // An engine that can't be started is an end like any other: it is tried again, and the banner says why.
            engineEnded(status: nil, because: "\(error)")
            return false
        }
    }

    private func watchEngine(_ pid: Int32, startedByApp: Bool) {
        if enginePID == pid, watch != nil { return }
        watch?.cancel()
        enginePID = pid
        self.startedByApp = startedByApp
        let hop = self.hop
        watch = launcher.watch(pid: pid) { [weak self] exit in
            hop { self?.processExited(pid, exit) }
        }
    }

    // MARK: - A connection

    private func adopt(_ transport: any EngineTransport) {
        generation += 1
        let generation = self.generation
        let link = EngineLink(transport: transport)
        self.link = link
        let hop = self.hop
        link.start { [weak self] incoming in
            hop { self?.received(incoming, generation) }
        }
        // "An app that gets no `hello`, from an engine holding the root or within 15 seconds of starting one".
        let patience = launchedAt.map { max(0, Self.socketWait - (clock.now - $0)) } ?? Self.helloWait
        helloTask?.cancel()
        helloTask = clock.after(patience) { [weak self] in
            guard let self, generation == self.generation, self.session == nil, self.link != nil else { return }
            if case .wrongAPI = self.phase { return }
            self.phase = .noHello
        }
    }

    private func received(_ incoming: Incoming, _ generation: Int) {
        guard generation == self.generation else { return }
        if let session {
            session.receive(incoming)
            return
        }
        switch incoming {
        case .hello(let hello):
            greeted(hello)
        case .closed:
            // The socket closed before any `hello`: whatever listened has gone, and the socket is tried again.
            helloTask?.cancel()
            link = nil
            if isSeeking { connectTask = clock.after(Self.connectEvery) { [weak self] in self?.tryConnect() } }
        default:
            break
        }
    }

    private func greeted(_ hello: Hello) {
        helloTask?.cancel()
        lastHello = hello
        // The process to watch is the one that said hello: the app's own, or one it found.
        if enginePID != hello.pid { watchEngine(hello.pid, startedByApp: false) }
        guard hello.isDrivable, let link else {
            phase = .wrongAPI(engine: hello.engine)
            return
        }
        let session = EngineSession(link: link, hello: hello, store: store, clock: clock)
        let generation = self.generation
        session.onClosed = { [weak self] in self?.connectionClosed(generation) }
        self.session = session
        session.start()
        phase = .connected

        // Spec 10 §3, "Notes" — `appStarted`: "The app connects to an engine", with "`launched`, whether it started the engine".
        let launched = launchedThisEngine && startedByApp
        session.send(.note(["event": .string("appStarted"), "app": .string(settings.appVersion), "launched": .bool(launched)],
                           text: launched ? "Project O \(settings.appVersion) started the engine" : "Project O \(settings.appVersion) connected"))
        if let end = pendingEnd {
            var note: [String: JSONValue] = ["event": .string("engineEnded"), "restart": .bool(end.restart), "count": .number(Double(end.count))]
            // "`status`, when the app started that engine".
            if let status = end.status { note["status"] = .number(Double(status)) }
            session.send(.note(note, text: end.restart ? "Restart the engine ended the engine" : (end.count == 1 ? "The engine ended" : "The engine ended \(end.count) times")))
            pendingEnd = nil
        }
        launchedAt = nil
        nextLaunchIsRelaunch = false
        onConnected?(session)
        schedulePing(generation)
    }

    /// The connection has gone. Spec 10 §2 — "If the socket closes and the
    /// process has gone", the engine has ended, and the watch on its process
    /// says so. Until it does, the engine may only have closed this
    /// connection, as it closes a client that fell too far behind (Area 13
    /// reading): the socket is tried again and nothing is counted as an end.
    private func connectionClosed(_ generation: Int) {
        guard generation == self.generation else { return }
        pingTask?.cancel()
        link = nil
        session = nil
        guard isSeeking else { return }
        if enginePID == nil {
            // The process's end was seen first and is being dealt with.
            return
        }
        connectTask = clock.after(0) { [weak self] in self?.tryConnect() }
        let was = self.generation
        helloTask?.cancel()
        helloTask = clock.after(Self.helloWait) { [weak self] in
            guard let self, was == self.generation, self.session == nil, self.enginePID != nil else { return }
            self.phase = .noHello
        }
    }

    // MARK: - The process (Spec 10 §2, "When the engine stops")

    private func processExited(_ pid: Int32, _ exit: EngineExit) {
        guard pid == enginePID else { return }
        watch = nil
        enginePID = nil
        let ours = startedByApp
        guard isSeeking else { return }
        if operatorRestart {
            // The end the operator asked for: the engine is started again, as a relaunch, and nothing is counted.
            operatorRestart = false
            dropConnection()
            launchedAt = nil
            tryConnect()
            return
        }
        var status: Int32?
        if case .exited(let code) = exit { status = code }
        if session == nil, ours {
            // "An engine that exits with status 3 found another engine holding the root (below), so the app keeps
            // waiting for the socket and doesn't count it as an end".
            if status == 3 { return }
            // Adam's answer, 2026-11-17 — status 2 (a first run asked wrongly) stops and shows the first-run sheet again.
            if status == 2 {
                dropConnection()
                connectTask?.cancel()
                phase = .firstRunRefused(console: roots.consoleTail())
                return
            }
        }
        engineEnded(status: ours ? status : nil, because: nil)
    }

    /// Spec 10 §2 — "a banner across the window says "The engine stopped.
    /// Restarting…", and the app starts it again ... at once for the first
    /// three ends within two minutes, then five seconds after each". "From
    /// the third such end the banner says how many there have been and shows
    /// the console log's last lines".
    ///
    /// Adam's answer at Area 13's first stop, 2026-11-17 — the banner counts
    /// the ends in the two minutes before, the same ones the cadence counts,
    /// whether or not an engine connected in between: one that says `hello`
    /// and then ends every time still reaches the console lines.
    private func engineEnded(status: Int32?, because: String?) {
        dropConnection()
        pendingEnd = (status: status, restart: false, count: (pendingEnd?.count ?? 0) + 1)
        let delay = cadence.ended(at: clock.now)
        let ends = cadence.recent(at: clock.now)
        nextLaunchIsRelaunch = true
        launchedAt = nil
        var console = ends >= Self.endsBeforeConsole ? roots.consoleTail() : []
        if let because { console.append(because) }
        phase = .restarting(ends: ends, console: console)
        restartTask?.cancel()
        restartTask = clock.after(delay) { [weak self] in
            guard let self, case .restarting = self.phase else { return }
            self.tryConnect()
        }
    }

    private func dropConnection() {
        helloTask?.cancel()
        pingTask?.cancel()
        connectTask?.cancel()
        let session = self.session
        let link = self.link
        self.session = nil
        self.link = nil
        // A new generation: whatever the old connection still reports is no longer this one's.
        generation += 1
        session?.onClosed = nil
        link?.close()
        store.disconnected()
    }

    // MARK: - Ping (Spec 10 §2, "When it doesn't answer")

    private func schedulePing(_ generation: Int) {
        pingTask = clock.after(Self.pingEvery) { [weak self] in self?.ping(generation) }
    }

    private func ping(_ generation: Int) {
        guard generation == self.generation, let session, session.isOpen else { return }
        let answer = Answered()
        session.send(.ping) { [weak self] reply in
            guard let self, reply != nil else { return }
            answer.arrived = true
            // A pong, however late, says the control side is alive (Area 13 reading: it clears the banner).
            if generation == self.generation, self.phase == .notResponding { self.phase = .connected }
        }
        clock.after(Self.pingPatience) { [weak self] in
            guard let self, generation == self.generation, !answer.arrived, self.phase == .connected else { return }
            // "The app never ends the engine on its own, since the outputs may still be playing."
            self.phase = .notResponding
        }
        schedulePing(generation)
    }

    private final class Answered {
        var arrived = false
    }

    // MARK: - Restart the engine (Spec 10 §2)

    /// Spec 10 §2 — "Restart the engine": "It ends the engine by its `pid`
    /// with a kill, never a terminate signal ..., and starts it again, as a
    /// relaunch." The window asks first (it "says the screens go black for a
    /// moment"); this is what the button does once the operator has agreed.
    /// "finding the engine by the process id in `.engine.lock`, and starts
    /// one when nothing holds the root."
    public func restartEngine() {
        guard isSeeking || isStopped else { return }
        restartTask?.cancel()
        let pid = enginePID ?? lastHello?.pid ?? roots.lockHolder()
        pendingEnd = (status: nil, restart: true, count: (pendingEnd?.count ?? 0) + 1)
        nextLaunchIsRelaunch = true
        dropConnection()
        launchedAt = nil
        phase = .starting
        // The id may be a stale one that names some other program by now: only an `oengine` is ever ended.
        if let pid, launcher.isRunning(pid: pid), launcher.executablePath(pid: pid).map({ URL(fileURLWithPath: $0).lastPathComponent }) == "oengine" {
            operatorRestart = true
            watchEngine(pid, startedByApp: enginePID == pid && startedByApp)
            launcher.kill(pid: pid)
            // The watch reports its end, and the engine is started again from there.
        } else {
            watch?.cancel()
            watch = nil
            enginePID = nil
            tryConnect()
        }
    }

    /// Spec 10 §2, "Versions" — "When the app finds an engine of another
    /// build running, as after Keep outputs running and an update, the
    /// banner says so and offers Restart the engine for as long as the
    /// builds differ". The two versions while such an engine is connected;
    /// nil otherwise. `hello` names a version only, so the versions are what
    /// is compared (Area 13 reading).
    public var anotherBuild: AnotherBuild? {
        guard phase == .connected, let hello = lastHello, hello.engine != settings.appVersion else { return nil }
        return AnotherBuild(engine: hello.engine, app: settings.appVersion)
    }

    // MARK: - Quitting (Spec 10 §2, choice U-2)

    /// Spec 10 §2 — Quit "sends `stop`, waits up to ten seconds for its
    /// answer, shows the documents the answer names as unsaved (Spec 9 §7),
    /// then quits; with no answer in that time, it kills the engine by its
    /// `pid`, since Quit asked for the outputs to stop." `completion` gets
    /// the unsaved documents, or nil when the engine never answered.
    public func stopEngine(completion: @escaping ([String]?) -> Void) {
        let session = self.session
        let pid = enginePID ?? lastHello?.pid
        phase = .quitting
        connectTask?.cancel()
        restartTask?.cancel()
        helloTask?.cancel()
        pingTask?.cancel()
        let done = Answered()
        func end(_ unsaved: [String]?) {
            guard !done.arrived else { return }
            done.arrived = true
            stopTask?.cancel()
            if unsaved == nil, let pid, launcher.isRunning(pid: pid) { launcher.kill(pid: pid) }
            completion(unsaved)
        }
        guard let session, session.isOpen else {
            end(nil)
            return
        }
        session.send(.stop) { reply in
            // A connection that closes without an answer leaves nothing to show; the engine is ended if it is still there.
            end(reply?.outcome?.unsaved)
        }
        stopTask = clock.after(Self.stopWait) { end(nil) }
    }

    /// Spec 10 §2 — "Keep outputs running quits the app alone, and the next
    /// launch of the app finds the engine and connects."
    public func leaveEngineRunning() {
        phase = .quitting
        connectTask?.cancel()
        restartTask?.cancel()
        helloTask?.cancel()
        pingTask?.cancel()
        watch?.cancel()
        session?.onClosed = nil
        link?.close()
    }
}
