import Foundation
import IOSurface
import XCTest
import OCore
@testable import OEngine

/// Spec 10 §2, "The Mach channel" — previews: "each stack's preview as three
/// IOSurfaces, sent as Mach ports with the stack's number and size, at
/// connect and whenever a stack's surfaces are made again. After each preview
/// frame completes, a message names the stack and the surface that holds the
/// newest frame, at most 30 a second per stack, and the engine writes the
/// next frame into the oldest of the three". Channel pictures (choice U-3)
/// and meters likewise. Spec 10 §18, Area 19, the Mach channel.
///
/// The engine here is the headless one, whose backend draws nothing, so the
/// surfaces behind its textures are made by the test; what is sent, when and
/// to whom is the engine's own. The pixels themselves are
/// `MetalMachChannelTests`'.
final class MachChannelEngineTests: XCTestCase {
    var engine: HeadlessEngine!
    var channel: MachChannel!
    var client: MachClient!

    override func tearDown() {
        client?.disconnect()
        channel?.stop()
    }

    /// An engine with its Mach channel open and one client holding it.
    func open(library: Library? = nil, machine: Machine? = nil, connect: Bool = true, allows: @escaping @Sendable (uid_t) -> Bool = { $0 == geteuid() }) throws {
        engine = try HeadlessEngine(library: try library ?? EngineFixtures.library(), machine: try machine ?? EngineFixtures.spikeMachine(), media: EngineFixtures.media)
        let surfaces = TestSurfaces(engine.control)
        do {
            channel = try engine.engine.openMachChannel(surface: { surfaces.find($0) }, allows: allows)
        } catch {
            if ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil {
                throw XCTSkip("hosted runner: the bootstrap namespace refused the name (\(error)); the Mach tests run on the bench Mac")
            }
            throw error
        }
        client = MachClient()
        guard connect else { return }
        try client.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { self.client.state.previewSets == 2 && self.client.state.pictureSets == 3 }, "its surfaces arrive at connect")
    }

    /// Ticks, then waits for the sender to have passed on what the render
    /// thread drew and for the client to have taken it: each is a thread of
    /// its own, so the wait is for the client's count to stand still.
    func tick(_ count: Int = 1) {
        engine.tick(count: count)
        _ = waitUntil(2) { self.engine.engine.render.auxNotices.unread == 0 }
        let deadline = Date().addingTimeInterval(2)
        var seen = client.state.messages
        var still = 0
        while still < 6, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
            let now = client.state.messages
            still = now == seen ? still + 1 : 0
            seen = now
        }
    }

    func test_theChannelIsNamedForTheRunAsHelloSays() throws {
        try open(connect: false)
        XCTAssertEqual(channel.name, MachServiceName.engine(run: engine.engine.run))
        XCTAssertEqual(channel.clientCount, 0)
        XCTAssertFalse(engine.control.picturesWanted.load(ordering: .relaxed), "nobody holds the channel: no picture work")
    }

    func test_aClientGetsThreeSurfacesPerStackAndThreePerChannelAtConnect() throws {
        try open()
        let state = client.state
        XCTAssertEqual(state.previews.keys.sorted(), [1, 2], "each stack")
        XCTAssertEqual(state.pictures.keys.sorted(), [1, 2, 3], "each channel")
        for set in state.previews.values {
            XCTAssertEqual(set.surfaces.count, 3)
            XCTAssertEqual(set.width, 480, "a quarter of the 1920-wide stack, sent with its size")
            XCTAssertEqual(set.height, 270)
            XCTAssertEqual(Set(set.surfaces.map { IOSurfaceGetID($0) }).count, 3, "three different surfaces")
        }
        for set in state.pictures.values {
            XCTAssertEqual(set.surfaces.count, 3)
            XCTAssertEqual(set.width, 256)
            XCTAssertEqual(set.height, 144, "256 by 144 pixels")
        }
        XCTAssertEqual(channel.clientCount, 1)
        XCTAssertTrue(engine.control.picturesWanted.load(ordering: .relaxed), "a client holds the channel")
    }

    /// "After each preview frame completes, a message names the stack and the
    /// surface that holds the newest frame, at most 30 a second per stack,
    /// and the engine writes the next frame into the oldest of the three".
    func test_afterEachPreviewFrameAMessageNamesItsSurfaceAndTheSurfacesAreWrittenInTurn() throws {
        try open()
        tick(60)   // a second at 60 Hz
        let frames = client.state.previewFrames
        for stack in [1, 2] {
            let slots = frames.filter { $0.stack == stack }.map(\.slot)
            XCTAssertEqual(slots.count, 30, "30 a second per stack")
            XCTAssertEqual(slots, (0..<30).map { $0 % 3 }, "in turn: the next frame goes into the oldest of the three")
        }
        XCTAssertEqual(client.state.newestPreview, [1: 2, 2: 2], "the last named is the newest")
        // The surface a frame message names is never the one the next frame is drawn into.
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertTrue(plan.auxPasses.isEmpty, "frame 59 is no preview tick")
        tick()     // frame 60: the next previews are planned into the next surfaces
        let next = try XCTUnwrap(engine.lastPlan).auxPasses.filter { $0.kind == .preview }
        XCTAssertEqual(next.map(\.slot), [0, 0])
        XCTAssertEqual(next.first?.target, engine.control.previewSurfaces[1]?[0])
    }

    /// "a live picture of each channel ... An aux pass, at most 30 times a
    /// second like the previews, makes them for each channel with pixel
    /// content"; "Text gets no picture".
    func test_aChannelWithPixelContentGetsPicturesAndTextGetsNone() throws {
        try open()
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        engine.send("channel 2 write text \"Great is Thy faithfulness\"")
        tick(60)
        let frames = client.state.pictureFrames
        XCTAssertEqual(Set(frames.map(\.channel)), [1], "the media channel, and not the text channel or the empty one")
        XCTAssertGreaterThanOrEqual(frames.count, 29)
        XCTAssertLessThanOrEqual(frames.count, 30, "at most 30 times a second")
        XCTAssertEqual(frames.map(\.slot), (0..<frames.count).map { $0 % 3 }, "written in turn, as the previews are")
        let plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertTrue(plan.channelPasses.contains { $0.channel == 1 && !$0.auxOnly }, "stack 1 samples channel 1: its pass is live work, and the picture adds none")
    }

    /// "a channel with pixel content that no stack pass has sampled since the
    /// last one runs its channel pass as aux work" — while a client holds the
    /// channel, and only then.
    func test_aChannelNoStackHoldsRunsItsPassAsAuxWorkOnlyWhileAClientHoldsTheChannel() throws {
        var machine = try EngineFixtures.spikeMachine()
        machine.stacks[0].slots = [StackSlot(channel: 2)]                          // no stack holds channel 1
        machine.stacks[1].slots = [StackSlot(channel: 2), StackSlot(channel: 3)]
        try open(machine: machine)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        tick(2)
        tick()   // frame 2: a preview tick
        var plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertEqual(plan.channelPasses.filter { $0.channel == 1 }.map(\.auxOnly), [true], "its channel pass, as aux work")
        XCTAssertEqual(plan.auxPasses.filter { $0.kind == .picture }.map(\.channel), [1])
        tick()   // frame 3: not a preview tick
        plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertTrue(plan.channelPasses.isEmpty, "at the preview rate, not the master's")
        tick(20)
        XCTAssertFalse(client.state.pictureFrames.isEmpty, "it still gets pictures")

        // The client goes: the next send finds it gone, and the picture work stops with it.
        client.disconnect()
        engine.tick(count: 4)
        XCTAssertTrue(waitUntil(5) { self.channel.clientCount == 0 })
        XCTAssertTrue(waitUntil(5) { !self.engine.control.picturesWanted.load(ordering: .relaxed) }, "the engine is told nobody holds the channel")
        engine.tick(count: 4)
        plan = try XCTUnwrap(engine.lastPlan)
        XCTAssertTrue(plan.channelPasses.isEmpty, "nobody watches the strip: the unheld channel isn't rendered")
        XCTAssertFalse(plan.auxPasses.contains { $0.kind == .picture })
    }

    /// "A channel whose media is missing gets a black picture, never its texture's old pixels."
    func test_aChannelWhoseMediaIsMissingGetsABlackPicture() throws {
        try open()
        engine.control.missing.insert(EngineFixtures.dawn)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        tick(3)
        XCTAssertEqual(engine.state.channels[1]?.content.media?.missing, true)
        let pictures = try XCTUnwrap(engine.lastPlan).auxPasses.filter { $0.kind == .picture }
        XCTAssertEqual(pictures.map(\.channel), [1])
        XCTAssertEqual(pictures.map(\.clear), [true], "cleared to black without reading the channel's texture")
        XCTAssertFalse(client.state.pictureFrames.isEmpty, "and named like any other picture")
    }

    /// "the pictures are skipped first under GPU pressure": they are aux
    /// work, and a tick that skips its aux passes names no frame.
    func test_underGpuPressurePicturesAndPreviewsAreSkippedAndNoFrameIsNamed() throws {
        try open()
        let backend = try XCTUnwrap(engine.recording)
        engine.send("channel 1 write media \(EngineFixtures.dawn)")
        tick(10)
        let before = (client.state.previewFrames.count, client.state.pictureFrames.count)
        XCTAssertGreaterThan(before.0, 0)
        XCTAssertGreaterThan(before.1, 0)
        backend.simulatedGPUMilliseconds = 20   // over half the tick
        tick(1)                                 // the tick that reads the overrun still drew
        let during = (client.state.previewFrames.count, client.state.pictureFrames.count)
        tick(20)
        XCTAssertEqual(client.state.previewFrames.count, during.0, "no preview frame while the GPU is over budget")
        XCTAssertEqual(client.state.pictureFrames.count, during.1, "and no picture")
        XCTAssertTrue(engine.renderLoop.isSkippingAux)
        backend.simulatedGPUMilliseconds = 3
        tick(10)
        XCTAssertGreaterThan(client.state.previewFrames.count, during.0, "and they come back with the headroom")
    }

    /// "the surfaces are sent again after a GPU reset".
    func test_theSurfacesAreSentAgainAfterAGpuRecovery() throws {
        try open()
        let backend = try XCTUnwrap(engine.recording)
        tick(2)
        backend.failNextCompletion = true
        engine.tick(count: 4)
        XCTAssertGreaterThan(backend.rebuilds, 0, "the recovery ran")
        XCTAssertTrue(waitUntil(5) { self.client.state.previewSets == 4 && self.client.state.pictureSets == 6 }, "every stack's and every channel's, again")
        // A new set starts with no frame named: the app waits for the next message before it reads.
        tick(4)
        XCTAssertNotNil(client.state.newestPreview[1])
    }

    /// "sent ... when a channel is added or renumbered ...; when a channel is
    /// removed, a message names it and the app drops its surfaces." Nothing
    /// changes the channel list while the engine runs until Area 14 does; the
    /// two calls it will make are driven here.
    func test_aRemovedChannelIsNamedForDroppingAndAChangedListSendsTheSurfacesAgain() throws {
        try open()
        channel.channelRemoved(3)
        XCTAssertTrue(waitUntil(5) { self.client.state.removed == [3] })
        XCTAssertEqual(client.state.pictures.keys.sorted(), [1, 2], "the app drops its surfaces")
        channel.resendSurfaces()
        XCTAssertTrue(waitUntil(5) { self.client.state.pictureSets == 6 }, "and a renumbered or added channel's follow it")
        XCTAssertEqual(client.state.pictures.keys.sorted(), [1, 2, 3])
    }

    /// Area 19 reading — the channel is the engine's own user's, as the local
    /// socket is: a client of another user gets nothing.
    func test_aClientOfAnotherUserIsRefused() throws {
        try open(connect: false, allows: { _ in false })
        try client.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { self.channel.clientsRefused == 1 })
        engine.tick(count: 10)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(channel.clientCount, 0)
        XCTAssertEqual(client.state.previewSets, 0, "no surface is sent to it")
        XCTAssertTrue(client.state.previewFrames.isEmpty)
        XCTAssertFalse(engine.control.picturesWanted.load(ordering: .relaxed))
    }

    func test_twoClientsEachGetEverything() throws {
        try open()
        let second = MachClient()
        defer { second.disconnect() }
        try second.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { second.state.previewSets == 2 && second.state.pictureSets == 3 })
        XCTAssertEqual(channel.clientCount, 2, "the app and the soak's client, say")
        tick(20)
        XCTAssertEqual(second.state.previewFrames.count, 20)
        XCTAssertEqual(client.state.previewFrames.count, 20)
        XCTAssertEqual(client.state.previewSets, 2, "the first client isn't sent its surfaces again")
    }

    // MARK: - Meters

    /// "Meters: 15 times a second, for each channel whose content has sound".
    func test_metersArriveFifteenTimesASecond() throws {
        let levels = [MeterReading(channel: 1, peak: -6, rms: -9), MeterReading(channel: 3, peak: -20.5, rms: -24)]
        let source = MachChannel.Source(previews: { [] }, pictures: { [] }, finished: { _ in true }, meters: { levels })
        let run = UUID()
        channel = MachChannel(name: MachServiceName.engine(run: run), notices: AuxNoticeRing(), source: source, log: EngineLog(category: "test-mach"))
        do { try channel.start() } catch {
            if ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil { throw XCTSkip("hosted runner: \(error)") }
            throw error
        }
        client = MachClient()
        try client.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { self.client.state.meterFrames > 0 })
        // The rate over the time that really passed: a sleep on a busy machine runs long.
        let first = client.state.meterFrames
        let began = MonotonicClock.now().nanoseconds
        Thread.sleep(forTimeInterval: 2)
        let arrived = Double(client.state.meterFrames - first)
        let seconds = Double(MonotonicClock.now().nanoseconds - began) / 1e9
        XCTAssertEqual(arrived / seconds, 15, accuracy: 1.5, "15 a second: \(arrived) frames in \(seconds) s")
        XCTAssertEqual(client.state.meters, levels, "each channel's peak and RMS, in dBFS")
    }

    /// "a channel without sound sends none": with no channel sounding, one
    /// empty frame says so (Area 19 reading), and then the meters are quiet.
    func test_withNoChannelSoundingOneEmptyFrameAndThenNone() throws {
        let sounding = LockedFlag()
        sounding.set(true)
        let source = MachChannel.Source(previews: { [] }, pictures: { [] }, finished: { _ in true },
                                        meters: { sounding.value ? [MeterReading(channel: 2, peak: -3, rms: -6)] : [] })
        channel = MachChannel(name: MachServiceName.engine(run: UUID()), notices: AuxNoticeRing(), source: source, log: EngineLog(category: "test-mach"))
        do { try channel.start() } catch {
            if ProcessInfo.processInfo.environment["O_HOSTED_RUNNER"] != nil { throw XCTSkip("hosted runner: \(error)") }
            throw error
        }
        client = MachClient()
        try client.connect(name: channel.name)
        XCTAssertTrue(waitUntil(5) { self.client.state.meterFrames >= 2 })
        sounding.set(false)
        XCTAssertTrue(waitUntil(5) { self.client.state.meters.isEmpty && self.client.state.meterFrames > 0 }, "the empty frame")
        let after = client.state.meterFrames
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertLessThanOrEqual(client.state.meterFrames - after, 1, "then none")
    }
}
