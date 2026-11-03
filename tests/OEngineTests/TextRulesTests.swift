import XCTest
import OCore
@testable import OEngine

/// Spec 4 §8 — "A box whose text contains variables is re-laid-out only when
/// its resolved text changes, and no more than once a second; the result
/// replaces the cache entry. A timer box therefore costs one small raster per
/// second. Boxes with `transitionOnVariableChange` run their box transition
/// between the old and new textures; the rest swap." Area 5 reading, approved
/// on 2026-11-03: the second is the wall-clock second the variable provider
/// reads for `[Time]`, and the gate sits between two non-empty values; a first
/// value and a clear are not re-layouts and show at once.
final class VariableBoxGateTests: XCTestCase {
    /// The spike library with a caption preset: one static `[Popup 1]` box on
    /// channel 2's slot of the main stack, dissolving over 500 ms.
    func engine(transitionOnChange: Bool, clock: VariableRasterTests.MovingClock) throws -> HeadlessEngine {
        var library = try EngineFixtures.library()
        let box = Box(binding: .static(text: "[Popup 1]"), frame: Frame(x: 0.1, y: 0.8, w: 0.8, h: 0.15),
                      fit: .text(TextFit(policy: .shrinkToFit, maxLines: 2, minSize: 20)), textStyle: BoxTextStyle(),
                      transition: BoxTransition(ref: 2, ms: 500), transitionOnVariableChange: transitionOnChange)
        library.presets.append(Preset(number: 4, label: "Caption", uuid: EngineFixtures.uuid("c0de", 4), layouts: [.any: Layout(boxes: [box])]))
        var machine = try EngineFixtures.spikeMachine()
        machine.stacks[0].slots[1].preset = 4
        return try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot, wallClock: { clock.now })
    }

    func captionBox(_ engine: HeadlessEngine) -> ResolvedBox? {
        engine.lastPlan?.stackPasses.first { $0.stack == 1 }?.boxes.first { if case .static = $0.binding.kind { return true } else { return false } }
    }

    func test_aVariableBoxAdoptsOneValuePerSecondAndTheLatestAfter() throws {
        let clock = VariableRasterTests.MovingClock()
        let engine = try engine(transitionOnChange: true, clock: clock)
        engine.tick()
        XCTAssertNil(captionBox(engine), "no popup: nothing to draw")
        engine.send("popup 1 set \"a\"")
        engine.tick()
        XCTAssertEqual(captionBox(engine)?.text, "a", "the first value shows at once: nothing was laid out before it")
        engine.send("popup 1 set \"b\"")
        engine.tick()
        XCTAssertEqual(captionBox(engine)?.text, "a", "a second change within the same second waits")
        engine.send("popup 1 set \"c\"")
        engine.tick(count: 3)
        XCTAssertEqual(captionBox(engine)?.text, "a")
        clock.advance(seconds: 1)
        engine.tick()
        let box = try XCTUnwrap(captionBox(engine))
        XCTAssertEqual(box.text, "c", "the latest value, once the second has moved on")
        let transition = try XCTUnwrap(box.transition, "transitionOnVariableChange: the box dissolves from the old lines")
        XCTAssertEqual(transition.type, .dissolve)
        XCTAssertFalse(transition.outgoing.isEmpty)
        XCTAssertEqual(transition.progress, 0, accuracy: 0.0001)
        engine.tick(count: 31)   // 500 ms is 30 frames at 60 Hz
        XCTAssertNil(captionBox(engine)?.transition)
        XCTAssertEqual(captionBox(engine)?.text, "c")
    }

    func test_aClearShowsAtOnceAndAVariableBoxWithoutTheFlagSwaps() throws {
        let clock = VariableRasterTests.MovingClock()
        let engine = try engine(transitionOnChange: false, clock: clock)
        engine.send("popup 1 set \"a\"")
        engine.tick()
        XCTAssertEqual(captionBox(engine)?.text, "a")
        clock.advance(seconds: 1)
        engine.send("popup 1 set \"b\"")
        engine.tick()
        let box = try XCTUnwrap(captionBox(engine))
        XCTAssertEqual(box.text, "b")
        XCTAssertNil(box.transition, "without the flag the textures swap")
        engine.send("popup 1 clear")
        engine.tick()
        XCTAssertNil(captionBox(engine), "a clear is not a re-layout: the box goes at once")
        engine.send("popup 1 set \"d\"")
        engine.tick()
        XCTAssertEqual(captionBox(engine)?.text, "d", "after a clear the next value shows at once")
    }

    /// The confidence stack's `[Time]` box has `transitionOnVariableChange`
    /// and a 120 ms dissolve: on the minute the new raster dissolves in.
    func test_theTimeBoxDissolvesOnTheMinuteWhenAsked() throws {
        let clock = VariableRasterTests.MovingClock()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(),
                                        mediaRoot: EngineFixtures.mediaRoot, wallClock: { clock.now })
        func timeBox() -> ResolvedBox? {
            engine.lastPlan?.stackPasses.first { $0.stack == 2 }?.boxes.first { if case .static = $0.binding.kind { return true } else { return false } }
        }
        engine.tick(count: 2)
        XCTAssertEqual(timeBox()?.text, "10:00 AM")
        XCTAssertNil(timeBox()?.transition)
        clock.advance(seconds: 60)
        engine.tick()
        let box = try XCTUnwrap(timeBox())
        XCTAssertEqual(box.text, "10:01 AM")
        XCTAssertEqual(box.transition?.type, .dissolve)
        XCTAssertEqual(box.transition?.progress ?? -1, 0, accuracy: 0.0001)
        engine.tick(count: 7)   // 120 ms is 7 frames at 60 Hz
        XCTAssertNil(timeBox()?.transition)
        XCTAssertEqual(timeBox()?.text, "10:01 AM")
    }
}

/// Spec 4 §12 — "Text raster fails (font missing, layout exception): Draw with
/// the fallback font; record the substitution for pre-flight." Spec 4 §8 —
/// "recording the substitution for pre-flight".
final class RasterFailureTests: XCTestCase {
    /// A renderer that cannot draw one font and hands everything else to the
    /// real rasterizer.
    final class BrokenFontRenderer: TextRenderer, @unchecked Sendable {
        struct Failure: Error {}
        let name = "broken-font"
        let fallbackFont = "HelveticaNeue"
        let broken: String
        private let inner = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")
        private let lock = NSLock()
        private var attemptedFonts: [String] = []

        init(broken: String) { self.broken = broken }

        var attempts: [String] { lock.lock(); defer { lock.unlock() }; return attemptedFonts }

        func rasterize(_ job: TextJob) throws -> TextRaster {
            lock.lock()
            attemptedFonts.append(job.style.values.font)
            lock.unlock()
            if job.style.values.font == broken { throw Failure() }
            return try inner.rasterize(job)
        }
    }

    func job(_ text: String = "Amen", font: String) -> TextJob {
        var values = TextStyleValues()
        values.font = font
        let style = BoxTextStyle(values: values)
        let box = PixelSize(width: 800, height: 200)
        return TextJob(key: TextKey.make(text: text, style: style, box: box, fit: TextFit(), outputHeight: 1080),
                       text: text, style: style, box: box, fit: TextFit(), outputHeight: 1080)
    }

    func test_aFailedRasterIsDrawnWithTheFallbackFontAndRecorded() throws {
        let renderer = BrokenFontRenderer(broken: "Broken-Font")
        let cache = TextCache(renderer: renderer, backend: RecordingBackend(), synchronous: true)
        let first = job(font: "Broken-Font")
        cache.request(first)
        XCTAssertNotNil(cache.entry(for: first), "drawn with the fallback font")
        XCTAssertEqual(renderer.attempts, ["Broken-Font", "HelveticaNeue"], "one retry, with the fallback font")
        XCTAssertEqual(cache.statistics.failed, 0)
        XCTAssertEqual(cache.fontSubstitutions, [FontSubstitution(requested: "Broken-Font", actual: "HelveticaNeue", count: 1)])
        cache.request(job("Again", font: "Broken-Font"))
        XCTAssertEqual(cache.fontSubstitutions.map(\.count), [2], "counted per raster, one record per font")
        XCTAssertEqual(cache.statistics.substitutedFonts, 1)
    }

    func test_aRasterThatFailsWithTheFallbackTooCountsAsFailed() throws {
        let renderer = BrokenFontRenderer(broken: "HelveticaNeue")
        let log = EngineLog(category: "test-raster")
        let cache = TextCache(renderer: renderer, backend: RecordingBackend(), synchronous: true, log: log)
        let job = job(font: "HelveticaNeue")
        cache.request(job)
        XCTAssertNil(cache.entry(for: job))
        XCTAssertEqual(cache.statistics.failed, 1)
        XCTAssertTrue(cache.fontSubstitutions.isEmpty, "nothing stood in")
        XCTAssertTrue(log.contains("text raster failed"))
    }

    /// Spec 4 §8 — "falls back to the machine's fallback font, recording the
    /// substitution": the rasterizer's own substitution lands in the same record.
    func test_anUnknownFontIsRecordedThroughTheRasterizer() throws {
        let cache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: RecordingBackend(), synchronous: true)
        cache.request(job(font: "NoSuchFont-Bold"))
        cache.request(job("Twice", font: "NoSuchFont-Bold"))
        cache.request(job(font: "NoSuchOther-Bold"))
        XCTAssertEqual(cache.fontSubstitutions, [
            FontSubstitution(requested: "NoSuchFont-Bold", actual: "HelveticaNeue", count: 2),
            FontSubstitution(requested: "NoSuchOther-Bold", actual: "HelveticaNeue", count: 1),
        ])
        XCTAssertEqual(cache.fontSubstitutions.map(\.description), ["NoSuchFont-Bold -> HelveticaNeue (2)", "NoSuchOther-Bold -> HelveticaNeue (1)"])
    }
}

/// Spec 4 §12 — "memory pressure (the system notification) shrinks the text
/// and thumbnail caches and never touches decoder pools during playback";
/// "thermal throttling is logged from the process thermal state so a rising
/// GPU time has an explanation, and changes nothing."
final class PressureTests: XCTestCase {
    func job(_ text: String) -> TextJob {
        var values = TextStyleValues()
        values.size = TextSize(value: 24)
        let style = BoxTextStyle(values: values)
        let box = PixelSize(width: 400, height: 60)
        return TextJob(key: TextKey.make(text: text, style: style, box: box, fit: TextFit(), outputHeight: 1080),
                       text: text, style: style, box: box, fit: TextFit(), outputHeight: 1080)
    }

    func test_thePolicyShrinksByLevel() {
        XCTAssertNil(CachePressurePolicy.ceilingFraction(for: .normal), "normal restores the full cap")
        XCTAssertEqual(CachePressurePolicy.ceilingFraction(for: .warning), 0.5)
        XCTAssertEqual(CachePressurePolicy.ceilingFraction(for: .critical), 0.25)
    }

    func test_warningAndCriticalShrinkTheTextCacheAndNormalRestoresIt() throws {
        let cap = 1024 * 1024
        let cache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: RecordingBackend(),
                              maximumBytes: cap, synchronous: true)
        for i in 0..<60 { cache.request(job("Line \(i)")) }
        let full = cache.statistics.bytes
        XCTAssertGreaterThan(full, cap / 2, "the cache is fuller than half its cap: \(full)")
        XCTAssertLessThanOrEqual(full, cap)
        let log = EngineLog(category: "test-pressure")
        let monitor = MemoryPressureMonitor(caches: [cache], log: log)
        XCTAssertEqual(monitor.level, .normal)
        monitor.apply(.warning)
        XCTAssertEqual(monitor.level, .warning)
        XCTAssertLessThanOrEqual(cache.statistics.bytes, cap / 2, "warning: down to half the cap")
        XCTAssertGreaterThan(cache.statistics.bytes, 0, "what the last plans used stays")
        XCTAssertTrue(log.contains("memory pressure"), log.recent.map(\.message).joined(separator: "\n"))
        monitor.apply(.critical)
        XCTAssertLessThanOrEqual(cache.statistics.bytes, cap / 4, "critical: down to a quarter")
        XCTAssertEqual(cache.statistics.shrinks, 2)
        monitor.apply(.normal)
        XCTAssertEqual(monitor.level, .normal)
        for i in 60..<120 { cache.request(job("Line \(i)")) }
        XCTAssertGreaterThan(cache.statistics.bytes, cap / 2, "the cap is back: the cache fills again")
        XCTAssertLessThanOrEqual(cache.statistics.bytes, cap)
        monitor.apply(.normal)
        XCTAssertEqual(cache.statistics.shrinks, 2, "normal to normal is not a shrink")
    }

    func test_thermalChangesAreLoggedAndChangeNothingElse() {
        let log = EngineLog(category: "test-thermal")
        let monitor = ThermalMonitor(log: log, read: { .nominal })
        XCTAssertEqual(monitor.level, .nominal)
        monitor.observe(.nominal)
        XCTAssertEqual(monitor.changes, 0, "the same state again is not a change")
        monitor.observe(.serious)
        XCTAssertEqual(monitor.level, .serious)
        XCTAssertEqual(monitor.changes, 1)
        XCTAssertTrue(log.contains("thermal state nominal -> serious"), log.recent.map(\.message).joined(separator: "\n"))
        monitor.observe(.nominal)
        XCTAssertEqual(monitor.changes, 2)
    }

    func test_theEngineOwnsBothMonitorsOverItsTextCache() throws {
        let metal = try MetalHarness.backend()
        let engine = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                                        mediaRoot: EngineFixtures.mediaRoot, metal: metal)
        engine.send("list 42 cue 1")
        engine.tick(count: 2)
        let cache = try XCTUnwrap(engine.textCache)
        XCTAssertGreaterThan(cache.statistics.bytes, 0)
        XCTAssertTrue(engine.engine.pressure.caches.contains { $0 === cache }, "the engine's text cache answers to memory pressure")
        XCTAssertEqual(engine.engine.thermal.level, ThermalLevel(ProcessInfo.processInfo.thermalState))
        let sessions = engine.engine.sources.liveCount
        engine.engine.pressure.apply(.critical)
        XCTAssertEqual(engine.engine.sources.liveCount, sessions, "never touches decoder pools during playback")
        engine.engine.pressure.apply(.normal)
    }
}
