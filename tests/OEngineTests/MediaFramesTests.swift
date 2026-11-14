import CoreGraphics
import Foundation
import ImageIO
import OCore
import XCTest
@testable import OEngine

/// Spec 8 §5 — "The poster (M2) is the frame at the video's default
/// in-point ..., taken exactly, because that's the frame the engine stands it
/// in for when a write lands before its first decoded frame (Spec 4 §6). It's
/// a PNG fitted within 1920 × 1080, with alpha when the video has it". The
/// fixture clips carry their frame number in bars along the top, so the
/// poster says which frame it is. AVFoundation and VideoToolbox run on the
/// bench Mac, not the hosted runner (MetalHarness).
final class MediaFramesTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// An image's pixels as premultiplied BGRA bytes.
    static func pixels(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return (bytes, width, height)
    }

    /// The frame number the bars along the top of a fixture frame spell
    /// (FixtureMedia's painting, read as `FixtureMedia.frameIndex` reads a buffer).
    static func frameIndex(of image: CGImage) -> Int {
        let (bytes, width, height) = pixels(image)
        let y = max(0, height / 20)
        var index = 0
        for bar in 0..<FixtureMedia.barCount {
            let x = (bar * width + width / (2 * FixtureMedia.barCount)) / FixtureMedia.barCount
            // Unpremultiplied, so the half-transparent third of a 4444 frame reads as it was painted.
            let alpha = Double(bytes[(y * width + x) * 4 + 3])
            let green = alpha > 0 ? Double(bytes[(y * width + x) * 4 + 1]) / alpha : 0
            index = (index << 1) | (green > 0.5 ? 1 : 0)
        }
        return index
    }

    /// "taken exactly": the first frame at or after the in-point, decoded
    /// from the keyframe before it, as playback publishes it first. On a
    /// clip with a keyframe every 60 frames at 30 fps, frame 45 is at 1500 ms,
    /// and an in-point between two frames takes the later one.
    func test_thePosterIsTheFramePlaybackShowsFirst() throws {
        try MetalHarness.skipOnHostedRunner("AVFoundation decoding")
        let clip = try ClipFixtures.url(for: ClipFixtures.h264LongGOP)
        let frames = AVMediaFrames()
        for (inMs, expected) in [(0, 0), (1500, 45), (1510, 46), (2000, 60), (2010, 61)] {
            let image = try XCTUnwrap(frames.frame(of: clip, atMs: inMs, alpha: false)?.image, "\(inMs) ms")
            XCTAssertEqual(Self.frameIndex(of: image), expected, "the frame at \(inMs) ms")
            XCTAssertFalse(MediaImages.hasAlpha(image), "no alpha when the video has none")
        }
    }

    /// "the frame the engine stands it in for when a write lands before its
    /// first decoded frame": for the same in-points, the poster and the first
    /// frame `VideoFileSource` publishes are one frame.
    func test_thePosterMatchesTheFirstFramePlaybackPublishes() throws {
        try MetalHarness.skipOnHostedRunner("AVFoundation decoding")
        let url = try ClipFixtures.url(for: ClipFixtures.h264LongGOP)
        for inMs in [0, 1510, 1999, 2010] {
            let source = VideoFileSource(url: url, inMs: Double(inMs), outMs: nil, loop: false, device: nil, log: EngineLog(category: "test-frames"))
            source.start()
            defer { source.release() }
            XCTAssertTrue(waitUntil(15) { source.isReady || source.isFailed })
            // Picked within the first published frame's own 33 ms, which starts at or after the in-point.
            var picked = PickedFrame()
            _ = source.pick(mediaTimeMs: Double(inMs) + 33, into: &picked)
            let played = try XCTUnwrap(source.queue.displayedFrame?.pixelBuffer).map(FixtureMedia.frameIndex(in:))
            let poster = try XCTUnwrap(AVMediaFrames().frame(of: url, atMs: inMs, alpha: false)?.image)
            XCTAssertEqual(Self.frameIndex(of: poster), played, "at \(inMs) ms")
        }
    }

    /// "with alpha when the video has it": ProRes 4444's half-transparent
    /// third keeps its alpha through the PNG.
    func test_aPosterOfProRes4444KeepsItsAlpha() throws {
        try MetalHarness.skipOnHostedRunner("AVFoundation decoding")
        let clip = try ClipFixtures.url(for: ClipFixtures.proRes4444)
        let image = try XCTUnwrap(AVMediaFrames().frame(of: clip, atMs: 500, alpha: true)?.image)
        XCTAssertTrue(MediaImages.hasAlpha(image))
        let png = folder.appendingPathComponent("poster.png")
        XCTAssertTrue(MediaImages.writePNG(try XCTUnwrap(MediaImages.fitted(image)), to: png))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
        let read = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let (bytes, width, height) = Self.pixels(read)
        let opaque = bytes[((height / 2) * width + width / 6) * 4 + 3]
        let half = bytes[((height / 2) * width + width * 5 / 6) * 4 + 3]
        XCTAssertEqual(opaque, 255, "the left of the frame is opaque")
        XCTAssertEqual(Double(half), 128, accuracy: 4, "the right third is half transparent")
        XCTAssertEqual(Self.frameIndex(of: read), 15, "and it is the frame at 500 ms")
    }

    /// "fitted within 1920 × 1080": a 4K frame is made smaller, keeping its
    /// aspect; a smaller one keeps its size.
    func test_aPosterIsFittedWithin1920By1080() throws {
        try MetalHarness.skipOnHostedRunner("AVFoundation decoding")
        let uhd = FixtureMedia.Clip(name: "h264-uhd-0.2s", codec: .h264, width: 3840, height: 2160, seconds: 0.2)
        let image = try XCTUnwrap(AVMediaFrames().frame(of: try ClipFixtures.url(for: uhd), atMs: 0, alpha: false)?.image)
        XCTAssertEqual(image.width, 3840)
        let fitted = try XCTUnwrap(MediaImages.fitted(image))
        XCTAssertEqual(fitted.width, 1920)
        XCTAssertEqual(fitted.height, 1080)
        let small = try XCTUnwrap(AVMediaFrames().frame(of: try ClipFixtures.url(for: ClipFixtures.h264), atMs: 0, alpha: false)?.image)
        XCTAssertEqual(MediaImages.fitted(small)?.width, 320, "never made larger")
        // A file that isn't video gives no frame.
        let text = folder.appendingPathComponent("notes.mov")
        try Data("not a movie".utf8).write(to: text)
        XCTAssertNil(AVMediaFrames().frame(of: text, atMs: 0, alpha: false))
    }

    /// Spec 8 §5 — "Pool tiles (M3) are 480 px wide PNGs": drawn at 480
    /// wide from a larger image and from a smaller one, at its own aspect.
    func test_aTileIs480Wide() throws {
        for (width, height) in [(1920, 1080), (64, 36), (1080, 1920)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
            context.setFillColor(CGColor(gray: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let url = folder.appendingPathComponent("\(width)x\(height).png")
            XCTAssertTrue(MediaImages.writePNG(try XCTUnwrap(context.makeImage()), to: url))
            let tile = try XCTUnwrap(MediaImages.tile(from: url))
            XCTAssertEqual(tile.width, 480)
            XCTAssertEqual(tile.height, Int((480 * Double(height) / Double(width)).rounded()))
        }
    }
}
