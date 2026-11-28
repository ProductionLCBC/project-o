import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 11 §13, "Area 10, the text editor" — the Text page in the window, on
/// no screen, over the engine's recorded answers: the document beside its
/// fields column with no inspector (G-46), each chunk's number, section,
/// text, placeholder and row, typing through the text view, the arrows from
/// chunk to chunk, a selection that never crosses a break, the second ⌘A
/// that copies only, the fields column's edits, and a read-only list.
@MainActor
final class TextPageViewTests: XCTestCase {
    typealias Rig = DropsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private let c = ["11aa0000-0000-4000-8000-000000000001", "22bb0000-0000-4000-8000-000000000002",
                     "33cc0000-0000-4000-8000-000000000003", "44dd0000-0000-4000-8000-000000000004"]

    /// A rig with edit mode open on the Text page, on the live list, list 42 in the playlist Sunday.
    private func editing() throws -> Rig {
        let rig = try Rig()
        rig.view.enterEdit()
        rig.model.editing.show(page: .text)
        redraw(rig)
        return rig
    }

    /// Edit mode's regions drawn again, as the window does after a change of the model's.
    private func redraw(_ rig: Rig) {
        rig.view.refresh([.edit, .top])
        rig.view.layoutSubtreeIfNeeded()
    }

    private func page(_ rig: Rig) -> TextWorkspaceView { rig.view.workspace.text }
    private func chunks(_ rig: Rig) -> [ChunkView] { page(rig).document.chunkViews }
    private func last(_ rig: Rig) -> [String]? { rig.commands.last { !$0.isEmpty } }
    private func count(_ rig: Rig) -> Int { rig.commands.filter { !$0.isEmpty }.count }

    /// Puts the caret in a chunk, at its end, as a click would.
    private func focus(_ rig: Rig, _ chunk: ChunkView) {
        XCTAssertTrue(rig.window.window.makeFirstResponder(chunk.text))
        chunk.text.placeCaret(at: (chunk.text.string as NSString).length)
    }

    private func type(_ chunk: ChunkView, _ text: String) {
        chunk.text.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: - Fixtures, as the store would hold them after an edit elsewhere

    static let dawn = "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527"

    private func vary(_ rig: Rig, _ name: String, _ change: (inout List) -> Void) throws {
        var answer = try ShowWindowTests.Rig.load(name)
        var list = try XCTUnwrap(ListDocument(answer: answer)).list
        change(&list)
        answer["list"] = try JSONCoding.encode(list)
        rig.store.apply(list: answer)
    }

    nonisolated static func hold(_ list: inout List, cue index: Int, channel: Int) {
        list.cues[index].commands.removeAll { command in
            switch command.command {
            case .channelWrite(let write): return write.channel == .number(channel)
            case .channelClear(let target): return target == .number(channel)
            default: return false
            }
        }
    }

    nonisolated static func cue(_ n: Int, _ label: String, _ commands: [Command] = []) -> Cue {
        Cue(uuid: UUID(uuidString: String(format: "eeee%04d-0000-4000-8000-000000000000", n)) ?? UUID(), label: label,
            commands: commands.map { GuardedCommand($0) })
    }

    nonisolated static func write(_ channel: Int, _ content: ContentExpression) -> Command {
        .channelWrite(ChannelWrite(channel: .number(channel), content: content))
    }

    nonisolated static func text(_ body: String) -> ContentExpression { .text(fields: ["body": body]) }

    private func cueChannel(_ cue: String, _ state: CueChannelState, _ attributes: [Command] = []) throws -> String {
        let command = Command.edit(EditCommand(.cue(list: 42, cue: try XCTUnwrap(UUID(uuidString: cue))),
                                               .cueChannel(CueChannelEdit(channel: 2, state: state, attributes: attributes))))
        return try XCTUnwrap(CommandText.print(command))
    }

    // MARK: - The page (Spec 11 §2, §5 and G-46)

    func test_theTextPageLaysOutTheDocumentBesideItsFieldsWithNoInspector() throws {
        let rig = try editing()
        XCTAssertEqual(rig.model.editing.page, .text)
        XCTAssertTrue(rig.view.inspector.isHidden, "the Text page has no inspector (G-46)")
        XCTAssertEqual(rig.view.workspace.frame, NSRect(x: 268, y: 48, width: 804, height: 848), "so the document runs the full height")
        XCTAssertFalse(rig.view.browser.isHidden, "the Cues and Text pages keep the Browser")
        let page = page(rig)
        XCTAssertFalse(page.isHidden)
        XCTAssertTrue(rig.view.workspace.grid.isHidden)
        XCTAssertEqual(page.column.scroll.frame.width, TextWorkspaceView.columnWidth, "a tall column at the workspace's right")
        XCTAssertEqual(page.column.scroll.frame.height, page.bounds.height)
        XCTAssertEqual(rig.view.workspace.title.stringValue, "Great Is Thy Faithfulness")
        XCTAssertEqual(rig.view.workspace.meta.stringValue, "4 cues · version 17")
        // "The header's channel picker lists the channels, those whose `usualContent` is text first."
        let picker = rig.view.workspace.channelPicker
        XCTAssertFalse(picker.isHidden)
        XCTAssertEqual(picker.itemTitles, ["Channel 2 · Foreground", "Channel 1 · Background", "Channel 3 · Clock"])
        XCTAssertEqual(picker.selectedItem?.tag, 2)
        // A chunk per cue: the rule with its number, the section at each run's first chunk, the body, the live dot.
        let views = chunks(rig)
        XCTAssertEqual(views.map(\.cue), c)
        XCTAssertEqual(views.map(\.rule.number.stringValue), ["1", "2", "3", "4"])
        XCTAssertEqual(views.map(\.margin.isHidden), [false, true, true, false])
        XCTAssertEqual(views[0].margin.stringValue, "Verse 1")
        XCTAssertEqual(views[3].margin.stringValue, "Chorus")
        XCTAssertEqual(views[1].text.string, "There is no shadow\nof turning with Thee")
        XCTAssertEqual(views.map(\.rule.dot.isHidden), [false, true, true, true], "the live cue's rule carries the live dot")
        XCTAssertEqual(views[1].text.accessibilityLabel(), "Cue 2, Verse 1")
        XCTAssertEqual(views[0].text.accessibilityLabel(), "Cue 1, Verse 1, live")
        // Every chunk below the one before it, each as tall as its thumbnail at least.
        for (above, below) in zip(views, views.dropFirst()) { XCTAssertEqual(below.frame.minY, above.frame.maxY) }
        XCTAssertTrue(views.allSatisfy { $0.frame.height >= ChunkView.ruleHeight + ChunkView.thumbnailHeight })
        // The fields column: the list's fields.
        XCTAssertEqual(page.titleField.stringValue, "Great Is Thy Faithfulness")
        XCTAssertEqual(page.authorField.stringValue, "Thomas Chisholm")
        XCTAssertEqual(page.copyrightField.stringValue, "Public domain")
        XCTAssertEqual(page.ccliField.stringValue, "18723")
        XCTAssertEqual(page.trackThrough.state, .off)
    }

    func test_holdsAndClearsShowTheirPlaceholdersAndOtherContentARow() throws {
        let rig = try editing()
        try vary(rig, "list-42") { list in
            Self.hold(&list, cue: 0, channel: 2)
            Self.hold(&list, cue: 2, channel: 2)
            Self.hold(&list, cue: 3, channel: 2)
            list.cues[3].commands.append(GuardedCommand(Self.write(2, .media(MediaContent(ref: Self.dawn)))))
            list.cues.append(Self.cue(6, "Out", [.channelClear(channel: .number(2))]))
        }
        redraw(rig)
        let views = chunks(rig)
        XCTAssertEqual(views.count, 5)
        XCTAssertEqual(views[0].placeholder.stringValue, "Holds nothing")
        XCTAssertFalse(views[0].placeholder.isHidden)
        // Held text: the line, grayed.
        XCTAssertEqual(views[2].text.string, "There is no shadow\nof turning with Thee")
        XCTAssertEqual(views[2].text.textColor, Palette.faintText)
        XCTAssertTrue(views[2].placeholder.isHidden)
        // Other content: a row naming it, not editable.
        XCTAssertTrue(views[3].text.isHidden)
        XCTAssertFalse(views[3].row.isHidden)
        XCTAssertEqual(views[3].row.stringValue, "Video: dawn.mp4", "the item as the pool names it")
        XCTAssertEqual(views[4].placeholder.stringValue, "Clears")
    }

    // MARK: - Typing (Spec 11 §5)

    func test_typingInAChunkSendsItsWholeBodyAndTheTopBarSaysWhatItsKeysDo() throws {
        let rig = try editing()
        let views = chunks(rig)
        focus(rig, views[1])
        XCTAssertEqual(rig.model.editing.text.caret, c[1])
        XCTAssertEqual(rig.view.topBar.fieldHint, "Editing text: ⌥Return splits · Esc leaves")
        XCTAssertEqual(rig.model.editing.selection.lead, c[1], "the caret's cue is the page's selection, which the Preview shows")
        type(views[1], "!")
        XCTAssertEqual(last(rig), [try cueChannel(c[1], .write(Self.text("There is no shadow\nof turning with Thee!"), .none))])
        // The held line typed into turns to the chunk's own text, no longer grayed.
        try vary(rig, "list-42") { Self.hold(&$0, cue: 2, channel: 2) }
        redraw(rig)
        let held = chunks(rig)[2]
        XCTAssertEqual(held.text.textColor, Palette.faintText)
        focus(rig, held)
        rig.clock.advance(by: 1)
        type(held, "!")
        redraw(rig)
        XCTAssertEqual(held.text.textColor, Palette.text)
        XCTAssertEqual(last(rig), [try cueChannel(c[2], .write(Self.text("There is no shadow\nof turning with Thee!"), .none))])
    }

    func test_theArrowsCrossFromOneChunkToTheNextAndEscapeLeavesTheEditor() throws {
        let rig = try editing()
        let views = chunks(rig)
        focus(rig, views[0])
        // At the end of the first chunk's last line, ↓ goes into the second chunk's first line.
        views[0].text.moveDown(nil)
        XCTAssertTrue(rig.window.window.firstResponder === views[1].text)
        XCTAssertEqual(rig.model.editing.text.caret, c[1])
        // → at the very end goes to the next chunk's start; ← at the start back to the end of the one before.
        views[1].text.placeCaret(at: (views[1].text.string as NSString).length)
        views[1].text.moveRight(nil)
        XCTAssertTrue(rig.window.window.firstResponder === views[2].text)
        XCTAssertEqual(views[2].text.selectedRange().location, 0)
        views[2].text.moveLeft(nil)
        XCTAssertTrue(rig.window.window.firstResponder === views[1].text)
        XCTAssertEqual(views[1].text.selectedRange().location, (views[1].text.string as NSString).length)
        // "Escape leaves the editor and keeps what was typed".
        type(views[1], "?")
        views[1].text.cancelOperation(nil)
        XCTAssertFalse(rig.window.window.firstResponder === views[1].text)
        XCTAssertNil(rig.model.editing.text.caret)
        XCTAssertEqual(views[1].text.string, "There is no shadow\nof turning with Thee?")
    }

    // MARK: - Selection (Spec 11 §5)

    func test_aSecondCommandASelectsTheWholeDocumentForCopyOnly() throws {
        let rig = try editing()
        let page = page(rig)
        page.document.pasteboard = NSPasteboard(name: NSPasteboard.Name("o-text-test-\(UUID().uuidString)"))
        let views = chunks(rig)
        focus(rig, views[1])
        views[1].text.selectAll(nil)
        XCTAssertFalse(page.document.isDocumentSelected, "the first ⌘A selects the chunk")
        XCTAssertEqual(views[1].text.selectedRange(), NSRange(location: 0, length: (views[1].text.string as NSString).length))
        views[1].text.selectAll(nil)
        XCTAssertTrue(page.document.isDocumentSelected, "a second ⌘A selects the whole document")
        XCTAssertTrue(views.allSatisfy(\.isHighlighted))
        views[1].text.copy(nil)
        XCTAssertEqual(page.document.pasteboard.string(forType: .string),
                       "Verse 1\nGreat is Thy faithfulness,\nO God my Father\n\nThere is no shadow\nof turning with Thee\n\n"
                       + "Thou changest not,\nThy compassions, they fail not\n\nChorus\nGreat is Thy faithfulness!\nGreat is Thy faithfulness!")
        // "Typing, Delete, Cut or Paste over a selection that crosses a break does nothing and says "Select within one cue.""
        let sent = count(rig)
        type(views[1], "x")
        views[1].text.deleteBackward(nil)
        views[1].text.cut(nil)
        XCTAssertEqual(count(rig), sent)
        XCTAssertEqual(views[1].text.string, "There is no shadow\nof turning with Thee")
        redraw(rig)
        XCTAssertEqual(rig.view.workspace.notice.stringValue, "Select within one cue.")
        XCTAssertEqual(rig.view.spoken.last, "Select within one cue.", "announced where it shows (Spec 11 §10)")
        XCTAssertFalse(rig.view.workspace.notice.isHidden)
        // Moving the caret ends it.
        views[1].text.placeCaret(at: 0)
        views[1].text.moveRight(nil)
        XCTAssertFalse(page.document.isDocumentSelected)
        rig.clock.advance(by: 3.1)
        redraw(rig)
        XCTAssertTrue(rig.view.workspace.notice.isHidden, "said for three seconds")
    }

    // MARK: - The fields column (Spec 11 §5, G-46)

    func test_theFieldsColumnEditsTheListAndTheCaretsCue() throws {
        let rig = try editing()
        let page = page(rig)
        page.titleField.stringValue = "Great Is Thy Faithfulness (Runyan)"
        page.titleField.sendAction(page.titleField.action, to: page.titleField.target)
        XCTAssertEqual(last(rig), ["edit list 42 title \"Great Is Thy Faithfulness (Runyan)\""])
        page.trackThrough.performClick(nil)
        XCTAssertEqual(last(rig), ["edit list 42 trackThrough true"])
        // The caret's cue: its label, its section and Hold.
        focus(rig, chunks(rig)[3])
        redraw(rig)
        XCTAssertEqual(page.cueHeading.accessibilityLabel(), "Cue 4")
        XCTAssertEqual(page.labelField.stringValue, "Chorus")
        page.labelField.stringValue = "Refrain"
        page.labelField.sendAction(page.labelField.action, to: page.labelField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[3]) label \"Refrain\""])
        page.hold.press()
        XCTAssertEqual(last(rig), [try cueChannel(c[3], .hold, [.channelGrade(channel: .number(2), ref: 1, ms: 2000)])],
                       "Hold returns the channel to hold on that cue, keeping `track` riders")
        // A section set carries on to the cues after it that shared the old one, as the Cues page has it.
        focus(rig, chunks(rig)[1])
        redraw(rig)
        page.sectionField.stringValue = "Verse 2"
        page.sectionField.sendAction(page.sectionField.action, to: page.sectionField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[1]) section \"Verse 2\"", "edit list 42 cue \(c[2]) section \"Verse 2\""])
    }

    // MARK: - Breaks (Spec 11 §5)

    private let made = UUID(uuidString: "eeee0030-0000-4000-8000-000000000000") ?? UUID()

    private func insert(_ cue: Cue, at: Int) throws -> String {
        try XCTUnwrap(CommandText.print(TextEdits.insert(cue, at: at, list: 42)))
    }

    private func remove(_ cue: String) throws -> String {
        try XCTUnwrap(CommandText.print(.edit(EditCommand(.cue(list: 42, cue: try XCTUnwrap(UUID(uuidString: cue))), .remove(path: nil, at: nil)))))
    }

    /// A press on a cue's rule, a drag to a point of the document, and a release, as the pointer would make them.
    private func drag(_ rig: Rig, rule: BreakView, to point: NSPoint, release: Bool = true) throws {
        let window = rig.window.window
        func event(_ type: NSEvent.EventType, _ at: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let start = rule.convert(NSPoint(x: rule.ruleX + 40, y: rule.bounds.midY), to: nil)
        let end = page(rig).document.convert(point, to: nil)
        rule.mouseDown(with: try event(.leftMouseDown, start))
        rule.mouseDragged(with: try event(.leftMouseDragged, end))
        if release { rule.mouseUp(with: try event(.leftMouseUp, end)) }
    }

    /// The middle of a line of a chunk's text, in the document's coordinates.
    private func line(_ chunk: ChunkView, at index: Int, in rig: Rig) -> NSPoint {
        let rect = chunk.text.lineRect(at: index)
        let origin = chunk.text.textContainerOrigin
        return page(rig).document.convert(NSPoint(x: rect.midX + origin.x, y: rect.midY + origin.y), from: chunk.text)
    }

    func test_optionReturnSplitsAndTheCaretGoesOnInTheNewChunk() throws {
        let rig = try editing()
        rig.model.editing.makeUuid = { [made] in made }
        let views = chunks(rig)
        focus(rig, views[1])
        views[1].text.placeCaret(at: ("There is no shadow\n" as NSString).length)
        views[1].text.insertNewlineIgnoringFieldEditor(nil)
        let cue = Cue(uuid: made, label: "Verse 1", section: "Verse 1", commands: [GuardedCommand(Self.write(2, Self.text("of turning with Thee")))])
        XCTAssertEqual(last(rig), [try cueChannel(c[1], .write(Self.text("There is no shadow"), .none)), try insert(cue, at: 2)])
        // "the caret goes on": a new chunk, between cue 2 and cue 3, with the focus at its start.
        let after = chunks(rig)
        XCTAssertEqual(after.map(\.cue), [c[0], c[1], made.uuidString.lowercased(), c[2], c[3]])
        XCTAssertTrue(rig.window.window.firstResponder === after[2].text)
        XCTAssertEqual(after[2].text.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertEqual(after[1].text.string, "There is no shadow")
        XCTAssertEqual(after[2].rule.number.stringValue, "3")
        XCTAssertEqual(rig.view.spoken.last, "New cue 3 after cue 2")
        redraw(rig)
        XCTAssertEqual(rig.view.workspace.meta.stringValue, "5 cues · version 17", "the header counts the cue split off before the list comes back")
        XCTAssertEqual(page(rig).cueHeading.accessibilityLabel(), "Cue 3", "the column names the new cue")
        // Typing goes on in the new cue.
        rig.clock.advance(by: 1)
        type(after[2], "!")
        XCTAssertEqual(last(rig), [try cueChannel(made.uuidString.lowercased(), .write(Self.text("!of turning with Thee"), .none))])
    }

    func test_backspaceAtTheStartAndDeleteAtTheEndMergeOnAFreshPressOnly() throws {
        let rig = try editing()
        var views = chunks(rig)
        focus(rig, views[1])
        views[1].text.placeCaret(at: 0)
        // "A merge takes a fresh press: a held key stops at the chunk's edge."
        views[1].text.lastKeyWasRepeat = true
        views[1].text.deleteBackward(nil)
        XCTAssertEqual(count(rig), 0)
        views[1].text.lastKeyWasRepeat = false
        views[1].text.deleteBackward(nil)
        let joined = "Great is Thy faithfulness,\nO God my Father\nThere is no shadow\nof turning with Thee"
        XCTAssertEqual(last(rig), [try cueChannel(c[0], .write(Self.text(joined), .none)), try remove(c[1])])
        views = chunks(rig)
        XCTAssertEqual(views.map(\.cue), [c[0], c[2], c[3]])
        XCTAssertTrue(rig.window.window.firstResponder === views[0].text, "the caret goes to the chunk the text joined")
        XCTAssertEqual(views[0].text.selectedRange().location, ("Great is Thy faithfulness,\nO God my Father\n" as NSString).length)
        XCTAssertEqual(rig.view.spoken.last, "Cue 2 joined to cue 1")
        // Forward Delete at the end of a chunk joins the one below: cue 3, which asks first (its trigger and advance-after).
        views[0].text.placeCaret(at: (joined as NSString).length)
        views[0].text.deleteForward(nil)
        XCTAssertEqual(rig.asked, [.mergeCues(MergeQuestion(cue: 2, into: 1, reasons: [.trigger, .advanceAfter]))],
                       "the window asks, and the rig answers Merge")
        XCTAssertEqual(last(rig), [try cueChannel(c[0], .write(Self.text(joined + "\nThou changest not,\nThy compassions, they fail not"), .none)), try remove(c[2])])
        // In the middle of a chunk, Backspace deletes a character as ever.
        views = chunks(rig)
        views[0].text.placeCaret(at: 5)
        views[0].text.deleteBackward(nil)
        XCTAssertTrue(views[0].text.string.hasPrefix("Grea is"))
    }

    func test_aBreakDragsToALineBoundaryShowingWhereItLands() throws {
        let rig = try editing()
        var views = chunks(rig)
        XCTAssertFalse(views[0].rule.isDraggable, "the first chunk's rule isn't a break")
        XCTAssertTrue(views[1].rule.isDraggable)
        // Down past cue 2's first line: that line goes up to cue 1. While dragged, the drop line shows where.
        let below = line(views[1], at: 0, in: rig)
        try drag(rig, rule: views[1].rule, to: NSPoint(x: below.x, y: below.y + 12), release: false)
        let document = page(rig).document
        XCTAssertEqual(document.dragging?.lines, 1)
        XCTAssertFalse(document.dropLine.isHidden)
        try drag(rig, rule: views[1].rule, to: NSPoint(x: below.x, y: below.y + 12))
        XCTAssertTrue(document.dropLine.isHidden)
        XCTAssertEqual(last(rig), [try cueChannel(c[1], .write(Self.text("of turning with Thee"), .none)),
                                   try cueChannel(c[0], .write(Self.text("Great is Thy faithfulness,\nO God my Father\nThere is no shadow"), .none))])
        // Up into cue 3's chunk above cue 4: cue 3's last line goes down to the chorus.
        views = chunks(rig)
        let above = line(views[2], at: ("Thou changest not,\n" as NSString).length, in: rig)
        try drag(rig, rule: views[3].rule, to: NSPoint(x: above.x, y: above.y - 2))
        XCTAssertEqual(last(rig), [try cueChannel(c[2], .write(Self.text("Thou changest not,"), .none)),
                                   try cueChannel(c[3], .write(Self.text("Thy compassions, they fail not\nGreat is Thy faithfulness!\nGreat is Thy faithfulness!"),
                                                               Riders(audioTransition: TransitionRider(ref: 2, scope: .once), grade: GradeRider(ref: 1, ms: 2000, scope: .track))))])
        // Let go where it started: nothing moves.
        let sent = count(rig)
        views = chunks(rig)
        try drag(rig, rule: views[1].rule, to: NSPoint(x: below.x, y: views[1].frame.minY + ChunkView.ruleHeight / 2 + 1))
        XCTAssertEqual(count(rig), sent)
    }

    func test_moveLineToPreviousAndNextCueFromTheEditMenu() throws {
        let rig = try editing()
        let views = chunks(rig)
        let document = page(rig).document
        focus(rig, views[1])
        views[1].text.placeCaret(at: 4)
        XCTAssertTrue(document.canMoveLineAtCaret(previous: true))
        XCTAssertFalse(document.canMoveLineAtCaret(previous: false), "the caret isn't on the last line")
        document.moveLineAtCaret(previous: true)
        XCTAssertEqual(last(rig), [try cueChannel(c[1], .write(Self.text("of turning with Thee"), .none)),
                                   try cueChannel(c[0], .write(Self.text("Great is Thy faithfulness,\nO God my Father\nThere is no shadow"), .none))])
        // The caret follows its line into cue 1, on its last line.
        let after = chunks(rig)
        XCTAssertTrue(rig.window.window.firstResponder === after[0].text)
        XCTAssertEqual(after[0].text.selectedRange().location, ("Great is Thy faithfulness,\nO God my Father\n" as NSString).length + 4)
        // And back down: it is cue 1's last line now.
        XCTAssertTrue(document.canMoveLineAtCaret(previous: false))
        document.moveLineAtCaret(previous: false)
        XCTAssertEqual(last(rig), [try cueChannel(c[0], .write(Self.text("Great is Thy faithfulness,\nO God my Father"), .none)),
                                   try cueChannel(c[1], .write(Self.text("There is no shadow\nof turning with Thee"), .none))])
        XCTAssertTrue(rig.window.window.firstResponder === chunks(rig)[1].text)
        XCTAssertEqual(chunks(rig)[1].text.selectedRange().location, 4)
        // With no chunk focused there is nothing to move.
        rig.window.window.makeFirstResponder(nil)
        XCTAssertFalse(document.canMoveLineAtCaret(previous: true))
    }

    /// For review: the page after a split, and while a break is dragged.
    func test_theBreaksDrawIntoPictures() throws {
        let rig = try editing()
        rig.model.editing.makeUuid = { [made] in made }
        func picture(_ name: String) throws {
            redraw(rig)
            let view = rig.view
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 20_000)
            if let folder = ProcessInfo.processInfo.environment["O_RENDER_DIR"] {
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-text-\(name).png"))
            }
        }
        let views = chunks(rig)
        focus(rig, views[1])
        views[1].text.placeCaret(at: ("There is no shadow\n" as NSString).length)
        try picture("before-split")
        views[1].text.insertNewlineIgnoringFieldEditor(nil)
        try picture("after-split")
        let after = chunks(rig)
        let below = line(after[3], at: 0, in: rig)
        try drag(rig, rule: after[3].rule, to: NSPoint(x: below.x, y: below.y + 12), release: false)
        try picture("drag")
    }

    // MARK: - Other clients (Spec 11 §5)

    func test_aCueRemovedElsewhereKeepsItsTextWithAddAsNewCueAndCopy() throws {
        let rig = try editing()
        let page = page(rig)
        page.document.pasteboard = NSPasteboard(name: NSPasteboard.Name("o-text-test-\(UUID().uuidString)"))
        let views = chunks(rig)
        focus(rig, views[2])
        type(views[2], "!")
        rig.store.apply(event: "library", ["topic": .string("library"), "rev": .number(7), "cause": .string("edit"), "group": .string("g-lan"),
                                           "source": .object(["kind": .string("api")]),
                                           "changed": .array([.object(["object": .string("list"), "list": .number(42), "listUuid": .string("a9f00000-0000-4000-8000-00000000002a"),
                                                                       "paths": .array([.string("cues")])])])], now: rig.clock.now)
        try vary(rig, "list-42") { $0.cues.remove(at: 2) }
        redraw(rig)
        let ghost = try XCTUnwrap(chunks(rig).first { $0.cue == c[2] })
        XCTAssertEqual(chunks(rig).map(\.cue), [c[0], c[1], c[2], c[3]], "its text stays where it stood")
        XCTAssertEqual(ghost.text.string, "Thou changest not,\nThy compassions, they fail not!")
        XCTAssertEqual(ghost.tags.stringValue, "Cue removed")
        XCTAssertFalse(ghost.add.isHidden)
        XCTAssertFalse(ghost.copy.isHidden)
        let sent = count(rig)
        ghost.copy.press()
        XCTAssertEqual(page.document.pasteboard.string(forType: .string), "Thou changest not,\nThy compassions, they fail not!")
        XCTAssertEqual(count(rig), sent, "Copy sends nothing")
        redraw(rig)
        XCTAssertEqual(chunks(rig).map(\.cue), [c[0], c[1], c[3]])
    }

    // MARK: - Read-only (Spec 11 §5, "Other clients")

    func test_aLocalCopyOpensReadOnlyWithItsReason() throws {
        let rig = try editing()
        rig.model.editing.choose(list: "10ca1000-0000-4000-8000-00000000002a", from: .playlist("b1a70000-0000-4000-8000-000000000001"), item: nil)
        redraw(rig)
        XCTAssertTrue(rig.view.workspace.meta.stringValue.hasSuffix("Local copies are edited from v1.5"), rig.view.workspace.meta.stringValue)
        XCTAssertTrue(chunks(rig).allSatisfy { !$0.text.isEditable }, "a local copy opens read-only")
        XCTAssertFalse(page(rig).titleField.isEditable)
        XCTAssertFalse(page(rig).hold.isEnabled)
    }

    // MARK: - The look, for review (Spec 11 §5)

    func test_theTextPageDrawsIntoAPicture() throws {
        let rig = try editing()
        try vary(rig, "list-42") { list in
            Self.hold(&list, cue: 2, channel: 2)
            list.cues.append(Self.cue(5, "Out", [.channelClear(channel: .number(2))]))
        }
        redraw(rig)
        focus(rig, chunks(rig)[1])
        redraw(rig)
        let view = rig.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000)
        if let folder = ProcessInfo.processInfo.environment["O_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-text.png"))
        }
    }
}
