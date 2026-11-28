import XCTest
import OCore
@testable import OEngine

/// Spec 4 §5 — "Allocation happens at three moments only: show load, a stack
/// or output change (between ticks, double-buffered so the old pools serve
/// until the new ones exist) ... A stack or output change is anything that
/// changes a size below or adds or removes a channel or a stack: an edit, an
/// undo, a restore or a reload from disk (Spec 5 §2), and a stack switch onto
/// an output of another size." Spec 5 §2 — "A new channel or stack gets its
/// textures before the tick that first draws it". Spec 11 §13, Area 14, the
/// engine's edits: "the channel list rebuilt between ticks".
final class RebuildEngineTests: XCTestCase {
    typealias E = EngineFixtures
    static let wall = PixelSize(width: 4096, height: 2160)
    static let hd = PixelSize(width: 1920, height: 1080)
    static let picture = PixelSize(width: 256, height: 144)

    var engine: HeadlessEngine!
    var control: ControlLoop { engine.control }
    var table: ResourceTable { engine.backend.resources }

    /// Output 1 is the wall on stack 1 (channels 1 and 2); output 2 a 1080p
    /// screen on stack 2 (channels 2 and 3). Channels 1 and 3 are `largest`,
    /// channel 2 is 1920 by 1080. Retired textures go after six frames here.
    func makeEngine(_ configure: (inout Library, inout Machine) -> Void = { _, _ in }) throws {
        var library = try E.library()
        var machine = try E.spikeMachine(mainSize: Size(width: Self.wall.width, height: Self.wall.height))
        machine.settings.libraryMode = .writable
        configure(&library, &machine)
        engine = try HeadlessEngine(library: library, machine: machine, media: E.media)
        engine.control.retireGraceFrames = 6
    }

    override func setUpWithError() throws {
        try makeEngine()
    }

    func size(_ handle: TextureHandle?) -> PixelSize? {
        handle.flatMap { table.descriptor($0)?.size }
    }

    func apply(_ texts: String..., file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            if let rejection = engine.send(text, source: .ui) { XCTFail("\(text) → \(rejection.reason): \(rejection.message)", file: file, line: line) }
            let before = engine.rejections.count
            engine.tick()
            if engine.rejections.count > before, let last = engine.rejections.last {
                XCTFail("\(text) → \(last.reason): \(last.message)", file: file, line: line)
            }
            if let blocked = engine.lastExecuted.first(where: { $0.result == .blocked }) {
                XCTFail("\(text) → blocked: \(blocked.refusal?.message ?? "")", file: file, line: line)
            }
        }
    }

    func slotJSON(_ channel: Int) -> String {
        "{\"channel\": \(channel), \"mute\": false, \"opacity\": 1, \"preset\": null}"
    }

    // MARK: - At launch

    func test_atLaunchEveryChannelAndStackHasItsTexturesAtItsSize() throws {
        XCTAssertEqual(size(control.channelTextures[1]), Self.wall, "largest, in stack 1 on the wall")
        XCTAssertEqual(size(control.channelTextures[2]), Self.hd)
        XCTAssertEqual(size(control.channelTextures[3]), Self.hd, "largest, in stack 2 on the 1080p screen")
        XCTAssertEqual(size(control.channelSnapshots[1]), Self.wall)
        XCTAssertEqual(control.stackRings[1]?.map { size($0) }, [Self.wall, Self.wall, Self.wall])
        XCTAssertEqual(control.stackRings[2]?.map { size($0) }, [Self.hd, Self.hd, Self.hd])
        XCTAssertEqual(control.previewSurfaces[1]?.map { size($0) }, Array(repeating: PixelSize(width: 1024, height: 540), count: 3), "a quarter of the stack")
        XCTAssertEqual(control.pictureSurfaces.keys.sorted(), [1, 2, 3])
        XCTAssertEqual(control.pictureSurfaces[3]?.map { size($0) }, [Self.picture, Self.picture, Self.picture])
        XCTAssertEqual(control.geometry.stackSize(1), Self.wall)
        XCTAssertNil(control.lastRebuild, "nothing was made again")
        engine.tick(count: 3)
        XCTAssertNil(control.lastRebuild)
        XCTAssertEqual(table.pendingRelease, 0)
    }

    // MARK: - Channels

    /// Spec 5 §2 — "A new channel or stack gets its textures before the tick that first draws it".
    func test_aNewChannelGetsItsTexturesOnTheTickOfItsEdit() throws {
        engine.tick()
        let before = table.allocated
        apply("edit channel create")
        XCTAssertEqual(control.lastRebuild?.channelsMade, [4])
        XCTAssertEqual(control.lastRebuild?.frame, engine.frame)
        XCTAssertEqual(size(control.channelTextures[4]), Self.hd, "no stack holds it yet: 1920 by 1080")
        XCTAssertEqual(size(control.channelSnapshots[4]), Self.hd)
        XCTAssertEqual(control.pictureSurfaces[4]?.count, 3)
        XCTAssertEqual(table.allocated, before + 5, "its texture, its snapshot and three pictures")
        XCTAssertNotNil(engine.state.channels[4], "and its empty entry in the state (Spec 5 §1)")
        XCTAssertTrue(control.publishedSurfaces.pictures[4]?.count == 3, "the Mach channel's thread reads the new set")

        // In stack 1, on the wall, it is the wall's size: a new texture, the old one kept until no plan can name it.
        let small = try XCTUnwrap(control.channelTextures[4])
        apply("edit stack 1 insert slots 2 \(slotJSON(4))")
        XCTAssertEqual(control.lastRebuild?.channelsResized, [4])
        let large = try XCTUnwrap(control.channelTextures[4])
        XCTAssertNotEqual(large, small)
        XCTAssertEqual(size(large), Self.wall)
        XCTAssertEqual(size(small), Self.hd, "retired, not yet freed")
        XCTAssertEqual(control.geometry.channelSize(4), Self.wall)

        // It plays into its new texture on the tick it is written.
        XCTAssertNil(engine.send("channel 4 write media \(E.dawn)"))
        engine.tick()
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 4 })
        XCTAssertEqual(pass.target, large)
        XCTAssertEqual(pass.size, Self.wall)
        engine.tick(count: 10)
        XCTAssertNil(table.descriptor(small), "freed after the grace")
        XCTAssertEqual(table.pendingRelease, 0)
    }

    /// Spec 5 §1 — "one that an edit deletes loses it"; what the channel held goes with it.
    func test_aDeletedChannelLosesItsTexturesItsStateAndItsContent() throws {
        apply("edit channel create")
        XCTAssertNil(engine.send("channel 4 write media \(E.dawn)"))
        engine.tick(count: 2)
        let source = try XCTUnwrap(engine.fakeSources?.opened.last)
        XCTAssertEqual(engine.sources(onChannel: 4).count, 1)
        let handles = [control.channelTextures[4], control.channelSnapshots[4]].compactMap { $0 } + (control.pictureSurfaces[4] ?? [])
        XCTAssertEqual(handles.count, 5)
        let before = table.allocated

        apply("edit channel 4 delete")
        XCTAssertEqual(control.lastRebuild?.channelsGone, [4])
        XCTAssertNil(control.channelTextures[4])
        XCTAssertNil(control.channelSnapshots[4])
        XCTAssertNil(control.pictureSurfaces[4])
        XCTAssertNil(control.publishedSurfaces.pictures[4])
        XCTAssertNil(engine.state.channels[4])
        XCTAssertNil(control.model.channels[4], "its runtime went")
        XCTAssertTrue(source.released, "and the clip it held was released")
        XCTAssertEqual(table.allocated, before, "the textures stay until no plan can name them")
        engine.tick(count: 10)
        XCTAssertEqual(table.allocated, before - 5)
        for handle in handles { XCTAssertNil(table.descriptor(handle)) }
        XCTAssertTrue(engine.sources(onChannel: 4).isEmpty)
        XCTAssertNil(engine.lastPlan?.channelPasses.first { $0.channel == 4 })
    }

    /// Spec 4 §5 — "A channel whose render size is `largest` follows its
    /// stacks and keeps playing into its new texture"; a fixed size is the
    /// channel's own.
    func test_aChannelsRenderSizeEditRebuildsItsTextureAndItKeepsPlaying() throws {
        XCTAssertNil(engine.send("channel 1 write media \(E.dawn)"))
        engine.tick(count: 3)
        let old = try XCTUnwrap(control.channelTextures[1])
        let playing = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 })
        XCTAssertEqual(playing.target, old)
        XCTAssertEqual(playing.size, Self.wall)

        apply("edit channel 1 renderSize {\"height\": 720, \"width\": 1280}")
        XCTAssertEqual(control.lastRebuild?.channelsResized, [1])
        XCTAssertEqual(control.lastRebuild?.surfacesChanged, false, "its pictures are 256 by 144 whatever its size")
        let new = try XCTUnwrap(control.channelTextures[1])
        XCTAssertNotEqual(new, old)
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 1 }, "the plan of the edit's own tick")
        XCTAssertEqual(pass.target, new)
        XCTAssertEqual(pass.size, PixelSize(width: 1280, height: 720))
        XCTAssertNotNil(instance(pass.incoming.source))
        XCTAssertEqual(instance(pass.incoming.source), instance(playing.incoming.source), "the same clip, still playing")
        // The stack pass of that tick samples the new texture.
        let box = try XCTUnwrap(engine.boxes(stack: 1, channel: 1).first)
        guard case .pixels(let quad) = box.content else { return XCTFail("a pixel box") }
        XCTAssertEqual(quad.texture, new)

        apply("edit channel 1 renderSize largest")
        XCTAssertEqual(size(control.channelTextures[1]), Self.wall)
    }

    // MARK: - Stacks

    func test_aNewStackGetsItsRingAndPreviewsAndADeletedOneLosesThem() throws {
        engine.tick()
        apply("edit stack create")
        XCTAssertEqual(control.lastRebuild?.stacksMade, [3])
        XCTAssertEqual(control.lastRebuild?.surfacesChanged, true)
        let ring = try XCTUnwrap(control.stackRings[3])
        XCTAssertEqual(ring.map { size($0) }, [Self.hd, Self.hd, Self.hd], "no output shows it or defaults to it")
        XCTAssertEqual(control.previewSurfaces[3]?.map { size($0) }, Array(repeating: PixelSize(width: 480, height: 270), count: 3))
        XCTAssertNotNil(engine.state.stacks[3])
        XCTAssertEqual(control.publishedSurfaces.previews[3]?.count, 3)
        // No output feeds it: it renders for its preview, into its own ring.
        var drawn: StackPass?
        for _ in 0..<4 where drawn == nil {
            engine.tick()
            drawn = engine.lastPlan?.stackPasses.first { $0.stack == 3 }
        }
        let pass = try XCTUnwrap(drawn)
        XCTAssertTrue(ring.contains(pass.target))
        XCTAssertTrue(pass.auxOnly)

        let previews = control.previewSurfaces[3] ?? []
        apply("edit stack 3 delete")
        XCTAssertEqual(control.lastRebuild?.stacksGone, [3])
        XCTAssertNil(control.stackRings[3])
        XCTAssertNil(control.previewSurfaces[3])
        XCTAssertNil(engine.state.stacks[3])
        XCTAssertNil(control.previewSlots[3])
        engine.tick(count: 10)
        for handle in ring + previews { XCTAssertNil(table.descriptor(handle)) }
        XCTAssertNil(engine.lastPlan?.stackPasses.first { $0.stack == 3 })
    }

    /// Spec 4 §5 — "A stack switch (`output N stack M`) onto an output of
    /// another size rebuilds stack M at that output's size on the tick of the
    /// switch, and the old stack when the switch's transition ends and it is
    /// no longer mixed." Adam's answer of 2026-11-18.
    func test_aSwitchOntoAnOutputOfAnotherSizeRebuildsTheStackOnThatTick() throws {
        // Both outputs default to stack 2, so stack 1 is 1920 by 1080 until the wall shows it.
        try makeEngine { _, machine in machine.outputs[0].defaultStack = 2 }
        engine.tick(count: 2)
        XCTAssertEqual(control.geometry.stackSize(1), Self.hd)
        XCTAssertEqual(control.geometry.stackSize(2), Self.wall, "the largest output showing it")
        XCTAssertEqual(control.geometry.channelSize(1), Self.hd)
        let oldRing1 = try XCTUnwrap(control.stackRings[1])
        let ring2 = try XCTUnwrap(control.stackRings[2])

        XCTAssertNil(engine.send("output 1 stack 1"))   // output 1's switch transition is 2: a 500 ms dissolve, thirty frames
        engine.tick()
        let switched = engine.frame
        XCTAssertEqual(control.lastRebuild?.stacksResized, [1])
        XCTAssertEqual(control.lastRebuild?.channelsResized, [1], "channel 1 is `largest` and stack 1 holds it")
        let ring1 = try XCTUnwrap(control.stackRings[1])
        XCTAssertEqual(ring1.map { size($0) }, [Self.wall, Self.wall, Self.wall])
        XCTAssertTrue(Set(ring1).isDisjoint(with: oldRing1))
        XCTAssertEqual(control.stackRings[2], ring2, "the old stack of the running switch keeps its size")
        XCTAssertEqual(size(control.channelTextures[1]), Self.wall)

        // The plan of the switch's own tick draws stack 1 at the wall's size and mixes it over stack 2.
        let plan = try XCTUnwrap(engine.lastPlan)
        let pass = try XCTUnwrap(plan.stackPasses.first { $0.stack == 1 })
        XCTAssertEqual(pass.size, Self.wall)
        XCTAssertTrue(ring1.contains(pass.target))
        let sink = try XCTUnwrap(plan.sinkPasses.first { $0.output == 1 })
        XCTAssertEqual(sink.stack, pass.target)
        guard case .stack(let second) = sink.second else { return XCTFail("the switch mixes the old stack") }
        XCTAssertTrue(ring2.contains(second))

        // While the switch runs nothing more is rebuilt.
        engine.tick(count: 20)
        XCTAssertEqual(control.stackRings[2], ring2)
        XCTAssertEqual(control.stackRings[1], ring1)

        // The switch ends: stack 2 is shown by the 1080p screen alone.
        var ended: Int64?
        for _ in 0..<15 where ended == nil {
            engine.tick()
            if control.lastRebuild?.stacksResized == [2] { ended = engine.frame }
        }
        XCTAssertEqual(ended, switched + 30, "on the tick the switch's transition ends")
        XCTAssertEqual(control.stackRings[2]?.map { size($0) }, [Self.hd, Self.hd, Self.hd])
        XCTAssertEqual(control.lastRebuild?.channelsResized, [3], "channel 3 is `largest` and stack 2 is its only stack")
        XCTAssertEqual(size(control.channelTextures[3]), Self.hd)
        let after = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 2 })
        XCTAssertTrue(control.stackRings[2]?.contains(after.stack) == true)
        XCTAssertEqual(after.second, SecondTexture.none)
        engine.tick(count: 10)
        for handle in oldRing1 + ring2 { XCTAssertNil(table.descriptor(handle), "the old rings are freed") }
        XCTAssertEqual(table.pendingRelease, 0)
    }

    /// Spec 4 §10 — an interlaced output's first field is the previous tick's
    /// stack texture: on the tick a stack is made again, that is in the ring
    /// it had, since the new ring holds nothing from the tick before.
    func test_anInterlacedOutputsFirstFieldComesFromTheRingTheStackHad() throws {
        var machine = try E.pacingMachine()
        machine.settings.libraryMode = .writable
        // Output 1 is a 4096 by 2160 screen on stack 2; the interlaced output 3 shows stack 1.
        machine.outputs[0].format.width = Self.wall.width
        machine.outputs[0].format.height = Self.wall.height
        machine.outputs[0].defaultStack = 2
        machine.outputs[0].transitions = OutputTransitions(switch: 1, blackout: 1)
        engine = try HeadlessEngine(library: E.library(), machine: machine, media: E.media)
        // An interlaced output's sink is due on the second field's tick, an odd one: the switch lands on frame 5.
        engine.tick(count: 5)
        let oldRing = try XCTUnwrap(control.stackRings[1])
        XCTAssertEqual(size(oldRing.first), Self.hd)

        XCTAssertNil(engine.send("output 1 stack 1"))
        engine.tick()
        let frame = engine.frame
        XCTAssertEqual(frame, 5)
        XCTAssertEqual(control.lastRebuild?.stacksResized.contains(1), true)
        let ring = try XCTUnwrap(control.stackRings[1])
        let sink = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 3 })
        XCTAssertEqual(sink.stack, ring[Int(frame % 3)])
        XCTAssertEqual(sink.firstField?.stack, oldRing[Int((frame + 2) % 3)], "the picture of the tick before")
        engine.tick(count: 2)
        let next = try XCTUnwrap(engine.lastPlan?.sinkPasses.first { $0.output == 3 })
        XCTAssertEqual(next.firstField?.stack, ring[Int((frame + 1) % 3)], "from then on, its own ring")
    }

    // MARK: - What the old textures wait for

    /// Spec 4 §5 — "double-buffered so the old pools serve until the new ones
    /// exist": the build that makes a ring again takes four ticks here, and
    /// the render thread goes on reading the ring it had.
    func test_theOldTexturesServeWhileTheBuildThatReplacesThemIsLate() throws {
        try makeEngine { _, machine in machine.outputs[0].defaultStack = 2 }
        engine.control.retireGraceFrames = 12
        engine.tick(count: 3)
        let oldRing = try XCTUnwrap(control.stackRings[1])
        XCTAssertNil(engine.send("edit output 1 defaultStack 1", source: .ui))
        var checked = false
        engine.tickWithLateBuild(reusing: 4) {
            checked = true
            XCTAssertEqual(self.control.stackRings[1]?.map { self.size($0) }, [Self.wall, Self.wall, Self.wall], "stack 1 is the wall's default now")
            let reading = self.engine.lastPlan?.stackPasses.first { $0.stack == 1 }?.target
            XCTAssertTrue(reading == nil || oldRing.contains(reading ?? .none), "the render thread's plan is from before the edit")
            for handle in oldRing { XCTAssertNotNil(self.table.object(handle), "so the ring it names is still there") }
        }
        XCTAssertTrue(checked)
        engine.tick(count: 2)
        for handle in oldRing { XCTAssertNotNil(table.object(handle), "within the grace") }
        engine.tick(count: 8)
        for handle in oldRing { XCTAssertNil(table.object(handle)) }
    }

    /// Spec 4 §12 — a texture that can't be made is a severe line, never a
    /// trap: what was there goes on serving, at its old size.
    func test_whenATextureCannotBeMadeTheOldOneServes() throws {
        engine.tick(count: 2)
        let old = try XCTUnwrap(control.channelTextures[1])
        // Fill the table.
        while !engine.backend.makeTexture(TextureDescriptor(role: .textLine, size: PixelSize(width: 1, height: 1), label: "fill")).isNone {}
        apply("edit channel 1 renderSize {\"height\": 720, \"width\": 1280}")
        XCTAssertEqual(control.channelTextures[1], old)
        XCTAssertEqual(control.geometry.channelSize(1), Self.wall, "the size its texture has")
        XCTAssertEqual(control.lastRebuild?.failed, ["channel 1"])
        XCTAssertEqual(engine.engine.library.channel(1)?.renderSize, .size(width: 1280, height: 720), "the edit itself applied")
        engine.tick(count: 3)
    }

    // MARK: - Undo, and a group

    /// Spec 5 §8 — an undo is an edit like any other: the textures follow.
    func test_undoAndRedoRebuildToo() throws {
        engine.tick()
        apply("edit channel create")
        XCTAssertNotNil(control.channelTextures[4])
        apply("undo")
        XCTAssertNil(control.channelTextures[4])
        XCTAssertEqual(control.lastRebuild?.channelsGone, [4])
        apply("redo")
        XCTAssertNotNil(control.channelTextures[4])
        XCTAssertEqual(control.lastRebuild?.channelsMade, [4])
    }

    /// Spec 5 §1 — "So a group that makes a channel and then writes to it lands the write".
    func test_aGroupThatMakesAChannelAndWritesToItDrawsItOnThatTick() throws {
        engine.tick()
        XCTAssertNil(engine.send(group: ["edit channel create", "edit stack 1 insert slots 2 \(slotJSON(4))", "channel 4 write media \(E.dawn)"], source: .ui))
        engine.tick()
        XCTAssertEqual(engine.rejections.count, 0, engine.rejections.last?.message ?? "")
        let texture = try XCTUnwrap(control.channelTextures[4])
        XCTAssertEqual(size(texture), Self.wall)
        let pass = try XCTUnwrap(engine.lastPlan?.channelPasses.first { $0.channel == 4 })
        XCTAssertEqual(pass.target, texture)
        XCTAssertEqual(engine.boxes(stack: 1, channel: 4).count, 1, "stack 1 draws it")
    }
}

/// The decoded instance a pass reads, whatever its media time.
private func instance(_ source: SourceRef) -> InstanceHandle? {
    if case .instance(let handle, _) = source { return handle }
    return nil
}
