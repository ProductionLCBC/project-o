// OEngine — Spec 6 §6–§8, the timers and the popups' pending clears the
// control thread keeps, and the timer feedback.

import OCore

/// Spec 6 §8 — one timer's feedback from a build: "`/o/timer/N` carries `s:`
/// the value in the timer's default format and `i:` its value in
/// milliseconds", and "The `timers` topic sends one event per timer on the
/// same cadence, with the API's `seq` like every event (Spec 2 §9)": the
/// `seq` of the timer command's line, or the last line logged before a
/// once-a-second send.
public struct TimerFeedback: Equatable, Sendable {
    public var timer: Int
    public var reading: TimerReading
    public var seq: Int

    public init(timer: Int, reading: TimerReading, seq: Int) {
        self.timer = timer
        self.reading = reading
        self.seq = seq
    }

    /// `/o/timer/N`, to every target (Spec 2 §6).
    public var message: OSCMessage { reading.message(timer: timer) }

    /// The `timers` event.
    public var event: JSONValue { reading.event(timer: timer, seq: seq) }
}

/// Spec 6 §6 and §7 — what one group's commands settle against: working
/// copies of the timers and of the popups' pending clears, kept by the
/// control loop only when the group runs (Spec 2 §1, "There are no partial
/// runs"). Spec 2 §8 — "A timer command that would change nothing yields
/// `noop`"; Spec 6 §7 — "A later `popup N set` replaces any pending clear
/// with its own, or cancels it if it has none, and `popup N clear` cancels it
/// too", a set of the text a slot already shows being `ok` when it changed
/// the pending clear (Adam's answer to the plan, 2026-11-11). Control thread
/// only, for the length of one run.
final class GroupSettler {
    var timers: TimerBank
    var clears: [Int: Int64]
    let frame: Int64
    let rate: FrameRate
    let popupSlots: Int

    init(timers: TimerBank, clears: [Int: Int64], frame: Int64, rate: FrameRate, popupSlots: Int) {
        self.timers = timers
        self.clears = clears
        self.frame = frame
        self.rate = rate
        self.popupSlots = popupSlots
    }

    /// The result of `command`, which the projection gave as `result`.
    func settle(_ command: Command, result: CommandResult) -> CommandResult {
        switch command {
        case .timerSet, .timerStart, .timerPause, .timerReset:
            return timers.apply(command, frame: frame, rate: rate) ? .ok : .noop
        case .popupSet(let popup, _, let clearAfterMs):
            let before = clears[popup]
            if let clearAfterMs, popup >= 1, popup <= popupSlots {
                clears[popup] = frame + Int64(rate.frames(forMs: max(0, clearAfterMs)))
            } else {
                clears[popup] = nil
            }
            return result == .noop && clears[popup] != before ? .ok : result
        case .popupClear(let popup):
            clears[popup] = nil
            return result
        default:
            return result
        }
    }
}
