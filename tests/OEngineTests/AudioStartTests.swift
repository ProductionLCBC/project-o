import XCTest
import OCore
@testable import OEngine

/// Spec 4 §1 — "Every output presents a frame every refresh"; Spec 4 §12 —
/// a device that isn't there gets "silence ... rather than guessing", on a
/// stand-in "that keeps consuming, so the clock and the picture go on".
/// Spec 10 §2 — `hello` "means it is ready".
///
/// Adam's answer at Area 19's third stop (2026-11-16): the engine starts its
/// frame clock first and opens its audio devices on a thread of their own;
/// an output is silent until its device has opened, as it is for a device
/// that is absent. Found by hand that day: Core Audio took fourteen seconds
/// to open a device, and the engine drew nothing until it had.
final class AudioStartTests: XCTestCase {
    func output(_ number: Int, device: String) -> AudioOutput {
        AudioOutput(number: number, label: "out \(number)", device: .uid(device), channels: [0, 1], delayMs: 0)
    }

    func ring(value: Float, seconds: Double = 2) -> AudioRing {
        let ring = AudioRing(channels: 2, capacityFrames: Int(seconds * 48_000) + 16)
        _ = ring.write([Float](repeating: value, count: Int(seconds * 48_000) * 2))
        return ring
    }

    func test_startingDoesNotWaitForADeviceAndTheGraphRunsOnItsStandInUntilItOpens() throws {
        let factory = SlowAudioFactory()
        let log = EngineLog(category: "test-audio")
        let system = AudioSystem(outputs: [output(1, device: "A")], factory: factory, log: log)
        XCTAssertNotNil(promptly { system.start(openingInBackground: true) }, "the start returns at once")
        XCTAssertEqual(factory.opening.wait(timeout: .now() + 5), .success, "the device is opening, on a thread of its own")

        // While it opens, nothing else waits for it: the badge reads, a channel's sound attaches, the meters read.
        let states = try XCTUnwrap(promptly { system.deviceStates }, "the device states are read while the device opens")
        XCTAssertEqual(states.map(\.standing), [.silent], "silent until its device has opened")
        let rings = [ring(value: 0.5)]
        let attached = promptly {
            system.attach(handle: InstanceHandle(rawValue: 1), rings: rings, outputs: [1], inMs: 0, syncOffsetMs: 0, gainDb: 0, playing: true, channel: 1)
        }
        let attachment = try XCTUnwrap(try XCTUnwrap(attached, "a sound attaches while the device opens"))
        XCTAssertNotNil(promptly { system.takeMeters() })

        // The stand-in consumes, so the channel's clock, and with it its picture, goes on.
        let standIn = try XCTUnwrap(system.graph(forOutput: 1)?.device as? PacedAudioDevice, "the silence stand-in")
        XCTAssertTrue(standIn.isRunning)
        standIn.step()
        factory.inner.clock.nowNs += 100_000_000
        standIn.step()
        XCTAssertEqual(system.mediaTimeMs(of: attachment), 110, accuracy: 0.5, "a block, then a hundred milliseconds more, played to nobody")

        // The device opens: the graph moves to it, and the sound is heard from where it has got to.
        factory.gate.signal()
        XCTAssertTrue(waitUntil(5) { system.deviceStates.map(\.standing) == [.primary] })
        let device = try XCTUnwrap(factory.inner.device("A"))
        XCTAssertTrue(system.graph(forOutput: 1)?.device === device)
        XCTAssertFalse(standIn.isRunning)
        XCTAssertEqual(device.pull(frames: 480)[0], 0.5, accuracy: 1e-6)
        XCTAssertFalse(log.recent.contains { $0.message.contains("lost") || $0.message.contains("back") || $0.message.contains("absent") },
                       "opening at launch is neither a loss nor a return: \(log.recent.map(\.message))")
        system.stop()
    }

    /// Spec 4 §12 — "A device absent at launch gets the same rule", opened in the background or not.
    func test_aDeviceAbsentAtLaunchIsSilentAndSaysSoWhenOpenedInTheBackground() throws {
        let factory = SlowAudioFactory()
        factory.inner.absent = ["A"]
        let log = EngineLog(category: "test-audio")
        let system = AudioSystem(outputs: [output(1, device: "A")], factory: factory, log: log)
        system.start(openingInBackground: true)
        XCTAssertTrue(waitUntil(5) { log.contains("audio output 1: device A absent; silent until it returns") })
        XCTAssertEqual(system.deviceStates.map(\.standing), [.silent])
        XCTAssertNil(factory.inner.device("A"), "nothing was opened in its place")
        // It returns: the device list is watched from the first pass on, and a recheck takes it.
        factory.inner.absent = []
        let rechecked = Thread { system.recheckDevices() }
        rechecked.start()
        XCTAssertEqual(factory.opening.wait(timeout: .now() + 5), .success)
        factory.gate.signal()
        XCTAssertTrue(waitUntil(5) { system.deviceStates.map(\.standing) == [.primary] })
        system.stop()
    }

    func test_aStopWhileADeviceIsStillOpeningDoesNotWaitAndLeavesNothingRunning() throws {
        let factory = SlowAudioFactory()
        let system = AudioSystem(outputs: [output(1, device: "A")], factory: factory, log: EngineLog(category: "test-audio"))
        system.start(openingInBackground: true)
        XCTAssertEqual(factory.opening.wait(timeout: .now() + 5), .success)
        let standIn = try XCTUnwrap(system.graph(forOutput: 1)?.device as? PacedAudioDevice)
        XCTAssertNotNil(promptly { system.stop() }, "the stop doesn't wait for the device")
        XCTAssertFalse(standIn.isRunning)
        // The device finishes opening after the stop: it is not left running.
        factory.gate.signal()
        XCTAssertTrue(waitUntil(5) { factory.inner.device("A") != nil })
        let device = try XCTUnwrap(factory.inner.device("A"))
        XCTAssertTrue(waitUntil(5) { !device.isRunning }, "a device that opened after the stop is stopped again")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(device.isRunning)
    }

    /// The plain start is as it was: by the time it returns the devices are open.
    func test_thePlainStartStillOpensEveryDeviceBeforeItReturns() throws {
        let factory = SoftwareAudioDeviceFactory()
        let system = AudioSystem(outputs: [output(1, device: "A"), output(2, device: "B")], factory: factory, log: EngineLog(category: "test-audio"))
        system.start()
        XCTAssertEqual(system.deviceStates.map(\.standing), [.primary, .primary])
        XCTAssertEqual(factory.opened, 2)
        system.stop()
    }

    /// The engine: its frame clock runs, and commands land, while a device is still opening.
    func test_theEngineDrawsWhileItsAudioDeviceIsStillOpening() throws {
        let library = try EngineFixtures.library()
        let machine = try EngineFixtures.spikeMachine()
        let backend = RecordingBackend()
        let factory = SlowAudioFactory()
        let audio = AudioSystem(outputs: [output(1, device: "A")], factory: factory, log: EngineLog(category: "test-audio"))
        let engine = try Engine(library: library, machine: machine, media: EngineFixtures.media, backend: backend, clock: TimerClock(),
                                sinks: machine.outputs.map { CapturingSink(output: $0.number) }, sourceFactory: FakeSourceFactory(),
                                posters: FakePosterProvider(backend: backend), text: FakeTextProvider(backend: backend),
                                variables: VariableProvider(settings: machine.settings), audio: audio)
        XCTAssertNotNil(promptly(5) { engine.start() }, "the engine starts without waiting for its audio device")
        XCTAssertEqual(factory.opening.wait(timeout: .now() + 5), .success)
        engine.enqueue(CommandGroup(id: GroupID.random(), source: CommandSource(kind: .osc),
                                    commands: [Command.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "Amen"])))]))
        XCTAssertTrue(waitUntil(5) { engine.render.totalTicks > 20 }, "frames are drawn while the device opens")
        XCTAssertTrue(waitUntil(5) { engine.control.publishedState.channels[2]?.content.kind == "text" }, "and commands land")
        XCTAssertEqual(audio.deviceStates.map(\.standing), [.silent])
        factory.gate.signal()
        XCTAssertTrue(waitUntil(5) { audio.deviceStates.map(\.standing) == [.primary] })
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }
}
