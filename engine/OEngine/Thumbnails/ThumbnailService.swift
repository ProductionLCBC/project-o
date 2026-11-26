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
    /// Spec 5 §2 — the roots as the edits left them: "The cue's thumbnail is
    /// redrawn because its library version changes (Spec 4 §10)". Read under
    /// the lock; a render reads them once.
    private var roots: (library: Library, machine: Machine)
    /// Spec 1 §3 — the machine's `thumbnailStack`, as the roots name it now:
    /// a renumber of that stack rewrites the setting with it (Spec 1 §4).
    public var stack: Int {
        lock.lock()
        defer { lock.unlock() }
        return roots.machine.settings.thumbnailStack
    }
    /// Spec 4 §10 — "480 px wide", and as tall as the thumbnail stack's shape
    /// makes that: it follows an edit that changes the shape (Spec 4 §5).
    public var size: PixelSize {
        lock.lock()
        defer { lock.unlock() }
        return sized
    }
    private var sized: PixelSize
    public let textCache: TextCache
    public let cache: ThumbnailCache
    let backend: MetalBackend
    let posters: any PosterProvider
    let variables: VariableProvider
    /// Spec 8 §9 — "The projection's `missing` set, the thumbnail job ... all
    /// take the current one": the engine's, handed over with the roots.
    private var missing: Set<String>
    /// Spec 8 §5 — the poster files there, so a version notes whether each
    /// poster was found and "a change under `.posters/` ... redraws the tiles
    /// and thumbnails that went without it".
    private var posterFiles: Set<MediaLocation>
    /// Moves on with every hand-over of the roots, so the versions worked out before it are dropped.
    private var generation = 0
    /// The cue versions of the list last asked about: the `thumbnails` query asks cue by cue, and each answer
    /// would otherwise hash the documents again.
    private var remembered: (generation: Int, list: List, versions: [String])?
    private var scratch: TextureHandle
    /// Spec 11 §3 — the test pattern at the size last asked for, drawn once for it.
    private var pattern: (size: PixelSize, handle: TextureHandle)?
    private var pool: [TextureHandle]
    private let poolSize: Int
    /// The size the scratch and the pool were made at; they are made again, on the job's own thread, when `sized` moves on.
    private var texturesSize: PixelSize
    private var nextPoolSlot = 0
    private let queue = DispatchQueue(label: "o.engine.thumbnails", qos: .background)
    private let lock = NSLock()
    private var stats = Statistics()
    private var blocked: @Sendable () -> Bool = { false }
    private var lastRenderNs: Int64 = 0
    let log: EngineLog
    /// Spec 11 §3 — work "ahead of thumbnails": the `render` query's pictures, taken before the next thumbnail.
    private var ahead: [@Sendable () -> Void] = []
    /// Spec 11 §3 — the textures of the sizes the `render` query last drew at: a stack texture and the
    /// picture's own, kept for the next picture of that size.
    var canvasTextures: [PixelSize: (stack: TextureHandle, picture: TextureHandle, used: UInt64)] = [:]
    var canvasClock: UInt64 = 0
    /// Spec 11 §3 — the channel texture of the last grade picture, kept while the next is the same size.
    var gradeTexture: (size: PixelSize, texture: TextureHandle)?
    /// Spec 11 §3 as corrected 2026-11-26 (G-43) — "one reader the job keeps open, reading forward", and the texture
    /// its last frame was drawn into at the picture's size.
    let gradeFrames = GradeFrameReader()
    var gradeFrameTexture: (size: PixelSize, texture: TextureHandle)?
    /// The media folders a video's file is found in.
    let mediaFolders: MediaFolders

    public init(library: Library, machine: Machine, media: MediaFolders, backend: MetalBackend, posters: any PosterProvider, variables: VariableProvider,
                cacheFolder: URL, log: EngineLog, poolSize: Int = 32, textCacheBytes: Int = 64 * 1024 * 1024, memoryBytes: Int = 32 * 1024 * 1024) throws {
        roots = (library, machine)
        mediaFolders = media
        self.backend = backend
        self.posters = posters
        self.variables = variables
        self.log = log
        self.poolSize = max(1, poolSize)
        let stack = machine.settings.thumbnailStack
        guard let size = ThumbnailService.thumbnailSize(library: library, machine: machine) else { throw ThumbnailError.noSuchStack(stack) }
        sized = size
        texturesSize = size
        textCache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: machine.settings.fallbackFont), backend: backend,
                              maximumBytes: textCacheBytes, synchronous: true, log: log)
        cache = ThumbnailCache(folder: cacheFolder, maximumBytes: memoryBytes)
        // Spec 8 §9 — the missing set the control loop works out, by the same rule (Spec 3 §6).
        missing = LocalFiles.missingMedia(library: library, machine: machine, folders: media)
        posterFiles = LocalFiles.mediaPosters(folders: media)
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

    /// Spec 4 §10 — "on the thumbnail stack at 480 px wide": the size of a
    /// thumbnail, 480 wide in the shape of the thumbnail stack as its own
    /// outputs give it (Spec 4 §5: the largest output whose default stack it
    /// is, else 1920 by 1080), whatever the outputs happen to show. Nil when
    /// the machine has no such stack.
    static func thumbnailSize(library: Library, machine: Machine) -> PixelSize? {
        let stack = machine.settings.thumbnailStack
        guard machine.stack(stack) != nil else { return nil }
        let full = MachineGeometry(library: library, machine: machine).stackSize(stack)
        return ThumbnailService.pictureSize(width: ThumbnailService.width, of: full)
    }

    /// A picture `width` pixels wide in the shape of `full`.
    static func pictureSize(width: Int, of full: PixelSize) -> PixelSize {
        PixelSize(width: width, height: max(1, Int((Double(width) / max(0.01, full.aspect)).rounded())))
    }

    /// The thumbnail textures, made again when the thumbnail stack's shape has changed. On the thread that renders.
    private func remakeTexturesIfNeeded() {
        lock.lock()
        let wanted = sized
        let stale = wanted != texturesSize
        lock.unlock()
        guard stale else { return }
        let newScratch = backend.makeTexture(TextureDescriptor(role: .stack, size: wanted, label: "thumbnail stack"))
        var newPool: [TextureHandle] = []
        for index in 0..<poolSize {
            let handle = backend.makeTexture(TextureDescriptor(role: .thumbnail, size: wanted, label: "thumbnail \(index)"))
            if !handle.isNone { newPool.append(handle) }
        }
        guard !newScratch.isNone, !newPool.isEmpty else {
            for handle in [newScratch] + newPool { backend.resources.release(handle) }
            log.error("thumbnails: no textures could be made at \(wanted.width)x\(wanted.height); the ones there go on serving")
            return
        }
        lock.lock()
        let old = [scratch] + pool
        scratch = newScratch
        pool = newPool
        nextPoolSlot = 0
        texturesSize = wanted
        lock.unlock()
        for handle in old { backend.resources.release(handle) }
    }

    // MARK: - Reading

    public var library: Library {
        lock.lock()
        defer { lock.unlock() }
        return roots.library
    }

    public var machine: Machine {
        lock.lock()
        defer { lock.unlock() }
        return roots.machine
    }

    /// Spec 5 §2 — the engine hands over the roots after an applied edit.
    /// The thumbnail stack is read from them at each render, so an edit of
    /// its slots, its presets or its number shows in the next thumbnail
    /// (Spec 11 §6); when its shape changes, the thumbnails' size follows,
    /// and their textures are made again before the next one is drawn.
    public func update(library: Library, machine: Machine, missing: Set<String>? = nil, posters: Set<MediaLocation>? = nil) {
        let size = ThumbnailService.thumbnailSize(library: library, machine: machine)
        lock.lock()
        roots = (library, machine)
        if let size { sized = size }
        if let missing { self.missing = missing }
        if let posters { posterFiles = posters }
        generation += 1
        remembered = nil
        lock.unlock()
    }

    /// The missing set as last handed over.
    var missingNow: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return missing
    }

    /// Spec 4 §10 — each cue's library version now, in list order: the roots,
    /// the missing set and the poster files as last handed over, and as many
    /// cues ahead as the thumbnail stack's boxes look. Worked out once for a
    /// list and kept until the list or the roots change.
    func versions(of list: List) -> [String] {
        lock.lock()
        if let remembered, remembered.generation == generation, remembered.list == list {
            lock.unlock()
            return remembered.versions
        }
        let (roots, missing, posters, generation) = (self.roots, self.missing, self.posterFiles, self.generation)
        lock.unlock()
        let lookAhead = roots.machine.stack(roots.machine.settings.thumbnailStack).map { furthestOffset(of: $0, library: roots.library) } ?? 0
        let versions = LibraryVersion.versions(library: roots.library, machine: roots.machine, list: list, missing: missing,
                                               posters: posters, lookAhead: lookAhead)
        lock.lock()
        if generation == self.generation { remembered = (generation, list, versions) }
        lock.unlock()
        return versions
    }

    /// The library version of the cue `uuid` of `list`, if the list has it.
    func version(ofCue uuid: UUID, in list: List) -> String? {
        guard let index = list.cues.firstIndex(where: { $0.uuid == uuid }) else { return nil }
        let versions = versions(of: list)
        return index < versions.count ? versions[index] : nil
    }

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
        guard let version = version(ofCue: cue, in: list) else { return nil }
        return cache.lookup(ThumbnailKey(cue: cue, stack: stack, version: version))?.url
    }

    /// The PNG of a cue's thumbnail, from memory or disk, if it exists.
    public func thumbnailData(forCue cue: UUID, in list: List) -> Data? {
        guard let version = version(ofCue: cue, in: list) else { return nil }
        return cache.data(for: ThumbnailKey(cue: cue, stack: stack, version: version))
    }

    // MARK: - Rendering

    /// Spec 4 §10 — render the thumbnail of the cue at `position` (1-based,
    /// Spec 1 §4) of `list`, or answer from the cache. Synchronous, on the
    /// caller's thread; `warm` runs it on the background queue.
    public func render(cue position: Int, of list: List) throws -> Result {
        guard position >= 1, position <= list.cues.count else { throw ThumbnailError.noSuchCue(position) }
        let cue = list.cues[position - 1]
        let roots = (library: library, machine: machine)
        let stack = roots.machine.settings.thumbnailStack
        // Spec 11 §6 — the thumbnail stack as the edits left it; one that was deleted draws nothing.
        guard let stackObject = roots.machine.stack(stack) else { throw ThumbnailError.noSuchStack(stack) }
        let versions = self.versions(of: list)
        guard position <= versions.count else { throw ThumbnailError.noSuchCue(position) }
        let version = versions[position - 1]
        let key = ThumbnailKey(cue: cue.uuid, stack: stack, version: version)
        if let found = cache.lookup(key) {
            lock.lock()
            if found.hit == .memory { stats.hits += 1 } else { stats.diskHits += 1 }
            lock.unlock()
            return Result(cue: cue.uuid, stack: stack, version: version, url: found.url, outcome: .cached, frame: nil, surfaceID: nil, size: size)
        }
        remakeTexturesIfNeeded()
        lock.lock()
        stats.misses += 1
        let target = pool[nextPoolSlot]
        nextPoolSlot = (nextPoolSlot + 1) % pool.count
        let scratch = self.scratch
        let size = texturesSize
        lock.unlock()
        // A raster made for a later box must not push out the lines of an earlier box of the same picture.
        let drawn = textCache.withoutEviction { () -> Bool in
            let states = projectedStates(of: list, through: position - 1 + furthestOffset(of: stackObject, library: roots.library), roots: roots)
            let pass = stackPass(states: states, index: position - 1, roots: roots, list: list, stack: stackObject, size: size, target: scratch)
            return backend.renderOffline(pass, into: target)
        }
        guard drawn else {
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
        let hook = written
        lock.unlock()
        let result = Result(cue: cue.uuid, stack: stack, version: version, url: url, outcome: .rendered,
                            frame: MetalBackend.linearFrame(bgra8: read.bytes, width: read.width, height: read.height),
                            surfaceID: backend.surfaceID(of: target), size: size)
        hook?(result, list)
        return result
    }

    /// Spec 10 §3, the `thumbnails` topic — "A cue thumbnail written, with
    /// its stack, list, cue and file ... When written": called on the thread
    /// that rendered it, once per file written; a thumbnail answered from
    /// the cache writes nothing and calls nothing.
    public var onWritten: (@Sendable (Result, List) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return written
        }
        set {
            lock.lock()
            written = newValue
            lock.unlock()
        }
    }
    private var written: (@Sendable (Result, List) -> Void)?

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
                // Spec 11 §3 — the `render` query's pictures are drawn "ahead of thumbnails".
                runAhead()
                if let version = version(ofCue: cue.uuid, in: list), cache.lookup(ThumbnailKey(cue: cue.uuid, stack: stack, version: version)) != nil {
                    continue
                }
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

    /// G-43 — "it closes after ten seconds unused": looked at on the job's queue once that long has passed.
    func closeGradeFramesWhenIdle() {
        queue.asyncAfter(deadline: .now() + Double(GradeFrameReader.idleNs) / 1e9 + 0.1) { [weak self] in
            self?.gradeFrames.closeIfIdle()
        }
    }

    /// Spec 11 §3 — "The engine draws it on the thumbnail job's background
    /// queue, with the thumbnail job's code, ahead of thumbnails, and waits
    /// as that job does while the render thread is skipping aux passes (Spec
    /// 4 §10)": `work` runs on the job's queue before the next thumbnail,
    /// once the render thread has headroom and at the job's own pace.
    func performAhead(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        ahead.append(work)
        lock.unlock()
        queue.async { [self] in runAhead() }
    }

    /// On the job's queue: what waits ahead of the thumbnails, in order. Spec
    /// 11 §3 as corrected 2026-11-26 (G-43) — "between two thumbnails the job
    /// draws the pictures that were waiting, not those asked for meanwhile":
    /// work asked for while this runs waits for the next turn, which its own
    /// `performAhead` puts on the queue.
    private func runAhead() {
        lock.lock()
        var waiting = ahead.count
        lock.unlock()
        while waiting > 0 {
            waiting -= 1
            lock.lock()
            guard !ahead.isEmpty else {
                lock.unlock()
                return
            }
            let work = ahead.removeFirst()
            lock.unlock()
            // Spec 4 §4 — "skipped first under pressure"; Spec 4 §3 — "rate-limited to 30 Hz".
            while auxBlocked() { Thread.sleep(forTimeInterval: 0.05) }
            let since = MonotonicClock.now().nanoseconds - lastRenderNs
            if since < ThumbnailService.minimumIntervalNs {
                Thread.sleep(forTimeInterval: Double(ThumbnailService.minimumIntervalNs - since) / 1e9)
            }
            autoreleasepool { work() }
            lastRenderNs = MonotonicClock.now().nanoseconds
        }
    }

    // MARK: - The projected state (Spec 3)

    /// Spec 6 §3 — the furthest offset any box of a stack's layouts looks
    /// ahead, within what v1 draws (0 to +3).
    func furthestOffset(of stackObject: Stack, library: Library) -> Int {
        let offsets = stackObject.effectiveSlots(library: library).flatMap {
            SlotResolver.offsets(of: SlotResolver.layout(for: $0, stack: stackObject, library: library))
        }
        return min(Box.drawnOffsets.upperBound, max(0, offsets.max() ?? 0))
    }

    /// Spec 3 §1 — "the cue grid runs it from the top of a list to draw
    /// thumbnails": tracked state from the top of the list, starting empty,
    /// the state after each cue in turn, so cue 1's background shows on every
    /// later thumbnail. Spec 6 §5 — "Context values and list metadata come
    /// from the state being drawn: ... a thumbnail's projected state", and "In
    /// a static box, a value reads the state's pointer: its cue and its list";
    /// "A projected state has no playlist": each state read names the cue
    /// drawn and its list, with no playlist. The fold itself runs as before,
    /// from no pointer.
    ///
    /// The fold is OCore's (`CueView`, Spec 3 §7), the one the app's cue grid
    /// reads its chips from (Spec 10 §6), so a thumbnail and its chips can't
    /// disagree.
    func projectedStates(of list: List, through index: Int, roots: (library: Library, machine: Machine)) -> [ShowState] {
        let (library, machine) = roots
        lock.lock()
        let missing = self.missing
        lock.unlock()
        let variables = self.variables
        return CueView.states(of: list, through: index, library: library, machine: machine, missing: missing) { name, before in
            variables.value(name, state: before)
        }
    }

    /// Spec 4 §10 — "the normal stack pass against poster frames and
    /// rasterized text": the slots resolved as the live plan resolves them,
    /// pixel boxes bound to posters, text through the thumbnail's own cache
    /// at thumbnail scale. Spec 6 §3 — "In a projected state, such as a
    /// thumbnail ..., a +K box folds the next K cues of the same list from the
    /// cue being drawn. That fold has no playlist, so past the list's end the
    /// box draws nothing": offset boxes from the states after this cue, of
    /// `list`, the list the states were folded from.
    func stackPass(states: [ShowState], index: Int, roots: (library: Library, machine: Machine), list: List) -> StackPass {
        let number = roots.machine.settings.thumbnailStack
        lock.lock()
        let (scratch, size) = (self.scratch, texturesSize)
        lock.unlock()
        let stackObject = roots.machine.stack(number) ?? Stack(number: number)
        return stackPass(states: states, index: index, roots: roots, list: list, stack: stackObject, size: size, target: scratch)
    }

    /// The same pass for any stack at any size, into `target`: the thumbnail
    /// stack at 480 wide for a thumbnail, and the stack and width a `render`
    /// asks for (Spec 11 §3: "The cue's projected state on that stack ... as
    /// the thumbnail job draws it").
    func stackPass(states: [ShowState], index: Int, roots: (library: Library, machine: Machine), list: List, stack stackObject: Stack,
                   size: PixelSize, target scratch: TextureHandle) -> StackPass {
        let library = roots.library
        let stack = stackObject.number
        let state = states[min(index, states.count - 1)]
        let eager = EagerTextProvider(cache: textCache)
        // Spec 6 §3 — the list being drawn stands as the kept copy, so its field boxes find it even when the
        // library no longer holds that version.
        let inputs = SlotResolver.Inputs(library: library, machine: roots.machine, kept: KeptCopies(list: list), stack: stackObject, size: size,
                                         muted: state.stacks[stack]?.muted ?? [], text: eager)
        // Spec 6 §5 — "[Time], [Date], [Timer N] and [Service In] read the same in every state ... A thumbnail shows
        // them as they were when it rendered": the wall clock now, the live playlist and timers the last build published.
        let variableRoots = VariableRoots(library: library, machine: roots.machine, kept: KeptCopies(list: list))
        let clock = variables.publishedClock()
        var boxes: [ResolvedBox] = []
        for slot in stackObject.effectiveSlots(library: library) {
            let results = SlotResolver.resolve(inputs, slot: slot,
                                               state: { offset in
                                                   guard offset >= 0, index + offset < states.count else { return nil }
                                                   return states[index + offset]
                                               },
                                               pixels: { _, _, content in self.posterSource(for: content, roots: roots) },
                                               text: { key, _, template, shown in
                                                   let resolved = self.variables.resolve(template.raw, state: shown, scope: template.scope,
                                                                                         roots: variableRoots, clock: clock)
                                                   if !resolved.issues.isEmpty { self.variables.log(resolved.issues, box: key, to: self.log) }
                                                   return SlotResolver.BoxText(text: resolved.text, tabular: resolved.tabular)
                                               },
                                               onTextMiss: { _ in })
            boxes.append(contentsOf: results.compactMap(\.resolved))
        }
        return StackPass(stack: stack, target: scratch, size: size, base: stackObject.base, gammaBlend: stackObject.gammaBlend, boxes: boxes)
    }

    /// Spec 4 §5 — "Poster frame ... For offset boxes and thumbnails".
    /// Spec 11 §3 as corrected 2026-11-24 — "the test pattern, which the engine draws itself at the stack's size": made
    /// on the thumbnail queue the first time a size is asked for, and kept for the next picture of that size.
    func patternSource(_ size: PixelSize) -> SlotResolver.PixelSource? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let pattern, pattern.size == size {
            return SlotResolver.PixelSource(texture: pattern.handle, content: .full, contentPixels: size)
        }
        if let old = pattern {
            backend.resources.release(old.handle)
            pattern = nil
        }
        let handle = backend.makeTexture(TextureDescriptor(role: .poster, size: size, label: "test pattern"))
        guard !handle.isNone else { return nil }
        backend.upload(bgra8: TestPattern.bgra(width: size.width, height: size.height), bytesPerRow: size.width * 4, into: handle)
        pattern = (size, handle)
        return SlotResolver.PixelSource(texture: handle, content: .full, contentPixels: size)
    }

    func posterSource(for content: ContentInstance?, roots: (library: Library, machine: Machine)) -> SlotResolver.PixelSource? {
        guard let media = content?.media, !media.missing,
              let resolved = MediaResolver.resolve(media.ref, library: roots.library, machine: roots.machine),
              let key = PosterKey.of(resolved) else { return nil }
        let entry = resolved.entry
        // Spec 4 §10 — on the thumbnail queue: loaded now if it must be, so no thumbnail draws without a poster that is there.
        let poster = posters.load(key)
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
