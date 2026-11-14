import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §6 — `media delete` and `media undelete` in the engine, on a
/// temporary copy of the fixture, the Trash a seam (`FakeTrash`). Spec 8 §11,
/// Delete: "Every copy goes to the Trash and the entry stays, deleted and
/// pathless, with its references missing. An item on air is refused with
/// `onAir`, also when a channel plays it through a replaced id, still plays
/// its file after a replace, or a reader holds it prefetched; a volume with
/// no Trash refuses with `noTrash`; a move that fails, or an item that goes
/// on air while its files move, leaves everything in place. A group holding
/// several deletes applies whole, or puts every file back. `media undelete`
/// brings the files and the entry back, never over a file now at one of
/// their paths, and fails with `conflict` once the Trash is emptied (Area 12
/// for the undo). A `readOnlyMasters` machine refuses library items." And
/// Adam's answer of 2026-11-11 (7): runtime commands run while a delete's
/// files move; edits and media commands wait behind it.
final class MediaDeleteEngineTests: XCTestCase {
    typealias E = EngineFixtures
    var media: MediaFixture!

    override func setUpWithError() throws {
        media = try MediaFixture()
    }

    override func tearDown() {
        media?.trash.release()
        media = nil
    }

    var crossFiles: [(MediaFolder, String)] { [(.machineMedia, "cross-fast.png"), (.mediaRoot, "backgrounds/cross.png")] }

    func entry(_ id: String) -> MediaEntry? {
        MediaResolver.entry(for: id, library: media.control.library.mediaIndex, machine: media.control.machine.mediaLocal)?.entry
    }

    /// Ticks past the writer's one-second spacing (Spec 5 §2), then waits for it.
    func flush() {
        for _ in 0..<70 { media.engine.tick() }
        media.settle()
    }

    // MARK: - Delete and its inverse

    /// "Every copy goes to the Trash and the entry stays, deleted and
    /// pathless, with its references missing"; "the command is logged with
    /// where each file came from and where the Trash put it"; its inverse
    /// brings the files and the entry back.
    func test_aDeleteTrashesEveryCopyAndItsInverseBringsThemBack() throws {
        flush()
        let indexBefore = try XCTUnwrap(FileManager.default.contents(atPath: media.libraryRoot.appendingPathComponent("media-index.json").path))
        let revision = media.control.revision
        media.library.clear()
        XCTAssertNil(media.run("media delete \(E.cross)"))
        for (folder, path) in crossFiles { XCTAssertFalse(media.exists(folder, path), "\(path) went to the Trash") }
        XCTAssertEqual(media.trash.contents, ["cross-fast.png", "cross.png"], "the override's target and the identical copy")
        let deleted = try XCTUnwrap(entry(E.cross))
        XCTAssertNotNil(deleted.deletedAt)
        XCTAssertEqual(deleted.path, "", "the entry stays, deleted and pathless")
        XCTAssertTrue(media.control.missing.contains(E.cross), "its references show missing")
        let line = try XCTUnwrap(media.control.commandLog.entries.last)
        XCTAssertEqual(line.kind, .edit)
        XCTAssertEqual(line.result, .ok)
        guard case .media(.delete(let id, let files?)) = line.command else { return XCTFail("logged with its files: \(line.text)") }
        XCTAssertEqual(id, E.cross)
        XCTAssertEqual(Set(files.map(\.location)), Set(crossFiles.map { MediaLocation($0.0, $0.1)! }))
        XCTAssertTrue(files.allSatisfy { $0.trash.hasPrefix(media.trash.folder.path) }, "and where the Trash put each")
        XCTAssertEqual(line.inverse, .media(.undelete(id: E.cross, files: files)))
        XCTAssertEqual(media.control.revision, revision + 1)
        XCTAssertEqual(media.library.all.filter { $0["cause"] == .string("edit") }.count, 1, "one library event, cause edit")

        // The inverse: "moves the files back to where they came from and clears `deletedAt`".
        let inverse = try XCTUnwrap(line.inverse.flatMap(CommandText.print))
        XCTAssertNil(media.run(inverse))
        for (folder, path) in crossFiles { XCTAssertTrue(media.exists(folder, path), "\(path) is back") }
        XCTAssertEqual(media.trash.contents, [])
        XCTAssertNil(entry(E.cross)?.deletedAt)
        XCTAssertEqual(entry(E.cross)?.path, "backgrounds/cross.png")
        XCTAssertFalse(media.control.missing.contains(E.cross))
        XCTAssertEqual(media.control.commandLog.entries.last?.inverse, .media(.delete(id: E.cross, files: nil)))
        flush()
        XCTAssertEqual(FileManager.default.contents(atPath: media.libraryRoot.appendingPathComponent("media-index.json").path), indexBefore,
                       "the index byte for byte")
    }

    /// "It never overwrites a file now at one of those paths, giving the
    /// restored one a numbered name instead ... if the Trash has been
    /// emptied, the undo fails with `conflict`."
    func test_undeleteNeverWritesOverAFileAndFailsOnceTheTrashIsEmptied() throws {
        XCTAssertNil(media.run("media delete \(MediaFixture.announcement)"))
        let line = try XCTUnwrap(media.control.commandLog.entries.last)
        let inverse = try XCTUnwrap(line.inverse.flatMap(CommandText.print))
        try media.write(.machineMedia, "announcement.png", "another file, saved since")
        XCTAssertNil(media.run(inverse))
        XCTAssertEqual(try String(contentsOf: media.url(.machineMedia, "announcement.png"), encoding: .utf8), "another file, saved since",
                       "never over a file")
        XCTAssertTrue(media.exists(.machineMedia, "announcement 2.png"))
        XCTAssertEqual(entry(MediaFixture.announcement)?.path, "announcement 2.png")
        XCTAssertFalse(media.control.missing.contains(MediaFixture.announcement))

        // Once the Trash is emptied.
        XCTAssertNil(media.run("media delete \(MediaFixture.announcement)"))
        let again = try XCTUnwrap(media.control.commandLog.entries.last?.inverse.flatMap(CommandText.print))
        media.trash.empty()
        XCTAssertEqual(media.run(again)?.reason, .conflict)
        XCTAssertNotNil(entry(MediaFixture.announcement)?.deletedAt, "still deleted")
    }

    // MARK: - On air (Spec 8 §6, step 1)

    func test_anItemOnAirIsRefusedAndNothingMoves() throws {
        // Its channel's content.
        XCTAssertNil(media.run("channel 1 write media \(E.dawn)"))
        XCTAssertEqual(media.run("media delete \(E.dawn)")?.reason, .onAir)
        XCTAssertTrue(media.exists(.mediaRoot, "backgrounds/dawn.mp4"))
        XCTAssertEqual(media.trash.moveCount, 0, "nothing moved")
        // "still plays its file after a replace": the channel opened dawn; a replace points it elsewhere.
        let staged = try media.stage("Dawn v2.mp4", "dawn, version two")
        XCTAssertNil(media.importPath(staged))
        let v2 = MediaFixture.id("dawn, version two")
        XCTAssertNil(media.run("media replace \(E.dawn) \(v2)"))
        XCTAssertEqual(media.run("media delete \(E.dawn)")?.reason, .onAir, "the channel keeps the file it opened at its write")
        // "plays it through a replaced id": a write of dawn now resolves to v2.
        XCTAssertNil(media.run("channel 2 write media \(E.dawn)"))
        XCTAssertEqual(media.run("media delete \(v2)")?.reason, .onAir)
        XCTAssertEqual(media.trash.moveCount, 0)
    }

    /// "... or a reader holds it prefetched".
    func test_anItemAPrefetchedReaderHoldsIsOnAir() throws {
        let cross = try XCTUnwrap(entry(MediaFixture.announcement))
        let url = media.url(.machineMedia, "announcement.png")
        media.engine.fakeSources?.prefetch(SourceRequest(url: url, entry: cross, inMs: 0, outMs: nil, loop: false, handle: InstanceHandle(rawValue: 0)))
        XCTAssertEqual(media.run("media delete \(MediaFixture.announcement)")?.reason, .onAir)
        XCTAssertTrue(media.exists(.machineMedia, "announcement.png"))
    }

    // MARK: - Moves that fail

    /// "A file on a volume with no Trash is refused with `noTrash`"; "If one
    /// move fails, the files already moved go back and the delete is rejected."
    func test_noTrashAndAFailedMoveLeaveEverythingInPlace() throws {
        media.trash.refuse(["cross.png"])
        XCTAssertEqual(media.run("media delete \(E.cross)")?.reason, .noTrash)
        for (folder, path) in crossFiles { XCTAssertTrue(media.exists(folder, path), "\(path) in place") }
        XCTAssertEqual(media.trash.contents, [])
        XCTAssertNil(entry(E.cross)?.deletedAt)
        media.trash.refuse([])
        media.trash.fail(["cross.png"])
        XCTAssertEqual(media.run("media delete \(E.cross)")?.reason, .conflict)
        for (folder, path) in crossFiles { XCTAssertTrue(media.exists(folder, path), "\(path) in place") }
        XCTAssertFalse(media.control.missing.contains(E.cross), "it never turned missing")
    }

    /// "If the item went on air while its files moved, they go back and the
    /// delete is refused with `onAir`"; a write of it meanwhile lands, and its
    /// file opens once the files are back.
    func test_anItemThatGoesOnAirWhileItsFilesMoveIsRefused() throws {
        media.trash.hold()
        XCTAssertNil(media.engine.send("media delete \(MediaFixture.announcement)", source: .ui))
        media.engine.tick()
        XCTAssertNotNil(media.control.mediaPark, "parked while its files move")
        XCTAssertNil(media.engine.send("channel 2 write media \(MediaFixture.announcement)", source: .ui))
        media.engine.tick()
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.ref, MediaFixture.announcement, "a runtime command runs meanwhile")
        XCTAssertEqual(media.engine.sources(onChannel: 2), [], "its file doesn't open while it moves")
        media.trash.release()
        media.settle()
        XCTAssertEqual(media.control.rejections.last?.reason, .onAir)
        XCTAssertTrue(media.exists(.machineMedia, "announcement.png"), "the file went back")
        XCTAssertNil(entry(MediaFixture.announcement)?.deletedAt)
        XCTAssertEqual(media.engine.sources(onChannel: 2).count, 1, "and the write's file opens once it is back")
    }

    // MARK: - Groups

    /// "A group that holds a `media delete` ... is validated whole; then every
    /// file it deletes moves; then the checks run again, and the group applies
    /// in one step. Any failure puts every moved file back and rejects the group."
    func test_aGroupOfDeletesAppliesWholeOrPutsEveryFileBack() throws {
        media.trash.refuse(["announcement.png"])
        XCTAssertNil(media.engine.send(group: ["media delete \(E.cross)", "media delete \(MediaFixture.announcement)"], source: .ui))
        media.settle()
        XCTAssertEqual(media.control.rejections.last?.reason, .noTrash)
        for (folder, path) in crossFiles { XCTAssertTrue(media.exists(folder, path), "\(path) back in place") }
        XCTAssertNil(entry(E.cross)?.deletedAt)
        media.trash.refuse([])
        let revision = media.control.revision
        XCTAssertNil(media.engine.send(group: ["media delete \(E.cross)", "media delete \(MediaFixture.announcement)"], source: .ui))
        media.settle()
        XCTAssertNotNil(entry(E.cross)?.deletedAt)
        XCTAssertNotNil(entry(MediaFixture.announcement)?.deletedAt)
        XCTAssertEqual(media.trash.contents.count, 3)
        XCTAssertEqual(media.control.revision, revision + 1, "in one step")
    }

    /// "Library mode and operator lock apply (§2)": a `readOnlyMasters`
    /// machine refuses library items and deletes its own.
    func test_aReadOnlyMachineRefusesLibraryItems() throws {
        media = try MediaFixture(writable: false)
        XCTAssertEqual(media.run("media delete \(E.cross)")?.reason, .readOnlyLibrary)
        XCTAssertNil(media.run("media delete \(MediaFixture.announcement)"))
        XCTAssertNotNil(entry(MediaFixture.announcement)?.deletedAt)
    }

    // MARK: - Held deletes and the gate (Spec 8 §2, Adam's answer 7)

    /// "A delete held in a cue ... lets the rest of its group run at once.
    /// The delete applies after its files move, or is logged `blocked`. The
    /// group's one `library` event waits for it."
    func test_aHeldDeleteAppliesAfterTheRestOfItsGroupAndARefusalIsBlocked() throws {
        var library = media.control.library
        let list = try XCTUnwrap(library.lists.firstIndex { $0.number == 7 })
        library.lists[list].cues[1].commands = [
            GuardedCommand(.media(.delete(id: MediaFixture.announcement, files: nil))),
            GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .media(MediaContent(ref: E.cross))))),
        ]
        library.lists[list].cues[2].commands = [GuardedCommand(.media(.delete(id: E.cross, files: nil)))]
        try media.writeList(library.lists[list])
        media.engine.scanDisk()
        media.settle()
        media.library.clear()
        media.trash.hold()
        XCTAssertNil(media.engine.send("list 7 cue 2", source: .ui))
        media.engine.tick()
        XCTAssertEqual(media.engine.state.channels[2]?.content.media?.ref, E.cross, "the rest of the group ran at once")
        XCTAssertNil(entry(MediaFixture.announcement)?.deletedAt, "the delete waits for its files")
        XCTAssertEqual(media.library.all.filter { $0["cause"] == .string("edit") }.count, 0, "and so does the group's event")
        media.trash.release()
        media.settle()
        XCTAssertNotNil(entry(MediaFixture.announcement)?.deletedAt, "applied once its files moved")
        let deleteLine = try XCTUnwrap(media.control.commandLog.entries.last)
        XCTAssertEqual(deleteLine.result, .ok)
        XCTAssertEqual(deleteLine.source.kind, .cue)
        XCTAssertEqual(media.library.all.filter { $0["cause"] == .string("edit") }.count, 1, "the group's one event")
        // Cross is on air on channel 2 now: a cue holding its delete runs, the delete blocked.
        XCTAssertNil(media.run("list 7 cue 3"))
        XCTAssertEqual(media.control.commandLog.entries.last?.result, .blocked)
        XCTAssertEqual(media.control.commandLog.entries.last?.command, .media(.delete(id: E.cross, files: nil)))
        XCTAssertTrue(media.engine.log.contains("blocked cue edit media delete \(E.cross): onAir"))
        for (folder, path) in crossFiles { XCTAssertTrue(media.exists(folder, path)) }
    }

    /// Adam's answer of 2026-11-11 (7) — "runtime commands run; queued edits
    /// and media commands ... wait behind a parked delete", so every edit
    /// applies in the order it arrived.
    func test_editsAndMediaCommandsWaitBehindAParkedDelete() throws {
        media.trash.hold()
        XCTAssertNil(media.engine.send("media delete \(MediaFixture.announcement)", source: .ui))
        media.engine.tick()
        XCTAssertNil(media.engine.send("media replace \(E.mountains) \(E.dawn)", source: .ui))
        XCTAssertNil(media.engine.send("channel 1 write media \(E.dawn)", source: .ui))
        media.engine.tick()
        XCTAssertEqual(media.engine.state.channels[1]?.content.media?.ref, E.dawn, "the runtime command ran")
        XCTAssertNil(media.control.library.mediaIndex.replaced[E.mountains], "the replace waits")
        media.trash.release()
        media.settle()
        XCTAssertEqual(media.control.library.mediaIndex.replaced[E.mountains], E.dawn, "then applies")
        let lines = media.control.commandLog.entries.filter { $0.kind == .edit }.suffix(2).map(\.command)
        XCTAssertEqual(lines.first?.cmd, "media.delete", "in the order they arrived")
        XCTAssertEqual(lines.last?.cmd, "media.replace")
    }

    /// The plan's reading — "Any failure, or no report within ten seconds,
    /// puts every moved file back and rejects the group with ... `conflict`".
    func test_aParkThatHearsNothingForTenSecondsGivesUpAndTheFilesGoBack() throws {
        media.control.mediaParkTimeout = 100_000_000
        media.trash.hold()
        XCTAssertNil(media.engine.send("media delete \(MediaFixture.announcement)", source: .ui))
        for _ in 0..<12 { media.engine.tick() }
        XCTAssertEqual(media.control.rejections.last?.reason, .conflict)
        XCTAssertNil(media.control.mediaPark)
        media.trash.release()
        media.settle()
        XCTAssertTrue(media.exists(.machineMedia, "announcement.png"), "the late move went back")
        XCTAssertNil(entry(MediaFixture.announcement)?.deletedAt)
    }
}
