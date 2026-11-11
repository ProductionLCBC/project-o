import XCTest
import OCore
@testable import OEngine

/// Spec 6 §11, Area 11 — "Adoption. Popup sets at 30 a second are adopted no
/// closer than 100 ms apart and always end on the newest value. Captions sent
/// ten times a second each show within 100 ms and a frame. A clock box
/// changes once a wall-clock second. A context value changes on the fire's
/// own frame. First and empty values show at once." Spec 6 §5 — "When a box
/// adopts a new value. A box whose text names variables is laid out again
/// only when its resolved text changes ... How soon depends on what changed:
/// A context value changed by a fire shows at once (choice T-5) ... A popup
/// also shows at once, but at most ten times a second. A new value is adopted
/// on the first frame at least 100 ms after the box's previous adoption, and
/// the value adopted then is the newest (P10). The clock, a timer or `[Service
/// In]` alone changes the box at most once per wall-clock second ... A box's
/// first value, and a value going empty, show at once". The harness's master
/// tick is 60 Hz: 100 ms is six frames.
final class AdoptionTests: XCTestCase {
    typealias S = StageFixtures
    typealias E = EngineFixtures

    /// Stack 2's slot for channel 2 drawing `boxes`, under a wall clock the test sets.
    func engine(_ boxes: [Box], clock: SettableWallClock = SettableWallClock()) throws -> HeadlessEngine {
        var library = try E.library()
        var machine = try E.spikeMachine()
        library.presets.append(S.preset(9, "Adoption", boxes: boxes))
        machine.stacks[1].slots[0].preset = 9
        return try HeadlessEngine(library: library, machine: machine, mediaRoot: E.mediaRoot, wallClock: { clock.now })
    }

    func shown(_ engine: HeadlessEngine, _ raw: String, offset: Int = 0) -> String? {
        engine.boxes(stack: 2, channel: 2).first { box in
            guard case .static(let text) = box.binding.kind else { return false }
            return text == raw && box.offset == offset
        }?.text
    }

    func body(_ engine: HeadlessEngine) -> ResolvedBox? {
        engine.boxes(stack: 2, channel: 2).first { if case .field = $0.binding.kind { return true } else { return false } }
    }

    /// "Popup sets at 30 a second are adopted no closer than 100 ms apart and
    /// always end on the newest value."
    func test_popupSetsAtThirtyASecondAreAdoptedAtLeast100msApartAndEndOnTheNewest() throws {
        let engine = try engine([S.label("[Popup 1]", 0)])
        var adoptions: [(frame: Int64, text: String)] = []
        var latest = ""
        func observe() {
            guard let now = shown(engine, "[Popup 1]"), now != adoptions.last?.text else { return }
            XCTAssertEqual(now, latest, "frame \(engine.frame): the value adopted is the newest")
            adoptions.append((engine.frame, now))
        }
        for i in 0..<30 {
            engine.send("popup 1 set \"line \(i)\"")
            engine.tick()
            latest = "line \(i)"
            observe()
            engine.tick()
            observe()
        }
        for _ in 0..<12 {
            engine.tick()
            observe()
        }
        XCTAssertEqual(adoptions.first?.text, "line 0", "the first value shows at once")
        for (a, b) in zip(adoptions, adoptions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.frame - a.frame, 6, "\(a.text) at \(a.frame), \(b.text) at \(b.frame)")
        }
        XCTAssertGreaterThanOrEqual(adoptions.count, 9, "about one adoption every 100 ms over a second")
        XCTAssertEqual(adoptions.last?.text, "line 29", "it ends on the newest value")
    }

    /// "Captions sent ten times a second each show within 100 ms and a frame"
    /// (Spec 6 §7: "captions run at most a tenth of a second and a frame
    /// behind, not a line behind").
    func test_captionsAtTenASecondEachShowWithin100msAndAFrame() throws {
        let engine = try engine([S.label("[Popup 1]", 0)])
        for i in 0..<20 {
            engine.send("popup 1 set \"caption \(i)\"")
            var landed: Int64?
            var shownAt: Int64?
            for _ in 0..<6 {
                engine.tick()
                if landed == nil { landed = engine.frame }
                if shownAt == nil, shown(engine, "[Popup 1]") == "caption \(i)" { shownAt = engine.frame }
            }
            let at = try XCTUnwrap(shownAt, "caption \(i) never showed")
            XCTAssertLessThanOrEqual(at - (landed ?? 0), 7, "caption \(i)")
        }
    }

    /// "The clock ... alone changes the box at most once per wall-clock
    /// second": a seconds clock, the wall clock moving a sixtieth of a second
    /// a tick, changes on each new second and on no other frame.
    func test_aClockBoxChangesOnceAWallClockSecond() throws {
        let clock = SettableWallClock(SettableWallClock.at(2026, 10, 30, 10, 0, 0.5))
        let engine = try engine([S.label("[Time h:mm:ss a]", 0)], clock: clock)
        var changes: [(second: Int, text: String)] = []
        for _ in 0..<300 {
            clock.advance(seconds: 1.0 / 60)
            engine.tick()
            let second = Int(clock.now.timeIntervalSince1970.rounded(.down))
            guard let now = shown(engine, "[Time h:mm:ss a]"), now != changes.last?.text else { continue }
            changes.append((second, now))
        }
        XCTAssertEqual(changes.map(\.text), ["10:00:00 AM", "10:00:01 AM", "10:00:02 AM", "10:00:03 AM", "10:00:04 AM", "10:00:05 AM"])
        XCTAssertEqual(Set(changes.map(\.second)).count, changes.count, "never twice in one wall-clock second")
    }

    /// "A context value changed by a fire shows at once (choice T-5)": with
    /// the wall clock standing still, each fire's section shows on the fire's
    /// own frame, at 0 and at +1.
    func test_aContextValueChangesOnTheFiresOwnFrame() throws {
        let engine = try engine([S.label("[Section]", 0), S.label("[Section]", 1, y: 0.3), S.label("[Live Title] [CCLI]", 0, y: 0.5)])
        engine.send("list 42 cue 1")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Section]"), "Verse 1")
        engine.send("list 42 cue 4")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Section]"), "Chorus", "the next frame, in the same wall-clock second")
        XCTAssertNil(shown(engine, "[Section]", offset: 1), "past the list's last cue")
        engine.send("list 7 cue 1")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Section]"), "Verse")
        XCTAssertEqual(shown(engine, "[Section]", offset: 1), "Verse")
        XCTAssertEqual(shown(engine, "[Live Title] [CCLI]"), "Doxology 56204")
        engine.send("list 7 cue 2")
        engine.tick()
        engine.send("list 7 cue 3")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Section]"), "Out")
    }

    /// "A box's first value, and a value going empty, show at once": while a
    /// popup's change waits out the 100 ms, a clear shows at once, and so
    /// does the value after it, the box's first again; inside a text that
    /// stays, a popup going empty shows at once.
    func test_firstAndEmptyValuesShowAtOnce() throws {
        let engine = try engine([S.label("[Popup 1]", 0), S.label("Nursery: [Popup 2]", 0, y: 0.3)])
        engine.send("popup 1 set \"a\"")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Popup 1]"), "a", "the first value")
        engine.send("popup 1 set \"b\"")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Popup 1]"), "a", "a change within 100 ms waits")
        engine.send("popup 1 clear")
        engine.tick()
        XCTAssertNil(shown(engine, "[Popup 1]"), "a clear shows at once")
        engine.send("popup 1 set \"c\"")
        engine.tick()
        XCTAssertEqual(shown(engine, "[Popup 1]"), "c", "the value after a clear is the box's first again")
        XCTAssertEqual(shown(engine, "Nursery: [Popup 2]"), "Nursery: ")
        engine.tick(count: 6)
        engine.send("popup 2 set \"Room 12\"")
        engine.tick()
        XCTAssertEqual(shown(engine, "Nursery: [Popup 2]"), "Nursery: Room 12")
        engine.send("popup 2 set \"Room 14\"")
        engine.tick()
        XCTAssertEqual(shown(engine, "Nursery: [Popup 2]"), "Nursery: Room 12", "a change within 100 ms waits")
        engine.send("popup 2 clear")
        engine.tick()
        XCTAssertEqual(shown(engine, "Nursery: [Popup 2]"), "Nursery: ", "a value going empty shows at once")
    }

    /// Spec 6 §5 — "A box with `transitionOnVariableChange` runs its box
    /// transition between the old text and the new; the rest swap (Spec 4
    /// §8)": a field box's value change swaps unless the box asks, and new
    /// content transitions as any write does.
    func test_aFieldBoxsValueChangeSwapsUnlessTheBoxAsksAndNewContentTransitions() throws {
        for asks in [false, true] {
            let box = Box(binding: .field(name: "body"), frame: Frame(x: 0.05, y: 0.1, w: 0.9, h: 0.2),
                          fit: .text(TextFit(policy: .shrinkToFit, maxLines: 2, minSize: 12)), textStyle: BoxTextStyle(),
                          transition: BoxTransition(ref: 2, ms: 500), transitionOnVariableChange: asks)
            let engine = try engine([box])
            engine.send("channel 2 write text \"[Popup 1]\"")
            engine.tick()
            XCTAssertNil(body(engine), "an empty field hides the box")
            engine.send("popup 1 set \"a\"")
            engine.tick()
            XCTAssertEqual(body(engine)?.text, "a")
            XCTAssertNil(body(engine)?.transition)
            engine.tick(count: 6)
            engine.send("popup 1 set \"b\"")
            engine.tick()
            XCTAssertEqual(body(engine)?.text, "b")
            XCTAssertEqual(body(engine)?.transition?.type, asks ? .dissolve : nil, "a value change, transitionOnVariableChange \(asks)")
            engine.tick(count: 40)
            engine.send("channel 2 write text \"plain\"")
            engine.tick()
            XCTAssertEqual(body(engine)?.text, "plain")
            XCTAssertEqual(body(engine)?.transition?.type, .dissolve, "new content transitions, transitionOnVariableChange \(asks)")
        }
    }
}

