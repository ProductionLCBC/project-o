// OEngine — Spec 10 §18, Area 19: the soak's client on the Mach channel.

import Foundation
import OCore
import OMach

/// Spec 10 §18, Area 19, the soak — "The soak scenario gains a client holding
/// the Mach channel, so the previews and the channel pictures count in its
/// GPU p99 (Spec 4 §13)." Spec 4 §2 — "While the operator app holds its Mach
/// channel, the strip's channel pictures are a consumer at the preview rate
/// too": with nobody holding the channel the pictures aren't made, and a soak
/// without the client would measure less work than a service does.
///
/// The client holds the channel for the whole run, as the app does, and at
/// the end says what it was sent. A soak whose client got nothing did not
/// measure the previews and the pictures, so that is a failure of the run.
public final class SoakMachClient: @unchecked Sendable {
    private let client: MachClient
    private let lock = NSLock()
    private var held = false
    private var trouble: String?
    private var began: MonotonicTime = .zero

    public init(service: any MachService = BootstrapMachService()) {
        client = MachClient(service: service)
    }

    /// Takes the channel of the engine with this run. A channel that can't be
    /// reached is kept for the verdict; the soak goes on.
    public func hold(run: UUID) {
        let name = MachServiceName.engine(run: run)
        lock.lock()
        defer { lock.unlock() }
        began = MonotonicClock.now()
        do {
            try client.connect(name: name)
            held = true
        } catch {
            trouble = "\(error)"
        }
    }

    /// Lets the channel go.
    public func release() {
        client.disconnect()
    }

    /// What the client was sent, in lines, and what the run holds against it.
    public func verdict() -> (lines: [String], failures: [String]) {
        lock.lock()
        let held = self.held, trouble = self.trouble, began = self.began
        lock.unlock()
        guard held else {
            return (["the Mach channel: not held"],
                    ["the soak's Mach client did not connect (\(trouble ?? "no reason given")): the previews and the channel pictures were not in this run's GPU time"])
        }
        let seconds = max(0.001, Double(MonotonicClock.now().nanoseconds - began.nanoseconds) / 1e9)
        let state = client.state
        var failures: [String] = []
        if state.previewSets == 0 {
            failures.append("the Mach channel sent the soak's client no surfaces")
        }
        for stack in state.previews.keys.sorted() where (state.previewCounts[stack] ?? 0) == 0 {
            failures.append("no preview frame was named for stack \(stack) over the Mach channel")
        }
        return (["the Mach channel, as the soak's client held it:"] + client.report(seconds: seconds).map { "  " + $0 }, failures)
    }
}
