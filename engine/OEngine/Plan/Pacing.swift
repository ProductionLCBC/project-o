// OEngine — Spec 4 §2, clocks and frame pacing: the master rate and what is due.

import Foundation
import OCore

/// Spec 4 §2 — why a machine cannot be paced.
public enum PacingError: Error, Equatable, Sendable {
    /// "One rate family per machine. All outputs must share a family: integer
    /// (60, 30) or fractional (59.94, 29.97)." The outputs that disagree.
    case mixedRateFamily([Int])
    /// An output whose field rate does not divide the master rate (a 24p
    /// output on a 60 Hz tick): it "cannot be paced from one clock without
    /// periodic repeats".
    case rateNotADivisor(output: Int)
    case noOutputs
}

/// Spec 4 §2 — "One master tick. The engine runs on a single tick whose rate
/// is the highest output rate on the machine, counting fields for interlaced
/// outputs. With a 4K30 LED wall and 1080i60 sides the tick is 60 Hz; the wall
/// consumes every second tick, the sides consume two ticks per frame (one per
/// field)." "Render only what is due."
public struct Pacing: Equatable, Sendable {
    public let masterRate: FrameRate
    public let tickNanoseconds: Int64
    private let stackTicks: [Int: Int]
    private let sinkTicks: [Int: Int]

    public init(machine: Machine) throws {
        try self.init(outputs: machine.outputs)
    }

    public init(outputs: [Output]) throws {
        guard let first = outputs.first else { throw PacingError.noOutputs }
        let family = first.format.rate.reduced.den
        let disagreeing = outputs.filter { $0.format.rate.reduced.den != family }.map(\.number)
        if !disagreeing.isEmpty {
            throw PacingError.mixedRateFamily(([first.number] + disagreeing).sorted())
        }
        // Field rates: an interlaced output's rate is in frames; it consumes a tick per field.
        var master = first.format.rate.reduced
        for output in outputs {
            let field = Pacing.fieldRate(of: output)
            if field.perSecond > master.perSecond { master = field }
        }
        var stackTicks: [Int: Int] = [:]
        var sinkTicks: [Int: Int] = [:]
        for output in outputs {
            let field = Pacing.fieldRate(of: output)
            let frame = output.format.rate.reduced
            // master / field must be a whole number of ticks.
            let perField = master.num * field.den
            let fieldTicks = perField / max(1, field.num * master.den)
            guard fieldTicks >= 1, fieldTicks * field.num * master.den == perField else {
                throw PacingError.rateNotADivisor(output: output.number)
            }
            let perFrame = master.num * frame.den
            let frameTicks = perFrame / max(1, frame.num * master.den)
            stackTicks[output.number] = fieldTicks
            sinkTicks[output.number] = frameTicks
        }
        masterRate = master
        tickNanoseconds = master.nanosecondsPerFrame
        self.stackTicks = stackTicks
        self.sinkTicks = sinkTicks
    }

    /// Spec 4 §2 — fields per second for an interlaced output, frames otherwise.
    static func fieldRate(of output: Output) -> FrameRate {
        let rate = output.format.rate.reduced
        return output.format.interlaced ? FrameRate(num: rate.num * 2, den: rate.den).reduced : rate
    }

    /// Spec 4 §2 — "A stack pass runs on a tick only if an output that
    /// consumes it is due that tick": for an interlaced output, every field.
    public func isStackDue(output: Int, tick: Int64) -> Bool {
        guard let ticks = stackTicks[output] else { return false }
        return tick % Int64(ticks) == 0
    }

    /// Whether the output's sink encodes and presents or schedules on this tick.
    public func isSinkDue(output: Int, tick: Int64) -> Bool {
        guard let ticks = sinkTicks[output] else { return false }
        return tick % Int64(ticks) == 0
    }

    /// Ticks per presented frame of the output.
    public func ticksPerFrame(output: Int) -> Int { sinkTicks[output] ?? 0 }

    /// Ticks per stack frame the output consumes (fields for interlaced).
    public func ticksPerStackFrame(output: Int) -> Int { stackTicks[output] ?? 0 }

    /// Spec 3 §6 — milliseconds as whole ticks, rounded to the nearest.
    public func frames(forMs ms: Int) -> Int64 {
        Int64(masterRate.frames(forMs: ms))
    }

    /// Milliseconds of media per tick.
    public var millisecondsPerTick: Double {
        1000 / masterRate.perSecond
    }

    /// Spec 4 §2 — "Budget. At 60 Hz the tick is 16.7 ms. Targets: ... GPU
    /// time under 8 ms (half the tick)".
    public var gpuBudgetNanoseconds: Int64 { tickNanoseconds / 2 }
}
