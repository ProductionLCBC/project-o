import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 10, the text editor" — "the sheet view (G-50) laying
/// the same document out as one field, with each cue's number at its first
/// line, a dashed line under every cue, an empty cue as a blank line, a blank
/// line before each new section and other content grayed, a selection across
/// cues copying and refusing an edit over a dashed line, Backspace and forward
/// Delete at one merging, and typing, a split and a moved line sending what
/// the chunked document sends."
@MainActor
final class TextSheetTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    private let c = Recorded.cues42

    private func sheet(_ list: ListDocument, empty: String? = nil) throws -> TextSheet {
        let document = TextDocument.make(list: list.list, channel: 2, catalog: try Recorded.catalog(), media: try Recorded.media())
        return TextSheet.make(document: document, text: { $0.text }, row: { "Video: \($0.number)" }, empty: empty)
    }

    private func length(_ text: String) -> Int { (text as NSString).length }

    // MARK: - The layout (Spec 11 §5, "The sheet view")

    func test_theSheetIsEachCuesLinesOneAfterAnother() throws {
        let sheet = try sheet(try Recorded.list("list-42"))
        XCTAssertEqual(sheet.string, "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee\n"
                       + "Thou changest not,\nThy compassions, they fail not\nGreat is Thy faithfulness!\nGreat is Thy faithfulness!")
        XCTAssertEqual(sheet.segments.map(\.cue), c)
        XCTAssertEqual(sheet.segments.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(sheet.segments.map(\.location), [0, 43, 83, 133])
        XCTAssertEqual(sheet.segments[1].range, NSRange(location: 43, length: length("There is no shadow\nof turning with Thee")))
        // "a section's label in the margin at its first cue, with a blank line before each new section".
        XCTAssertEqual(sheet.segments.map(\.section), ["Verse 1", nil, nil, "Chorus"])
        XCTAssertEqual(sheet.segments.map(\.gapBefore), [false, false, false, true])
    }

    func test_anEmptyCueIsABlankLineAndOtherContentAGrayedLine() throws {
        let varied = try TextDocumentTests.list("list-42") { list in
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
            TextDocumentTests.hold(&list, cue: 2, channel: 2)
            list.cues[2].commands.append(GuardedCommand(TextDocumentTests.write(2, .media(MediaContent(ref: TextDocumentTests.dawn)))))
            list.cues.append(TextDocumentTests.cue(5, "Out", [.channelClear(channel: .number(2))]))
        }
        let sheet = try sheet(varied)
        // Cue 2 holds cue 1's text: "a held text shows as a blank line". Cue 3 writes media: a line naming it. Cue 5 clears.
        XCTAssertEqual(sheet.segments.map(\.text), ["Great is Thy faithfulness,\nO God my Father", "", "Video: 3",
                                                    "Great is Thy faithfulness!\nGreat is Thy faithfulness!", ""])
        XCTAssertEqual(sheet.segments.map(\.isEditable), [true, true, false, true, true])
        XCTAssertEqual(sheet.string, "Great is Thy faithfulness,\nO God my Father\n\nVideo: 3\nGreat is Thy faithfulness!\nGreat is Thy faithfulness!\n")
        XCTAssertEqual(sheet.segments[1].range, NSRange(location: 43, length: 0))
    }

    func test_anEmptyListIsOneLine() throws {
        let empty = try sheet(try TextDocumentTests.list("list-42") { $0.cues = [] }, empty: "")
        XCTAssertEqual(empty.segments.map(\.cue), [TextEditor.emptyChunk])
        XCTAssertEqual(empty.string, "")
    }

    // MARK: - Reading an edit (Spec 11 §5, "The sheet view")

    func test_typingWithinOneCueIsThatCuesNewText() throws {
        let sheet = try sheet(try Recorded.list("list-42"))
        // At the end of cue 2's text, before the line break: cue 2's.
        let end = sheet.segments[1].end
        XCTAssertEqual(sheet.index(at: end), 1)
        XCTAssertEqual(sheet.change(in: NSRange(location: end, length: 0), with: "!"),
                       .edit(index: 1, text: "There is no shadow\nof turning with Thee!"))
        // At the start of cue 3's: cue 3's.
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[2].location, length: 0), with: "O "),
                       .edit(index: 2, text: "O Thou changest not,\nThy compassions, they fail not"))
        // Return makes a line within the cue; a word deleted in the middle.
        XCTAssertEqual(sheet.change(in: NSRange(location: 43 + 9, length: 0), with: "\n"),
                       .edit(index: 1, text: "There is \nno shadow\nof turning with Thee"))
        XCTAssertEqual(sheet.change(in: NSRange(location: 43 + 9, length: 3), with: ""),
                       .edit(index: 1, text: "There is shadow\nof turning with Thee"))
    }

    func test_theLineBreakBetweenTwoCuesDeletedAloneMerges() throws {
        let sheet = try sheet(try Recorded.list("list-42"))
        // Backspace at the start of cue 2, or forward Delete at the end of cue 1: the same line break.
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[0].end, length: 1), with: ""), .merge(lower: 1))
        // Typing over it, or a selection across it, is refused.
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[0].end, length: 1), with: "x"), .refused)
        XCTAssertEqual(sheet.change(in: NSRange(location: 30, length: 20), with: ""), .refused)
        XCTAssertEqual(sheet.change(in: NSRange(location: 0, length: length(sheet.string)), with: "x"), .refused)
    }

    func test_otherContentTakesNoEditAndNoMerge() throws {
        let varied = try TextDocumentTests.list("list-42") { list in
            TextDocumentTests.hold(&list, cue: 1, channel: 2)
            list.cues[1].commands.append(GuardedCommand(TextDocumentTests.write(2, .media(MediaContent(ref: TextDocumentTests.dawn)))))
        }
        let sheet = try sheet(varied)
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[1].location + 2, length: 0), with: "x"), .ignored)
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[0].end, length: 1), with: ""), .ignored,
                       "nothing reaches into a row of other content")
        XCTAssertEqual(sheet.change(in: NSRange(location: sheet.segments[1].end, length: 1), with: ""), .ignored)
    }

    func test_anEditMovesTheCuesAfterIt() throws {
        var sheet = try sheet(try Recorded.list("list-42"))
        sheet.apply(index: 1, text: "There is no shadow")
        XCTAssertEqual(sheet.segments.map(\.location), [0, 43, 62, 112])
        XCTAssertEqual(sheet.string.components(separatedBy: "\n")[2], "There is no shadow")
    }

    func test_copyingAcrossCuesLeavesABlankLineAtEachBreak() throws {
        let sheet = try sheet(try Recorded.list("list-42"))
        // From "O God my Father" to "There is no shadow".
        let start = length("Great is Thy faithfulness,\n")
        XCTAssertEqual(sheet.copied(NSRange(location: start, length: 43 + 18 - start)), "O God my Father\n\nThere is no shadow")
        XCTAssertEqual(sheet.copied(NSRange(location: 0, length: 10)), "Great is T")
    }

    // MARK: - Through the editor

    func test_enteringFromTheSheetStartsHeldTextBlank() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.model.editing.open(page: .text))
        let text = rig.model.editing.text
        XCTAssertFalse(text.isSheet, "off when the page first opens")
        text.setSheet(true)
        XCTAssertTrue(text.isSheet)
        XCTAssertTrue(rig.model.settings.textSheet, "kept in view.json")
        try TextTypingTests.vary(rig, "list-42") { TextDocumentTests.hold(&$0, cue: 1, channel: 2) }
        text.enter(c[1], sheet: true)
        XCTAssertEqual(text.caretText, "", "a held text shows as a blank line, so typing into it starts from nothing")
        text.typed("Morning by morning", composing: false)
        XCTAssertEqual(rig.commands.last, [try TextTypingTests.cueChannel(42, c[1], .write(TextTypingTests.text("Morning by morning"), .none))],
                       "a copy of the held write with what was typed as its body")
    }
}
