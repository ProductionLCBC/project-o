// OEngine — the harness's power assertions.

import Foundation

/// Spec 10 §2 — "It holds a latency-critical activity ... and while any
/// output presents it keeps the displays and the system from sleeping": a
/// `PowerAssertions` that takes nothing from macOS and records what it was asked.
public final class FakePower: PowerAssertions, @unchecked Sendable {
    private let lock = NSLock()
    private var activityCount = 0
    private var awakeCalls: [Bool] = []

    public init() {}

    public func beginActivity() {
        lock.lock()
        activityCount += 1
        lock.unlock()
    }

    public func keepAwake(_ awake: Bool) {
        lock.lock()
        awakeCalls.append(awake)
        lock.unlock()
    }

    /// How many times the activity was begun.
    public var activities: Int {
        lock.lock()
        defer { lock.unlock() }
        return activityCount
    }

    /// Every `keepAwake` call, in order.
    public var calls: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return awakeCalls
    }
}
