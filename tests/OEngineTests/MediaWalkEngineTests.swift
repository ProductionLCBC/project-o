import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §4 — the walk in the engine: when it runs, what it reads and
/// skips, the cache, and what reaches the control thread; Spec 8 §2 — the
/// index changes it makes aren't commands; Spec 8 §9 — presence, the
/// thumbnail keys and the OSC ids follow it. Spec 8 §11, The walk: "It runs
/// at launch, on `media rebuild` and from the watcher; a growing file waits
/// until it has held for two seconds, and a half-written video that won't
/// open isn't indexed. Hidden folders, temporary files, `fonts/` and override
/// targets are skipped. The cache spares a second hash when dates differ from
/// the index, and the same path in both folders keeps two records." Logging:
/// "An import's and a walk's index changes raise the revision and send
/// `library` events with cause `media`, and aren't in the command log".
/// Resolver: "Missing state follows a walk and an index reload without a
/// relaunch." (The walk's rules themselves are MediaWalkTests'.)
final class MediaWalkEngineTests: XCTestCase {
    typealias E = EngineFixtures
    var media: MediaFixture!

    override func setUpWithError() throws {
        media = try MediaFixture()
    }

    override func tearDown() {
        media = nil
    }

    // MARK: - When it runs

    /// "The engine walks the media root and `machine/media/` at launch": the
    /// fixture's files hold their entries' ids, so nothing changes, every file
    /// is in the cache, and only mountains, absent on purpose, is missing.
    func test_theLaunchWalkReadsBothFoldersAndWritesTheCache() throws {
        XCTAssertEqual(media.control.missing, [E.mountains])
        XCTAssertEqual(media.mediaLibraryEvents.count, 0, "the fixture's files hold their entries' ids")
        XCTAssertEqual(media.control.revision, 1)
        let cache = LocalFiles.mediaCache(machineRoot: media.machineRoot)
        XCTAssertEqual(Set(cache.records.map(\.location)), [
            MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!, MediaLocation(.mediaRoot, "backgrounds/cross.png")!,
            MediaLocation(.mediaRoot, "slides/welcome.oslide")!, MediaLocation(.machineMedia, "announcement.png")!,
            MediaLocation(.machineMedia, "cross-fast.png")!,
        ], "a record per file found, the override's target included; .posters/ is hidden")
        XCTAssertEqual(cache.record(at: MediaLocation(.mediaRoot, "slides/welcome.oslide")!)?.hash, "slide:51de0000-0000-4000-8000-000000000001", "a slide by its uuid")
        XCTAssertEqual(media.mediaEvents.filter { $0["op"] == .string("walk") }.compactMap { $0["state"]?.stringValue }.first, "started")
        XCTAssertEqual(media.mediaEvents.filter { $0["op"] == .string("walk") }.last?["state"], .string("done"))
    }

    /// "... on `media rebuild` ...": a file that arrived is indexed, with one
    /// `library` event, cause `media`, the revision up by one; the command
    /// log holds the rebuild, and nothing for the index change.
    func test_aRebuildWalksAndItsIndexChangesArentCommands() throws {
        try media.write(.mediaRoot, "imports/Welcome.mov", "welcome, version one")
        let lines = media.control.commandLog.entries.count
        XCTAssertNil(media.engine.send("media rebuild", source: .ui))
        media.settle()
        let id = MediaFixture.id("welcome, version one")
        XCTAssertEqual(media.control.library.mediaIndex.entry(id)?.path, "imports/Welcome.mov")
        XCTAssertEqual(media.control.library.mediaIndex.entry(id)?.defaults, MediaDefaults())
        // The walk's change, then its poster's (Spec 8 §5, "The walk extracts missing posters"): one revision each.
        XCTAssertEqual(media.control.revision, 3)
        XCTAssertEqual(media.mediaLibraryEvents.count, 2)
        XCTAssertEqual(media.mediaLibraryEvents.first?["changed"],
                       .array([.object(["object": .string("media"), "media": .string(id), "paths": .array([])])]))
        XCTAssertEqual(media.mediaLibraryEvents.last?["changed"],
                       .array([.object(["object": .string("media"), "media": .string(id), "paths": .array([.string("poster")])])]))
        XCTAssertEqual(media.control.commandLog.entries.count, lines + 1)
        XCTAssertEqual(media.control.commandLog.entries.last?.command, .media(.rebuild))
        // Spec 8 §2 — the walk's index changes are written like any change.
        XCTAssertEqual(media.writtenIndex()?.entry(id)?.path, "imports/Welcome.mov")
        XCTAssertTrue(media.engine.log.contains("media: added \(id)"), "the engine log records it, by id")
    }

    /// "... and whenever its watcher reports a change under either folder":
    /// a real FSEvents stream on the copy's media folders.
    func test_theWatcherStartsAWalk() throws {
        let seen = expectation(description: "the watcher saw the media root change")
        seen.assertForOverFulfill = false
        let worker = try XCTUnwrap(media.worker)
        let watcher = DiskWatcher(libraryRoot: media.libraryRoot, machineRoot: media.machineRoot, media: [media.mediaRoot, media.machineMedia],
                                  onChange: {}, onMedia: {
                                      worker.requestWalk()
                                      seen.fulfill()
                                  })
        XCTAssertTrue(watcher.start())
        defer { watcher.stop() }
        try media.write(.machineMedia, "Local.mov", "a local video")
        wait(for: [seen], timeout: 10)
        media.settle()
        XCTAssertEqual(media.control.machine.mediaLocal.entry(MediaFixture.id("a local video"))?.path, "Local.mov")
        XCTAssertEqual(media.writtenLocal()?.entry(MediaFixture.id("a local video"))?.path, "Local.mov")
    }

    // MARK: - What it waits for and skips

    /// "A file is read once its size and modification date have held for two
    /// seconds, and a file that doesn't open yet as a kind v1 takes, such as a
    /// video still being exported, is left for a later walk".
    func test_aGrowingFileWaitsTwoSecondsAndAHalfWrittenVideoIsntIndexed() throws {
        media.clock.offset = 0
        try media.write(.mediaRoot, "Growing.mov", "still growing")
        media.walk()
        XCTAssertNil(media.control.library.mediaIndex.entry(MediaFixture.id("still growing")), "written under two seconds ago")
        XCTAssertEqual(media.control.mediaFiles[MediaLocation(.mediaRoot, "Growing.mov")!], .unhashed)
        media.clock.offset = 3
        media.walk()
        XCTAssertNotNil(media.control.library.mediaIndex.entry(MediaFixture.id("still growing")), "held for two seconds")

        try media.write(.mediaRoot, "Export.mov", "NOT YET half an export")
        media.walk()
        XCTAssertNil(media.control.library.mediaIndex.entry(MediaFixture.id("NOT YET half an export")), "it doesn't open yet")
        try media.write(.mediaRoot, "Export.mov", "the finished export")
        media.walk()
        XCTAssertEqual(media.control.library.mediaIndex.entry(MediaFixture.id("the finished export"))?.path, "Export.mov")
    }

    /// "What it skips: hidden files and folders (names starting with a dot,
    /// so `.posters/`), a sync tool's temporary files (Spec 1 §5), `fonts/`
    /// (Spec 1 §7), the files overrides point at, and kinds v1 doesn't take,
    /// which the reference report lists."
    func test_hiddenTemporaryFontsOverrideTargetsAndOtherKindsAreSkipped() throws {
        try media.write(.mediaRoot, ".hidden/Secret.mov", "hidden")
        try media.write(.mediaRoot, ".Hidden.mov", "hidden too")
        try media.write(.mediaRoot, "Partial.mov.tmp", "a sync tool's")
        try media.write(.mediaRoot, "fonts/DMSans.ttf", "a font")
        try media.write(.mediaRoot, "notes.txt", "plain text")
        media.walk()
        XCTAssertEqual(media.mediaLibraryEvents.count, 0)
        XCTAssertEqual(media.control.library.mediaIndex.entries.count, 4)
        XCTAssertNil(media.control.machine.mediaLocal.entry(E.cross), "an override's target is never an entry")
        XCTAssertTrue(media.engine.log.contains("notes.txt is plain text, which v1 doesn't take"), "kinds v1 doesn't take are reported")
    }

    // MARK: - The cache

    /// "A file whose size and date match its record isn't hashed again, so a
    /// file whose dates a checkout or a sync tool changed is hashed once, not
    /// at every launch": the fixture's entries' dates never match the copy's
    /// files, and a relaunch hashes nothing. "the same path in both folders
    /// keeps two records".
    func test_theCacheSparesASecondHash() throws {
        let first = media.worker.hashCount
        XCTAssertGreaterThanOrEqual(first, 5, "the launch walk hashed the fixture's files: their entries' dates are the fixture's")
        media.walk()
        XCTAssertEqual(media.worker.hashCount, first, "a walk with nothing changed hashes nothing")
        try media.launch()
        XCTAssertEqual(media.worker.hashCount, 0, "a relaunch reads the cache")
        XCTAssertEqual(media.control.missing, [E.mountains])
        // The same path in both folders.
        try FileManager.default.createDirectory(at: media.url(.machineMedia, "backgrounds"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: media.url(.mediaRoot, "backgrounds/dawn.mp4"), to: media.url(.machineMedia, "backgrounds/dawn.mp4"))
        media.walk()
        let cache = LocalFiles.mediaCache(machineRoot: media.machineRoot)
        XCTAssertEqual(cache.record(at: MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!)?.hash, E.dawn)
        XCTAssertEqual(cache.record(at: MediaLocation(.machineMedia, "backgrounds/dawn.mp4")!)?.hash, E.dawn)
        XCTAssertTrue(media.engine.log.contains("which the other folder's index holds"), "dawn is the library's: left alone, reported")
    }

    // MARK: - Moves, landings, presence

    /// Spec 8 §11 — "A move keeps the defaults", written to the index on disk.
    func test_aMoveKeepsTheDefaults() throws {
        let defaults = try XCTUnwrap(media.control.library.mediaIndex.entry(E.dawn)?.defaults)
        try media.move(.mediaRoot, "backgrounds/dawn.mp4", to: "Sunrise/dawn renamed.mp4")
        media.walk()
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.path, "Sunrise/dawn renamed.mp4")
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.defaults, defaults)
        XCTAssertEqual(media.writtenIndex()?.entry(E.dawn)?.path, "Sunrise/dawn renamed.mp4")
        XCTAssertFalse(media.control.missing.contains(E.dawn))
    }

    /// Spec 8 §11 — "A file exported over an item becomes a new item with its
    /// defaults, and the old id's cues play it": a write of the old id opens
    /// the new file, with the defaults it took.
    func test_aReExportPlaysUnderTheOldId() throws {
        try media.write(.mediaRoot, "backgrounds/dawn.mp4", "dawn, re-exported")
        media.walk()
        let new = MediaFixture.id("dawn, re-exported")
        XCTAssertEqual(media.control.library.mediaIndex.replaced[E.dawn], new)
        XCTAssertEqual(media.control.library.mediaIndex.entry(new)?.defaults.loop, true, "dawn's defaults")
        XCTAssertNil(media.engine.send("channel 1 write media \(E.dawn)", source: .ui))
        media.engine.tick()
        let instance = try XCTUnwrap(media.control.model.state.channels[1]?.content.media)
        XCTAssertEqual(instance.ref, E.dawn)
        XCTAssertFalse(instance.missing)
        XCTAssertEqual(instance.endBehavior, .loop)
        let factory = try XCTUnwrap(media.engine.sourceFactory as? FakeSourceFactory)
        XCTAssertEqual(factory.opened.last?.request.url.standardizedFileURL, media.url(.mediaRoot, "backgrounds/dawn.mp4").standardizedFileURL)
        XCTAssertEqual(factory.opened.last?.request.entry.id, new)
    }

    /// Spec 8 §11, Resolver — "Missing state follows a walk and an index
    /// reload without a relaunch", and the `media` topic "carries changes in
    /// an item's missing state".
    func test_missingStateFollowsAWalkAndAnIndexReload() throws {
        media.media.clear()
        try media.move(.mediaRoot, "backgrounds/dawn.mp4", to: "../dawn-elsewhere.mp4")
        media.walk()
        XCTAssertTrue(media.control.missing.contains(E.dawn))
        XCTAssertEqual(media.mediaEvents.filter { $0["op"] == .string("missing") },
                       [["type": .string("event"), "topic": .string("media"), "op": .string("missing"), "id": .string(E.dawn),
                         "missing": .bool(true), "seq": .number(Double(media.control.commandLog.lastSeq))]])
        try media.move(.mediaRoot, "../dawn-elsewhere.mp4", to: "backgrounds/dawn.mp4")
        media.walk()
        XCTAssertFalse(media.control.missing.contains(E.dawn))
        XCTAssertEqual(media.mediaEvents.filter { $0["op"] == .string("missing") }.last?["missing"], .bool(false))
        // An index reload: the machine index now points the announcement at a file that isn't there.
        let local = try XCTUnwrap(FileManager.default.contents(atPath: media.machineRoot.appendingPathComponent("media-local.json").path))
        let moved = String(decoding: local, as: UTF8.self).replacingOccurrences(of: "\"path\": \"announcement.png\"", with: "\"path\": \"gone.png\"")
        try Data(moved.utf8).write(to: media.machineRoot.appendingPathComponent("media-local.json"))
        media.engine.scanDisk()
        XCTAssertTrue(media.control.missing.contains(MediaFixture.announcement), "missing as soon as the index reloads")
        // The walk the reload asks for finds its bytes where they were: "If the entry's file goes ... the entry takes the copy's path."
        media.settle()
        XCTAssertEqual(media.control.machine.mediaLocal.entry(MediaFixture.announcement)?.path, "announcement.png")
        XCTAssertFalse(media.control.missing.contains(MediaFixture.announcement))
    }

    /// Spec 8 §11, The walk — "On a `readOnlyMasters` machine nothing in the
    /// library is written, and an unlisted file in the media root is left
    /// alone"; its own folder is indexed and written.
    func test_onAReadOnlyMachineTheLibraryIsntWritten() throws {
        media = try MediaFixture(writable: false)
        let before = try XCTUnwrap(FileManager.default.contents(atPath: media.libraryRoot.appendingPathComponent("media-index.json").path))
        try media.write(.mediaRoot, "unlisted.mov", "not in the synced index yet")
        try media.write(.mediaRoot, "backgrounds/dawn.mp4", "dawn, re-exported at a campus")
        try media.write(.machineMedia, "Campus.mov", "the campus's own")
        media.walk()
        XCTAssertEqual(FileManager.default.contents(atPath: media.libraryRoot.appendingPathComponent("media-index.json").path), before)
        XCTAssertNil(media.control.library.mediaIndex.entry(MediaFixture.id("not in the synced index yet")))
        XCTAssertEqual(media.control.library.mediaIndex.replaced, [:])
        XCTAssertTrue(media.control.missing.contains(E.dawn), "its file holds other bytes now")
        XCTAssertEqual(media.writtenLocal()?.entry(MediaFixture.id("the campus's own"))?.path, "Campus.mov")
    }

    // MARK: - Who follows it (Spec 8 §9)

    /// "the id set the OSC parser uses to expand abbreviated hashes" takes the
    /// current one: an item the walk indexed is reachable by its first 12 hex.
    func test_theOSCIdsFollowTheIndexes() throws {
        let server = OSCServer(port: 0, targets: [], mediaIDs: [], log: EngineLog(category: "test")) { _ in }
        try media.write(.mediaRoot, "imports/Late.mov", "arrived late")
        media.walk()
        let id = MediaFixture.id("arrived late")
        server.afterBuild(media.control, library: media.control.library, machine: media.control.machine)
        let short = String(id.prefix("sha256:".count + 12))
        let message = OSCMessage("/o/channel/1/write", [.string("media \(short)")])
        XCTAssertEqual(try OSCMapping.command(from: message, options: server.currentParseOptions).get(),
                       .channelWrite(ChannelWrite(channel: .number(1), content: .media(MediaContent(ref: id)))))
    }
}

extension MediaFixture {
    static let announcement = "sha256:fa3021eba9c15cb8aa65b79e04c0df3d5291d79d397e5930610248bab8d3e2e0"
}
