import CoreGraphics
import Foundation
import ImageIO
import OCore
import OFormats
import XCTest
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
    /// Spec 8 §5 — the frames posters are made from, and the in-points asked for.
    let frames = FakeMediaFrames()
    /// Spec 8 §6 — the Trash, a folder beside the roots.
    let trash: FakeTrash
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

    /// Runs between a file's hash and its copy (`MediaWorker.Seams.beforeCopy`).
    let beforeCopy: (@Sendable (URL) -> Void)?
    /// Where media may live, when the test says (Spec 8 §2, M-8).
    let places: MediaPlaces?

    /// `prepare` changes the copy before it loads; `configure` the machine.
    init(writable: Bool = true, places: MediaPlaces? = nil, beforeCopy: (@Sendable (URL) -> Void)? = nil,
         prepare: (MediaFixture) throws -> Void = { _ in }, configure: (inout Machine) -> Void = { _ in }) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-media-\(UUID().uuidString)")
        staging = folder.appendingPathComponent("Staging")
        clock = MediaTestClock()
        free = FreeSpace()
        self.places = places
        self.beforeCopy = beforeCopy
        try FileManager.default.copyItem(at: EngineFixtures.fixtureRoot, to: folder)
        trash = FakeTrash(folder: folder.appendingPathComponent("Trash"))
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
        let roots = try LoadedRoots.load(libraryRoot: libraryRoot, machineRoot: machineRoot, places: places)
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
                                                                       freeBytes: { _ in free.bytes }, beforeCopy: beforeCopy,
                                                                       frames: frames, trash: trash))
        settle()
    }

    // MARK: - Import (Spec 8 §3)

    /// A file put in the staging folder, as the app stages a drop.
    @discardableResult
    func stage(_ path: String, _ bytes: String) throws -> URL {
        let target = staging.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: target)
        return target
    }

    /// `media import "PATH"`, sent and settled; the rejection when it is rejected.
    @discardableResult
    func importPath(_ url: URL, source: SourceKind = .ui) -> Rejection? {
        run("media import \"\(url.standardizedFileURL.path)\"", source: source)
    }

    /// A command sent and settled; its parse rejection, or the rejection of
    /// its group when the tick that ran it rejected it (Spec 2 §8).
    @discardableResult
    func run(_ text: String, source: SourceKind = .ui) -> Rejection? {
        let before = control.rejections.count
        if let rejection = engine.send(text, source: source) { return rejection }
        settle()
        return control.rejections.count > before ? control.rejections.last : nil
    }

    /// The `media` topic's events of one job, in order.
    func events(ofJob job: String) -> [[String: JSONValue]] {
        mediaEvents.filter { $0["job"] == .string(job) }
    }

    /// Every job id the `media` topic named, in order.
    var jobs: [String] {
        var out: [String] = []
        for event in mediaEvents {
            if let job = event["job"]?.stringValue, !out.contains(job) { out.append(job) }
        }
        return out
    }

    /// The final outcome events (`state: done`), in order.
    var outcomes: [[String: JSONValue]] {
        mediaEvents.filter { $0["state"] == .string("done") && $0["op"] == .string("import") }
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

    /// Spec 8 §5 — a real PNG of `width` × `height`, for images and posters the tiles are drawn from.
    func writePNG(_ folder: MediaFolder, _ path: String, width: Int = 64, height: Int = 36, gray: CGFloat = 0.3) throws {
        let target = url(folder, path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertTrue(MediaImages.writePNG(context.makeImage()!, to: target))
    }

    /// Spec 8 §5 — the pool tiles in `machine/thumbnails/pool/`, by name.
    var tiles: Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: machineRoot.appendingPathComponent("thumbnails/pool").path)) ?? [])
    }

    /// The pixel size of a PNG on disk.
    static func size(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
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
