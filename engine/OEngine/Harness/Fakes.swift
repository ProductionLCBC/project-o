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

    /// Spec 8 §6 — the items a prefetched reader holds open.
    public var prefetchedIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(prefetched.keys.map(SourceRequest.id(ofPrefetchKey:)))
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

/// Spec 4 §5 — posters by handle, allocated on demand in the backend's
/// table. A poster whose id is in `notYet` isn't loaded until `arrive` is
/// called: the lookup asks for it and comes back `.none`, as the engine's
/// loader does while it reads (Spec 8 §9).
public final class FakePosterProvider: PosterProvider, @unchecked Sendable {
    private let backend: any RenderBackend
    private let lock = NSLock()
    private var handles: [PosterKey: TextureHandle] = [:]
    private var waiting: Set<String> = []
    private var asked: [PosterKey] = []
    private var changes = 0

    public init(backend: any RenderBackend) {
        self.backend = backend
    }

    public func poster(_ key: PosterKey) -> TextureHandle {
        lock.lock()
        defer { lock.unlock() }
        asked.append(key)
        if let handle = handles[key] { return handle }
        if waiting.contains(key.id) { return .none }
        let handle = backend.makeTexture(TextureDescriptor(role: .poster, size: PixelSize(width: 960, height: 540), label: "poster " + key.id.prefix(15)))
        handles[key] = handle
        return handle
    }

    public func postersChanged() {
        lock.lock()
        changes += 1
        lock.unlock()
    }

    /// The posters of these ids stay unloaded until `arrive`.
    public func holdBack(_ ids: Set<String>) {
        lock.lock()
        waiting.formUnion(ids)
        lock.unlock()
    }

    /// The posters of these ids load at the next lookup.
    public func arrive(_ ids: Set<String>) {
        lock.lock()
        waiting.subtract(ids)
        lock.unlock()
    }

    /// The handle a poster of this id was given, if it was.
    public func handle(for id: String) -> TextureHandle {
        lock.lock()
        defer { lock.unlock() }
        return handles.first { $0.key.id == id }?.value ?? .none
    }

    /// Every lookup so far, in order.
    public var lookups: [PosterKey] {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    /// How many times `.posters/` or the media was said to change.
    public var changeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return changes
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
