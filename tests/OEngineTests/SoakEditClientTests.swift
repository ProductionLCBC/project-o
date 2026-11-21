import XCTest
import OCore
@testable import OEngine

/// Area 14 — the soak's editing client: each pass makes a stack no output
/// shows and a channel no stack holds, or removes them again, so the engine
/// rebuilds its textures between ticks (Spec 4 §5), and asks for a picture
/// (Spec 11 §3). Its verdict fails a run whose edits were refused or whose
/// pictures never came, since that run measured neither.
final class SoakEditClientTests: XCTestCase {
    typealias E = EngineFixtures

    func engine() throws -> (engine: HeadlessEngine, library: Library, machine: Machine) {
        let library = try E.library()
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .writable
        return (try HeadlessEngine(library: library, machine: machine, media: E.media), library, machine)
    }

    /// A drawing that makes a few bytes, at once, in a folder of the test's.
    func pictures(for engine: HeadlessEngine) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("o-soak-edit-\(UUID().uuidString)")
        engine.engine.renders = RenderQueue(folder: folder, machineRoot: nil, log: EngineLog(category: "test-soak"), schedule: { $0() },
                                            draw: { job in .success(RenderDrawn(png: Data("png".utf8), size: PixelSize(width: job.request.width, height: 90))) })
        return folder
    }

    func test_aPassMakesAStackAndAChannelAndTheNextRemovesThem() throws {
        let (engine, library, machine) = try engine()
        let folder = pictures(for: engine)
        defer { try? FileManager.default.removeItem(at: folder) }
        engine.tick()
        let client = SoakEditClient(hub: engine.engine.api, library: library, machine: machine, log: engine.log)
        let channels = engine.control.channelTextures.count
        let stacks = engine.control.stackRings.count

        client.pass()
        engine.tick()
        XCTAssertEqual(engine.control.lastRebuild?.channelsMade, [4])
        XCTAssertEqual(engine.control.lastRebuild?.stacksMade, [3])
        XCTAssertEqual(engine.control.channelTextures.count, channels + 1)
        XCTAssertEqual(engine.control.stackRings.count, stacks + 1)

        client.pass()
        engine.tick()
        XCTAssertEqual(engine.control.lastRebuild?.channelsGone, [4])
        XCTAssertEqual(engine.control.lastRebuild?.stacksGone, [3])
        XCTAssertEqual(engine.control.channelTextures.count, channels)
        XCTAssertEqual(engine.control.stackRings.count, stacks)
        XCTAssertEqual(engine.engine.library.channels.map(\.number), library.channels.map(\.number), "the library is as it was")

        let verdict = client.verdict()
        XCTAssertEqual(verdict.failures, [])
        XCTAssertTrue(verdict.lines.joined(separator: "\n").contains("2 passes; 2 of 2 edit groups applied (stack 3 and channel 4"), "\(verdict.lines)")
        XCTAssertTrue(verdict.lines.joined(separator: "\n").contains("2 of 2 pictures drawn"), "\(verdict.lines)")
    }

    func test_aRunWhoseEditsOrPicturesWereRefusedFails() throws {
        // A read-only library, and an engine with no thumbnail job.
        let library = try E.library()
        var machine = try E.spikeMachine()
        machine.settings.libraryMode = .readOnlyMasters
        let engine = try HeadlessEngine(library: library, machine: machine, media: E.media)
        engine.tick()
        let client = SoakEditClient(hub: engine.engine.api, library: library, machine: machine, log: engine.log)
        client.pass()
        engine.tick()
        let verdict = client.verdict()
        XCTAssertTrue(verdict.failures.contains { $0.contains("was not applied") }, "\(verdict.failures)")
        XCTAssertTrue(verdict.failures.contains { $0.contains("was refused") }, "\(verdict.failures)")
    }

    func test_aRunTooShortForAPassSaysSo() throws {
        let (engine, library, machine) = try engine()
        let client = SoakEditClient(hub: engine.engine.api, library: library, machine: machine, log: engine.log)
        XCTAssertTrue(client.verdict().failures.contains { $0.contains("made no pass") })
    }
}
