import XCTest
import Darwin
import Synchronization
import OCore
@testable import OEngine

/// Spec 4 §3 — the render thread "takes no locks, allocates nothing, touches
/// no file"; CLAUDE.md — "Nothing allocates ... on the render thread". A
/// render tick under libmalloc's logging hook, counting this thread's
/// allocations and frees: both must be zero once the engine is warm.
///
/// The backend is the recording one in its keep-nothing mode, so the count is
/// the engine's own tick: plan take, picks, publish into the rings, metrics.
/// Metal's per-frame objects are outside this (the brief records that).
///
/// The exact zero holds in an optimized build (`swift test -c release`), which
/// is what ships. An unoptimized build allocates and frees a temporary per
/// loop iteration of unspecialised generic code (measured: every `for` over an
/// array or a range, nothing of the engine's own), so there the test proves
/// the weaker property that nothing survives the tick.
final class RenderThreadAllocationTests: XCTestCase {
    func test_aWarmRenderTickAllocatesNothing() throws {
        guard MallocCounter.available else { throw XCTSkip("malloc_logger is not reachable in this process") }
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(), mediaRoot: EngineFixtures.mediaRoot)
        let backend = try XCTUnwrap(engine.recording)
        backend.recordsEncodes = false
        engine.send("list 42 cue 1")
        engine.tick(count: 40)   // warm: the sources are ready, the rings and picks have been through their first lap
        engine.send("next")
        engine.tick(count: 5)

        // The hook sees everything: a deliberate allocation proves the count is live.
        MallocCounter.begin()
        var proof = [Int](repeating: 0, count: 1024)
        proof[3] = 1
        let control = MallocCounter.end()
        XCTAssertGreaterThan(control.allocations, 0, "the counter sees allocations on this thread")
        withExtendedLifetime(proof) {}

        let render = engine.renderLoop
        let ticksBefore = render.totalTicks
        var allocations: Int64 = 0
        var frees: Int64 = 0
        for i in 0..<30 {
            let frame = engine.frame + 1 + Int64(i)
            let now = MonotonicTime(nanoseconds: frame * engine.engine.pacing.tickNanoseconds)
            engine.engine.planRing.publish(engine.control.build(for: frame, now: now))
            let time = TickTime(tick: frame, reference: now, wake: now)
            MallocCounter.begin()
            render.tick(time)
            let counts = MallocCounter.end()
            allocations += counts.allocations
            frees += counts.frees
        }
        #if DEBUG
        XCTAssertEqual(allocations, frees, "a render tick kept memory it allocated (debug build: compiler temporaries only)")
        XCTAssertLessThan(allocations, 30 * 64, "far more than the debug build's loop temporaries: something allocates")
        #else
        XCTAssertEqual(allocations, 0, "a render tick allocated")
        XCTAssertEqual(frees, 0, "a render tick freed")
        #endif
        XCTAssertEqual(render.totalTicks, ticksBefore + 30)
    }
}

/// libmalloc's `malloc_logger` hook, reached through `dlsym`, counting on one thread.
enum MallocCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    static let allocations = Atomic<Int64>(0)
    static let frees = Atomic<Int64>(0)
    static let thread = Atomic<UInt>(0)
    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }()

    static var available: Bool { slot != nil }

    static let hook: Logger = { type, _, _, _, _, _ in
        guard UInt(bitPattern: pthread_self()) == MallocCounter.thread.load(ordering: .relaxed) else { return }
        if type & 2 != 0 {           // MALLOC_LOG_TYPE_ALLOCATE
            MallocCounter.allocations.add(1, ordering: .relaxed)
        } else if type & 4 != 0 {    // MALLOC_LOG_TYPE_DEALLOCATE
            MallocCounter.frees.add(1, ordering: .relaxed)
        }
    }

    static func begin() {
        // Touch every global before the hook is live, so their lazy init is not counted.
        _ = allocations.load(ordering: .relaxed)
        _ = frees.load(ordering: .relaxed)
        allocations.store(0, ordering: .relaxed)
        frees.store(0, ordering: .relaxed)
        thread.store(UInt(bitPattern: pthread_self()), ordering: .releasing)
        slot?.pointee = hook
    }

    static func end() -> (allocations: Int64, frees: Int64) {
        slot?.pointee = nil
        thread.store(0, ordering: .releasing)
        return (allocations.load(ordering: .relaxed), frees.load(ordering: .relaxed))
    }
}
