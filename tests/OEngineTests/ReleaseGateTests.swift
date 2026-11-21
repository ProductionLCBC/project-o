import XCTest
import OCore
@testable import OEngine

/// Spec 4 §3 — "the render thread only ever reads a finished plan", and with
/// no new plan it reuses the one it has; Spec 4 §5 — "Everything the render
/// thread touches is allocated before it is needed". So nothing a plan names
/// may be freed while the render thread can still read that plan: a texture
/// or a source that is released waits until the render thread has taken a
/// plan built after the release, however many ticks the build in between
/// took. Area 14's rebuild between ticks leans on this, since allocating a
/// stack's textures can make a build long.
final class ReleaseGateTests: XCTestCase {
    typealias E = EngineFixtures

    private func texture(_ table: ResourceTable, _ label: String = "t") -> TextureHandle {
        table.allocate(PlaceholderTexture(TextureDescriptor(role: .textLine, size: PixelSize(width: 8, height: 8), label: label)),
                       descriptor: TextureDescriptor(role: .textLine, size: PixelSize(width: 8, height: 8), label: label))
    }

    // MARK: - The texture table

    /// The table is swept with the frame of the newest plan the render thread
    /// has taken. A release made during the build for frame 500 waits for a
    /// plan built for a later frame, whatever tick the caller asked for.
    func test_aReleaseWaitsForAPlanBuiltAfterIt() {
        let table = ResourceTable(capacity: 16)
        let handle = texture(table)
        table.sweep(consumedTick: 100)
        table.noteBuild(frame: 500)                      // the control thread fell behind: its build is for frame 500
        table.release(handle, afterTick: 104)            // a caller that reckoned from the last plan it knew was taken
        table.sweep(consumedTick: 500)                   // the render thread took the plan built for frame 500, which may name it
        XCTAssertNotNil(table.object(handle), "the plan for frame 500 was built while the texture was still handed out")
        XCTAssertEqual(table.pendingRelease, 1)
        table.sweep(consumedTick: 501)
        XCTAssertNil(table.object(handle), "a plan built after the release has been taken")
        XCTAssertEqual(table.pendingRelease, 0)
    }

    /// The control thread, catching up, can build twice for one frame; the
    /// second build's release still waits for a plan with a later frame.
    func test_aReleaseWithNoTickWaitsTheRingsDepthPastItsBuild() {
        let table = ResourceTable(capacity: 16)
        let handle = texture(table)
        table.sweep(consumedTick: 7)
        table.noteBuild(frame: 40)
        table.release(handle)
        table.sweep(consumedTick: 40 + Int64(PlanRing.depth) - 1)
        XCTAssertNotNil(table.object(handle))
        table.sweep(consumedTick: 40 + Int64(PlanRing.depth))
        XCTAssertNil(table.object(handle))
    }

    /// A later tick asked for is kept: a box transition's old lines stay until it has run.
    func test_aLaterTickAskedForIsKept() {
        let table = ResourceTable(capacity: 16)
        let handle = texture(table)
        table.noteBuild(frame: 10)
        table.release(handle, afterTick: 70)
        table.sweep(consumedTick: 69)
        XCTAssertNotNil(table.object(handle))
        table.sweep(consumedTick: 70)
        XCTAssertNil(table.object(handle))
    }

    /// A freed handle is the last to be handed out again, so a handle someone
    /// still holds by mistake names nothing rather than another texture.
    func test_aFreedHandleIsNotTheNextOneHandedOut() {
        let table = ResourceTable(capacity: 8)
        let first = texture(table, "a")
        let second = texture(table, "b")
        table.release(first, afterTick: 0)
        table.sweep(consumedTick: 5)
        XCTAssertNil(table.object(first))
        let third = texture(table, "c")
        XCTAssertNotEqual(third, first)
        XCTAssertNotEqual(third, second)
        // Every handle is handed out before the freed one comes round again.
        var seen: Set<TextureHandle> = [second, third]
        for _ in 0..<5 { seen.insert(texture(table)) }
        XCTAssertFalse(seen.contains(first))
        XCTAssertEqual(texture(table), first, "the table is full but for the freed handle")
        XCTAssertTrue(texture(table).isNone, "and now it is full")
    }

    // MARK: - The engine

    private func instance(in plan: FramePlan?) -> InstanceHandle? {
        for pass in plan?.channelPasses ?? [] {
            if case .instance(let handle, _) = pass.incoming.source { return handle }
            if case .instance(let handle, _)? = pass.outgoing?.source { return handle }
        }
        return nil
    }

    /// The render thread notes the frame of each plan it takes, and the
    /// control side sweeps with that, not with the count of ticks rendered.
    func test_theSweepFollowsThePlansTakenNotTheTicksRendered() throws {
        let engine = try HeadlessEngine(library: E.library(), machine: E.spikeMachine(), media: E.media)
        engine.tick(count: 5)
        XCTAssertEqual(engine.renderLoop.lastTakenPlanFrame, 4)
        engine.stallControl(ticks: 6)
        engine.tick(count: 6)
        XCTAssertEqual(engine.renderLoop.lastConsumedTick, 10, "the render thread ran every tick on the plan it had")
        XCTAssertEqual(engine.renderLoop.lastTakenPlanFrame, 4, "and took no new plan")
        engine.tick()
        XCTAssertEqual(engine.renderLoop.lastTakenPlanFrame, 11)
        XCTAssertEqual(engine.backend.resources.lastConsumedTick, 4, "the build for frame 11 swept before the render thread took its plan")
        engine.tick()
        XCTAssertEqual(engine.backend.resources.lastConsumedTick, 11)
    }

    /// A clip is cleared in a build that takes four ticks, and the control
    /// thread, behind, builds again before the render thread's next tick. The
    /// render thread is still on the plan that plays the clip: its source
    /// stays in the table until a later plan has been taken.
    func test_aSourceThePlanInUseNamesStaysWhileTheControlThreadIsBehind() throws {
        let engine = try HeadlessEngine(library: E.library(), machine: E.spikeMachine(), media: E.media)
        XCTAssertNil(engine.send("channel 1 write media \(E.dawn)"), "channel 1 cuts by default")
        engine.tick(count: 4)
        let handle = try XCTUnwrap(instance(in: engine.lastPlan), "the plan plays the clip")
        XCTAssertNotNil(engine.engine.sources.source(handle))

        XCTAssertNil(engine.send("channel 1 clear"))
        var checked = false
        engine.tickWithLateBuild(reusing: 4) {
            checked = true
            XCTAssertEqual(self.instance(in: engine.lastPlan), handle, "the render thread has not taken a plan since the clear")
            XCTAssertNotNil(engine.engine.sources.source(handle), "so the clip's source is still in the table")
        }
        XCTAssertTrue(checked)
        XCTAssertNil(instance(in: engine.lastPlan), "the plan taken now plays nothing")
        engine.tick(count: 3)
        XCTAssertNil(engine.engine.sources.source(handle), "freed once a plan built after the clear was taken")
    }
}
