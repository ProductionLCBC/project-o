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

    public init() {}

    /// A screen-configuration change: the sink's screen is there or not.
    public mutating func screenChanged(available: Bool) {
        switch (phase, available) {
        case (.running, false): phase = .paused
        case (.paused, true): phase = .running
        default: break
        }
    }

    /// What a refresh should do with the newest completed frame of tick `tick`.
    public enum Action: Equatable, Sendable { case present, rePresent, skip }

    public mutating func refresh(newestCompletedTick: Int64?) -> Action {
        guard phase == .running else { return .skip }
        guard let tick = newestCompletedTick, tick != lastPresentedTick else {
            if lastPresentedTick >= 0 { rePresented += 1 }
            return .rePresent
        }
        lastPresentedTick = tick
        presented += 1
        return .present
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
        makeLink = { sink in screen.displayLink(target: sink, selector: #selector(DisplaySink.refresh(_:))) }
        queue = backend.device.makeCommandQueue()
        super.init()
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
        guard let layer, let queue else { return }
        let newest = ring.newest
        let completed = newest.flatMap { frame -> CompletedFrame? in
            guard let completion = backend.completion(of: frame.receipt), !completion.failed else { return nil }
            return frame
        }
        lock.lock()
        let action = state.refresh(newestCompletedTick: completed?.tick)
        lock.unlock()
        let now = MonotonicClock.now()
        switch action {
        case .skip:
            return
        case .rePresent:
            // The previous drawable stays on screen; count it (Spec 4 §13).
            presents.write(PresentRecord(output: output, frame: completed?.tick ?? -1, rePresented: true, latencyNs: 0, completion: nil,
                                         dropsSinceStart: currentState.drops))
            lastPresentNs.store(now.nanoseconds, ordering: .releasing)
        case .present:
            guard let frame = completed, let drawable = layer.nextDrawable() else {
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
