import Foundation
import IOSurface
import XCTest
@testable import OMach
@testable import OApp

/// Spec 10 §2 — "The preview surfaces, the channel pictures and the meters
/// come over a Mach channel"; Area 13 reading: the channel has failed when
/// the lookup or the connect fails, and is tried again every five seconds.
@MainActor
final class MachLinkTests: XCTestCase {
    /// A Mach channel the test fills in.
    final class FakeSource: MachSource, @unchecked Sendable {
        private let lock = NSLock()
        private var held = MachClient.State()
        private var fails = false
        private var names: [String] = []
        private var closed = 0

        var state: MachClient.State {
            get { lock.lock(); defer { lock.unlock() }; return held }
            set { lock.lock(); held = newValue; lock.unlock() }
        }

        var isFailing: Bool {
            get { lock.lock(); defer { lock.unlock() }; return fails }
            set { lock.lock(); fails = newValue; lock.unlock() }
        }

        var connects: [String] { lock.lock(); defer { lock.unlock() }; return names }
        var disconnects: Int { lock.lock(); defer { lock.unlock() }; return closed }

        func connect(name: String) throws {
            lock.lock()
            defer { lock.unlock() }
            names.append(name)
            if fails { throw CocoaError(.fileNoSuchFile) }
        }

        func disconnect() {
            lock.lock()
            closed += 1
            lock.unlock()
        }
    }

    private func link(_ source: FakeSource, _ clock: ManualClock) -> MachLink {
        MachLink(source: source, clock: clock) { work, done in done(work()) }
    }

    private func surface() throws -> IOSurfaceRef {
        try XCTUnwrap(IOSurfaceCreate([kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4] as CFDictionary))
    }

    func test_itConnectsToTheServiceHelloNames() {
        let source = FakeSource()
        let link = link(source, ManualClock())
        var changes = 0
        link.onChange = { changes += 1 }
        link.connect(name: "org.lcbc.projecto.engine.51e2")
        XCTAssertTrue(link.isConnected)
        XCTAssertEqual(source.connects, ["org.lcbc.projecto.engine.51e2"])
        XCTAssertEqual(changes, 1)
        link.connect(name: "org.lcbc.projecto.engine.51e2")
        XCTAssertEqual(source.connects.count, 1, "the same engine isn't connected to twice")
    }

    func test_aFailedConnectIsTriedAgainEveryFiveSeconds() {
        let source = FakeSource()
        source.isFailing = true
        let clock = ManualClock()
        let link = link(source, clock)
        link.connect(name: "engine.a")
        XCTAssertFalse(link.isConnected)
        clock.advance(by: 4.9)
        XCTAssertEqual(source.connects.count, 1)
        clock.advance(by: 0.1)
        XCTAssertEqual(source.connects.count, 2)
        source.isFailing = false
        clock.advance(by: 5)
        XCTAssertTrue(link.isConnected)
        clock.advance(by: 30)
        XCTAssertEqual(source.connects.count, 3, "once it is up it is left alone: there is no staleness timer")
    }

    func test_whenTheEngineGoesItStopsTryingAndHoldsNothing() throws {
        let source = FakeSource()
        source.isFailing = true
        let clock = ManualClock()
        let link = link(source, clock)
        link.connect(name: "engine.a")
        link.disconnect()
        clock.advance(by: 20)
        XCTAssertEqual(source.connects.count, 1)
        source.isFailing = false
        link.connect(name: "engine.b")
        var state = MachClient.State()
        state.previews[1] = MachSurfaceSet(number: 1, width: 4, height: 4, surfaces: [try surface()])
        state.newestPreview[1] = 0
        source.state = state
        link.poll()
        XCTAssertNotNil(link.preview(stack: 1))
        link.disconnect()
        XCTAssertNil(link.preview(stack: 1))
        XCTAssertEqual(source.disconnects, 1)
    }

    func test_itReadsTheNewestSurfaceOfEachStackAndChannelAndTheMeters() throws {
        let source = FakeSource()
        let link = link(source, ManualClock())
        link.connect(name: "engine.a")
        let (first, second, picture) = (try surface(), try surface(), try surface())
        var state = MachClient.State()
        state.previews[1] = MachSurfaceSet(number: 1, width: 4, height: 4, surfaces: [first, second])
        state.newestPreview[1] = 1
        state.pictures[2] = MachSurfaceSet(number: 2, width: 4, height: 4, surfaces: [picture])
        state.newestPicture[2] = 0
        state.meters = [MeterReading(channel: 1, peak: 0.5, rms: 0.25)]
        source.state = state
        XCTAssertNil(link.preview(stack: 1), "nothing until the views ask it to look")
        link.poll()
        XCTAssertTrue(link.preview(stack: 1) === second, "the surface the newest frame names")
        XCTAssertTrue(link.picture(channel: 2) === picture)
        XCTAssertNil(link.preview(stack: 9))
        XCTAssertNil(link.picture(channel: 1), "a channel with no pixel content has no picture")
        XCTAssertEqual(try XCTUnwrap(link.level(channel: 1)), -6.02, accuracy: 0.01, "half of full scale, in dBFS")
        XCTAssertNil(link.level(channel: 2), "no sound, no meter")
        state.newestPreview[1] = 5
        source.state = state
        link.poll()
        XCTAssertNil(link.preview(stack: 1), "a frame that names a surface that isn't there shows nothing")
    }
}
