import XCTest
import AVFoundation
import OCore
@testable import OEngine

/// Spec 4 §6 — the video file source: trims, loops, layouts, the queue, end
/// of media; Spec 4 §16, Frame selection — "a loop with a pre-rolled second
/// reader shows no gap". The clips are synthetic (FixtureMedia): every frame
/// carries its index in bars the test reads back from the decoded buffer.
final class VideoSourceTests: XCTestCase {
    func open(_ clip: FixtureMedia.Clip, inMs: Double = 0, outMs: Double? = nil, loop: Bool = false, device: Bool = false) throws -> VideoFileSource {
        let url = try ClipFixtures.url(for: clip)
        let source = VideoFileSource(url: url, inMs: inMs, outMs: outMs, loop: loop, device: device ? MTLCreateSystemDefaultDevice() : nil,
                                     log: EngineLog(category: "test-video"))
        source.start()
        XCTAssertTrue(waitUntil(15) { source.isReady || source.isFailed }, "the first frame arrives")
        XCTAssertFalse(source.isFailed, "decoding started")
        return source
    }

    /// Pick at `ms` and read the frame index from the displayed buffer.
    func index(_ source: VideoFileSource, at ms: Double) -> (PickResult, Int?) {
        var picked = PickedFrame()
        let result = source.pick(mediaTimeMs: ms, into: &picked)
        guard let buffer = source.queue.displayedFrame?.pixelBuffer else { return (result, nil) }
        return (result, FixtureMedia.frameIndex(in: buffer))
    }

    func test_theFirstFrameIsFrameZeroAndFramesFollowMediaTime() throws {
        let source = try open(ClipFixtures.h264)
        defer { source.release() }
        XCTAssertEqual(source.layout, .nv12)
        XCTAssertEqual(source.size, PixelSize(width: 320, height: 180))
        XCTAssertEqual(index(source, at: 0).1, 0)
        // Half a second in at 30 fps is frame 15; let the decoder catch up as the queue drains.
        var seen: [Int] = []
        var repeats = 0
        for tick in 0...60 {
            let ms = Double(tick) * 1000 / 60
            _ = waitUntil(2) { source.queueDepth > 0 || source.queue.isEnded }
            let (result, frame) = index(source, at: ms)
            if result == .repeated { repeats += 1 }
            if let frame { seen.append(frame) }
        }
        XCTAssertEqual(seen.last, 30, "one second in is frame 30")
        XCTAssertEqual(seen, seen.sorted(), "frames never go backwards")
        XCTAssertGreaterThan(repeats, 20, "a 30 fps clip on a 60 Hz tick repeats about every other tick")
        XCTAssertEqual(source.decodeErrors, 0)
    }

    func test_inPointTrimDropsTheFramesBeforeIt() throws {
        let source = try open(ClipFixtures.h264LongGOP, inMs: 1500)
        defer { source.release() }
        XCTAssertEqual(index(source, at: 1500).1, 45, "the pre-roll decoded from the keyframe and dropped the frames before the in-point")
        XCTAssertGreaterThanOrEqual(source.queue.displayedFrame?.presentationMs ?? 0, 1500)
    }

    func test_outPointEndsTheStream() throws {
        let source = try open(ClipFixtures.h264, outMs: 500)
        defer { source.release() }
        var last: Int?
        for tick in 0...40 {
            _ = waitUntil(2) { source.queueDepth > 0 || source.queue.isEnded }
            if let f = index(source, at: Double(tick) * 1000 / 60).1 { last = f }
        }
        XCTAssertEqual(last, 14, "the last frame before the out-point holds")
        XCTAssertTrue(waitUntil(5) { source.queue.isEnded })
    }

    func test_loopShowsNoGap() throws {
        let source = try open(ClipFixtures.h264Loop, loop: true)
        defer { source.release() }
        var nothing = 0
        var indices: [Int] = []
        for tick in 0...150 {   // 2.5 s over a 1 s loop
            let ms = Double(tick) * 1000 / 60
            _ = waitUntil(2) { source.queueDepth > 0 }
            let (result, frame) = index(source, at: ms)
            if result == .nothing { nothing += 1 }
            if let frame { indices.append(frame) }
        }
        XCTAssertEqual(nothing, 0, "a looping clip always has a frame")
        XCTAssertGreaterThanOrEqual(source.loops, 2)
        XCTAssertEqual(indices.last, 15, "2.5 s into a 1 s loop is frame 15 of the third pass")
        XCTAssertTrue(indices.contains(29) && indices.contains(0), "the loop went through the out-point and back to the in-point")
    }

    func test_everyCodecDecodesToItsNativeLayout() throws {
        let expectations: [(FixtureMedia.Clip, SourceLayout)] = [
            (ClipFixtures.hevc, .nv12),
            (ClipFixtures.proRes, .yuv422p10),
            (ClipFixtures.proRes4444, .rgba16),
        ]
        for (clip, layout) in expectations {
            let source = try open(clip)
            XCTAssertEqual(source.layout, layout, clip.name)
            XCTAssertEqual(index(source, at: 0).1, 0, clip.name)
            source.release()
        }
    }

    func test_tenBitHEVCDecodesToP010() throws {
        let url: URL
        do {
            url = try ClipFixtures.url(for: ClipFixtures.hevc10)
        } catch {
            throw XCTSkip("this machine cannot encode HEVC Main 10: \(error)")
        }
        let source = VideoFileSource(url: url, inMs: 0, outMs: nil, loop: false, device: nil)
        source.start()
        defer { source.release() }
        XCTAssertTrue(waitUntil(15) { source.isReady || source.isFailed })
        XCTAssertEqual(source.layout, .p010)
        XCTAssertEqual(index(source, at: 0).1, 0)
    }

    func test_metalTexturesWrapTheDecodedPlanes() throws {
        guard MetalBackend.isAvailable else { throw XCTSkip("no Metal device") }
        let source = try open(ClipFixtures.h264, device: true)
        defer { source.release() }
        var picked = PickedFrame()
        XCTAssertEqual(source.pick(mediaTimeMs: 0, into: &picked), .frame)
        XCTAssertNotNil(picked.plane0, "the luma plane as a Metal texture")
        XCTAssertNotNil(picked.plane1, "the chroma plane as a Metal texture")
        XCTAssertEqual(picked.layout, .nv12)
    }

    func test_releaseStopsTheDecoder() throws {
        let source = try open(ClipFixtures.h264)
        source.release()
        XCTAssertTrue(source.isReleased)
        let decoded = source.decodedFrames
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertLessThanOrEqual(source.decodedFrames, decoded + 8, "no more than what was already in flight")
    }

    /// The committed fixture clip of Spec 1 §9 decodes as well as the generated ones.
    func test_fixtureClipDecodes() throws {
        let url = EngineFixtures.mediaRoot.appendingPathComponent("backgrounds/dawn.mp4")
        let source = VideoFileSource(url: url, inMs: 0, outMs: nil, loop: true, device: MTLCreateSystemDefaultDevice(), log: EngineLog(category: "test-video"))
        source.start()
        defer { source.release() }
        XCTAssertTrue(waitUntil(15) { source.isReady || source.isFailed })
        XCTAssertFalse(source.isFailed, "dawn.mp4 decodes; errors \(source.decodeErrors)")
        XCTAssertEqual(source.size, PixelSize(width: 64, height: 36))
        var picked = PickedFrame()
        XCTAssertEqual(source.pick(mediaTimeMs: 0, into: &picked), .frame)
    }

    func test_demuxerReportsTheStream() throws {
        let url = try ClipFixtures.url(for: ClipFixtures.proRes)
        let session = try AVAssetReaderDemuxer().open(url, startMs: 0)
        XCTAssertEqual(session.description.size, PixelSize(width: 320, height: 180))
        XCTAssertEqual(session.description.durationMs, 2000, accuracy: 1)
        XCTAssertEqual(session.description.codec, "apco")
        XCTAssertFalse(session.description.hasAudio)
        let first = try XCTUnwrap(session.nextVideoSample())
        XCTAssertEqual(first.presentationMs, 0, accuracy: 0.01)
        XCTAssertTrue(first.isKeyframe)
        session.close()
    }
}

/// Spec 4 §6 — stills: "Decoded once with ImageIO off the render thread,
/// downsampled to the channel render size, converted to RGBA16Float linear".
final class StillSourceTests: XCTestCase {
    func test_decodeFitsWithinTheChannelAndIsLinear() throws {
        let url = EngineFixtures.mediaRoot.appendingPathComponent("backgrounds/cross.png")
        let frame = try StillSource.decode(url: url, fitWithin: PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(frame.width, 64)
        XCTAssertEqual(frame.height, 36)
        XCTAssertTrue(frame.pixels.allSatisfy { $0.a == 1 }, "an opaque PNG")
        let small = try StillSource.decode(url: url, fitWithin: PixelSize(width: 32, height: 32))
        XCTAssertEqual(small.width, 32)
        XCTAssertEqual(small.height, 18)
    }

    func test_stillSourceBecomesReadyWithATexture() throws {
        let backend = try MetalHarness.backend()
        let url = EngineFixtures.mediaRoot.appendingPathComponent("backgrounds/cross.png")
        let still = StillSource(url: url, fitWithin: PixelSize(width: 1920, height: 1080), backend: backend)
        XCTAssertFalse(still.isReady)
        try still.load()
        XCTAssertTrue(still.isReady)
        XCTAssertEqual(still.size, PixelSize(width: 64, height: 36))
        var picked = PickedFrame()
        XCTAssertEqual(still.pick(mediaTimeMs: 0, into: &picked), .frame)
        XCTAssertNotNil(picked.plane0)
        XCTAssertEqual(picked.layout, .linearRGBA16)
        let back = try XCTUnwrap(backend.readback(still.handle))
        XCTAssertEqual(back.width, 64)
    }

    func test_posterProviderLoadsOnceAndCaches() throws {
        let backend = try MetalHarness.backend()
        let library = try EngineFixtures.library()
        let provider = ImagePosterProvider(backend: backend, mediaRoot: EngineFixtures.mediaRoot)
        let entry = try XCTUnwrap(library.mediaIndex.entry(EngineFixtures.dawn))
        let handle = provider.poster(for: entry)
        XCTAssertFalse(handle.isNone)
        XCTAssertEqual(provider.poster(for: entry), handle)
        XCTAssertEqual(backend.resources.descriptor(handle)?.role, .poster)
        let noPoster = try XCTUnwrap(library.mediaIndex.entry(EngineFixtures.cross))
        XCTAssertTrue(provider.poster(for: noPoster).isNone)
    }
}

/// Spec 4 §6 — the real source factory with prefetch.
final class MediaSourceFactoryTests: XCTestCase {
    func test_prefetchedSourceIsAdoptedOnceAndOpenedOtherwise() throws {
        let backend = try MetalHarness.backend()
        let factory = MediaSourceFactory(backend: backend, log: EngineLog(category: "test"))
        let url = try ClipFixtures.url(for: ClipFixtures.h264)
        let entry = MediaEntry(id: "sha256:test", path: "h264.mov", kind: .video, size: 1, durationMs: 2000, width: 320, height: 180, codec: "avc1")
        let request = SourceRequest(url: url, entry: entry, inMs: 0, outMs: nil, loop: false, handle: InstanceHandle(rawValue: 0))
        factory.prefetch(request)
        factory.prefetch(request)
        XCTAssertEqual(factory.openedCount, 1, "the same media and in-point is prefetched once")
        let adopted = try XCTUnwrap(factory.adoptPrefetched(request))
        XCTAssertNil(factory.adoptPrefetched(request), "adopted once")
        XCTAssertTrue(waitUntil(15) { adopted.isReady })
        adopted.release()
        let fresh = factory.open(request)
        XCTAssertEqual(factory.openedCount, 2)
        fresh.release()
    }
}

/// The synthetic clips themselves: what the generator wrote reads back as
/// described, which the bench's capture analysis relies on (Spec 4 §15).
final class FixtureMediaTests: XCTestCase {
    func test_clipHasTheRequestedShape() throws {
        let url = try ClipFixtures.url(for: ClipFixtures.clapper)
        let asset = AVURLAsset(url: url)
        XCTAssertEqual(asset.duration.seconds, 3, accuracy: 0.05)
        XCTAssertEqual(asset.tracks(withMediaType: .video).count, 1)
        XCTAssertEqual(asset.tracks(withMediaType: .audio).count, 1)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize.width, 320)
        XCTAssertEqual(track.nominalFrameRate, 30, accuracy: 0.01)
    }

    func test_barsReadBackFromARenderedFrame() {
        var frame = CapturedFrame(width: 120, height: 60)
        for y in 0..<60 {
            for x in 0..<120 {
                let l = Float(FixtureMedia.luma(frameIndex: 1234, x: x, y: y, width: 120, height: 60, flash: false))
                frame[x, y] = LinearPixel(r: l, g: l, b: l, a: 1)
            }
        }
        XCTAssertEqual(FixtureMedia.frameIndex(in: frame), 1234)
    }

    func test_clickSitsAtTheRequestedSample() {
        let samples = FixtureMedia.audioSamples(.click(atMs: 1000), seconds: 2)
        XCTAssertEqual(samples[Int(47_999) * 2], 0)
        XCTAssertNotEqual(samples[48_000 * 2], 0)
        XCTAssertEqual(samples.count, 2 * 48_000 * 2)
    }
}
