import XCTest
import OCore
@testable import OEngine

/// Spec 4 §11 — "One Core Audio output unit (the HAL output AudioUnit) per
/// distinct device, each with its own render callback"; "When a channel is
/// routed to more than one device, the first-numbered device is the clock".
/// Spec 4 §12 — "Audio device vanishes: Switch to the Audio Output's
/// configured fallback device if one is set; otherwise drop that output's
/// audio (silence, with a badge) rather than guessing; return when the
/// device reappears." Spec 4 §16 — each row of §12 "is simulated in the
/// harness and produces the documented response and log line". Area 16
/// readings approved on 2026-11-03: the clock is the device of the
/// lowest-numbered output the channel names; a graph whose device is lost
/// follows its lowest-numbered output's fallback and silences the outputs
/// whose fallback differs; silence is a stand-in device that keeps consuming
/// so the clock and the picture continue; a device absent at startup gets
/// the same rule and no default-device guess.
final class AudioSystemTests: XCTestCase {
    func output(_ number: Int, device: String, channels: [Int] = [0, 1], fallback: String? = nil, delayMs: Int = 0) -> AudioOutput {
        AudioOutput(number: number, label: "out \(number)", device: .uid(device), channels: channels, delayMs: delayMs, fallbackDevice: fallback)
    }

    /// Outputs 1 and 3 on device A (3 on its channels 2 and 3), output 2 on device B.
    func twoDevices(fallback1: String? = nil) -> [AudioOutput] {
        [output(1, device: "A", fallback: fallback1), output(2, device: "B"), output(3, device: "A", channels: [2, 3])]
    }

    func ring(value: Float, seconds: Double = 2) -> AudioRing {
        let ring = AudioRing(channels: 2, capacityFrames: Int(seconds * 48_000) + 16)
        _ = ring.write([Float](repeating: value, count: Int(seconds * 48_000) * 2))
        return ring
    }

    func makeSystem(_ outputs: [AudioOutput], factory: SoftwareAudioDeviceFactory, log: EngineLog = EngineLog(category: "test-audio")) -> AudioSystem {
        let system = AudioSystem(outputs: outputs, factory: factory, log: log)
        system.start()
        return system
    }

    func attach(_ system: AudioSystem, outputs: [Int], value: Float = 0.5, seconds: Double = 2, handle: Int32 = 1, channel: Int = 1) throws -> AudioAttachment {
        let count = system.ringCount(forOutputs: outputs)
        let rings = (0..<count).map { _ in ring(value: value, seconds: seconds) }
        return try XCTUnwrap(system.attach(handle: InstanceHandle(rawValue: handle), rings: rings, outputs: outputs, inMs: 0, syncOffsetMs: 0,
                                           gainDb: 0, playing: true, channel: channel))
    }

    final class Recoveries: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [WatchdogRecovery] = []
        func add(_ recovery: WatchdogRecovery) { lock.lock(); items.append(recovery); lock.unlock() }
        var list: [WatchdogRecovery] { lock.lock(); defer { lock.unlock() }; return items }
    }

    // MARK: - Spec 4 §11, one graph per device

    func test_oneGraphPerDistinctDevice() {
        let factory = SoftwareAudioDeviceFactory()
        let system = makeSystem(twoDevices(), factory: factory)
        XCTAssertEqual(system.graphs.map(\.key), ["A", "B"], "in the order of their lowest output number")
        XCTAssertEqual(system.graphs.map(\.channelCount), [4, 2], "device A carries channels up to index 3")
        XCTAssertEqual(system.graphs.map(\.outputNumbers), [[1, 3], [2]])
        XCTAssertEqual(factory.opened, 2, "one unit per device, not per output")
        XCTAssertEqual(system.graph(forOutput: 3)?.key, "A")
        XCTAssertEqual(system.ringCount(forOutputs: [1, 3]), 1, "two outputs on one device share a ring")
        XCTAssertEqual(system.ringCount(forOutputs: [1, 2]), 2)
        XCTAssertEqual(system.ringCount(forOutputs: [9]), 0, "an output the machine does not have reaches nothing")
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .primary])
        system.stop()
    }

    func test_twoOutputsOnOneDeviceMixOnceIntoBothChannelPairs() throws {
        let factory = SoftwareAudioDeviceFactory()
        let system = makeSystem(twoDevices(), factory: factory)
        let attachment = try attach(system, outputs: [1, 3])
        XCTAssertEqual(attachment.members.count, 1, "one ring, one instance, on device A")
        XCTAssertEqual(attachment.members[0].instance.routing.pairs,
                       [AudioRouting.Pair(source: 0, target: 0), AudioRouting.Pair(source: 1, target: 1),
                        AudioRouting.Pair(source: 0, target: 2), AudioRouting.Pair(source: 1, target: 3)])
        let a = try XCTUnwrap(factory.device("A"))
        let out = a.pull(frames: 10)
        XCTAssertEqual(Array(out[0..<4]), [0.5, 0.5, 0.5, 0.5], "output 1's pair and output 3's pair both carry the sound")
        system.detach(attachment)
        XCTAssertEqual(a.pull(frames: 10)[0], 0, "detached: silence")
        system.stop()
    }

    /// Spec 4 §11 — "the first-numbered device is the clock and the others may
    /// drift by their own clock error; pre-flight notes multi-device routing".
    func test_theLowestNumberedOutputsDeviceIsTheClock() throws {
        let factory = SoftwareAudioDeviceFactory()
        let log = EngineLog(category: "test-audio")
        let system = makeSystem(twoDevices(), factory: factory, log: log)
        let attachment = try attach(system, outputs: [2, 1])
        XCTAssertEqual(attachment.members.map(\.graph.key), ["A", "B"], "listed out of order, output 1's device still comes first")
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        let onA = a.pull(frames: 480)
        let onB = b.pull(frames: 4800)
        XCTAssertEqual(onA[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(onA[1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(onA[2], 0, accuracy: 1e-6, "output 3 was not named")
        XCTAssertEqual(onB[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 10, accuracy: 0.01, "ten milliseconds, device A's delivery; B's hundred do not count")
        XCTAssertTrue(log.contains("channel 1 routes to audio outputs on more than one device"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(log.recent.filter { $0.message.contains("more than one device") }.count, 1, "noted once per channel")
        _ = try attach(system, outputs: [2, 1], handle: 2)
        XCTAssertEqual(log.recent.filter { $0.message.contains("more than one device") }.count, 1)
        system.stop()
    }

    /// Spec 4 §11 — "Mute of an audio output zeroes that device's mix with a 20 ms ramp".
    func test_muteReachesTheGraphThatHoldsTheOutput() throws {
        let factory = SoftwareAudioDeviceFactory()
        let system = makeSystem(twoDevices(), factory: factory)
        _ = try attach(system, outputs: [1, 2, 3])
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        _ = a.pull(frames: 10)
        _ = b.pull(frames: 10)
        system.setMuted(true, output: 3)
        let onA = a.pull(frames: 960)
        XCTAssertEqual(onA[959 * 4 + 2], 0, accuracy: 0.003, "output 3's channels are muted after the ramp")
        XCTAssertEqual(onA[959 * 4], 0.5, accuracy: 1e-6, "output 1 on the same device is untouched")
        XCTAssertEqual(b.pull(frames: 960)[959 * 2], 0.5, accuracy: 1e-6, "device B is untouched")
        system.setMuted(true, output: 2)
        XCTAssertEqual(b.pull(frames: 960)[959 * 2], 0, accuracy: 0.003)
        system.stop()
    }

    /// Spec 4 §11 — the audio transition "between the outgoing and incoming
    /// instance of a channel" runs on every device the channel reaches.
    func test_aTransitionRunsOnEveryDeviceTheChannelReaches() throws {
        let factory = SoftwareAudioDeviceFactory()
        let system = makeSystem(twoDevices(), factory: factory)
        let outgoing = try attach(system, outputs: [1, 2], value: 0.5, handle: 1)
        let incoming = try attach(system, outputs: [1, 2], value: 0.25, handle: 2)
        system.startTransition(outgoing: outgoing, incoming: incoming, type: .crossfade, ms: 100, offsetMs: 0)
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        let onA = a.pull(frames: 4800)
        let onB = b.pull(frames: 4800)
        XCTAssertEqual(onA[2400 * 4], 0.375, accuracy: 1e-6, "half way on A")
        XCTAssertEqual(onB[2400 * 2], 0.375, accuracy: 1e-6, "half way on B")
        XCTAssertEqual(a.pull(frames: 1)[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(b.pull(frames: 1)[0], 0.25, accuracy: 1e-6)
        system.stop()
    }

    // MARK: - Spec 4 §12, the audio row

    func test_deviceLossSwitchesToTheFallbackAndTheReturnTakesTheDeviceBack() throws {
        let factory = SoftwareAudioDeviceFactory()
        let log = EngineLog(category: "test-audio")
        let recoveries = Recoveries()
        let system = makeSystem(twoDevices(fallback1: "C"), factory: factory, log: log)
        system.onRecovery = { recoveries.add($0) }
        let attachment = try attach(system, outputs: [1, 3])
        let a = try XCTUnwrap(factory.device("A"))
        _ = a.pull(frames: 480)
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .primary])
        XCTAssertNil(factory.device("C"), "the fallback is not opened while the primary is there")

        factory.absent.insert("A")
        system.recheckDevices()
        let c = try XCTUnwrap(factory.device("C"), "the fallback was opened")
        XCTAssertTrue(system.graph(forOutput: 1)?.device === c, "the graph swapped its device and kept everything else")
        XCTAssertFalse(a.isRunning, "the lost device's unit is stopped")
        let out = c.pull(frames: 480)
        XCTAssertEqual(out[0], 0.5, accuracy: 1e-6, "output 1 plays on its fallback")
        XCTAssertEqual(out[2], 0, accuracy: 1e-6, "output 3 has no fallback: silent on the stand-in")
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 20, accuracy: 0.01, "the clock continued: ten ms on A, ten on C")
        XCTAssertTrue(log.contains("audio output 1: device A lost; on fallback C"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(log.contains("audio output 3: device A lost; silent until it returns"))
        XCTAssertEqual(recoveries.list, [.audioDeviceLost("A")])
        XCTAssertEqual(system.deviceStates.map(\.standing), [.fallback, .primary])
        XCTAssertEqual(system.deviceStates[0].standIn, "C")

        factory.absent.remove("A")
        system.recheckDevices()
        let again = try XCTUnwrap(factory.device("A"))
        XCTAssertFalse(again === a, "a fresh unit on the returned device")
        XCTAssertTrue(system.graph(forOutput: 1)?.device === again)
        XCTAssertFalse(c.isRunning, "the fallback's unit is stopped")
        let back = again.pull(frames: 10)
        XCTAssertEqual(back[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(back[2], 0.5, accuracy: 1e-6, "output 3 plays again")
        XCTAssertTrue(log.contains("audio output 1: device A back"))
        XCTAssertTrue(log.contains("audio output 3: device A back"))
        XCTAssertEqual(recoveries.list.count, 1, "a return is not a recovery")
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .primary])
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 20 + 10.0 / 48, accuracy: 0.01, "and the clock went on")
        system.stop()
    }

    func test_deviceLossWithoutAFallbackRunsSilentAndTheClockStillMoves() throws {
        let factory = SoftwareAudioDeviceFactory()
        let log = EngineLog(category: "test-audio")
        let recoveries = Recoveries()
        let system = makeSystem(twoDevices(), factory: factory, log: log)
        system.onRecovery = { recoveries.add($0) }
        let attachment = try attach(system, outputs: [2])
        let ring = attachment.members[0].instance.ring
        let b = try XCTUnwrap(factory.device("B"))
        _ = b.pull(frames: 480)
        let before = ring.framesAvailable

        factory.clock.nowNs = 5_000_000_000
        factory.absent.insert("B")
        system.recheckDevices()
        let standIn = try XCTUnwrap(system.graph(forOutput: 2)?.device as? PacedAudioDevice, "the silence stand-in")
        XCTAssertNil(standIn.destination, "its mix goes nowhere")
        XCTAssertFalse(b.isRunning)
        XCTAssertTrue(log.contains("audio output 2: device B lost; silent until it returns"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .silent])
        XCTAssertEqual(recoveries.list, [.audioDeviceLost("B")])

        // Spec 4 §12 — the stand-in consumes on the machine clock, so the decoder keeps flowing and the picture keeps moving.
        standIn.step()
        XCTAssertEqual(ring.framesAvailable, before - PacedAudioDevice.blockFrames, "one block due at the moment it started")
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 20, accuracy: 0.01)
        factory.clock.nowNs += 100_000_000
        standIn.step()
        XCTAssertEqual(ring.framesAvailable, before - 11 * PacedAudioDevice.blockFrames, "a hundred milliseconds later, ten more blocks")
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 120, accuracy: 0.01, "ten ms on B, then a hundred and ten on the stand-in")

        factory.absent.remove("B")
        system.recheckDevices()
        let again = try XCTUnwrap(factory.device("B"))
        XCTAssertTrue(system.graph(forOutput: 2)?.device === again)
        XCTAssertFalse(standIn.isRunning)
        XCTAssertEqual(again.pull(frames: 480)[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 130, accuracy: 0.01)
        XCTAssertTrue(log.contains("audio output 2: device B back"))
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .primary])
        system.stop()
    }

    func test_aFallbackLostFallsToSilenceAndIsTakenAgainWhenItReturns() throws {
        let factory = SoftwareAudioDeviceFactory()
        let log = EngineLog(category: "test-audio")
        let system = makeSystem(twoDevices(fallback1: "C"), factory: factory, log: log)
        _ = try attach(system, outputs: [1])
        factory.absent.insert("A")
        system.recheckDevices()
        XCTAssertEqual(system.deviceStates[0].standing, .fallback)
        let c = try XCTUnwrap(factory.device("C"))

        factory.absent.insert("C")
        system.recheckDevices()
        XCTAssertEqual(system.deviceStates[0].standing, .silent)
        XCTAssertFalse(c.isRunning)
        XCTAssertTrue(system.graph(forOutput: 1)?.device is PacedAudioDevice)
        XCTAssertTrue(log.contains("audio output 1: fallback device C lost; silent until a device returns"), log.recent.map(\.message).joined(separator: "\n"))

        factory.absent.remove("C")
        system.recheckDevices()
        XCTAssertEqual(system.deviceStates[0].standing, .fallback, "the fallback is taken again while the primary is still absent")
        XCTAssertTrue(system.graph(forOutput: 1)?.device === factory.device("C"))
        XCTAssertTrue(log.contains("audio output 1: device A absent; on fallback C"))

        factory.absent.remove("A")
        system.recheckDevices()
        XCTAssertEqual(system.deviceStates[0].standing, .primary, "and the primary is taken back over the fallback")
        XCTAssertTrue(system.graph(forOutput: 1)?.device === factory.device("A"))
        system.stop()
    }

    /// The same rule at startup: a configured device that is absent at launch
    /// gets its fallback or silence, never the default device.
    func test_aDeviceAbsentAtStartupGetsTheSameRuleAndNoGuess() {
        let factory = SoftwareAudioDeviceFactory()
        factory.absent = ["A", "B"]
        let log = EngineLog(category: "test-audio")
        let system = makeSystem(twoDevices(fallback1: "C"), factory: factory, log: log)
        XCTAssertEqual(system.deviceStates.map(\.standing), [.fallback, .silent])
        XCTAssertTrue(log.contains("audio output 1: device A absent; on fallback C"), log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(log.contains("audio output 3: device A absent; silent until it returns"))
        XCTAssertTrue(log.contains("audio output 2: device B absent; silent until it returns"))
        XCTAssertNil(factory.device("default"), "no default-device guess")
        XCTAssertEqual(factory.opened, 1, "only the fallback was opened")
        XCTAssertFalse(log.recent.contains { $0.message.contains("lost") }, "absent at launch, not lost")
        system.stop()
    }

    /// Spec 4 §13 — "audio underruns per device".
    func test_underrunsAreCountedPerDevice() throws {
        let factory = SoftwareAudioDeviceFactory()
        let system = makeSystem(twoDevices(), factory: factory)
        _ = try attach(system, outputs: [1, 2], seconds: 0.1)
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        _ = a.pull(frames: 4800 + 100)
        _ = b.pull(frames: 4800)
        XCTAssertEqual(system.underrunsByDevice, ["A": 100, "B": 0])
        XCTAssertEqual(system.underruns, 100)
        XCTAssertEqual(system.deviceStates.map(\.underruns), [100, 0])
        system.stop()
    }
}
