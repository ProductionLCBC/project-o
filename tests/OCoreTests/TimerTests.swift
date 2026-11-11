import XCTest
@testable import OCore

/// Spec 6 §6 — "Timers are slots 1 up to the machine's `timers` count ...
/// Timers live in the engine, outside ShowState (Spec 3 §2), and run on its
/// monotonic clock (Spec 4 §2), so a change to the wall clock never moves
/// them": they count the master tick's frames at its rate (Adam's answer to
/// the plan, 2026-11-11). Spec 6 §11, Area 11 — "Timers. Set, start, pause and
/// reset, counting down and up. A countdown holds `0:00`, and `overrun` shows
/// `0:00` for the first second past zero, then `-0:01`. ... The `noop` cases".
/// Spec 6 §8 — "Feedback ... this section gives their values."
final class TimerTests: XCTestCase {
    let rate = FrameRate.fps60

    func reading(_ bank: TimerBank, _ timer: Int = 1, at frame: Int64) -> TimerReading {
        bank.reading(timer, frame: frame, rate: rate)
    }

    /// "`timer N set DURATION` Sets a countdown from DURATION, stopped";
    /// "`timer N start` Runs it from its current value"; "`timer N pause`
    /// Holds its current value"; "`timer N reset` Returns it to its set value,
    /// stopped (choice T-11)".
    func test_setStartPauseAndResetACountdown() {
        var bank = TimerBank(count: 4)
        XCTAssertEqual(reading(bank, at: 0), .unset, "after a launch every timer is unset")
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 300_000), frame: 0, rate: rate))
        XCTAssertEqual(reading(bank, at: 600), TimerReading(state: .stopped, direction: .down, setMs: 300_000, valueMs: 300_000))
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 600, rate: rate))
        XCTAssertEqual(reading(bank, at: 720), TimerReading(state: .running, direction: .down, setMs: 300_000, valueMs: 298_000))
        XCTAssertEqual(reading(bank, at: 720).text(format: "m:ss", overrun: false), "4:58")
        XCTAssertEqual(reading(bank, at: 730).text(format: "m:ss", overrun: false), "4:58", "rounded up")
        XCTAssertTrue(bank.apply(.timerPause(timer: 1), frame: 720, rate: rate))
        XCTAssertEqual(reading(bank, at: 10_000), TimerReading(state: .paused, direction: .down, setMs: 300_000, valueMs: 298_000))
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 10_000, rate: rate))
        XCTAssertEqual(reading(bank, at: 10_060).valueMs, 297_000, "it runs on from where it was held")
        XCTAssertTrue(bank.apply(.timerReset(timer: 1), frame: 10_060, rate: rate))
        XCTAssertEqual(reading(bank, at: 20_000), TimerReading(state: .stopped, direction: .down, setMs: 300_000, valueMs: 300_000))
        // A set while running sets it again, stopped.
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 20_000, rate: rate))
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 60_000), frame: 20_060, rate: rate))
        XCTAssertEqual(reading(bank, at: 30_000), TimerReading(state: .stopped, direction: .down, setMs: 60_000, valueMs: 60_000))
        XCTAssertEqual(reading(bank, 2, at: 30_000), .unset, "each slot is its own")
    }

    /// "`timer N set DURATION up` Sets a count-up from DURATION, usually
    /// `0:00`, stopped (R3)"; "Counting up (R3). The timer runs from its set
    /// value, with no limit ... a stopwatch"; Spec 6 §8 — "on a count-up, it
    /// includes the starting value".
    func test_aCountUp() {
        var bank = TimerBank(count: 4)
        XCTAssertTrue(bank.apply(.timerSet(timer: 2, ms: 0, up: true), frame: 0, rate: rate))
        XCTAssertEqual(reading(bank, 2, at: 0), TimerReading(state: .stopped, direction: .up, setMs: 0, valueMs: 0))
        XCTAssertTrue(bank.apply(.timerStart(timer: 2), frame: 0, rate: rate))
        XCTAssertEqual(reading(bank, 2, at: 59).text(format: "m:ss", overrun: false), "0:00", "rounded down")
        XCTAssertEqual(reading(bank, 2, at: 60).text(format: "m:ss", overrun: false), "0:01")
        XCTAssertEqual(reading(bank, 2, at: 216_000).text(format: "m:ss", overrun: false), "1:00:00", "no limit")
        XCTAssertTrue(bank.apply(.timerSet(timer: 3, ms: 60_000, up: true), frame: 0, rate: rate))
        XCTAssertTrue(bank.apply(.timerStart(timer: 3), frame: 0, rate: rate))
        XCTAssertEqual(reading(bank, 3, at: 600).valueMs, 70_000, "the starting value included")
        XCTAssertTrue(bank.apply(.timerReset(timer: 3), frame: 600, rate: rate))
        XCTAssertEqual(reading(bank, 3, at: 900), TimerReading(state: .stopped, direction: .up, setMs: 60_000, valueMs: 60_000))
    }

    /// "Counting down (P8). The timer runs from its set value toward zero, and
    /// at `0:00` its display holds ... Underneath, the timer keeps running
    /// past zero until it is paused, reset or set again. `overrun` shows that
    /// time (§5), the feedback reports it as negative milliseconds, and the
    /// timer's state stays `running` (§8)" (choice T-12).
    func test_aCountdownHoldsZeroAndRunsOnUnderneath() {
        var bank = TimerBank(count: 4)
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 2000), frame: 0, rate: rate))
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 0, rate: rate))
        XCTAssertEqual(reading(bank, at: 119).text(format: "m:ss", overrun: false), "0:01")
        let zero = reading(bank, at: 120)
        XCTAssertEqual(zero.valueMs, 0)
        XCTAssertEqual(zero.text(format: "m:ss", overrun: false), "0:00", "it reads 0:00 exactly when it reaches zero")
        let past = reading(bank, at: 150)
        XCTAssertEqual(past.state, .running)
        XCTAssertEqual(past.valueMs, -500)
        XCTAssertEqual(past.text(format: "m:ss", overrun: false), "0:00", "the display holds")
        XCTAssertEqual(past.text(format: "m:ss", overrun: true), "0:00", "the first second past zero")
        XCTAssertEqual(reading(bank, at: 180).text(format: "m:ss", overrun: true), "-0:01")
        XCTAssertEqual(reading(bank, at: 270).text(format: "m:ss", overrun: true), "-0:02")
        XCTAssertEqual(reading(bank, at: 270).valueMs, -2500)
    }

    /// "A timer command that would change nothing yields `noop` (Spec 2 §8):
    /// `start` on a running timer, `pause` on one that isn't running, `reset`
    /// on a stopped timer already at its set value, and any command but `set`
    /// on an unset timer." A number above the count, from a cue nothing
    /// validated at run time, changes nothing either.
    func test_theNoopCases() {
        var bank = TimerBank(count: 4)
        for command: Command in [.timerStart(timer: 1), .timerPause(timer: 1), .timerReset(timer: 1)] {
            XCTAssertFalse(bank.apply(command, frame: 0, rate: rate), "\(command) on an unset timer")
        }
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 60_000), frame: 0, rate: rate))
        XCTAssertFalse(bank.apply(.timerPause(timer: 1), frame: 0, rate: rate), "pause on a stopped timer")
        XCTAssertFalse(bank.apply(.timerReset(timer: 1), frame: 0, rate: rate), "reset on a stopped timer at its set value")
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 0, rate: rate))
        XCTAssertFalse(bank.apply(.timerStart(timer: 1), frame: 60, rate: rate), "start on a running timer")
        XCTAssertTrue(bank.apply(.timerPause(timer: 1), frame: 60, rate: rate))
        XCTAssertFalse(bank.apply(.timerPause(timer: 1), frame: 120, rate: rate), "pause on a paused timer")
        XCTAssertTrue(bank.apply(.timerReset(timer: 1), frame: 120, rate: rate), "reset on a paused timer stops it")
        XCTAssertFalse(bank.apply(.timerReset(timer: 1), frame: 180, rate: rate))
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 60_000), frame: 180, rate: rate), "set is never on the list")
        XCTAssertFalse(bank.apply(.timerSet(timer: 5, ms: 1000), frame: 0, rate: rate), "above the count")
        XCTAssertFalse(bank.apply(.timerStart(timer: 0), frame: 0, rate: rate))
        XCTAssertEqual(bank.reading(5, frame: 0, rate: rate), .unset)
        XCTAssertFalse(bank.apply(.channelClear(channel: .number(1)), frame: 0, rate: rate), "not a timer command")
    }

    /// Spec 4 §2 — "One rate family per machine": at 59.94 the master tick's
    /// frames count real time, 5994 frames being 100 seconds less a tenth of
    /// a millisecond.
    func test_aFractionalRateCountsRealTime() {
        let ntsc = FrameRate(num: 60000, den: 1001)
        var bank = TimerBank(count: 1)
        XCTAssertTrue(bank.apply(.timerSet(timer: 1, ms: 300_000), frame: 1000, rate: ntsc))
        XCTAssertTrue(bank.apply(.timerStart(timer: 1), frame: 1000, rate: ntsc))
        XCTAssertEqual(bank.reading(1, frame: 1000 + 5994, rate: ntsc).valueMs, 200_000)
        XCTAssertEqual(bank.reading(1, frame: 1000 + 5994, rate: ntsc).text(format: "m:ss", overrun: false), "3:20")
        XCTAssertEqual(TimerBank.elapsedMs(frames: 60, rate: .fps60), 1000)
        XCTAssertEqual(TimerBank.elapsedMs(frames: 1, rate: .fps60), 17)
    }

    /// Spec 6 §8 — "`/o/timer/N` carries `s:` the value in the timer's default
    /// format and `i:` its value in milliseconds. On a countdown, `i` goes
    /// negative past zero ... An unset timer sends `s:""` alone." "The
    /// `timers` topic sends one event per timer ... with the API's `seq` like
    /// every event (Spec 2 §9). `state` is `unset`, `stopped`, `running` or
    /// `paused`, and `direction` is `down` or `up`. An unset timer has `null`
    /// for `direction`, `setMs` and `valueMs`, and `""` for `text`."
    func test_theFeedbackShapes() throws {
        let running = TimerReading(state: .running, direction: .down, setMs: 300_000, valueMs: 298_000)
        XCTAssertEqual(running.message(timer: 1), OSCMessage("/o/timer/1", [.string("4:58"), .int32(298_000)]))
        let past = TimerReading(state: .running, direction: .down, setMs: 60_000, valueMs: -2500)
        XCTAssertEqual(past.message(timer: 2), OSCMessage("/o/timer/2", [.string("0:00"), .int32(-2500)]))
        XCTAssertEqual(TimerReading.unset.message(timer: 3), OSCMessage("/o/timer/3", [.string("")]))
        XCTAssertEqual(OSCFeedback.timerUnset(3), OSCMessage("/o/timer/3", [.string("")]))
        XCTAssertEqual(running.event(timer: 1, seq: 4830), .object([
            "type": .string("event"), "topic": .string("timers"), "timer": .number(1), "state": .string("running"),
            "direction": .string("down"), "setMs": .number(300_000), "valueMs": .number(298_000), "text": .string("4:58"),
            "seq": .number(4830),
        ]))
        XCTAssertEqual(TimerReading.unset.event(timer: 4, seq: 7), .object([
            "type": .string("event"), "topic": .string("timers"), "timer": .number(4), "state": .string("unset"),
            "direction": .null, "setMs": .null, "valueMs": .null, "text": .string(""), "seq": .number(7),
        ]))
        let up = TimerReading(state: .paused, direction: .up, setMs: 0, valueMs: 61_500)
        XCTAssertEqual(up.message(timer: 1), OSCMessage("/o/timer/1", [.string("1:01"), .int32(61_500)]))
        // "once a second while the timer runs": the whole second its value is in, on its own phase.
        XCTAssertEqual(TimerReading(state: .running, direction: .down, setMs: 0, valueMs: 1500).second, 2)
        XCTAssertEqual(TimerReading(state: .running, direction: .down, setMs: 0, valueMs: 1000).second, 1)
        XCTAssertEqual(TimerReading(state: .running, direction: .down, setMs: 0, valueMs: 0).second, 0)
        XCTAssertEqual(TimerReading(state: .running, direction: .down, setMs: 0, valueMs: -999).second, 0)
        XCTAssertEqual(TimerReading(state: .running, direction: .down, setMs: 0, valueMs: -1000).second, -1)
        XCTAssertEqual(up.second, 61)
        XCTAssertNil(TimerReading.unset.second)
    }
}
