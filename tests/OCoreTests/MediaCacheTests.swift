import Foundation
import XCTest
@testable import OCore

/// Spec 8 §4 — "The cache. `machine/media-cache.json` holds a record for
/// every file the engine has hashed: its folder (the media root or
/// `machine/media/`), path, size, modification date and hash. It starts with
/// the header every document has (Spec 1 §5), with kind `mediaCache`, and the
/// loader leaves it alone. A file whose size and date match its record isn't
/// hashed again".
final class MediaCacheTests: XCTestCase {
    typealias F = FixtureLibrary

    static let cache = MediaCache(records: [
        MediaCacheRecord(location: MediaLocation(.machineMedia, "announcement.png")!, size: 160, modified: "2026-11-11T09:00:00.123456789Z", hash: F.announcement),
        MediaCacheRecord(location: MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!, size: 1292, modified: "2026-11-11T09:00:01Z", hash: F.dawn),
        MediaCacheRecord(location: MediaLocation(.mediaRoot, "slides/welcome.oslide")!, size: 412, modified: "2026-11-11T09:00:02Z", hash: F.welcomeSlide),
    ])

    func test_theCacheIsADocumentTheLoaderLeavesAlone() throws {
        let data = Writer.data(for: .mediaCache(Self.cache))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\": \"mediaCache\""))
        let loaded = try Loader.document(path: "media-cache.json", data: data)
        XCTAssertEqual(loaded.body, .mediaCache(Self.cache))
        XCTAssertEqual(Writer.data(for: loaded), data, "it round-trips byte for byte")
        // The schema describes it.
        let schema = try JSONValue.parse(try XCTUnwrap(FileManager.default.contents(atPath: F.schemasRoot.appendingPathComponent("media-cache.schema.json").path)))
        XCTAssertEqual(MiniSchema.validate(try JSONValue.parse(data), against: schema), [])
        // "the loader leaves it alone": a machine root holding it loads as without it, and reports nothing.
        var snapshot = F.machineSnapshot
        let plain = Loader.machine(from: snapshot)
        snapshot.files["media-cache.json"] = data
        let withCache = Loader.machine(from: snapshot)
        XCTAssertEqual(withCache.machine, plain.machine)
        XCTAssertEqual(withCache.report.issues, plain.report.issues)
    }

    /// Records are kept by location in order, one per location, and a lookup
    /// matches on size and date ("A file whose size and date match its record
    /// isn't hashed again").
    func test_aRecordMatchesOnSizeAndDate() {
        let cache = MediaCache(records: Self.cache.records.reversed() + [
            MediaCacheRecord(location: MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!, size: 1, modified: "later", hash: F.cross),
        ])
        XCTAssertEqual(cache.records.map(\.location.path), ["backgrounds/dawn.mp4", "slides/welcome.oslide", "announcement.png"])
        XCTAssertEqual(cache.records.first?.hash, F.cross, "the last record for a location wins")
        let dawn = MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!
        XCTAssertEqual(cache.hash(at: dawn, size: 1, modified: "later"), F.cross)
        XCTAssertNil(cache.hash(at: dawn, size: 1, modified: "earlier"))
        XCTAssertNil(cache.hash(at: dawn, size: 2, modified: "later"))
        XCTAssertNil(cache.hash(at: MediaLocation(.machineMedia, "backgrounds/dawn.mp4")!, size: 1, modified: "later"))
        XCTAssertEqual(cache.lastSeen[MediaLocation(.machineMedia, "announcement.png")!], F.announcement)
    }
}
