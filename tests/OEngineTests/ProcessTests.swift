import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 4 §15 — the spike fixture library and machine, the soak script, the
/// `oengine` process's pieces that run without a screen: the roots load, the
/// script parses and plays through the headless engine, the driver sends it
/// over UDP, the black box reads back for the thresholds, the fixture media
/// writes, and the command line answers.
final class ProcessTests: XCTestCase {
    static var spikeRoot: URL { EngineFixtures.repoRoot.appendingPathComponent("tests/fixtures/spike") }
    static var scenarioURL: URL { EngineFixtures.repoRoot.appendingPathComponent("tests/soak/spike.json") }

    static func roots() throws -> LoadedRoots {
        try LoadedRoots.load(libraryRoot: spikeRoot.appendingPathComponent("library"), machineRoot: spikeRoot.appendingPathComponent("machine"))
    }

    // MARK: - The fixtures

    func test_spikeRootsLoadClean() throws {
        let roots = try Self.roots()
        XCTAssertFalse(roots.hasErrors, roots.issueLines.joined(separator: "\n"))
        XCTAssertEqual(roots.library.lists.count, 1, "Spec 4 §15: a fixture list of public-domain hymn lyrics")
        XCTAssertEqual(roots.library.mediaIndex.entries.count, 6)
        XCTAssertEqual(roots.library.channels.map(\.number), [1, 2])
        XCTAssertEqual(roots.machine.outputs.map(\.kind), [.display, .display], "Spec 4 §15: two displays on the dev Mac; the bench edits the main output")
        XCTAssertEqual(roots.machine.stacks.count, 2)
        XCTAssertEqual(roots.machine.audioOutputs.map(\.kind), [.device])
        XCTAssertEqual(roots.mediaRoot.lastPathComponent, "media")
        XCTAssertEqual(roots.mediaRoot.deletingLastPathComponent().lastPathComponent, "library")
        // Every list's media ref is in the index: no missing media in the fixture (Spec 1 §7).
        let ids = roots.mediaIDs
        for list in roots.library.lists {
            for cue in list.cues {
                for command in cue.commands {
                    if case .channelWrite(let write) = command.command, case .media(let m) = write.content {
                        XCTAssertTrue(ids.contains(m.ref), "\(list.title): \(m.ref)")
                    }
                }
            }
        }
        let list = try XCTUnwrap(roots.library.lists.first)
        XCTAssertEqual(list.cues.count, 27)
        XCTAssertEqual(Set(list.cues.map(\.section)).count, 6, "five hymns and the clapper")
        // Public-domain hymns only (CLAUDE.md).
        XCTAssertEqual(list.copyright, "Public domain")
    }

    func test_scenarioParsesAgainstTheSpikeLibrary() throws {
        let roots = try Self.roots()
        let scenario = try SoakScenario.load(Self.scenarioURL)
        XCTAssertEqual(scenario.loopMs, 600_000, "Spec 4 §15: a stack switch and a blackout every ten minutes")
        XCTAssertTrue(scenario.loop)
        let (commands, rejections) = scenario.parsed(options: ParseOptions(mediaIDs: roots.mediaIDs))
        XCTAssertTrue(rejections.isEmpty, rejections.map { "\($0.step): \($0.rejection.message)" }.joined(separator: "\n"))
        XCTAssertEqual(commands.count, scenario.steps.count)
        XCTAssertEqual(scenario.steps, scenario.steps.sorted { $0.atMs < $1.atMs }, "steps in time order")
        XCTAssertTrue(commands.contains(.outputStack(output: 1, stack: 2)))
        XCTAssertTrue(commands.contains(.stackBlackout(stack: 1, state: .on)))
        XCTAssertTrue(commands.contains(.stackBlackout(stack: 1, state: .off)))
        XCTAssertEqual(commands.filter { if case .listCue(1, 1) = $0 { return true } else { return false } }.count, 5, "the list restarts five times a loop")
        XCTAssertEqual(commands.filter { $0 == .next }.count, scenario.steps.count - 9)
        // The schedule loops: two passes for twenty minutes, and the end is cut at the duration.
        XCTAssertEqual(scenario.schedule(durationMs: 1_200_000).count, scenario.steps.count * 2)
        XCTAssertEqual(scenario.schedule(durationMs: 12_000).map(\.atMs), [0, 5000, 10_000])
        var once = scenario
        once.loop = false
        XCTAssertEqual(once.schedule(durationMs: 1_200_000).count, scenario.steps.count)
    }

    /// Spec 4 §15 — the script through the headless engine over the fakes: one
    /// cycle of the six lists, no rejection, the confidence +1 slot right.
    func test_scenarioPlaysThroughTheHeadlessEngine() throws {
        let roots = try Self.roots()
        let engine = try HeadlessEngine(library: roots.library, machine: roots.machine, mediaRoot: roots.mediaRoot)
        let scenario = try SoakScenario.load(Self.scenarioURL)
        let ticksPerMs = 60.0 / 1000
        var ticksDone = 0
        var checked = 0
        for step in scenario.steps where step.atMs < 135_000 {
            let due = Int(Double(step.atMs) * ticksPerMs)
            engine.tick(count: due - ticksDone)
            ticksDone = due
            XCTAssertNil(engine.send(step.cmd), step.cmd)
            engine.tick()
            ticksDone += 1
            XCTAssertTrue(engine.rejections.isEmpty, "\(step.cmd): \(engine.rejections.map(\.message))")
            // After every list or next: the confidence stack's +1 box is the projection's next lyric (Spec 4 §9).
            if let confidence = engine.lastPlan?.stackPasses.first(where: { $0.stack == 2 }) {
                let projected = lookahead(engine.state, steps: 1, context: engine.control.projectionContext(frame: engine.frame, source: CommandSource(kind: .engine)))
                if case .text(let t)? = projected?.channels[2]?.content {
                    XCTAssertEqual(confidence.boxes.first { $0.offset == 1 }?.text, t.fields["body"], "\(step.cmd) at \(step.atMs)")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 15, "the +1 slot was checked across the cycle")
        XCTAssertEqual(engine.state.channels[1]?.content.media?.ref, "sha256:c1a99e71c1a99e71c1a99e71c1a99e71c1a99e71c1a99e71c1a99e71c1a99e71", "the cycle ends on the clapper")
        XCTAssertEqual(engine.state.channels[2]?.content.kind, "empty")
        XCTAssertEqual(engine.recording?.encoded.count, ticksDone, "every tick encoded")
        let metrics = engine.drainMetrics()
        XCTAssertFalse(metrics.contains { $0.planReused }, "the control side kept up")
    }

    // MARK: - The driver

    func test_driverSendsTheScheduleOverUDP() throws {
        let roots = try Self.roots()
        let received = Counter()
        let server = OSCServer(port: 0, targets: [], mediaIDs: roots.mediaIDs, log: EngineLog(category: "test")) { _ in received.increment() }
        try server.start()
        defer { server.stop() }
        let scenario = SoakScenario(title: "three", loop: false, loopMs: 150, steps: [
            SoakScenario.Step(atMs: 0, cmd: "list 1 cue 1"),
            SoakScenario.Step(atMs: 50, cmd: "next"),
            SoakScenario.Step(atMs: 100, cmd: "channel 1 write media sha256:f1e1d0a1f1e1d0a1f1e1d0a1f1e1d0a1f1e1d0a1f1e1d0a1f1e1d0a1f1e1d0a1 loop transition 2 1.0 once"),
            SoakScenario.Step(atMs: 120, cmd: "channel 9 nonsense"),
        ])
        let driver = try ScenarioDriver(scenario: scenario, options: ParseOptions(mediaIDs: roots.mediaIDs),
                                        to: OSCPeer(host: "127.0.0.1", port: server.boundPort), log: EngineLog(category: "test"))
        let started = Date()
        driver.run(durationMs: 200)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.19, "the driver waits out the duration")
        XCTAssertEqual(driver.sent, 3)
        XCTAssertEqual(driver.failed.count, 1, "the step that does not parse is reported, not sent")
        XCTAssertTrue(waitUntil(5) { received.value == 3 })
        XCTAssertEqual(server.rejected, 0)
    }

    func test_peerParsing() throws {
        XCTAssertEqual(try OSCClient.peer("10.20.0.15:9000"), OSCPeer(host: "10.20.0.15", port: 9000))
        XCTAssertEqual(try OSCClient.peer("localhost:8000"), OSCPeer(host: "127.0.0.1", port: 8000))
        XCTAssertEqual(try OSCClient.peer(":8000"), OSCPeer(host: "127.0.0.1", port: 8000))
        XCTAssertThrowsError(try OSCClient.peer("nonsense"))
        XCTAssertThrowsError(try OSCClient.peer("host:port"))
    }

    // MARK: - The black box read back

    func test_blackBoxReadsBackForTheThresholds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-blackbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let box = BlackBox(folder: folder)
        let tickNs: Int64 = 16_666_667
        for frame in 0..<200 {
            var record = TickRecord()
            record.frame = Int64(frame)
            record.masterTimeNs = Int64(frame) * tickNs
            record.gpuChannelNs = 1_500_000
            record.gpuStackNs = 500_000
            record.cpuEncodeNs = 300_000
            record.channelPasses = 1
            record.stackPasses = 2
            if frame == 7 { record.markRepeat(channel: 1) }
            record.setQueueDepth(3, instance: 0)
            try box.append(record, at: Date(timeIntervalSince1970: 1_793_368_800))
            try box.append(PresentRecord(output: 1, frame: Int64(frame), rePresented: false, latencyNs: 2_000_000, completion: nil, dropsSinceStart: 0),
                           at: Date(timeIntervalSince1970: 1_793_368_800))
            try box.append(PresentRecord(output: 3, frame: Int64(frame), rePresented: false, latencyNs: 1_000_000, completion: .completed, dropsSinceStart: 0),
                           at: Date(timeIntervalSince1970: 1_793_368_800))
        }
        for minute in 0..<13 {
            try box.append(MinuteRecord(minute: minute, memoryBytes: 500_000_000 + Int64(minute) * 1_000_000, decoderSessions: 2,
                                        textCacheHitRate: 0.98, audioUnderruns: 0, watchdogEvents: 0, watchdogRecoveries: 0),
                           at: Date(timeIntervalSince1970: 1_793_368_800))
        }
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: tickNs, sdiOutputs: [3], displayOutputs: [1])
        XCTAssertEqual(run.ticks.count, 200)
        XCTAssertEqual(run.presents.count, 400)
        XCTAssertEqual(run.minutes.count, 13)
        XCTAssertEqual(run.ticks[7].videoRepeat, [1])
        XCTAssertEqual(run.ticks[7].instanceQueueDepths, [3])
        XCTAssertEqual(run.ticks[7].gpuTotalNs, 2_000_000)
        XCTAssertEqual(run.presents.filter { $0.output == 3 }.first?.completion, .completed)
        XCTAssertEqual(run.minutes[12].memoryBytes, 512_000_000)
        XCTAssertEqual(SoakThresholds.evaluate(run), [])
        let report = BlackBoxReader.report(run: run, failures: [])
        XCTAssertTrue(report.contains("PASS"), report)
        XCTAssertTrue(report.contains("output 3 (SDI)"), report)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["evaluate", "--blackbox", folder.path, "--sdi", "3", "--display", "1"]), 0)

        // One dropped SDI frame fails the run (Spec 4 §13).
        try box.append(PresentRecord(output: 3, frame: 200, rePresented: false, latencyNs: 0, completion: .dropped, dropsSinceStart: 1),
                       at: Date(timeIntervalSince1970: 1_793_368_800))
        let failed = try BlackBoxReader.load(folder: folder, tickNanoseconds: tickNs, sdiOutputs: [3], displayOutputs: [1])
        XCTAssertEqual(SoakThresholds.evaluate(failed), [.sdiDroppedOrLate(output: 3, count: 1)])
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["evaluate", "--blackbox", folder.path, "--sdi", "3", "--display", "1"]), 1)
        XCTAssertTrue(BlackBoxReader.report(run: failed, failures: SoakThresholds.evaluate(failed)).contains("FAIL"))
    }

    // MARK: - The fixture media

    func test_makeFixturesWritesEveryItem() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-spike-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(SpikeFixtures.exist(in: folder))
        let written = try SpikeFixtures.write(into: folder, scale: 0.1)
        XCTAssertEqual(written.count, 6)
        XCTAssertTrue(SpikeFixtures.exist(in: folder))
        let still = try StillSource.decode(url: folder.appendingPathComponent("stills/cross.png"), fitWithin: PixelSize(width: 4096, height: 2160))
        XCTAssertEqual(still.width, 640)
        XCTAssertEqual(still.height, 360)
        let centre = still[320, 180]
        XCTAssertGreaterThan(centre.r, 0.9, "the cross is white at the centre")
        // The index names what was written, path for path.
        let roots = try Self.roots()
        XCTAssertEqual(Set(roots.library.mediaIndex.entries.map(\.path)), Set(SpikeFixtures.items().map(\.path)))
        for entry in roots.library.mediaIndex.entries where entry.kind == .video {
            let item = try XCTUnwrap(SpikeFixtures.items().first { $0.path == entry.path })
            XCTAssertEqual(entry.durationMs, item.clip?.durationMs, entry.path)
            XCTAssertEqual(entry.hasAudio, item.clip?.audio != nil, entry.path)
            XCTAssertEqual(entry.codec, item.clip?.codec.fourCC, entry.path)
        }
    }

    // MARK: - The command line

    func test_commandLineAnswers() {
        XCTAssertEqual(OEngineCommandLine.run(arguments: []), 2)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["version"]), 0)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["help"]), 0)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["bogus"]), 2)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["evaluate"]), 1, "missing --blackbox")
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["evaluate", "--blackbox", "/nonexistent/folder"]), 1)
        XCTAssertEqual(OEngineCommandLine.run(arguments: ["make-fixtures"]), 1, "missing the folder")
        let args = Arguments(["--library", "/a", "--no-audio", "--seconds", "30", "--sdi", "2, 3", "folder"])
        XCTAssertEqual(try args.string("--library"), "/a")
        XCTAssertTrue(args.flag("--no-audio"))
        XCTAssertEqual(try args.int("--seconds"), 30)
        XCTAssertEqual(try args.ints("--sdi"), [2, 3])
        XCTAssertEqual(args.positional, ["folder"])
        XCTAssertNil(try args.int("--minutes"))
        XCTAssertThrowsError(try args.string("--machine"))
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
