// OEngine — Spec 4 §15, the `oengine` process: its subcommands.

import AppKit
import Foundation
import OCore
import OMach
import Synchronization

/// Spec 4 §15 — the argument dispatcher the executable calls. `run` is the
/// engine on the machine's outputs; `soak` is `run` with the script sent over
/// OSC and the Spec 4 §13 thresholds judged at the end; `drive` sends a script
/// to a running engine; `evaluate` judges a black box folder; `make-fixtures`
/// writes the synthetic spike media. Nothing here runs under `swift test`:
/// these open screens and speakers.
public enum OEngineCommandLine {
    public static func run(arguments: [String]) -> Int32 {
        guard let first = arguments.first else {
            print(usage)
            return 2
        }
        let rest = Arguments(Array(arguments.dropFirst()))
        do {
            switch first {
            case "version":
                print("oengine \(OCore.appVersion)")
                return 0
            case "help", "--help", "-h":
                print(usage)
                return 0
            case "run":
                return try runEngine(rest, soak: false)
            case "soak":
                return try runEngine(rest, soak: true)
            case "drive":
                return try drive(rest)
            case "evaluate":
                return try evaluate(rest)
            case "make-fixtures":
                return try makeFixtures(rest)
            case "mach-proof":
                return try machProof(rest)
            case "devices":
                return devices()
            case "mach-watch":
                return try machWatch(rest)
            default:
                fail("unknown command \(first)\n" + usage)
                return 2
            }
        } catch {
            fail("\(error)")
            return 1
        }
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data(("oengine: " + message + "\n").utf8))
    }

    public static let usage = """
    usage: oengine <command> [options]
      version
      run  --library <root> --machine <root> [--osc-port N] [--blackbox <folder>] [--seconds N] [--no-audio] [--no-lan]
           [--campus <name> --operator-screen display:<uuid>] [--relaunch] [--released display:<uuid> ...]
           the engine on the machine's outputs until Ctrl-C or --seconds; OSC on the machine's port;
           the logs in <machine>/logs and the black box in <machine>/blackbox unless --blackbox names a folder;
           the LAN API on the machine's apiPort once its token is read from the login keychain (made there
           at the first launch), advertised over Bonjour; --no-lan opens no listener and leaves the Keychain alone;
           first run: a library root without library.json gets the first-run library, and a machine root
           without machine.json gets this Mac's (its outputs are every DeckLink port, then every screen but the
           one --operator-screen names; --campus names it); a file that is there is never written over, and
           without both options a root with no machine.json is refused, with nothing written (status 2);
           --relaunch says the engine before this one ended: the last state is put back whatever
           restoreLastState says, and no startup macro runs; a run that ended without a stop since the Mac
           started makes a relaunch without it; --released keeps every output on that screen closed;
           exits with status 3 when another engine holds the machine root, 4 when the roots don't load
      soak --library <root> --machine <root> --scenario <file> [--minutes N] [--blackbox <folder>] [--osc-port N] [--no-audio] [--no-lan]
           [--screens display:<uuid>,display:<uuid>]
           run, with the scenario sent over OSC for N minutes (180 by default), then the Spec 4 §13 thresholds; exit 1 on a failure;
           its display outputs take the screens --screens names, in order, or every screen of this Mac left to right,
           and a client of its own holds the Mach channel throughout, so the previews and channel pictures are in its GPU time
      drive --to host:port --scenario <file> --library <root> [--seconds N]
           send a scenario to a running engine (the library validates media ids); one pass by default
      evaluate --blackbox <folder> [--tick-ns N] [--sdi 2,3] [--display 1,2]
           judge a black box folder against the thresholds; exit 1 on a failure
      make-fixtures <media-folder> [--scale X]
           write the synthetic spike clips and still (tests/fixtures/spike/library/media)
      devices
           print this Mac's screens (display:<uuid>), DeckLink output ports and audio output devices as JSON,
           as the devices query answers them (Spec 10 §3); the ids are what an output's device holds
      mach-proof serve <name> [--register]
           register <name> as a Mach service (bootstrap_check_in, or the deprecated bootstrap_register with
           --register) and answer each lookup with one surface until killed; opens no screen (Spec 10 §2)
      mach-proof lookup <name> [<result-file>]
           look <name> up, read the surface it sends and say what was read; exit 1 when it isn't there
      mach-watch <name> [--seconds N]
           hold a running engine's Mach channel (the name its hello gives) for N seconds, 3 by default, and say
           what arrived: each stack's preview surfaces and each channel's pictures, how many frames a second
           were named, whether the newest hold a picture, and the meters; exit 1 when nothing arrived
    A display output opens only on the screen its device names (display:<uuid>); while that screen isn't there
    the output is absent, and it opens when the screen appears.
    """

    // MARK: - run and soak

    /// Spec 10 §2 — status 3 belongs to "another engine holds the root", which
    /// the app doesn't count as an end, so roots that don't load exit with a
    /// status of their own.
    static let rootsExitStatus: Int32 = 4

    /// Spec 10 §2 — the root's lock, held for as long as the process runs.
    nonisolated(unsafe) static var engineLock: EngineLock?

    /// Spec 10 §13 (Area 19 reading) — a launch that can't do the first run it
    /// would have to do was asked wrongly: it exits as a wrong command does.
    static let firstRunRefusedExitStatus: Int32 = 2

    static func runEngine(_ args: Arguments, soak: Bool) throws -> Int32 {
        let libraryRoot = try args.url("--library"), machineRoot = try args.url("--machine")
        // Spec 10 §2 — "One engine per machine root": the lock first, before the roots are read or anything is written.
        switch EngineLock.acquire(machineRoot: machineRoot) {
        case .success(let lock):
            engineLock = lock
        case .failure(let failure):
            fail("\(failure): \(machineRoot.path)")
            if case .held = failure { return EngineLock.heldExitStatus }
            return 1
        }
        // Spec 10 §2 — "The socket's path must fit macOS's limit of 103 bytes, so first run refuses a location that
        // would make it longer (§13)": an engine the app can't reach doesn't start, and leaves nothing behind.
        if let failure = LocalSocket.check(path: LocalSocket.url(machineRoot: machineRoot).path) {
            fail("\(failure)")
            withdrawLock()
            return 1
        }
        // Spec 10 §13 — first run needs the campus and the app's screen; a launch without them writes nothing, so
        // what taking the lock made goes again too.
        let firstRun = FirstRunWriter.Request(libraryRoot: libraryRoot, machineRoot: machineRoot, campus: args.options["--campus"],
                                              operatorScreen: args.options["--operator-screen"])
        if let refusal = FirstRunWriter.refusal(firstRun) {
            fail(refusal)
            withdrawLock()
            return firstRunRefusedExitStatus
        }
        // Spec 10 §2 — "the engine trims the file in place to its last 10 MB at launch".
        ConsoleLog.trim(ConsoleLog.url(machineRoot: machineRoot))
        // Spec 10 §2 — "It writes any first-run documents before Spec 9 §4's first step": whichever side is missing,
        // once, and never over a file that is there (Spec 10 §13).
        switch FirstRunWriter.run(firstRun, devices: { MainActor.assumeIsolated { _ = NSApplication.shared; return SystemDevices().devices() } }) {
        case .nothing:
            break
        case .wrote(let written):
            for line in FirstRunWriter.lines(written, request: firstRun) { print("oengine: " + line) }
        case .refused(let why):
            fail(why)
            releaseLock()
            return firstRunRefusedExitStatus
        case .failed(let why):
            fail(why)
            releaseLock()
            return 1
        }
        do {
            return try runLocked(args, soak: soak, libraryRoot: libraryRoot, machineRoot: machineRoot)
        } catch {
            releaseLock()
            throw error
        }
    }

    /// Lets the machine root go: at a stop, and when a launch gives up.
    static func releaseLock() {
        engineLock?.release()
        engineLock = nil
    }

    /// Lets the machine root go and takes away what taking it made: a launch that was refused before it wrote anything.
    static func withdrawLock() {
        engineLock?.withdraw()
        engineLock = nil
    }

    private static func runLocked(_ args: Arguments, soak: Bool, libraryRoot: URL, machineRoot: URL) throws -> Int32 {
        // Spec 8 §2, choice M-8 — the engine reads media only where media may live on this Mac.
        var roots = try LoadedRoots.load(libraryRoot: libraryRoot, machineRoot: machineRoot, places: .thisMac())
        for line in roots.issueLines { fail(line) }
        if roots.hasErrors {
            fail("the roots did not load cleanly; fix the issues above")
            releaseLock()
            return rootsExitStatus
        }
        if soak {
            // The spike's outputs name screens no Mac has, and an output opens only on its own screen (Spec 10 §2):
            // the soak's display outputs take the screens --screens names, or this Mac's, left to right.
            let named = args.options["--screens"].map { $0.split(separator: ",").map(String.init) }
            let screens = named ?? OutputPlacement.soakScreens(MainActor.assumeIsolated { _ = NSApplication.shared; return SystemDevices().devices() }.screens)
            roots.machine.outputs = OutputPlacement.bound(roots.machine.outputs, to: screens)
            for output in roots.machine.outputs where output.kind == .display { print("oengine: soak output \(output.number) on \(output.device)") }
        }
        var options = EngineProcess.Options()
        options.oscPort = try args.int("--osc-port")
        options.audio = !args.flag("--no-audio")
        // Spec 10 §2 — "When the app starts an engine after the last one ended, it adds `--relaunch` (below), and
        // `--released display:<uuid>` for each screen it has released while it runs (§9)." Without the flag, a run
        // that ended without a stop since the Mac started makes this launch a relaunch too.
        options.relaunch = args.flag("--relaunch")
        options.bootedAtMs = BootTime.wallMilliseconds()
        options.released = args.all("--released")
        // Spec 10 §2 — the LAN API: the system's WebSocket listener, and the token from the login keychain. A run
        // with --no-lan opens neither and never touches the Keychain.
        if !args.flag("--no-lan") { options.lan = EngineProcess.LanOptions(server: NetworkLanServer(), secrets: KeychainStore()) }
        let blackBoxFolder = blackBoxFolder(named: args.optionalURL("--blackbox"), machineRoot: roots.machineRoot, soak: soak,
                                            stamp: fileStamp(Date()), working: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        options.blackBoxFolder = blackBoxFolder
        let scenario = soak ? try SoakScenario.load(try args.url("--scenario")) : nil
        let seconds: Int? = soak ? (try args.int("--minutes") ?? 180) * 60 : try args.int("--seconds")

        // The process runs the main thread's run loop for AppKit (the display sinks' windows); the engine is on its own threads.
        // Spec 10 §2 — "It runs as an accessory process ... they never ... make the engine the active app". macOS makes an
        // accessory process the active app as its launch finishes, which would take the keyboard from the operator's app.
        // So it launches as a process that can't be activated, and becomes an accessory process once launched (the delegate).
        _ = MainActor.assumeIsolated { NSApplication.shared.setActivationPolicy(.prohibited) }
        let process = try MainActor.assumeIsolated { try EngineProcess(roots: roots, options: options) }
        process.start()
        print("oengine: running on \(roots.machine.settings.campusName); OSC on port \(process.osc?.boundPort ?? 0); black box in \(blackBoxFolder.path)")
        // Spec 10 §18 — "The soak scenario gains a client holding the Mach channel, so the previews and the channel
        // pictures count in its GPU p99 (Spec 4 §13)."
        let machClient: SoakMachClient? = soak ? SoakMachClient() : nil
        machClient?.hold(run: process.engine.run)
        if let seconds { print("oengine: stopping after \(seconds) s") }

        let finishing = Atomic<Bool>(false)
        let driver: ScenarioDriver? = try scenario.map { scenario in
            try ScenarioDriver(scenario: scenario, options: ParseOptions(mediaIDs: roots.mediaIDs),
                               to: OSCPeer(host: "127.0.0.1", port: process.osc?.boundPort ?? 0), log: process.log)
        }
        let finish: @Sendable (Int32) -> Void = { requested in
            guard !finishing.exchange(true, ordering: .acquiringAndReleasing) else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                driver?.stop()
                let held = machClient?.verdict()
                machClient?.release()
                process.stop()
                print(process.summary())
                var code = requested
                if let held {
                    print(held.lines.joined(separator: "\n"))
                    for failure in held.failures { print("FAIL: " + failure) }
                    if !held.failures.isEmpty { code = 1 }
                }
                if soak {
                    do {
                        let run = try BlackBoxReader.load(folder: blackBoxFolder, tickNanoseconds: process.engine.pacing.tickNanoseconds,
                                                          sdiOutputs: roots.machine.outputs.filter { $0.kind == .sdi }.map(\.number),
                                                          displayOutputs: roots.machine.outputs.filter { $0.kind == .display }.map(\.number))
                        let failures = SoakThresholds.evaluate(run)
                        print(BlackBoxReader.report(run: run, failures: failures))
                        if let driver, !driver.failed.isEmpty {
                            print("scenario steps that did not go out: \(driver.failed.count)")
                            for line in driver.failed.prefix(10) { print("  - \(line)") }
                            code = 1
                        }
                        if !failures.isEmpty { code = 1 }
                    } catch {
                        fail("could not read the black box: \(error)")
                        code = 1
                    }
                }
                releaseLock()
                exit(code)
            }
        }
        installSignalHandlers { finish(0) }
        // Spec 10 §3 — `stop` is answered "before it exits": the hub stops the engine, sends the answer, then comes here.
        process.engine.api.afterStop = { finish(0) }
        // Spec 10 §2 — "When macOS asks it to quit (logout, restart, shutdown) or sends it a terminate signal, it stops on
        // request as Spec 9 §4 says."
        MainActor.assumeIsolated {
            let delegate = EngineAppDelegate(onQuit: { finish(0) })
            appDelegate = delegate
            NSApplication.shared.delegate = delegate
        }
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { finish(0) }
        }
        if let driver, let seconds {
            let thread = Thread {
                driver.run(durationMs: seconds * 1000)
                finish(0)
            }
            thread.name = "o.engine.drive"
            thread.start()
        }
        MainActor.assumeIsolated { NSApplication.shared.run() }
        return 0
    }

    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    /// The application's delegate, which AppKit holds only weakly.
    @MainActor static var appDelegate: EngineAppDelegate?

    static func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { handler() }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Spec 9 §8 — "The black box in `machine/blackbox/` in the engine's
    /// normal runs ...; the soak keeps `--blackbox`": the folder the command
    /// line names, else `machine/blackbox/` for `run` and the soak's own
    /// output folder, `tests/soak-output/<stamp>` under the working folder,
    /// for `soak`.
    static func blackBoxFolder(named: URL?, machineRoot: URL, soak: Bool, stamp: String, working: URL) -> URL {
        if let named { return named }
        if soak { return working.appendingPathComponent("tests/soak-output").appendingPathComponent(stamp) }
        return machineRoot.appendingPathComponent("blackbox")
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    // MARK: - drive

    static func drive(_ args: Arguments) throws -> Int32 {
        let peer = try OSCClient.peer(try args.string("--to"))
        let scenario = try SoakScenario.load(try args.url("--scenario"))
        let roots = try LoadedRoots.load(libraryRoot: try args.url("--library"), machineRoot: try args.url("--library"))
        let seconds = try args.int("--seconds") ?? max(1, scenario.loopMs / 1000)
        let driver = try ScenarioDriver(scenario: scenario, options: ParseOptions(mediaIDs: Set(roots.library.mediaIndex.entries.map(\.id))),
                                        to: peer, log: EngineLog(category: "drive"))
        installSignalHandlers { driver.stop() }
        print("oengine: driving \(peer.host):\(peer.port) with '\(scenario.title)' for \(seconds) s")
        driver.run(durationMs: seconds * 1000)
        print("sent \(driver.sent) messages")
        for line in driver.failed { fail(line) }
        return driver.failed.isEmpty ? 0 : 1
    }

    // MARK: - evaluate

    static func evaluate(_ args: Arguments) throws -> Int32 {
        let folder = try args.url("--blackbox")
        let tickNs = Int64(try args.int("--tick-ns") ?? 16_666_667)
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: tickNs, sdiOutputs: try args.ints("--sdi") ?? [],
                                          displayOutputs: try args.ints("--display") ?? [1, 2])
        let failures = SoakThresholds.evaluate(run)
        print(BlackBoxReader.report(run: run, failures: failures))
        return failures.isEmpty ? 0 : 1
    }

    // MARK: - make-fixtures

    static func makeFixtures(_ args: Arguments) throws -> Int32 {
        guard let folder = args.positional.first else { throw ProcessError.missingArgument("<media-folder>") }
        let scale = try args.double("--scale") ?? 1
        let written = try SpikeFixtures.write(into: URL(fileURLWithPath: folder), scale: scale)
        for url in written { print(url.path) }
        return 0
    }

    // MARK: - devices

    /// Spec 10 §3, the `devices` query — what this Mac has, as the query
    /// answers it: the way to learn which `display:<uuid>` is which screen
    /// when an output is bound by hand, as on the bench.
    static func devices() -> Int32 {
        let list = MainActor.assumeIsolated {
            _ = NSApplication.shared
            return SystemDevices().devices()
        }
        guard let json = try? JSONCoding.encode(list) else { return 1 }
        print(JSONCanonical.string(json), terminator: "")
        return 0
    }

    // MARK: - mach-watch

    /// Spec 10 §2, "The Mach channel" — the channel from a process that
    /// didn't start the engine, as the operator app will hold it: looks the
    /// service up under the name `hello` gives, holds it for a few seconds and
    /// says what arrived. The check by hand on the bench.
    static func machWatch(_ args: Arguments) throws -> Int32 {
        guard let name = args.positional.first else { throw ProcessError.missingArgument("<name>") }
        let seconds = Double(try args.int("--seconds") ?? 3)
        let client = MachClient()
        try client.connect(name: name)
        Thread.sleep(forTimeInterval: seconds)
        let lines = client.report(seconds: seconds)
        let arrived = client.state.previewSets + client.state.pictureSets
        client.disconnect()
        print("mach-watch: pid \(getpid()) held \(name) for \(Int(seconds)) s")
        print(lines.joined(separator: "\n"))
        if arrived == 0 { print("mach-watch: no surface arrived") }
        return arrived == 0 ? 1 : 0
    }

    // MARK: - mach-proof

    /// Spec 10 §2 — "Area 19 proves the call on the dev Mac at its first stop
    /// for review": each side of `MachProof` in a process of its own, so the
    /// lookup can come "from an app that didn't start the engine" (Spec 10
    /// §18). `scripts/mach-proof.sh` runs both and prints what they say.
    static func machProof(_ args: Arguments) throws -> Int32 {
        guard args.positional.count >= 2 else { throw ProcessError.missingArgument("serve|lookup <name>") }
        let name = args.positional[1]
        switch args.positional[0] {
        case "serve":
            let service = BootstrapMachService(calls: args.flag("--register") ? [.register] : [.checkIn, .register])
            let registration = try service.register(name: name)
            print("serve: pid \(getpid()) registered \(name) with \(registration.call == .checkIn ? "bootstrap_check_in" : "bootstrap_register")")
            while true {
                switch MachProof.answerOne(on: registration, timeoutMs: 1000) {
                case .success(let caller): print("serve: sent a surface to pid \(caller.pid), user \(caller.uid)")
                case .failure(.receive(MACH_RCV_TIMED_OUT)): continue
                case .failure(let failure): print("serve: \(failure)")
                }
            }
        case "lookup":
            var lines = ["lookup: pid \(getpid()), started by pid \(getppid()), user \(getuid())"]
            var code: Int32 = 0
            do {
                let reading = try MachProof.lookUp(name: name)
                let intact = reading.firstPixel == MachProof.pixel && reading.lastPixel == MachProof.pixel
                lines.append("lookup: found \(name), served by pid \(reading.serverPID), registered with \(reading.call == .checkIn ? "bootstrap_check_in" : "bootstrap_register")")
                lines.append("lookup: the server saw pid \(reading.seenPID), user \(reading.seenUID) in the audit token")
                lines.append("lookup: surface \(reading.width) by \(reading.height), first pixel \(reading.firstPixel), last pixel \(reading.lastPixel): \(intact ? "as sent" : "NOT as sent")")
                if !intact { code = 1 }
            } catch {
                lines.append("lookup: \(error)")
                code = 1
            }
            let text = lines.joined(separator: "\n") + "\n"
            print(text, terminator: "")
            if args.positional.count > 2 {
                try Data(text.utf8).write(to: URL(fileURLWithPath: args.positional[2]))
            }
            return code
        default:
            throw ProcessError.badArgument("mach-proof", args.positional[0])
        }
    }
}

/// Spec 10 §2, "The engine as a process" — "It runs as an accessory process,
/// with no Dock icon and no menu bar ... they never take the keyboard or make
/// the engine the active app", and "When macOS asks it to quit (logout,
/// restart, shutdown) ... it stops on request as Spec 9 §4 says."
///
/// macOS makes an accessory process the active app as its launch finishes
/// (found on the dev Mac, macOS 26.3: the operator's keys would then go
/// nowhere until someone clicked the app). A process that can't be activated
/// isn't, so the engine launches as one and becomes an accessory process here,
/// once launched; nothing activates it after that, since its only windows are
/// non-activating panels.
@MainActor
final class EngineAppDelegate: NSObject, NSApplicationDelegate {
    private let onQuit: @Sendable () -> Void

    init(onQuit: @escaping @Sendable () -> Void) {
        self.onQuit = onQuit
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// The stop on request runs, and the process exits when it is done; AppKit is told to wait for that.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        onQuit()
        return .terminateLater
    }
}

/// `--name value` options, `--flag` switches and positional words.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    /// Every value of an option given more than once, in order (`--released`, once a screen).
    var repeated: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ list: [String]) {
        var index = 0
        while index < list.count {
            let word = list[index]
            if word.hasPrefix("--") {
                if index + 1 < list.count, !list[index + 1].hasPrefix("--") {
                    options[word] = list[index + 1]
                    repeated[word, default: []].append(list[index + 1])
                    index += 2
                } else {
                    flags.insert(word)
                    index += 1
                }
            } else {
                positional.append(word)
                index += 1
            }
        }
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    /// Every value given for `name`, in order.
    func all(_ name: String) -> [String] { repeated[name] ?? [] }

    func string(_ name: String) throws -> String {
        guard let value = options[name] else { throw ProcessError.missingArgument(name) }
        return value
    }

    func url(_ name: String) throws -> URL {
        URL(fileURLWithPath: try string(name)).standardizedFileURL
    }

    func optionalURL(_ name: String) -> URL? {
        options[name].map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    func int(_ name: String) throws -> Int? {
        guard let value = options[name] else { return nil }
        guard let number = Int(value) else { throw ProcessError.badArgument(name, value) }
        return number
    }

    func double(_ name: String) throws -> Double? {
        guard let value = options[name] else { return nil }
        guard let number = Double(value) else { throw ProcessError.badArgument(name, value) }
        return number
    }

    func ints(_ name: String) throws -> [Int]? {
        guard let value = options[name] else { return nil }
        let numbers = value.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !numbers.contains(nil) else { throw ProcessError.badArgument(name, value) }
        return numbers.compactMap { $0 }
    }
}
