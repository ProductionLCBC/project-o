// OEngine — Spec 10 §2, the engine's activity and sleep assertions.

import Foundation
import IOKit.pwr_mgt

/// Spec 10 §2 — "It holds a latency-critical activity so macOS never naps or
/// throttles it, and while any output presents it keeps the displays and the
/// system from sleeping." The activity is the process's for its whole life
/// and leaves sleep alone; the sleep assertion is its own, taken and let go
/// with the outputs.
public final class SystemPower: PowerAssertions, @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?
    private var assertion = IOPMAssertionID(0)

    public init() {}

    public func beginActivity() {
        lock.lock()
        defer { lock.unlock() }
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                         reason: "Project O's engine renders every frame of a live service")
    }

    public func keepAwake(_ awake: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if awake, assertion == 0 {
            // Holding the displays awake holds the system awake with them.
            var taken = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Project O's outputs are presenting" as CFString, &taken)
            if result == kIOReturnSuccess { assertion = taken }
        } else if !awake, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    /// Whether the sleep assertion is held now.
    public var isKeepingAwake: Bool {
        lock.lock()
        defer { lock.unlock() }
        return assertion != 0
    }

    /// Whether the activity has been taken.
    public var hasActivity: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activity != nil
    }
}
