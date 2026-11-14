import AVFoundation
import CoreVideo
import Foundation
import OCore
import XCTest
@testable import OEngine

/// Spec 8 §3 — "The kinds v1 takes (M6), found by opening the file, not from
/// its extension ... Anything else is refused with `unsupported`, so a `.mov`
/// holding a codec v1 can't play never reaches a cue." Spec 8 §11 — "Kinds
/// come from the content: a `.mov` with a codec v1 can't play is refused."
/// And Adam's answer of 2026-11-11: the engine hashes with CryptoKit, and
/// OCore's SHA-256 cross-checks it. AVFoundation and VideoToolbox run on the
/// bench Mac, not the hosted runner (MetalHarness).
final class MediaProbeTests: XCTestCase {
    typealias E = EngineFixtures
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func read(_ url: URL) -> MediaRead? {
        AVMediaProbe().read(url)
    }

    func metadata(_ url: URL, file: StaticString = #filePath, line: UInt = #line) -> MediaMetadata? {
        guard case .media(let m)? = read(url) else {
            XCTFail("\(url.lastPathComponent) didn't read as media: \(String(describing: read(url)))", file: file, line: line)
            return nil
        }
        return m
    }

    func test_videoImagesAndSlidesReadByTheirContent() throws {
        try MetalHarness.skipOnHostedRunner("the AVFoundation probe")
        let dawn = metadata(E.mediaRoot.appendingPathComponent("backgrounds/dawn.mp4"))
        XCTAssertEqual(dawn?.kind, .video)
        XCTAssertEqual(dawn?.codec, "avc1")
        XCTAssertEqual(dawn?.width, 64)
        XCTAssertEqual(dawn?.height, 36)
        XCTAssertEqual(dawn?.durationMs, 2000)
        XCTAssertEqual(dawn?.fps, FrameRate(num: 4))
        XCTAssertEqual(dawn?.hasAudio, false)
        for (clip, codec) in [(ClipFixtures.proRes, "apco"), (ClipFixtures.hevc, "hvc1"), (ClipFixtures.proRes4444, "ap4h")] {
            let read = metadata(try ClipFixtures.url(for: clip))
            XCTAssertEqual(read?.kind, .video, clip.name)
            XCTAssertEqual(read?.codec, codec, clip.name)
        }
        let cross = metadata(E.mediaRoot.appendingPathComponent("backgrounds/cross.png"))
        XCTAssertEqual(cross?.kind, .image)
        XCTAssertEqual(cross?.codec, "png")
        XCTAssertEqual(cross?.width, 64)
        let slide = metadata(E.mediaRoot.appendingPathComponent("slides/welcome.oslide"))
        XCTAssertEqual(slide?.kind, .slide)
        // A PNG named .mov is an image: the content says so, not the name.
        let disguised = folder.appendingPathComponent("Looks like a movie.mov")
        try FileManager.default.copyItem(at: E.mediaRoot.appendingPathComponent("backgrounds/cross.png"), to: disguised)
        XCTAssertEqual(metadata(disguised)?.kind, .image)
    }

    /// "a file that doesn't open yet as a kind v1 takes, such as a video still
    /// being exported, is left for a later walk" (Spec 8 §4): the probe says nil.
    func test_aHalfWrittenVideoDoesntOpenYet() throws {
        try MetalHarness.skipOnHostedRunner("the AVFoundation probe")
        let whole = try Data(contentsOf: E.mediaRoot.appendingPathComponent("backgrounds/dawn.mp4"))
        let half = folder.appendingPathComponent("half.mp4")
        try whole.prefix(whole.count / 3).write(to: half)
        XCTAssertNil(read(half))
    }

    /// "a `.mov` holding a codec v1 can't play" is refused, naming it; so is
    /// anything that isn't media.
    func test_aCodecV1CantPlayAndOtherFilesAreRefused() throws {
        try MetalHarness.skipOnHostedRunner("the AVFoundation probe")
        let jpeg = folder.appendingPathComponent("Motion JPEG.mov")
        try Self.writeMotionJPEG(to: jpeg)
        XCTAssertEqual(read(jpeg), .unsupported("jpeg video"))
        let text = folder.appendingPathComponent("notes.txt")
        try Data("plain words".utf8).write(to: text)
        guard case .unsupported? = read(text) else { return XCTFail("text is refused") }
        let pdf = folder.appendingPathComponent("Order of service.mov")
        try Data("%PDF-1.7 not a movie".utf8).write(to: pdf)
        XCTAssertEqual(read(pdf), .unsupported("a PDF document"))
    }

    /// Spec 1 §4 — the same id from CryptoKit and from OCore's SHA-256, over
    /// one chunk and many.
    func test_cryptoKitAndOCoresSHA256Agree() throws {
        let dawn = E.mediaRoot.appendingPathComponent("backgrounds/dawn.mp4")
        XCTAssertEqual(MediaHashing.identity(of: dawn), E.dawn)
        var bytes = [UInt8](repeating: 0, count: 3 * MediaHashing.chunk + 12_345)
        var state: UInt64 = 0x2026_1111
        for i in bytes.indices {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[i] = UInt8(truncatingIfNeeded: state >> 33)
        }
        let large = folder.appendingPathComponent("large.mov")
        try Data(bytes).write(to: large)
        var shares: [Double] = []
        XCTAssertEqual(MediaHashing.identity(of: large) { shares.append($0) }, MediaID.sha256(of: Data(bytes)))
        XCTAssertEqual(shares.last, 1)
        XCTAssertEqual(MediaHashing.identity(of: E.mediaRoot.appendingPathComponent("slides/welcome.oslide")),
                       "slide:51de0000-0000-4000-8000-000000000001", "a slide by its uuid")
    }

    /// A few frames of motion JPEG in a QuickTime movie: a codec AVFoundation
    /// reads and v1 doesn't play.
    static func writeMotionJPEG(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.jpeg,
                                                                          AVVideoWidthKey: 64, AVVideoHeightKey: 36])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var waited = 0
            while !input.isReadyForMoreMediaData, waited < 500 {
                Thread.sleep(forTimeInterval: 0.01)
                waited += 1
            }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 60) == .success, writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
