import CoreText
import XCTest
import OCore
@testable import OEngine

/// Spec 6 §4 — "Tabular digits. A box whose text names `[Time]`, `[Timer N]`
/// or `[Service In]`, itself or inside a popup it shows, lays out its digits
/// with the font's tabular figures (`tnum`) when the font has them. A running
/// clock then stays put instead of shifting sideways every second (choice
/// T-10). The text job carries the flag, and the text cache's key includes it
/// (Spec 4 §8)."
final class TabularDigitTests: XCTestCase {
    func test_aBoxNamingAClockOrATimerAsksForTabularDigits() {
        let yes = ["[Time]", "[time h:mm a]", "Now [TIME HH:mm]", "[Timer 2]", "Doors close in [timer 1 mm:ss overrun]", "[Service In]", "[service in h:mm:ss]"]
        let no = ["[Date]", "Amen", "[Timer]", "[Timer one]", "[[Time]]", "[Popup 1]", "[Service]", "[Section]", "2026", "[Time"]
        for text in yes { XCTAssertTrue(SlotResolver.wantsTabularDigits(text, popups: [:]), text) }
        for text in no { XCTAssertFalse(SlotResolver.wantsTabularDigits(text, popups: [:]), text) }
        // Inside a popup the box shows, one level deep (Spec 6 §5, choice T-2).
        XCTAssertTrue(SlotResolver.wantsTabularDigits("[Popup 1]", popups: [1: "Doors close in [Timer 1]"]))
        XCTAssertTrue(SlotResolver.wantsTabularDigits("Next: [popup 3]", popups: [3: "[Time]"]))
        XCTAssertFalse(SlotResolver.wantsTabularDigits("[Popup 1]", popups: [1: "Welcome"]))
        XCTAssertFalse(SlotResolver.wantsTabularDigits("[Popup 1]", popups: [1: "[Popup 2]", 2: "[Time]"]), "never deeper than one level")
        XCTAssertFalse(SlotResolver.wantsTabularDigits("[Popup 2]", popups: [1: "[Time]"]))
    }

    func test_theFlagIsInTheCacheKeyAndKeepsTwoRastersApart() throws {
        let plain = TextJobs.job("10:01 AM")
        let tabular = TextJobs.job("10:01 AM", tabular: true)
        XCTAssertNotEqual(plain.key, tabular.key)
        let cache = TextCache(renderer: CoreTextLineRasterizer(fallbackFont: "HelveticaNeue"), backend: RecordingBackend(), synchronous: true)
        cache.request(plain)
        cache.request(tabular)
        XCTAssertEqual(cache.statistics.entries, 2, "a tabular and a proportional raster of the same text")
        XCTAssertNotNil(cache.entry(for: plain))
        XCTAssertNotNil(cache.entry(for: tabular))
    }

    /// "with the font's tabular figures (`tnum`) when the font has them":
    /// Skia, in every Mac's supplemental fonts, has proportional figures of its
    /// own and tabular ones on request.
    func test_tabularDigitsKeepAClockLineTheSameWidth() throws {
        let font = "Skia-Regular"
        guard (CTFontCopyPostScriptName(CTFontCreateWithName(font as CFString, 12, nil)) as String) == font else {
            throw XCTSkip("Skia is not installed")
        }
        var style = TextJobs.plain(size: 72)
        style.font = font
        // Skia is a variable font whose `wght` runs 0.48 to 3.2: naming it keeps Skia's own default (Spec 1 §2).
        style.variations = ["wght": 1]
        let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue")
        func width(_ text: String, tabular: Bool) throws -> Double {
            Double(try XCTUnwrap(rasterizer.rasterize(TextJobs.job(text, style: style, tabular: tabular)).layout.lines.first).origin.width)
        }
        XCTAssertGreaterThan(abs(try width("1:11", tabular: false) - width("0:00", tabular: false)), 10, "Skia's own figures are proportional")
        XCTAssertEqual(try width("1:11", tabular: true), try width("0:00", tabular: true), accuracy: 0.5, "tabular figures: the line keeps its width")
    }

    /// The engine sets the flag on the jobs of a `[Time]` box and of a box
    /// showing a popup that names a timer, and only those.
    func test_theEngineAsksForTabularDigitsForAClockAndAPopupShowingATimer() throws {
        var library = try EngineFixtures.library()
        library.presets.append(StageFixtures.preset(9, "Caption", boxes: [StageFixtures.label("[Popup 1]", 0)]))
        var machine = try EngineFixtures.spikeMachine()
        machine.stacks[0].slots[1].preset = 9
        let engine = try HeadlessEngine(library: library, machine: machine, mediaRoot: EngineFixtures.mediaRoot)
        let fake = try XCTUnwrap(engine.fakeText)
        fake.missAll = true
        engine.send("popup 1 set \"Doors close in [Timer 1]\"")
        engine.tick()
        let clock = fake.requested.filter { $0.text == "10:00 AM" }
        XCTAssertFalse(clock.isEmpty)
        XCTAssertTrue(clock.allSatisfy(\.tabular), "stack 2's [Time] box")
        let caption = fake.requested.filter { $0.text.hasPrefix("Doors close in") }
        XCTAssertFalse(caption.isEmpty)
        XCTAssertTrue(caption.allSatisfy(\.tabular), "a popup that names a timer")
        engine.send("popup 1 clear")
        engine.tick()
        engine.send("popup 1 set \"Welcome\"")
        engine.tick()
        let welcome = fake.requested.filter { $0.text == "Welcome" }
        XCTAssertFalse(welcome.isEmpty)
        XCTAssertFalse(welcome.contains(where: \.tabular), "a popup without one keeps the font's own figures")
        engine.send("list 42 cue 1")
        engine.tick()
        let lyric = fake.requested.filter { $0.text.hasPrefix("Great is Thy") }
        XCTAssertFalse(lyric.isEmpty)
        XCTAssertFalse(lyric.contains(where: \.tabular))
    }
}
