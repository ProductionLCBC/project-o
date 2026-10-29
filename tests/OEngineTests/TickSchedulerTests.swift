import XCTest
import OCore
import Synchronization
@testable import OEngine

/// Spec 4 §2 — the disciplined timer: ticks follow the master clock, free-run
/// one tick when a reference is late, and fall back to the next clock within
/// a second when the master disappears. Spec 4 §3 — the threaded engine.
final class TickSchedulerTests: XCTestCase {
    /// A clock that ticks on its own thread for a while, then goes silent.
    final class DyingClock: MasterClock, @unchecked Sendable {
        let name = "dying"
        let ticksBeforeDeath: Int
        private var thread: Thread?
        private let running = Atomic<Bool>(false)

        init(ticksBeforeDeath: Int) { self.ticksBeforeDeath = ticksBeforeDeath }

        func now() -> MonotonicTime { MonotonicClock.now() }

        func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void) {
            running.store(true, ordering: .releasing)
            let period = Double(rate.nanosecondsPerFrame) / 1_000_000_000
            let thread = Thread { [self] in
                for tick in 0..<ticksBeforeDeath where running.load(ordering: .relaxed) {
                    let now = MonotonicClock.now()
                    handler(TickTime(tick: Int64(tick), reference: now, wake: now))
                    Thread.sleep(forTimeInterval: period)
                }
            }
            self.thread = thread
            thread.start()
        }

        func stop() { running.store(false, ordering: .releasing) }
    }

    func test_ticksFollowTheClockThenFreeRunThenFallBack() {
        let log = EngineLog(category: "test-scheduler")
        let ticks = Atomic<Int64>(0)
        let scheduler = TickScheduler(clocks: [DyingClock(ticksBeforeDeath: 6), TimerClock()], rate: .fps60, log: log) { _ in
            ticks.add(1, ordering: .relaxed)
        }
        scheduler.start()
        XCTAssertTrue(waitUntil(5) { scheduler.fallbacks >= 1 }, "falls back within a second of the master dying")
        XCTAssertGreaterThan(scheduler.freeRunTicks, 0, "free-ran while waiting for the reference")
        let afterFallback = ticks.load(ordering: .relaxed)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertGreaterThan(ticks.load(ordering: .relaxed), afterFallback + 5, "the timer clock keeps the ticks coming")
        XCTAssertEqual(scheduler.activeClock.name, "timer")
        XCTAssertTrue(log.contains("falling back to timer"))
        scheduler.stop()
    }

    func test_timerClockTicksAtTheRate() {
        let clock = TimerClock()
        let ticks = Atomic<Int64>(0)
        clock.start(rate: .fps60) { _ in ticks.add(1, ordering: .relaxed) }
        Thread.sleep(forTimeInterval: 0.25)
        clock.stop()
        let count = ticks.load(ordering: .relaxed)
        XCTAssertGreaterThan(count, 8, "about fifteen ticks in a quarter second")
        XCTAssertLessThan(count, 24)
    }

    /// Spec 4 §3 — control, render and sink threads over the engine, driven by the timer clock.
    func test_threadedEngineTicksBuildsPlansAndRecords() throws {
        let library = try EngineFixtures.library()
        let machine = try EngineFixtures.spikeMachine()
        let backend = RecordingBackend()
        let sinks = machine.outputs.map { CapturingSink(output: $0.number) }
        let engine = try Engine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot, backend: backend, clock: TimerClock(),
                                sinks: sinks, sourceFactory: FakeSourceFactory(), posters: FakePosterProvider(backend: backend),
                                text: FakeTextProvider(backend: backend), variables: VariableProvider(settings: machine.settings))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blackbox-\(UUID().uuidString)")
        engine.start(blackBox: BlackBox(folder: folder))
        engine.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .osc), commands: [Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "Amen"])))]))
        XCTAssertTrue(waitUntil(5) { engine.render.totalTicks > 20 })
        XCTAssertTrue(waitUntil(5) { engine.control.publishedState.channels[2]?.content.kind == "text" }, "the command landed on a tick boundary")
        XCTAssertTrue(waitUntil(5) { (engine.recorder?.liveSummary.ticks ?? 0) > 10 }, "the black box drained the tick ring")
        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertEqual(engine.watchdog.recoveries, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("blackbox-"))
    }
}
