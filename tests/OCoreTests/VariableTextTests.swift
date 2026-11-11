import XCTest
@testable import OCore

/// Spec 6 §11, Area 11 — "Parsing. A table of variable texts: names in any
/// case, each format, `overrun` alone and after a format, doubled brackets,
/// names that print as written, a timer number above the count resolving
/// empty, and an unknown format falling back with one log line." The
/// language is Spec 6 §5's: "A variable is a name in square brackets, then
/// optionally a format, then, for a timer, optionally the word `overrun`".
/// Resolution (the empty value, the fallback and its line) is in
/// `VariableResolverTests` and the engine's `VariableValueTests`.
final class VariableTextTests: XCTestCase {
    func tokens(_ text: String) -> [VariableToken] { VariableText.parse(text).tokens }

    func token(_ name: VariableName, _ written: String, format: String? = nil, overrun: Bool = false) -> VariableToken {
        VariableToken(name: name, format: format, overrun: overrun, written: written)
    }

    /// "Names match in any case".
    func test_namesMatchInAnyCase() {
        let table: [(String, VariableName)] = [
            ("[Time]", .time), ("[time]", .time), ("[TIME]", .time),
            ("[Date]", .date), ("[dAtE]", .date),
            ("[Timer 1]", .timer(1)), ("[timer 12]", .timer(12)), ("[TIMER 3]", .timer(3)), ("[Timer 01]", .timer(1)),
            ("[Popup 3]", .popup(3)), ("[popup 3]", .popup(3)), ("[POPUP 16]", .popup(16)),
            ("[Live Title]", .liveTitle), ("[live title]", .liveTitle), ("[LIVE TITLE]", .liveTitle),
            ("[Next Title]", .nextTitle), ("[next TITLE]", .nextTitle),
            ("[Section]", .section), ("[section]", .section),
            ("[Cue Note]", .cueNote), ("[cue NOTE]", .cueNote),
            ("[Copyright]", .copyright), ("[COPYRIGHT]", .copyright),
            ("[CCLI]", .ccli), ("[ccli]", .ccli), ("[Ccli]", .ccli),
            ("[Service In]", .serviceIn), ("[service in]", .serviceIn), ("[SERVICE IN]", .serviceIn),
        ]
        for (text, name) in table {
            XCTAssertEqual(VariableText.parse(text).segments, [.variable(token(name, text))], text)
        }
    }

    /// "Names match in any case, but formats must match exactly": the format
    /// is the rest of the brackets as written, checked when it resolves.
    func test_eachFormatIsKeptAsWritten() {
        let table: [(String, VariableName, String)] = [
            ("[Time h:mm a]", .time, "h:mm a"), ("[Time HH:mm]", .time, "HH:mm"), ("[Time h:mm:ss a]", .time, "h:mm:ss a"),
            ("[Date MMMM d]", .date, "MMMM d"), ("[Date EEEE, MMMM d]", .date, "EEEE, MMMM d"), ("[Date yyyy-MM-dd]", .date, "yyyy-MM-dd"),
            ("[Timer 1 m:ss]", .timer(1), "m:ss"), ("[Timer 1 mm:ss]", .timer(1), "mm:ss"), ("[Timer 1 h:mm:ss]", .timer(1), "h:mm:ss"),
            ("[Service In m:ss]", .serviceIn, "m:ss"), ("[service in mm:ss]", .serviceIn, "mm:ss"), ("[Service In h:mm:ss]", .serviceIn, "h:mm:ss"),
            // Outside the set, or on a name that takes none: still the variable, with the format as written.
            ("[Time hh:mm]", .time, "hh:mm"), ("[time H:MM]", .time, "H:MM"), ("[Date MMM d]", .date, "MMM d"),
            ("[Time  HH:mm]", .time, " HH:mm"), ("[Time ]", .time, ""), ("[Section x]", .section, "x"), ("[Popup 1 big]", .popup(1), "big"),
        ]
        for (text, name, format) in table {
            XCTAssertEqual(tokens(text), [token(name, text, format: format)], text)
        }
        XCTAssertEqual(VariableName.time.formats, ["h:mm a", "HH:mm", "h:mm:ss a"])
        XCTAssertEqual(VariableName.date.formats, ["MMMM d", "EEEE, MMMM d", "yyyy-MM-dd"])
        XCTAssertEqual(VariableName.timer(1).formats, ["m:ss", "mm:ss", "h:mm:ss"])
        XCTAssertEqual(VariableName.serviceIn.formats, ["m:ss", "mm:ss", "h:mm:ss"])
        for name: VariableName in [.popup(1), .liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli] {
            XCTAssertNil(name.formats, "\(name) takes no format")
        }
    }

    /// "then, for a timer, optionally the word `overrun`: `[Timer 1 overrun]`,
    /// `[Timer 1 mm:ss overrun]`". The word matches in any case and comes last;
    /// on anything but a timer it is noted and the value renders as the default.
    func test_overrunAloneAndAfterAFormat() {
        XCTAssertEqual(tokens("[Timer 1 overrun]"), [token(.timer(1), "[Timer 1 overrun]", overrun: true)])
        XCTAssertEqual(tokens("[Timer 1 mm:ss overrun]"), [token(.timer(1), "[Timer 1 mm:ss overrun]", format: "mm:ss", overrun: true)])
        XCTAssertEqual(tokens("[timer 2 OVERRUN]"), [token(.timer(2), "[timer 2 OVERRUN]", overrun: true)])
        XCTAssertEqual(tokens("[Timer 1 h:mm:ss Overrun]"), [token(.timer(1), "[Timer 1 h:mm:ss Overrun]", format: "h:mm:ss", overrun: true)])
        // Before the format it is part of the format, which is then outside the set.
        XCTAssertEqual(tokens("[Timer 1 overrun mm:ss]"), [token(.timer(1), "[Timer 1 overrun mm:ss]", format: "overrun mm:ss")])
        // On anything else it is still read, for the resolver to note.
        XCTAssertEqual(tokens("[Time overrun]"), [token(.time, "[Time overrun]", overrun: true)])
        XCTAssertEqual(tokens("[Service In overrun]"), [token(.serviceIn, "[Service In overrun]", overrun: true)])
    }

    /// "Doubled brackets print one bracket, so `[[Time]]` prints `[Time]`".
    func test_doubledBracketsPrintOneBracket() {
        XCTAssertEqual(VariableText.parse("[[Time]]").segments, [.text("[Time]")])
        XCTAssertEqual(VariableText.parse("a [[ b ]] c").segments, [.text("a [ b ] c")])
        XCTAssertEqual(VariableText.parse("[[[Time]]]").segments, [.text("["), .variable(token(.time, "[Time]")), .text("]")])
        XCTAssertEqual(VariableText.parse("x]]").segments, [.text("x]")])
        XCTAssertFalse(VariableText.parse("[[Time]]").hasVariables)
    }

    /// "Brackets around anything that isn't a v1 name print as written, so a
    /// lyric's `[Chorus]` or `[x2]` shows unchanged" (choice T-1). Names are
    /// the table's words, single-spaced, with a slot number of 1 or more.
    func test_otherBracketedTextPrintsAsWritten() {
        let asWritten = ["[Chorus]", "[x2]", "[MUSIC]", "[Timer]", "[Timer one]", "[Timer 0]", "[Timer -1]", "[Timer +1]",
                         "[Popup]", "[Popup x]", "[ Time]", "[Timer  1]", "[Live]", "[Live Item]", "[Next]", "[Cue]",
                         "[Service]", "[Service Out]", "[Times]", "[Timecode]", "[]", "[Channel 2 Content]", "[Time[x]"]
        for text in asWritten {
            XCTAssertEqual(VariableText.parse(text).segments, [.text(text)], text)
            XCTAssertFalse(VariableText.parse(text).hasVariables, text)
        }
        // An unclosed bracket, and a bracket that opens again before closing, print as written.
        XCTAssertEqual(VariableText.parse("[Time").segments, [.text("[Time")])
        XCTAssertEqual(VariableText.parse("a ] b").segments, [.text("a ] b")])
        XCTAssertEqual(VariableText.parse("[a [Time]]").segments, [.text("[a "), .variable(token(.time, "[Time]")), .text("]")])
        // Lyrics around a variable keep every character.
        XCTAssertEqual(VariableText.parse("[x2] Great is Thy faithfulness [Chorus]\n[Section]").segments,
                       [.text("[x2] Great is Thy faithfulness [Chorus]\n"), .variable(token(.section, "[Section]"))])
        XCTAssertEqual(VariableText.parse("No brackets at all").segments, [.text("No brackets at all")])
        XCTAssertEqual(VariableText.parse("").segments, [])
    }

    /// "A timer or popup number above the machine's count is still a v1
    /// name" (it resolves empty, `VariableResolverTests`).
    func test_aNumberAboveAnyCountIsStillAName() {
        XCTAssertEqual(tokens("[Timer 99]"), [token(.timer(99), "[Timer 99]")])
        XCTAssertEqual(tokens("[Popup 17]"), [token(.popup(17), "[Popup 17]")])
        XCTAssertEqual(tokens("[Timer 99999999999999999999999]").map(\.name), [.timer(Int.max)])
    }

    /// Spec 6 §4 — "A box whose text names `[Time]`, `[Timer N]` or `[Service
    /// In]`" asks for tabular digits; Spec 6 §5 — how soon each name's change
    /// shows: "context values at once", "A popup also shows at once, but at
    /// most ten times a second", "The clock, a timer or `[Service In]` ... at
    /// most once per wall-clock second" (`[Date]` is the clock's).
    func test_whatEachNameAsksFor() {
        let tabular: [VariableName] = [.time, .timer(1), .serviceIn]
        let proportional: [VariableName] = [.date, .popup(1), .liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli]
        for name in tabular { XCTAssertTrue(name.asksForTabularDigits, "\(name)") }
        for name in proportional { XCTAssertFalse(name.asksForTabularDigits, "\(name)") }
        for name: VariableName in [.liveTitle, .nextTitle, .section, .cueNote, .copyright, .ccli] { XCTAssertEqual(name.pacing, .context, "\(name)") }
        XCTAssertEqual(VariableName.popup(2).pacing, .popup)
        for name: VariableName in [.time, .date, .timer(1), .serviceIn] { XCTAssertEqual(name.pacing, .clocked, "\(name)") }
        XCTAssertTrue(VariableText.parse("Doors close in [timer 1 mm:ss overrun]").asksForTabularDigits)
        XCTAssertFalse(VariableText.parse("[Date] [[Time]]").asksForTabularDigits)
    }
}
