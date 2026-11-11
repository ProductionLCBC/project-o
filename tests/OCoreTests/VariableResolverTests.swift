import XCTest
@testable import OCore

/// Spec 6 §5 — the v1 set resolved against the state being drawn, over the
/// fixture library (Spec 1 §10): list 42, Great Is Thy Faithfulness, whose
/// fourth cue is the Chorus with the note "Build the lights here"; list 7,
/// Doxology; and the Sunday playlist (a header, list 42, its local copy, a
/// header, list 7). Spec 6 §11, Area 11 — "Values. Each v1 variable is read
/// from a live state, a +1 lookahead state and a thumbnail's state. Context
/// values follow provenance in content and the pointer in static boxes.
/// `[Next Title]` skips headers, is empty after the last list, and is empty in
/// a thumbnail"; "Popups. ... A variable in a popup's text resolves, a
/// `[Popup N]` inside it prints as written, and other bracketed text shows as
/// sent." The engine's tests read the same through its states and boxes.
final class VariableResolverTests: XCTestCase {
    typealias F = FixtureLibrary
    static let loaded = F.load()

    var library: Library { Self.loaded.library }
    var machine: Machine { Self.loaded.machine }
    var roots: VariableRoots { VariableRoots(library: library, machine: machine, kept: KeptCopies()) }

    /// Sunday 8 November 2026, 10:30:15 in the machine's zone.
    let morning = WallClockReading(year: 2026, month: 11, day: 8, weekday: 1, hour: 10, minute: 30, second: 15)
    var chorus: LivePointer { LivePointer(listUuid: F.listUuid(42), cueUuid: F.list42Cues[3]) }
    var doxologyVerse: Provenance { .cue(F.list7Cues[0], list: F.listUuid(7)) }

    func clock(timeFormat: String = "h:mm a", serviceIn: Int? = nil, timers: [Int: TimerReading] = [:]) -> VariableClock {
        VariableClock(wall: morning, timeFormat: timeFormat, serviceInSeconds: serviceIn, timers: timers, timerSlots: 4, popupSlots: 4)
    }

    func state(pointer: LivePointer? = nil, body: String? = nil, provenance: Provenance? = nil, popups: [Int: String] = [:]) -> ShowState {
        var state = ShowState.fresh(library: library, machine: machine)
        state.pointer = pointer
        if let body {
            state.channels[2]?.content = .text(TextInstance(fields: ["body": body]))
            state.channels[2]?.provenance = provenance
        }
        state.popups = popups
        return state
    }

    func resolve(_ text: String, _ state: ShowState, scope: VariableScope = .pointer, clock: VariableClock? = nil,
                 roots: VariableRoots? = nil) -> ResolvedText {
        VariableResolver.resolve(text, state: state, scope: scope, roots: roots ?? self.roots, clock: clock ?? self.clock())
    }

    // MARK: - Context values (Spec 6 §5, "Which state a value reads")

    /// "In a static box, a value reads the state's pointer: its cue and its list."
    func test_aStaticBoxReadsThePointersCueAndList() {
        let text = "[Live Title]|[Section]|[Cue Note]|[Copyright]|[CCLI]"
        XCTAssertEqual(resolve(text, state(pointer: chorus)).text, "Great Is Thy Faithfulness|Chorus|Build the lights here|Public domain|18723")
        // "Context values in static boxes ... Nothing loaded: Empty" (Spec 7 §4).
        XCTAssertEqual(resolve(text, state()).text, "||||")
        // "A playlist loaded, no cue fired: Empty".
        XCTAssertEqual(resolve(text, state(pointer: LivePointer(playlist: F.playlistUuid))).text, "||||")
    }

    /// "In text content, a value reads the content's provenance: the cue that
    /// wrote it and the list that cue was fired from."
    func test_contentReadsItsProvenance() {
        let text = "[Live Title]|[Section]|[Cue Note]|[Copyright]|[CCLI]"
        let shown = state(pointer: chorus, body: text, provenance: doxologyVerse)
        XCTAssertEqual(resolve(text, shown, scope: .content(channel: 2)).text, "Doxology|Verse||Public domain|56204")
        XCTAssertEqual(resolve(text, shown, scope: .pointer).text, "Great Is Thy Faithfulness|Chorus|Build the lights here|Public domain|18723",
                       "the same state, read by a static box")
        // "a restored channel keeps the cue and list it had".
        let restored = state(pointer: chorus, body: text, provenance: .restored(cue: F.list7Cues[0], list: F.listUuid(7)))
        XCTAssertEqual(resolve(text, restored, scope: .content(channel: 2)).text, "Doxology|Verse||Public domain|56204")
    }

    /// "Content no cue wrote, from the UI, a key, OSC, the API or the
    /// scheduler, reads the state's pointer instead"; content written under a
    /// provenance with no list (from a `last.json` before Area 6) reads the
    /// pointer's list, as Area 6 read it.
    func test_contentNoCueWroteReadsThePointer() {
        let text = "[Live Title] [Section]"
        for provenance: Provenance in [.source(.osc), .source(.ui), .source(.key), .restored(cue: nil, list: nil), .cue(F.list7Cues[0], list: nil)] {
            let shown = state(pointer: chorus, body: text, provenance: provenance)
            XCTAssertEqual(resolve(text, shown, scope: .content(channel: 2)).text, "Great Is Thy Faithfulness Chorus", "\(provenance)")
        }
    }

    /// Spec 7 §4 — "Context values in static boxes ... A cue fired: The live
    /// list and cue, from the kept copies when they are gone."
    func test_keptCopiesStandInWhenTheListOrTheCueIsGone() {
        let original = try! XCTUnwrap(library.list(number: 42))
        var withoutList = library
        withoutList.lists.removeAll { $0.number == 42 }
        let gone = VariableRoots(library: withoutList, machine: machine, kept: KeptCopies(list: original))
        XCTAssertEqual(resolve("[Live Title]/[Section]/[Cue Note]", state(pointer: chorus), roots: gone).text,
                       "Great Is Thy Faithfulness/Chorus/Build the lights here")
        var withoutCue = library
        withoutCue.lists = withoutCue.lists.map { list in
            var list = list
            if list.number == 42 { list.cues.removeLast(); list.title = "Great Is Thy Faithfulness (edited)" }
            return list
        }
        let edited = VariableRoots(library: withoutCue, machine: machine, kept: KeptCopies(list: original))
        XCTAssertEqual(resolve("[Live Title]/[Section]/[Cue Note]", state(pointer: chorus), roots: edited).text,
                       "Great Is Thy Faithfulness (edited)/Chorus/Build the lights here", "the list as it is now, the gone cue from the kept copy")
        XCTAssertEqual(resolve("[Live Title]", state(pointer: chorus), roots: VariableRoots(library: withoutList, machine: machine, kept: KeptCopies())).text, "")
    }

    /// `[Next Title]`: "The title of the next list in the live playlist. It
    /// skips headers and items whose list is missing or has no cues, as
    /// `next` does, and is empty after the last list or with no playlist";
    /// Spec 7 §4 — "A playlist loaded, no cue fired: The first list's title";
    /// "`[Next Title]` reads the state's pointer in both cases ... A projected
    /// state has no playlist, so in a thumbnail it is empty."
    func test_nextTitleReadsThePlaylistPosition() {
        func at(_ item: Int, list: UUID, cue: UUID) -> LivePointer {
            LivePointer(playlist: F.playlistUuid, itemUuid: F.sundayItems[item - 1], listUuid: list, cueUuid: cue)
        }
        XCTAssertEqual(resolve("[Next Title]", state(pointer: at(2, list: F.listUuid(42), cue: F.list42Cues[0]))).text,
                       "Great Is Thy Faithfulness (Manheim)", "item 3, the local copy")
        XCTAssertEqual(resolve("[Next Title]", state(pointer: at(3, list: F.localCopyUuid, cue: F.list42Cues[0]))).text,
                       "Doxology", "the header at item 4 is skipped")
        XCTAssertEqual(resolve("[Next Title]", state(pointer: at(5, list: F.listUuid(7), cue: F.list7Cues[0]))).text, "", "after the last list")
        XCTAssertEqual(resolve("[Next Title]", state(pointer: LivePointer(playlist: F.playlistUuid))).text,
                       "Great Is Thy Faithfulness", "a playlist loaded, no cue fired: the first list's title")
        XCTAssertEqual(resolve("[Next Title]", state(pointer: chorus)).text, "", "a list fired from the library, with no playlist")
        XCTAssertEqual(resolve("[Next Title]", state()).text, "", "nothing loaded")
        // The same in content: it reads the pointer, not the provenance.
        let shown = state(pointer: at(2, list: F.listUuid(42), cue: F.list42Cues[0]), body: "[Next Title]", provenance: doxologyVerse)
        XCTAssertEqual(resolve("[Next Title]", shown, scope: .content(channel: 2)).text, "Great Is Thy Faithfulness (Manheim)")
    }

    // MARK: - Popups (Spec 6 §5, §7)

    /// "`[Popup N]` reads the state's own popup text (Spec 3 §2) ... The
    /// variables inside that text read the same state"; "A `[Popup N]` inside
    /// a popup's text prints as written, so resolution never goes deeper than
    /// one level"; "Brackets around anything that isn't a v1 name still print
    /// as written (T-1), so a caption's `[MUSIC]` shows as sent."
    func test_aPopupResolvesOneLevelDeep() {
        let popups = [1: "Now: [Section] at [Time]", 2: "[Popup 1] and [MUSIC] [[x]]", 3: "[Section x]"]
        let shown = state(pointer: chorus, body: "[Popup 1]", provenance: doxologyVerse, popups: popups)
        XCTAssertEqual(resolve("[Popup 1]", shown).text, "Now: Chorus at 10:30 AM")
        XCTAssertEqual(resolve("[Popup 1]", shown, scope: .content(channel: 2)).text, "Now: Verse at 10:30 AM",
                       "in content, the popup's values read the content's cue")
        XCTAssertEqual(resolve("[Popup 2]", shown).text, "[Popup 1] and [MUSIC] [x]")
        // "Empty values ... `Nursery: [Popup 1]` shows just "Nursery:" while the slot is clear".
        XCTAssertEqual(resolve("Nursery: [Popup 4]", shown).text, "Nursery: ")
        XCTAssertEqual(resolve("[Popup 4]", shown).text, "")
        // "A timer or popup number above the machine's count ... resolves empty".
        XCTAssertEqual(resolve("[Popup 5]", state(popups: [5: "five"])).text, "")
        // A format in a popup's text that is outside the set is noted like any other.
        XCTAssertEqual(resolve("[Popup 3]", shown).issues.map(\.token), ["[Section x]"])
    }

    // MARK: - Clocked values

    /// `[Time]`, `[Date]`, `[Service In]` and `[Timer N]`: "read the same in
    /// every state"; "`[Timer N]` Timer N's value (§6); empty while unset";
    /// "`[Service In]` ... is empty when no playlist is live or the live one
    /// has no `serviceTime`".
    func test_clockedValues() {
        let shown = state(pointer: chorus)
        XCTAssertEqual(resolve("[Time]", shown).text, "10:30 AM")
        XCTAssertEqual(resolve("[Time HH:mm]", shown).text, "10:30")
        XCTAssertEqual(resolve("[Time h:mm:ss a]", shown).text, "10:30:15 AM")
        XCTAssertEqual(resolve("[Time]", shown, clock: clock(timeFormat: "HH:mm")).text, "10:30", "the machine's timeFormat")
        XCTAssertEqual(resolve("[Date]", shown).text, "November 8", "choice T-9")
        XCTAssertEqual(resolve("[Date EEEE, MMMM d]|[Date yyyy-MM-dd]", shown).text, "Sunday, November 8|2026-11-08")
        XCTAssertEqual(resolve("[Service In]", shown, clock: clock(serviceIn: 1800)).text, "30:00")
        XCTAssertEqual(resolve("[Service In mm:ss]|[Service In h:mm:ss]", shown, clock: clock(serviceIn: 4500)).text, "75:00|1:15:00")
        XCTAssertEqual(resolve("[Service In]", shown, clock: clock(serviceIn: 0)).text, "0:00")
        XCTAssertEqual(resolve("[Service In]", shown).text, "")
        XCTAssertEqual(resolve("[Timer 1]", shown).text, "", "every timer is unset")
        XCTAssertEqual(resolve("[Timer 9]", shown).text, "", "above the count")
        let running = clock(timers: [1: TimerReading(state: .running, direction: .down, setMs: 300_000, valueMs: 299_500),
                                     2: TimerReading(state: .running, direction: .down, setMs: 60_000, valueMs: -1500),
                                     3: TimerReading(state: .paused, direction: .up, setMs: 0, valueMs: 61_900)])
        XCTAssertEqual(resolve("[Timer 1]|[Timer 1 mm:ss]|[Timer 1 h:mm:ss]", shown, clock: running).text, "5:00|05:00|0:05:00")
        XCTAssertEqual(resolve("[Timer 2]|[Timer 2 overrun]|[Timer 2 mm:ss overrun]", shown, clock: running).text, "0:00|-0:01|-00:01")
        XCTAssertEqual(resolve("[Timer 3]|[Timer 3 overrun]", shown, clock: running).text, "1:01|1:01", "overrun means nothing on a count-up")
        XCTAssertEqual(resolve("[Timer 3 overrun]", shown, clock: running).issues, [], "a count-up is a timer: nothing to note")
    }

    // MARK: - Formats outside the set (Spec 6 §5)

    /// "A format outside the set, or `overrun` on anything but a timer,
    /// renders with the default and is logged once per box. So does a machine
    /// `timeFormat` outside the `[Time]` set." The resolver names each one;
    /// the engine logs it once per box.
    func test_aFormatOutsideTheSetRendersTheDefaultAndIsNoted() {
        let shown = state(pointer: chorus)
        let time = resolve("[Time HH:mm:ss]", shown)
        XCTAssertEqual(time.text, "10:30 AM")
        XCTAssertEqual(time.issues.map(\.token), ["[Time HH:mm:ss]"])
        XCTAssertTrue(time.issues.first?.message.contains("h:mm a, HH:mm, h:mm:ss a") == true, time.issues.first?.message ?? "")
        XCTAssertEqual(resolve("[Date dd/MM]", shown).text, "November 8")
        XCTAssertEqual(resolve("[Date dd/MM]", shown).issues.count, 1)
        XCTAssertEqual(resolve("[Service In ss]", shown, clock: clock(serviceIn: 75)).text, "1:15")
        XCTAssertEqual(resolve("[Time overrun]", shown).text, "10:30 AM")
        XCTAssertEqual(resolve("[Time overrun]", shown).issues.count, 1)
        XCTAssertEqual(resolve("[Service In overrun]", shown, clock: clock(serviceIn: 75)).text, "1:15")
        XCTAssertEqual(resolve("[Service In overrun]", shown, clock: clock(serviceIn: 75)).issues.count, 1)
        // A format on a name that takes none: the value, noted.
        XCTAssertEqual(resolve("[Section x]", shown).text, "Chorus")
        XCTAssertEqual(resolve("[Section x]", shown).issues.count, 1)
        // The machine's `timeFormat` outside the set.
        let odd = clock(timeFormat: "HH:mm:ss")
        XCTAssertEqual(resolve("[Time]", shown, clock: odd).text, "10:30 AM")
        XCTAssertEqual(resolve("[Time]", shown, clock: odd).issues.count, 1)
        XCTAssertEqual(resolve("[Time HH:mm]", shown, clock: odd).text, "10:30")
        XCTAssertEqual(resolve("[Time HH:mm]", shown, clock: odd).issues, [], "its own format: the machine's isn't used")
        XCTAssertEqual(resolve("[Time] [Time]", shown).issues, [])
    }

    // MARK: - What a box needs from a resolution

    /// Spec 6 §5 — "Brackets around anything that isn't a v1 name print as
    /// written"; "Doubled brackets print one bracket"; Spec 6 §4 — the tabular
    /// flag from the names, one level into the popups shown; and each value
    /// with how soon a change to it shows, for the box's adoption (§5).
    func test_textValuesAndTabularDigits() {
        let shown = state(pointer: chorus, popups: [1: "T [Timer 1]", 2: "Welcome", 3: "[Popup 4]", 4: "[Time]"])
        let plain = resolve("[x2] Amen [[Time]] [Chorus]", shown)
        XCTAssertEqual(plain.text, "[x2] Amen [Time] [Chorus]")
        XCTAssertFalse(plain.hasVariables)
        XCTAssertEqual(plain.values, [])
        let mixed = resolve("[Time] / [Section] / [Popup 1]", shown)
        XCTAssertEqual(mixed.text, "10:30 AM / Chorus / T ")
        XCTAssertTrue(mixed.tabular)
        XCTAssertEqual(mixed.values, [
            ResolvedValue(written: "[Time]", pacing: .clocked, value: "10:30 AM"),
            ResolvedValue(written: "[Section]", pacing: .context, value: "Chorus"),
            ResolvedValue(written: "[Popup 1]", pacing: .popup, value: "T [Timer 1]"),
            ResolvedValue(written: "[Timer 1]", pacing: .clocked, value: ""),
        ])
        XCTAssertFalse(resolve("[Popup 2]", shown).tabular)
        XCTAssertTrue(resolve("[Popup 1]", shown).tabular, "a popup that names a timer")
        XCTAssertFalse(resolve("[Popup 3]", shown).tabular, "never deeper than one level")
        XCTAssertTrue(VariableResolver.asksForTabularDigits("Next: [popup 1]", popups: shown.popups))
        XCTAssertFalse(VariableResolver.asksForTabularDigits("[Popup 9]", popups: shown.popups))
    }
}
