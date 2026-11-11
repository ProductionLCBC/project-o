import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 5 §10 — "Changes that arrive on disk"; Spec 1 §8 — "the app reloads
/// it on the control thread"; Spec 7 §2 — folders on disk, moves, "a list
/// file that disappears stays loaded for three seconds", two files holding
/// one list; Spec 7 §10 — "A file moved between folders with its uuid is a
/// move, also when it arrives as a delete and a create within three seconds,
/// and no version goes up ... A copy that arrives before the original goes
/// still ends as a move"; Spec 5 §11 — "Disk. ... A change arriving inside the
/// write window lands in `machine/conflicts/`, and the engine's version is
/// written"; "Events. Each applied group or reload sends exactly one
/// `library` event, and the revision goes up by one." On a temporary copy of
/// the fixture, each scan run as the folder watcher would ask for it.
final class DiskChangeTests: XCTestCase {
    static let list7 = "a9f00000-0000-4000-8000-000000000007"
    static let doxology = "lists/007-doxology.json"

    var disk: DiskFixture!
    var library: Library { disk.engine.engine.library }
    var machine: Machine { disk.engine.engine.machine }
    var fileEvents: [[String: JSONValue]] { disk.events.all.filter { $0["cause"] == .string("file") } }

    override func setUpWithError() throws {
        disk = try DiskFixture()
    }

    override func tearDown() {
        disk = nil
    }

    func listJSON(_ change: (inout [String: JSONValue]) -> Void) throws -> Data {
        guard let data = disk.data(.library, Self.doxology), case .object(var members) = try JSONValue.parse(data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        change(&members)
        return JSONCanonical.data(.object(members))
    }

    func move(_ from: String, _ to: String) throws {
        try FileManager.default.createDirectory(at: disk.url(.library, to).deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: disk.url(.library, from), to: disk.url(.library, to))
    }

    // MARK: - Reloads

    /// "No unwritten edits. The engine loads the arriving document ... and
    /// sends a `library` event with cause `file`": one event for the reload,
    /// with every list it changed, and the revision up by one.
    func test_changedMastersReloadWithOneFileEvent() throws {
        try disk.write(.library, Self.doxology, try disk.edited(.library, Self.doxology, "title", .string("Old Hundredth")))
        let hymn = "lists/Hymns/042-great-is-thy-faithfulness.json"
        try disk.write(.library, hymn, try disk.edited(.library, hymn, "author", .string("T. O. Chisholm")))
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 7)?.title, "Old Hundredth")
        XCTAssertEqual(library.list(number: 42)?.author, "T. O. Chisholm")
        XCTAssertEqual(disk.control.revision, 2)
        XCTAssertEqual(fileEvents.count, 1)
        let event = try XCTUnwrap(fileEvents.first)
        XCTAssertNil(event["group"])
        XCTAssertNil(event["source"])
        let changed = event["changed"]?.arrayValue?.compactMap { $0["list"]?.intValue }
        XCTAssertEqual(changed.map { Set($0) }, [7, 42])
        XCTAssertFalse(disk.exists(.machine, "conflicts"), "nothing was unwritten")
        XCTAssertFalse(disk.exists(.library, "lists/007-old-hundredth.json"), "a reload writes nothing")
    }

    /// The engine's own writes aren't changes that arrive.
    func test_theEnginesOwnWritesAreNotReloaded() throws {
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.settle()
        disk.engine.scanDisk()
        disk.engine.scanDisk()
        XCTAssertTrue(fileEvents.isEmpty, "\(fileEvents)")
        XCTAssertEqual(disk.control.revision, 2, "the edit's")
    }

    /// Spec 1 §5 — the watcher ignores "any file whose JSON does not parse
    /// yet, so a document arriving by sync is read only once it is complete".
    func test_aFileThatDoesNotReadYetIsReadOnceComplete() throws {
        let complete = try listJSON { $0["title"] = .string("Gloria") }
        try disk.write(.library, Self.doxology, Data("{\"schema\": 1, \"kind\": \"list\", \"title\": \"Glo".utf8))
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology", "the list stays as it loaded")
        XCTAssertTrue(fileEvents.isEmpty)
        XCTAssertTrue(disk.log.contains("does not read yet"))
        try disk.write(.library, Self.doxology, complete)
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 7)?.title, "Gloria")
    }

    /// Spec 1 §8 — "a master arriving by sync" loads, in its folder.
    func test_aNewMasterArrives() throws {
        let data = try listJSON { members in
            members["uuid"] = .string("a9f00000-0000-4000-8000-000000000039")
            members["number"] = .number(57)
            members["title"] = .string("Be Thou My Vision")
        }
        try disk.write(.library, "lists/Hymns/057-be-thou-my-vision.json", data)
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 57)?.title, "Be Thou My Vision")
        XCTAssertEqual(library.folder(ofList: try XCTUnwrap(UUID(uuidString: "a9f00000-0000-4000-8000-000000000039"))), "Hymns")
        XCTAssertEqual(fileEvents.count, 1)
    }

    // MARK: - Moves and deletes (Spec 7 §2)

    /// "A list file that turns up in another folder with the same uuid is the
    /// same list, moved", and no version goes up.
    func test_aMoveOnDiskIsAMove() throws {
        try move(Self.doxology, "lists/Hymns/007-doxology.json")
        disk.engine.scanDisk()
        let uuid = try XCTUnwrap(UUID(uuidString: Self.list7))
        XCTAssertEqual(library.folder(ofList: uuid), "Hymns")
        XCTAssertEqual(library.list(number: 7)?.version, 3)
        XCTAssertTrue(disk.control.documents?.reload.pending.isEmpty == true)
        XCTAssertEqual(fileEvents.count, 1)
    }

    /// "A sync can deliver a move as a delete and a create, so a list file
    /// that disappears stays loaded for three seconds and counts as deleted
    /// only if no file with its uuid appears under `lists/` in that time."
    func test_aDeleteAndACreateWithinThreeSecondsIsAMove() throws {
        let data = try XCTUnwrap(disk.data(.library, Self.doxology))
        try FileManager.default.removeItem(at: disk.url(.library, Self.doxology))
        disk.engine.scanDisk()
        XCTAssertNotNil(library.list(number: 7), "still loaded")
        disk.engine.tick(count: 120)
        try disk.write(.library, "lists/Christmas/007-doxology.json", data)
        disk.engine.scanDisk()
        disk.engine.tick(count: 240)
        let uuid = try XCTUnwrap(UUID(uuidString: Self.list7))
        XCTAssertEqual(library.folder(ofList: uuid), "Christmas")
        XCTAssertEqual(library.list(number: 7)?.version, 3)
        XCTAssertTrue(disk.log.contains("moved on disk"))
    }

    /// The same delete with nothing arriving: deleted after three seconds,
    /// with a `library` event.
    func test_aFileGoneForThreeSecondsIsADelete() throws {
        try FileManager.default.removeItem(at: disk.url(.library, Self.doxology))
        disk.engine.scanDisk()
        disk.engine.tick(count: 170)
        XCTAssertNotNil(library.list(number: 7), "inside the window")
        XCTAssertTrue(fileEvents.isEmpty)
        disk.engine.tick(count: 20)
        XCTAssertNil(library.list(number: 7))
        XCTAssertEqual(fileEvents.count, 1)
        XCTAssertEqual(fileEvents.first?["changed"]?.arrayValue?.first?["list"], .number(7))
    }

    /// "If the new file arrives before the old one goes, the two files hold
    /// one list for a moment, and the next rule keeps one until the other
    /// goes" — "A copy that arrives before the original goes still ends as a move."
    func test_aCopyThatArrivesBeforeTheOriginalGoesStillEndsAsAMove() throws {
        let data = try XCTUnwrap(disk.data(.library, Self.doxology))
        try disk.write(.library, "lists/Hymns/007-doxology.json", data)
        disk.engine.scanDisk()
        XCTAssertEqual(library.lists.filter { $0.number == 7 }.count, 1, "one list")
        XCTAssertTrue(disk.log.contains("both hold list 7"), "\(disk.log.recent)")
        try FileManager.default.removeItem(at: disk.url(.library, Self.doxology))
        disk.engine.scanDisk()
        disk.engine.tick(count: 200)
        let uuid = try XCTUnwrap(UUID(uuidString: Self.list7))
        XCTAssertEqual(library.folder(ofList: uuid), "Hymns")
        XCTAssertNotNil(library.list(number: 7))
        XCTAssertFalse(library.otherFiles.contains("lists/Hymns/007-doxology.json"))
    }

    /// Choice Q-5 — "a copy made in the Finder ("… copy.json") never replaces
    /// the original": it isn't loaded, it is reported, and a save never
    /// writes over it.
    func test_aFinderCopyIsReportedAndNeverWrittenOver() throws {
        let copy = "lists/007-doxology copy.json"
        let data = try XCTUnwrap(disk.data(.library, Self.doxology))
        try disk.write(.library, copy, data)
        disk.engine.scanDisk()
        XCTAssertEqual(library.documentPaths["list/" + Self.list7], Self.doxology)
        XCTAssertTrue(library.otherFiles.contains(copy))
        XCTAssertTrue(disk.log.contains("\(copy) holds list 7"), "\(disk.log.recent)")
        disk.send("edit list 7 title \"Gloria\"")
        disk.settle()
        XCTAssertEqual(disk.data(.library, copy), data)
        XCTAssertEqual(disk.list(at: "lists/007-gloria.json")?.title, "Gloria")
    }

    // MARK: - Unwritten edits (Spec 5 §10, choice E-5)

    /// "Unwritten edits. The engine's edits win. It keeps the arriving file
    /// in `machine/conflicts/`, named with the time and the file's name,
    /// writes its own document, and logs both."
    func test_aChangeInsideTheWriteWindowGoesToConflicts() throws {
        disk.send("edit list 7 title \"A\"")
        disk.settle()
        disk.send("edit list 7 title \"B\"")
        disk.engine.tick()
        let arriving = try disk.edited(.library, "lists/007-a.json", "author", .string("Someone Else"))
        try disk.write(.library, "lists/007-a.json", arriving)
        disk.engine.scanDisk()
        disk.engine.waitForWrites()
        XCTAssertEqual(disk.files(.machine, under: "conflicts"), ["conflicts/2026-10-30-100000-007-a.json"])
        XCTAssertEqual(disk.data(.machine, "conflicts/2026-10-30-100000-007-a.json"), arriving)
        XCTAssertEqual(library.list(number: 7)?.title, "B")
        XCTAssertEqual(library.list(number: 7)?.author, "Thomas Ken", "nothing is merged")
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: "lists/007-b.json")?.title, "B")
        XCTAssertEqual(disk.files(.machine, under: "conflicts").count, 1, "kept once")
        XCTAssertTrue(disk.log.contains("is kept as conflicts/2026-10-30-100000-007-a.json"))
        XCTAssertTrue(fileEvents.isEmpty, "the engine's list didn't change")
    }

    /// "When a list with unwritten edits has moved on disk, the engine writes
    /// them at the new path."
    func test_aMovedListWithUnwrittenEditsIsWrittenAtItsNewPath() throws {
        disk.send("edit list 7 title \"A\"")
        disk.settle()
        disk.send("edit list 7 title \"B\"")
        disk.engine.tick()
        try move("lists/007-a.json", "lists/Hymns/007-a.json")
        disk.engine.scanDisk()
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: "lists/Hymns/007-b.json")?.title, "B")
        XCTAssertFalse(disk.exists(.library, "lists/007-a.json"))
        XCTAssertFalse(disk.exists(.library, "lists/Hymns/007-a.json"))
        XCTAssertFalse(disk.exists(.machine, "conflicts"), "a move alone loses nothing")
    }

    // MARK: - Folders and playlists

    /// Spec 7 §2 — "Folders are directories ... a Finder reorganize or a sync
    /// shows up as the same moves in the app"; "an empty folder survives a
    /// reload".
    func test_foldersMadeAndRemovedOnDisk() throws {
        try FileManager.default.createDirectory(at: disk.url(.library, "lists/Easter"), withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: disk.url(.library, "lists/Christmas"))
        disk.engine.scanDisk()
        XCTAssertEqual(library.folders, ["Easter", "Hymns"])
        let changed = fileEvents.first?["changed"]?.arrayValue?.compactMap { $0["folder"]?.stringValue }
        XCTAssertEqual(changed.map { Set($0) }, ["Easter", "Christmas"])
        let reread = try LoadedRoots.load(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot)
        XCTAssertEqual(reread.library.folders, ["Easter", "Hymns"], "the empty folder loads")
    }

    /// Spec 7 §3 — playlists reload, arrive and go; "A playlist file that
    /// disappears is deleted at once" (the machine root is never synced).
    func test_playlistsReloadArriveAndGo() throws {
        let night = "playlists/sunday-night.json"
        try disk.write(.machine, night, try disk.edited(.machine, night, "title", .string("Sunday Evening")))
        var easter = try disk.edited(.machine, night, "uuid", .string("b1a70000-0000-4000-8000-0000000000ee"))
        guard case .object(var members) = try JSONValue.parse(easter) else { return XCTFail() }
        members["title"] = .string("Easter")
        members["items"] = .array([])
        easter = JSONCanonical.data(.object(members))
        try disk.write(.machine, "playlists/easter.json", easter)
        disk.engine.scanDisk()
        XCTAssertEqual(machine.playlist(titled: "Sunday Evening")?.uuid.uuidString.lowercased(), "b1a70000-0000-4000-8000-000000000010")
        XCTAssertNotNil(machine.playlist(titled: "Easter"))
        try FileManager.default.removeItem(at: disk.url(.machine, "playlists/easter.json"))
        disk.engine.scanDisk()
        XCTAssertNil(machine.playlist(titled: "Easter"), "at once")
        XCTAssertEqual(fileEvents.count, 2)
    }

    // MARK: - The folder watcher

    /// Spec 1 §8 — a real FSEvents stream on the roots: a hand edit reloads.
    func test_theFolderWatcherSeesAChange() throws {
        let seen = expectation(description: "the watcher saw lists/ change")
        seen.assertForOverFulfill = false
        let control = disk.control
        let watcher = DiskWatcher(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot) {
            control.requestScan()
            seen.fulfill()
        }
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try disk.write(.library, Self.doxology, try disk.edited(.library, Self.doxology, "title", .string("Old Hundredth")))
        wait(for: [seen], timeout: 10)
        disk.engine.waitForWrites()
        disk.engine.tick()
        XCTAssertEqual(library.list(number: 7)?.title, "Old Hundredth")
    }

    /// Events under the rest of the roots aren't changes to documents; Spec 8
    /// §4 — events under the media root or `machine/media/` start a walk.
    func test_theWatcherWatchesDocumentsAndTheMediaFolders() {
        let media = [disk.libraryRoot.appendingPathComponent("media"), disk.machineRoot.appendingPathComponent("media")]
        let watcher = DiskWatcher(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot, media: media, onChange: {})
        let library = DiskWatcher.realPath(disk.libraryRoot)
        let machine = DiskWatcher.realPath(disk.machineRoot)
        XCTAssertTrue(library.hasPrefix("/private/"), "FSEvents names real paths: \(library)")
        XCTAssertTrue(watcher.matches(library + "/lists/Hymns/042.json"))
        XCTAssertTrue(watcher.matches(library + "/lists"))
        XCTAssertTrue(watcher.matches(machine + "/playlists/sunday.json"))
        XCTAssertTrue(watcher.matches(machine + "/lists-local/042-x.json"))
        XCTAssertTrue(watcher.matches(library + "/media-index.json"), "Spec 8 §2 — the library media index")
        XCTAssertTrue(watcher.matches(machine + "/media-local.json"), "and the machine's")
        XCTAssertFalse(watcher.matches(machine + "/media-cache.json"), "the cache is the engine's own")
        XCTAssertFalse(watcher.matches(machine + "/thumbnails/a.png"))
        XCTAssertFalse(watcher.matches(library + "/media/dawn.mp4"))
        XCTAssertFalse(watcher.matches(library + "/listsx/a.json"))
        XCTAssertTrue(watcher.matchesMedia(library + "/media/backgrounds/dawn.mp4"))
        XCTAssertTrue(watcher.matchesMedia(machine + "/media/announcement.png"))
        XCTAssertFalse(watcher.matchesMedia(machine + "/media-local.json"))
        XCTAssertFalse(watcher.matchesMedia(library + "/lists/Hymns/042.json"))
    }

    // MARK: - The media indexes (Spec 8 §2, §9)

    /// Spec 8 §2 — "Missing state is worked out ... whenever either index
    /// reloads": a media index changed on disk reloads with one `library`
    /// event, cause `file`, naming the media by id.
    func test_aMediaIndexChangedOnDiskReloads() throws {
        let announcement = "sha256:fa3021eba9c15cb8aa65b79e04c0df3d5291d79d397e5930610248bab8d3e2e0"
        let data = try XCTUnwrap(disk.data(.machine, "media-local.json"))
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"loop\": false", with: "\"loop\": true")
        try disk.write(.machine, "media-local.json", Data(text.utf8))
        disk.engine.scanDisk()
        XCTAssertEqual(machine.mediaLocal.entry(announcement)?.defaults.loop, true)
        XCTAssertEqual(fileEvents.count, 1)
        XCTAssertEqual(fileEvents.last?["changed"], .array([.object(["object": .string("media"), "media": .string(announcement), "paths": .array([])])]))
        // The library's, which arrives by sync.
        let index = try XCTUnwrap(disk.data(.library, "media-index.json"))
        let synced = String(decoding: index, as: UTF8.self).replacingOccurrences(of: "\"replaced\": {}",
            with: "\"replaced\": { \"\(EngineFixtures.mountains)\": \"\(EngineFixtures.dawn)\" }")
        try disk.write(.library, "media-index.json", Data(synced.utf8))
        disk.engine.scanDisk()
        XCTAssertEqual(library.mediaIndex.replaced, [EngineFixtures.mountains: EngineFixtures.dawn])
        XCTAssertEqual(fileEvents.count, 2)
        // A file that went: the engine keeps the index it holds.
        try FileManager.default.removeItem(at: disk.url(.machine, "media-local.json"))
        disk.engine.scanDisk()
        XCTAssertEqual(machine.mediaLocal.entry(announcement)?.defaults.loop, true)
        XCTAssertEqual(fileEvents.count, 2)
    }
}
