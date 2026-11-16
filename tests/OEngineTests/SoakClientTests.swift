import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §18, Area 19, the soak — "The soak scenario gains a client holding
/// the Mach channel, so the previews and the channel pictures count in its
/// GPU p99 (Spec 4 §13)." The client, against a headless engine and its
/// channel; and the screens the soak's display outputs take, since an output
/// "opens only on the screen its device names" (Spec 10 §2) and the spike's
/// name none a Mac has. The soak itself is not run here.
final class SoakClientTests: XCTestCase {
    func engineWithItsChannel() throws -> (HeadlessEngine, MachChannel) {
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        let surfaces = TestSurfaces(engine.control)
        do {
            return (engine, try engine.engine.openMachChannel(surface: { surfaces.find($0) }))
        } catch {
            if ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil {
                throw XCTSkip("hosted runner: the bootstrap namespace refused the name (\(error)); the Mach tests run on the bench Mac")
            }
            throw error
        }
    }

    func test_theSoaksClientHoldsTheChannelSoThePicturesAreMadeAndItsFramesArrive() throws {
        let (engine, channel) = try engineWithItsChannel()
        defer { channel.stop() }
        XCTAssertFalse(engine.control.picturesWanted.load(ordering: .relaxed), "with nobody holding the channel no picture is made")
        let client = SoakMachClient()
        client.hold(run: engine.engine.run)
        defer { client.release() }
        XCTAssertTrue(waitUntil(5) { engine.control.picturesWanted.load(ordering: .relaxed) }, "held: the channel pictures are a consumer now (Spec 4 §2)")
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        XCTAssertTrue(waitUntil(5) {
            engine.tick(count: 4)
            let verdict = client.verdict()
            return verdict.failures.isEmpty && verdict.lines.contains { $0.contains("channel 1") && !$0.contains(" 0 pictures named") }
        }, "previews for every stack and the clip's picture reached the client: \(client.verdict())")
        let verdict = client.verdict()
        XCTAssertEqual(verdict.failures, [])
        XCTAssertTrue(verdict.lines.contains { $0.contains("stack 1: three surfaces") }, verdict.lines.joined(separator: "\n"))
        XCTAssertTrue(verdict.lines.contains { $0.contains("stack 2: three surfaces") })
    }

    func test_aClientThatGotNothingFailsTheRun() throws {
        // No engine under that name: the run did not measure the previews and the pictures.
        let stray = SoakMachClient()
        stray.hold(run: UUID())
        let nothing = stray.verdict()
        XCTAssertEqual(nothing.failures.count, 1)
        XCTAssertTrue(nothing.failures[0].contains("did not connect"), nothing.failures[0])

        // A channel that names no frame: the engine never ticked.
        let (engine, channel) = try engineWithItsChannel()
        defer { channel.stop() }
        let client = SoakMachClient()
        client.hold(run: engine.engine.run)
        defer { client.release() }
        XCTAssertTrue(waitUntil(5) { client.verdict().lines.contains { $0.contains("stack 2: three surfaces") } })
        let idle = client.verdict()
        XCTAssertEqual(idle.failures, ["no preview frame was named for stack 1 over the Mach channel", "no preview frame was named for stack 2 over the Mach channel"])
    }

    // MARK: - The soak's screens

    func display(_ number: Int, _ device: String) -> Output {
        Output(number: number, defaultStack: number, label: "out \(number)", kind: .display, device: device)
    }

    func test_theSoaksDisplayOutputsTakeTheScreensInOrderAndNothingElseChanges() throws {
        let machine = try EngineFixtures.spikeMachine()
        XCTAssertEqual(machine.outputs.map(\.device), ["display:main", "display:confidence"], "the spike names screens no Mac has")
        let bound = OutputPlacement.bound(machine.outputs, to: ["display:AA", "display:BB"])
        XCTAssertEqual(bound.map(\.device), ["display:AA", "display:BB"])
        var same = bound
        for index in same.indices { same[index].device = machine.outputs[index].device }
        XCTAssertEqual(same, machine.outputs, "its number, format, stack and transitions are the machine's")

        // Fewer screens than outputs: the rest keep their device, and stay absent.
        XCTAssertEqual(OutputPlacement.bound(machine.outputs, to: ["display:AA"]).map(\.device), ["display:AA", "display:confidence"])
        XCTAssertEqual(OutputPlacement.bound(machine.outputs, to: []).map(\.device), ["display:main", "display:confidence"])
        // By output number, whatever the list's order; and a card's output is left alone.
        let sdi = Output(number: 2, defaultStack: 2, kind: .sdi, device: "decklink:1")
        let mixed = OutputPlacement.bound([display(3, "display:c"), sdi, display(1, "display:a")], to: ["display:AA", "display:BB", "display:CC"])
        XCTAssertEqual(mixed.map(\.device), ["display:BB", "decklink:1", "display:AA"])
    }

    func test_withNoScreensNamedTheSoakUsesEveryScreenLeftToRight() {
        func screen(_ id: String, x: Double, y: Double = 0) -> DetectedScreen {
            DetectedScreen(device: "display:" + id, name: id, frame: ScreenFrame(x: x, y: y, width: 1920, height: 1080), mode: VideoFormat())
        }
        XCTAssertEqual(OutputPlacement.soakScreens([screen("RIGHT", x: 1920), screen("LEFT", x: -1920), screen("MIDDLE", x: 0)]),
                       ["display:LEFT", "display:MIDDLE", "display:RIGHT"])
        XCTAssertEqual(OutputPlacement.soakScreens([screen("LOWER", x: 0, y: 1080), screen("UPPER", x: 0, y: 0)]), ["display:UPPER", "display:LOWER"])
        XCTAssertEqual(OutputPlacement.soakScreens([]), [])
    }
}
