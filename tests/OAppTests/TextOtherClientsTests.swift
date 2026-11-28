import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — "another client's change
/// patching other chunks, "Changed elsewhere" on the caret's, and "Cue
/// removed" keeping its text". Spec 11 §5, "Other clients": "A `library`
/// event patches the chunks it names, never moving the caret or the scroll.
/// The chunk with the caret keeps its text, takes the rest of its cue from the
/// event, and says "Changed elsewhere" until it next sends."
@MainActor
final class TextOtherClientsTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    private func editing() throws -> (Rig, TextEditor) {
        let rig = try Rig()
        XCTAssertTrue(rig.model.editing.open(page: .text))
        return (rig, rig.model.editing.text)
    }

    private var rev = 4

    /// A `library` event, as the engine sends it after an applied group: its group, its source and what it names.
    private func event(_ rig: Rig, cause: String = "edit", group: String, source: String = "osc", cue: String? = nil, list: Bool = false) {
        rev += 1
        var changed: [JSONValue] = []
        if let cue {
            changed.append(.object(["object": .string("cue"), "list": .number(42), "listUuid": .string(Recorded.list42), "cue": .string(cue),
                                    "paths": .array([.string("commands")])]))
        }
        if list {
            changed.append(.object(["object": .string("list"), "list": .number(42), "listUuid": .string(Recorded.list42), "paths": .array([.string("cues")])]))
        }
        rig.store.apply(event: "library", ["topic": .string("library"), "rev": .number(Double(rev)), "cause": .string(cause), "group": .string(group),
                                           "source": .object(["kind": .string(source)]), "changed": .array(changed)], now: rig.clock.now)
    }

    private func ok(_ rig: Rig, _ index: Int, group: String) {
        rig.answers[index](.result(CommandOutcome(kind: .ok, group: group)))
    }

    private func body(_ list: inout List, cue index: Int, _ body: String) {
        guard let at = list.cues[index].commands.firstIndex(where: { $0.command.namedChannel == 2 }),
              case .channelWrite(var write) = list.cues[index].commands[at].command, case .text(var fields) = write.content else { return }
        fields["body"] = body
        write.content = .text(fields: fields)
        list.cues[index].commands[at] = GuardedCommand(.channelWrite(write))
    }

    func test_anotherClientsChangePatchesTheChunksItNamesAndKeepsTheCaretsText() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[1])
        text.typed("There is no shadow\nof turning with Thee!", composing: false)
        // Another station edits cue 3's text while cue 2 has the caret.
        event(rig, group: "g-lan", source: "api", cue: Recorded.cues42[2])
        try TextTypingTests.vary(rig, "list-42") { self.body(&$0, cue: 2, "Thou changest not,\nThy mercies, they fail not") }
        XCTAssertEqual(text.text(of: Recorded.cues42[2]), "Thou changest not,\nThy mercies, they fail not", "the chunk it names is patched")
        XCTAssertEqual(text.text(of: Recorded.cues42[1]), "There is no shadow\nof turning with Thee!", "the caret's chunk keeps its text")
        XCTAssertEqual(text.caret, Recorded.cues42[1], "never moving the caret")
        XCTAssertFalse(text.changedElsewhere, "the change didn't touch the caret's cue")
    }

    func test_theCaretsChunkSaysChangedElsewhereUntilItNextSends() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[3])
        text.typed("Great is Thy faithfulness!", composing: false)
        ok(rig, 0, group: "g-mine")
        // The editor's own echo: its group, and the list as it sent it.
        event(rig, group: "g-mine", source: "ui", cue: Recorded.cues42[3])
        try TextTypingTests.vary(rig, "list-42") { self.body(&$0, cue: 3, "Great is Thy faithfulness!") }
        XCTAssertFalse(text.changedElsewhere, "its own change is no change from elsewhere")
        // OSC takes the chorus's grade rider away while the caret is there.
        event(rig, group: "g-osc", cue: Recorded.cues42[3])
        try TextTypingTests.vary(rig, "list-42") { list in
            self.body(&list, cue: 3, "Great is Thy faithfulness!")
            guard case .channelWrite(var write) = list.cues[3].commands[0].command else { return }
            write.riders.grade = nil
            list.cues[3].commands[0] = GuardedCommand(.channelWrite(write))
        }
        XCTAssertTrue(text.changedElsewhere)
        XCTAssertEqual(text.caretText, "Great is Thy faithfulness!", "the chunk with the caret keeps its text")
        // The next send takes the rest of its cue from the event: no grade rider any more.
        rig.clock.advance(by: 1)
        text.typed("Great is Thy faithfulness!!", composing: false)
        XCTAssertEqual(rig.commands.last, [try TextTypingTests.cueChannel(42, Recorded.cues42[3],
                                                                          .write(TextTypingTests.text("Great is Thy faithfulness!!"),
                                                                                 Riders(audioTransition: TransitionRider(ref: 2, scope: .once))))])
        XCTAssertFalse(text.changedElsewhere, "until it next sends")
    }

    func test_itsCueRemovedElsewhereKeepsTheTextAsCueRemovedWithAddAsNewCueAndCopy() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[2])
        text.typed("Thou changest not!", composing: false)
        let sent = rig.sent.count
        event(rig, group: "g-lan", source: "api", list: true)
        try TextTypingTests.vary(rig, "list-42") { $0.cues.remove(at: 2) }
        let removed = try XCTUnwrap(text.removed)
        XCTAssertEqual(removed.cue, Recorded.cues42[2])
        XCTAssertEqual(removed.text, "Thou changest not!", "its text stays, marked \"Cue removed\"")
        XCTAssertEqual(removed.index, 2, "where it stood")
        // Typing on in it sends nothing until Add as New Cue or Copy is chosen.
        text.typed("Thou changest not!!", composing: false)
        text.leave()
        rig.clock.advance(by: 1)
        XCTAssertEqual(rig.sent.count, sent, "nothing is sent until one is chosen")
        // Add as New Cue: the text where the cue stood, with its label and section, every other channel held.
        let made = try TextTypingTests.uuid("eeee0002-0000-4000-8000-000000000000")
        rig.model.editing.makeUuid = { made }
        text.addRemovedAsNewCue()
        let cue = Cue(uuid: made, label: "Verse 1", section: "Verse 1",
                      commands: [GuardedCommand(TextDocumentTests.write(2, TextTypingTests.text("Thou changest not!!")))])
        XCTAssertEqual(rig.commands.last, [try XCTUnwrap(CommandText.print(TextEdits.insert(cue, at: 2, list: 42)))])
        XCTAssertNil(text.removed)
        XCTAssertEqual(text.document.chunks.map(\.cue)[2], made.uuidString.lowercased(), "the new chunk stands where the old one did")
    }

    func test_copyTakesTheRemovedChunksTextAndDropsIt() throws {
        let (rig, text) = try editing()
        text.enter(Recorded.cues42[2])
        text.typed("Thou changest not!", composing: false)
        let sent = rig.sent.count
        event(rig, group: "g-lan", source: "api", list: true)
        try TextTypingTests.vary(rig, "list-42") { $0.cues.remove(at: 2) }
        XCTAssertEqual(text.copyRemoved(), "Thou changest not!")
        XCTAssertNil(text.removed)
        XCTAssertEqual(rig.sent.count, sent, "Copy sends nothing")
        XCTAssertEqual(text.document.chunks.count, 3)
    }

    func test_anUndoReplacesTheCaretsChunkKeepingWhereTheCaretWas() throws {
        let (rig, text) = try editing()
        var replaced: [String] = []
        text.onReplaced = { replaced.append($0) }
        text.enter(Recorded.cues42[1])
        text.typed("There is no shadow\nof turning with Thee!", composing: false)
        ok(rig, 0, group: "g-mine")
        // An undo puts the old body back: "An undo or a redo replaces every chunk it names, the caret's included".
        event(rig, cause: "undo", group: "g-undo", source: "restore", cue: Recorded.cues42[1])
        try TextTypingTests.vary(rig, "list-42") { self.body(&$0, cue: 1, "There is no shadow") }
        XCTAssertEqual(text.caretText, "There is no shadow")
        XCTAssertEqual(replaced, ["There is no shadow"])
        XCTAssertEqual(text.caret, Recorded.cues42[1], "the caret stays in its chunk")
    }
}
