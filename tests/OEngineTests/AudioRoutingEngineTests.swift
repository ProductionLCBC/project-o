import XCTest
import OCore
@testable import OEngine

/// Spec 4 §11 — "Each channel's content may carry sound; the engine decodes
/// it, applies the channel's gain and audio transition, and routes it to the
/// numbered audio outputs the channel names"; "the first-numbered device is
/// the clock". Spec 4 §12 — the audio row, simulated through the harness
/// (Spec 4 §16). The engine over Metal with the software device factory and
/// the clapper clip.
final class AudioRoutingEngineTests: XCTestCase {
    func test_aChannelsSoundReachesEveryOutputItNamesAndADeviceLossKeepsThePictureMoving() throws {
        let metal = try MetalHarness.backend()
        let url = try ClipFixtures.url(for: ClipFixtures.clapper)
        var library = try EngineFixtures.library()
        let id = "sha256:" + String(repeating: "c1a99e71", count: 8)
        library.mediaIndex.add(MediaEntry(id: id, path: url.lastPathComponent, kind: .video, size: 1, durationMs: 3000, fps: FrameRate(num: 30),
                                          width: 320, height: 180, hasAudio: true, codec: "avc1"))
        guard let index = library.channels.firstIndex(where: { $0.number == 1 }) else { return XCTFail("channel 1") }
        library.channels[index].audioOutputs = [2, 1]
        var machine = try EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270))
        machine.audioOutputs = [AudioOutput(number: 1, label: "A", device: .uid("A"), channels: [0, 1]),
                                AudioOutput(number: 2, label: "B", device: .uid("B"), channels: [0, 1])]
        let engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: ClipFixtures.folder, metal: metal)
        let system = try XCTUnwrap(engine.engine.audio)
        let factory = try XCTUnwrap(engine.audioFactory)
        XCTAssertEqual(system.graphs.map(\.key), ["A", "B"])

        engine.send("channel 1 write media \(id)")
        engine.tick()
        var pass: ChannelPass?
        for _ in 0..<300 {
            engine.tick()
            pass = engine.lastPlan?.channelPasses.first
            if case .instance? = pass?.incoming.source { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard case .instance? = pass?.incoming.source else { return XCTFail("the clip is live") }
        let media = try XCTUnwrap(engine.control.model.channels[1]?.live.media)
        let attachment = try XCTUnwrap(media.audio)
        XCTAssertEqual(attachment.members.map(\.graph.key), ["A", "B"], "two rings, two instances, output 1's device first")
        XCTAssertEqual(media.audioDecoder?.rings.count, 2)
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        let ringA = attachment.members[0].instance.ring
        let ringB = attachment.members[1].instance.ring
        XCTAssertTrue(waitUntil(5) { ringA.framesAvailable >= AudioGraph.prerollFrames && ringB.framesAvailable >= AudioGraph.prerollFrames })

        // Device A takes a second of audio, device B a tenth: the picture follows A.
        var mixA: [Float] = []
        for _ in 0..<100 {
            XCTAssertTrue(waitUntil(5) { ringA.framesAvailable >= 480 || ringA.isEnded })
            mixA += a.pull(frames: 480)
        }
        XCTAssertTrue(waitUntil(5) { ringB.framesAvailable >= 4800 || ringB.isEnded })
        let mixB = b.pull(frames: 4800)
        XCTAssertLessThan(mixA.map(abs).max() ?? 1, 0.01, "silence before the click on A")
        XCTAssertLessThan(mixB.map(abs).max() ?? 1, 0.01)
        XCTAssertEqual(system.underruns, 0)
        engine.tick()
        guard case .instance(_, let afterSecond)? = engine.lastPlan?.channelPasses.first?.incoming.source else { return XCTFail() }
        XCTAssertEqual(afterSecond, 1000, accuracy: 1000.0 / 30, "media time follows device A, within one frame")
        XCTAssertTrue(waitUntil(5) { ringA.framesAvailable >= 48 && ringB.framesAvailable >= 48 })
        XCTAssertGreaterThan(a.pull(frames: 48).map(abs).max() ?? 0, 0.5, "the click reaches A")
        XCTAssertTrue(waitUntil(5) { ringB.framesAvailable >= 43_200 || ringB.isEnded })
        _ = b.pull(frames: 43_200)
        XCTAssertGreaterThan(b.pull(frames: 48).map(abs).max() ?? 0, 0.5, "and B, a second into B's own delivery")

        // Spec 4 §12 — device A vanishes with no fallback: output 1 is silent, the clock and the picture go on.
        factory.clock.nowNs = 9_000_000_000
        factory.absent.insert("A")
        system.recheckDevices()
        let standIn = try XCTUnwrap(system.graph(forOutput: 1)?.device as? PacedAudioDevice)
        XCTAssertTrue(engine.log.contains("audio output 1: device A lost; silent until it returns"), engine.log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(engine.engine.watchdog.recoveries, 1)
        standIn.step()
        factory.clock.nowNs += 200_000_000
        XCTAssertTrue(waitUntil(5) { ringA.framesAvailable >= 21 * PacedAudioDevice.blockFrames || ringA.isEnded })
        standIn.step()
        engine.tick()
        guard case .instance(_, let later)? = engine.lastPlan?.channelPasses.first?.incoming.source else { return XCTFail() }
        XCTAssertEqual(later, 1001 + 210, accuracy: 1000.0 / 30, "two hundred and ten milliseconds on the stand-in, within one frame")
        XCTAssertEqual(engine.livenessReading().sinkLastPresent.isEmpty, false, "the engine is still ticking")
        XCTAssertEqual(system.deviceStates.map(\.standing), [.silent, .primary])
    }
}
