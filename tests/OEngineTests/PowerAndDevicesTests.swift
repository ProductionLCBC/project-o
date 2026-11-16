import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §2, "The engine as a process" — "It holds a latency-critical
/// activity so macOS never naps or throttles it, and while any output
/// presents it keeps the displays and the system from sleeping."
final class PowerTests: XCTestCase {
    func test_theActivityIsTakenOnceAtLaunch() {
        let fake = FakePower()
        let power = OutputPower(power: fake)
        power.begin()
        XCTAssertEqual(fake.activities, 1)
        XCTAssertEqual(fake.calls, [], "no output presents yet, so nothing is kept awake")
    }

    func test_theMacIsKeptAwakeWhileAnyOutputPresentsAndOnlyThen() {
        let fake = FakePower()
        let power = OutputPower(power: fake)
        power.update([1: .absent, 2: .absent])
        XCTAssertEqual(fake.calls, [])
        power.update([1: .presenting, 2: .absent])
        XCTAssertEqual(fake.calls, [true])
        power.update([1: .presenting, 2: .presenting])
        power.update([1: .paused, 2: .presenting])
        XCTAssertEqual(fake.calls, [true], "asked once, however many builds pass")
        power.update([1: .paused, 2: .released])
        XCTAssertEqual(fake.calls, [true, false], "nothing presents: the displays and the system may sleep")
        power.update([1: .presenting, 2: .released])
        power.end()
        XCTAssertEqual(fake.calls, [true, false, true, false], "and a stopped engine holds nothing")
    }

    /// The real assertions, taken and given back; nothing is left held.
    func test_theSystemsAssertionsAreTakenAndGivenBack() {
        let power = SystemPower()
        power.beginActivity()
        power.beginActivity()
        XCTAssertTrue(power.hasActivity)
        XCTAssertFalse(power.isKeepingAwake)
        power.keepAwake(true)
        power.keepAwake(true)
        XCTAssertTrue(power.isKeepingAwake)
        power.keepAwake(false)
        XCTAssertFalse(power.isKeepingAwake)
    }

    /// An engine tells the rule its outputs' states after every build: the
    /// harness's sinks present, so the Mac is kept awake from the first tick
    /// and let go at the stop.
    func test_anEngineKeepsTheMacAwakeWhileItsOutputsPresent() throws {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        let fake = FakePower()
        engine.engine.power = OutputPower(power: fake)
        XCTAssertEqual(engine.engine.outputStandings(), [1: OutputStanding.presenting, 2: OutputStanding.presenting])
        engine.tick()
        engine.tick()
        XCTAssertEqual(fake.calls, [true])
        engine.engine.power?.end()
        XCTAssertEqual(fake.calls, [true, false])
    }
}

/// Spec 10 §3, the `devices` query — "Screens (`display:<uuid>`, name, frame,
/// current mode, and whether it is mirrored), DeckLink output ports
/// (`decklink:<id>`, name, the modes it plays) and audio output devices (UID,
/// name, channel count, whether it is the system default)": what this Mac
/// answers has that shape, whatever it has plugged in.
final class SystemDevicesTests: XCTestCase {
    @MainActor
    func test_thisMacsScreensAreNamedByTheirDisplayIds() {
        let devices = SystemDevices().devices()
        for screen in devices.screens {
            XCTAssertTrue(screen.device.hasPrefix("display:"), screen.device)
            XCTAssertEqual(screen.uuid, screen.uuid.uppercased())
            XCTAssertNotNil(UUID(uuidString: screen.uuid), "\(screen.device) holds a uuid")
            XCTAssertFalse(screen.name.isEmpty)
            XCTAssertGreaterThan(screen.frame.width, 0)
            XCTAssertGreaterThan(screen.mode.width, 0)
            XCTAssertGreaterThan(screen.mode.rate.num, 0)
            XCTAssertFalse(screen.mode.interlaced)
            XCTAssertNotNil(SystemDevices.screen(uuid: screen.uuid.lowercased()), "the id finds its screen again, whatever its case")
        }
        XCTAssertEqual(Set(devices.screens.map(\.device)).count, devices.screens.count, "one entry a screen")
        XCTAssertNil(SystemDevices.screen(uuid: "00000000-0000-4000-8000-000000000000"))
    }

    @MainActor
    func test_thisMacsAudioOutputsAndPortsHaveTheirShape() {
        let devices = SystemDevices().devices()
        for device in devices.audio {
            XCTAssertFalse(device.uid.isEmpty)
            XCTAssertFalse(device.name.isEmpty)
            XCTAssertGreaterThan(device.channels, 0, "only devices that can play")
        }
        XCTAssertLessThanOrEqual(devices.audio.filter(\.isDefault).count, 1, "one system default at most")
        for port in devices.ports {
            XCTAssertTrue(port.device.hasPrefix("decklink:"), port.device)
            XCTAssertFalse(port.name.isEmpty)
        }
    }

    func test_theFakeListAnswersWhatItWasGivenAndCanChange() {
        let fake = FakeDevices(DetectedDevices(screens: [FakeDevices.screen("AAAAAAAA-0000-4000-8000-000000000001", hertz: 59.94)]))
        XCTAssertEqual(fake.devices().screens.map(\.mode.rate), [FrameRate(num: 60000, den: 1001)])
        fake.list.screens = []
        XCTAssertEqual(fake.devices(), DetectedDevices())
    }
}
