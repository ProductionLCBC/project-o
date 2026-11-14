import CoreGraphics
import Foundation
import OCore
import OFormats
import XCTest
@testable import OEngine

/// Spec 4 §5 — "Poster frame: BGRA8Unorm sRGB, Half the channel render size,
/// 1 per pool item, loaded on demand." Spec 8 §9 — "The poster loader reads
/// at the entry's location and caches by the poster's path, doesn't cache a
/// miss, reads an image as its own poster, and downsizes to half the channel
/// render size"; Spec 8 §5 — "a change under `.posters/` makes it look
/// again". And the plan's readings: loads off the control thread, a byte cap,
/// a released texture freed two plans later.
final class PosterLoaderTests: XCTestCase {
    typealias E = EngineFixtures
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-posters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".posters"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    var media: MediaFolders { MediaFolders(mediaRoot: folder, machineMedia: E.machineMediaRoot) }

    func writePNG(_ path: String, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        context.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        XCTAssertTrue(MediaImages.writePNG(try XCTUnwrap(context.makeImage()), to: folder.appendingPathComponent(path)))
    }

    func key(_ path: String, _ id: String = E.dawn) -> PosterKey {
        PosterKey(location: MediaLocation(.mediaRoot, path)!, id: id)
    }

    /// Which poster: a video's PNG beside it, an image's own file at its
    /// resolved location, none for audio or a video with none yet.
    func test_aPosterKeyIsTheVideosPosterOrTheImageItself() throws {
        let library = try E.library()
        let dawn = try XCTUnwrap(library.mediaIndex.entry(E.dawn))
        XCTAssertEqual(PosterKey.of(dawn, tier: .library, location: MediaLocation(.mediaRoot, dawn.path)),
                       PosterKey(location: MediaLocation(.mediaRoot, ".posters/\(String(E.dawn.dropFirst(7)))-0.png")!, id: E.dawn))
        var local = dawn
        local.poster = ".posters/x-0.png"
        XCTAssertEqual(PosterKey.of(local, tier: .machine, location: nil)?.location.folder, .machineMedia,
                       "relative to the same folder as its path")
        let cross = try XCTUnwrap(library.mediaIndex.entry(E.cross))
        let override = MediaLocation(.machineMedia, "cross-fast.png")!
        XCTAssertEqual(PosterKey.of(cross, tier: .library, location: override), PosterKey(location: override, id: E.cross),
                       "an image is its own poster, at the location it resolves to")
        var noPoster = dawn
        noPoster.poster = nil
        XCTAssertNil(PosterKey.of(noPoster, tier: .library, location: nil))
        let audio = MediaEntry(id: E.dawn, path: "a.wav", kind: .audio, size: 1, addedAt: "2026-11-01T09:00:00Z")
        XCTAssertNil(PosterKey.of(audio, tier: .library, location: MediaLocation(.mediaRoot, "a.wav")))
    }

    /// The control thread looks up and never waits: the first lookup asks
    /// and comes back `.none`; the loader's queue reads it; later lookups
    /// find it, read once.
    func test_aLookupNeverWaitsAndAPosterIsReadOnce() throws {
        let backend = try MetalHarness.backend()
        try writePNG(".posters/a-0.png", width: 1920, height: 1080)
        let loader = ImagePosterProvider(backend: backend, media: media, fit: PixelSize(width: 960, height: 540))
        let poster = key(".posters/a-0.png")
        XCTAssertTrue(loader.poster(poster).isNone, "asked for, not waited for")
        XCTAssertTrue(waitUntil(5) { !loader.poster(poster).isNone })
        let handle = loader.poster(poster)
        XCTAssertEqual(loader.poster(poster), handle)
        XCTAssertEqual(loader.loadCount, 1, "cached by its path")
        XCTAssertEqual(backend.resources.descriptor(handle)?.role, .poster)
        XCTAssertEqual(backend.resources.descriptor(handle)?.size, PixelSize(width: 960, height: 540), "half the channel render size")
    }

    /// "Half the channel render size": half the largest channel's; a small
    /// poster keeps its size; the thumbnail job's `load` waits for it.
    func test_postersAreFittedWithinHalfTheLargestChannel() throws {
        XCTAssertEqual(ImagePosterProvider.fit(channels: [PixelSize(width: 1920, height: 1080), PixelSize(width: 3840, height: 2160)]),
                       PixelSize(width: 1920, height: 1080))
        let backend = try MetalHarness.backend()
        try writePNG(".posters/small-0.png", width: 64, height: 36)
        try writePNG(".posters/tall-0.png", width: 1080, height: 1920)
        let loader = ImagePosterProvider(backend: backend, media: media, fit: PixelSize(width: 960, height: 540))
        let small = loader.load(key(".posters/small-0.png"))
        XCTAssertEqual(backend.resources.descriptor(small)?.size, PixelSize(width: 64, height: 36), "never made larger")
        let tall = loader.load(key(".posters/tall-0.png", E.cross))
        XCTAssertEqual(backend.resources.descriptor(tall)?.size, PixelSize(width: 304, height: 540), "its aspect kept")
    }

    /// "doesn't cache a miss ... a change under `.posters/` makes it look
    /// again": a poster that isn't there is looked for once until the
    /// change, then found.
    func test_aMissIsRememberedOnlyUntilPostersChange() throws {
        let backend = try MetalHarness.backend()
        let loader = ImagePosterProvider(backend: backend, media: media, synchronous: true)
        let poster = key(".posters/late-0.png")
        XCTAssertTrue(loader.poster(poster).isNone)
        XCTAssertTrue(loader.poster(poster).isNone)
        XCTAssertEqual(loader.loadCount, 1, "not looked for again on every build")
        try writePNG(".posters/late-0.png", width: 64, height: 36)
        XCTAssertTrue(loader.poster(poster).isNone, "until the change is said")
        loader.postersChanged()
        XCTAssertFalse(loader.poster(poster).isNone, "found once .posters/ changed")
    }

    /// "reads an image as its own poster": the image's own file, fitted.
    func test_anImageIsItsOwnPoster() throws {
        let backend = try MetalHarness.backend()
        let loader = ImagePosterProvider(backend: backend, media: E.media, synchronous: true)
        let cross = PosterKey(location: MediaLocation(.mediaRoot, "backgrounds/cross.png")!, id: E.cross)
        let handle = loader.poster(cross)
        XCTAssertFalse(handle.isNone)
        XCTAssertEqual(backend.resources.descriptor(handle)?.size, PixelSize(width: 64, height: 36))
    }

    /// Past the byte cap, posters no build has asked for in two seconds go,
    /// least recently asked first; the resource table frees each two plans
    /// later; a poster that went is read again when asked for.
    func test_pastTheCapUnaskedPostersGo() throws {
        let backend = try MetalHarness.backend()
        for name in ["a", "b", "c"] { try writePNG(".posters/\(name)-0.png", width: 64, height: 36) }
        let loader = ImagePosterProvider(backend: backend, media: media, cap: 2 * 64 * 36 * 4, synchronous: true)
        let a = loader.poster(key(".posters/a-0.png", "a"))
        backend.resources.sweep(consumedTick: 10)
        _ = loader.poster(key(".posters/b-0.png", "b"))
        backend.resources.sweep(consumedTick: 200)
        _ = loader.poster(key(".posters/b-0.png", "b"))
        let pending = backend.resources.pendingRelease
        _ = loader.poster(key(".posters/c-0.png", "c"))
        XCTAssertEqual(backend.resources.pendingRelease, pending + 1, "a, unasked for two seconds, went; b was just asked for")
        XCTAssertEqual(loader.bytesHeld, 2 * 64 * 36 * 4)
        XCTAssertNotNil(backend.resources.descriptor(a), "not freed until two plans later")
        backend.resources.sweep(consumedTick: 203)
        XCTAssertNil(backend.resources.descriptor(a), "freed once the plans that could name it were consumed")
        let loads = loader.loadCount
        XCTAssertFalse(loader.poster(key(".posters/a-0.png", "a")).isNone)
        XCTAssertEqual(loader.loadCount, loads + 1, "read again when asked for")
    }
}
