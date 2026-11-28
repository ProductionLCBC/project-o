import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OAppUI

/// Spec 11 §3 — "The files. `machine/thumbnails/render/` ..., keeping each canvas's newest two": every picture edit
/// mode asks for is a new file, and a grade's video playing (G-43) asks for several a second, so the app keeps only
/// the newest sixteen of them, enough for a connection's eight canvases; other pictures stay as they were.
@MainActor
final class PictureStoreTests: XCTestCase {
    /// A one-pixel PNG at `path` under `folder`.
    func png(_ path: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(path)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func test_onlyTheNewestEditModePicturesAreKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-pictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("thumbnails/render"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PictureStore()
        let tile = try png("tile.png", in: folder)
        let renders = try (0..<20).map { try png("thumbnails/render/c1-grade-\($0).png", in: folder) }
        let read = expectation(description: "every picture read")
        read.expectedFulfillmentCount = 21
        for url in [tile] + renders { _ = store.picture(at: url) { _ in read.fulfill() } }
        wait(for: [read], timeout: 10)
        XCTAssertEqual(store.rendersHeld, PictureStore.rendersKept)
        XCTAssertNotNil(store.picture(at: tile) { _ in }, "a picture that isn't edit mode's stays")
    }

    /// Spec 4 §10 — a cue thumbnail is "one file per cue named by its uuid and the library version, a stale version
    /// removed when the new one is written". Typing in the text editor makes a new version of a cue and of every cue
    /// after it a few times a second (Spec 11 §5), so a version read before is forgotten when its cue's next is read.
    func test_aCueThumbnailsOlderVersionsAreForgottenWhenANewerOneIsRead() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-pictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("thumbnails/1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = PictureStore()
        let cue = "22bb0000-0000-4000-8000-000000000002"
        let other = "33cc0000-0000-4000-8000-000000000003"
        let versions = try (0..<5).map { try png("thumbnails/1/\(cue)-v\($0)abc.png", in: folder) }
        let neighbour = try png("thumbnails/1/\(other)-v0abc.png", in: folder)
        for url in versions + [neighbour] {
            let read = expectation(description: url.lastPathComponent)
            _ = store.picture(at: url) { _ in read.fulfill() }
            wait(for: [read], timeout: 10)
        }
        XCTAssertEqual(store.thumbnailsHeld, 2, "the cue's newest version, and the other cue's")
        XCTAssertNotNil(store.picture(at: versions[4]) { _ in })
        XCTAssertNotNil(store.picture(at: neighbour) { _ in })
        XCTAssertNil(store.picture(at: versions[0]) { _ in }, "an older version is read again only if asked for again")
    }
}
