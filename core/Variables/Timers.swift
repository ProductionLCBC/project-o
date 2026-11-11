// OCore — Spec 6 §6, timers, and their feedback (§8).

/// Spec 6 §6 — one timer slot: "Timers live in the engine, outside ShowState
/// (Spec 3 §2), and run on its monotonic clock (Spec 4 §2), so a change to the
/// wall clock never moves them." A running timer counts the master tick's
/// frames from the frame its run began (Adam's answer to the plan,
/// 2026-11-11); `heldMs` is its value then, or while it is stopped or paused.
public struct TimerSlot: Equatable, Sendable {
    public var state: TimerReading.State
    public var direction: TimerReading.Direction
    public var setMs: Int
    public var heldMs: Int
    public var since: Int64

    public init(state: TimerReading.State, direction: TimerReading.Direction, setMs: Int, heldMs: Int, since: Int64) {
        self.state = state
        self.direction = direction
        self.setMs = setMs
        self.heldMs = heldMs
        self.since = since
    }

    /// Spec 6 §6 — "after a relaunch every timer is unset".
    public static let unset = TimerSlot(state: .unset, direction: .down, setMs: 0, heldMs: 0, since: 0)

    /// The signed value at `frame`: a countdown's time left, negative past
    /// zero, or a count-up's time from zero, its starting value included.
    public func valueMs(at frame: Int64, rate: FrameRate) -> Int {
        guard state == .running else { return heldMs }
        let elapsed = TimerBank.elapsedMs(frames: max(0, frame - since), rate: rate)
        return direction == .down ? heldMs - elapsed : heldMs + elapsed
    }
}

/// Spec 6 §6 — "Timers are slots 1 up to the machine's `timers` count, which
/// is 4 on first run ... Nothing about them is saved (Spec 1 §4)." A value:
/// the engine keeps one and runs the timer commands on it.
public struct TimerBank: Equatable, Sendable {
    public private(set) var slots: [TimerSlot]

    public init(count: Int) {
        slots = Array(repeating: .unset, count: max(0, count))
    }

    public var count: Int { slots.count }

    /// Milliseconds in `frames` of the master tick at `rate`, to the nearest.
    public static func elapsedMs(frames: Int64, rate: FrameRate) -> Int {
        guard rate.num > 0, rate.den > 0 else { return 0 }
        let num = Int64(rate.num)
        let den = Int64(rate.den)
        return Int((frames * 1000 * den + num / 2) / num)
    }

    /// Spec 6 §6 — a timer command at `frame`, the frame its group lands on:
    ///
    /// | Command | Effect |
    /// | --- | --- |
    /// | `timer N set DURATION` | Sets a countdown from DURATION, stopped |
    /// | `timer N set DURATION up` | Sets a count-up from DURATION, usually `0:00`, stopped (R3) |
    /// | `timer N start` | Runs it from its current value |
    /// | `timer N pause` | Holds its current value |
    /// | `timer N reset` | Returns it to its set value, stopped (choice T-11) |
    ///
    /// "A timer command that would change nothing yields `noop` (Spec 2 §8):
    /// `start` on a running timer, `pause` on one that isn't running, `reset`
    /// on a stopped timer already at its set value, and any command but `set`
    /// on an unset timer." True when the timer changed; false for those, for
    /// a number outside the slots (a cue's command, which nothing validates
    /// at run time), and for any other command.
    public mutating func apply(_ command: Command, frame: Int64, rate: FrameRate) -> Bool {
        let timer: Int
        switch command {
        case .timerSet(let n, _, _), .timerStart(let n), .timerPause(let n), .timerReset(let n): timer = n
        default: return false
        }
        guard timer >= 1, timer <= slots.count else { return false }
        var slot = slots[timer - 1]
        switch command {
        case .timerSet(_, let ms, let up):
            slot = TimerSlot(state: .stopped, direction: up ? .up : .down, setMs: max(0, ms), heldMs: max(0, ms), since: frame)
        case .timerStart:
            guard slot.state == .stopped || slot.state == .paused else { return false }
            slot.state = .running
            slot.since = frame
        case .timerPause:
            guard slot.state == .running else { return false }
            slot.heldMs = slot.valueMs(at: frame, rate: rate)
            slot.state = .paused
        case .timerReset:
            guard slot.state != .unset, !(slot.state == .stopped && slot.heldMs == slot.setMs) else { return false }
            slot.state = .stopped
            slot.heldMs = slot.setMs
            slot.since = frame
        default:
            return false
        }
        slots[timer - 1] = slot
        return true
    }

    /// Spec 6 §8 — timer `timer` at `frame`; unset outside the slots.
    public func reading(_ timer: Int, frame: Int64, rate: FrameRate) -> TimerReading {
        guard timer >= 1, timer <= slots.count else { return .unset }
        let slot = slots[timer - 1]
        guard slot.state != .unset else { return .unset }
        return TimerReading(state: slot.state, direction: slot.direction, setMs: slot.setMs, valueMs: slot.valueMs(at: frame, rate: rate))
    }

    /// Every timer at `frame`, by slot.
    public func readings(frame: Int64, rate: FrameRate) -> [Int: TimerReading] {
        var out: [Int: TimerReading] = [:]
        for timer in 1...max(1, slots.count) where timer <= slots.count {
            out[timer] = reading(timer, frame: frame, rate: rate)
        }
        return out
    }
}

extension TimerReading {
    /// Spec 6 §8 — "once a second while the timer runs": the whole second its
    /// value is in, on the timer's own phase, which changes when its display
    /// does (a countdown rounded up, the time past zero rounded down, a
    /// count-up rounded down). Nil while unset.
    public var second: Int? {
        guard state != .unset, let direction, let valueMs else { return nil }
        switch direction {
        case .down: return valueMs > 0 ? (valueMs + 999) / 1000 : -((-valueMs) / 1000)
        case .up: return max(0, valueMs) / 1000
        }
    }

    /// Spec 6 §8 — "`/o/timer/N` carries `s:` the value in the timer's default
    /// format and `i:` its value in milliseconds. On a countdown, `i` goes
    /// negative past zero; on a count-up, it includes the starting value ...
    /// An unset timer sends `s:""` alone."
    public func message(timer: Int) -> OSCMessage {
        guard state != .unset, let valueMs else { return OSCFeedback.timerUnset(timer) }
        return OSCFeedback.timer(timer, formatted: text(format: VariableFormat.durations[0], overrun: false), ms: valueMs)
    }

    /// Spec 6 §8 — "The `timers` topic sends one event per timer on the same
    /// cadence, with the API's `seq` like every event (Spec 2 §9). `state` is
    /// `unset`, `stopped`, `running` or `paused`, and `direction` is `down` or
    /// `up`. An unset timer has `null` for `direction`, `setMs` and
    /// `valueMs`, and `""` for `text`."
    public func event(timer: Int, seq: Int) -> JSONValue {
        func number(_ n: Int?) -> JSONValue { n.map { .number(Double($0)) } ?? .null }
        return .object([
            "type": .string("event"), "topic": .string("timers"), "timer": .number(Double(timer)), "state": .string(state.rawValue),
            "direction": direction.map { .string($0.rawValue) } ?? .null, "setMs": number(setMs), "valueMs": number(valueMs),
            "text": .string(text(format: VariableFormat.durations[0], overrun: false)), "seq": .number(Double(seq)),
        ])
    }
}
