import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 11 §13, "Area 10, the text editor" — "the sheet view (G-50) laying the
/// same document out as one field, with each cue's number at its first line,
/// a dashed line under every cue, an empty cue as a blank line, a blank line
/// before each new section and other content grayed, a selection across cues
/// copying and refusing an edit over a dashed line, Backspace and forward
/// Delete at one merging, and typing, a split and a moved line sending what
/// the chunked document sends." The window on no screen, over the engine's
/// recorded answers.
@MainActor
final class SheetViewTests: XCTestCase {
    typealias Rig = DropsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private let c = ["11aa0000-0000-4000-8000-000000000001", "22bb0000-0000-4000-8000-000000000002",
                     "33cc0000-0000-4000-8000-000000000003", "44dd0000-0000-4000-8000-000000000004"]
    private let made = UUID(uuidString: "eeee0040-0000-4000-8000-000000000000") ?? UUID()

    /// A rig with the Text page open on list 42, the Sheet toggle switched on as the operator would.
    private func sheeted() throws -> Rig {
        let rig = try Rig()
        rig.view.enterEdit()
        rig.model.editing.show(page: .text)
        redraw(rig)
        rig.view.workspace.sheetToggle.performClick(nil)
        redraw(rig)
        return rig
    }

    private func redraw(_ rig: Rig) {
        rig.view.refresh([.edit, .top])
        rig.view.layoutSubtreeIfNeeded()
    }

    private func sheet(_ rig: Rig) -> SheetTextView { rig.view.workspace.text.sheet }
    private func last(_ rig: Rig) -> [String]? { rig.commands.last { !$0.isEmpty } }
    private func count(_ rig: Rig) -> Int { rig.commands.filter { !$0.isEmpty }.count }
    private func length(_ text: String) -> Int { (text as NSString).length }

    private func focus(_ rig: Rig, at location: Int) {
        let view = sheet(rig)
        XCTAssertTrue(rig.window.window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: location, length: 0))
    }

    private func type(_ rig: Rig, _ text: String) {
        sheet(rig).insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func vary(_ rig: Rig, _ change: (inout List) -> Void) throws {
        var answer = try ShowWindowTests.Rig.load("list-42")
        var list = try XCTUnwrap(ListDocument(answer: answer)).list
        change(&list)
        answer["list"] = try JSONCoding.encode(list)
        rig.store.apply(list: answer)
        redraw(rig)
    }

    private func write(_ cue: String, _ body: String, riders: Riders = .none, _ attributes: [Command] = []) throws -> String {
        let command = Command.edit(EditCommand(.cue(list: 42, cue: try XCTUnwrap(UUID(uuidString: cue))),
                                               .cueChannel(CueChannelEdit(channel: 2, state: .write(.text(fields: ["body": body]), riders), attributes: attributes))))
        return try XCTUnwrap(CommandText.print(command))
    }

    private func remove(_ cue: String) throws -> String {
        try XCTUnwrap(CommandText.print(.edit(EditCommand(.cue(list: 42, cue: try XCTUnwrap(UUID(uuidString: cue))), .remove(path: nil, at: nil)))))
    }

    private var whole: String {
        "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee\n"
            + "Thou changest not,\nThy compassions, they fail not\nGreat is Thy faithfulness!\nGreat is Thy faithfulness!"
    }

    // MARK: - The layout (Spec 11 §5, "The sheet view")

    func test_theSheetShowsTheDocumentAsOneField() throws {
        let rig = try sheeted()
        XCTAssertTrue(rig.model.settings.textSheet, "the toggle, kept in view.json")
        XCTAssertEqual(rig.view.workspace.sheetToggle.state, .on)
        XCTAssertTrue(rig.view.workspace.text.scroll.isHidden, "the chunked document gives way")
        XCTAssertFalse(rig.view.workspace.text.sheetScroll.isHidden)
        let view = sheet(rig)
        XCTAssertEqual(view.string, whole, "each cue's lines one after another, as a printed lyric sheet reads")
        XCTAssertEqual(view.sheet.segments.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(view.sheet.segments.map(\.section), ["Verse 1", nil, nil, "Chorus"])
        // "a faint dashed line under each cue": under each cue's last line, above the next cue's first.
        for index in 0..<3 {
            let rule = try XCTUnwrap(view.ruleY(after: index))
            XCTAssertGreaterThan(rule, view.lineRect(at: view.sheet.segments[index].end - 1).maxY - 0.5)
            XCTAssertLessThan(rule, view.lineRect(at: view.sheet.segments[index + 1].location).maxY)
        }
        // "with a blank line before each new section": the chorus starts a line further down than a cue in the verse.
        let inVerse = view.lineRect(at: view.sheet.segments[2].location).minY - view.lineRect(at: view.sheet.segments[1].end - 1).maxY
        let atChorus = view.lineRect(at: view.sheet.segments[3].location).minY - view.lineRect(at: view.sheet.segments[2].end - 1).maxY
        XCTAssertGreaterThan(atChorus, inVerse + SheetTextView.lineHeight - 1)
        // Off again: the chunked document.
        rig.view.workspace.sheetToggle.performClick(nil)
        redraw(rig)
        XCTAssertFalse(rig.model.settings.textSheet)
        XCTAssertFalse(rig.view.workspace.text.scroll.isHidden)
    }

    func test_anEmptyCueIsABlankLineAndTypingIntoItWritesWhatWasTyped() throws {
        let rig = try sheeted()
        try vary(rig) { list in
            list.cues[2].commands.removeAll { $0.command.namedChannel == 2 }
            list.cues[2].commands.append(GuardedCommand(.channelClear(channel: .number(2))))
        }
        let view = sheet(rig)
        XCTAssertEqual(view.string, "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee\n\n"
                       + "Great is Thy faithfulness!\nGreat is Thy faithfulness!", "cue 3 clears: a blank line with its number")
        XCTAssertNotNil(view.ruleY(after: 2), "a dashed line under the empty cue too")
        focus(rig, at: view.sheet.segments[2].location)
        type(rig, "Thou changest not")
        XCTAssertEqual(last(rig), [try write(c[2], "Thou changest not")])
    }

    // MARK: - Typing (Spec 11 §5)

    func test_typingInTheSheetSendsThatCuesWholeBody() throws {
        let rig = try sheeted()
        let view = sheet(rig)
        focus(rig, at: view.sheet.segments[1].end)
        XCTAssertEqual(rig.model.editing.text.caret, c[1])
        XCTAssertEqual(rig.view.topBar.fieldHint, "Editing text: ⌥Return splits · Esc leaves")
        type(rig, "!")
        XCTAssertEqual(last(rig), [try write(c[1], "There is no shadow\nof turning with Thee!")])
        XCTAssertEqual(view.sheet.segments[2].location, view.sheet.segments[1].end + 1, "the cues after it move along")
        // At the start of the next cue's first line: that cue's.
        rig.clock.advance(by: 1)
        focus(rig, at: view.sheet.segments[2].location)
        XCTAssertEqual(rig.model.editing.text.caret, c[2])
        type(rig, "O ")
        XCTAssertEqual(last(rig), [try write(c[2], "O Thou changest not,\nThy compassions, they fail not")])
        // Return makes a line within the cue.
        rig.clock.advance(by: 1)
        view.insertNewline(nil)
        XCTAssertEqual(last(rig), [try write(c[2], "O \nThou changest not,\nThy compassions, they fail not")])
        XCTAssertEqual(view.sheet.segments.count, 4)
    }

    func test_aSelectionAcrossCuesCopiesAndRefusesAnyEdit() throws {
        let rig = try sheeted()
        let view = sheet(rig)
        view.pasteboard = NSPasteboard(name: NSPasteboard.Name("o-sheet-test-\(UUID().uuidString)"))
        XCTAssertTrue(rig.window.window.makeFirstResponder(view))
        let start = length("Great is Thy faithfulness,\n")
        view.setSelectedRange(NSRange(location: start, length: 43 + 18 - start))
        view.copy(nil)
        XCTAssertEqual(view.pasteboard.string(forType: .string), "O God my Father\n\nThere is no shadow", "a blank line where it crosses a cue")
        // "typing, Delete, Cut or Paste over a selection that crosses a cue's dashed line does nothing and says "Select within one cue.""
        type(rig, "x")
        view.deleteBackward(nil)
        XCTAssertEqual(count(rig), 0)
        XCTAssertEqual(view.string, whole)
        redraw(rig)
        XCTAssertEqual(rig.view.workspace.notice.stringValue, "Select within one cue.")
        // "A ⌘A selects the whole field at once, for Copy only."
        view.selectAll(nil)
        view.copy(nil)
        XCTAssertEqual(view.pasteboard.string(forType: .string), rig.model.editing.text.documentText())
        type(rig, "x")
        XCTAssertEqual(count(rig), 0)
    }

    // MARK: - Breaks (Spec 11 §5)

    func test_backspaceAndForwardDeleteAtADashedLineMerge() throws {
        let rig = try sheeted()
        let view = sheet(rig)
        focus(rig, at: view.sheet.segments[1].location)
        view.lastKeyWasRepeat = true
        view.deleteBackward(nil)
        XCTAssertEqual(count(rig), 0, "a held key stops at the dashed line")
        view.lastKeyWasRepeat = false
        view.deleteBackward(nil)
        let joined = "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee"
        XCTAssertEqual(last(rig), [try write(c[0], joined), try remove(c[1])])
        XCTAssertEqual(view.sheet.segments.map(\.cue), [c[0], c[2], c[3]])
        XCTAssertEqual(view.selectedRange().location, length("Great is Thy faithfulness,\nO God my Father\n"), "the caret where the texts meet")
        XCTAssertEqual(view.string, whole, "the field reads the same; one dashed line fewer")
        // Forward Delete at the end of the joined cue: cue 3 joins, after the window asks (its trigger and advance-after).
        view.setSelectedRange(NSRange(location: view.sheet.segments[0].end, length: 0))
        view.deleteForward(nil)
        XCTAssertEqual(rig.asked, [.mergeCues(MergeQuestion(cue: 2, into: 1, reasons: [.trigger, .advanceAfter]))])
        XCTAssertEqual(last(rig), [try write(c[0], joined + "\nThou changest not,\nThy compassions, they fail not"), try remove(c[2])])
    }

    func test_optionReturnSplitsAndTheCaretGoesOnInTheNewCue() throws {
        let rig = try sheeted()
        rig.model.editing.makeUuid = { [made] in made }
        let view = sheet(rig)
        focus(rig, at: view.sheet.segments[1].location + length("There is no shadow\n"))
        view.insertNewlineIgnoringFieldEditor(nil)
        let cue = Cue(uuid: made, label: "Verse 1", section: "Verse 1",
                      commands: [GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2), content: .text(fields: ["body": "of turning with Thee"]))))])
        XCTAssertEqual(last(rig), [try write(c[1], "There is no shadow"), try XCTUnwrap(CommandText.print(TextEdits.insert(cue, at: 2, list: 42)))])
        XCTAssertEqual(view.sheet.segments.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(view.sheet.segments[2].cue, made.uuidString.lowercased())
        XCTAssertEqual(view.selectedRange().location, view.sheet.segments[2].location, "at the start of the new cue's line")
        XCTAssertTrue(rig.window.window.firstResponder === view)
        XCTAssertEqual(view.string, whole, "the same words, a dashed line more")
    }

    func test_aDashedLineDragsToMoveLines() throws {
        let rig = try sheeted()
        let view = sheet(rig)
        let window = rig.window.window
        func event(_ type: NSEvent.EventType, _ at: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(at, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let rule = try XCTUnwrap(view.ruleY(after: 0))
        let x = SheetTextView.margin + 40
        // Down past cue 2's first line: it goes up to cue 1.
        let target = view.lineRect(at: view.sheet.segments[1].location).maxY + 3
        view.mouseDown(with: try event(.leftMouseDown, NSPoint(x: x, y: rule)))
        view.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: x, y: target)))
        XCTAssertEqual(view.dragging?.lines, 1)
        XCTAssertNotNil(view.dropY, "the drop line shows where it lands")
        view.mouseUp(with: try event(.leftMouseUp, NSPoint(x: x, y: target)))
        XCTAssertNil(view.dropY)
        XCTAssertEqual(last(rig), [try write(c[1], "of turning with Thee"), try write(c[0], "Great is Thy faithfulness,\nO God my Father\nThere is no shadow")])
        // ⌥⌘↓ from the Edit menu's helper, with the caret on cue 1's last line: it goes back down.
        focus(rig, at: view.sheet.segments[0].end - 2)
        XCTAssertTrue(rig.view.workspace.text.canMoveLineAtCaret(previous: false))
        rig.view.workspace.text.moveLineAtCaret(previous: false)
        XCTAssertEqual(last(rig), [try write(c[0], "Great is Thy faithfulness,\nO God my Father"),
                                   try write(c[1], "There is no shadow\nof turning with Thee")])
    }

    // MARK: - The look, for review

    func test_theSheetDrawsIntoAPicture() throws {
        let rig = try sheeted()
        try vary(rig) { list in
            list.cues.insert(Cue(uuid: UUID(uuidString: "eeee0041-0000-4000-8000-000000000000") ?? UUID(), label: "Verse 1", section: "Verse 1",
                                 commands: [GuardedCommand(.channelClear(channel: .number(2)))]), at: 3)
            list.cues.append(Cue(uuid: UUID(uuidString: "eeee0042-0000-4000-8000-000000000000") ?? UUID(), label: "Chorus", section: "Chorus",
                                 commands: [GuardedCommand(.channelWrite(ChannelWrite(channel: .number(2),
                                                                                      content: .text(fields: ["body": "Morning by morning\nnew mercies I see"]))))]))
        }
        focus(rig, at: sheet(rig).sheet.segments[1].end)
        redraw(rig)
        let view = rig.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        if let folder = ProcessInfo.processInfo.environment["O_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-text-sheet.png"))
        }
    }
}
