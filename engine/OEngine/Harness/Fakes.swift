// OEngine — Spec 4 §14, the headless harness: sources, posters and text that
// need no decoder, no disk and no GPU.

import Foundation
import OCore

/// A source that becomes ready after a number of ticks and then always has a
/// frame, so the control loop's readiness rules can be tested without a
/// decoder (Spec 4 §6).
public final class FakeSource: ContentSource, @unchecked Sendable {
    public let layout: SourceLayout
    public let size: PixelSize
    public let request: SourceRequest
    private var ticksUntilReady: Int
    private let lock = NSLock()
    public private(set) var released = false
    public private(set) var picks = 0
    /// Scripted frame times, for frame-selection tests; empty means "always a frame".
    public var framesMs: [Double] = []
    private var lastPicked: Double = -1

    public init(request: SourceRequest, layout: SourceLayout, size: PixelSize, readyAfterTicks: Int) {
        self.request = request
        self.layout = layout
        self.size = size
        ticksUntilReady = readyAfterTicks
    }

    public var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticksUntilReady <= 0
    }

    public var queueDepth: Int { isReady ? 3 : 0 }

    func advance() {
        lock.lock()
        if ticksUntilReady > 0 { ticksUntilReady -= 1 }
        lock.unlock()
    }

    public func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult {
        guard isReady else { return .nothing }
        picks += 1
        frame.layout = layout
        guard !framesMs.isEmpty else {
            frame.presentationMs = mediaTimeMs
            return .frame
        }
        guard let newest = framesMs.last(where: { $0 <= mediaTimeMs }) else { return .nothing }
        frame.presentationMs = newest
        if newest == lastPicked { return .repeated }
        lastPicked = newest
        return .frame
    }

    public func release() {
        lock.lock()
        released = true
        lock.unlock()
    }
}

/// Spec 4 §6 — a factory that opens fake sources and keeps prefetched ones.
public final class FakeSourceFactory: SourceFactory, @unchecked Sendable {
    /// Ticks a newly opened source waits before its first frame.
    public var readyAfterTicks = 0
    private let lock = NSLock()
    public private(set) var opened: [FakeSource] = []
    public private(set) var prefetched: [String: FakeSource] = [:]

    public init() {}

    static func layout(for entry: MediaEntry) -> SourceLayout {
        if entry.kind == .image { return .linearRGBA16 }
        switch entry.codec ?? "" {
        case "hvc1", "hev1": return .p010
        case "apcn", "apch", "apcs", "apco": return .yuv422p10
        case "ap4h", "ap4x": return .rgba16
        default: return .nv12
        }
    }

    public func open(_ request: SourceRequest) -> any ContentSource {
        let source = FakeSource(request: request, layout: FakeSourceFactory.layout(for: request.entry),
                                size: PixelSize(width: request.entry.width ?? 1920, height: request.entry.height ?? 1080),
                                readyAfterTicks: readyAfterTicks)
        lock.lock()
        opened.append(source)
        lock.unlock()
        return source
    }

    public func prefetch(_ request: SourceRequest) {
        lock.lock()
        defer { lock.unlock() }
        guard prefetched[request.prefetchKey] == nil else { return }
        let source = FakeSource(request: request, layout: FakeSourceFactory.layout(for: request.entry),
                                size: PixelSize(width: request.entry.width ?? 1920, height: request.entry.height ?? 1080),
                                readyAfterTicks: readyAfterTicks)
        prefetched[request.prefetchKey] = source
        opened.append(source)
    }

    public func adoptPrefetched(_ request: SourceRequest) -> (any ContentSource)? {
        lock.lock()
        defer { lock.unlock() }
        return prefetched.removeValue(forKey: request.prefetchKey)
    }

    /// One tick passed: sources get closer to ready.
    public func advance() {
        lock.lock()
        let sources = opened
        lock.unlock()
        for source in sources { source.advance() }
    }

    public var liveSources: [FakeSource] {
        lock.lock()
        defer { lock.unlock() }
        return opened.filter { !$0.released }
    }
}

/// Spec 4 §5 — posters by handle, allocated on demand in the backend's table.
public final class FakePosterProvider: PosterProvider, @unchecked Sendable {
    private let backend: any RenderBackend
    private let lock = NSLock()
    private var handles: [String: TextureHandle] = [:]

    public init(backend: any RenderBackend) {
        self.backend = backend
    }

    public func poster(for entry: MediaEntry) -> TextureHandle {
        guard entry.poster != nil else { return .none }
        lock.lock()
        defer { lock.unlock() }
        if let handle = handles[entry.id] { return handle }
        let size = PixelSize(width: max(2, (entry.width ?? 1920) / 2), height: max(2, (entry.height ?? 1080) / 2))
        let handle = backend.makeTexture(TextureDescriptor(role: .poster, size: size, label: "poster " + entry.id.prefix(15)))
        handles[entry.id] = handle
        return handle
    }

    public func handle(for id: String) -> TextureHandle {
        lock.lock()
        defer { lock.unlock() }
        return handles[id] ?? .none
    }
}

/// Spec 4 §8 — a text cache that answers at once with one placeholder line
/// per line of text, unless told to miss, so `textLate` and the box
/// transitions can be tested before the rasterizer exists.
public final class FakeTextProvider: TextProvider, @unchecked Sendable {
    private let backend: any RenderBackend
    private let lock = NSLock()
    private var entries: [TextKey: TextEntry] = [:]
    public private(set) var requested: [TextJob] = []
    /// Keys that miss once, then hit.
    public var missOnce: Set<TextKey> = []
    public var missAll = false

    public init(backend: any RenderBackend) {
        self.backend = backend
    }

    public func entry(for job: TextJob) -> TextEntry? {
        lock.lock()
        defer { lock.unlock() }
        if missAll { return nil }
        if missOnce.remove(job.key) != nil { return nil }
        if let entry = entries[job.key] { return entry }
        let lineHeight = Float(job.style.values.size.pixels(outputHeight: job.outputHeight) * job.style.values.lineSpacing)
        let lines = job.text.components(separatedBy: "\n").enumerated().map { index, _ in
            let handle = backend.makeTexture(TextureDescriptor(role: .textLine, size: PixelSize(width: job.box.width, height: Int(lineHeight.rounded(.up))),
                                                               label: "line \(index) " + job.text.prefix(12)))
            return TextLine(texture: handle, frame: PixelRect(x: 0, y: Float(index) * lineHeight, width: Float(job.box.width), height: lineHeight))
        }
        let entry = TextEntry(lines: lines, bytes: lines.count * job.box.width * Int(lineHeight.rounded(.up)) * 4)
        entries[job.key] = entry
        return entry
    }

    public func request(_ job: TextJob) {
        lock.lock()
        requested.append(job)
        lock.unlock()
    }
}
