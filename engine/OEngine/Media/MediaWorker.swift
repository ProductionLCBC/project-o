// OEngine — Spec 8 §2–§4, the media worker: the walk and import, off the control and render threads.

import Foundation
import OCore
import OFormats

/// Spec 8 §4 — the walk's first look: every file in the folders it reads,
/// its size and date, before anything is hashed. Presence follows it at
/// once: a file that went is missing from the next build.
public struct MediaListing: Sendable {
    public var folders: Set<MediaFolder>
    public var files: [MediaLocation: MediaFileStat]
    public var overrideTargets: Set<MediaLocation>
    /// Spec 8 §5 — the poster files in each folder's `.posters/`, which the
    /// walk skips as media: what the poster loader and the thumbnail
    /// versions know of posters (a change there "makes it look again").
    public var posters: Set<MediaLocation> = []
}

/// Spec 8 §6 — what a parked `media delete` or `media undelete` asks of the
/// worker for one item.
public struct MediaMove: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "The worker moves the item's file, and any identical copy the walk found, to the Trash."
        case trash([MediaLocation])
        /// "moves the files back to where they came from ... and checks each file against the id".
        case restore([MediaTrashedFile])
    }

    public var id: String
    public var kind: Kind
    /// The entry's own size and date, which confirm a restored file's id
    /// without hashing it (Spec 8 §2, "otherwise from the entry's own size
    /// and date when they match").
    public var size: Int?
    public var modified: String?

    public init(id: String, kind: Kind, size: Int? = nil, modified: String? = nil) {
        self.id = id
        self.kind = kind
        self.size = size
        self.modified = modified
    }

    /// The locations whose files this move takes away while it runs, which
    /// the walk doesn't count as gone (the plan's "in-flight moves hidden
    /// from the walk").
    public var locations: [MediaLocation] {
        switch kind {
        case .trash(let locations): return locations
        case .restore(let files): return files.map(\.location)
        }
    }
}

/// Spec 8 §4 — what the walk found, ready for its rules on the control thread.
public struct MediaFindings: Sendable {
    public var folders: Set<MediaFolder>
    public var found: [MediaLocation: MediaFound]
    public var overrideTargets: Set<MediaLocation>
}

/// Spec 8 §2 — "The engine does all of it (M1). Importing, walking the
/// media folders, hashing, reading metadata ... happen in the engine
/// process, on a worker at background priority, never on the control or
/// render threads (Spec 4 §3)."
///
/// The worker reads the disk and writes copies; it never changes an index.
/// What it finds goes to the control thread as reports, which a build takes
/// in "through the one queue" (Spec 8 §2) and applies against the indexes as
/// they are then, so an import and a walk never race an edit. Walks and
/// imports run one at a time, in the order asked, so a walk always sees the
/// copies of the imports before it. The control thread hands the worker
/// what it applied (`adopt`), which the worker reads to decide what to hash,
/// read and copy.
public final class MediaWorker: @unchecked Sendable {
    /// Spec 8 §11 — "Free space, the watcher's events, the Trash and the
    /// clock are seams, so the tests run without real volumes or waits."
    public struct Seams: Sendable {
        /// The wall clock: the two seconds a file must hold, and `addedAt`.
        public var now: @Sendable () -> Date
        /// Run something later on another thread: the walk again once the
        /// files still being written have held for two seconds. Tests leave it out.
        public var schedule: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)?
        /// Spec 8 §3 — "found by opening the file".
        public var probe: any MediaProbe
        /// The free bytes of the volume a folder is on.
        public var freeBytes: @Sendable (URL) -> Int64?
        /// Spec 4 §10 — background work waits while the render thread is skipping aux passes.
        public var blocked: @Sendable () -> Bool
        /// Tests only: runs with a file's source once it is hashed, before its
        /// copy is made (Spec 8 §11, "a file changed mid-import is refused").
        public var beforeCopy: (@Sendable (URL) -> Void)?
        /// Spec 8 §5 — "the frame at the video's default in-point ... taken exactly".
        public var frames: any MediaFrames
        /// Spec 8 §6 — where `media delete` moves files, and `media undelete` finds them.
        public var trash: any MediaTrash

        public init(now: @escaping @Sendable () -> Date = { Date() },
                    schedule: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
                    probe: any MediaProbe = AVMediaProbe(),
                    freeBytes: @escaping @Sendable (URL) -> Int64? = MediaWorker.freeBytes,
                    blocked: @escaping @Sendable () -> Bool = { false },
                    beforeCopy: (@Sendable (URL) -> Void)? = nil,
                    frames: any MediaFrames = AVMediaFrames(),
                    trash: any MediaTrash = SystemTrash()) {
            self.now = now
            self.schedule = schedule
            self.probe = probe
            self.freeBytes = freeBytes
            self.blocked = blocked
            self.beforeCopy = beforeCopy
            self.frames = frames
            self.trash = trash
        }

        /// The engine's own: the real clock, a timer, AVFoundation, the volume's free space.
        public static func live(blocked: @escaping @Sendable () -> Bool = { false }) -> Seams {
            Seams(schedule: { delay, work in DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay, execute: work) },
                  blocked: blocked)
        }
    }

    /// What the control thread last applied.
    public struct Snapshot: Sendable {
        public var library: MediaIndex
        public var machine: MediaLocalIndex
        public var libraryWritable: Bool
        public var importFolder: String
        public var cache: MediaCache
        public var missing: Set<String>
        /// Spec 8 §2 — what is known of each location, for each entry's own presence.
        public var files: [MediaLocation: MediaFileState]

        public init(library: MediaIndex = MediaIndex(), machine: MediaLocalIndex = MediaLocalIndex(), libraryWritable: Bool = false,
                    importFolder: String = "imports", cache: MediaCache = MediaCache(), missing: Set<String> = [],
                    files: [MediaLocation: MediaFileState] = [:]) {
            self.library = library
            self.machine = machine
            self.libraryWritable = libraryWritable
            self.importFolder = importFolder
            self.cache = cache
            self.missing = missing
            self.files = files
        }

        func entry(_ id: String) -> MediaEntry? {
            MediaResolver.entry(for: id, library: library, machine: machine)?.entry
        }

        /// The entry whose path is this location, if one holds it.
        func entry(at location: MediaLocation) -> MediaEntry? {
            switch location.folder {
            case .mediaRoot: return library.entries.first { $0.path == location.path && !$0.isDeleted }
            case .machineMedia: return machine.entries.first { $0.path == location.path && !$0.isDeleted }
            case .absolute: return nil
            }
        }

        /// The entry whose path each location is, for a whole walk at once.
        func holders() -> [MediaLocation: MediaEntry] {
            var out: [MediaLocation: MediaEntry] = [:]
            for e in library.entries where !e.isDeleted {
                if let location = MediaLocation(.mediaRoot, e.path), out[location] == nil { out[location] = e }
            }
            for e in machine.entries where !e.isDeleted {
                if let location = MediaLocation(.machineMedia, e.path), out[location] == nil { out[location] = e }
            }
            return out
        }
    }

    /// What the worker hands the control thread.
    public enum Report: Sendable {
        case listed(MediaListing)
        case walked(MediaFindings)
        /// Spec 8 §7 — a `media` event's own fields, for the topic.
        case event([String: JSONValue])
        /// Spec 8 §3 — a file from outside both folders, copied in.
        case copied(job: String, file: String, MediaImport.Copied)
        /// Spec 8 §3 — a file's outcome, decided with nothing copied.
        case decided(job: String, file: String, MediaImportOutcome)
        /// Spec 8 §3 — a file already in a folder, which the walk indexes where it is.
        case inPlace(job: String, file: String, MediaLocation)
        /// Spec 8 §5 — posters made (or that failed), and the old files that
        /// went once the new ones were written.
        case posters(made: [MediaPosters.Made], removed: [MediaLocation])
        /// Spec 8 §5 — the pool tiles there now, by name, after a pass drew some.
        case tiles(Set<String>)
        /// Spec 8 §6 — a park's files moved, by id: where each came from and
        /// where it went; or why not, every file already moved put back.
        case moved(park: Int, Result<[String: [MediaTrashedFile]], Rejection>)
        /// Spec 8 §6 — a park's files are back where they were.
        case undone(park: Int)
    }

    /// Spec 8 §4 — "A file is read once its size and modification date have held for two seconds".
    public static let settle: TimeInterval = 2
    /// Spec 8 §3 — "An import that would leave less than 1 GB free on its volume is refused".
    public static let reserve: Int64 = 1_000_000_000

    public let folders: MediaFolders
    let machineRoot: URL?
    let staging: URL?
    let seams: Seams
    let log: EngineLog
    private let queue = DispatchQueue(label: "o.engine.media", qos: .background)
    /// Spec 8 §6 — "the worker's urgent queue, ahead of all background work": Trash moves.
    private let urgent = DispatchQueue(label: "o.engine.media.urgent", qos: .userInitiated)
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var reports: [Report] = []
    private var walkQueued = false
    private var walkScheduled = false
    private var postersQueued = false
    private var hashes = 0
    private var submissions = 0

    /// How many files the worker has hashed, for the tests of the cache (Spec 8 §11).
    public var hashCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hashes
    }

    private func countHash() {
        lock.lock()
        hashes += 1
        lock.unlock()
    }

    // On the queue only.
    private struct Memo {
        var stat: MediaFileStat
        var id: String?
        var read: MediaRead?
        var notYet = false
    }
    private var memo: [MediaLocation: Memo] = [:]
    /// Ids an import reported, until the control thread's snapshot holds them.
    private var reportedIDs: Set<String> = []
    /// Paths an import's copy took, until the snapshot holds them.
    private var claimed: Set<MediaLocation> = []
    /// Spec 8 §5 — posters whose extraction failed this run, with their
    /// video's size and date then: tried again only once that file changes.
    private var failedPosters: [MediaLocation: (source: MediaLocation, stat: MediaFileStat?)] = [:]
    /// Whether the tiles there have been reported since launch.
    private var tilesReported = false
    /// Tiles that couldn't be drawn this run, with their source's size and
    /// date then: drawn again only once that file changes.
    private var failedTiles: [String: MediaFileStat?] = [:]

    public init(folders: MediaFolders, machineRoot: URL?, staging: URL?, seams: Seams = .live(), log: EngineLog) {
        self.folders = folders
        self.machineRoot = machineRoot
        self.staging = staging
        self.seams = seams
        self.log = log
    }

    // MARK: - The control thread's side

    /// The indexes, mode, import folder, cache and missing set the control
    /// thread applied, for the worker to read.
    public func adopt(_ next: Snapshot) {
        lock.lock()
        snapshot = next
        lock.unlock()
    }

    func current() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    /// Spec 8 §4 — "The engine walks the media root and `machine/media/` at
    /// launch, on `media rebuild`, and whenever its watcher reports a change
    /// under either folder". Asks made while a walk waits are one walk.
    public func requestWalk() {
        lock.lock()
        let queued = walkQueued
        walkQueued = true
        lock.unlock()
        guard !queued else { return }
        enqueue { [self] in
            lock.lock()
            walkQueued = false
            lock.unlock()
            walk()
        }
    }

    /// Spec 8 §5 — "by the walk when one is missing": the posters and tiles
    /// the indexes as last adopted lack, made now. Asks made while a pass
    /// waits are one pass.
    public func requestPosters() {
        lock.lock()
        let queued = postersQueued
        postersQueued = true
        lock.unlock()
        guard !queued else { return }
        enqueue { [self] in
            lock.lock()
            postersQueued = false
            lock.unlock()
            posterPass()
        }
    }

    /// Spec 8 §3 — `media import "PATH"`, the job its result named.
    public func importPath(job: String, path: String) {
        enqueue { [self] in runImport(job: job, path: path) }
    }

    /// Spec 8 §4 — write the cache the control thread applied.
    public func persist(_ cache: MediaCache) {
        enqueue { [self] in
            guard let machineRoot else { return }
            let path = DocumentKind.mediaCache.fixedPath ?? "media-cache.json"
            do {
                try LocalFiles.execute(WritePlan(operations: [.replace(path: path, data: Writer.data(for: .mediaCache(cache)))]), in: machineRoot)
            } catch {
                log.error("could not write the media cache: \(error)")
            }
        }
    }

    /// Spec 8 §3 — "empties the folder at launch".
    public func emptyStaging() {
        enqueue { [self] in
            guard let staging, let items = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return }
            for item in items { try? FileManager.default.removeItem(at: item) }
        }
    }

    /// Spec 8 §4 — the posters of the entries the launch pruned, and their
    /// pool tiles. Only files in a `.posters/` folder or among the tiles are
    /// ever removed.
    public func removePosters(_ locations: [MediaLocation], tilesOf ids: [String] = []) {
        enqueue { [self] in
            for location in locations where location.path.hasPrefix(MediaPosters.posterFolder + "/") {
                guard let url = folders.url(for: location) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
            if let tiles = tilesFolder, !ids.isEmpty {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: tiles.path)) ?? []
                where ids.contains(where: { MediaPosters.belongs(name, to: $0) }) {
                    try? FileManager.default.removeItem(at: tiles.appendingPathComponent(name))
                }
            }
        }
    }

    /// Whether anything waits for the control thread to take it.
    public var hasReports: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reports.isEmpty
    }

    /// Everything reported since the last call, in order.
    public func takeReports() -> [Report] {
        lock.lock()
        defer { lock.unlock() }
        let out = reports
        reports.removeAll()
        return out
    }

    /// Wait until the worker has done everything asked so far, and what that
    /// work asked for in turn (an import in place asks for a walk).
    public func waitUntilIdle() {
        while true {
            let before = submitted
            urgent.sync {}
            queue.sync {}
            if submitted == before { return }
        }
    }

    /// Everything the worker does goes through here, one piece at a time.
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        submissions += 1
        lock.unlock()
        queue.async(execute: work)
    }

    private func enqueueUrgent(_ work: @escaping @Sendable () -> Void) {
        lock.lock()
        submissions += 1
        lock.unlock()
        urgent.async(execute: work)
    }

    private var submitted: Int {
        lock.lock()
        defer { lock.unlock() }
        return submissions
    }

    private func report(_ report: Report) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    private func waitWhileBlocked() {
        var waited = 0
        while seams.blocked(), waited < 200 {
            Thread.sleep(forTimeInterval: 0.05)
            waited += 1
        }
    }

    // MARK: - The walk (Spec 8 §4)

    private func walk() {
        let snap = current()
        forgetApplied(snap)
        let now = seams.now().timeIntervalSince1970
        var stats: [MediaLocation: (stat: MediaFileStat, modified: Double)] = [:]
        var walked: Set<MediaFolder> = []
        for folder in [MediaFolder.mediaRoot, .machineMedia] {
            guard let root = folders.folder(folder) else { continue }
            walked.insert(folder)
            list(root, folder, into: &stats)
        }
        // Spec 8 §2 — the files overrides point at: skipped as entries, read for their entry's presence.
        var targets: Set<MediaLocation> = []
        for value in snap.machine.overrides.values {
            guard let target = MediaLocation.override(value) else { continue }
            targets.insert(target)
            if target.folder == .absolute, let url = folders.url(for: target) {
                walked.insert(.absolute)
                if let found = LocalFiles.mediaStatTime(url) { stats[target] = found }
            }
        }
        var posters: Set<MediaLocation> = []
        for folder in [MediaFolder.mediaRoot, .machineMedia] where walked.contains(folder) {
            posters.formUnion(posterFiles(in: folder))
        }
        report(.listed(MediaListing(folders: walked, files: stats.mapValues(\.stat), overrideTargets: targets, posters: posters)))
        report(.event(["op": .string("walk"), "state": .string("started"), "files": .number(Double(stats.count))]))

        var found: [MediaLocation: MediaFound] = [:]
        let holders = snap.holders()
        var settles: Double?
        let locations = stats.keys.sorted()
        var lastProgress = Date.distantPast
        for (index, location) in locations.enumerated() {
            guard let (stat, modified) = stats[location], let url = folders.url(for: location) else { continue }
            waitWhileBlocked()
            if now - modified < Self.settle {
                found[location] = .pending
                settles = min(settles ?? .infinity, modified + Self.settle)
                continue
            }
            if let result = identify(location, url: url, stat: stat, snap: snap, holders: holders) {
                found[location] = result
            }
            if Date().timeIntervalSince(lastProgress) > 0.5 {
                lastProgress = Date()
                report(.event(["op": .string("walk"), "state": .string("hashing"),
                               "progress": .number(Double(index + 1) / Double(max(1, locations.count)))]))
            }
        }
        report(.walked(MediaFindings(folders: walked, found: found, overrideTargets: targets)))
        report(.event(["op": .string("walk"), "state": .string("done")]))
        // Spec 8 §4 — a file still being written is read by a later walk, once it has held for two seconds.
        if let settles, let schedule = seams.schedule {
            lock.lock()
            let already = walkScheduled
            walkScheduled = true
            lock.unlock()
            if !already {
                schedule(max(0.1, settles - now + 0.05)) { [self] in
                    lock.lock()
                    walkScheduled = false
                    lock.unlock()
                    requestWalk()
                }
            }
        }
    }

    /// Spec 8 §4 — "What it skips: hidden files and folders (names starting
    /// with a dot, so `.posters/`), a sync tool's temporary files (Spec 1 §5),
    /// `fonts/` (Spec 1 §7)", and symbolic links, which it doesn't follow.
    private func list(_ root: URL, _ folder: MediaFolder, into stats: inout [MediaLocation: (stat: MediaFileStat, modified: Double)]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        let base = root.standardizedFileURL.path + "/"
        for case let item as URL in walker {
            let full = item.standardizedFileURL.path
            guard full.hasPrefix(base) else { continue }
            let relative = String(full.dropFirst(base.count))
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { continue }
            if values?.isDirectory == true {
                if FileLayout.isIgnored(path: relative) || (folder == .mediaRoot && relative == "fonts") { walker.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, !FileLayout.isIgnored(path: relative),
                  let location = MediaLocation(folder, relative), let stat = LocalFiles.mediaStatTime(item) else { continue }
            stats[location] = stat
        }
    }

    /// Spec 8 §2 — "The hash is known from this machine's cache record for
    /// that location when the file's size and modification date match it,
    /// otherwise from the entry's own size and date when they match,
    /// otherwise by hashing the file"; and the file is read when no index
    /// holds its id or its entry lacks metadata. Nil when it can't be read.
    private func identify(_ location: MediaLocation, url: URL, stat: MediaFileStat, snap: Snapshot,
                          holders: [MediaLocation: MediaEntry]) -> MediaFound? {
        var known = memo[location].flatMap { $0.stat == stat ? $0 : nil }
        if known?.notYet == true { return .pending }
        var id = known?.id
        if id == nil { id = snap.cache.hash(at: location, size: stat.size, modified: stat.modified) }
        if id == nil, let entry = holders[location], entry.size == stat.size, entry.modified == stat.modified { id = entry.id }
        if id == nil {
            countHash()
            guard let hashed = MediaHashing.identity(of: url) else {
                // A slide that doesn't parse yet, or a file that can't be read now: left for a later walk.
                memo[location] = Memo(stat: stat, notYet: true)
                return .pending
            }
            guard LocalFiles.mediaStat(url) == stat else { return .pending }
            id = hashed
        }
        guard let id else { return nil }
        var read = known?.read
        let entry = snap.entry(id)
        let wantsRead = (entry == nil && !reportedIDs.contains(id)) || entry.map(Self.lacksMetadata) == true
        if wantsRead, read == nil {
            guard let probed = seams.probe.read(url) else {
                // "a file that doesn't open yet as a kind v1 takes ... is left for a later walk".
                memo[location] = Memo(stat: stat, id: id, notYet: true)
                return .pending
            }
            read = probed
        }
        known = Memo(stat: stat, id: id, read: read)
        memo[location] = known
        return .file(MediaFoundFile(id: id, size: stat.size, modified: stat.modified, read: wantsRead ? read : nil))
    }

    static func lacksMetadata(_ e: MediaEntry) -> Bool {
        switch e.kind {
        case .video: return e.durationMs == nil || e.width == nil || e.height == nil || e.codec == nil
        case .image: return e.width == nil || e.height == nil
        case .audio: return e.durationMs == nil
        case .audioSet, .slide, .template: return false
        }
    }

    /// What the snapshot now holds no longer needs remembering here.
    private func forgetApplied(_ snap: Snapshot) {
        reportedIDs = reportedIDs.filter { snap.entry($0) == nil }
        claimed = claimed.filter { snap.entry(at: $0) == nil }
    }

    // MARK: - Import (Spec 8 §3)

    /// Spec 8 §3 — `media import "PATH"`: a file or a folder. "A dropped
    /// folder imports its files recursively and keeps its subfolders under
    /// the import folder ... Hidden files and folders are skipped, and a file
    /// v1 doesn't take is refused without stopping the rest." A PATH already
    /// in the media root or `machine/media/` is "Indexed where it is", by the
    /// walk it asks for.
    private func runImport(job: String, path: String) {
        let source = URL(fileURLWithPath: path).standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isFolder) else {
            report(.decided(job: job, file: source.lastPathComponent, .refused(.changed, nil)))
            return
        }
        var files: [(url: URL, name: String, subfolder: String)] = []
        if isFolder.boolValue {
            let parent = source.deletingLastPathComponent().path + "/"
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
            if let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                for case let item as URL in walker {
                    let values = try? item.resourceValues(forKeys: Set(keys))
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                    let full = item.standardizedFileURL.path
                    let relative = full.hasPrefix(parent) ? String(full.dropFirst(parent.count)) : item.lastPathComponent
                    let subfolder = (relative as NSString).deletingLastPathComponent
                    files.append((item.standardizedFileURL, relative, subfolder))
                }
            }
            files.sort { $0.name < $1.name }
        } else {
            files = [(source, source.lastPathComponent, "")]
        }
        var inPlace = false
        for file in files {
            if let location = location(of: file.url) {
                report(.inPlace(job: job, file: file.name, location))
                inPlace = true
            } else {
                importFile(job: job, file: file.name, url: file.url, subfolder: file.subfolder)
            }
        }
        if isFolder.boolValue, isStaged(source) { removeEmptyFolders(source) }
        if inPlace { requestWalk() }
    }

    /// The location of a file already in the media root or `machine/media/`.
    func location(of url: URL) -> MediaLocation? {
        let path = DiskWatcher.realPath(url)
        for folder in [MediaFolder.mediaRoot, .machineMedia] {
            guard let root = folders.folder(folder) else { continue }
            let base = DiskWatcher.realPath(root) + "/"
            if path.hasPrefix(base) { return MediaLocation(folder, String(path.dropFirst(base.count))) }
        }
        return nil
    }

    func isStaged(_ url: URL) -> Bool {
        guard let staging else { return false }
        return DiskWatcher.realPath(url).hasPrefix(DiskWatcher.realPath(staging) + "/")
    }

    private func event(_ job: String, _ file: String, _ state: String, progress: Double? = nil) {
        var fields: [String: JSONValue] = ["job": .string(job), "op": .string("import"), "file": .string(file), "state": .string(state)]
        if let progress { fields["progress"] = .number((progress * 100).rounded() / 100) }
        report(.event(fields))
    }

    /// One file from outside both folders: "Staged ... Hash first ... The
    /// kind ... Copy ... Index" (Spec 8 §3).
    private func importFile(job: String, file: String, url: URL, subfolder: String) {
        let staged = isStaged(url)
        func done(_ outcome: MediaImportOutcome) {
            report(.decided(job: job, file: file, outcome))
            // "removes a staged file once its import is done".
            if staged { try? FileManager.default.removeItem(at: url) }
        }
        // 2. Hash first.
        event(job, file, "hashing", progress: 0)
        guard let before = LocalFiles.mediaStat(url) else { return done(.refused(.changed, nil)) }
        var last = Date()
        countHash()
        let identity = MediaHashing.identity(of: url) { share in
            if Date().timeIntervalSince(last) > 0.25 {
                last = Date()
                self.event(job, file, "hashing", progress: share)
            }
        }
        guard let id = identity, LocalFiles.mediaStat(url) == before else { return done(.refused(.changed, nil)) }
        let snap = current()
        forgetApplied(snap)
        if reportedIDs.contains(id) { return done(.known(id)) }
        let decision = MediaImport.decide(id: id, libraryWritable: snap.libraryWritable, library: snap.library, machine: snap.machine,
                                          presence: { snap.missing.contains($0) ? .missing : .ok })
        let folder: MediaFolder, tier: MediaTier, back: String?
        switch decision {
        case .known(let resolved): return done(.known(resolved))
        case .refused(let reason): return done(.refused(reason, nil))
        case .copy(let into, let t, let b): (folder, tier, back) = (into, t, b)
        }
        // 3. The kind, for a new item: "found by opening the file".
        var metadata: MediaMetadata?
        if back == nil {
            switch seams.probe.read(url) {
            case .media(let m)?: metadata = m
            case .unsupported(let format)?: return done(.refused(.unsupported, format))
            case nil: return done(.refused(.unsupported, "a file that doesn't open as a kind v1 takes"))
            }
        }
        // 4. Copy, under a name no file and no entry holds.
        guard let root = folders.folder(folder) else {
            log.warning("media import of \(file): the \(folder.rawValue) folder isn't read here, so nothing can be imported into it")
            return done(.refused(.readOnlyLibrary, nil))
        }
        let directory = [snap.importFolder, subfolder].filter { !$0.isEmpty }.joined(separator: "/")
        var taken = Set(names(in: root, directory: MediaLocation(folder, directory) != nil ? directory : ""))
        let index = folder == .mediaRoot ? snap.library.entries.map(\.path) : snap.machine.entries.map(\.path)
        taken.formUnion(index.filter { !$0.isEmpty })
        taken.formUnion(claimed.filter { $0.folder == folder }.map(\.path))
        guard var destination = MediaImport.destination(name: url.lastPathComponent, subfolder: subfolder, importFolder: snap.importFolder,
                                                        folder: folder, taken: taken),
              var target = folders.url(for: destination) else { return done(.refused(.changed, nil)) }
        let sameVolume = staged && Self.volume(url) == Self.volume(root)
        if !sameVolume, let free = seams.freeBytes(root), free - Int64(before.size) < Self.reserve {
            return done(.refused(.diskFull, nil))
        }
        seams.beforeCopy?(url)
        event(job, file, "copying", progress: 0)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            log.error("media import of \(file): \(error)")
            return done(.refused(.changed, nil))
        }
        // "The copy is written under a hidden name and renamed when complete, so the walk never reads half of it".
        let hidden = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".importing-" + job)
        var moved = false
        if sameVolume, case .moved = LocalFiles.moveMedia(url, to: hidden) {
            moved = LocalFiles.mediaStat(hidden) == before
            if !moved {
                _ = LocalFiles.moveMedia(hidden, to: url)
                return done(.refused(.changed, nil))
            }
        }
        if !moved {
            switch copy(url, to: hidden, job: job, file: file) {
            case .some(let copiedID) where copiedID == id:
                break
            default:
                // "a file that changes while it's imported is refused with `changed`".
                try? FileManager.default.removeItem(at: hidden)
                return done(.refused(.changed, nil))
            }
        }
        var attempts = 0
        while true {
            switch LocalFiles.moveMedia(hidden, to: target) {
            case .moved:
                break
            case .taken where attempts < 50:
                attempts += 1
                taken.insert(destination.path)
                guard let next = MediaImport.destination(name: url.lastPathComponent, subfolder: subfolder, importFolder: snap.importFolder,
                                                         folder: folder, taken: taken), let nextURL = folders.url(for: next) else { break }
                destination = next
                target = nextURL
                continue
            default:
                // A moved staged file goes back where it was; a copy of ours is removed.
                if moved { _ = LocalFiles.moveMedia(hidden, to: url) } else { try? FileManager.default.removeItem(at: hidden) }
                return done(.refused(.changed, nil))
            }
            break
        }
        // 5. Index: the metadata read, the poster extracted, the entry made on the control thread.
        event(job, file, "reading")
        guard let stat = LocalFiles.mediaStat(target) else { return done(.refused(.changed, nil)) }
        var poster: String?
        if metadata?.kind == .video, let path = MediaPosters.posterPath(id: id, inMs: 0), let location = MediaLocation(folder, path) {
            // Spec 8 §5 — "At import": a new item's in-point is 0, its defaults being empty.
            event(job, file, "poster")
            if writePoster(of: destination, at: location, inMs: 0, alpha: metadata?.hasAlpha ?? false) {
                poster = path
            } else {
                failedPosters[location] = (destination, stat)
                log.warning("media import of \(file): no poster, its first frame couldn't be extracted")
            }
        }
        reportedIDs.insert(id)
        claimed.insert(destination)
        memo[destination] = Memo(stat: stat, id: id, read: metadata.map(MediaRead.media))
        report(.copied(job: job, file: file, MediaImport.Copied(location: destination,
                                                                 file: MediaFoundFile(id: id, size: stat.size, modified: stat.modified,
                                                                                      read: metadata.map(MediaRead.media)),
                                                                 metadata: metadata, tier: tier, bringsBack: back, poster: poster)))
        if staged, !moved { try? FileManager.default.removeItem(at: url) }
    }

    /// Spec 8 §3 — the copy, hashed as it is written, so it "is checked
    /// against the hash"; the id of what was written, or nil.
    private func copy(_ from: URL, to: URL, job: String, file: String) -> String? {
        guard let input = try? FileHandle(forReadingFrom: from) else { return nil }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: to.path, contents: nil), let output = try? FileHandle(forWritingTo: to) else { return nil }
        defer { try? output.close() }
        let total = Double(LocalFiles.mediaStat(from)?.size ?? 0)
        var running = MediaHashing.Running()
        var written = 0.0
        var last = Date()
        do {
            while let piece = try input.read(upToCount: MediaHashing.chunk), !piece.isEmpty {
                waitWhileBlocked()
                try output.write(contentsOf: piece)
                running.update(piece)
                written += Double(piece.count)
                if total > 0, Date().timeIntervalSince(last) > 0.25 {
                    last = Date()
                    event(job, file, "copying", progress: min(1, written / total))
                }
            }
            try output.synchronize()
        } catch {
            return nil
        }
        return running.finish()
    }

    /// The names in the folder a copy goes into, as paths relative to the
    /// media folder, hidden ones included, for numbered names: "A name that a
    /// file holds".
    private func names(in root: URL, directory: String) -> [String] {
        let folder = directory.isEmpty ? root : root.appendingPathComponent(directory)
        let prefix = directory.isEmpty ? "" : directory + "/"
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).map { prefix + $0 }
    }

    private func removeEmptyFolders(_ folder: URL) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { removeEmptyFolders(item) }
        let rest = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        if rest.allSatisfy({ $0 == ".DS_Store" }) { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Posters and tiles (Spec 8 §5)

    /// Spec 1 §5 — "thumbnails/ ...; pool tiles in pool/ (Spec 8 §5)", in the machine root.
    var tilesFolder: URL? {
        machineRoot?.appendingPathComponent(MediaPosters.tileFolder, isDirectory: true)
    }

    /// The poster files in a folder's `.posters/`.
    func posterFiles(in folder: MediaFolder) -> Set<MediaLocation> {
        guard let root = folders.folder(folder), folder != .absolute else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(MediaPosters.posterFolder).path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") && $0.hasSuffix(".png") }
            .compactMap { MediaLocation(folder, MediaPosters.posterFolder + "/" + $0) })
    }

    private func exists(_ location: MediaLocation) -> Bool {
        folders.url(for: location).map { LocalFiles.mediaStat($0) != nil } ?? false
    }

    /// Spec 8 §5 — "The walk extracts missing posters", and "Tiles are a
    /// machine cache, never synced, and made again when missing": every
    /// poster the indexes this machine writes lack, then every tile missing,
    /// from the indexes and file states the control thread last adopted.
    private func posterPass() {
        let snap = current()
        var failed: Set<MediaLocation> = []
        for (poster, recorded) in failedPosters {
            let now = folders.url(for: recorded.source).flatMap(LocalFiles.mediaStat)
            if now == recorded.stat { failed.insert(poster) } else { failedPosters[poster] = nil }
        }
        let tasks = MediaPosters.posters(library: snap.library, machine: snap.machine, libraryWritable: snap.libraryWritable,
                                         state: { snap.files[$0] ?? .absent }, posterExists: exists, failed: failed)
        var made: [MediaPosters.Made] = []
        var removed: [MediaLocation] = []
        for task in tasks {
            waitWhileBlocked()
            if task.extract, !writePoster(of: task.source, at: task.poster, inMs: task.inMs, alpha: task.alpha) {
                failedPosters[task.poster] = (task.source, folders.url(for: task.source).flatMap(LocalFiles.mediaStat))
                log.warning("media: no poster for \(task.id): its frame at \(task.inMs) ms couldn't be extracted from \(task.source.folder.rawValue) \(task.source.path)")
                made.append(MediaPosters.Made(id: task.id, tier: task.tier, inMs: task.inMs, path: nil))
                continue
            }
            made.append(MediaPosters.Made(id: task.id, tier: task.tier, inMs: task.inMs, path: task.poster.path))
            removed += removeOldPosters(of: task.id, keeping: task.poster)
        }
        if !made.isEmpty { report(.posters(made: made, removed: removed)) }
        makeTiles(snap)
    }

    /// Spec 8 §5 — the frame at the in-point, "a PNG fitted within 1920 ×
    /// 1080, with alpha when the video has it", at `.posters/<hex>-<in>.png`.
    private func writePoster(of source: MediaLocation, at poster: MediaLocation, inMs: Int, alpha: Bool) -> Bool {
        guard let url = folders.url(for: source), let target = folders.url(for: poster),
              let frame = seams.frames.frame(of: url, atMs: inMs, alpha: alpha),
              let fitted = MediaImages.fitted(frame.image) else { return false }
        return MediaImages.writePNG(fitted, to: target)
    }

    /// Spec 8 §5 — "The old file goes once the new one is written": the
    /// other posters of the same id beside it.
    private func removeOldPosters(of id: String, keeping poster: MediaLocation) -> [MediaLocation] {
        var removed: [MediaLocation] = []
        for other in posterFiles(in: poster.folder) where other != poster && MediaPosters.belongs(other.name, to: id) {
            guard let url = folders.url(for: other) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil { removed.append(other) }
        }
        return removed
    }

    /// Spec 8 §5 — "Pool tiles (M3) are 480 px wide PNGs at
    /// `machine/thumbnails/pool/<hex>-<in>.png` ..., made from the poster for
    /// video and from the image for an image"; a new tile replaces the
    /// item's old ones.
    private func makeTiles(_ snap: Snapshot) {
        guard let folder = tilesFolder else { return }
        var names = Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") })
        let tasks = MediaPosters.tiles(library: snap.library, machine: snap.machine, state: { snap.files[$0] ?? .absent },
                                       posterExists: exists, tileExists: { names.contains($0) })
        var drew = false
        for task in tasks {
            waitWhileBlocked()
            let stat = folders.url(for: task.source).flatMap(LocalFiles.mediaStat)
            if let failed = failedTiles[task.name], failed == stat { continue }
            guard let source = folders.url(for: task.source), let tile = MediaImages.tile(from: source),
                  MediaImages.writePNG(tile, to: folder.appendingPathComponent(task.name)) else {
                failedTiles[task.name] = stat
                log.warning("media: no pool tile for \(task.id): \(task.source.folder.rawValue) \(task.source.path) couldn't be drawn")
                continue
            }
            failedTiles[task.name] = nil
            names.insert(task.name)
            drew = true
            for other in names where other != task.name && MediaPosters.belongs(other, to: task.id) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(other))
                names.remove(other)
            }
        }
        if drew || !tilesReported {
            tilesReported = true
            report(.tiles(names))
        }
    }

    // MARK: - The Trash (Spec 8 §6)

    /// Spec 8 §6 — a park's moves, on the urgent queue: every file of each
    /// delete to the Trash, every file of each undelete back where it came
    /// from. "If one move fails, the files already moved go back"; "Any
    /// failure puts every moved file back and rejects the group".
    public func moveFiles(park: Int, moves: [MediaMove]) {
        enqueueUrgent { [self] in
            var done: [String: [MediaTrashedFile]] = [:]
            var failure: Rejection?
            for move in moves where failure == nil {
                switch move.kind {
                case .trash(let locations):
                    done[move.id] = []
                    for location in locations where failure == nil {
                        guard let url = folders.url(for: location), LocalFiles.mediaStat(url) != nil else { continue }
                        switch seams.trash.trash(url) {
                        case .success(let trashed):
                            done[move.id, default: []].append(MediaTrashedFile(location: location, trash: trashed.path))
                        case .failure(.noTrash):
                            failure = Rejection(reason: .noTrash, message: "\(location.folder.rawValue) \(location.path) is on a volume with no Trash")
                        case .failure(let other):
                            failure = Rejection(reason: .conflict, message: "\(location.folder.rawValue) \(location.path) couldn't move to the Trash: \(other)")
                        }
                    }
                case .restore(let files):
                    done[move.id] = []
                    for file in files where failure == nil {
                        switch restore(file, of: move.id) {
                        case .success(let back):
                            done[move.id, default: []].append(back)
                            if !holds(move, at: back.location) {
                                failure = Rejection(reason: .conflict, message: "the file put back at \(back.location.path) isn't \(move.id)")
                            }
                        case .failure(let rejection):
                            failure = rejection
                        }
                    }
                }
            }
            if let failure {
                undoNow(done, moves: moves)
                log.warning("media: files moved back: \(failure.message)")
                report(.moved(park: park, .failure(failure)))
            } else {
                report(.moved(park: park, .success(done)))
            }
        }
    }

    /// Spec 8 §6 — a park the control thread didn't apply (its second check
    /// failed, or it gave up waiting): every file goes back where it was.
    public func undoMoves(_ done: [String: [MediaTrashedFile]], moves: [MediaMove], park: Int) {
        enqueueUrgent { [self] in
            undoNow(done, moves: moves)
            report(.undone(park: park))
        }
    }

    private func undoNow(_ done: [String: [MediaTrashedFile]], moves: [MediaMove]) {
        for move in moves {
            for file in done[move.id] ?? [] {
                switch move.kind {
                case .trash:
                    // Out of the Trash, to its place or a numbered name beside it.
                    if case .failure(let why) = restore(file, of: move.id) { log.error("media: \(file.trash) couldn't go back: \(why.message)") }
                case .restore:
                    // Back into the Trash, where the delete's record says it is.
                    guard let url = folders.url(for: file.location) else { continue }
                    if case .failed(let why) = LocalFiles.moveMedia(url, to: URL(fileURLWithPath: file.trash)) {
                        log.error("media: \(file.location.path) couldn't go back to the Trash: \(why)")
                    }
                }
            }
        }
    }

    /// Spec 8 §6 — one file out of the Trash: "It never overwrites a file now
    /// at one of those paths, giving the restored one a numbered name
    /// instead, as an import does (§3) ... if the Trash has been emptied, the
    /// undo fails with `conflict`". Where it went, and where it came from.
    /// The item's own entry doesn't count as holding its path: a delete
    /// refused after its files moved leaves the entry where it was.
    private func restore(_ file: MediaTrashedFile, of id: String) -> Result<MediaTrashedFile, Rejection> {
        var target = file.location
        let trashed = URL(fileURLWithPath: file.trash)
        for _ in 0..<50 {
            guard let url = folders.url(for: target) else {
                return .failure(Rejection(reason: .conflict, message: "\(target.path) isn't where media may live now"))
            }
            if LocalFiles.mediaStat(url) != nil || named(target, except: id) {
                guard let next = numbered(target, except: id) else { break }
                target = next
                continue
            }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch seams.trash.putBack(trashed, to: url) {
            case .success:
                return .success(MediaTrashedFile(location: target, trash: file.trash))
            case .failure(.taken):
                continue
            case .failure(.gone):
                return .failure(Rejection(reason: .conflict, message: "the Trash no longer holds \(file.trash): it has been emptied"))
            case .failure(let other):
                return .failure(Rejection(reason: .conflict, message: "\(file.trash) couldn't come back: \(other)"))
            }
        }
        return .failure(Rejection(reason: .conflict, message: "no free name for \(file.location.path)"))
    }

    /// The paths the entries of a location's folder hold, but one item's.
    private func entryPaths(in folder: MediaFolder, except id: String) -> [String] {
        let snap = current()
        let entries = folder == .mediaRoot ? snap.library.entries : folder == .machineMedia ? snap.machine.entries : []
        return entries.filter { $0.id != id && !$0.path.isEmpty }.map(\.path)
    }

    /// Whether another entry's path holds a location ("or that another entry's path holds").
    private func named(_ location: MediaLocation, except id: String) -> Bool {
        entryPaths(in: location.folder, except: id).contains { $0.lowercased() == location.path.lowercased() }
    }

    /// The next numbered name beside a location, as the Finder names copies.
    private func numbered(_ location: MediaLocation, except id: String) -> MediaLocation? {
        guard let url = folders.url(for: location) else { return nil }
        let directory = url.deletingLastPathComponent()
        let parent = location.parent
        let prefix = parent.isEmpty ? "" : (location.folder == .absolute && parent == "/" ? "/" : parent + "/")
        var taken = Set(((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).map { prefix + $0 })
        taken.insert(location.path)
        taken.formUnion(entryPaths(in: location.folder, except: id))
        return MediaImport.destination(name: location.name, importFolder: parent, folder: location.folder, taken: taken)
    }

    /// Spec 8 §6 — "checks each file against the id": by the entry's own
    /// size and date when they match (Spec 8 §2), else by hashing it.
    private func holds(_ move: MediaMove, at location: MediaLocation) -> Bool {
        guard let url = folders.url(for: location), let stat = LocalFiles.mediaStat(url) else { return false }
        if stat.size == move.size, stat.modified == move.modified { return true }
        countHash()
        return MediaHashing.identity(of: url) == move.id
    }

    // MARK: - Volumes

    /// The volume a path is on (its device), from its nearest existing folder.
    static func volume(_ url: URL) -> UInt64? {
        var current = url.standardizedFileURL
        var info = stat()
        while stat(current.path, &info) != 0 {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return UInt64(info.st_dev)
    }

    /// The free bytes of the volume a folder is on, as macOS reports them for important use.
    public static func freeBytes(_ url: URL) -> Int64? {
        var current = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        let values = try? current.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

extension MediaPlaces {
    /// Spec 8 §2, choice M-8 — this Mac's places: the user's home, and the
    /// startup volume, which on macOS is two volumes in one group: the system
    /// volume at `/` and the data volume at `/System/Volumes/Data` that
    /// `/Users` and the rest of the writable folders are on.
    public static func thisMac(home: String = NSHomeDirectory()) -> MediaPlaces {
        MediaPlaces(home: home, isOnStartupVolume: { path in
            guard let device = MediaWorker.volume(URL(fileURLWithPath: path)) else { return false }
            return [MediaWorker.volume(URL(fileURLWithPath: "/")), MediaWorker.volume(URL(fileURLWithPath: "/System/Volumes/Data"))]
                .compactMap { $0 }.contains(device)
        })
    }
}
