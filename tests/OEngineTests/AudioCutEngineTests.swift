import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 4 §11 as corrected 2026-11-27 — "a positive offset starts the sound's change that long after the trigger, an L
/// cut; a negative one starts it at the trigger and the channel's picture transition that long after it, a J cut, the
/// outgoing picture held until then. The offset applies only when the channel's outgoing or incoming content has
/// sound"; "an outgoing item's sound plays until its part of the audio transition ends: its video decoder is released
/// with its picture, and its sound when the fade ends." Through the engine, over Metal with the software audio device
/// and two entries of the clapper clip, which has sound.
final class AudioCutEngineTests: XCTestCase {
    static let first = "sha256:" + String(repeating: "c1a99e71", count: 8)
    static let second = "sha256:" + String(repeating: "c1a99e72", count: 8)

    /// The engine with both entries on channel 1, audio transition 3 a J cut (200 ms crossfade, −500 ms) and 4 an L cut
    /// (200 ms crossfade, +500 ms).
    func engine(sound: Bool = true) throws -> HeadlessEngine {
        let metal = try MetalHarness.backend()
        let url = try ClipFixtures.url(for: ClipFixtures.clapper)
        var library = try EngineFixtures.library()
        for id in [Self.first, Self.second] {
            library.mediaIndex.add(MediaEntry(id: id, path: url.lastPathComponent, kind: .video, size: 1, durationMs: 3000, fps: FrameRate(num: 30),
                                              width: 320, height: 180, hasAudio: sound, codec: "avc1"))
        }
        library.audioTransitions.removeAll { $0.number >= 3 }
        library.audioTransitions += [AudioTransition(number: 3, type: .crossfade, ms: 200, offsetMs: -500),
                                     AudioTransition(number: 4, type: .crossfade, ms: 200, offsetMs: 500)]
        guard let index = library.channels.firstIndex(where: { $0.number == 1 }) else { throw XCTSkip("channel 1") }
        library.channels[index].audioOutputs = [1]
        var machine = try EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270))
        machine.audioOutputs = [AudioOutput(number: 1, label: "A", device: .uid("A"), channels: [0, 1])]
        return try HeadlessEngine(library: library, machine: machine, media: MediaFolders(mediaRoot: ClipFixtures.folder), metal: metal)
    }

    /// Ticks until channel 1 plays `id` from its decoder.
    func untilLive(_ engine: HeadlessEngine, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<400 {
            engine.tick()
            if let m = engine.control.model.channels[1]?.live.media, m.ref == id, m.ready { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("\(id) never went live", file: file, line: line)
    }

    func test_aJCutHoldsThePictureAndChangesTheSoundAtTheTrigger() throws {
        let engine = try engine()
        XCTAssertNil(engine.send("channel 1 write media \(Self.first)"))
        untilLive(engine, Self.first)
        let firstHandle = try XCTUnwrap(engine.control.model.channels[1]?.live.media?.handle)
        XCTAssertNil(engine.send("channel 1 write media \(Self.second) transition 2 0.3 once audiotransition 3 once"))
        engine.tick()
        let landed = engine.frame
        let delay = engine.control.pacing.frames(forMs: 500)
        let run = try XCTUnwrap(engine.control.model.channels[1]?.transition)
        XCTAssertEqual(run.notBefore, landed + delay, "the picture's transition waits 500 ms after the trigger")
        // Until then the old picture holds, whether or not the new item's first frame has come.
        while engine.frame < landed + delay - 1 {
            let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
            XCTAssertNil(pass.transition, "frame \(engine.frame): no mix yet")
            guard case .instance(let handle, _) = pass.incoming.source else { return XCTFail("frame \(engine.frame): the held picture") }
            XCTAssertEqual(handle, firstHandle, "frame \(engine.frame): the outgoing picture holds")
            Thread.sleep(forTimeInterval: 0.01)
            engine.tick()
        }
        // The new item's sound changed at the trigger; its picture mixes in from then, or from its first frame if later.
        untilLive(engine, Self.second)
        XCTAssertNotNil(engine.control.model.channels[1]?.live.media?.audio)
        let start = try XCTUnwrap(engine.control.model.channels[1]?.transition?.startFrame)
        XCTAssertGreaterThanOrEqual(start, landed + delay)
        while engine.frame < start + 2 { engine.tick() }
        let mixing = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        XCTAssertNotNil(mixing.transition, "then the dissolve runs")
    }

    func test_anLCutsOutgoingSoundOutlivesItsPicture() throws {
        let engine = try engine()
        XCTAssertNil(engine.send("channel 1 write media \(Self.first)"))
        untilLive(engine, Self.first)
        XCTAssertNil(engine.send("channel 1 write media \(Self.second) transition 1 once audiotransition 4 once"))
        engine.tick()
        let landed = engine.frame
        untilLive(engine, Self.second)
        engine.tick(count: 2)
        let channel = try XCTUnwrap(engine.control.model.channels[1])
        XCTAssertNil(channel.outgoing, "a cut: the old picture is gone")
        let tail = try XCTUnwrap(channel.soundTails.first, "its sound plays on")
        XCTAssertEqual(tail.media.ref, Self.first)
        XCTAssertNil(tail.media.source, "its video decoder released with its picture")
        XCTAssertNotNil(tail.media.audio)
        XCTAssertEqual(tail.until, landed + engine.control.pacing.frames(forMs: 700), "500 ms of offset, then the 200 ms fade")
        while engine.frame <= tail.until { engine.tick() }
        XCTAssertEqual(engine.control.model.channels[1]?.soundTails.count, 0, "released once the fade ends")
    }

    /// "between two items without sound it changes nothing".
    func test_withoutSoundTheOffsetChangesNothing() throws {
        let engine = try engine(sound: false)
        XCTAssertNil(engine.send("channel 1 write media \(Self.first)"))
        untilLive(engine, Self.first)
        XCTAssertNil(engine.send("channel 1 write media \(Self.second) transition 2 0.3 once audiotransition 3 once"))
        engine.tick()
        XCTAssertNil(engine.control.model.channels[1]?.transition?.notBefore)
    }
}
