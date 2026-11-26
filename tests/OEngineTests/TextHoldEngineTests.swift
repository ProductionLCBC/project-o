import XCTest
import OCore
@testable import OEngine

/// A text provider that keeps what was released, over the harness's fake.
final class RecordingText: TextProvider, @unchecked Sendable {
    let fake: FakeTextProvider
    private let lock = NSLock()
    private var releases: [(key: TextKey, afterTick: Int64)] = []

    init(_ fake: FakeTextProvider) {
        self.fake = fake
    }

    var released: [(key: TextKey, afterTick: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return releases
    }

    func entry(for job: TextJob) -> TextEntry? { fake.entry(for: job) }
    func request(_ job: TextJob) { fake.request(job) }

    func release(_ key: TextKey, afterTick: Int64) {
        lock.lock()
        releases.append((key, afterTick))
        lock.unlock()
    }
}

/// Spec 4 §9 — "When the box has been drawing this text and only its raster
/// is missing, the box keeps drawing its previous lines until the new raster
/// is ready and counts nothing late: after an edit that changes how the text
/// looks (the box's frame, fit or text style, or the text style itself),
/// after its stack changes size (section 5), when the lines are scaled with
/// the stack, and when a variable in it takes a new value (section 8). So a
/// look edit, a stack switch or a clock's new minute never blanks a line for
/// a tick (Spec 5 §2). Text a cue has just written is not the text the box
/// was drawing, and still waits for its own raster". Adam's answer of
/// 2026-11-18. And Spec 4 §9, box transitions "are tracked per box of a slot
/// of a stack": a box keeps what it drew when its slot moves, and a box that
/// becomes another box starts afresh.
final class TextHoldEngineTests: XCTestCase {
    typealias E = EngineFixtures
    typealias S = StageFixtures

    var engine: HeadlessEngine!
    var fake: FakeTextProvider!
    var text: RecordingText!
    var control: ControlLoop { engine.control }

    /// Stack 2's slot for channel 2 draws preset 9, of `boxes`; preset 10 is another preset with one body box.
    func makeEngine(boxes: [Box], clock: SettableWallClock = SettableWallClock(), mainSize: Size = .hd) throws {
        var library = try E.library()
        var machine = try E.spikeMachine(mainSize: mainSize)
        machine.settings.libraryMode = .writable
        library.presets.append(S.preset(9, "Hold", boxes: boxes))
        library.presets.append(S.preset(10, "Another", boxes: [S.body(0, y: 0.5, size: 0.2)]))
        library.lists.append(S.three)
        machine.stacks[1].slots[0].preset = 9
        let backend = RecordingBackend()
        fake = FakeTextProvider(backend: backend)
        text = RecordingText(fake)
        engine = try HeadlessEngine(library: library, machine: machine, media: E.media, backend: backend, sourceFactory: FakeSourceFactory(),
                                    posters: FakePosterProvider(backend: backend), text: text, wallClock: { clock.now })
    }

    /// The box preset 9 draws for channel 2 on stack 2.
    func box(file: StaticString = #filePath, line: UInt = #line) throws -> ResolvedBox {
        try XCTUnwrap(engine.boxes(stack: 2, channel: 2).first, "stack 2 draws channel 2's box", file: file, line: line)
    }

    func lines(_ box: ResolvedBox) -> [TextLine] {
        if case .lines(let lines) = box.content { return lines }
        return []
    }

    func apply(_ edit: String, file: StaticString = #filePath, line: UInt = #line) {
        if let rejection = engine.send(edit, source: .ui) { XCTFail("\(edit) → \(rejection.message)", file: file, line: line) }
        let before = engine.rejections.count
        engine.tick()
        if engine.rejections.count > before { XCTFail("\(edit) → \(engine.rejections.last?.message ?? "")", file: file, line: line) }
        if let blocked = engine.lastExecuted.first(where: { $0.result == .blocked }) {
            XCTFail("\(edit) → blocked: \(blocked.refusal?.message ?? "")", file: file, line: line)
        }
    }

    // MARK: - A variable's new value (Spec 4 §8)

    /// "Until the new raster is ready the box keeps drawing the old value's
    /// lines (section 9), so a clock never blanks as its minute changes, and
    /// that counts nothing late."
    func test_aClocksNewMinuteKeepsTheOldLinesUntilItsRasterIsReady() throws {
        let clock = SettableWallClock(SettableWallClock.at(2026, 11, 22, 10, 0, 30))
        try makeEngine(boxes: [S.label("[Time]", 0)], clock: clock)
        engine.tick(count: 3)
        let before = try box()
        XCTAssertFalse(lines(before).isEmpty)
        _ = engine.drainMetrics()

        fake.missAll = true
        clock.advance(seconds: 60)
        engine.tick()
        let held = try box()
        XCTAssertNotEqual(held.text, before.text, "the box took the new minute")
        XCTAssertEqual(held.content, before.content, "and goes on drawing the old minute's lines")
        XCTAssertNil(held.transition)
        XCTAssertEqual(control.textLateThisBuild, 0)
        XCTAssertEqual(engine.drainMetrics().last?.textLate, 0, "the render thread counts nothing late either")
        XCTAssertTrue(fake.requested.contains { $0.text == held.text }, "the new minute's raster was asked for")
        XCTAssertTrue(text.released.isEmpty, "the old minute's raster stays while the box draws it")

        engine.tick(count: 3)
        XCTAssertEqual(try box().content, before.content, "for as long as the raster takes")
        XCTAssertEqual(control.textLateThisBuild, 0)

        fake.missAll = false
        engine.tick()
        let fresh = try box()
        XCTAssertFalse(lines(fresh).isEmpty)
        XCTAssertNotEqual(fresh.content, before.content, "the new minute's own lines")
        XCTAssertEqual(text.released.count, 2, "and now the old minute's raster goes: this box's, and that of the fixture's clock beside it")
    }

    /// Spec 4 §8 — "Boxes with `transitionOnVariableChange` run their box
    /// transition between the old and new textures": the transition starts
    /// when the new texture is there, not while the old lines are held.
    func test_aValuesTransitionStartsWhenItsRasterArrives() throws {
        let clock = SettableWallClock(SettableWallClock.at(2026, 11, 22, 10, 0, 30))
        var label = S.label("[Time]", 0)
        label.transition = BoxTransition(ref: 2, ms: 500)
        label.transitionOnVariableChange = true
        try makeEngine(boxes: [label], clock: clock)
        engine.tick(count: 3)
        let before = try box()

        fake.missAll = true
        clock.advance(seconds: 60)
        engine.tick(count: 2)
        XCTAssertNil(try box().transition, "nothing to dissolve to yet")
        XCTAssertEqual(try box().content, before.content)

        fake.missAll = false
        engine.tick()
        let arrived = try box()
        XCTAssertEqual(arrived.transition?.type, .dissolve)
        XCTAssertEqual(arrived.transition?.outgoing, before.content, "from the old minute's lines")
        XCTAssertNotEqual(arrived.content, before.content)
        // The old raster outlives the dissolve that shows it.
        let release = try XCTUnwrap(text.released.first)
        XCTAssertGreaterThanOrEqual(release.afterTick, engine.frame + 30)
    }

    // MARK: - A look edit (Spec 5 §2)

    func test_aLookEditKeepsTheLinesUntilTheNewRasterIsReady() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)])
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        let before = try box()
        XCTAssertEqual(before.text, "a")
        XCTAssertFalse(lines(before).isEmpty)

        fake.missAll = true
        apply("edit preset 9 layouts.*.boxes.0.frame {\"h\": 0.2, \"w\": 0.5, \"x\": 0.05, \"y\": 0.5}")
        let held = try box()
        XCTAssertEqual(held.frame.y, 540, accuracy: 0.5, "the box is where the edit put it")
        XCTAssertEqual(held.content, before.content, "its lines are the ones it had, until the new raster is ready")
        XCTAssertEqual(control.textLateThisBuild, 0)

        fake.missAll = false
        engine.tick()
        let fresh = try box()
        XCTAssertEqual(lines(fresh).first?.frame.y ?? 0, 540, accuracy: 0.5, "the new raster, laid out in the new frame")
        XCTAssertNil(fresh.transition, "the same text: nothing to transition between")
    }

    /// The box's own text style is part of how its text looks.
    func test_aBoxesTextStyleEditKeepsTheLinesToo() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)])
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        let before = try box()
        XCTAssertFalse(lines(before).isEmpty)

        fake.missAll = true
        apply("edit preset 9 layouts.*.boxes.0.textStyle.size.value 48")
        XCTAssertEqual(try box().content, before.content)
        XCTAssertEqual(control.textLateThisBuild, 0)
        XCTAssertTrue(fake.requested.contains { $0.text == "a" && $0.style.values.size.value == 48 }, "the new look's raster was asked for")
    }

    // MARK: - New text still waits

    func test_textACueHasJustWrittenStillWaitsForItsOwnRaster() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)])
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        XCTAssertFalse(lines(try box()).isEmpty)
        _ = engine.drainMetrics()

        fake.missAll = true
        engine.send("list 51 cue 2")
        engine.tick()
        let late = try box()
        XCTAssertEqual(late.text, "b")
        XCTAssertTrue(lines(late).isEmpty, "not the text the box was drawing: it draws nothing this tick")
        // Stack 1 draws channel 2 as well, through Preset 1: two boxes wait. The clock on stack 2 kept its lines.
        XCTAssertEqual(control.textLateThisBuild, 2)
        // The render thread counts the boxes that draw nothing: both, since Preset 1's body box on stack 1 takes
        // channel 2's default transition, a cut (Spec 4 §9 as corrected 2026-11-25), and isn't dissolving out of its
        // old lines.
        XCTAssertEqual(engine.drainMetrics().last?.textLate, 2)
    }

    // MARK: - A stack that changes size (Spec 4 §5)

    /// "The stack's text draws from its previous rasters, scaled, until the new ones are ready".
    func test_aResizedStacksTextDrawsFromItsPreviousRastersScaled() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)], mainSize: Size(width: 3840, height: 2160))
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        let before = try box()
        XCTAssertEqual(control.geometry.stackSize(2), PixelSize(width: 1920, height: 1080))

        fake.missAll = true
        XCTAssertNil(engine.send("output 1 stack 2"))   // the 3840 by 2160 output takes stack 2
        engine.tick()
        XCTAssertEqual(control.geometry.stackSize(2), PixelSize(width: 3840, height: 2160))
        let held = try box()
        XCTAssertEqual(held.frame.width, before.frame.width * 2, accuracy: 0.5)
        let was = lines(before)
        let now = lines(held)
        XCTAssertEqual(now.count, was.count)
        XCTAssertFalse(now.isEmpty)
        for (old, new) in zip(was, now) {
            XCTAssertEqual(new.texture, old.texture, "the raster it had")
            XCTAssertEqual(new.frame.x, old.frame.x * 2, accuracy: 0.01)
            XCTAssertEqual(new.frame.y, old.frame.y * 2, accuracy: 0.01)
            XCTAssertEqual(new.frame.width, old.frame.width * 2, accuracy: 0.01)
            XCTAssertEqual(new.frame.height, old.frame.height * 2, accuracy: 0.01)
        }
        XCTAssertEqual(control.textLateThisBuild, 0)

        fake.missAll = false
        engine.tick()
        XCTAssertNotEqual(lines(try box()).first?.texture, was.first?.texture, "the raster made for the new size")
    }

    // MARK: - Which box a run belongs to (Spec 4 §9)

    /// A slot that moves in its stack is the same slot: its boxes keep what they drew.
    func test_aBoxKeepsItsLinesWhenItsSlotMoves() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)])
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        let before = try box()
        fake.missAll = true
        apply("edit stack 2 slot 2 move 1")
        XCTAssertEqual(engine.engine.machine.stack(2)?.slots.map(\.channel), [3, 2])
        XCTAssertEqual(try box().content, before.content)
        XCTAssertEqual(control.textLateThisBuild, 0)
    }

    /// A slot given another preset draws other boxes: the first box of the
    /// new preset is not the first box of the old one, and waits for its raster.
    func test_aBoxOfAnotherPresetStartsAfresh() throws {
        try makeEngine(boxes: [S.body(0, y: 0.1)])
        engine.send("list 51 cue 1")
        engine.tick(count: 2)
        XCTAssertFalse(lines(try box()).isEmpty)
        fake.missAll = true
        apply("edit stack 2 slot 2 preset 10")
        let other = try box()
        XCTAssertEqual(other.frame.y, 540, accuracy: 0.5, "preset 10's box")
        XCTAssertTrue(lines(other).isEmpty)
        XCTAssertNil(other.transition)
        XCTAssertEqual(control.textLateThisBuild, 1, "channel 2's box; the clock beside it kept its lines")
    }
}
