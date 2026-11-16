import XCTest
import OCore
@testable import OEngine
import protocol OEngine.AudioDevice   // the engine's, not Core Audio's type of the same name

/// Spec 10 §2, "The Mach channel" — "Meters: 15 times a second, for each
/// channel whose content has sound, the peak and RMS level in dBFS since the
/// last frame, after gain, of its loudest audio channel. A channel without
/// sound sends none." Spec 10 §18, Area 19, the Mach channel.
///
/// The levels are measured in the audio callback, with atomics and memory the
/// instance holds from the start, and taken by the Mach channel's sender; the
/// device here is the software one, pulled by the test.
final class AudioMeterTests: XCTestCase {
    func output(_ number: Int, device: String) -> AudioOutput {
        AudioOutput(number: number, label: "out \(number)", device: .uid(device), channels: [0, 1], delayMs: 0)
    }

    /// A stereo ring holding `seconds` of what `sample` gives for each frame and channel.
    func ring(seconds: Double = 2, _ sample: (Int, Int) -> Float) -> AudioRing {
        let frames = Int(seconds * 48_000)
        let ring = AudioRing(channels: 2, capacityFrames: frames + 16)
        var samples = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            samples[f * 2] = sample(f, 0)
            samples[f * 2 + 1] = sample(f, 1)
        }
        _ = ring.write(samples)
        return ring
    }

    func system(_ outputs: [AudioOutput], factory: SoftwareAudioDeviceFactory) -> AudioSystem {
        let system = AudioSystem(outputs: outputs, factory: factory, log: EngineLog(category: "test-meters"))
        system.start()
        return system
    }

    func attach(_ system: AudioSystem, rings: [AudioRing], outputs: [Int] = [1], channel: Int, gainDb: Double = 0, playing: Bool = true,
                handle: Int32 = 1) throws -> AudioAttachment {
        try XCTUnwrap(system.attach(handle: InstanceHandle(rawValue: handle), rings: rings, outputs: outputs, inMs: 0, syncOffsetMs: 0,
                                    gainDb: gainDb, playing: playing, channel: channel))
    }

    func test_aChannelsLevelIsItsPeakAndRmsInDecibelsAfterGain() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A")], factory: factory)
        defer { audio.stop() }
        // A full-scale sine at 1 kHz: its peak is 0 dBFS and its RMS 3.01 dB under it.
        let sine = ring { f, _ in sinf(2 * .pi * 1000 * Float(f) / 48_000) }
        _ = try attach(audio, rings: [sine], channel: 2, gainDb: -6)
        let device = try XCTUnwrap(factory.device("A"))
        _ = device.pull(frames: 4800)
        let levels = audio.takeMeters()
        XCTAssertEqual(levels.map(\.channel), [2], "the channel the sound belongs to")
        let level = try XCTUnwrap(levels.first)
        XCTAssertEqual(level.peak, -6, accuracy: 0.05, "the peak, after the channel's gain of -6 dB")
        XCTAssertEqual(level.rms, -9.01, accuracy: 0.05, "the RMS level, 3.01 dB under a sine's peak")
    }

    func test_theLevelIsOfTheLoudestAudioChannel() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A")], factory: factory)
        defer { audio.stop() }
        _ = try attach(audio, rings: [ring { _, c in c == 0 ? 0.1 : 0.5 }], channel: 1)
        _ = try XCTUnwrap(factory.device("A")).pull(frames: 4800)
        let level = try XCTUnwrap(audio.takeMeters().first)
        XCTAssertEqual(level.peak, -6.02, accuracy: 0.01, "the right channel's 0.5, not the left's 0.1 or their sum")
        XCTAssertEqual(level.rms, -6.02, accuracy: 0.01)
    }

    /// "since the last frame": each take starts the next measure.
    func test_eachTakeMeasuresOnlyWhatPlayedSinceTheLast() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A")], factory: factory)
        defer { audio.stop() }
        // Half a second at 0.5, then quiet at 0.05.
        _ = try attach(audio, rings: [ring { f, _ in f < 24_000 ? 0.5 : 0.05 }], channel: 1)
        let device = try XCTUnwrap(factory.device("A"))
        _ = device.pull(frames: 24_000)
        XCTAssertEqual(try XCTUnwrap(audio.takeMeters().first).peak, -6.02, accuracy: 0.01)
        _ = device.pull(frames: 3200)
        let quiet = try XCTUnwrap(audio.takeMeters().first)
        XCTAssertEqual(quiet.peak, -26.02, accuracy: 0.01, "the loud half second is not in this measure")
        XCTAssertEqual(quiet.rms, -26.02, accuracy: 0.01, "nor counted twice, nor spread over it")
        // Nothing pulled since: the channel still has sound, and its level is the floor.
        let idle = try XCTUnwrap(audio.takeMeters().first)
        XCTAssertEqual(idle.peak, MachWire.floorDecibels)
        XCTAssertEqual(idle.rms, MachWire.floorDecibels)
    }

    /// "A channel without sound sends none"; a channel whose sound is paused
    /// still has sound, and reads the floor.
    func test_aChannelWithoutSoundHasNoReadingAndAPausedOneReadsTheFloor() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A")], factory: factory)
        defer { audio.stop() }
        XCTAssertEqual(audio.takeMeters(), [], "nothing attached: no reading")
        let attachment = try attach(audio, rings: [ring { _, _ in 0.5 }], channel: 3, playing: false)
        let device = try XCTUnwrap(factory.device("A"))
        _ = device.pull(frames: 4800)
        XCTAssertEqual(audio.takeMeters(), [MeterReading(channel: 3, peak: MachWire.floorDecibels, rms: MachWire.floorDecibels)], "paused: silent, and still a channel with sound")
        audio.setPlaying(true, for: attachment)
        _ = device.pull(frames: 4800)
        XCTAssertEqual(try XCTUnwrap(audio.takeMeters().first).peak, -6.02, accuracy: 0.01)
        audio.detach(attachment)
        _ = device.pull(frames: 480)
        XCTAssertEqual(audio.takeMeters(), [], "its sound gone, the channel sends none")
    }

    /// Area 19 reading — a channel routed to more than one device is measured
    /// on its clock device, once (Spec 4 §11: "the first-numbered device is the clock").
    func test_aChannelOnTwoDevicesIsMeasuredOnceOnItsClockDevice() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A"), output(2, device: "B")], factory: factory)
        defer { audio.stop() }
        let rings = [ring { _, _ in 0.5 }, ring { _, _ in 0.5 }]
        _ = try attach(audio, rings: rings, outputs: [1, 2], channel: 1)
        let a = try XCTUnwrap(factory.device("A"))
        let b = try XCTUnwrap(factory.device("B"))
        _ = b.pull(frames: 4800)
        XCTAssertEqual(audio.takeMeters(), [MeterReading(channel: 1, peak: MachWire.floorDecibels, rms: MachWire.floorDecibels)], "device B's delivery is not the measure")
        _ = a.pull(frames: 4800)
        let levels = audio.takeMeters()
        XCTAssertEqual(levels.count, 1, "one reading for the channel, not one per device")
        XCTAssertEqual(try XCTUnwrap(levels.first).peak, -6.02, accuracy: 0.01)
    }

    /// The transition's envelope is part of "after gain": a channel fading out reads lower as it goes.
    func test_theLevelFollowsAnAudioTransitionAndBothInstancesReadAsOneChannel() throws {
        let factory = SoftwareAudioDeviceFactory()
        let audio = system([output(1, device: "A")], factory: factory)
        defer { audio.stop() }
        let outgoing = try attach(audio, rings: [ring { _, _ in 0.5 }], channel: 1, handle: 1)
        let incoming = try attach(audio, rings: [ring { _, _ in 0.125 }], channel: 1, handle: 2)
        audio.startTransition(outgoing: outgoing, incoming: incoming, type: .crossfade, ms: 100, offsetMs: 0)
        let device = try XCTUnwrap(factory.device("A"))
        _ = device.pull(frames: 4800)
        let during = audio.takeMeters()
        XCTAssertEqual(during.count, 1, "the outgoing and the incoming instance are one channel")
        XCTAssertEqual(try XCTUnwrap(during.first).peak, -6.02, accuracy: 0.05, "the outgoing, at the start of the fade")
        _ = device.pull(frames: 4800)
        XCTAssertEqual(try XCTUnwrap(audio.takeMeters().first).peak, -18.06, accuracy: 0.05, "after it, the incoming alone")
    }

    /// A factory whose devices open only when the test lets them: a HAL device can take seconds to start.
    final class SlowFactory: AudioDeviceFactory, @unchecked Sendable {
        let inner = SoftwareAudioDeviceFactory()
        let opening = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)

        func isPresent(key: String) -> Bool { true }
        func makeDevice(key: String, channelCount: Int) -> (any AudioDevice)? {
            opening.signal()
            gate.wait()
            return inner.makeDevice(key: key, channelCount: channelCount)
        }
        func makeSilenceDevice(name: String, channelCount: Int) -> PacedAudioDevice { inner.makeSilenceDevice(name: name, channelCount: channelCount) }
        func observeDeviceList(_ handler: @escaping @Sendable () -> Void) { inner.observeDeviceList(handler) }
        func stopObserving() { inner.stopObserving() }
    }

    /// Found on the dev Mac on 2026-11-16: a launch whose audio device was
    /// slow to open left the Mach channel sending nothing, because the meters
    /// were read under the lock the system holds while a device opens. The
    /// meters have their own lock now, and reading them never waits on a device.
    func test_takingTheMetersNeverWaitsOnADeviceThatIsSlowToOpen() throws {
        let factory = SlowFactory()
        let audio = AudioSystem(outputs: [output(1, device: "A")], factory: factory, log: EngineLog(category: "test-meters"))
        let starter = Thread { audio.start() }
        starter.start()
        XCTAssertEqual(factory.opening.wait(timeout: .now() + 5), .success, "the device is opening, and the system holds its lock")
        let taken = DispatchSemaphore(value: 0)
        let taker = Thread {
            _ = audio.takeMeters()
            taken.signal()
        }
        taker.start()
        let prompt = taken.wait(timeout: .now() + 2)
        factory.gate.signal()   // let the device open whatever the outcome, so the test ends
        XCTAssertEqual(prompt, .success, "the meters were read while the device was still opening")
        XCTAssertTrue(waitUntil(5) { starter.isFinished })
        audio.stop()
    }

    /// A linear level as dBFS, with a floor so silence is a number.
    func test_decibels() {
        XCTAssertEqual(MeterReading.decibels(1), 0)
        XCTAssertEqual(MeterReading.decibels(0.5), -6.0206, accuracy: 0.001)
        XCTAssertEqual(MeterReading.decibels(0), MachWire.floorDecibels)
        XCTAssertEqual(MeterReading.decibels(1e-9), MachWire.floorDecibels, "never below the floor")
    }

    /// The callback and the taker run at once without a lock: over many
    /// takes, every frame the device pulled is measured exactly once.
    func test_takesRacingTheCallbackNeitherLoseNorDoubleCountFrames() throws {
        let device = SoftwareAudioDevice()
        let graph = AudioGraph(device: device, outputs: [output(1, device: "software")])
        try graph.start()
        let source = ring(seconds: 4) { _, _ in 0.5 }
        let instance = AudioInstance(handle: InstanceHandle(rawValue: 1), ring: source, inMs: 0, syncOffsetMs: 0,
                                     routing: graph.routing(forAudioOutputs: [1], instanceChannels: 2), meterChannel: 1)
        XCTAssertTrue(graph.add(instance, gainDb: 0))
        let pulls = 3000
        let puller = Thread { for _ in 0..<pulls { _ = device.pull(frames: 64) } }
        puller.start()
        var frames: Int64 = 0
        var square = 0.0
        var takes = 0
        while true {
            let ended = puller.isFinished   // read before the take, so the last take covers everything pulled
            let taken = instance.takeMeter()
            frames += taken.frames
            square += taken.square
            takes += 1
            if ended { break }
        }
        XCTAssertEqual(frames, Int64(pulls * 64), "every frame once, over \(takes) takes")
        XCTAssertEqual(square, Double(pulls * 64) * 0.25, accuracy: 0.01, "and its energy once")
    }
}
