// OEngine — Spec 4 §10, the display sink.

import Foundation
import AppKit
import Metal
import QuartzCore
import OCore
import Synchronization

/// Spec 4 §12 — "Display disconnected: Pause that sink, keep its ring; resume
/// when it returns, at its current mode." Spec 10 §2 — "A display output
/// whose screen isn't there stays `absent` and opens when a screen with its
/// id appears; it never falls back to another screen." Spec 10 §9 — an
/// output taken off its screen is `released` for the rest of the run. The
/// sink's state, kept apart so it can be tested without a screen.
public struct DisplaySinkState: Equatable, Sendable {
    /// `absent`: started, and its screen has not been there yet. `paused`:
    /// it presented, and its screen went. `released`: taken off its screen
    /// until the engine ends.
    public enum Phase: Equatable, Sendable { case stopped, running, paused, absent, released }

    public var phase: Phase = .stopped
    public var presented: Int64 = 0
    public var rePresented: Int64 = 0
    public var drops: Int64 = 0
    public var lastPresentedTick: Int64 = -1
    /// Spec 4 §10 — the master tick a refresh is one frame behind: latched one
    /// frame behind the newest published frame at the first refresh, then
    /// stepped by the master time between refreshes. The sink's vsync callback
    /// and the render thread race on the same vsync; without this the race,
    /// not the clock, would decide whether a frame shows once, twice or not at all.
    public var expectedTick: Int64 = -1
    public var tickPhase: Double = 0
    /// Ticks per presented frame of this output (Spec 4 §2 pacing).
    public var ticksPerFrame: Int = 1
    /// True when the screen refreshes no faster than the output: then a
    /// refresh with nothing new to show is a re-present (Spec 4 §13), not the
    /// hold by design of a slower output on a faster screen.
    public var screenMatchesOutput = true

    public init() {}

    /// Spec 10 §2 — the sink starts: with its screen there it presents, and
    /// without it it waits, `absent`. A released sink stays released.
    public mutating func started(screenPresent: Bool) {
        guard phase == .stopped else { return }
        phase = screenPresent ? .running : .absent
    }

    /// A screen-configuration change: the sink's screen is there or not. A
    /// screen that goes pauses a running sink; one that comes resumes a
    /// paused sink and opens an absent one, each from the newest frame.
    public mutating func screenChanged(available: Bool) {
        switch (phase, available) {
        case (.running, false):
            phase = .paused
        case (.paused, true), (.absent, true):
            phase = .running
            // What was due before the screen went is long gone: latch again, one frame behind the newest.
            expectedTick = -1
            lastPresentedTick = -1
            tickPhase = 0
        default:
            break
        }
    }

    /// Spec 10 §9 — "the engine closes those outputs' windows, reports them
    /// `released`": from any phase, and no change of screens brings it back;
    /// only `retakeScreen` does (`retaken()`).
    public mutating func released() {
        phase = .released
    }

    /// Spec 10 §9 — "Put Back on This Screen sends `retakeScreen` with it: the
    /// engine opens those outputs' windows again, reports them `presenting`"
    /// (corrected 2026-11-24). A released sink waits for its screen again,
    /// `absent`, and its screen opens it as one that appears does, from the
    /// newest frame; a sink that isn't released is left as it is.
    public mutating func retaken() {
        guard phase == .released else { return }
        phase = .absent
    }

    /// Spec 10 §3 — the output's state as the `outputs` topic reports it.
    public var standing: OutputStanding {
        switch phase {
        case .running: return .presenting
        case .paused: return .paused
        case .released: return .released
        case .stopped, .absent: return .absent
        }
    }

    /// What a refresh should do: present the frame of a tick, show the previous
    /// one again (counted), hold it without counting, or nothing (not running).
    public enum Action: Equatable, Sendable { case present(Int64), rePresent, hold, skip }

    /// One refresh. `newestPublished` is the ring's newest frame, maybe still
    /// on the GPU; `elapsedTicks` the master ticks since the previous refresh;
    /// `isComplete` whether the frame of a tick is in the ring and finished.
    public mutating func refresh(newestPublished: Int64?, elapsedTicks: Double, isComplete: (Int64) -> Bool) -> Action {
        guard phase == .running else { return .skip }
        guard let newest = newestPublished, newest >= 0 else { return .hold }
        let perFrame = Int64(max(1, ticksPerFrame))
        if expectedTick < 0 && lastPresentedTick < 0 {
            // The first refresh with a frame: latch one frame behind it, even if that is before the first tick.
            expectedTick = newest - perFrame
            tickPhase = 0
        } else {
            // Rounded to the nearest tick, so vsync timestamp jitter never loses or doubles a step.
            tickPhase += max(0, elapsedTicks)
            let steps = Int64(tickPhase.rounded(.toNearestOrAwayFromZero))
            tickPhase -= Double(steps)
            expectedTick += steps
        }
        // The ring holds three frames: ahead of the master (unlocked drift, a missed
        // tick) take what there is; far behind it (the sink's thread was starved) catch up.
        if expectedTick > newest { expectedTick = newest }
        if expectedTick < newest - 2 * perFrame { expectedTick = newest - perFrame }
        let due = expectedTick >= 0 ? expectedTick - expectedTick % perFrame : -1
        guard due > lastPresentedTick else {
            if screenMatchesOutput {
                if lastPresentedTick >= 0 { rePresented += 1 }
                return .rePresent
            }
            return .hold
        }
        var tick = due
        while tick > lastPresentedTick, tick > due - 3 * perFrame {
            if isComplete(tick) {
                lastPresentedTick = tick
                presented += 1
                return .present(tick)
            }
            tick -= perFrame
        }
        if lastPresentedTick >= 0 { rePresented += 1 }
        return .rePresent
    }

    public mutating func dropped() {
        drops += 1
    }
}

/// Spec 4 §10 — "Display sink. One borderless, opaque window per screen at
/// the screen's current mode, on every Space, above every other window but
/// the few of the operator app's that must sit over an output (Spec 10 §2,
/// §11), hosting a CAMetalLayer: pixel format bgr10a2Unorm (10-bit;
/// bgra8Unorm_srgb as a fallback the sink reports), colour space
/// sRGB/Rec.709, extended dynamic range off, displaySyncEnabled on,
/// presentsWithTransaction off, maximumDrawableCount 3. ... The sink's
/// CADisplayLink callback, not the render thread, takes the newest completed
/// frame from the output's ring, requests a drawable, encodes the trivial
/// encode pass into it and presents; if no drawable is available within the
/// callback it skips and counts a drop."
///
/// Spec 10 §2 — the sink exists whether or not its screen does. `place(on:)`
/// gives it the screen whose id its output names, at launch and at every
/// change of screens, or takes it away: "A display output whose screen isn't
/// there stays `absent` and opens when a screen with its id appears; it never
/// falls back to another screen." The window is an `OutputPanel`.
///
/// AppKit is main-actor bound, so the window and the display link are made on
/// the main actor; the refresh callback then runs on the sink's own thread.
public final class DisplaySink: NSObject, OutputSink, @unchecked Sendable {
    public let output: Int
    /// Spec 1 §3 — the display's uuid the output's `device` names
    /// (`display:<uuid>`), in capitals; nil when it names no display.
    public let screenUUID: String?
    public let encode: EncodeKind = .display10Bit
    public let ring = FrameRing()
    public let presents = PresentRing()
    private let backend: MetalBackend
    private let log: EngineLog
    private let lastPresentNs = Atomic<Int64>(0)
    private let running = Atomic<Bool>(false)
    private let queue: MTLCommandQueue?
    public private(set) var usesEightBitFallback = false

    // Read by the refresh thread and written on the main actor, under the lock.
    private let lock = NSLock()
    private var state = DisplaySinkState()
    private var masterRate = FrameRate(num: 60)
    private var screenRefreshRate: Double = 60
    private var lastRefreshTimestamp: CFTimeInterval = 0
    private var layer: CAMetalLayer?
    private var link: CADisplayLink?

    // The main actor's own: the screen the sink was given, and what is open on it.
    private var placed: NSScreen?
    private var window: OutputPanel?
    private var linkAlive: LinkToken?
    private var attachedDisplay: CGDirectDisplayID?
    private var attachedFrame = CGRect.zero
    private var attachedScale: CGFloat = 0
    private var screenName = ""

    /// One display link's thread runs while its token says so.
    private final class LinkToken: Sendable {
        let alive = Atomic<Bool>(true)
    }

    @MainActor
    public init(output: Int, device: String, backend: MetalBackend, log: EngineLog) {
        self.output = output
        screenUUID = DetectedScreen.uuid(ofDevice: device)
        self.backend = backend
        self.log = log
        queue = backend.device.makeCommandQueue()
        super.init()
    }

    /// Spec 4 §2 — the master rate and this output's ticks per frame, from the
    /// engine's pacing, so a refresh knows which tick it is one frame behind.
    public func configure(masterRate: FrameRate, ticksPerFrame: Int) {
        lock.lock()
        self.masterRate = masterRate
        state.ticksPerFrame = max(1, ticksPerFrame)
        matchScreenToOutput()
        lock.unlock()
    }

    /// With the lock held: whether the screen refreshes no faster than the output.
    private func matchScreenToOutput() {
        let outputRate = masterRate.perSecond / Double(max(1, state.ticksPerFrame))
        state.screenMatchesOutput = screenRefreshRate <= outputRate * 1.01
    }

    public var lastPresent: MonotonicTime { MonotonicTime(nanoseconds: lastPresentNs.load(ordering: .acquiring)) }

    public var currentState: DisplaySinkState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Spec 10 §3 — the output's state as the `outputs` topic reports it.
    public var standing: OutputStanding { currentState.standing }

    // MARK: - Lifecycle

    /// Spec 10 §2 — the sink starts: on its screen when `place(on:)` gave it
    /// one, else `absent` until a screen with its id appears. A sink released
    /// before it started (`--released`) stays released.
    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        onMain { self.open() }
    }

    @MainActor
    private func open() {
        lock.lock()
        state.started(screenPresent: placed != nil)
        let phase = state.phase
        lock.unlock()
        if phase == .running, let placed {
            attach(placed)
        } else if phase == .absent {
            log.warning("display sink \(output): its screen (\(screenUUID ?? "none named")) isn't there; absent until it appears")
        }
    }

    /// Spec 10 §2 — the sink's screen as the Mac has it now: the screen whose
    /// id the output names, or nil when no screen has it. Called before the
    /// sink starts and at every change of screens. A screen that appears
    /// opens the window on it; one that goes pauses the sink, which keeps its
    /// ring (Spec 4 §12) and hides its window, so macOS can't move an output
    /// onto another screen; one whose frame or mode changed is followed.
    @MainActor
    public func place(on screen: NSScreen?) {
        placed = screen
        guard running.load(ordering: .relaxed) else { return }
        lock.lock()
        let before = state.phase
        lock.unlock()
        guard before == .running || before == .paused || before == .absent else { return }
        if let screen {
            attach(screen)
            lock.lock()
            state.screenChanged(available: true)
            lock.unlock()
            if before != .running { log.info("display sink \(output): \(before == .paused ? "screen back, resumed" : "screen appeared, opened")") }
        } else if before == .running {
            detach()
            lock.lock()
            state.screenChanged(available: false)
            lock.unlock()
            log.warning("display sink \(output): screen lost, paused")
        }
    }

    /// Spec 10 §9 — "the engine closes those outputs' windows, reports them
    /// `released`": until `retakeScreen` puts them back, or for the rest of
    /// the run, whatever the screens do.
    @MainActor
    public func retake() {
        lock.lock()
        state.retaken()
        let phase = state.phase
        lock.unlock()
        if phase == .absent { log.info("display sink \(output): put back; waiting for its screen") }
    }

    /// Spec 10 §9 — "the engine closes those outputs' windows, reports them
    /// `released`": until `retakeScreen` puts them back (`retake()`).
    @MainActor
    public func release() {
        detach()
        window?.close()
        window = nil
        lock.lock()
        layer = nil
        state.released()
        lock.unlock()
        log.info("display sink \(output): released from its screen")
    }

    /// Opens the window on `screen`, or moves it to the screen's frame and
    /// mode as they are now, with a display link of that screen. Nothing to
    /// do when the sink is already on this screen as it is.
    @MainActor
    private func attach(_ screen: NSScreen) {
        let display = SystemDevices.displayID(of: screen)
        let frame = screen.frame, scale = screen.backingScaleFactor
        if linkAlive != nil, attachedDisplay == display, attachedFrame == frame, attachedScale == scale { return }
        endLink()
        attachedDisplay = display
        attachedFrame = frame
        attachedScale = scale
        screenName = screen.localizedName

        let panel = window ?? OutputPanel(frame: frame)
        let metal = currentLayer() ?? makeLayer()
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        if panel.contentView?.layer !== metal {
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer = metal
        }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        window = panel

        let link = screen.displayLink(target: self, selector: #selector(DisplaySink.refresh(_:)))
        let token = LinkToken()
        lock.lock()
        layer = metal
        self.link = link
        screenRefreshRate = screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 60
        lastRefreshTimestamp = 0
        matchScreenToOutput()
        lock.unlock()
        linkAlive = token
        let boxed = DisplayLinkBox(link)
        let thread = Thread {
            boxed.link.add(to: RunLoop.current, forMode: .common)
            while token.alive.load(ordering: .relaxed) {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            boxed.link.invalidate()
        }
        thread.name = "o.engine.sink.display.\(output)"
        thread.qualityOfService = .userInteractive
        thread.start()
        log.info("display sink \(output) on \(screenName) at \(Int(frame.width))x\(Int(frame.height)) scale \(scale)")
    }

    @MainActor
    private func makeLayer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.device = backend.device
        layer.pixelFormat = .bgr10a2Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.wantsExtendedDynamicRangeContent = false
        layer.displaySyncEnabled = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        layer.framebufferOnly = true
        layer.isOpaque = true
        return layer
    }

    private func currentLayer() -> CAMetalLayer? {
        lock.lock()
        defer { lock.unlock() }
        return layer
    }

    /// Ends the display link's thread; the window stays as it is.
    @MainActor
    private func endLink() {
        linkAlive?.alive.store(false, ordering: .releasing)
        linkAlive = nil
        lock.lock()
        link = nil
        lock.unlock()
    }

    /// Takes the sink off its screen: no link, and the window out of sight.
    @MainActor
    private func detach() {
        endLink()
        window?.orderOut(nil)
        attachedDisplay = nil
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        onMain {
            self.detach()
            self.window?.close()
            self.window = nil
        }
        lock.lock()
        state.phase = .stopped
        lock.unlock()
    }

    /// AppKit's work, from whichever thread asks.
    private func onMain(_ body: @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
        }
    }

    /// Spec 4 §13 — "present latency (tick to vsync ...)": the vsync this
    /// refresh targets minus the reference of the tick that rendered the frame,
    /// both on the display link's clock.
    public static func presentLatency(targetNs: Int64, referenceNs: Int64) -> Int64 {
        max(0, targetNs - referenceNs)
    }

    // MARK: - Refresh (the sink's own cadence)

    @objc func refresh(_ link: CADisplayLink) {
        // The drawable and the command buffer are autoreleased: a pool per refresh.
        autoreleasepool { refreshInPool(link) }
    }

    private func refreshInPool(_ link: CADisplayLink) {
        lock.lock()
        let layer = self.layer
        let current = self.link
        lock.unlock()
        // A link the sink has moved on from (its screen went, or changed) presents nothing more.
        guard let layer, let queue, current === link else { return }
        let ring = self.ring
        let backend = self.backend
        let isComplete: (Int64) -> Bool = { tick in
            guard let frame = ring.frame(forTick: tick), let completion = backend.completion(of: frame.receipt) else { return false }
            return !completion.failed
        }
        lock.lock()
        let elapsedTicks = lastRefreshTimestamp > 0 ? (link.timestamp - lastRefreshTimestamp) * masterRate.perSecond : 1
        lastRefreshTimestamp = link.timestamp
        let action = state.refresh(newestPublished: ring.newest?.tick, elapsedTicks: elapsedTicks, isComplete: isComplete)
        let lastTick = state.lastPresentedTick
        lock.unlock()
        let now = MonotonicClock.now()
        switch action {
        case .skip:
            return
        case .hold:
            // Nothing new was due (a slower output on a faster screen): alive, not counted.
            lastPresentNs.store(now.nanoseconds, ordering: .releasing)
        case .rePresent:
            // The previous drawable stays on screen; count it (Spec 4 §13) once there is one.
            if lastTick >= 0 {
                presents.write(PresentRecord(output: output, frame: lastTick, rePresented: true, latencyNs: 0, completion: nil,
                                             dropsSinceStart: currentState.drops))
            }
            lastPresentNs.store(now.nanoseconds, ordering: .releasing)
        case .present(let tick):
            guard let frame = ring.frame(forTick: tick), let drawable = layer.nextDrawable() else {
                lock.lock()
                state.dropped()
                lock.unlock()
                log.warning("display sink \(output): no drawable this refresh; dropped")
                return
            }
            guard let buffer = queue.makeCommandBuffer() else { return }
            guard backend.encodeDisplay(frame, into: drawable.texture, command: buffer) else {
                // Spec 4 §1 — "A missing frame is a repeat, never black": nothing was drawn into this drawable
                // (the frame's stack texture is gone, Spec 4 §5), so it is not presented and the last one stays.
                if lastTick >= 0 {
                    presents.write(PresentRecord(output: output, frame: lastTick, rePresented: true, latencyNs: 0, completion: nil,
                                                 dropsSinceStart: currentState.drops))
                }
                lastPresentNs.store(now.nanoseconds, ordering: .releasing)
                return
            }
            buffer.present(drawable)
            buffer.commit()
            presents.write(PresentRecord(output: output, frame: frame.tick, rePresented: false,
                                         latencyNs: DisplaySink.presentLatency(targetNs: Int64(link.targetTimestamp * 1_000_000_000), referenceNs: frame.referenceNs),
                                         completion: .completed, dropsSinceStart: currentState.drops))
            lastPresentNs.store(now.nanoseconds, ordering: .releasing)
        }
    }
}
