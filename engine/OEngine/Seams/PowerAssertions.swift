// OEngine — Spec 4 §14, a seam: what the engine asks of macOS's power management.

import Foundation
import Synchronization

/// Spec 10 §2, "The engine as a process" — "It holds a latency-critical
/// activity so macOS never naps or throttles it, and while any output
/// presents it keeps the displays and the system from sleeping." One v1
/// implementation, `SystemPower`; the harness's `FakePower` records the calls.
public protocol PowerAssertions: Sendable {
    /// "It holds a latency-critical activity": taken once, for the process's life.
    func beginActivity()
    /// "it keeps the displays and the system from sleeping": held while
    /// `awake` is true and let go when it is false.
    func keepAwake(_ awake: Bool)
}

/// Spec 10 §2 — "while any output presents it keeps the displays and the
/// system from sleeping": the rule between the outputs' states and the
/// assertion. It asks only when the answer changes.
public final class OutputPower: Sendable {
    private let power: any PowerAssertions
    private let awake = Atomic<Bool>(false)

    public init(power: any PowerAssertions) {
        self.power = power
    }

    /// Spec 10 §2 — "It runs as an accessory process ... It holds a
    /// latency-critical activity": at launch.
    public func begin() {
        power.beginActivity()
    }

    /// The outputs' states now, by output number: awake while one presents.
    public func update(_ standings: [Int: OutputStanding]) {
        let wanted = standings.values.contains(.presenting)
        guard awake.exchange(wanted, ordering: .acquiringAndReleasing) != wanted else { return }
        power.keepAwake(wanted)
    }

    /// The engine stops: nothing presents, so nothing is kept awake.
    public func end() {
        update([:])
    }
}
