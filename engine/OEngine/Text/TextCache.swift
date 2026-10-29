// OEngine — Spec 4 §8, the text cache.

import Foundation
import OCore

/// Spec 4 §8 — "Cache. Keyed by a hash of (field text, text style value, box
/// pixel width, box pixel height, fit policy, output scale). Entries hold the
/// line textures and the layout. The cache is an LRU bounded by bytes (section
/// 5). Lookahead pre-rasterizes the next cue's text for every due stack so a
/// fire never waits on text; a cache miss on a fire draws nothing for that box
/// on the first tick and the texture from the second". Spec 4 §3 — "Text
/// raster: utility ... Core Text layout and Core Graphics raster ... Finished
/// text textures into the cache."
public final class TextCache: TextProvider, @unchecked Sendable {
    public struct Entry: Sendable {
        public var lines: [TextLine]
        public var bytes: Int
        public var layout: TextLayout
        public var substitutedFont: String?
        var lastUsed: UInt64
    }

    public struct Statistics: Equatable, Sendable {
        public var hits: Int = 0
        public var misses: Int = 0
        public var rasterized: Int = 0
        public var evicted: Int = 0
        public var failed: Int = 0
        public var bytes: Int = 0
        public var pending: Int = 0

        public var hitRate: Double { hits + misses > 0 ? Double(hits) / Double(hits + misses) : 1 }
    }

    private let renderer: any TextRenderer
    private let backend: any RenderBackend
    public let maximumBytes: Int
    private let synchronous: Bool
    private let queue = DispatchQueue(label: "o.engine.text", qos: .utility)
    private let lock = NSLock()
    private var entries: [TextKey: Entry] = [:]
    private var pending: Set<TextKey> = []
    private var clock: UInt64 = 0
    private var stats = Statistics()
    private var substitutions: Set<String> = []
    private let log: EngineLog?
    /// Handles to release once the render thread has moved past them (Spec 4 §3).
    private var releaseAfterTick: Int64 = 0

    /// `synchronous` rasterizes inside `request`, for the harness, so the
    /// second tick after a miss hits as the spec describes.
    public init(renderer: any TextRenderer, backend: any RenderBackend, maximumBytes: Int = 256 * 1024 * 1024, synchronous: Bool = false,
                log: EngineLog? = nil) {
        self.renderer = renderer
        self.backend = backend
        self.maximumBytes = max(1, maximumBytes)
        self.synchronous = synchronous
        self.log = log
    }

    // MARK: - TextProvider

    public func entry(for job: TextJob) -> TextEntry? {
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        guard var entry = entries[job.key] else {
            stats.misses += 1
            return nil
        }
        entry.lastUsed = clock
        entries[job.key] = entry
        stats.hits += 1
        return TextEntry(lines: entry.lines, bytes: entry.bytes)
    }

    public func request(_ job: TextJob) {
        lock.lock()
        if entries[job.key] != nil || pending.contains(job.key) {
            lock.unlock()
            return
        }
        pending.insert(job.key)
        stats.pending = pending.count
        lock.unlock()
        if synchronous {
            rasterize(job)
        } else {
            queue.async { [self] in self.rasterize(job) }
        }
    }

    /// Spec 4 §3 — the render thread consumed this tick: evicted handles
    /// older than the plan ring may be freed.
    public func sweep(consumedTick: Int64) {
        releaseAfterTick = consumedTick + Int64(PlanRing.depth)
        backend.resources.sweep(consumedTick: consumedTick)
    }

    // MARK: - Raster thread

    private func rasterize(_ job: TextJob) {
        let raster: TextRaster
        do {
            raster = try renderer.rasterize(job)
        } catch {
            // Spec 4 §12 — "Text raster fails (font missing, layout exception): Draw with the fallback font".
            log?.error("text raster failed: \(error)")
            lock.lock()
            pending.remove(job.key)
            stats.failed += 1
            stats.pending = pending.count
            lock.unlock()
            return
        }
        var lines: [TextLine] = []
        var bytes = 0
        for line in raster.lines {
            let handle = backend.makeTexture(TextureDescriptor(role: .textLine, size: PixelSize(width: line.width, height: line.height),
                                                               label: "text " + job.text.prefix(16)))
            guard !handle.isNone else { continue }
            (backend as? MetalBackend)?.upload(bgra8: line.pixels, bytesPerRow: line.bytesPerRow, into: handle)
            lines.append(TextLine(texture: handle, frame: line.frame))
            bytes += line.bytes
        }
        lock.lock()
        clock += 1
        entries[job.key] = Entry(lines: lines, bytes: bytes, layout: raster.layout, substitutedFont: raster.substitutedFont, lastUsed: clock)
        pending.remove(job.key)
        stats.rasterized += 1
        stats.bytes += bytes
        stats.pending = pending.count
        if let substituted = raster.substitutedFont { substitutions.insert(job.style.values.font + " -> " + substituted) }
        evictIfNeeded()
        lock.unlock()
    }

    /// Spec 4 §8 — "an LRU bounded by bytes": the least recently used entries
    /// go first, their textures released after the plans that may name them.
    private func evictIfNeeded() {
        guard stats.bytes > maximumBytes else { return }
        let ordered = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
        for (key, entry) in ordered where stats.bytes > maximumBytes {
            // Keep what the last few plans used.
            if entry.lastUsed + 8 >= clock { continue }
            entries.removeValue(forKey: key)
            stats.bytes -= entry.bytes
            stats.evicted += 1
            for line in entry.lines { backend.resources.release(line.texture, afterTick: releaseAfterTick) }
        }
    }

    // MARK: - Reading

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    public func layout(for key: TextKey) -> TextLayout? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]?.layout
    }

    /// Spec 4 §8 — "recording the substitution for pre-flight".
    public var fontSubstitutions: [String] {
        lock.lock()
        defer { lock.unlock() }
        return substitutions.sorted()
    }

    /// Harness: block until the raster queue is idle.
    public func waitUntilIdle() {
        queue.sync {}
    }
}
