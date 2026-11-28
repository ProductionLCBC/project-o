import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — breaks: "⌥Return splits in the
/// middle and at the end, the new write keeping the other fields and none of
/// the riders ...; a merge both ways on a fresh press only, asking when the
/// second cue does more or is the live or the armed cue; a moved break, by a
/// drag and by Move Line to Previous Cue and Next Cue; holds and clears joining
/// as empty text, and nothing reaching other content". Each is one group (Spec
/// 5 §5). The model over a store fed the engine's recorded answers; the fresh
/// press and the drag are the view's (TextPageViewTests).
@MainActor
final class TextBreakTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private let c = Recorded.cues42
    private let made = UUID(uuidString: "eeee0010-0000-4000-8000-000000000000") ?? UUID()
    private var madeName: String { made.uuidString.lowercased() }
    private let dox = ["55ee0000-0000-4000-8000-000000000001", "66ff0000-0000-4000-8000-000000000002", "77aa0000-0000-4000-8000-000000000003"]

    /// What the editor said to VoiceOver, where the caret went, and what the window was asked.
    private final class Heard {
        var said: [String] = []
        var carets: [(String, Int)] = []
        var asked: [Confirmation] = []
        var answer = true
    }

    private func editing(_ list: String = Recorded.list42) throws -> (Rig, TextEditor, Heard) {
        let rig = try Rig()
        XCTAssertTrue(rig.model.editing.open(page: .text))
        if list != Recorded.list42 { rig.model.editing.choose(list: list, from: .list(list), item: nil) }
        let heard = Heard()
        let text = rig.model.editing.text
        text.onSay = { heard.said.append($0) }
        text.onCaret = { heard.carets.append(($0, $1)) }
        rig.model.confirm = { confirmation, reply in
            heard.asked.append(confirmation)
            reply(heard.answer)
        }
        rig.model.editing.makeUuid = { [made] in made }
        return (rig, text, heard)
    }

    private func length(_ text: String) -> Int { (text as NSString).length }

    private func uuid(_ text: String) throws -> UUID { try XCTUnwrap(UUID(uuidString: text)) }

    private func write(_ list: Int, _ cue: String, _ body: String, _ fields: [String: String] = [:], riders: Riders = .none,
                       _ attributes: [Command] = []) throws -> String {
        try TextTypingTests.cueChannel(list, cue, .write(TextTypingTests.text(body, fields), riders), attributes)
    }

    private func insert(_ cue: Cue, at: Int, list: Int = 42) throws -> String {
        try XCTUnwrap(CommandText.print(TextEdits.insert(cue, at: at, list: list)))
    }

    private func remove(_ cue: String, list: Int = 42) throws -> String {
        try XCTUnwrap(CommandText.print(.edit(EditCommand(.cue(list: list, cue: try uuid(cue)), .remove(path: nil, at: nil)))))
    }

    private func newCue(label: String, section: String?, _ commands: [Command]) -> Cue {
        Cue(uuid: made, label: label, section: section, commands: commands.map { GuardedCommand($0) })
    }

    private let chorusRiders = Riders(audioTransition: TransitionRider(ref: 2, scope: .once), grade: GradeRider(ref: 1, ms: 2000, scope: .track))

    // MARK: - Split (Spec 11 §5)

    func test_aSplitInTheMiddleKeepsTheTextAboveAndANewCueTakesTheTextBelow() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[1])
        text.split(at: length("There is no shadow\n"))
        let cue = newCue(label: "Verse 1", section: "Verse 1", [TextDocumentTests.write(2, TextTypingTests.text("of turning with Thee"))])
        XCTAssertEqual(rig.commands.last, [try write(42, c[1], "There is no shadow"), try insert(cue, at: 2)],
                       "one group: edit.cueChannel, then edit.insert with a uuid the app makes, the label and section copied")
        XCTAssertEqual(rig.sent.last?.type, "commands")
        XCTAssertEqual(rig.sent.last?.fields["group"], .bool(true))
        // The caret goes on at the start of the new cue's chunk, which shows before the engine answers.
        XCTAssertEqual(text.caret, madeName)
        XCTAssertEqual(text.caretText, "of turning with Thee")
        XCTAssertEqual(heard.carets.last?.0, madeName)
        XCTAssertEqual(heard.carets.last?.1, 0)
        XCTAssertEqual(text.document.chunks.map(\.cue), [c[0], c[1], madeName, c[2], c[3]])
        XCTAssertEqual(text.document.chunks[1].text, "There is no shadow")
        XCTAssertEqual(text.document.chunks.map(\.number), [1, 2, 3, 4, 5])
        // Spec 11 §10 — "a split ... says what it did ("New cue 5 after cue 4")".
        XCTAssertEqual(heard.said.last, "New cue 3 after cue 2")
        // Typing goes on in the new cue.
        rig.clock.advance(by: 1)
        text.typed("of turning with Thee!", composing: false)
        XCTAssertEqual(rig.commands.last, [try write(42, madeName, "of turning with Thee!")])
    }

    func test_theNewWriteKeepsTheOtherFieldsAndNoneOfTheRiders() throws {
        let (rig, text, _) = try editing()
        // The chorus rides in with `audiotransition 2 once` and `grade 1 2.0 track`; channel 1's gain is the cue's too.
        text.enter(c[3])
        text.split(at: length("Great is Thy faithfulness!\n"))
        let cue = newCue(label: "Chorus", section: "Chorus", [TextDocumentTests.write(2, TextTypingTests.text("Great is Thy faithfulness!"))])
        XCTAssertEqual(rig.commands.last, [try write(42, c[3], "Great is Thy faithfulness!", riders: chorusRiders), try insert(cue, at: 4)],
                       "the text above keeps the write's riders; the new write has none of them")
        // Doxology's first write carries a title: the new write takes it.
        let (dox7, doxText, _) = try editing(Recorded.list7)
        doxText.enter(dox[0])
        doxText.split(at: length("Praise God, from whom all blessings flow;\n"))
        let titled = Cue(uuid: made, label: "Verse", section: "Verse",
                         commands: [GuardedCommand(TextDocumentTests.write(2, TextTypingTests.text("Praise Him, all creatures here below;", ["title": "Doxology"])))])
        XCTAssertEqual(dox7.commands.last, [try write(7, dox[0], "Praise God, from whom all blessings flow;", ["title": "Doxology"]),
                                             try insert(titled, at: 1, list: 7)])
    }

    func test_aSplitAtTheEndInsertsAClearAndOneAtTheStartClearsTheCue() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[1])
        text.split(at: length("There is no shadow\nof turning with Thee"))
        let empty = newCue(label: "Verse 1", section: "Verse 1", [.channelClear(channel: .number(2))])
        XCTAssertEqual(rig.commands.last, [try insert(empty, at: 2)],
                       "at the end of a chunk the new cue's chunk is empty, which is a clear until something is typed into it")
        XCTAssertEqual(text.document.chunk(madeName)?.kind, .clear)
        XCTAssertEqual(text.caretText, "")
        XCTAssertEqual(heard.carets.last?.1, 0)
        // At the start of a chunk: the cue is left empty, so it clears, its tracked grade kept as a standalone write.
        let (start, startText, _) = try editing()
        startText.enter(c[3])
        startText.split(at: 0)
        let all = newCue(label: "Chorus", section: "Chorus", [TextDocumentTests.write(2, TextTypingTests.text("Great is Thy faithfulness!\nGreat is Thy faithfulness!"))])
        XCTAssertEqual(start.commands.last, [try TextTypingTests.cueChannel(42, c[3], .clear, [.channelGrade(channel: .number(2), ref: 1, ms: 2000)]),
                                             try insert(all, at: 4)])
    }

    func test_aSplitTakesTheTypingNotSentYet() throws {
        let (rig, text, _) = try editing()
        text.enter(c[1])
        text.typed("There is no shadow\nof turning with Thee,", composing: false)
        rig.clock.advance(by: 0.05)
        text.typed("There is no shadow\nof turning with Thee, so true", composing: false)
        XCTAssertEqual(text.unsent, "There is no shadow\nof turning with Thee, so true", "inside the quarter second")
        text.split(at: length("There is no shadow\n"))
        let cue = newCue(label: "Verse 1", section: "Verse 1", [TextDocumentTests.write(2, TextTypingTests.text("of turning with Thee, so true"))])
        XCTAssertEqual(rig.commands.last, [try write(42, c[1], "There is no shadow"), try insert(cue, at: 2)])
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.commands.last, [try write(42, c[1], "There is no shadow"), try insert(cue, at: 2)], "the waiting text went with the split")
    }

    func test_splittingAClearInsertsAClearedCueAfterIt() throws {
        let (rig, text, _) = try editing(Recorded.list7)
        text.enter(dox[2])
        text.split(at: 0)
        let empty = newCue(label: "Out", section: "Out", [.channelClear(channel: .number(2))])
        XCTAssertEqual(rig.commands.last, [try insert(empty, at: 3, list: 7)], "the clear itself is left as it is")
    }

    // MARK: - Merge (Spec 11 §5)

    private var joined12: String { "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee" }

    func test_backspaceAtTheStartOfAChunkJoinsItToTheChunkAbove() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[1])
        text.mergeUp()
        XCTAssertTrue(heard.asked.isEmpty, "cue 2 does nothing beyond its text")
        XCTAssertEqual(rig.commands.last, [try write(42, c[0], joined12), try remove(c[1])], "one group, edit.cueChannel then edit.remove")
        XCTAssertEqual(text.caret, c[0])
        XCTAssertEqual(text.caretText, joined12)
        XCTAssertEqual(heard.carets.last?.1, length("Great is Thy faithfulness,\nO God my Father\n"), "the caret where the texts meet")
        XCTAssertEqual(text.document.chunks.map(\.cue), [c[0], c[2], c[3]])
        XCTAssertNil(text.removed, "the editor's own merge removed cue 2: no \"Cue removed\" chunk")
        XCTAssertEqual(heard.said.last, "Cue 2 joined to cue 1")
    }

    func test_forwardDeleteAtTheEndOfAChunkJoinsTheChunkBelowToIt() throws {
        let (rig, text, _) = try editing()
        text.enter(c[0])
        text.mergeDown()
        XCTAssertEqual(rig.commands.last, [try write(42, c[0], joined12), try remove(c[1])])
        XCTAssertEqual(text.caret, c[0])
    }

    func test_aMergeAsksWhenTheSecondCueDoesMoreAndMergeIsNeverDone() throws {
        let (rig, text, heard) = try editing()
        // Cue 3 fires 8 s after cue 2 and advances after 12 s.
        text.enter(c[2])
        heard.answer = false
        text.mergeUp()
        XCTAssertEqual(heard.asked, [.mergeCues(MergeQuestion(cue: 3, into: 2, reasons: [.trigger, .advanceAfter]))])
        XCTAssertTrue(rig.sent.isEmpty, "Cancel merges nothing")
        heard.answer = true
        text.mergeUp()
        XCTAssertEqual(rig.commands.last, [try write(42, c[1], "There is no shadow\nof turning with Thee\nThou changest not,\nThy compassions, they fail not"),
                                           try remove(c[2])])
        // The chorus: its gain on channel 1, its riders on channel 2, its note.
        let (chorusRig, chorus, chorusHeard) = try editing()
        chorus.enter(c[3])
        chorus.mergeUp()
        XCTAssertEqual(chorusHeard.asked, [.mergeCues(MergeQuestion(cue: 4, into: 3, reasons: [.writes([1]), .changes(channel: 2), .note]))])
        // Doxology's last cue: a slide on channel 1, macro 1, an advance-after.
        let (outRig, out, outHeard) = try editing(Recorded.list7)
        out.enter(dox[2])
        out.mergeUp()
        XCTAssertEqual(outHeard.asked, [.mergeCues(MergeQuestion(cue: 3, into: 2, reasons: [.writes([1]), .runs([1]), .advanceAfter]))])
        withExtendedLifetime((chorusRig, outRig)) {}
    }

    func test_aMergeAsksWhenTheSecondCueIsTheLiveOrTheArmedCue() throws {
        let (rig, text, heard) = try editing()
        try rig.live { event in
            event["cue"] = .string(self.c[1])
            event["position"] = .object(["cue": .number(2), "item": .number(2)])
            event["armed"] = .object(["cue": .string(self.c[3]), "inMs": .number(8000), "item": .string("ae3aafe3-4744-5aa5-ab4a-37d19b07310e"),
                                      "position": .object(["cue": .number(4), "item": .number(2)])])
        }
        heard.answer = false
        text.enter(c[1])
        text.mergeUp()
        text.enter(c[3])
        text.mergeUp()
        XCTAssertEqual(heard.asked, [.mergeCues(MergeQuestion(cue: 2, into: 1, reasons: [.live])),
                                     .mergeCues(MergeQuestion(cue: 4, into: 3, reasons: [.armed, .writes([1]), .changes(channel: 2), .note]))])
    }

    func test_theMergeQuestionInWords() throws {
        try CatalogFile.install()
        let us = Locale(identifier: "en_US")
        let words = EditWording.words(.mergeCues(MergeQuestion(cue: 5, into: 4, reasons: [.writes([1]), .runs([3])])), locale: us)
        XCTAssertEqual(words.title, "Merge cue 5 into cue 4?")
        XCTAssertEqual(words.body, ["Cue 5 also writes channel 1 and runs macro 3.", "Merging removes them."], "Spec 11 §5's own example")
        XCTAssertEqual(words.button, "Merge")
        let armed = EditWording.words(.mergeCues(MergeQuestion(cue: 4, into: 3, reasons: [.armed, .writes([1, 3]), .changes(channel: 2), .otherCommands(2), .note])),
                                      locale: us)
        XCTAssertEqual(armed.body, ["Cue 4 is armed to fire next.",
                                    "Cue 4 also writes channels 1 and 3, changes how channel 2 plays, has 2 other commands, and has a note.",
                                    "Merging removes them."])
        let live = EditWording.words(.mergeCues(MergeQuestion(cue: 2, into: 1, reasons: [.live])), locale: us)
        XCTAssertEqual(live.body, ["Cue 2 is the live cue.", "Merging removes it."])
        let timed = EditWording.words(.mergeCues(MergeQuestion(cue: 3, into: 2, reasons: [.trigger, .advanceAfter])), locale: us)
        XCTAssertEqual(timed.body, ["Cue 3 also has a trigger of its own and advances to the next cue by itself.", "Merging removes them."])
    }

    // MARK: - What joins (Spec 11 §5)

    func test_holdsAndClearsJoinAsEmptyText() throws {
        // Doxology's cue 3 clears channel 2: joined to cue 2, the text above doesn't change, so only the remove goes.
        let (dox7, doxText, _) = try editing(Recorded.list7)
        doxText.enter(dox[1])
        doxText.mergeDown()
        XCTAssertEqual(dox7.commands.last, [try remove(dox[2], list: 7)])
        // Text joined into a cue that clears makes it a write, with the other fields of the write the text came from.
        let (rig, text, _) = try editing()
        try TextTypingTests.vary(rig, "list-42") { list in
            TextDocumentTests.hold(&list, cue: 0, channel: 2)
            list.cues[0].commands.append(GuardedCommand(.channelClear(channel: .number(2))))
        }
        XCTAssertEqual(text.document.chunks[0].kind, .clear)
        text.enter(c[1])
        text.mergeUp()
        XCTAssertEqual(rig.commands.last, [try write(42, c[0], "There is no shadow\nof turning with Thee"), try remove(c[1])])
        // A hold below joins as empty text too.
        let (held, heldText, heldHeard) = try editing()
        try TextTypingTests.vary(held, "list-42") { TextDocumentTests.hold(&$0, cue: 2, channel: 2) }
        heldText.enter(c[1])
        heldText.mergeDown()
        XCTAssertEqual(heldHeard.asked.count, 1, "cue 3 still has its trigger and its advance-after")
        XCTAssertEqual(held.commands.last, [try remove(c[2])])
    }

    func test_nothingReachesIntoARowOfOtherContent() throws {
        let (rig, text, heard) = try editing()
        try TextTypingTests.vary(rig, "list-42") { list in
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
            list.cues[1].commands.append(GuardedCommand(TextDocumentTests.write(2, .media(MediaContent(ref: TextDocumentTests.dawn)))))
        }
        text.enter(c[2])
        text.mergeUp()
        text.enter(c[0])
        text.mergeDown()
        XCTAssertTrue(rig.sent.isEmpty, "Backspace at the start of a chunk under such a row does nothing")
        XCTAssertTrue(heard.asked.isEmpty)
        XCTAssertEqual(text.breakRange(above: c[1]), 0...0)
        XCTAssertEqual(text.breakRange(above: c[2]), 0...0)
    }

    // MARK: - Moving a break (Spec 11 §5, G-48)

    func test_moveLineToPreviousCueMovesTheFirstLineUpAndTheCaretFollowsIt() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[1])
        XCTAssertTrue(text.canMoveLine(previous: true, at: 3))
        XCTAssertFalse(text.canMoveLine(previous: true, at: length("There is no shadow\nof")), "not with the caret on another line")
        XCTAssertFalse(text.canMoveLine(previous: false, at: 3), "the last line moves to the next cue")
        text.moveLine(previous: true, at: 3)
        XCTAssertEqual(rig.commands.last, [try write(42, c[1], "of turning with Thee"),
                                           try write(42, c[0], "Great is Thy faithfulness,\nO God my Father\nThere is no shadow")],
                       "one group of two edit.cueChannel edits")
        XCTAssertEqual(text.caret, c[0])
        XCTAssertEqual(heard.carets.last?.1, length("Great is Thy faithfulness,\nO God my Father\n") + 3)
        XCTAssertEqual(heard.said.last, "Moved 1 line to cue 1")
    }

    func test_moveLineToNextCueMovesTheLastLineDown() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[0])
        let at = length("Great is Thy faithfulness,\nO ")
        XCTAssertTrue(text.canMoveLine(previous: false, at: at))
        text.moveLine(previous: false, at: at)
        XCTAssertEqual(rig.commands.last, [try write(42, c[0], "Great is Thy faithfulness,"),
                                           try write(42, c[1], "O God my Father\nThere is no shadow\nof turning with Thee")])
        XCTAssertEqual(text.caret, c[1])
        XCTAssertEqual(heard.carets.last?.1, 2)
        XCTAssertEqual(heard.said.last, "Moved 1 line to cue 2")
    }

    func test_aBreakNeverPassesAChunksLastLine() throws {
        let (rig, text, _) = try editing()
        try TextTypingTests.vary(rig, "list-42") { list in
            guard case .channelWrite(var write) = list.cues[1].commands[0].command else { return }
            write.content = TextTypingTests.text("There is no shadow")
            list.cues[1].commands[0] = GuardedCommand(.channelWrite(write))
        }
        text.enter(c[1])
        XCTAssertFalse(text.canMoveLine(previous: true, at: 0))
        text.moveLine(previous: true, at: 0)
        text.moveBreak(above: c[1], by: 1)
        XCTAssertTrue(rig.sent.isEmpty)
        XCTAssertEqual(text.breakRange(above: c[1]), -1...0, "cue 1 has two lines to give, cue 2 one to keep")
        XCTAssertEqual(text.breakRange(above: c[0]), 0...0, "the first chunk's rule isn't a break")
    }

    func test_aDraggedBreakMovesSeveralLinesAndIntoAClearMakesAWrite() throws {
        let (rig, text, heard) = try editing()
        try TextTypingTests.vary(rig, "list-42") { list in
            guard case .channelWrite(var write) = list.cues[0].commands[1].command else { return }
            write.content = TextTypingTests.text("Great is Thy faithfulness,\nO God my Father\nThere is no shadow")
            list.cues[0].commands[1] = GuardedCommand(.channelWrite(write))
        }
        XCTAssertEqual(text.breakRange(above: c[1]), -2...1)
        text.moveBreak(above: c[1], by: -2)
        XCTAssertEqual(rig.commands.last, [try write(42, c[0], "Great is Thy faithfulness,"),
                                           try write(42, c[1], "O God my Father\nThere is no shadow\nThere is no shadow\nof turning with Thee")])
        XCTAssertEqual(heard.said.last, "Moved 2 lines to cue 2")
        // Into a clear: Doxology's cue 2 cleared; cue 1's last line moves in, with the title of the write it came from.
        let (dox7, doxText, _) = try editing(Recorded.list7)
        try TextTypingTests.vary(dox7, "list-7") { list in
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
            list.cues[1].commands.append(GuardedCommand(.channelClear(channel: .number(2))))
        }
        doxText.moveBreak(above: dox[1], by: -1)
        XCTAssertEqual(dox7.commands.last, [try write(7, dox[0], "Praise God, from whom all blessings flow;", ["title": "Doxology"]),
                                            try write(7, dox[1], "Praise Him, all creatures here below;", ["title": "Doxology"])])
    }

    // MARK: - What the engine answers

    func test_aRefusedSplitTakesTheNewChunkAwayAndPutsTheCaretBack() throws {
        let (rig, text, heard) = try editing()
        text.enter(c[1])
        text.split(at: length("There is no shadow\n"))
        XCTAssertEqual(text.caret, madeName)
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "conflict", message: "no"))))
        XCTAssertEqual(text.document.chunks.map(\.cue), c, "the page shows the list as the engine has it")
        XCTAssertEqual(text.caret, c[1])
        XCTAssertEqual(text.caretText, "There is no shadow\nof turning with Thee")
        XCTAssertEqual(heard.carets.last?.0, c[1])
        XCTAssertEqual(rig.model.editing.notice, .rejected(EngineRejection(code: "conflict", message: "no")))
    }

    func test_theSplitShowsUntilTheEnginesListComesBack() throws {
        let (rig, text, _) = try editing()
        text.enter(c[1])
        text.split(at: length("There is no shadow\n"))
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .ok, group: "g-split")))
        XCTAssertEqual(text.document.chunks.count, 5, "applied, and the list not back yet")
        XCTAssertTrue(text.ownGroups.contains("g-split"))
        // The list comes back with the split in it.
        let cue = newCue(label: "Verse 1", section: "Verse 1", [TextDocumentTests.write(2, TextTypingTests.text("of turning with Thee"))])
        try TextTypingTests.vary(rig, "list-42") { list in
            guard case .channelWrite(var write) = list.cues[1].commands[0].command else { return }
            write.content = TextTypingTests.text("There is no shadow")
            list.cues[1].commands[0] = GuardedCommand(.channelWrite(write))
            list.cues.insert(cue, at: 2)
        }
        XCTAssertEqual(text.document.chunks.map(\.cue), [c[0], c[1], madeName, c[2], c[3]])
        // Another station took it away again: the page follows the engine's list.
        try TextTypingTests.vary(rig, "list-42") { _ in }
        XCTAssertEqual(text.document.chunks.map(\.cue), c)
    }

    func test_aListThatCantBeEditedSplitsNothing() throws {
        let (rig, text, _) = try editing(Recorded.localCopy)
        let first = try XCTUnwrap(text.document.chunks.first)
        text.enter(first.cue)
        text.split(at: 0)
        text.mergeDown()
        XCTAssertTrue(rig.sent.isEmpty)
        XCTAssertEqual(rig.model.editing.notice, .notSent(.localCopy))
    }
}
