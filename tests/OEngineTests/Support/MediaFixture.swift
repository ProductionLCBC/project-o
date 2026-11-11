import Foundation
import OCore
import OFormats
@testable import OEngine

/// The wall clock the media worker reads, moved by the tests: files written
/// now are `offset` seconds old to it (Spec 8 §4, the two seconds).
final class MediaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var shift: TimeInterval

    init(offset: TimeInterval = 60) {
        shift = offset
    }

    var offset: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return shift }
        set { lock.lock(); shift = newValue; lock.unlock() }
    }

    func now() -> Date {
        Date().addingTimeInterval(offset)
    }
}

/// Collects a topic's events from the engine's own publisher.
final class TopicRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: JSONValue]] = []

    func record(_ event: JSONValue) {
        lock.lock()
        events.append(event.objectValue ?? [:])
        lock.unlock()
    }

    var all: [[String: JSONValue]] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

/// Spec 8 §9 — "every test that launches the engine on a fixture runs on a
/// temporary copy": the fixture library copied to a temporary folder, loaded
/// with its media where the copy has it, the engine over fakes with its
/// documents attached and a media worker whose clock, probe, free space and
/// staging folder the test controls (Spec 8 §11, "seams").
final class MediaFixture {
    let folder: URL
    let staging: URL
    let clock: MediaTestClock
    let free: FreeSpace
    let media = TopicRecorder()
    let library = TopicRecorder()
    private(set) var engine: HeadlessEngine!
    private(set) var worker: MediaWorker!

    /// The free bytes the worker sees, set by the tests (Spec 8 §3, `diskFull`).
    final class FreeSpace: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 1 << 40
        var bytes: Int64 {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    var libraryRoot: URL { folder.appendingPathComponent("library") }
    var machineRoot: URL { folder.appendingPathComponent("machine") }
    var mediaRoot: URL { libraryRoot.appendingPathComponent("media") }
    var machineMedia: URL { machineRoot.appendingPathComponent("media") }
    var control: ControlLoop { engine.control }

    /// `prepare` changes the copy before it loads; `configure` the machine.
    init(writable: Bool = true, prepare: (MediaFixture) throws -> Void = { _ in }, configure: (inout Machine) -> Void = { _ in }) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-media-\(UUID().uuidString)")
        staging = folder.appendingPathComponent("Staging")
        clock = MediaTestClock()
        free = FreeSpace()
        try FileManager.default.copyItem(at: EngineFixtures.fixtureRoot, to: folder)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try prepare(self)
        try launch(writable: writable, configure: configure)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Spec 8 §4 — a launch on the copy: the roots and the cache read, the
    /// worker attached, the launch walk taken in.
    func launch(writable: Bool = true, configure: (inout Machine) -> Void = { _ in }) throws {
        let roots = try LoadedRoots.load(libraryRoot: libraryRoot, machineRoot: machineRoot)
        var machine = roots.machine
        machine.outputs = try EngineFixtures.spikeMachine().outputs
        machine.settings.libraryMode = writable ? .writable : .readOnlyMasters
        configure(&machine)
        engine = try HeadlessEngine(library: roots.library, machine: machine, media: roots.media,
                                    mediaCache: LocalFiles.mediaCache(machineRoot: machineRoot))
        engine.attachDocuments(roots)
        let media = self.media
        let library = self.library
        engine.engine.publisher.subscribe(["media"]) { media.record($0) }
        engine.engine.publisher.subscribe(["library"]) { library.record($0) }
        let clock = self.clock
        let free = self.free
        worker = try engine.attachMediaWorker(machineRoot: machineRoot, staging: staging,
                                              seams: MediaWorker.Seams(now: { clock.now() }, probe: FakeMediaProbe(),
                                                                       freeBytes: { _ in free.bytes }))
        settle()
    }

    /// Queued commands run, the worker finishes, a tick takes in what it
    /// found, the cache and the indexes are written.
    func settle() {
        engine.settleMedia()
    }

    /// What the watcher does on a change under a media folder.
    func walk() {
        engine.walkMedia()
    }

    // MARK: - Files

    func url(_ folder: MediaFolder, _ path: String) -> URL {
        (folder == .machineMedia ? machineMedia : mediaRoot).appendingPathComponent(path)
    }

    func write(_ folder: MediaFolder, _ path: String, _ bytes: String) throws {
        let target = url(folder, path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: target)
    }

    func move(_ folder: MediaFolder, _ from: String, to: String) throws {
        let target = url(folder, to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(folder, from), to: target)
    }

    func remove(_ folder: MediaFolder, _ path: String) throws {
        try FileManager.default.removeItem(at: url(folder, path))
    }

    func exists(_ folder: MediaFolder, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(folder, path).path)
    }

    /// The id of some bytes, as the walk works it out.
    static func id(_ bytes: String) -> String {
        MediaID.sha256(of: Data(bytes.utf8))
    }

    /// An index as written on disk.
    func writtenIndex() -> MediaIndex? {
        guard let data = FileManager.default.contents(atPath: libraryRoot.appendingPathComponent("media-index.json").path),
              case .mediaIndex(let index)? = try? Loader.document(path: "media-index.json", data: data).body else { return nil }
        return index
    }

    func writtenLocal() -> MediaLocalIndex? {
        guard let data = FileManager.default.contents(atPath: machineRoot.appendingPathComponent("media-local.json").path),
              case .mediaLocal(let index)? = try? Loader.document(path: "media-local.json", data: data).body else { return nil }
        return index
    }

    var mediaEvents: [[String: JSONValue]] { media.all }
    var mediaLibraryEvents: [[String: JSONValue]] { library.all.filter { $0["cause"] == .string("media") } }
}
