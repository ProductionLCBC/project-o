import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §2, "The app and the engine", and §18's "Area 13, the engine" —
/// "A closed socket shows the banner and relaunches ...; it is started again
/// however often it ends, at once for the first three ends within two
/// minutes and five seconds after each end from the fourth, an exit with
/// status 3 isn't an end, and an engine that runs 15 seconds without a
/// socket is offered Restart the engine and never killed without it; ... a
/// silent engine shows "isn't responding" and is never killed without the
/// button; a different `api` asks to restart".
///
/// The supervisor with a launcher, a connector and a clock of the test's
/// own: no engine is started and no time is waited for.
@MainActor
final class EngineSupervisorTests: XCTestCase {
    /// A supervisor and everything it was given.
    @MainActor
    final class Rig {
        let folder: URL
        let roots: EngineRoots
        let launcher = FakeLauncher()
        let connector = FakeConnector()
        let clock = ManualClock()
        let store = ShowStore()
        let supervisor: EngineSupervisor
        var phases: [EngineSupervisor.Phase] = []
        static let helper = URL(fileURLWithPath: "/Applications/Project O.app/Contents/Helpers/oengine")

        init(firstRun: Bool = false) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-supervisor-\(UUID().uuidString)")
            roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
            if !firstRun {
                try FileManager.default.createDirectory(at: roots.machine, withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: roots.machine.appendingPathComponent("machine.json"))
            }
            supervisor = EngineSupervisor(roots: roots, store: store, launcher: launcher, connector: connector, clock: clock,
                                          settings: .init(executable: Self.helper, appVersion: "0.1.0"), hop: immediateHop)
            supervisor.operatorScreen = { "display:37D8832A" }
            supervisor.onPhase = { [unowned self] in self.phases.append($0) }
        }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }

        /// The engine the app started opens its socket and says `hello`.
        func engineComesUp(api: Int = Hello.api, engine: String = "0.1.0", pid: Int32? = nil) {
            connector.isListening = true
            clock.advance(by: 0.1)
            connector.last?.engineSends(Hello.test(api: api, engine: engine, pid: pid ?? launcher.pids.last ?? 4182).message)
        }

        /// The engine process ends and takes its socket with it.
        func engineDies(_ exit: EngineExit = .signaled(SIGSEGV)) {
            connector.isListening = false
            connector.last?.engineCloses()
            if let pid = launcher.pids.last { launcher.exit(pid, exit) }
        }

        /// The notes the app sent on the newest connection, by their event.
        func notes(on transport: FakeTransport? = nil) -> [[String: JSONValue]] {
            ((transport ?? connector.last)?.sent("note") ?? []).compactMap { $0["note"]?.objectValue }
        }

        func writeConsole(_ text: String) throws {
            try FileManager.default.createDirectory(at: roots.consoleLog.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: roots.consoleLog)
        }
    }

    private func rig(firstRun: Bool = false) throws -> Rig {
        let rig = try Rig(firstRun: firstRun)
        addTeardownBlock { await MainActor.run { rig.remove() } }
        return rig
    }

    // MARK: - Starting

    func test_anEngineThatAnswersIsUsedWhoeverStartedIt() throws {
        let rig = try rig()
        rig.connector.isListening = true
        rig.launcher.running(pid: 4182, path: "/somewhere/oengine")
        rig.supervisor.start()
        XCTAssertEqual(rig.supervisor.phase, .starting)
        rig.connector.last?.engineSends(Hello.test(pid: 4182).message)
        XCTAssertEqual(rig.supervisor.phase, .connected)
        XCTAssertEqual(rig.launcher.launches, [], "nothing was started")
        XCTAssertEqual(rig.connector.last?.sent.map { $0["type"]?.stringValue }.prefix(4), ["subscribe", "query", "query", "query"])
        let started = try XCTUnwrap(rig.notes().first)
        XCTAssertEqual(started["event"], .string("appStarted"))
        XCTAssertEqual(started["app"], .string("0.1.0"))
        XCTAssertEqual(started["launched"], .bool(false), "it found the engine running")
    }

    func test_withNoEngineAnsweringItStartsOneAndWaitsForItsSocket() throws {
        let rig = try rig()
        rig.supervisor.start()
        XCTAssertEqual(rig.launcher.launches.count, 1)
        let launch = try XCTUnwrap(rig.launcher.launches.first)
        XCTAssertEqual(launch.executable, Rig.helper)
        XCTAssertEqual(launch.arguments, ["run", "--library", rig.roots.library.path, "--machine", rig.roots.machine.path, "--operator-screen", "display:37D8832A"])
        XCTAssertEqual(launch.consoleLog, rig.roots.machine.appendingPathComponent("logs/engine-console.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.roots.consoleLog.deletingLastPathComponent().path), "the log's folder is there to open it in")
        XCTAssertEqual(rig.supervisor.phase, .starting, "Starting the engine…")
        rig.clock.advance(by: 3)
        XCTAssertEqual(rig.supervisor.phase, .starting)
        XCTAssertEqual(rig.launcher.launches.count, 1, "one engine, however often the socket is tried")
        rig.engineComesUp()
        XCTAssertEqual(rig.supervisor.phase, .connected)
        XCTAssertEqual(rig.notes().first?["launched"], .bool(true))
        XCTAssertEqual(rig.phases, [.starting, .connected])
    }

    func test_atFirstRunItAddsTheCampusAndTheReleasedScreensAndRelaunchGoesLast() throws {
        let rig = try rig(firstRun: true)
        rig.supervisor.campus = { "Manheim" }
        rig.supervisor.releasedScreens = { ["display:AAAA", "display:BBBB"] }
        rig.supervisor.start()
        XCTAssertEqual(Array(rig.launcher.arguments().dropFirst(5)),
                       ["--operator-screen", "display:37D8832A", "--campus", "Manheim", "--released", "display:AAAA", "--released", "display:BBBB"])
        rig.engineComesUp()
        rig.engineDies()
        rig.clock.advance(by: 0)
        XCTAssertEqual(rig.launcher.arguments(1).last, "--relaunch", "a flag with no value goes last, where the engine can't read a word as its value")
        XCTAssertTrue(rig.launcher.arguments(1).contains("--released"))
    }

    func test_fifteenSecondsWithoutASocketShowsTheConsoleLinesAndNeverEndsTheEngine() throws {
        let rig = try rig()
        try rig.writeConsole((1...30).map { "line \($0)" }.joined(separator: "\n") + "\n")
        rig.supervisor.start()
        rig.clock.advance(by: 14.9)
        XCTAssertEqual(rig.supervisor.phase, .starting)
        rig.clock.advance(by: 0.2)
        guard case .noSocket(let console) = rig.supervisor.phase else { return XCTFail("\(rig.supervisor.phase)") }
        XCTAssertEqual(console.count, 20, "the console log's last lines")
        XCTAssertEqual(console.first, "line 11")
        XCTAssertEqual(console.last, "line 30")
        XCTAssertEqual(rig.launcher.kills, [], "never killed without the button")
        XCTAssertEqual(rig.launcher.launches.count, 1)
        // The engine was only slow: its socket comes up, and the app connects.
        rig.connector.isListening = true
        rig.clock.advance(by: 1)
        rig.connector.last?.engineSends(Hello.test(pid: rig.launcher.pids[0]).message)
        XCTAssertEqual(rig.supervisor.phase, .connected)
    }

    func test_anExitWithStatus3IsNotAnEnd() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.launcher.exit(rig.launcher.pids[0], .exited(status: 3))
        rig.clock.advance(by: 5)
        XCTAssertEqual(rig.supervisor.phase, .starting, "another engine holds the root: the app keeps waiting for the socket")
        XCTAssertEqual(rig.launcher.launches.count, 1, "and starts no other")
        // The engine that holds the root answers.
        rig.launcher.running(pid: 777, path: "/somewhere/oengine")
        rig.engineComesUp(pid: 777)
        XCTAssertEqual(rig.supervisor.phase, .connected)
        XCTAssertEqual(rig.notes().map { $0["event"] }, [.string("appStarted")], "no engineEnded: nothing ended")
    }

    func test_aRefusedFirstRunStopsAndIsNotTriedAgain() throws {
        let rig = try rig(firstRun: true)
        try rig.writeConsole("first run needs --campus and --operator-screen\n")
        rig.supervisor.start()
        rig.launcher.exit(rig.launcher.pids[0], .exited(status: 2))
        XCTAssertEqual(rig.supervisor.phase, .firstRunRefused(console: ["first run needs --campus and --operator-screen"]))
        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.launcher.launches.count, 1, "Adam's answer, 2026-11-17: status 2 stops and shows the first-run sheet again")
        // The sheet has been answered: the app starts over.
        rig.supervisor.campus = { "Manheim" }
        rig.supervisor.start()
        XCTAssertEqual(rig.launcher.launches.count, 2)
    }

    // MARK: - When the engine stops

    func test_aClosedSocketWithTheProcessGoneShowsTheBannerAndRelaunches() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        rig.engineDies(.signaled(SIGSEGV))
        XCTAssertEqual(rig.supervisor.phase, .restarting(ends: 1, console: []), "The engine stopped. Restarting…")
        XCTAssertFalse(rig.store.isConnected)
        rig.clock.advance(by: 0)
        XCTAssertEqual(rig.launcher.launches.count, 2, "at once")
        XCTAssertEqual(rig.launcher.arguments(1).last, "--relaunch")
        rig.engineComesUp()
        XCTAssertEqual(rig.supervisor.phase, .connected)
        let notes = rig.notes()
        XCTAssertEqual(notes.map { $0["event"] }, [.string("appStarted"), .string("engineEnded")])
        XCTAssertEqual(notes[1]["restart"], .bool(false))
        XCTAssertEqual(notes[1]["count"], .number(1))
        XCTAssertNil(notes[1]["status"], "a signal ended it: there is no exit status to give")
    }

    func test_itIsStartedAgainHoweverOftenItEndsAtOnceThreeTimesThenEveryFiveSeconds() throws {
        let rig = try rig()
        try rig.writeConsole("the engine's last words\n")
        rig.supervisor.start()
        for end in 1...3 {
            rig.launcher.exit(rig.launcher.pids[end - 1], .exited(status: 1))
            XCTAssertEqual(rig.supervisor.phase, .restarting(ends: end, console: end >= 3 ? ["the engine's last words"] : []),
                           "from the third end the banner shows the console log's last lines")
            rig.clock.advance(by: 0)
            XCTAssertEqual(rig.launcher.launches.count, end + 1, "end \(end): at once")
        }
        rig.launcher.exit(rig.launcher.pids[3], .exited(status: 1))
        rig.clock.advance(by: 4.9)
        XCTAssertEqual(rig.launcher.launches.count, 4, "the fourth end waits")
        rig.clock.advance(by: 0.1)
        XCTAssertEqual(rig.launcher.launches.count, 5, "five seconds")
        for end in 5...12 {
            rig.launcher.exit(rig.launcher.pids[end - 1], .exited(status: 1))
            rig.clock.advance(by: 5)
            XCTAssertEqual(rig.launcher.launches.count, end + 1, "end \(end): started again")
        }
        XCTAssertEqual(rig.launcher.kills, [])
        // The one that stays up is told how many ended, with the status of an engine the app started.
        rig.engineComesUp()
        let ended = try XCTUnwrap(rig.notes().last)
        XCTAssertEqual(ended["event"], .string("engineEnded"))
        XCTAssertEqual(ended["count"], .number(12))
        XCTAssertEqual(ended["status"], .number(1))
    }

    /// Spec 10 §2 — "From the third such end the banner says how many there
    /// have been and shows the console log's last lines". Adam's answer at
    /// Area 13's first stop, 2026-11-17 — the banner counts the ends in the
    /// two minutes before, the ones the cadence counts, so an engine that
    /// says `hello` and then ends every time still gets there.
    func test_theBannerCountsTheEndsOfTheLastTwoMinutesEvenWhenEachEngineConnectedFirst() throws {
        let rig = try rig()
        try rig.writeConsole("the engine's last words\n")
        rig.supervisor.start()
        for end in 1...3 {
            rig.engineComesUp()
            XCTAssertEqual(rig.supervisor.phase, .connected)
            rig.engineDies()
            XCTAssertEqual(rig.supervisor.phase, .restarting(ends: end, console: end >= 3 ? ["the engine's last words"] : []),
                           "end \(end), each after a connection")
            rig.clock.advance(by: 0)
        }
        // The fourth engine is slow to open its socket, and two minutes pass before it ends too.
        rig.clock.advance(by: 121)
        rig.engineComesUp()
        XCTAssertEqual(rig.supervisor.phase, .connected)
        rig.engineDies()
        XCTAssertEqual(rig.supervisor.phase, .restarting(ends: 1, console: []), "the three ends of more than two minutes ago are no longer counted")
    }

    func test_rootsThatDoNotLoadAreRetriedOnTheSameCadenceWithTheConsoleLines() throws {
        let rig = try rig()
        try rig.writeConsole("the machine root doesn't load: stacks.json\n")
        rig.supervisor.start()
        for end in 1...4 {
            rig.launcher.exit(rig.launcher.pids[end - 1], .exited(status: 4))
            rig.clock.advance(by: 5)
        }
        XCTAssertEqual(rig.launcher.launches.count, 5, "status 4 is an end like any other (Adam's answer, 2026-11-17)")
        rig.launcher.exit(rig.launcher.pids[4], .exited(status: 4))
        XCTAssertEqual(rig.supervisor.phase, .restarting(ends: 5, console: ["the machine root doesn't load: stacks.json"]))
    }

    func test_anEngineThatCannotBeStartedAtAllIsAnEndWithItsReason() throws {
        let rig = try rig()
        rig.launcher.failure = .spawn(path: Rig.helper.path, errno: ENOENT)
        rig.supervisor.start()
        guard case .restarting(1, let console) = rig.supervisor.phase else { return XCTFail("\(rig.supervisor.phase)") }
        XCTAssertEqual(console.count, 1, "the banner says why")
        rig.launcher.failure = nil
        rig.clock.advance(by: 0)
        XCTAssertEqual(rig.launcher.launches.count, 1, "and it is tried again")
    }

    func test_aSocketThatClosesWhileTheProcessLivesIsNotAnEnd() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let first = try XCTUnwrap(rig.connector.last)
        // The engine closes this connection, as it closes a client that fell too far behind, and goes on running.
        first.engineCloses()
        XCTAssertFalse(rig.store.isConnected)
        rig.clock.advance(by: 0)
        XCTAssertEqual(rig.connector.connections.count, 2, "it connects again at once")
        rig.connector.last?.engineSends(Hello.test(pid: rig.launcher.pids[0]).message)
        XCTAssertEqual(rig.supervisor.phase, .connected)
        XCTAssertEqual(rig.launcher.launches.count, 1, "no second engine")
        XCTAssertEqual(rig.notes().map { $0["event"] }, [.string("appStarted")], "and nothing ended")
        XCTAssertEqual(rig.connector.last?.queries, ["state", "catalog", "media"], "it asks again")
    }

    func test_aKeyPressedWhileTheEngineIsAwaySendsNothingLater() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let session = try XCTUnwrap(rig.supervisor.session)
        rig.engineDies()
        XCTAssertNil(rig.supervisor.session)
        var reply: Reply?? = .none
        XCTAssertNil(session.send(.command(.next, source: .key)) { reply = .some($0) }, "dropped, never queued")
        XCTAssertEqual(reply, .some(nil))
        rig.clock.advance(by: 0)
        rig.engineComesUp()
        XCTAssertEqual(rig.connector.last?.sent("command"), [], "the next engine is sent no command the app held back")
    }

    // MARK: - When it doesn't answer

    func test_itPingsEveryTwoSecondsAndASilentEngineIsNotRespondingAfterFive() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let transport = try XCTUnwrap(rig.connector.last)
        rig.clock.advance(by: 2)
        XCTAssertEqual(transport.sent("ping").count, 1)
        transport.engineAnswers(transport.id(of: "ping"), [:], type: "pong")
        rig.clock.advance(by: 2)
        XCTAssertEqual(transport.sent("ping").count, 2)
        // From here the engine says nothing.
        rig.clock.advance(by: 4.9)
        XCTAssertEqual(rig.supervisor.phase, .connected)
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.supervisor.phase, .notResponding, "The engine isn't responding")
        rig.clock.advance(by: 60)
        XCTAssertEqual(rig.launcher.kills, [], "The app never ends the engine on its own, since the outputs may still be playing")
        XCTAssertEqual(rig.launcher.launches.count, 1)
        // A pong, however late, clears the banner.
        transport.engineAnswers(transport.id(of: "ping"), [:], type: "pong")
        XCTAssertEqual(rig.supervisor.phase, .connected)
    }

    func test_restartTheEngineKillsItByItsPidAndStartsItAgainAsARelaunch() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let pid = rig.launcher.pids[0]
        rig.clock.advance(by: 9)
        XCTAssertEqual(rig.supervisor.phase, .notResponding)
        rig.connector.isListening = false
        rig.supervisor.restartEngine()
        XCTAssertEqual(rig.launcher.kills, [pid], "a kill, by its pid")
        XCTAssertEqual(rig.launcher.launches.count, 2)
        XCTAssertEqual(rig.launcher.arguments(1).last, "--relaunch", "as a relaunch, so the last state comes back")
        XCTAssertEqual(rig.supervisor.phase, .starting)
        rig.engineComesUp()
        XCTAssertEqual(rig.supervisor.phase, .connected)
        let ended = try XCTUnwrap(rig.notes().last)
        XCTAssertEqual(ended["event"], .string("engineEnded"))
        XCTAssertEqual(ended["restart"], .bool(true), "Restart the engine ended it")
        // "not counting restarts the operator asked for": the next three real ends are still at once.
        for end in 1...3 {
            rig.engineDies()
            rig.clock.advance(by: 0)
            XCTAssertEqual(rig.launcher.launches.count, 2 + end)
            rig.engineComesUp()
        }
    }

    func test_aDifferentApiAsksToRestartAndIsNeverDriven() throws {
        let rig = try rig()
        rig.connector.isListening = true
        rig.launcher.running(pid: 4182, path: "/old/Project O.app/Contents/Helpers/oengine")
        rig.supervisor.start()
        rig.connector.last?.engineSends(Hello.test(api: 2, engine: "0.9.0", pid: 4182).message)
        XCTAssertEqual(rig.supervisor.phase, .wrongAPI(engine: "0.9.0"))
        XCTAssertNil(rig.supervisor.session)
        XCTAssertEqual(rig.connector.last?.sent, [], "nothing is sent to an engine the app can't drive")
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.supervisor.phase, .wrongAPI(engine: "0.9.0"), "it waits for the operator")
        rig.connector.isListening = false
        rig.supervisor.restartEngine()
        XCTAssertEqual(rig.launcher.kills, [4182])
        XCTAssertEqual(rig.launcher.launches.count, 1, "and this build's engine is started in its place")
    }

    func test_anEngineOfAnotherBuildWithTheSameApiIsDrivenAndKnownAsAnother() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp(engine: "0.0.9")
        XCTAssertEqual(rig.supervisor.phase, .connected, "versions may differ while api matches")
        XCTAssertEqual(rig.supervisor.anotherBuild, AnotherBuild(engine: "0.0.9", app: "0.1.0"), "the banner says so and offers Restart the engine")
        rig.engineDies()
        XCTAssertNil(rig.supervisor.anotherBuild, "while the engine is away the banner says that")
        let same = try self.rig()
        same.supervisor.start()
        same.engineComesUp()
        XCTAssertNil(same.supervisor.anotherBuild)
    }

    func test_noHelloFromAnEngineHoldingTheRootOffersTheRestartByTheLockFilesPid() throws {
        let rig = try rig()
        try Data("5150\n".utf8).write(to: rig.roots.lockFile)
        rig.launcher.running(pid: 5150, path: "/Applications/Project O.app/Contents/Helpers/oengine")
        rig.connector.isListening = true
        rig.supervisor.start()
        rig.clock.advance(by: 4.9)
        XCTAssertEqual(rig.supervisor.phase, .starting)
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.supervisor.phase, .noHello)
        XCTAssertEqual(rig.launcher.kills, [])
        rig.connector.isListening = false
        rig.supervisor.restartEngine()
        XCTAssertEqual(rig.launcher.kills, [5150], "found by the process id in .engine.lock")
        XCTAssertEqual(rig.launcher.launches.count, 1)
    }

    func test_aStaleLockFileNamingSomeOtherProgramEndsNothing() throws {
        let rig = try rig()
        try Data("6000\n".utf8).write(to: rig.roots.lockFile)
        rig.launcher.running(pid: 6000, path: "/usr/bin/some-other-program")
        rig.connector.isListening = true
        rig.supervisor.start()
        rig.clock.advance(by: 6)
        XCTAssertEqual(rig.supervisor.phase, .noHello)
        rig.connector.isListening = false
        rig.supervisor.restartEngine()
        XCTAssertEqual(rig.launcher.kills, [], "the file outlives its engine, and the id names another program by now")
        XCTAssertEqual(rig.launcher.launches.count, 1, "nothing holds the root: an engine is started")
    }

    // MARK: - Quitting

    func test_quitSendsStopAndShowsWhatTheEngineCouldNotWrite() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let transport = try XCTUnwrap(rig.connector.last)
        var unsaved: [String]?? = .none
        rig.supervisor.stopEngine { unsaved = .some($0) }
        XCTAssertEqual(rig.supervisor.phase, .quitting)
        XCTAssertEqual(transport.sent("stop").count, 1)
        XCTAssertEqual(unsaved, .none, "it waits for the answer")
        transport.engineAnswers(transport.id(of: "stop"), ["result": .string("ok"), "unsaved": .array([.string("lists/042-great-is-thy-faithfulness.json")])], type: "result")
        XCTAssertEqual(unsaved, .some(["lists/042-great-is-thy-faithfulness.json"]))
        // The engine exits after its answer: that is no end, and nothing is started again.
        rig.engineDies(.exited(status: 0))
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.launcher.launches.count, 1)
        XCTAssertEqual(rig.launcher.kills, [])
    }

    func test_quitKillsAnEngineThatDoesNotAnswerWithinTenSeconds() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        var unsaved: [String]?? = .none
        rig.supervisor.stopEngine { unsaved = .some($0) }
        rig.clock.advance(by: 9.9)
        XCTAssertEqual(rig.launcher.kills, [])
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.launcher.kills, [rig.launcher.pids[0]], "since Quit asked for the outputs to stop")
        XCTAssertEqual(unsaved, .some(nil))
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.launcher.launches.count, 1, "and it isn't started again")
    }

    func test_keepOutputsRunningLeavesTheEngineAlone() throws {
        let rig = try rig()
        rig.supervisor.start()
        rig.engineComesUp()
        let transport = try XCTUnwrap(rig.connector.last)
        rig.supervisor.leaveEngineRunning()
        XCTAssertEqual(transport.sent("stop"), [])
        XCTAssertTrue(transport.isClosed, "the app lets go of the connection")
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.launcher.kills, [])
        XCTAssertEqual(rig.launcher.launches.count, 1)
    }
}
