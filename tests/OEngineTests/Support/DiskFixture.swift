import Foundation
import OCore
import OFormats
@testable import OEngine

/// A wall clock a test can move.
final class MovableWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) {
        current = date
    }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}

/// Spec 7 §8 — "Tests that need files the fixture shouldn't hold ... make
/// them in a temporary copy": the fixture's two roots copied to a temporary
/// folder, loaded through OFormats, and an engine over them that writes its
/// edits there (Spec 5 §2). The machine takes the spike's display outputs in
/// memory (the fixture's own pair a 60p display with a 29.97 SDI output) and
/// is `writable` unless the test says otherwise; neither is ever written.
final class DiskFixture {
    let folder: URL
    let engine: HeadlessEngine
    let clock: MovableWallClock
    let events = EventRecorder()

    var libraryRoot: URL { folder.appendingPathComponent("library") }
    var machineRoot: URL { folder.appendingPathComponent("machine") }
    var control: ControlLoop { engine.control }
    var log: EngineLog { engine.log }

    /// `prepare` changes the copy before it loads.
    init(wallClock: Date = HeadlessEngine.fixedWallClock(), prepare: (URL) throws -> Void = { _ in },
         configure: (inout Machine) -> Void = { _ in }) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-disk-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: EngineFixtures.fixtureRoot, to: folder)
        try prepare(folder)
        let roots = try LoadedRoots.load(libraryRoot: folder.appendingPathComponent("library"),
                                         machineRoot: folder.appendingPathComponent("machine"))
        var machine = roots.machine
        machine.outputs = try EngineFixtures.spikeMachine().outputs
        machine.settings.libraryMode = .writable
        configure(&machine)
        let clock = MovableWallClock(wallClock)
        self.clock = clock
        engine = try HeadlessEngine(library: roots.library, machine: machine, mediaRoot: EngineFixtures.mediaRoot,
                                    wallClock: { clock.now })
        engine.attachDocuments(roots)
        let events = self.events
        engine.engine.publisher.subscribe(["library"]) { events.record($0) }
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Driving

    @discardableResult
    func send(_ text: String, source: SourceKind = .ui, client: String? = nil) -> Rejection? {
        engine.send(text, source: source, client: client)
    }

    /// One tick, then the writer's queue finishes, then a tick reads its reports.
    func settle() {
        engine.tick()
        engine.waitForWrites()
        engine.tick()
    }

    /// A second of ticks, so the next write is due, then settle.
    func nextSecond() {
        engine.tick(count: 60)
        engine.waitForWrites()
        engine.tick()
    }

    // MARK: - Files

    func url(_ root: DocumentWriter.Root, _ path: String) -> URL {
        (root == .library ? libraryRoot : machineRoot).appendingPathComponent(path)
    }

    func exists(_ root: DocumentWriter.Root, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(root, path).path)
    }

    func data(_ root: DocumentWriter.Root, _ path: String) -> Data? {
        FileManager.default.contents(atPath: url(root, path).path)
    }

    /// The document a file holds, read as the loader reads it.
    func document(_ root: DocumentWriter.Root, _ path: String) -> Document? {
        guard let data = data(root, path) else { return nil }
        return (try? Loader.document(path: path, data: data))?.body
    }

    func list(at path: String) -> List? {
        if case .list(let list)? = document(.library, path) { return list }
        return nil
    }

    func playlist(at path: String) -> Playlist? {
        if case .playlist(let playlist)? = document(.machine, path) { return playlist }
        return nil
    }

    func write(_ root: DocumentWriter.Root, _ path: String, _ data: Data) throws {
        let target = url(root, path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    /// A file's JSON with one top-level member changed, as a hand edit or a
    /// sync would leave it.
    func edited(_ root: DocumentWriter.Root, _ path: String, _ key: String, _ value: JSONValue) throws -> Data {
        guard let data = data(root, path), case .object(var members) = try JSONValue.parse(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        members[key] = value
        return JSONCanonical.data(.object(members))
    }

    /// The files under a folder of a root, relative to it, sorted; hidden ones left out.
    func files(_ root: DocumentWriter.Root, under folder: String) -> [String] {
        let base = url(root, folder)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        let prefix = base.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            out.append(folder + "/" + String(url.standardizedFileURL.path.dropFirst(prefix.count)))
        }
        return out.sorted()
    }
}
