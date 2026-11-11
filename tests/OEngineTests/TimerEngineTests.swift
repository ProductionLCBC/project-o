import CoreText
import XCTest
import OCore
@testable import OEngine

/// Spec 6 §11, Area 11 — "Timers. Set, start, pause and reset, counting down
/// and up. A countdown holds `0:00`, and `overrun` shows `0:00` for the first
/// second past zero, then `-0:01`. A jump in the wall clock moves no timer.
/// After a relaunch every timer is unset. The `noop` cases, and a timer number
/// above the count rejected." Spec 6 §6 — "Every timer command is logged with
/// `undo: none`". "Tabular digits. A counting timer's line keeps its width
/// from value to value". The harness's master tick is 60 Hz.
final class TimerEngineTests: XCTestCase {
    typealias S = StageFixtures
    typealias E = EngineFixtures

    /// Stack 2's slot for channel 2 drawing `boxes`, under a wall clock the test sets.
    func engine(_ boxes: [Box], clock: SettableWallClock = SettableWallClock()) throws -> HeadlessEngine {
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(S.preset(9, "Timers", boxes: boxes))
        machine.stacks[1].slots[0].preset = 9
        return try HeadlessEngine(library: library, machine: machine, mediaRoot: E.mediaRoot, wallClock: { clock.now })
    }

    func shown(_ engine: HeadlessEngine, _ raw: String) -> String? {
        engine.boxes(stack: 2, channel: 2).first { box in
            guard case .static(let text) = box.binding.kind else { return false }
            return text == raw
        }?.text
    }

    func lastLine(_ engine: HeadlessEngine) -> LogEntry? {
        engine.control.commandLog.entries.last
    }

    /// "A timer command that would change nothing yields `noop` (Spec 2 §8)
    /// ... Every timer command is logged with `undo: none`".
    func test_timerCommandsAreLoggedOkOrNoopWithUndoNone() throws {
        let engine = try engine([S.label("[Timer 1]", 0)])
        func run(_ text: String, source: SourceKind = .osc) -> (CommandResult, UndoClass)? {
            engine.send(text, source: source)
            engine.tick()
            return lastLine(engine).map { ($0.result, $0.undo) }
        }
        XCTAssertEqual(run("timer 1 start")?.0, .noop, "start on an unset timer")
        XCTAssertEqual(run("timer 1 set 5:00")?.0, .ok)
        XCTAssertEqual(run("timer 1 set 5:00")?.1, UndoClass.none)
        XCTAssertEqual(run("timer 1 pause", source: .key)?.0, .noop, "pause on a stopped timer")
        XCTAssertEqual(run("timer 1 reset")?.0, .noop, "reset on a stopped timer at its set value")
        XCTAssertEqual(run("timer 1 start", source: .key)?.0, .ok)
        XCTAssertEqual(run("timer 1 start")?.0, .noop, "start on a running timer")
        XCTAssertEqual(run("timer 1 pause")?.0, .ok)
        XCTAssertEqual(run("timer 1 reset")?.0, .ok)
        XCTAssertEqual(lastLine(engine)?.source.kind, .osc)
        XCTAssertEqual(engine.control.commandLog.entries.filter { $0.command.cmd.hasPrefix("timer.") }.map(\.undo).allSatisfy { $0 == .none }, true)
        XCTAssertFalse(engine.log.contains("passthrough timer"), "the engine acts on timer commands")
    }

    /// "A higher number is rejected, as any unknown target is (Spec 2 §8)."
    func test_aTimerNumberAboveTheCountIsRejected() throws {
        let engine = try engine([S.label("[Timer 1]", 0)])
        engine.send("timer 5 set 1:00")
        engine.tick()
        XCTAssertEqual(engine.lastRejected.first?.rejection.reason, .noSuchTarget)
        XCTAssertTrue(engine.control.commandLog.entries.isEmpty, "a rejected command never reaches the runtime log")
    }

    /// "Counting down (P8). The timer runs from its set value toward zero, and
    /// at `0:00` its display holds ... `overrun` shows that time"; "Counting
    /// up (R3) ... a stopwatch".
    func test_aTimerBoxCountsDownHoldsAtZeroAndCountsUp() throws {
        let clock = SettableWallClock()
        let engine = try engine([S.label("[Timer 1]", 0), S.label("[Timer 1 overrun]", 0, y: 0.3), S.label("[Timer 2 mm:ss]", 0, y: 0.5)], clock: clock)
        engine.send(group: ["timer 1 set 0:02", "timer 1 start", "timer 2 set 0:00 up", "timer 2 start"])
        var seen: [String] = []
        var overrun: [String] = []
        for _ in 0..<(60 * 5) {
            clock.advance(seconds: 1.0 / 60)
            engine.tick()
            if let text = shown(engine, "[Timer 1]"), text != seen.last { seen.append(text) }
            if let text = shown(engine, "[Timer 1 overrun]"), text != overrun.last { overrun.append(text) }
        }
        XCTAssertEqual(seen, ["0:02", "0:01", "0:00"], "the display holds at 0:00")
        XCTAssertEqual(overrun, ["0:02", "0:01", "0:00", "-0:01", "-0:02"], "0:00 for the first second past zero, then -0:01")
        XCTAssertEqual(engine.control.timers.reading(1, frame: engine.frame, rate: .fps60).state, .running, "it runs on underneath (T-12)")
        XCTAssertEqual(shown(engine, "[Timer 2 mm:ss]"), "00:04", "the count-up, rounded down")
    }

    /// "Timers ... run on its monotonic clock (Spec 4 §2), so a change to the
    /// wall clock never moves them."
    func test_aJumpInTheWallClockMovesNoTimer() throws {
        let clock = SettableWallClock()
        let engine = try engine([S.label("[Timer 1]", 0)], clock: clock)
        engine.send(group: ["timer 1 set 5:00", "timer 1 start"])
        engine.tick()
        let started = engine.frame
        engine.tick(count: 60)
        clock.advance(seconds: 3600)
        engine.tick()
        clock.advance(seconds: -7200)
        engine.tick(count: 59)
        XCTAssertEqual(engine.control.timers.reading(1, frame: engine.frame, rate: .fps60).valueMs,
                       300_000 - TimerBank.elapsedMs(frames: engine.frame - started, rate: .fps60))
        XCTAssertEqual(shown(engine, "[Timer 1]"), "4:58")
    }

    /// "Nothing about them is saved (Spec 1 §4): after a relaunch every timer
    /// is unset until a cue, a macro, a key or the operator sets it."
    func test_afterARelaunchEveryTimerIsUnset() throws {
        let first = try engine([S.label("[Timer 1]", 0)])
        first.send(group: ["timer 1 set 5:00", "timer 1 start"])
        first.tick(count: 30)
        XCTAssertEqual(shown(first, "[Timer 1]"), "5:00")
        let relaunched = try engine([S.label("[Timer 1]", 0)])
        relaunched.tick()
        XCTAssertEqual(relaunched.control.timers.readings(frame: relaunched.frame, rate: .fps60).values.map(\.state),
                       [.unset, .unset, .unset, .unset])
        XCTAssertNil(shown(relaunched, "[Timer 1]"))
    }

    /// Spec 6 §5 — "The clock, a timer or `[Service In]` alone changes the box
    /// at most once per wall-clock second": a timer's box moves on the
    /// timer's own second (Adam's answer to the plan, 2026-11-11), and a box
    /// that also shows `[Time]` still moves at most once a wall-clock second.
    func test_aTimersBoxMovesOnItsOwnSecondAndBesideTheClockOnceAWallSecond() throws {
        let clock = SettableWallClock(SettableWallClock.at(2026, 10, 30, 10, 0, 0))
        let both = "[Time h:mm:ss a] [Timer 1]"
        let engine = try engine([S.label("[Timer 1]", 0), S.label(both, 0, y: 0.3)], clock: clock)
        engine.send("timer 1 set 0:10")
        var timerChanges: [Int64] = []
        var bothChanges: [Int] = []
        var lastTimer: String?
        var lastBoth: String?
        for tick in 0..<(60 * 5) {
            if tick == 30 { engine.send("timer 1 start") }   // half a wall-clock second in
            engine.tick()
            clock.advance(seconds: 1.0 / 60)
            if let text = shown(engine, "[Timer 1]"), text != lastTimer {
                if lastTimer != nil { timerChanges.append(engine.frame) }
                lastTimer = text
            }
            if let text = shown(engine, both), text != lastBoth {
                bothChanges.append(Int(clock.now.timeIntervalSince1970.rounded(.down)))
                lastBoth = text
            }
        }
        XCTAssertEqual(timerChanges.count, 4)
        XCTAssertEqual(zip(timerChanges, timerChanges.dropFirst()).map { $1 - $0 }, [60, 60, 60], "once a second, on the timer's own second")
        XCTAssertEqual(Set(bothChanges).count, bothChanges.count, "never twice in one wall-clock second")
        XCTAssertGreaterThanOrEqual(bothChanges.count, 4)
    }

    /// Spec 6 §4 and §11 — "A counting timer's line keeps its width from value
    /// to value": the timer box's jobs ask for tabular digits, and in a font
    /// with tabular figures (Skia, in every Mac's supplemental fonts) every
    /// value it shows lays out to one width.
    func test_aCountingTimersLineKeepsItsWidth() throws {
        guard (CTFontCopyPostScriptName(CTFontCreateWithName("Skia-Regular" as CFString, 12, nil)) as String) == "Skia-Regular" else {
            throw XCTSkip("Skia is not installed")
        }
        var box = S.label("[Timer 1]", 0)
        var style = BoxTextStyle()
        style.values.font = "Skia-Regular"
        // Skia is a variable font whose `wght` runs 0.48 to 3.2: naming it keeps Skia's own default (Spec 1 §2).
        style.values.variations = ["wght": 1]
        style.values.size = TextSize(value: 72)
        style.values.shadow = Shadow()
        style.values.outline = Outline()
        box.textStyle = style
        box.fit = .text(TextFit(policy: .maxLines, maxLines: 1, minSize: 12))
        let clock = SettableWallClock()
        let engine = try engine([box], clock: clock)
        let fake = try XCTUnwrap(engine.fakeText)
        fake.missAll = true   // every raster is asked for, so each value's job is seen
        engine.send(group: ["timer 1 set 0:12", "timer 1 start"])
        for _ in 0..<(60 * 12) {
            engine.tick()
            clock.advance(seconds: 1.0 / 60)   // the wall clock runs on with the master tick
        }
        let jobs = Dictionary(fake.requested.filter { $0.text.hasPrefix("0:") }.map { ($0.text, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertGreaterThanOrEqual(jobs.count, 10)
        XCTAssertTrue(jobs.values.allSatisfy(\.tabular), "a timer's box asks for tabular digits")
        let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")
        let widths = try jobs.values.map { try XCTUnwrap(rasterizer.rasterize($0).layout.lines.first).origin.width }
        let narrowest = try XCTUnwrap(widths.min())
        let widest = try XCTUnwrap(widths.max())
        XCTAssertEqual(Double(widest), Double(narrowest), accuracy: 0.5, "\(jobs.keys.sorted()): \(widths)")
    }
}

/// Spec 6 §11, Area 11 — "Popups. `clearafter` clears and is logged from
/// source `engine`, and a later set replaces or cancels the pending clear.
/// ... `system clearall` leaves popups." Spec 6 §7 — "`clearafter` clears the
/// slot that many seconds after the set. A later `popup N set` replaces any
/// pending clear with its own, or cancels it if it has none, and `popup N
/// clear` cancels it too. The clear is logged as a `popup N clear` from
/// source `engine` (Spec 2 §5), so replaying the log reproduces it."
final class PopupClearTests: XCTestCase {
    func engine() throws -> HeadlessEngine {
        try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
    }

    func clears(_ engine: HeadlessEngine) -> [LogEntry] {
        engine.control.commandLog.entries.filter { $0.command == .popupClear(popup: 1) }
    }

    func test_clearAfterClearsTheSlotLoggedFromSourceEngine() throws {
        let engine = try engine()
        engine.send("popup 1 set \"Doors open\" clearafter 1")
        engine.tick()
        let set = engine.frame
        engine.tick(count: 59)
        XCTAssertEqual(engine.state.popups[1], "Doors open", "59 frames after the set")
        engine.tick()
        XCTAssertNil(engine.state.popups[1], "a second after the set")
        XCTAssertEqual(engine.frame - set, 60)
        let line = try XCTUnwrap(clears(engine).last)
        XCTAssertEqual(line.source, CommandSource(kind: .engine))
        XCTAssertEqual(line.result, .ok)
        XCTAssertEqual(line.text, "popup 1 clear")
        engine.tick(count: 120)
        XCTAssertEqual(clears(engine).count, 1, "once")
    }

    func test_aLaterSetReplacesOrCancelsThePendingClearAndAClearCancelsIt() throws {
        let engine = try engine()
        engine.send("popup 1 set \"One\" clearafter 2")
        engine.tick(count: 30)
        engine.send("popup 1 set \"Two\" clearafter 1")
        engine.tick(count: 60)
        XCTAssertEqual(engine.state.popups[1], "Two", "past the first set's time, 59 frames after the second")
        engine.tick()
        XCTAssertNil(engine.state.popups[1], "the later set's own clear")
        engine.send("popup 1 set \"Three\" clearafter 1")
        engine.tick(count: 10)
        engine.send("popup 1 set \"Four\"")
        engine.tick(count: 180)
        XCTAssertEqual(engine.state.popups[1], "Four", "a set with no clearafter cancels the pending clear")
        engine.send("popup 1 set \"Five\" clearafter 1")
        engine.tick(count: 10)
        engine.send("popup 1 clear")
        engine.tick()
        engine.send("popup 1 set \"Six\"")
        engine.tick(count: 180)
        XCTAssertEqual(engine.state.popups[1], "Six", "the clear cancelled the pending clear")
        XCTAssertEqual(clears(engine).filter { $0.source.kind == .engine }.count, 1)
    }

    /// Adam's answer to the plan (2026-11-11): a set of the text a slot
    /// already shows is logged `ok` when it changed the pending clear, and
    /// `noop` otherwise.
    func test_anIdenticalSetIsOkWhenItChangesThePendingClear() throws {
        let engine = try engine()
        func result(_ text: String) -> CommandResult? {
            engine.send(text)
            engine.tick()
            return engine.control.commandLog.entries.last?.result
        }
        XCTAssertEqual(result("popup 1 set \"Same\""), .ok)
        XCTAssertEqual(result("popup 1 set \"Same\""), .noop, "nothing pending, none asked for")
        XCTAssertEqual(result("popup 1 set \"Same\" clearafter 5"), .ok, "a clear to come")
        XCTAssertEqual(result("popup 1 set \"Same\""), .ok, "the pending clear cancelled")
        engine.tick(count: 400)
        XCTAssertEqual(engine.state.popups[1], "Same")
    }

    /// "`system clearall` leaves popups as they are": their pending clears too.
    func test_clearAllLeavesPopupsAndTheirPendingClears() throws {
        let engine = try engine()
        engine.send("popup 1 set \"Stays\" clearafter 1")
        engine.tick()
        engine.send("system clearall")
        engine.tick()
        XCTAssertEqual(engine.state.popups[1], "Stays")
        engine.tick(count: 59)
        XCTAssertNil(engine.state.popups[1], "its own clear still comes")
    }
}

/// Spec 6 §11, Area 11 — "Feedback. `/o/timer/N` and the `timers` topic
/// arrive once a second while a timer runs and after each command that
/// changes it, with the values of §8. `/o/channel/N/remaining` arrives once a
/// second, and only at clients that subscribed to that channel."
final class TimerFeedbackTests: XCTestCase {
    typealias E = EngineFixtures

    func engine() throws -> HeadlessEngine {
        try HeadlessEngine(library: E.library(), machine: E.spikeMachine(), mediaRoot: E.mediaRoot)
    }

    /// Spec 6 §8 — "It is sent once a second while the timer runs, and after
    /// every timer command that changes the timer"; the events carry the
    /// `seq` of the line that caused them, or of the last line logged.
    func test_timerFeedbackAfterEachChangeAndOnceASecondWhileItRuns() throws {
        let engine = try engine()
        let events = EventRecorder()
        engine.engine.publisher.subscribe(["timers"]) { events.record($0) }
        var messages: [(frame: Int64, message: OSCMessage)] = []
        func tick(_ count: Int = 1) {
            for _ in 0..<count {
                engine.tick()
                messages += engine.control.lastTimerFeedback.map { (engine.frame, $0.message) }
            }
        }
        engine.send("timer 1 set 0:03")
        tick()
        let setSeq = try XCTUnwrap(engine.control.commandLog.entries.last?.seq)
        XCTAssertEqual(messages.map(\.message), [OSCMessage("/o/timer/1", [.string("0:03"), .int32(3000)])])
        XCTAssertEqual(events.all.last, ["type": .string("event"), "topic": .string("timers"), "timer": .number(1), "state": .string("stopped"),
                                         "direction": .string("down"), "setMs": .number(3000), "valueMs": .number(3000),
                                         "text": .string("0:03"), "seq": .number(Double(setSeq))])
        engine.send("timer 1 pause")
        tick(30)
        XCTAssertEqual(messages.count, 1, "a command that changes nothing sends nothing, and a stopped timer is quiet")
        engine.send("timer 1 start")
        tick()
        let started = engine.frame
        XCTAssertEqual(messages.last?.message, OSCMessage("/o/timer/1", [.string("0:03"), .int32(3000)]))
        XCTAssertEqual(events.all.last?["state"], .string("running"))
        tick(60 * 5)
        let running = messages.dropFirst(2)
        XCTAssertEqual(running.map { $0.frame - started }, [60, 120, 180, 240, 300], "once a second, on the timer's own second")
        XCTAssertEqual(running.map { $0.message.arguments.first }, Array(repeating: .string("0:02"), count: 1) + [.string("0:01"), .string("0:00"),
                                                                                                                    .string("0:00"), .string("0:00")])
        XCTAssertEqual(running.map { $0.message.arguments.last }, [.int32(2000), .int32(1000), .int32(0), .int32(-1000), .int32(-2000)],
                       "on past zero, i goes negative")
        XCTAssertEqual(events.all.count, 2 + 5)
        XCTAssertEqual(events.all.last?["seq"], .number(Double(engine.control.commandLog.lastSeq)), "the last line logged")
    }

    /// "An unset timer sends `s:""` alone"; Spec 2 §6 — "Any client may ask
    /// for a current value with `/o/query` ... and receives the feedback
    /// message once": the timers, the popups and a channel's remaining time.
    func test_queryAnswersTimersPopupsAndRemainingTime() throws {
        let engine = try engine()
        engine.send(group: ["timer 1 set 1:00", "popup 2 set \"Nursery\"", "channel 1 write media \(E.dawn)"])
        engine.tick(count: 2)
        XCTAssertEqual(engine.control.answerVariables(query: "/o/timer/1"), OSCMessage("/o/timer/1", [.string("1:00"), .int32(60_000)]))
        XCTAssertEqual(engine.control.answerVariables(query: "/o/timer/2"), OSCMessage("/o/timer/2", [.string("")]))
        XCTAssertEqual(engine.control.answerVariables(query: "/o/popup/2"), OSCFeedback.popup(2, text: "Nursery"))
        XCTAssertEqual(engine.control.answerVariables(query: "/o/popup/1"), OSCFeedback.popup(1, text: ""))
        let remaining = try XCTUnwrap(engine.control.answerVariables(query: "/o/channel/1/remaining"))
        XCTAssertEqual(remaining.address, "/o/channel/1/remaining")
        XCTAssertNil(engine.control.answerVariables(query: "/o/channel/2/remaining"), "no timed content on channel 2")
        XCTAssertNil(engine.control.answerVariables(query: "/o/timer/9"), "no such timer")
    }

    /// Spec 2 §6 — "`/o/channel/N/remaining` `i:ms` Once a second while timed
    /// content plays"; a loop counts down the pass it is in (Adam's answer to
    /// the plan, 2026-11-11). The dawn clip is two seconds long.
    func test_remainingTimeOnceASecondWhileTimedContentPlays() throws {
        let engine = try engine()
        var sent: [(frame: Int64, ms: Int)] = []
        func tick(_ count: Int) {
            for _ in 0..<count {
                engine.tick()
                for message in engine.control.lastRemaining where message.address == "/o/channel/1/remaining" {
                    if case .int32(let ms)? = message.arguments.first { sent.append((engine.frame, Int(ms))) }
                }
            }
        }
        // The dawn clip loops by its pool item's default (Spec 8 §2); `end hold` in the same group plays it once.
        engine.send(group: ["channel 1 write media \(E.dawn)", "channel 1 end hold"])
        tick(60 * 3)
        XCTAssertEqual(sent.map { ($0.ms + 999) / 1000 }, [2, 1, 0], "each whole second once, then nothing at its end")
        XCTAssertEqual(sent.first?.ms, 2000)
        sent = []
        engine.send("channel 1 write media \(E.dawn)")
        tick(60 * 6)
        XCTAssertEqual(Array(sent.map { ($0.ms + 999) / 1000 }.prefix(6)), [2, 1, 2, 1, 2, 1], "a loop counts down each pass")
        XCTAssertEqual(sent.first?.ms, 2000, "the restart is sent at once")
        sent = []
        engine.send("channel 1 pause")
        tick(120)
        XCTAssertTrue(sent.isEmpty, "paused: nothing")
    }

    /// Spec 2 §6 — "High-rate feedback is opt-in per address: a client sends
    /// /o/subscribe ... subscriptions expire with the client's registration."
    /// A client registers the port it listens on and may send from another;
    /// its subscriptions go to the peers of its host and end once the host
    /// has no live registration.
    func test_remainingTimeGoesOnlyToASubscribedClientAndEndsWithItsRegistration() throws {
        let clock = FakeMonotonic()
        let log = EngineLog(category: "test-osc")
        let server = OSCServer(port: 0, targets: [], mediaIDs: [], log: log, now: { clock.now }, enqueue: { _ in })
        try server.start()
        defer { server.stop() }
        let listener = try UDPTestClient()
        let sender = try UDPTestClient()
        defer { listener.close(); sender.close() }
        try sender.send(OSCMessage("/o/register", [.string("127.0.0.1"), .int32(Int32(listener.port))]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { server.liveRegistrations.count == 1 })
        server.feedback([OSCFeedback.channelRemaining(1, ms: 5000)])
        XCTAssertNil(listener.receive(timeout: 0.3), "not subscribed: nothing")
        try sender.send(OSCMessage("/o/subscribe", [.string("/o/channel/1/remaining")]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { server.subscriptionCount == 1 })
        server.feedback([OSCFeedback.channelRemaining(2, ms: 4000)])
        XCTAssertNil(listener.receive(timeout: 0.3), "another channel's remaining time: nothing")
        server.feedback([OSCFeedback.channelRemaining(1, ms: 4000)])
        XCTAssertNotNil(listener.receive(timeout: 2), "subscribed from another port of the same client: delivered where it listens")
        clock.advance(seconds: 61)
        server.feedback([OSCFeedback.channelRemaining(1, ms: 3000)])
        XCTAssertNil(listener.receive(timeout: 0.3), "the registration expired")
        try sender.send(OSCMessage("/o/register", [.string("127.0.0.1"), .int32(Int32(listener.port))]).encoded(), to: server.boundPort)
        XCTAssertTrue(waitUntil(5) { server.liveRegistrations.count == 1 })
        server.feedback([OSCFeedback.channelRemaining(1, ms: 2000)])
        XCTAssertNil(listener.receive(timeout: 0.3), "the subscription ended with the registration")
        XCTAssertEqual(server.subscriptionCount, 0)
    }
}
