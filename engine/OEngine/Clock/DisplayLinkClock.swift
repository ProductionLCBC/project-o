// OEngine — Spec 4 §2, "Display outputs only: The primary output's CADisplayLink".

import Foundation
import AppKit
import QuartzCore
import OCore
import Synchronization

/// Spec 4 §14 — `MasterClock` over a CADisplayLink: "The best clock
/// available without hardware". The link is made on the main actor (AppKit)
/// and runs on its own thread's run loop; each refresh's target timestamp is
/// the reference.
public final class DisplayLinkClock: NSObject, MasterClock, @unchecked Sendable {
    public let name: String
    private let makeLink: @MainActor (DisplayLinkClock) -> CADisplayLink
    private let refreshRate: Double
    private var link: CADisplayLink?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let ticks = Atomic<Int64>(0)
    private var handler: (@Sendable (TickTime) -> Void)?
    private var divider = 1
    private var callbacks = 0

    @MainActor
    public init(screen: NSScreen) {
        name = "displaylink"
        refreshRate = screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 60
        makeLink = { clock in screen.displayLink(target: clock, selector: #selector(DisplayLinkClock.fire(_:))) }
        super.init()
    }

    public func now() -> MonotonicTime { MonotonicClock.now() }

    public func start(rate: FrameRate, handler: @escaping @Sendable (TickTime) -> Void) {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        self.handler = handler
        // A 120 Hz screen on a 60 Hz master delivers every second refresh.
        divider = max(1, Int((refreshRate / max(1, rate.perSecond)).rounded()))
        let make = makeLink
        let boxed: DisplayLinkBox
        if Thread.isMainThread {
            boxed = MainActor.assumeIsolated { DisplayLinkBox(make(self)) }
        } else {
            boxed = DispatchQueue.main.sync { MainActor.assumeIsolated { DisplayLinkBox(make(self)) } }
        }
        let link = boxed.link
        self.link = link
        let thread = Thread { [self] in
            link.add(to: RunLoop.current, forMode: .common)
            while self.running.load(ordering: .relaxed) {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            link.invalidate()
        }
        thread.name = "o.engine.clock.displaylink"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    @objc func fire(_ link: CADisplayLink) {
        callbacks += 1
        guard callbacks % divider == 0 else { return }
        let tick = ticks.add(1, ordering: .relaxed).oldValue
        let reference = MonotonicTime(nanoseconds: Int64(link.targetTimestamp * 1_000_000_000))
        handler?(TickTime(tick: tick, reference: reference, wake: MonotonicClock.now()))
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        thread = nil
    }
}

/// A display link made on the main actor and handed to its thread; the link
/// itself is driven from one run loop only.
final class DisplayLinkBox: @unchecked Sendable {
    let link: CADisplayLink

    init(_ link: CADisplayLink) {
        self.link = link
    }
}
