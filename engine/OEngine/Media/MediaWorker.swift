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

        public init(now: @escaping @Sendable () -> Date = { Date() },
                    schedule: (@Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void)? = nil,
                    probe: any MediaProbe = AVMediaProbe(),
                    freeBytes: @escaping @Sendable (URL) -> Int64? = MediaWorker.freeBytes,
                    blocked: @escaping @Sendable () -> Bool = { false },
                    beforeCopy: (@Sendable (URL) -> Void)? = nil) {
            self.now = now
            self.schedule = schedule
            self.probe = probe
            self.freeBytes = freeBytes
            self.blocked = blocked
            self.beforeCopy = beforeCopy
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

        public init(library: MediaIndex = MediaIndex(), machine: MediaLocalIndex = MediaLocalIndex(), libraryWritable: Bool = false,
                    importFolder: String = "imports", cache: MediaCache = MediaCache(), missing: Set<String> = []) {
            self.library = library
            self.machine = machine
            self.libraryWritable = libraryWritable
            self.importFolder = importFolder
            self.cache = cache
            self.missing = missing
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
    private let lock = NSLock()
    private var snapshot = Snapshot()
    private var reports: [Report] = []
    private var walkQueued = false
    private var walkScheduled = false
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

    /// Spec 8 §4 — the posters of the entries the launch pruned. Only files
    /// in a `.posters/` folder are ever removed.
    public func removePosters(_ locations: [MediaLocation]) {
        enqueue { [self] in
            for location in locations where location.path.hasPrefix(".posters/") {
                guard let url = folders.url(for: location) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
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
        report(.listed(MediaListing(folders: walked, files: stats.mapValues(\.stat), overrideTargets: targets)))
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
        // 5. Index: the metadata read, the entry made on the control thread.
        event(job, file, "reading")
        guard let stat = LocalFiles.mediaStat(target) else { return done(.refused(.changed, nil)) }
        reportedIDs.insert(id)
        claimed.insert(destination)
        memo[destination] = Memo(stat: stat, id: id, read: metadata.map(MediaRead.media))
        report(.copied(job: job, file: file, MediaImport.Copied(location: destination,
                                                                 file: MediaFoundFile(id: id, size: stat.size, modified: stat.modified,
                                                                                      read: metadata.map(MediaRead.media)),
                                                                 metadata: metadata, tier: tier, bringsBack: back)))
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
