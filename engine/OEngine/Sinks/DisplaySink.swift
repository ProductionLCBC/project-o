// OEngine — Spec 4 §10, the display sink.

import Foundation
import AppKit
import Metal
import QuartzCore
import OCore
import Synchronization

/// Spec 4 §12 — "Display disconnected: Pause that sink, keep its ring; resume
/// at the configured mode when it returns." The sink's state, kept apart so
/// it can be tested without a screen.
public struct DisplaySinkState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case stopped, running, paused }

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

    /// A screen-configuration change: the sink's screen is there or not.
    public mutating func screenChanged(available: Bool) {
        switch (phase, available) {
        case (.running, false): phase = .paused
        case (.paused, true): phase = .running
        default: break
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
/// the screen's native mode, above every other window, hosting a
/// CAMetalLayer: pixel format bgr10a2Unorm (10-bit; bgra8Unorm_srgb as a
/// fallback the sink reports), colour space sRGB/Rec.709, extended dynamic
/// range off, displaySyncEnabled on, presentsWithTransaction off,
/// maximumDrawableCount 3. ... The sink's CADisplayLink callback, not the
/// render thread, takes the newest completed frame from the output's ring,
/// requests a drawable, encodes the trivial encode pass into it and
/// presents; if no drawable is available within the callback it skips and
/// counts a drop."
///
/// AppKit is main-actor bound, so the window and the display link are made on
/// the main actor; the refresh callback then runs on the sink's own thread.
public final class DisplaySink: NSObject, OutputSink, @unchecked Sendable {
    public let output: Int
    public let encode: EncodeKind = .display10Bit
    public let ring = FrameRing()
    public let presents = PresentRing()
    private let backend: MetalBackend
    private let log: EngineLog
    private let screenName: String
    private let screenFrame: CGRect
    private let screenScale: CGFloat
    private let screenRefreshRate: Double
    private var masterRate = FrameRate(num: 60)
    private var lastRefreshTimestamp: CFTimeInterval = 0
    private let makeLink: @MainActor (DisplaySink) -> CADisplayLink
    private let lastPresentNs = Atomic<Int64>(0)
    private let lock = NSLock()
    private var state = DisplaySinkState()
    private var window: NSWindow?
    private var layer: CAMetalLayer?
    private var link: CADisplayLink?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let queue: MTLCommandQueue?
    public private(set) var usesEightBitFallback = false
    private var screenObserver: NSObjectProtocol?

    @MainActor
    public init(output: Int, screen: NSScreen, backend: MetalBackend, log: EngineLog) {
        self.output = output
        self.backend = backend
        self.log = log
        screenName = screen.localizedName
        screenFrame = screen.frame
        screenScale = screen.backingScaleFactor
        screenRefreshRate = screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 60
        makeLink = { sink in screen.displayLink(target: sink, selector: #selector(DisplaySink.refresh(_:))) }
        queue = backend.device.makeCommandQueue()
        super.init()
    }

    /// Spec 4 §2 — the master rate and this output's ticks per frame, from the
    /// engine's pacing, so a refresh knows which tick it is one frame behind.
    public func configure(masterRate: FrameRate, ticksPerFrame: Int) {
        lock.lock()
        self.masterRate = masterRate
        state.ticksPerFrame = max(1, ticksPerFrame)
        let outputRate = masterRate.perSecond / Double(max(1, ticksPerFrame))
        state.screenMatchesOutput = screenRefreshRate <= outputRate * 1.01
        lock.unlock()
    }

    public var lastPresent: MonotonicTime { MonotonicTime(nanoseconds: lastPresentNs.load(ordering: .acquiring)) }

    public var currentState: DisplaySinkState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        lock.lock()
        state.phase = .running
        lock.unlock()
        let boxed: DisplayLinkBox
        if Thread.isMainThread {
            boxed = MainActor.assumeIsolated { DisplayLinkBox(openWindow()) }
        } else {
            boxed = DispatchQueue.main.sync { MainActor.assumeIsolated { DisplayLinkBox(openWindow()) } }
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
        thread.name = "o.engine.sink.display.\(output)"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        log.info("display sink \(output) on \(screenName) at \(Int(screenFrame.width))x\(Int(screenFrame.height)) scale \(screenScale)")
    }

    @MainActor
    private func openWindow() -> CADisplayLink {
        let window = NSWindow(contentRect: screenFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = NSView(frame: CGRect(origin: .zero, size: screenFrame.size))
        view.wantsLayer = true
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
        layer.contentsScale = screenScale
        layer.drawableSize = CGSize(width: screenFrame.width * screenScale, height: screenFrame.height * screenScale)
        view.layer = layer
        window.contentView = view
        window.setFrame(screenFrame, display: true)
        window.orderFrontRegardless()
        self.window = window
        self.layer = layer
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.screensChanged() }
        }
        return makeLink(self)
    }

    public func stop() {
        running.store(false, ordering: .releasing)
        let close = { [self] in
            MainActor.assumeIsolated {
                if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
                screenObserver = nil
                window?.orderOut(nil)
                window = nil
            }
        }
        if Thread.isMainThread { close() } else { DispatchQueue.main.sync(execute: close) }
        lock.lock()
        state.phase = .stopped
        lock.unlock()
    }

    /// Spec 4 §12 — pause when the screen leaves, resume when it returns.
    @MainActor
    func screensChanged() {
        let available = NSScreen.screens.contains { $0.localizedName == screenName }
        lock.lock()
        let before = state.phase
        state.screenChanged(available: available)
        let after = state.phase
        lock.unlock()
        if before != after { log.warning("display sink \(output): \(after == .paused ? "screen lost, paused" : "screen back, resumed")") }
    }

    // MARK: - Refresh (the sink's own cadence)

    @objc func refresh(_ link: CADisplayLink) {
        // The drawable and the command buffer are autoreleased: a pool per refresh.
        autoreleasepool { refreshInPool(link) }
    }

    private func refreshInPool(_ link: CADisplayLink) {
        guard let layer, let queue else { return }
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
            backend.encodeDisplay(frame, into: drawable.texture, command: buffer)
            buffer.present(drawable)
            buffer.commit()
            presents.write(PresentRecord(output: output, frame: frame.tick, rePresented: false,
                                         latencyNs: max(0, Int64(link.targetTimestamp * 1_000_000_000) - now.nanoseconds), completion: .completed,
                                         dropsSinceStart: currentState.drops))
            lastPresentNs.store(now.nanoseconds, ordering: .releasing)
        }
    }
}
