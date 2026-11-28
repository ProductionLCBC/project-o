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
}
