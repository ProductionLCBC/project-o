import Foundation
import XCTest
@testable import OCore

/// Spec 2 §10 — Round trip: "For every row of the vocabulary table, a text
/// example parses to the expected object and prints back to the canonical
/// text; `parse(print(x)) == x` over a corpus that includes every rider, every
/// short form, abbreviated hashes, escaped strings and both duration
/// spellings." Plus Spec 1 §10's text half: "Every command object in the
/// fixtures converts to canonical text and back without loss."
final class CommandTextTests: XCTestCase {
    typealias F = FixtureLibrary

    static let dawn = F.dawn
    static let mountains = F.mountains
    static let slide = F.welcomeSlide
    static let slideUuid = "51de0000-0000-4000-8000-000000000001"

    struct Row {
        let text: String
        let command: Command
        let canonical: String
    }

    func row(_ text: String, _ command: Command, canonical: String? = nil) -> Row {
        Row(text: text, command: command, canonical: canonical ?? text)
    }

    func write(_ channel: Target, _ content: ContentExpression, _ riders: Riders = .none) -> Command {
        .channelWrite(ChannelWrite(channel: channel, content: content, riders: riders))
    }

    // MARK: - Helpers

    @discardableResult
    func parsed(_ text: String, _ options: ParseOptions = ParseOptions(),
                file: StaticString = #filePath, line: UInt = #line) -> GuardedCommand? {
        switch CommandText.parse(text, options: options) {
        case .success(let entry):
            return entry
        case .failure(let rejection):
            XCTFail("\(text) → \(rejection.reason.rawValue): \(rejection.message)", file: file, line: line)
            return nil
        }
    }

    /// Parses `text`, checks the object, prints it back and checks the
    /// canonical text, then parses the canonical text again.
    func check(_ row: Row, _ options: ParseOptions = ParseOptions(), file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = parsed(row.text, options, file: file, line: line) else { return }
        XCTAssertEqual(entry.command, row.command, row.text, file: file, line: line)
        XCTAssertNil(entry.when, row.text, file: file, line: line)
        XCTAssertEqual(CommandText.print(row.command), row.canonical, row.text, file: file, line: line)
        guard let again = parsed(row.canonical, options, file: file, line: line) else { return }
        XCTAssertEqual(again.command, row.command, row.canonical, file: file, line: line)
    }

    func check(_ text: String, prints canonical: String, _ options: ParseOptions = ParseOptions(),
               file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = parsed(text, options, file: file, line: line) else { return }
        XCTAssertEqual(CommandText.print(entry), canonical, text, file: file, line: line)
    }

    // MARK: - Spec 2 §3, one example per row of the vocabulary table

    lazy var vocabulary: [Row] = [
        // Channels
        row("channel 1 write media \(Self.dawn) loop transition 2 1.0 once",
            write(.number(1), .media(MediaContent(ref: Self.dawn, loop: true)),
                  Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))),
        row("channel 2 clear", .channelClear(channel: .number(2))),
        row("channel 2 reset", .channelReset(channel: .number(2))),
        row("channel all reset", .channelReset(channel: .all)),
        row("channel 2 transition 2 0.5", .channelTransition(channel: .number(2), ref: 2, ms: 500)),
        row("channel 2 transition 2", .channelTransition(channel: .number(2), ref: 2, ms: nil)),
        row("channel 2 audiotransition 2 0.5", .channelAudioTransition(channel: .number(2), ref: 2, ms: 500)),
        row("channel 2 audiotransition 2", .channelAudioTransition(channel: .number(2), ref: 2, ms: nil)),
        row("channel 2 grade 5", .channelGrade(channel: .number(2), ref: 5, ms: nil)),
        row("channel 2 grade 5 2.0", .channelGrade(channel: .number(2), ref: 5, ms: 2000)),
        row("channel 2 grade 0", .channelGrade(channel: .number(2), ref: 0, ms: nil)),
        row("channel 2 gain -6", .channelGain(channel: .number(2), db: -6)),
        row("channel 2 gain -6.5", .channelGain(channel: .number(2), db: -6.5)),
        row("channel 2 play", .channelTransport(channel: .number(2), mode: .play)),
        row("channel 2 pause", .channelTransport(channel: .number(2), mode: .pause)),
        row("channel 2 stop", .channelTransport(channel: .number(2), mode: .stop)),
        row("channel 2 end loop", .channelEndBehavior(channel: .number(2), mode: .loop)),
        row("channel 2 end hold", .channelEndBehavior(channel: .number(2), mode: .hold)),
        row("channel 2 end clear", .channelEndBehavior(channel: .number(2), mode: .clear)),
        row("channel 2 lock", .channelLock(channel: .number(2), locked: true)),
        row("channel 2 unlock", .channelLock(channel: .number(2), locked: false)),
        row("channel 2 freeze on", .channelFreeze(channel: .number(2), state: .on)),
        row("channel 2 freeze off", .channelFreeze(channel: .number(2), state: .off)),
        row("channel 2 skip", .channelTrack(channel: .number(2), direction: .skip)),
        row("channel 2 back", .channelTrack(channel: .number(2), direction: .back)),
        row("channel 2 build 3", .channelBuild(channel: .number(2), build: 3)),
        // Stacks and outputs
        row("output 1 stack 4", .outputStack(output: 1, stack: 4)),
        row("stack 2 blackout on", .stackBlackout(stack: 2, state: .on)),
        row("stack 2 blackout off", .stackBlackout(stack: 2, state: .off)),
        row("stack 2 blackout toggle", .stackBlackout(stack: 2, state: .toggle)),
        row("stack 2 mute 1 toggle", .stackMute(stack: 2, channel: 1, state: .toggle)),
        // Playlist and library navigation
        row("next", .next),
        row("previous", .previous),
        row("cue 7", .cue(7)),
        row("item 4 cue 3", .itemCue(item: 4, cue: 3)),
        row("item 4 section \"chorus\"", .itemSection(item: 4, section: "chorus")),
        row("list 42 cue 3", .listCue(list: 42, cue: 3)),
        row("playlist \"Sunday\" 2026-11-01", .playlistLoad(title: "Sunday", date: "2026-11-01")),
        row("playlist \"Sunday\"", .playlistLoad(title: "Sunday", date: nil)),
        // Timers, popups and audio
        row("timer 1 set 5:00", .timerSet(timer: 1, ms: 300_000)),
        row("timer 1 start", .timerStart(timer: 1)),
        row("timer 2 pause", .timerPause(timer: 2)),
        row("timer 3 reset", .timerReset(timer: 3)),
        row("popup 3 set \"Nursery: please come to room 12\" clearafter 30",
            .popupSet(popup: 3, text: "Nursery: please come to room 12", clearAfterMs: 30_000)),
        row("popup 3 set \"Hi\"", .popupSet(popup: 3, text: "Hi", clearAfterMs: nil)),
        row("popup 3 clear", .popupClear(popup: 3)),
        row("audio 2 mute on", .audioMute(audio: .number(2), state: .on)),
        row("audio all mute toggle", .audioMute(audio: .all, state: .toggle)),
        // Macros, history and system
        row("macro 12", .macro(12)),
        row("undo", .undo),
        row("redo", .redo),
        row("history jump 5", .historyJump(5)),
        row("system clearall", .systemClearAll),
        row("system preflight", .systemPreflight),
        row("system snapshot", .systemSnapshot),
        // The reserved edit shape
        row("edit channel 2 label \"Lyrics\"",
            .edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Lyrics")))),
    ]

    func test_everyVocabularyRowParsesAndPrintsCanonically() {
        for row in vocabulary { check(row) }
        // Every `cmd` of the vocabulary has a row above.
        let seen = Set(vocabulary.map(\.command.cmd))
        let expected = Command.knownNames.subtracting(["macro", "next", "previous", "cue", "undo", "redo"])
        XCTAssertEqual(expected.subtracting(seen), [], "rows missing")
    }

    // MARK: - Spec 2 §2, content expressions and riders

    func test_everyContentKindAndEveryRider() {
        let media = MediaContent(ref: Self.dawn, inMs: 2000, outMs: 90_000, loop: true, gain: -3, syncOffsetMs: 40)
        let riders = Riders(
            transition: TransitionRider(ref: 2, ms: 1000, scope: .once),
            audioTransition: TransitionRider(ref: 2, ms: nil, scope: .track),
            grade: GradeRider(ref: 1, ms: 2000, scope: .track),
            gain: GainRider(db: -6, scope: .once),
            chase: ChaseRider(scope: .track),
            build: 2)
        check(row("channel 1 write media \(Self.dawn) in 0:02 out 1:30 loop gain -3 sync 40 "
                  + "transition 2 1.0 once audiotransition 2 track grade 1 2.0 track gain -6 once chase track build 2",
                  write(.number(1), .media(media), riders)))
        check(row("channel 2 write text \"There is no shadow\\nof turning with Thee\"",
                  write(.number(2), .text(fields: ["body": "There is no shadow\nof turning with Thee"]))))
        check(row("channel 2 write text body \"Verse\" title \"Great Is Thy Faithfulness\"",
                  write(.number(2), .text(fields: ["body": "Verse", "title": "Great Is Thy Faithfulness"]))))
        check(row("channel 2 write text title \"Only a title\"",
                  write(.number(2), .text(fields: ["title": "Only a title"]))))
        check(row("channel 2 write text", write(.number(2), .text(fields: [:]))))
        check(row("channel 2 write text \"my key\" \"v\"", write(.number(2), .text(fields: ["my key": "v"]))))
        check(row("channel 3 write \(Self.slide) build 2", write(.number(3), .slide(ref: Self.slide, build: 2))))
        check(row("channel 3 write \(Self.slide)", write(.number(3), .slide(ref: Self.slide, build: nil))))
        check(row("channel 3 write \(Self.slide) build 2 transition 2 1.0 once",
                  write(.number(3), .slide(ref: Self.slide, build: 2),
                        Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once)))))
        check(row("channel 1 write input 2", write(.number(1), .input(2))))
        check(row("channel 1 write input 2 transition 1 once",
                  write(.number(1), .input(2), Riders(transition: TransitionRider(ref: 1, ms: nil, scope: .once)))))
        check(row("channel 1 write empty", write(.number(1), .empty)))
        check(row("channel all write empty", write(.all, .empty)))
        // A build rider on media content stays a rider (Spec 3 §3 rule 8: a noop there).
        check(row("channel 1 write media \(Self.dawn) build 2",
                  write(.number(1), .media(MediaContent(ref: Self.dawn)), Riders(build: 2))))
    }

    /// Decision 3 (Area 3 plan): inside a media write, `gain DB` with no scope
    /// is the content's gain override; with a scope it is the rider.
    func test_mediaGainOverrideVersusGainRider() {
        check(row("channel 1 write media \(Self.dawn) gain -6",
                  write(.number(1), .media(MediaContent(ref: Self.dawn, gain: -6)))))
        check(row("channel 1 write media \(Self.dawn) gain -6 once",
                  write(.number(1), .media(MediaContent(ref: Self.dawn)), Riders(gain: GainRider(db: -6, scope: .once)))))
        check(row("channel 1 write media \(Self.dawn) gain -3 gain -6 track",
                  write(.number(1), .media(MediaContent(ref: Self.dawn, gain: -3)), Riders(gain: GainRider(db: -6, scope: .track)))))
    }

    /// Decision 4 (Area 3 plan): on a slide write the build belongs to the
    /// content; a `build` rider is folded into it.
    func test_buildRiderOnASlideWriteFoldsIntoTheContent() {
        check(row("channel 3 write \(Self.slide) transition 2 1.0 once build 2",
                  write(.number(3), .slide(ref: Self.slide, build: 2),
                        Riders(transition: TransitionRider(ref: 2, ms: 1000, scope: .once))),
                  canonical: "channel 3 write \(Self.slide) build 2 transition 2 1.0 once"))
        // Both given: the content keeps its own, the rider stays a rider.
        check(row("channel 3 write \(Self.slide) build 1 build 2",
                  write(.number(3), .slide(ref: Self.slide, build: 1), Riders(build: 2))))
    }

    // MARK: - Spec 2 §4, accepted spellings print canonically

    func test_shortFormsAndSpellingsPrintCanonically() {
        let ids = ParseOptions(mediaIDs: [Self.dawn, Self.mountains])
        check("ch 2 clear", prints: "channel 2 clear")
        check("  Channel   2   CLEAR ", prints: "channel 2 clear")
        check("7", prints: "cue 7")
        check("channel 1 write media sha256:55c84469c37e tr 2 1.0 once", prints:
              "channel 1 write media \(Self.dawn) transition 2 1.0 once", ids)
        check("channel 1 write media sha256:55c84469c37e1e6a72a9b8", prints: "channel 1 write media \(Self.dawn)", ids)
        check("channel 1 write media \(Self.dawn.uppercased())", prints: "channel 1 write media \(Self.dawn)")
        check("channel 3 write slide:\(Self.slideUuid.uppercased())", prints: "channel 3 write \(Self.slide)")
        check("CHANNEL 1 WRITE EMPTY", prints: "channel 1 write empty")
        check("Channel 2 End Loop", prints: "channel 2 end loop")
        check("System ClearAll", prints: "system clearall")
        check("channel 1 write media \(Self.dawn) grade 1 track tr 2 1.0 once", prints:
              "channel 1 write media \(Self.dawn) transition 2 1.0 once grade 1 track")
        check("channel 1 write media \(Self.dawn) sync 40 gain -3 loop out 1:30 in 0:02", prints:
              "channel 1 write media \(Self.dawn) in 0:02 out 1:30 loop gain -3 sync 40")
        check("channel 2 write text body \"a\"", prints: "channel 2 write text \"a\"")
        check("channel 2 write text title \"T\" body \"b\"", prints: "channel 2 write text body \"b\" title \"T\"")
        check("channel 2 gain -6.0", prints: "channel 2 gain -6")
        check("channel 2 gain +3", prints: "channel 2 gain 3")
        check("item 4 section \"Chorus\"", prints: "item 4 section \"Chorus\"")
    }

    /// Decision 2 (Area 3 plan): a standalone attribute write is always tracked
    /// (Spec 3 §3 rule 2); the §2 examples' trailing `track` is accepted and
    /// never printed.
    func test_trailingTrackOnStandaloneAttributeWrites() {
        check("channel 2 grade 5 track", prints: "channel 2 grade 5")
        check("channel 2 grade 5 2.0 track", prints: "channel 2 grade 5 2.0")
        check("channel 2 gain -6 track", prints: "channel 2 gain -6")
        check("channel 2 transition 2 1 track", prints: "channel 2 transition 2 1.0")
        check("channel 2 audiotransition 2 track", prints: "channel 2 audiotransition 2")
    }

    /// Decision 1 (Area 3 plan): positions and timers print clock style,
    /// effect durations print as seconds with a point; every spelling parses.
    func test_durationSpellings() {
        check("channel 2 transition 2 1", prints: "channel 2 transition 2 1.0")
        check("channel 2 transition 2 0:01", prints: "channel 2 transition 2 1.0")
        check("channel 2 transition 2 1.50", prints: "channel 2 transition 2 1.5")
        check("channel 2 transition 2 0.033", prints: "channel 2 transition 2 0.033")
        check("channel 2 transition 2 2:30", prints: "channel 2 transition 2 150.0")
        check("channel 2 grade 5 0:00.25", prints: "channel 2 grade 5 0.25")
        check("timer 1 set 300", prints: "timer 1 set 5:00")
        check("timer 1 set 90.5", prints: "timer 1 set 1:30.5")
        check("timer 1 set 1:02:03", prints: "timer 1 set 1:02:03")
        check("timer 1 set 3723", prints: "timer 1 set 1:02:03")
        check("timer 1 set 0:00.033", prints: "timer 1 set 0:00.033")
        check("timer 1 set 0", prints: "timer 1 set 0:00")
        check("channel 1 write media \(Self.dawn) in 2 out 90", prints: "channel 1 write media \(Self.dawn) in 0:02 out 1:30")
        check("channel 1 write media \(Self.dawn) in 1.5", prints: "channel 1 write media \(Self.dawn) in 0:01.5")
        check("channel 1 write media \(Self.dawn) transition 2 0:01 once", prints:
              "channel 1 write media \(Self.dawn) transition 2 1.0 once")
        check("channel 1 write media \(Self.dawn) transition 2 once", prints:
              "channel 1 write media \(Self.dawn) transition 2 once")
        XCTAssertEqual(parsed("timer 1 set 1:02:03")?.command, .timerSet(timer: 1, ms: 3_723_000))
        XCTAssertEqual(parsed("timer 1 set 0:00.033")?.command, .timerSet(timer: 1, ms: 33))
    }

    func test_durationText() {
        XCTAssertEqual(DurationText.ms("5:00"), 300_000)
        XCTAssertEqual(DurationText.ms("0:30"), 30_000)
        XCTAssertEqual(DurationText.ms("1:02:03"), 3_723_000)
        XCTAssertEqual(DurationText.ms("1.5"), 1500)
        XCTAssertEqual(DurationText.ms("2"), 2000)
        XCTAssertEqual(DurationText.ms("0:01.5"), 1500)
        XCTAssertEqual(DurationText.ms("0"), 0)
        XCTAssertNil(DurationText.ms("0:90"))
        XCTAssertNil(DurationText.ms("-1"))
        XCTAssertNil(DurationText.ms("1e3"))
        XCTAssertNil(DurationText.ms(":30"))
        XCTAssertNil(DurationText.ms("1:2:3:4"))
        XCTAssertNil(DurationText.ms("abc"))
        XCTAssertNil(DurationText.ms(""))
        XCTAssertEqual(DurationText.text(ms: 2000, style: .clock), "0:02")
        XCTAssertEqual(DurationText.text(ms: 90_000, style: .clock), "1:30")
        XCTAssertEqual(DurationText.text(ms: 3_723_000, style: .clock), "1:02:03")
        XCTAssertEqual(DurationText.text(ms: 1500, style: .clock), "0:01.5")
        XCTAssertEqual(DurationText.text(ms: 33, style: .clock), "0:00.033")
        XCTAssertEqual(DurationText.text(ms: 0, style: .clock), "0:00")
        XCTAssertEqual(DurationText.text(ms: 1000, style: .seconds), "1.0")
        XCTAssertEqual(DurationText.text(ms: 500, style: .seconds), "0.5")
        XCTAssertEqual(DurationText.text(ms: 1250, style: .seconds), "1.25")
        XCTAssertEqual(DurationText.text(ms: 33, style: .seconds), "0.033")
        XCTAssertEqual(DurationText.text(ms: 150_000, style: .seconds), "150.0")
        XCTAssertEqual(DurationText.text(ms: 0, style: .seconds), "0.0")
    }

    // MARK: - Spec 2 §2, strings with JSON escapes

    func test_escapedStrings() {
        check(row("channel 2 write text \"say \\\"hi\\\"\\n\\ttab\\\\\"",
                  write(.number(2), .text(fields: ["body": "say \"hi\"\n\ttab\\"]))))
        check("channel 2 write text \"\\u0041\\u00e9\"", prints: "channel 2 write text \"Aé\"")
        check("channel 2 write text \"a\\/b\"", prints: "channel 2 write text \"a/b\"")
        check("popup 1 set \"\"", prints: "popup 1 set \"\"")
        check(row("popup 1 set \"line one\\rline two\\u0001\"",
                  .popupSet(popup: 1, text: "line one\rline two\u{01}", clearAfterMs: nil)))
    }

    // MARK: - Spec 2 §7, guards in text

    func test_guardsParseAndPrint() {
        func guarded(_ text: String, _ condition: Guard, _ command: Command, canonical: String? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
            guard let entry = parsed(text, file: file, line: line) else { return }
            XCTAssertEqual(entry.when, condition, text, file: file, line: line)
            XCTAssertEqual(entry.command, command, text, file: file, line: line)
            XCTAssertEqual(CommandText.print(GuardedCommand(command, when: condition)), canonical ?? text, text, file: file, line: line)
        }
        guarded("when [Timer 1] is 0:00 channel 2 clear",
                Guard(variable: "Timer 1", op: .is, value: "0:00"), .channelClear(channel: .number(2)))
        guarded("when [Output 1 Stack] is 2 output 1 stack 1",
                Guard(variable: "Output 1 Stack", op: .is, value: "2"), .outputStack(output: 1, stack: 1))
        guarded("when [Channel 2 Content] is empty channel 2 write text \"Welcome\"",
                Guard(variable: "Channel 2 Content", op: .isEmpty), write(.number(2), .text(fields: ["body": "Welcome"])))
        guarded("when [Channel 2 Content] is not empty channel 2 clear",
                Guard(variable: "Channel 2 Content", op: .isNotEmpty), .channelClear(channel: .number(2)))
        guarded("when [Timer 1] greater than 0:30 next", Guard(variable: "Timer 1", op: .greaterThan, value: "0:30"), .next)
        guarded("when [Timer 1] less than 1:00 next", Guard(variable: "Timer 1", op: .lessThan, value: "1:00"), .next)
        guarded("when [Channel 2 Lock] is not on channel 2 clear",
                Guard(variable: "Channel 2 Lock", op: .isNot, value: "on"), .channelClear(channel: .number(2)))
        guarded("when [Live Title] is \"Great Is Thy Faithfulness\" next",
                Guard(variable: "Live Title", op: .is, value: "Great Is Thy Faithfulness"), .next)
        // Keywords are case-insensitive and the short forms expand; the variable keeps its spelling.
        guarded("WHEN [timer 1] IS 0:00 ch 2 clear",
                Guard(variable: "timer 1", op: .is, value: "0:00"), .channelClear(channel: .number(2)),
                canonical: "when [timer 1] is 0:00 channel 2 clear")
        guarded("when [ Timer 1 ] is 0:00 next", Guard(variable: "Timer 1", op: .is, value: "0:00"), .next,
                canonical: "when [Timer 1] is 0:00 next")
        // A quoted simple value prints bare; a value that would read as a keyword stays quoted.
        guarded("when [Timer 1] is \"0:00\" next", Guard(variable: "Timer 1", op: .is, value: "0:00"), .next,
                canonical: "when [Timer 1] is 0:00 next")
        XCTAssertEqual(CommandText.print(Guard(variable: "Live Title", op: .is, value: "empty")), "when [Live Title] is \"empty\"")
        XCTAssertEqual(CommandText.print(Guard(variable: "Live Title", op: .isNot, value: "not")), "when [Live Title] is not \"not\"")
        XCTAssertEqual(CommandText.print(Guard(variable: "Live Title", op: .is, value: "")), "when [Live Title] is \"\"")
        XCTAssertEqual(CommandText.print(Guard(variable: "Timer 1", op: .isEmpty, value: nil)), "when [Timer 1] is empty")
        for condition in [Guard(variable: "Live Title", op: .is, value: "empty"),
                          Guard(variable: "Live Title", op: .isNot, value: "not"),
                          Guard(variable: "Live Title", op: .is, value: ""),
                          Guard(variable: "Live Title", op: .is, value: "two words"),
                          Guard(variable: "Live Title", op: .is, value: "[bracket]")] {
            let text = CommandText.print(GuardedCommand(.next, when: condition)) ?? ""
            XCTAssertEqual(parsed(text)?.when, condition, text)
        }
    }

    // MARK: - Spec 2 §10, parse(print(x)) == x over a corpus

    func test_corpusRoundTrips() {
        let corpus: [Command] = [
            write(.number(1), .media(MediaContent(ref: Self.mountains)), Riders(
                transition: TransitionRider(ref: 2, ms: 1000, scope: .once),
                audioTransition: TransitionRider(ref: 2, ms: nil, scope: .track),
                grade: GradeRider(ref: 1, ms: 2000, scope: .track),
                gain: GainRider(db: -6, scope: .once),
                chase: ChaseRider(scope: .track),
                build: 2)),
            write(.all, .media(MediaContent(ref: Self.dawn, inMs: 2000, outMs: nil, loop: true, gain: -3, syncOffsetMs: 10))),
            write(.number(2), .text(fields: ["body": "Great is Thy faithfulness,\nO God my Father"])),
            write(.number(2), .text(fields: ["body": "b", "title": "t", "subtitle": "s"])),
            write(.number(2), .text(fields: [:])),
            write(.number(3), .slide(ref: Self.slide, build: nil)),
            write(.number(3), .slide(ref: Self.slide, build: 0)),
            write(.number(1), .input(2)),
            write(.number(1), .empty, Riders(transition: TransitionRider(ref: 3, ms: 0, scope: .once))),
            .channelClear(channel: .number(2)), .channelReset(channel: .all),
            .channelTransition(channel: .number(1), ref: 2, ms: 500),
            .channelTransition(channel: .number(1), ref: 2, ms: 0),
            .channelAudioTransition(channel: .number(1), ref: 2, ms: nil),
            .channelGrade(channel: .number(1), ref: 0, ms: nil),
            .channelGrade(channel: .all, ref: 1, ms: 33),
            .channelGain(channel: .number(1), db: -6.5),
            .channelGain(channel: .number(1), db: 0),
            .channelGain(channel: .number(1), db: -0.25),
            .channelTransport(channel: .number(1), mode: .stop),
            .channelEndBehavior(channel: .number(1), mode: .clear),
            .channelLock(channel: .number(1), locked: true),
            .channelFreeze(channel: .number(1), state: .on),
            .channelFreeze(channel: .number(1), state: .toggle),
            .channelTrack(channel: .number(1), direction: .back),
            .channelBuild(channel: .number(1), build: 3),
            .outputStack(output: 1, stack: 4),
            .stackBlackout(stack: 2, state: .toggle),
            .stackMute(stack: 2, channel: 1, state: .off),
            .next, .previous, .cue(7),
            .itemCue(item: 4, cue: 3),
            .itemSection(item: 4, section: "chorus"),
            .itemSection(item: 4, section: "Verse \"two\""),
            .listCue(list: 42, cue: 3),
            .playlistLoad(title: "Sunday", date: "2026-11-01"),
            .playlistLoad(title: "Sunday", date: nil),
            .playlistLoad(title: "", date: nil),
            .timerSet(timer: 1, ms: 300_000), .timerSet(timer: 1, ms: 0), .timerSet(timer: 1, ms: 3_723_456),
            .timerStart(timer: 1), .timerPause(timer: 2), .timerReset(timer: 3),
            .popupSet(popup: 3, text: "Nursery", clearAfterMs: 30_000), .popupSet(popup: 3, text: "", clearAfterMs: nil),
            .popupClear(popup: 3),
            .audioMute(audio: .all, state: .on),
            .macro(12), .undo, .redo, .historyJump(5), .historyJump(0),
            .systemClearAll, .systemPreflight, .systemSnapshot,
            .edit(EditCommand(target: "channel", number: 2, field: "label", value: .string("Lyrics"))),
            .edit(EditCommand(target: "stack", number: 1, field: "gammaBlend", value: .bool(true))),
            .edit(EditCommand(target: "channel", number: 2, field: "decoderCap", value: .number(3))),
            .edit(EditCommand(target: "channel", number: 2, field: "audioOutputs", value: .array([.number(1), .number(2)]))),
            .edit(EditCommand(target: "channel", number: 2, field: "defaults", value: .object(["gain": .number(-6)]))),
            .edit(EditCommand(target: "channel", number: 2, field: "label", value: nil)),
        ]
        for command in corpus {
            guard let text = CommandText.print(command) else { return XCTFail("no text for \(command)") }
            XCTAssertEqual(parsed(text)?.command, command, text)
        }
    }

    func test_unknownAndInvalidCommandsHaveNoText() {
        XCTAssertNil(CommandText.print(.unknown(cmd: "channel.teleport", fields: ["channel": .number(2)])))
        XCTAssertNil(CommandText.print(.invalid(cmd: "channel.clear", fields: ["channel": .string("two")])))
    }

    // MARK: - Spec 1 §10, the fixture library's commands in text

    func test_everyFixtureCommandConvertsToTextAndBack() {
        let (library, machine, _) = F.load()
        var entries: [(String, GuardedCommand)] = []
        for list in library.lists + machine.localLists {
            for (c, cue) in list.cues.enumerated() {
                for (i, entry) in cue.commands.enumerated() { entries.append(("list \(list.number) cue \(c + 1) command \(i + 1)", entry)) }
            }
        }
        for macro in library.macros + machine.macros {
            for (i, entry) in macro.commands.enumerated() { entries.append(("macro \(macro.number) command \(i + 1)", entry)) }
        }
        for (i, key) in machine.keys.enumerated() { entries.append(("key binding \(i + 1)", GuardedCommand(key.command))) }
        XCTAssertGreaterThan(entries.count, 25)
        for (location, entry) in entries {
            guard let text = CommandText.print(entry) else { return XCTFail("\(location): no text") }
            guard let again = parsed(text) else { continue }
            XCTAssertEqual(again.command, entry.command, "\(location): \(text)")
            XCTAssertEqual(again.when, entry.when, "\(location): \(text)")
        }
    }
}
