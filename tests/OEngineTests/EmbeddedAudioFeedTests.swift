import XCTest
import OCore
@testable import OEngine

/// Spec 4 §10 — "Embedded audio is enabled on the same output at 48 kHz,
/// 24-bit in 32-bit words, scheduled against the same stream time as the
/// video." Spec 4 §11 — "SDI embedded audio is an Audio Output whose device
/// is a DeckLink output. Its mix is produced by the same graph on a timer
/// thread (there is no device callback) and scheduled against the DeckLink
/// stream time ... so embedded audio and the picture share one clock." Area
/// 16 prompt: "the embedded feed's samples landing on the right stream time
/// against a fake card".
final class FakeCard: StreamAudioDestination, @unchecked Sendable {
    struct Block: Equatable {
        var streamTime: Int64
        var frames: Int
        var first: Int32
    }

    private let lock = NSLock()
    private var streamTime: Int64?
    private var accepting = true
    private var scheduled: [Block] = []
    let audioLeadNs: Int64

    init(streamTimeNowNs: Int64? = nil, leadNs: Int64 = 50_000_000) {
        streamTime = streamTimeNowNs
        audioLeadNs = leadNs
    }

    var streamTimeNowNs: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return streamTime }
        set { lock.lock(); streamTime = newValue; lock.unlock() }
    }

    var accept: Bool {
        get { lock.lock(); defer { lock.unlock() }; return accepting }
        set { lock.lock(); accepting = newValue; lock.unlock() }
    }

    var blocks: [Block] { lock.lock(); defer { lock.unlock() }; return scheduled }

    func scheduleAudio(_ samples: UnsafeBufferPointer<Int32>, frames: Int, streamTime: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard accepting else { return 0 }
        scheduled.append(Block(streamTime: streamTime, frames: frames, first: samples.first ?? 0))
        return frames
    }
}

final class EmbeddedAudioFeedTests: XCTestCase {
    let blockNs: Int64 = 10_000_000

    func ring(value: Float, seconds: Double = 2) -> AudioRing {
        let ring = AudioRing(channels: 2, capacityFrames: Int(seconds * 48_000) + 16)
        _ = ring.write([Float](repeating: value, count: Int(seconds * 48_000) * 2))
        return ring
    }

    /// A feed on a manual paced device over a fake card, with one instance of a constant 0.5.
    func feed(card: FakeCard, clock: SettableNanoClock = SettableNanoClock(nowNs: 7_000_000_000), log: EngineLog? = nil) throws
        -> (device: PacedAudioDevice, graph: AudioGraph, instance: AudioInstance) {
        let device = PacedAudioDevice(name: "sdi:2", channelCount: 2, destination: card, clock: { clock.nowNs }, threaded: false, log: log)
        let output = AudioOutput(number: 2, label: "SDI", kind: .sdiEmbedded, device: .sdiOutput(2), channels: [0, 1])
        let graph = AudioGraph(device: device, outputs: [output], key: "sdi:2")
        try graph.start()
        let instance = AudioInstance(handle: InstanceHandle(rawValue: 1), ring: ring(value: 0.5), inMs: 0, syncOffsetMs: 0,
                                     routing: graph.routing(forAudioOutputs: [2], instanceChannels: 2))
        XCTAssertTrue(graph.add(instance, gainDb: 0))
        return (device, graph, instance)
    }

    func test_blocksLandContiguouslyOnStreamTimeWithinTheLead() throws {
        let card = FakeCard(streamTimeNowNs: 1_000_000_000)
        let (device, graph, instance) = try feed(card: card)
        device.step()
        XCTAssertEqual(card.blocks.map(\.streamTime), (0..<6).map { 1_000_000_000 + Int64($0) * blockNs },
                       "from the card's time now up to the lead, ten milliseconds a block")
        XCTAssertEqual(card.blocks.map(\.frames), [Int](repeating: PacedAudioDevice.blockFrames, count: 6))
        XCTAssertEqual(card.blocks.first?.first, 0x4000_0000, "0.5 as 24-bit in a 32-bit word")
        XCTAssertEqual(graph.mediaTimeMs(of: instance), 60, accuracy: 0.01, "the clock reads what has been scheduled, as it does on a device")
        XCTAssertTrue(device.onStream)
        card.streamTimeNowNs = 1_020_000_000
        device.step()
        XCTAssertEqual(card.blocks.count, 8, "two more blocks fell within the lead")
        XCTAssertEqual(card.blocks.last?.streamTime, 1_070_000_000)
        XCTAssertEqual(device.blocksScheduled, 8)
        XCTAssertEqual(device.refused, 0)
        XCTAssertEqual(device.resyncs, 0)
        XCTAssertEqual(device.hostTimeNowNs, 1_020_000_000, "the device's clock is the card's stream time")
    }

    func test_aCardThatIsNotRunningIsConsumedOnTheMachineClockAndJoinedWhenItStarts() throws {
        let card = FakeCard(streamTimeNowNs: nil)
        let clock = SettableNanoClock(nowNs: 7_000_000_000)
        let log = EngineLog(category: "test-audio")
        let (device, graph, instance) = try feed(card: card, clock: clock, log: log)
        let before = instance.ring.framesAvailable
        device.step()
        XCTAssertTrue(card.blocks.isEmpty, "nothing scheduled on a card that is not running")
        XCTAssertFalse(device.onStream)
        XCTAssertEqual(instance.ring.framesAvailable, before - PacedAudioDevice.blockFrames, "but the ring is consumed, so the decoder flows and the clock runs")
        XCTAssertEqual(graph.mediaTimeMs(of: instance), 10, accuracy: 0.01)
        clock.nowNs += 100_000_000
        device.step()
        XCTAssertEqual(instance.ring.framesAvailable, before - 11 * PacedAudioDevice.blockFrames)
        XCTAssertEqual(graph.mediaTimeMs(of: instance), 110, accuracy: 0.01)
        XCTAssertEqual(device.hostTimeNowNs, clock.nowNs)

        card.streamTimeNowNs = 2_000_000_000
        device.step()
        XCTAssertTrue(device.onStream)
        XCTAssertEqual(card.blocks.map(\.streamTime), (0..<6).map { 2_000_000_000 + Int64($0) * blockNs }, "joined at the card's time now")
        XCTAssertEqual(device.resyncs, 1)
        XCTAssertTrue(log.contains("sdi:2: joined the card's stream time"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(graph.mediaTimeMs(of: instance), 170, accuracy: 0.01, "the clock carried on across the join")
    }

    func test_aRefusedBlockIsDroppedAndCounted() throws {
        let card = FakeCard(streamTimeNowNs: 1_000_000_000)
        card.accept = false
        let log = EngineLog(category: "test-audio")
        let (device, _, instance) = try feed(card: card, log: log)
        let before = instance.ring.framesAvailable
        device.step()
        XCTAssertTrue(card.blocks.isEmpty)
        XCTAssertEqual(device.refused, 6, "every block the card refused")
        XCTAssertEqual(instance.ring.framesAvailable, before - 6 * PacedAudioDevice.blockFrames, "the samples are gone, not replayed")
        XCTAssertTrue(log.contains("sdi:2: the card refused"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(log.recent.filter { $0.message.contains("refused") }.count, 1, "logged once")
        card.accept = true
        card.streamTimeNowNs = 1_010_000_000
        device.step()
        XCTAssertEqual(card.blocks.map(\.streamTime), [1_060_000_000], "the stream time carried on from where the refused blocks would have been")
    }

    func test_aJumpInTheCardsClockResyncs() throws {
        let card = FakeCard(streamTimeNowNs: 1_000_000_000)
        let log = EngineLog(category: "test-audio")
        let (device, _, _) = try feed(card: card, log: log)
        device.step()
        card.streamTimeNowNs = 3_000_000_000
        device.step()
        XCTAssertEqual(card.blocks.count, 12, "six blocks, then six from the new time; no two seconds of catch-up")
        XCTAssertEqual(card.blocks[6].streamTime, 3_000_000_000)
        XCTAssertEqual(device.resyncs, 1)
        XCTAssertTrue(log.contains("sdi:2: resynced"), log.recent.map(\.message).joined(separator: "\n"))
        // A small lag (the thread woke late) is caught up, not resynced.
        card.streamTimeNowNs = 3_200_000_000
        device.step()
        XCTAssertEqual(card.blocks.last?.streamTime, 3_250_000_000)
        XCTAssertEqual(device.resyncs, 1)
    }

    /// Spec 4 §10 — the card takes 2, 8 or 16 embedded channels; the Audio
    /// Output's channel indices (Spec 1 §3) decide which.
    func test_embeddedChannelCountIsTwoEightOrSixteen() {
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [0, 1]), 2)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: []), 2)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [2, 3]), 8)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [7]), 8)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [8, 9]), 16)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [15]), 16)
        XCTAssertEqual(DeckLinkSink.embeddedChannelCount(for: [40]), 16, "beyond the card: capped")
    }

    /// Spec 4 §12 — an unavailable card has no stream time and takes nothing.
    func test_anUnavailableSinkHasNoStreamTimeAndTakesNothing() throws {
        let backend = try MetalHarness.backend()
        let sink = DeckLinkSink(output: 2, persistentID: "decklink:none", format: VideoFormat(width: 1920, height: 1080, rate: .fps60), audioChannels: 2,
                                backend: backend, log: EngineLog(category: "test-decklink"))
        try sink.start()
        guard !DeckLinkSink.sdkAvailable else { throw XCTSkip("a card may be present") }
        XCTAssertNil(sink.streamTimeNowNs)
        XCTAssertEqual(sink.audioLeadNs, 3 * FrameRate.fps60.nanosecondsPerFrame, "three video frames, the depth the sink schedules video")
        let samples = [Int32](repeating: 0, count: 4)
        XCTAssertEqual(samples.withUnsafeBufferPointer { sink.scheduleAudio($0, frames: 2, streamTime: 0) }, 0)
        sink.stop()
    }
}
