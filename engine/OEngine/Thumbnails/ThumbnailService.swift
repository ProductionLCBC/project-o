// OEngine — Spec 4 §10, thumbnails.

import Foundation
import OCore
import OFormats

public enum ThumbnailError: Error, Equatable {
    case noSuchStack(Int)
    case noSuchCue(Int)
    case noTextures
    case renderDidNotComplete
    case readbackFailed
}

/// Spec 4 §10 — "The thumbnail job renders a cue's projected state (Spec 3)
/// on the thumbnail stack at 480 px wide, on the background queue, using the
/// normal stack pass against poster frames and rasterized text. Results are
/// written as PNG into a disk cache keyed by (cue uuid, stack, library
/// version) so thumbnails survive a relaunch; the UI reads them through the
/// same IOSurface path or as files." Spec 4 §3 — "Thumbnails and multiviewer:
/// background ... rate-limited to 30 Hz". Spec 4 §4 — aux work is "skipped
/// first under pressure", so the job waits while the render thread is
/// skipping its aux passes. Spec 4 §8 — "Thumbnails use the same rasterizer
/// at thumbnail scale". Spec 4 §5 — the thumbnail textures are "A fixed pool".
/// Spec 4 §12 — memory pressure shrinks the thumbnail cache.
public final class ThumbnailService: ShrinkableCache, @unchecked Sendable {
    /// Spec 4 §10 — "480 px wide".
    public static let width = 480
    /// Spec 4 §3 — "rate-limited to 30 Hz": the least time between two renders of a warm.
    public static let minimumIntervalNs: Int64 = 1_000_000_000 / 30

    public enum Outcome: Equatable, Sendable { case rendered, cached }

    public struct Result: Sendable {
        public var cue: UUID
        public var stack: Int
        public var version: String
        public var url: URL
        public var outcome: Outcome
        /// The rendered pixels, premultiplied linear, when the thumbnail was rendered now.
        public var frame: CapturedFrame?
        /// Spec 4 §10 — the IOSurface the thumbnail landed in, when rendered now.
        public var surfaceID: UInt32?
        public var size: PixelSize
    }

    public struct Statistics: Equatable, Sendable {
        public var rendered = 0
        public var hits = 0
        public var diskHits = 0
        public var misses = 0
        public var failed = 0
        public var queued = 0

        /// Spec 4 §13 — "cache hit rates": the thumbnail cache's, memory and disk together.
        public var hitRate: Double {
            let asked = hits + diskHits + misses
            return asked > 0 ? Double(hits + diskHits) / Double(asked) : 1
        }
    }

    public let name = "thumbnails"
    public let library: Library
    public let machine: Machine
    /// Spec 1 §3 — the machine's `thumbnailStack`.
    public let stack: Int
    public let size: PixelSize
    public let textCache: TextCache
    public let cache: ThumbnailCache
    private let stackObject: Stack
    private let backend: MetalBackend
    private let posters: any PosterProvider
    private let variables: VariableProvider
    private let missing: Set<String>
    private let scratch: TextureHandle
    private let pool: [TextureHandle]
    private var nextPoolSlot = 0
    private let queue = DispatchQueue(label: "o.engine.thumbnails", qos: .background)
    private let lock = NSLock()
    private var stats = Statistics()
    private var blocked: @Sendable () -> Bool = { false }
    private var lastRenderNs: Int64 = 0
    private let log: EngineLog

    public init(library: Library, machine: Machine, mediaRoot: URL?, backend: MetalBackend, posters: any PosterProvider, variables: VariableProvider,
                cacheFolder: URL, log: EngineLog, poolSize: Int = 32, textCacheBytes: Int = 64 * 1024 * 1024, memoryBytes: Int = 32 * 1024 * 1024) throws {
        self.library = library
        self.machine = machine
        self.backend = backend
        self.posters = posters
        self.variables = variables
        self.log = log
        stack = machine.settings.thumbnailStack
        guard let stackObject = machine.stack(stack) else { throw ThumbnailError.noSuchStack(stack) }
        self.stackObject = stackObject
        let full = MachineGeometry(library: library, machine: machine).stackSize(stack)
        let height = max(1, Int((Double(ThumbnailService.width) / max(0.01, full.aspect)).rounded()))
        size = PixelSize(width: ThumbnailService.width, height: height)
        textCache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: machine.settings.fallbackFont), backend: backend,
                              maximumBytes: textCacheBytes, synchronous: true, log: log)
        cache = ThumbnailCache(folder: cacheFolder, maximumBytes: memoryBytes)
        if let mediaRoot, let existing = try? LocalFiles.existingMediaPaths(mediaRoot: mediaRoot) {
            missing = MediaResolver.missingIds(library: library, machine: machine, existingPaths: existing)
        } else {
            missing = []
        }
        // Spec 4 §5 — allocated at load: the scratch stack texture and the fixed pool of thumbnail textures.
        scratch = backend.makeTexture(TextureDescriptor(role: .stack, size: size, label: "thumbnail stack"))
        var pool: [TextureHandle] = []
        for index in 0..<max(1, poolSize) {
            let handle = backend.makeTexture(TextureDescriptor(role: .thumbnail, size: size, label: "thumbnail \(index)"))
            if !handle.isNone { pool.append(handle) }
        }
        self.pool = pool
        guard !scratch.isNone, !pool.isEmpty else { throw ThumbnailError.noTextures }
    }

    // MARK: - Reading

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Spec 4 §4 — set by the engine to the render thread's reading of
    /// pressure; the job waits while it is true.
    public var auxBlocked: @Sendable () -> Bool {
        get { lock.lock(); defer { lock.unlock() }; return blocked }
        set { lock.lock(); blocked = newValue; lock.unlock() }
    }

    /// The file of a cue's thumbnail at the current library version, if it exists.
    public func thumbnailURL(forCue cue: UUID, in list: List) -> URL? {
        cache.lookup(ThumbnailKey(cue: cue, stack: stack, version: LibraryVersion.hash(library: library, list: list)))?.url
    }

    /// The PNG of a cue's thumbnail, from memory or disk, if it exists.
    public func thumbnailData(forCue cue: UUID, in list: List) -> Data? {
        cache.data(for: ThumbnailKey(cue: cue, stack: stack, version: LibraryVersion.hash(library: library, list: list)))
    }

    // MARK: - Rendering

    /// Spec 4 §10 — render the thumbnail of the cue at `position` (1-based,
    /// Spec 1 §4) of `list`, or answer from the cache. Synchronous, on the
    /// caller's thread; `warm` runs it on the background queue.
    public func render(cue position: Int, of list: List) throws -> Result {
        guard position >= 1, position <= list.cues.count else { throw ThumbnailError.noSuchCue(position) }
        let cue = list.cues[position - 1]
        let version = LibraryVersion.hash(library: library, list: list)
        let key = ThumbnailKey(cue: cue.uuid, stack: stack, version: version)
        if let found = cache.lookup(key) {
            lock.lock()
            if found.hit == .memory { stats.hits += 1 } else { stats.diskHits += 1 }
            lock.unlock()
            return Result(cue: cue.uuid, stack: stack, version: version, url: found.url, outcome: .cached, frame: nil, surfaceID: nil, size: size)
        }
        lock.lock()
        stats.misses += 1
        let target = pool[nextPoolSlot]
        nextPoolSlot = (nextPoolSlot + 1) % pool.count
        lock.unlock()
        let states = projectedStates(of: list, through: position - 1 + furthestOffset)
        let pass = stackPass(states: states, index: position - 1)
        guard backend.renderOffline(pass, into: target) else {
            countFailure()
            throw ThumbnailError.renderDidNotComplete
        }
        guard let read = backend.readbackBGRA8(target) else {
            countFailure()
            throw ThumbnailError.readbackFailed
        }
        let png = try ThumbnailCache.png(bgra8: read.bytes, width: read.width, height: read.height)
        let url = try cache.store(png, for: key)
        lock.lock()
        stats.rendered += 1
        lock.unlock()
        return Result(cue: cue.uuid, stack: stack, version: version, url: url, outcome: .rendered,
                      frame: MetalBackend.linearFrame(bgra8: read.bytes, width: read.width, height: read.height),
                      surfaceID: backend.surfaceID(of: target), size: size)
    }

    private func countFailure() {
        lock.lock()
        stats.failed += 1
        lock.unlock()
    }

    /// Spec 4 §10 — the job on "the background queue": every cue of the list
    /// that is not cached, in order, each render waiting out the render
    /// thread's pressure and the 30 Hz pace. The engine calls this when the
    /// live list changes (Area 5 reading, approved 2026-11-03).
    public func warm(list: List) {
        lock.lock()
        stats.queued += 1
        lock.unlock()
        queue.async { [self] in
            for position in 1...max(1, list.cues.count) where position <= list.cues.count {
                let cue = list.cues[position - 1]
                if cache.lookup(ThumbnailKey(cue: cue.uuid, stack: stack, version: LibraryVersion.hash(library: library, list: list))) != nil { continue }
                // Spec 4 §4 — "skipped first under pressure".
                while auxBlocked() { Thread.sleep(forTimeInterval: 0.05) }
                // Spec 4 §3 — "rate-limited to 30 Hz".
                let since = MonotonicClock.now().nanoseconds - lastRenderNs
                if since < ThumbnailService.minimumIntervalNs {
                    Thread.sleep(forTimeInterval: Double(ThumbnailService.minimumIntervalNs - since) / 1e9)
                }
                autoreleasepool {
                    do {
                        _ = try render(cue: position, of: list)
                    } catch {
                        log.error("thumbnail of cue \(position) of list \(list.number): \(error)")
                    }
                }
                lastRenderNs = MonotonicClock.now().nanoseconds
            }
        }
    }

    /// Harness: block until the queue is idle.
    public func waitUntilIdle() {
        queue.sync {}
    }

    // MARK: - The projected state (Spec 3)

    /// The furthest offset any slot of the thumbnail stack looks ahead.
    private var furthestOffset: Int { stackObject.slots.map(\.offset).max() ?? 0 }

    /// Spec 3 §1 — "the cue grid runs it from the top of a list to draw
    /// thumbnails": tracked state from the top of the list, starting empty,
    /// the state after each cue in turn, so cue 1's background shows on every
    /// later thumbnail.
    func projectedStates(of list: List, through index: Int) -> [ShowState] {
        var state = ShowState.fresh(library: library, machine: machine)
        var out: [ShowState] = []
        for (i, cue) in list.cues.enumerated() where i <= index {
            let current = state
            let variables = self.variables
            let context = ProjectionContext(frame: 0, library: library, machine: machine, missing: missing,
                                            source: CommandSource(kind: .cue, list: list.uuid, cue: cue.uuid),
                                            variables: { name in variables.value(name, state: current) })
            state = project(state, cue.commands.map(\.command), context: context).0
            out.append(state)
        }
        return out
    }

    /// Spec 4 §10 — "the normal stack pass against poster frames and
    /// rasterized text": the slots resolved as the live plan resolves them,
    /// pixel boxes bound to posters, text through the thumbnail's own cache
    /// at thumbnail scale, offset slots from the states after this cue.
    func stackPass(states: [ShowState], index: Int) -> StackPass {
        let state = states[min(index, states.count - 1)]
        let eager = EagerTextProvider(cache: textCache)
        let inputs = SlotResolver.Inputs(library: library, stack: stackObject, size: size, muted: state.stacks[stack]?.muted ?? [], text: eager)
        var boxes: [ResolvedBox] = []
        for (slotIndex, slot) in stackObject.effectiveSlots(library: library).enumerated() {
            var content: ContentInstance?
            if slot.offset >= 0, index + slot.offset < states.count {
                content = states[index + slot.offset].channels[slot.channel]?.content
            }
            let results = SlotResolver.resolve(inputs, slotIndex: slotIndex, slot: slot, content: content,
                                               pixels: { _, content in self.posterSource(for: content) },
                                               staticText: { _, _, raw in self.variables.resolve(raw, state: state) },
                                               onTextMiss: { _ in })
            boxes.append(contentsOf: results.compactMap(\.resolved))
        }
        return StackPass(stack: stack, target: scratch, size: size, base: stackObject.base, gammaBlend: stackObject.gammaBlend, boxes: boxes)
    }

    /// Spec 4 §5 — "Poster frame ... For offset slots and thumbnails".
    private func posterSource(for content: ContentInstance?) -> SlotResolver.PixelSource? {
        guard let media = content?.media, !media.missing, !missing.contains(media.ref),
              let entry = MediaResolver.resolve(media.ref, library: library, machine: machine)?.entry else { return nil }
        let poster = posters.poster(for: entry)
        guard !poster.isNone else { return nil }
        return SlotResolver.PixelSource(texture: poster, content: .full, contentPixels: PixelSize(width: entry.width ?? 16, height: entry.height ?? 9))
    }

    // MARK: - ShrinkableCache (Spec 4 §12)

    public var maximumBytes: Int { textCache.maximumBytes + cache.maximumBytes }

    /// The text rasters and the PNGs held in memory; the disk is not counted.
    public var bytesInUse: Int { textCache.statistics.bytes + cache.memoryBytes }

    /// Spec 4 §12 — "shrinks the text and thumbnail caches": the ceiling is
    /// shared between the thumbnail's text rasters and its PNGs in memory, in
    /// proportion to their caps.
    public func setPressureCeiling(_ bytes: Int?) {
        guard let bytes else {
            textCache.setPressureCeiling(nil)
            cache.setPressureCeiling(nil)
            return
        }
        let total = Double(max(1, maximumBytes))
        textCache.setPressureCeiling(Int(Double(bytes) * Double(textCache.maximumBytes) / total))
        cache.setPressureCeiling(Int(Double(bytes) * Double(cache.maximumBytes) / total))
    }
}

/// Spec 4 §8 — the thumbnail job's view of its text cache: a miss rasterizes
/// now (the cache is synchronous) so the stack pass never draws a late box.
final class EagerTextProvider: TextProvider, @unchecked Sendable {
    let cache: TextCache

    init(cache: TextCache) {
        self.cache = cache
    }

    func entry(for job: TextJob) -> TextEntry? {
        if let entry = cache.entry(for: job) { return entry }
        cache.request(job)
        return cache.entry(for: job)
    }

    func request(_ job: TextJob) {
        cache.request(job)
    }

    func release(_ key: TextKey, afterTick: Int64) {
        cache.release(key, afterTick: afterTick)
    }

    func sweep(consumedTick: Int64) {
        cache.sweep(consumedTick: consumedTick)
    }
}
