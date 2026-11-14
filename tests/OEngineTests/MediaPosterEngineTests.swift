import CoreGraphics
import Foundation
import ImageIO
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 8 §5 — posters and pool tiles in the engine, on a temporary copy of
/// the fixture, with the frames as a seam (`FakeMediaFrames`; the real
/// extraction is `MediaFramesTests`'). Spec 8 §11, Posters: "The frame at the
/// default in-point, fitted within 1920 × 1080, with alpha when the video has
/// it, at `.posters/<hex>-<in>.png` beside its media. A `defaults.trimInMs`
/// edit gives a new poster under a new name ... A poster that arrives after
/// its entry shows, in its tile ..., without a relaunch. Images are their own
/// poster, audio has none, and only a writable machine writes library
/// posters." Tiles: "480 px wide, from the poster or the image; none for
/// audio; a new tile with a new poster." Spec 8 §7 — the import's `poster` state.
final class MediaPosterEngineTests: XCTestCase {
    typealias E = EngineFixtures
    var media: MediaFixture!

    override func setUpWithError() throws {
        media = try MediaFixture()
    }

    override func tearDown() {
        media = nil
    }

    static func hex(_ id: String) -> String { String(id.dropFirst(7)) }

    func tileSize(_ name: String) -> (width: Int, height: Int)? {
        MediaFixture.size(of: media.machineRoot.appendingPathComponent("thumbnails/pool/\(name)"))
    }

    /// Spec 8 §3, step 5 — "extracts the poster (§5), writes the entry ...
    /// and makes the pool tile"; Spec 8 §7 — "one event per file as a job
    /// moves through hashing, copying, reading and the poster".
    func test_anImportedVideoGetsItsPosterAtTheInPointAndItsTile() throws {
        media.frames.size = (3840, 2160)
        let staged = try media.stage("Welcome.mov", "welcome video bytes")
        XCTAssertNil(media.importPath(staged))
        let id = MediaFixture.id("welcome video bytes")
        let poster = ".posters/\(Self.hex(id))-0.png"
        let entry = try XCTUnwrap(media.control.library.mediaIndex.entry(id))
        XCTAssertEqual(entry.poster, poster, "the entry is written with its poster")
        XCTAssertEqual(media.frames.asked, [FakeMediaFrames.Ask(file: "Welcome.mov", inMs: 0, alpha: false)],
                       "the frame at the default in-point, 0 for a new item's empty defaults")
        let size = try XCTUnwrap(MediaFixture.size(of: media.url(.mediaRoot, poster)))
        XCTAssertEqual(size.width, 1920, "fitted within 1920 × 1080")
        XCTAssertEqual(size.height, 1080)
        let job = try XCTUnwrap(media.jobs.last)
        XCTAssertEqual(media.events(ofJob: job).compactMap { $0["state"]?.stringValue }.filter { $0 != "hashing" && $0 != "copying" },
                       ["reading", "poster", "done"])
        XCTAssertEqual(media.mediaLibraryEvents.count, 1, "one index change: the entry with its poster")
        // The tile, 480 px wide, from the poster.
        XCTAssertTrue(media.tiles.contains("\(Self.hex(id))-0.png"))
        XCTAssertEqual(tileSize("\(Self.hex(id))-0.png")?.width, 480)
        XCTAssertEqual(tileSize("\(Self.hex(id))-0.png")?.height, 270)
        XCTAssertTrue(media.control.mediaTiles.contains("\(Self.hex(id))-0.png"))
        XCTAssertTrue(media.control.posterFiles.contains(MediaLocation(.mediaRoot, poster)!))
    }

    /// "with alpha when the video has it": the frame is asked for with its
    /// alpha, and the PNG keeps it.
    func test_aPosterKeepsAlphaWhenTheVideoHasIt() throws {
        let staged = try media.stage("Lower third.mov", "a video with alpha")
        media.importPath(staged)
        let id = MediaFixture.id("a video with alpha")
        // The fake probe reads no alpha; the entry says so, as the real probe would for ProRes 4444.
        XCTAssertEqual(media.frames.asked.last?.alpha, false)
        var index = media.control.library.mediaIndex
        let i = try XCTUnwrap(index.position(of: id))
        index.entries[i].hasAlpha = true
        index.entries[i].poster = nil
        try media.removeFile(.mediaRoot, ".posters/\(Self.hex(id))-0.png")
        try media.writeIndex(index)
        media.engine.scanDisk()
        media.settle()
        XCTAssertEqual(media.frames.asked.last, FakeMediaFrames.Ask(file: "Lower third.mov", inMs: 0, alpha: true))
        let url = media.url(.mediaRoot, ".posters/\(Self.hex(id))-0.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(media.control.library.mediaIndex.entry(id)?.poster, ".posters/\(Self.hex(id))-0.png")
    }

    /// "by the walk when one is missing": a poster removed by hand is made
    /// again at the entry's in-point, and a new file the walk finds gets one;
    /// "Who. The machine that writes the entry's index".
    func test_theWalkMakesMissingPostersWhereTheMachineWritesTheIndex() throws {
        let dawnPoster = ".posters/\(Self.hex(E.dawn))-0.png"
        try media.removeFile(.mediaRoot, dawnPoster)
        try media.write(.mediaRoot, "imports/Sermon.mp4", "sermon bumper")
        media.walk()
        XCTAssertTrue(media.exists(.mediaRoot, dawnPoster), "made again")
        XCTAssertTrue(media.frames.asked.contains(FakeMediaFrames.Ask(file: "dawn.mp4", inMs: 0, alpha: false)))
        let sermon = MediaFixture.id("sermon bumper")
        XCTAssertEqual(media.control.library.mediaIndex.entry(sermon)?.poster, ".posters/\(Self.hex(sermon))-0.png")
        XCTAssertTrue(media.engine.log.contains("media: the poster of \(sermon) (library) is .posters/"), "logged by id")
        // The poster's index change is one more `library` event, cause `media`.
        XCTAssertEqual(media.mediaLibraryEvents.last?["changed"],
                       .array([.object(["object": .string("media"), "media": .string(sermon), "paths": .array([.string("poster")])])]))
        // Written like any change: a second after the entry's own write (Spec 5 §2).
        for _ in 0..<70 { media.engine.tick() }
        media.engine.waitForWrites()
        XCTAssertEqual(media.writtenIndex()?.entry(sermon)?.poster, ".posters/\(Self.hex(sermon))-0.png", "and written")
    }

    func test_aReadOnlyMachineNeverWritesALibraryPoster() throws {
        media = try MediaFixture(writable: false)
        let dawnPoster = ".posters/\(Self.hex(E.dawn))-0.png"
        try media.removeFile(.mediaRoot, dawnPoster)
        try media.write(.machineMedia, "Campus.mov", "the campus's own video")
        media.walk()
        XCTAssertFalse(media.exists(.mediaRoot, dawnPoster), "library posters are written only on a writable machine")
        XCTAssertFalse(media.frames.asked.contains { $0.file == "dawn.mp4" })
        let campus = MediaFixture.id("the campus's own video")
        let poster = ".posters/\(Self.hex(campus))-0.png"
        XCTAssertEqual(media.control.machine.mediaLocal.entry(campus)?.poster, poster)
        XCTAssertTrue(media.exists(.machineMedia, poster), "in machine/media/ for local-only media")
    }

    /// "after an edit changes `defaults.trimInMs`. The new in-point gives the
    /// poster a new name ... The old file goes once the new one is written";
    /// "a new tile with a new poster". (The edit itself, `edit media … defaults.trimInMs`,
    /// sets the new name; here the index changes on disk, as a sync brings it.)
    func test_aNewInPointGivesANewPosterAndTileAndTheOldOnesGo() throws {
        let hex = Self.hex(E.dawn)
        XCTAssertTrue(media.tiles.contains("\(hex)-0.png"), "made at launch from the fixture's poster")
        var index = media.control.library.mediaIndex
        let i = try XCTUnwrap(index.position(of: E.dawn))
        index.entries[i].defaults.trimInMs = 1500
        try media.writeIndex(index)
        media.engine.scanDisk()
        media.settle()
        XCTAssertEqual(media.frames.asked.last, FakeMediaFrames.Ask(file: "dawn.mp4", inMs: 1500, alpha: false))
        XCTAssertEqual(media.control.library.mediaIndex.entry(E.dawn)?.poster, ".posters/\(hex)-1500.png")
        XCTAssertTrue(media.exists(.mediaRoot, ".posters/\(hex)-1500.png"))
        XCTAssertFalse(media.exists(.mediaRoot, ".posters/\(hex)-0.png"), "the old file goes once the new one is written")
        XCTAssertTrue(media.tiles.contains("\(hex)-1500.png"))
        XCTAssertFalse(media.tiles.contains("\(hex)-0.png"), "the new tile replaces the old")
    }

    /// "it's null until extracted, and when extraction fails, which is
    /// reported"; a failure isn't tried again until its file changes.
    func test_aFailedExtractionLeavesThePosterNullAndIsReported() throws {
        let staged = try media.stage("Broken.mov", "NO FRAME in this video")
        media.importPath(staged)
        let id = MediaFixture.id("NO FRAME in this video")
        XCTAssertNotNil(media.control.library.mediaIndex.entry(id))
        XCTAssertNil(media.control.library.mediaIndex.entry(id)?.poster)
        XCTAssertTrue(media.engine.log.contains("no poster"))
        XCTAssertEqual(media.outcomes.last?["outcome"], .string("imported"), "the import itself stands")
        let asked = media.frames.asked.count
        media.walk()
        XCTAssertEqual(media.frames.asked.count, asked, "not tried again while its file is the same")
        XCTAssertFalse(media.tiles.contains { $0.hasPrefix(Self.hex(id)) }, "no poster, no tile")
    }

    /// "Only video has a poster file: an image is its own poster ..., and
    /// audio has none"; tiles "made from ... the image for an image. Audio has
    /// no tile".
    func test_imagesAreTheirOwnPosterAndAudioHasNone() throws {
        try media.writePNG(.mediaRoot, "imports/Announcement.png", width: 960, height: 540)
        try media.write(.mediaRoot, "imports/Bell.wav", "a bell")
        media.walk()
        let image = try XCTUnwrap(media.control.library.mediaIndex.entries.first { $0.path == "imports/Announcement.png" })
        XCTAssertNil(image.poster)
        let tile = "\(Self.hex(image.id))-0.png"
        XCTAssertTrue(media.tiles.contains(tile), "`<in>` is 0 for an image")
        XCTAssertEqual(tileSize(tile)?.width, 480)
        XCTAssertEqual(tileSize(tile)?.height, 270)
        let bell = MediaFixture.id("a bell")
        XCTAssertNil(media.control.library.mediaIndex.entry(bell)?.poster)
        XCTAssertFalse(media.tiles.contains { $0.hasPrefix(Self.hex(bell)) })
        XCTAssertFalse(media.frames.asked.contains { $0.file == "Announcement.png" || $0.file == "Bell.wav" })
        // The fixture's own images, in both folders, have their tiles too.
        XCTAssertTrue(media.tiles.contains("\(Self.hex(E.cross))-0.png"))
        XCTAssertTrue(media.tiles.contains("\(Self.hex(MediaFixture.announcement))-0.png"))
    }

    /// "a poster that arrives by sync after its entry appears without a
    /// relaunch": on a `readOnlyMasters` machine the library's poster arrives
    /// in `.posters/`; the walk's look sees it and its tile is drawn.
    func test_aPosterThatArrivesAfterItsEntryGetsItsTile() throws {
        media = try MediaFixture(writable: false)
        let hex = Self.hex(E.mountains)
        let poster = ".posters/\(hex)-1500.png"
        XCTAssertFalse(media.control.posterFiles.contains(MediaLocation(.mediaRoot, poster)!))
        XCTAssertFalse(media.tiles.contains("\(hex)-1500.png"))
        try media.writePNG(.mediaRoot, poster, width: 1920, height: 1080)
        media.walk()
        XCTAssertTrue(media.control.posterFiles.contains(MediaLocation(.mediaRoot, poster)!), "a change under .posters/ is seen")
        XCTAssertTrue(media.tiles.contains("\(hex)-1500.png"), "its tile is drawn, though the video itself is still missing")
        XCTAssertEqual(tileSize("\(hex)-1500.png")?.width, 480)
    }
}

extension MediaFixture {
    func removeFile(_ folder: MediaFolder, _ path: String) throws {
        try FileManager.default.removeItem(at: url(folder, path))
    }

    /// The library index written to disk as a hand edit or a sync would.
    func writeIndex(_ index: MediaIndex) throws {
        try Writer.data(for: .mediaIndex(index)).write(to: libraryRoot.appendingPathComponent("media-index.json"))
    }
}
