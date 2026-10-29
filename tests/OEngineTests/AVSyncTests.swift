import XCTest
import OCore
@testable import OEngine

/// Spec 4 §16, Audio — "the clock reading drives frame selection within one
/// frame of the expected media time"; Spec 4 §15 — "A/V sync within one frame
/// on a clapper fixture", here in software: the engine over Metal with the
/// software audio device, the clapper clip's audio pulled by the test in
/// device-sized buffers.
final class AVSyncTests: XCTestCase {
    func test_videoFollowsTheAudioClock() throws {
        let metal = try MetalHarness.backend()
        let url = try ClipFixtures.url(for: ClipFixtures.clapper)
        var library = try EngineFixtures.library()
        let id = "sha256:" + String(repeating: "c1a99e71", count: 8)
        library.mediaIndex.add(MediaEntry(id: id, path: url.lastPathComponent, kind: .video, size: 1, durationMs: 3000, fps: FrameRate(num: 30),
                                          width: 320, height: 180, hasAudio: true, codec: "avc1"))
        let engine = try HeadlessEngine(library: library, machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        mediaRoot: ClipFixtures.folder, metal: metal)
        engine.send("channel 1 write media \(id)")
        engine.tick()
        // Wait for the first decoded frame; the audio clock has not moved yet.
        var pass: ChannelPass?
        for _ in 0..<300 {
            engine.tick()
            pass = engine.lastPlan?.channelPasses.first
            if case .instance? = pass?.incoming.source { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard case .instance(_, let atStart)? = pass?.incoming.source else { return XCTFail("the clip is live") }
        XCTAssertEqual(atStart, 0, accuracy: 1, "nothing delivered to the device yet: media time holds at the in-point")
        let media = try XCTUnwrap(engine.control.model.channels[1]?.live.media)
        let ring = try XCTUnwrap(media.audioDecoder?.ring)
        XCTAssertNotNil(media.audio, "the clip's sound is on the graph")

        // The device takes one second of audio, 10 ms at a time, as a HAL device would.
        var mix: [Float] = []
        for _ in 0..<100 {
            XCTAssertTrue(waitUntil(5) { ring.framesAvailable >= 480 || ring.isEnded })
            mix += engine.pullAudio(frames: 480)
        }
        XCTAssertEqual(engine.engine.audio?.underruns, 0)
        XCTAssertLessThan(mix.map(abs).max() ?? 1, 0.01, "silence before the click")

        // Spec 4 §2 — the picture follows the audio clock: media time is one second, frame thirty.
        engine.tick()
        guard case .instance(_, let afterSecond)? = engine.lastPlan?.channelPasses.first?.incoming.source else { return XCTFail() }
        XCTAssertEqual(afterSecond, 1000, accuracy: 1000.0 / 30, "within one frame of the audio clock")
        var shown: Int?
        for _ in 0..<60 {
            engine.tick()
            if let channel = metal.readback(engine.control.channelTextures[1] ?? .none) {
                shown = FixtureMedia.frameIndex(in: channel)
            }
            if shown == FixtureMedia.flashIndex { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(shown, FixtureMedia.flashIndex, "frame thirty is the clapper's flash frame, one second in")

        // The next millisecond of sound carries the click: the flash and the click land together.
        XCTAssertTrue(waitUntil(5) { ring.framesAvailable >= 48 })
        let next = engine.pullAudio(frames: 48)
        XCTAssertGreaterThan(next.map(abs).max() ?? 0, 0.5, "the click went through the mix at one second")
    }
}
