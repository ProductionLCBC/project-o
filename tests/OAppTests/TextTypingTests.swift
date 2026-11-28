import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — typing: "typing sends whole
/// bodies with the cue's latest riders, at most four times a second and once
/// on leaving ...; composing text isn't sent; an empty chunk sends a clear on
/// leaving, keeping `track` riders, and never an empty write; typing into
/// held text copies the held write; while an output shows a box at +1 to +3,
/// the three chunks after the live cue send only on leaving, the next song's
/// first chunks among them when the live cue is near a song's end, and while
/// none does they send while typing". The model over a store fed the engine's
/// recorded answers, on the app's manual clock.
@MainActor
final class TextTypingTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    /// A rig with the Text page open on what show mode had in hand: list 42, from Sunday, which is live on its first cue.
    private func editing() throws -> (Rig, TextEditor) {
        let rig = try Rig()
        XCTAssertTrue(rig.model.editing.open(page: .text))
        XCTAssertEqual(rig.model.editing.page, .text)
        return (rig, rig.model.editing.text)
    }

    /// A recorded list changed, as the store would hold it after an edit elsewhere.
    static func vary(_ rig: Rig, _ name: String, _ change: (inout List) -> Void) throws {
        var answer = try RecordedAPI.load(name)
        var list = try XCTUnwrap(ListDocument(answer: answer)).list
        change(&list)
        answer["list"] = try JSONCoding.encode(list)
        rig.store.apply(list: answer)
    }

    static func uuid(_ text: String) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: text))
    }

    /// What a channel edit of a cue of list `list` reads as, in canonical text: the expectation is written as the
    /// command, so it says what is sent and not how the printer spaces it.
    static func cueChannel(_ list: Int, _ cue: String, channel: Int = 2, _ state: CueChannelState, _ attributes: [Command] = []) throws -> String {
        let command = Command.edit(EditCommand(.cue(list: list, cue: try uuid(cue)),
                                               .cueChannel(CueChannelEdit(channel: channel, state: state, attributes: attributes))))
        return try XCTUnwrap(CommandText.print(command))
    }

    static func text(_ body: String, _ fields: [String: String] = [:]) -> ContentExpression {
        var fields = fields
        fields["body"] = body
        return .text(fields: fields)
    }

    // MARK: - Whole bodies (Spec 11 §5, "Typing")

    func test_typingSendsTheWholeBodyWithTheCuesLatestRiders() throws {
        let (rig, text) = try editing()
        XCTAssertEqual(text.document.chunks.count, 4)
        // The chorus writes its text with `audiotransition 2 once` and `grade 1 2.0 track`, and gains channel 1 by -6.
        text.enter(Recorded.cues42[3])
        XCTAssertEqual(text.caretText, "Great is Thy faithfulness!\nGreat is Thy faithfulness!")
        let body = "Great is Thy faithfulness!\nGreat is Thy faithfulness!\nMorning by morning"
        text.typed(body, composing: false)
        let riders = Riders(audioTransition: TransitionRider(ref: 2, scope: .once), grade: GradeRider(ref: 1, ms: 2000, scope: .track))
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[3], .write(Self.text(body), riders))],
                       "one edit.cueChannel for that cue and channel: the whole body, its riders kept, channel 1 untouched")
        XCTAssertEqual(rig.sent.last?.fields["source"], .string("ui"))
        XCTAssertEqual(rig.sent.last?.type, "command", "typing is one edit, never a group")
        // Doxology's first cue writes a title as well: "its other fields" go with the body.
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        text.enter("55ee0000-0000-4000-8000-000000000001")
        rig.clock.advance(by: 1)
        text.typed("Praise God, from whom all blessings flow!", composing: false)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(7, "55ee0000-0000-4000-8000-000000000001",
                                                               .write(Self.text("Praise God, from whom all blessings flow!", ["title": "Doxology"]), .none))])
    }

    func test_atMostFourSendsASecondAndOneWhenTheCaretLeaves() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[1])
        var body = "There is no shadow\nof turning with Thee"
        // A keystroke every twentieth of a second for a second and a half.
        for _ in 0..<30 {
            body += "!"
            text.typed(body, composing: false)
            rig.clock.advance(by: 0.05)
        }
        let sends = rig.commands.count
        XCTAssertGreaterThanOrEqual(sends, 6)
        XCTAssertLessThanOrEqual(sends, 7, "the first at once, then one each quarter second")
        // In no second were there more than four.
        XCTAssertEqual(rig.sent.count, rig.commands.count)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[1], .write(Self.text(body), .none))],
                       "the last keystroke always lands")
        let settled = rig.commands.count
        // One more keystroke and the caret leaves before its quarter is up: it goes at once, and once.
        body += "?"
        text.typed(body, composing: false)
        text.typed(body + "?", composing: false)
        text.enter(Recorded.cues42[2])
        XCTAssertEqual(rig.commands.count, settled + 2, "the first at once, the second as the caret leaves")
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[1], .write(Self.text(body + "?"), .none))])
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.commands.count, settled + 2, "nothing waits after the caret left")
    }

    func test_aChunkTheCaretPassesThroughSendsNothing() throws {
        let (rig, text) = try editing()
        for cue in Recorded.cues42 { text.enter(cue) }
        text.leave()
        rig.clock.advance(by: 2)
        XCTAssertTrue(rig.sent.isEmpty, "a chunk the caret passes through without typing sends nothing")
        // Typing back to what it was sends nothing either.
        text.enter(Recorded.cues42[0])
        text.typed("Great is Thy faithfulness,\nO God my Father", composing: false)
        text.leave()
        XCTAssertTrue(rig.sent.isEmpty)
    }

    func test_composedTextIsntSentUntilItIsEntered() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[1])
        // An accent being composed: "Text still being composed (an accent, dictation) isn't sent until it is entered."
        text.typed("There is no shadow\nof turning with Thee ´", composing: true)
        rig.clock.advance(by: 1)
        XCTAssertTrue(rig.sent.isEmpty)
        text.typed("There is no shadow\nof turning with Thee é", composing: false)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[1], .write(Self.text("There is no shadow\nof turning with Thee é"), .none))])
    }

    // MARK: - An emptied chunk (Spec 11 §5, R5)

    func test_anEmptiedChunkSendsAClearOnLeavingKeepingItsTrackRidersAndNeverAnEmptyWrite() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[3])
        text.typed("Great is Thy faithfulness!", composing: false)
        let sent = rig.commands.count
        rig.clock.advance(by: 1)
        text.typed("", composing: false)
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.commands.count, sent, "never an empty text write")
        text.leave()
        // "keeping the write's `track` riders as standalone attribute writes": the grade tracks on, the once
        // audio transition goes with the write.
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[3], .clear, [.channelGrade(channel: .number(2), ref: 1, ms: 2000)])])
        // A clear that is left empty sends nothing.
        rig.model.editing.choose(list: Recorded.list7, from: .list(Recorded.list7), item: nil)
        let before = rig.sent.count
        text.enter("77aa0000-0000-4000-8000-000000000003")
        text.typed("x", composing: false)
        text.typed("", composing: false)
        text.leave()
        XCTAssertEqual(rig.commands.count, before + 1, "the x went; the clear it went back to is what the cue had")
    }

    // MARK: - Holds (Spec 11 §5, "A chunk shows")

    func test_typingIntoHeldTextCopiesTheHeldWrite() throws {
        let (rig, text) = try editing()
        let riders = Riders(transition: TransitionRider(ref: 2, ms: 500, scope: .once), grade: GradeRider(ref: 1, scope: .track))
        // Cue 2 holds cue 1's text, which rides in with a dissolve for once and a grade from here on.
        try Self.vary(rig, "list-42") { list in
            guard case .channelWrite(var write) = list.cues[0].commands[1].command else { return }
            write.riders = riders
            list.cues[0].commands[1] = GuardedCommand(.channelWrite(write))
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
        }
        XCTAssertEqual(text.document.chunks.map(TextDocumentTests.state)[1], "held text from 1")
        text.enter(Recorded.cues42[1])
        XCTAssertEqual(text.caretText, "Great is Thy faithfulness,\nO God my Father", "the held line, grayed, is where typing starts")
        XCTAssertFalse(text.isTyped(Recorded.cues42[1]))
        text.typed("Great is Thy faithfulness,\nO God my Father!", composing: false)
        XCTAssertTrue(text.isTyped(Recorded.cues42[1]))
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[1], .write(Self.text("Great is Thy faithfulness,\nO God my Father!"), riders))],
                       "a copy of the held write with the typing in its body")
    }

    func test_typingOverHeldMediaOrNothingWritesOnlyWhatWasTyped() throws {
        let (rig, text) = try editing()
        // Cue 1 writes the dawn loop on channel 2 with a dissolve; cue 2 holds it.
        try Self.vary(rig, "list-42") { list in
            TextDocumentTests.hold(&list, cue: 0, channel: 2)
            list.cues[0].commands.append(GuardedCommand(TextDocumentTests.write(2, .media(MediaContent(ref: TextDocumentTests.dawn)),
                                                                                riders: Riders(transition: TransitionRider(ref: 2, scope: .once)))))
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
        }
        XCTAssertEqual(text.document.chunks.prefix(2).map(TextDocumentTests.state), ["other: media dawn", "held media dawn"])
        text.enter(Recorded.cues42[0])
        XCTAssertNil(text.caret, "a row of other content takes no caret")
        text.enter(Recorded.cues42[1])
        XCTAssertEqual(text.caretText, "")
        text.typed("Morning by morning", composing: false)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[1], .write(Self.text("Morning by morning"), .none))],
                       "the write is only what was typed")
        // Holding nothing: the same.
        try Self.vary(rig, "list-42") { list in TextDocumentTests.hold(&list, cue: 0, channel: 2) }
        XCTAssertEqual(text.document.chunks[0].kind, .holdsNothing)
        text.enter(Recorded.cues42[0])
        rig.clock.advance(by: 1)
        text.typed("Great is Thy faithfulness", composing: false)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[0], .write(Self.text("Great is Thy faithfulness"), .none))])
    }

    // MARK: - An empty list (Spec 11 §5)

    func test_theFirstCharacterInAnEmptyListMakesTheFirstCueAndItsWrite() throws {
        let (rig, text) = try editing()
        try Self.vary(rig, "list-42") { $0.cues = [] }
        XCTAssertTrue(text.isEmptyList, "one empty chunk saying \"Type or paste the song's text\"")
        let made = try Self.uuid("eeee0001-0000-4000-8000-000000000000")
        rig.model.editing.makeUuid = { made }
        text.enter(TextEditor.emptyChunk)
        text.typed("G", composing: false)
        let cue = Cue(uuid: made, commands: [GuardedCommand(TextDocumentTests.write(2, Self.text("G")))])
        XCTAssertEqual(rig.commands.last, [try XCTUnwrap(CommandText.print(TextEdits.insert(cue, at: 0, list: 42)))],
                       "the first character creates the first cue and its write as one group")
        XCTAssertEqual(text.caret, made.uuidString.lowercased(), "and typing goes on from there")
        XCTAssertEqual(text.document.chunks.map(\.cue), [made.uuidString.lowercased()], "the new chunk shows before the engine answers")
        rig.clock.advance(by: 1)
        text.typed("Great", composing: false)
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, made.uuidString.lowercased(), .write(Self.text("Great"), .none))])
        // The engine refusing the insert takes the chunk away again.
        try Self.vary(rig, "list-42") { $0.cues = [] }
        rig.answers[rig.answers.count - 2](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "readOnlyLibrary", message: "no"))))
        XCTAssertTrue(text.isEmptyList)
    }

    // MARK: - Near the live cue (Spec 11 §5, choice A-14, G-49)

    /// Puts output 1 on the confidence stack, whose preset draws a body box at +1.
    private func confidence(_ rig: Rig) {
        rig.store.apply(event: "outputs", ["topic": .string("outputs"), "output": .number(1), "stack": .number(2), "state": .string("presenting")],
                        now: rig.clock.now)
    }

    func test_theChunksAfterTheLiveCueHoldBackOnlyWhileAnOutputLooksAhead() throws {
        let (rig, text) = try editing()
        // Sunday is live on list 42's first cue, and no output shows a box ahead: every chunk types as usual.
        XCTAssertEqual(text.document.chunks.map(\.holdsBack), [false, false, false, false])
        XCTAssertEqual(text.document.chunks.map(\.isLive), [true, false, false, false])
        text.enter(Recorded.cues42[1])
        text.typed("There is no shadow", composing: false)
        XCTAssertEqual(rig.commands.count, 1, "while none does they send while typing")
        text.leave()
        confidence(rig)
        XCTAssertEqual(text.document.chunks.map(\.holdsBack), [false, true, true, true], "the three cues after the live cue")
        text.enter(Recorded.cues42[2])
        text.typed("Thou changest not", composing: false)
        rig.clock.advance(by: 2)
        XCTAssertEqual(rig.commands.count, 1, "they send when the caret leaves them, not while typing")
        text.enter(Recorded.cues42[0])
        XCTAssertEqual(rig.commands.last, [try Self.cueChannel(42, Recorded.cues42[2], .write(Self.text("Thou changest not"), .none))])
        // The live cue's own chunk sends as it is typed: it is on air already, and shows its edit at its next fire.
        text.typed("Great is Thy faithfulness", composing: false)
        XCTAssertEqual(rig.commands.count, 3)
    }

    func test_nearASongsEndTheNextSongsFirstChunksHoldBack() throws {
        let (rig, text) = try editing()
        confidence(rig)
        // Sunday Night: header, list 42, list 7, list 42. Live on list 42's last cue: the next three are Doxology's.
        try rig.live { event in
            event["playlist"] = .string(Recorded.sundayNight)
            event["playlistTitle"] = .string("Sunday Night")
            event["item"] = .string("f5ddefa0-c441-5343-9e77-91de5edd9942")
            event["cue"] = .string(Recorded.cues42[3])
            event["label"] = .string("Chorus")
            event["position"] = .object(["cue": .number(4), "item": .number(2)])
        }
        rig.model.editing.choose(list: Recorded.list7, from: .playlist(Recorded.sundayNight), item: nil)
        XCTAssertEqual(text.document.chunks.map(\.holdsBack), [true, true, true])
        // Sunday: list 42, then this Mac's copy of it, two cues, then a header, then Doxology: only its first.
        try rig.live { event in
            event["cue"] = .string(Recorded.cues42[3])
            event["label"] = .string("Chorus")
            event["position"] = .object(["cue": .number(4), "item": .number(2)])
        }
        rig.model.editing.choose(list: Recorded.list7, from: .playlist(Recorded.sunday), item: nil)
        XCTAssertEqual(text.document.chunks.map(\.holdsBack), [true, false, false], "a local copy's cues count as any list's")
    }

    // MARK: - Read-only (Spec 11 §5, "Other clients")

    func test_aReadOnlyListSendsNothingAndSaysWhy() throws {
        let (rig, text) = try editing()
        rig.model.editing.choose(list: Recorded.localCopy, from: .playlist(Recorded.sunday), item: nil)
        XCTAssertEqual(text.cannotEdit, .localCopy)
        let first = try XCTUnwrap(text.document.chunks.first)
        text.enter(first.cue)
        text.typed("Something else", composing: false)
        text.leave()
        XCTAssertTrue(rig.sent.isEmpty, "a local copy opens read-only")
        XCTAssertEqual(rig.model.editing.notice, .notSent(.localCopy))
        // A machine whose masters are read-only.
        var catalog = try RecordedAPI.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        var settings = try XCTUnwrap(machine["settings"]?.objectValue)
        settings["libraryMode"] = .string("readOnlyMasters")
        machine["settings"] = .object(settings)
        catalog["machine"] = .object(machine)
        catalog["rev"] = .number(9)
        rig.store.apply(catalog: catalog)
        rig.model.editing.choose(list: Recorded.list42, from: .playlist(Recorded.sunday), item: nil)
        XCTAssertEqual(text.cannotEdit, .unavailable(.readOnlyMasters))
    }
}
