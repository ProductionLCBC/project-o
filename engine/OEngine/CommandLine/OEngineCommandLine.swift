// OEngine — Spec 4 §15, the `oengine` process: its subcommands.

import AppKit
import Foundation
import OCore
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
      run  --library <root> --machine <root> [--osc-port N] [--blackbox <folder>] [--seconds N] [--no-audio]
           the engine on the machine's outputs until Ctrl-C or --seconds; OSC on the machine's port
      soak --library <root> --machine <root> --scenario <file> [--minutes N] [--blackbox <folder>] [--osc-port N] [--no-audio]
           run, with the scenario sent over OSC for N minutes (180 by default), then the Spec 4 §13 thresholds; exit 1 on a failure
      drive --to host:port --scenario <file> --library <root> [--seconds N]
           send a scenario to a running engine (the library validates media ids); one pass by default
      evaluate --blackbox <folder> [--tick-ns N] [--sdi 2,3] [--display 1,2]
           judge a black box folder against the thresholds; exit 1 on a failure
      make-fixtures <media-folder> [--scale X]
           write the synthetic spike clips and still (tests/fixtures/spike/library/media)
    With fewer screens than display outputs, the last outputs share the last screen, the later one on top.
    """

    // MARK: - run and soak

    static func runEngine(_ args: Arguments, soak: Bool) throws -> Int32 {
        let roots = try LoadedRoots.load(libraryRoot: try args.url("--library"), machineRoot: try args.url("--machine"))
        for line in roots.issueLines { fail(line) }
        if roots.hasErrors {
            fail("the roots did not load cleanly; fix the issues above")
            return 3
        }
        var options = EngineProcess.Options()
        options.oscPort = try args.int("--osc-port")
        options.audio = !args.flag("--no-audio")
        let blackBoxFolder = args.optionalURL("--blackbox") ?? defaultBlackBoxFolder()
        options.blackBoxFolder = blackBoxFolder
        let scenario = soak ? try SoakScenario.load(try args.url("--scenario")) : nil
        let seconds: Int? = soak ? (try args.int("--minutes") ?? 180) * 60 : try args.int("--seconds")

        // The process runs the main thread's run loop for AppKit (the display sinks' windows); the engine is on its own threads.
        _ = MainActor.assumeIsolated { NSApplication.shared.setActivationPolicy(.accessory) }
        let process = try MainActor.assumeIsolated { try EngineProcess(roots: roots, options: options) }
        process.start()
        print("oengine: running on \(roots.machine.settings.campusName); OSC on port \(process.osc?.boundPort ?? 0); black box in \(blackBoxFolder.path)")
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
                process.stop()
                print(process.summary())
                var code = requested
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
                exit(code)
            }
        }
        installSignalHandlers { finish(0) }
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

    static func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { handler() }
            source.resume()
            signalSources.append(source)
        }
    }

    static func defaultBlackBoxFolder() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("tests/soak-output")
            .appendingPathComponent(formatter.string(from: Date()))
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
}

/// `--name value` options, `--flag` switches and positional words.
struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ list: [String]) {
        var index = 0
        while index < list.count {
            let word = list[index]
            if word.hasPrefix("--") {
                if index + 1 < list.count, !list[index + 1].hasPrefix("--") {
                    options[word] = list[index + 1]
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
