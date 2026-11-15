// OEngine — Spec 9 §3 and §6, the worker that writes snapshots and reads what a restore needs.

import Foundation
import OCore

/// Spec 9 §3 — "The engine copies the documents on the control thread, so a
/// snapshot is one consistent moment, then writes the zip on a worker at
/// background priority, under a hidden name renamed when complete (Spec 1
/// §5)." Spec 9 §6 — "the reading, checking and writing happen on a worker":
/// a kept version's file, a snapshot's zip, and the snapshot taken before a
/// restore replaces anything.
///
/// One serial queue at background priority. The control thread hands it
/// values (the roots are Swift values, so the copy is the moment) and reads
/// its reports at the next build; nothing here runs on the control or render
/// threads. Every write goes through the disk seam (§8).
public final class SnapshotWorker: @unchecked Sendable {
    /// Spec 9 §7 — "When free space on the machine root's volume falls under
    /// 1 GB (Spec 8 §3's line), automatic snapshots ... pause".
    public static let lowDiskBytes: Int64 = 1 << 30

    /// One snapshot to take: the roots as they were when it was asked for.
    public struct Take: Sendable {
        public var token: Int
        public var reason: SnapshotManifest.Reason
        /// The id it takes when no other has it: the local date and time to the second.
        public var stamp: String
        public var takenAt: String
        public var date: Date
        public var library: Library
        public var machine: Machine
        public var run: UUID
        public var seq: Int
    }

    public enum Report: Sendable {
        /// Written, complete, under `id`.
        case taken(token: Int, reason: SnapshotManifest.Reason, id: String, bytes: Int)
        /// Spec 9 §3 — an automatic snapshot "whose documents equal the newest snapshot's isn't written".
        case unchanged(token: Int, reason: SnapshotManifest.Reason, newest: String)
        /// Spec 9 §7 — an automatic snapshot not taken while the disk is low.
        case paused(token: Int, reason: SnapshotManifest.Reason)
        case failed(token: Int, reason: SnapshotManifest.Reason, failure: Disk.Failure)
        /// Spec 9 §6 — what was read for a parked restore, by what was asked.
        case read(park: Int, [RestoreKey: Result<RestoreMaterial, Rejection>])
    }

    public let folder: URL
    public let libraryRoot: URL
    public let disk: Disk
    /// Spec 9 §7 — what every writer knows of the disk.
    public let status: DiskStatus?
    private let timeZone: TimeZone
    /// Spec 9 §7 — what the retention pass needs from outside the folder:
    /// today's date in the machine's time zone, and the snapshots an undo or
    /// redo step names. Set once, before the first snapshot.
    public var retention: (today: @Sendable () -> String, named: @Sendable () -> Set<String>)?
    private let queue = DispatchQueue(label: "o.engine.snapshots", qos: .background)
    private let lock = NSLock()
    private var reports: [Report] = []
    private var removed: [String] = []
    /// The queue's own: the newest snapshot it wrote or read, so the
    /// ten-minute check doesn't read a zip each time.
    private var newest: Snapshot?
    /// Called on the queue after each snapshot is written (Spec 9 §7: "The
    /// retention pass runs ... after each snapshot").
    public var afterSnapshot: (@Sendable () -> Void)?
    /// A seam for tests: called on the queue before a restore's files are
    /// read, so a test can hold the worker there and look at what waits.
    public var beforeRead: (@Sendable () -> Void)?

    /// `folder` is `machine/snapshots/`; `libraryRoot` holds `versions/`.
    public init(folder: URL, libraryRoot: URL, disk: Disk = .live, status: DiskStatus? = nil, timeZone: TimeZone) {
        self.folder = folder
        self.libraryRoot = libraryRoot
        self.disk = disk
        self.status = status
        self.timeZone = timeZone
    }

    /// Spec 9 §7 — "The retention pass runs at launch, after each snapshot":
    /// every snapshot §7's rule no longer keeps is removed, oldest first,
    /// but one "an undo or redo step names", which "is kept until the run
    /// ends". After everything asked so far.
    public func retain() {
        queue.async { [self] in removeExpired() }
    }

    /// The ids the pass removed since this was last asked, for the engine log.
    public func takeRemoved() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let out = removed
        removed.removeAll()
        return out
    }

    private func removeExpired() {
        guard let retention else { return }
        let expired = Retention.snapshotsToRemove(ids(), today: retention.today(), named: retention.named())
        guard !expired.isEmpty else { return }
        for id in expired {
            try? disk.remove(url(id))
            if newest?.manifest.id == id { newest = nil }
        }
        lock.lock()
        removed += expired
        lock.unlock()
    }

    // MARK: - The control thread's side

    /// Spec 9 §3 — take one snapshot, after everything asked so far.
    public func take(_ request: Take) {
        queue.async { [self] in report(write(request)) }
    }

    /// Spec 9 §6 — read what a parked restore needs. For a snapshot, "Before
    /// it replaces anything, the engine takes a snapshot with reason
    /// `restore`": `before` is that one, written once the zip has been read
    /// and before the answer goes back.
    public func read(park: Int, _ keys: [RestoreKey], before: Take?) {
        queue.async { [self] in
            beforeRead?()
            var results: [RestoreKey: Result<RestoreMaterial, Rejection>] = [:]
            for key in keys {
                switch key {
                case .version(let list, let version): results[key] = readVersion(list: list, version: version)
                case .snapshot(let id): results[key] = readSnapshot(id, before: before)
                }
            }
            report(.read(park: park, results))
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

    public var hasReports: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reports.isEmpty
    }

    /// Wait until the queue has done everything asked so far.
    public func waitUntilIdle() {
        queue.sync {}
    }

    private func report(_ report: Report) {
        lock.lock()
        reports.append(report)
        lock.unlock()
    }

    // MARK: - Writing (on the queue)

    /// The ids of the snapshots in the folder: every `<id>.zip` with a
    /// visible name. A half-written one has a hidden name and isn't one yet.
    public func ids() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return SnapshotID.sorted(names.filter { $0.hasSuffix(".zip") && !$0.hasPrefix(".") }.map { String($0.dropLast(4)) })
    }

    func url(_ id: String) -> URL {
        folder.appendingPathComponent(id + ".zip")
    }

    private func write(_ request: Take) -> Report {
        let reason = request.reason
        if reason.isAutomatic {
            // Spec 9 §7 — "automatic snapshots ... pause" on a low disk; on a full one "Snapshots aren't written".
            if status?.full == true { return .paused(token: request.token, reason: reason) }
            if let free = disk.freeBytes(at: folder.deletingLastPathComponent()), free < Self.lowDiskBytes {
                return .paused(token: request.token, reason: reason)
            }
        }
        let taken = ids()
        let id = SnapshotID.free(request.stamp, taken: Set(taken))
        let snapshot = Snapshot.taking(id: id, takenAt: request.takenAt, reason: reason, library: request.library, machine: request.machine,
                                       run: request.run, seq: request.seq)
        if reason.isAutomatic, let last = taken.last, let held = newestSnapshot(last), snapshot.holdsTheSame(as: held) {
            return .unchanged(token: request.token, reason: reason, newest: last)
        }
        do {
            let data = try Zip.archive(snapshot.files.map { Zip.Entry(path: $0.path, data: $0.data) }, modified: request.date, timeZone: timeZone)
            // Spec 1 §5 — a temporary file with a hidden name in the same folder, synced, then renamed.
            try disk.replace(data, at: url(id))
            newest = snapshot
            // Spec 9 §7 — "The retention pass runs ... after each snapshot".
            removeExpired()
            afterSnapshot?()
            return .taken(token: request.token, reason: reason, id: id, bytes: data.count)
        } catch {
            let failure = Disk.Failure(error)
            status?.failed(failure)
            return .failed(token: request.token, reason: reason, failure: failure)
        }
    }

    /// The snapshot `id` holds, from memory when it is the one last written or read.
    private func newestSnapshot(_ id: String) -> Snapshot? {
        if let newest, newest.manifest.id == id { return newest }
        guard case .success(let snapshot) = load(id) else { return nil }
        newest = snapshot
        return snapshot
    }

    private func load(_ id: String) -> Result<Snapshot, Rejection> {
        guard SnapshotID.isPlausible(id), let data = try? Data(contentsOf: url(id), options: .mappedIfSafe) else {
            // "Refused with `unknownObject` for an id with no file."
            return .failure(Rejection(reason: .unknownObject, message: "there is no snapshot \"\(id)\""))
        }
        do {
            let entries = try Zip.entries(of: data)
            return .success(try Snapshot(files: entries.map { ($0.path, $0.data) }))
        } catch let failure as Zip.Failure {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\" can't be read: \(failure.message)"))
        } catch let failure as Snapshot.Unreadable {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\" can't be read: \(failure.message)"))
        } catch {
            return .failure(Rejection(reason: .badValue, message: "snapshot \"\(id)\" can't be read: \(error)"))
        }
    }

    // MARK: - Reading for a restore (on the queue)

    private func readSnapshot(_ id: String, before: Take?) -> Result<RestoreMaterial, Rejection> {
        let snapshot: Snapshot
        switch load(id) {
        case .failure(let rejection): return .failure(rejection)
        case .success(let read): snapshot = read
        }
        guard let before else {
            return .failure(Rejection(reason: .conflict, message: "no snapshot was taken before the restore, so it can't be undone"))
        }
        // Spec 9 §10 — "a failure while the pre-restore snapshot is written leaves every document as it was".
        switch write(before) {
        case .taken(_, _, let taken, _):
            return .success(.snapshot(snapshot, before: taken))
        case .failed(_, _, let failure):
            return .failure(Rejection(reason: failure.isFull ? .diskFull : .conflict,
                                      message: "the snapshot before the restore couldn't be written: \(failure)"))
        case .unchanged, .paused, .read:
            return .failure(Rejection(reason: .conflict, message: "the snapshot before the restore wasn't written"))
        }
    }

    /// Spec 9 §6 — "The version is the file with that list's uuid and
    /// `version` V; without one, the command is refused with `unknownObject`."
    private func readVersion(list: UUID, version: Int) -> Result<RestoreMaterial, Rejection> {
        let path = FileLayout.versionPath(list: list, version: version)
        let none = Rejection(reason: .unknownObject, message: "there is no version \(version) of that list (\(path))")
        guard let data = FileManager.default.contents(atPath: libraryRoot.appendingPathComponent(path).path) else { return .failure(none) }
        do {
            guard case .list(let kept) = try Loader.document(path: path, data: data).body else { return .failure(none) }
            return .success(.version(kept, kept: Set(versions(of: list).map(\.version))))
        } catch let failure as DocumentFailure {
            return .failure(Rejection(reason: .badValue, message: "version \(version) can't be read: \(failure.message)"))
        } catch {
            return .failure(Rejection(reason: .badValue, message: "version \(version) can't be read: \(error)"))
        }
    }

    // MARK: - Listings (Spec 9 §6, "Picking one")

    /// The versions kept for a list on disk, with each file's date, oldest first.
    public func versions(of list: UUID) -> [(version: Int, url: URL, modified: Date)] {
        let folder = libraryRoot.appendingPathComponent("versions/" + list.uuidString.lowercased())
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var out: [(version: Int, url: URL, modified: Date)] = []
        for name in names where name.hasPrefix("v") && name.hasSuffix(".json") {
            guard let version = Int(name.dropFirst().dropLast(5)) else { continue }
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            out.append((version, url, modified))
        }
        return out.sorted { $0.version < $1.version }
    }

    /// Spec 9 §6 — "`{ "type": "query", "what": "versions", "list": 42 }`
    /// returns that list's kept versions, newest first, each with `version`,
    /// `keptAt` (the file's date), `title` and `cues`, how many it has." A
    /// file that doesn't read is left out. Any thread but the control and
    /// render threads: it reads the files.
    public func versionListing(of list: UUID, stamp: (Date) -> String) -> [JSONValue] {
        versions(of: list).reversed().compactMap { entry in
            guard let data = FileManager.default.contents(atPath: entry.url.path),
                  case .list(let kept)? = try? Loader.document(path: FileLayout.versionPath(list: list, version: entry.version), data: data).body else {
                return nil
            }
            return .object(["version": .number(Double(entry.version)), "keptAt": .string(stamp(entry.modified)),
                            "title": .string(kept.title), "cues": .number(Double(kept.cues.count))])
        }
    }

    /// Spec 9 §6 — "`{ "type": "query", "what": "snapshots" }` returns the
    /// snapshots in `machine/snapshots/`, newest first, each with `id`,
    /// `takenAt`, `reason`, `bytes`, and `machine` and `campus` from its
    /// manifest." A zip whose manifest doesn't read is left out.
    public func snapshotListing() -> [JSONValue] {
        ids().reversed().compactMap { id in
            let file = url(id)
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let entry = try? Zip.entry(SnapshotManifest.path, of: data), let manifest = SnapshotManifest(data: entry) else { return nil }
            var members: [String: JSONValue] = ["id": .string(id), "takenAt": .string(manifest.takenAt), "reason": .string(manifest.reason),
                                                "bytes": .number(Double(data.count))]
            members["machine"] = manifest.machine.map(JSONValue.string) ?? .null
            members["campus"] = manifest.campus.map(JSONValue.string) ?? .null
            return .object(members)
        }
    }
}
