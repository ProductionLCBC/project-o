import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 10 §5, §6, §10 and §14 — the edits as the window offers them: the
/// menus on real rows and cells, the fields that open in place, the small
/// panels, the sheet of versions, and Undo. Laid out on no screen, over the
/// engine's recorded answers.
@MainActor
final class EditsViewTests: XCTestCase {
    static let sunday = "b1a70000-0000-4000-8000-000000000001"
    static let sundayNight = "b1a70000-0000-4000-8000-000000000010"
    static let list42 = "a9f00000-0000-4000-8000-00000000002a"

    /// A window whose engine's answers the test gives, and whose questions it answers.
    @MainActor
    final class Rig {
        let base: ShowWindowTests.Rig
        var answers: [(Reply?) -> Void] = []
        var asked: [Confirmation] = []
        var says = true
        var view: ShowWindowView { base.view }
        var model: ShowModel { base.model }
        var window: MainWindow { base.window.window }
        var commands: [[String]] { base.commands }
        var sent: [EngineRequest] { base.sent }

        init(size: NSSize = NSSize(width: 1440, height: 900)) throws {
            base = try ShowWindowTests.Rig(size: size)
            base.model.transmit = { [unowned self] request, answer in
                self.base.sent.append(request)
                self.answers.append(answer)
            }
            base.model.confirm = { [unowned self] confirmation, reply in
                self.asked.append(confirmation)
                reply(self.says)
            }
        }

        func lock(_ on: Bool = true) throws {
            let events = try ShowWindowTests.Rig.load("events")
            var engine = try XCTUnwrap(events["engine"]?.objectValue)
            engine["lock"] = .bool(on)
            base.store.apply(event: "engine", engine, now: 0)
        }

        /// Opens a playlist in the tree, so its items show.
        func expand(_ playlist: String) {
            model.choose(playlist: playlist, option: false)
            view.layoutSubtreeIfNeeded()
        }

        /// Replaces what the focused field holds, as selecting it all and typing would.
        func retype(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "no field has the cursor", file: file, line: line)
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        }

        /// Return in a field.
        func pressReturn(in field: NSTextField) {
            _ = NSApplication.shared.sendAction(field.action ?? #selector(NSResponder.insertNewline(_:)), to: field.target, from: field)
        }

        func playlistRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> RowView {
            try XCTUnwrap(view.left.playlists.rows.first { $0.title.stringValue.caseInsensitiveCompare(title) == .orderedSame }, title, file: file, line: line)
        }

        func libraryRow(_ title: String, file: StaticString = #filePath, line: UInt = #line) throws -> RowView {
            try XCTUnwrap(view.left.library.rows.first { $0.title.stringValue == title }, title, file: file, line: line)
        }

        func cell(_ label: String, at index: Int = 0, file: StaticString = #filePath, line: UInt = #line) throws -> CueCellView {
            let found = view.grid.document.cells.filter { $0.cell.label == label }
            return try XCTUnwrap(found.indices.contains(index) ? found[index] : nil, label, file: file, line: line)
        }
    }

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    // MARK: - Playlists (§5)

    func test_aPlaylistsMenuAndARenameInPlace() throws {
        let rig = try Rig()
        let row = try rig.playlistRow("Sunday Night")
        let menu = try XCTUnwrap(row.menuNow)
        XCTAssertEqual(menu.titles, ["Make Live", "Rename", "Date and Time…", "Duplicate…", "Archive a Copy", "Archive", "Delete…"])
        try XCTUnwrap(menu.entry("Rename")).choose()
        let editor = try XCTUnwrap(rig.view.inlineEditor, "a field opens over the row")
        XCTAssertEqual(editor.field.stringValue, "Sunday Night")
        XCTAssertEqual(editor.field.fieldKind, .edit)
        XCTAssertEqual(rig.window.firstResponder, editor.field.currentEditor(), "with the cursor in it")
        XCTAssertEqual(rig.view.topBar.hint.stringValue, "Editing: Return saves · Esc discards")
        XCTAssertEqual(Audit.unlabelled(in: editor), [])
        try rig.retype("Sunday PM")
        XCTAssertEqual(rig.sent.count, 0, "nothing is sent while typing")
        rig.pressReturn(in: editor.field)
        XCTAssertEqual(rig.commands, [["edit playlist \(Self.sundayNight) title \"Sunday PM\""]])
        XCTAssertNil(rig.view.inlineEditor, "the field closed")
        XCTAssertFalse(rig.window.firstResponder is NSText, "and handed the keys back")
    }

    func test_escapeDiscardsARenameAndAClickOutsideSavesItAndDoesNothingElse() throws {
        let rig = try Rig()
        let tap = rig.base.window.keyTap
        try XCTUnwrap(try rig.playlistRow("Sunday Night").menuNow?.entry("Rename")).choose()
        try rig.retype("Thrown away")
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        XCTAssertTrue(tap.take(escape))
        XCTAssertNil(rig.view.inlineEditor)
        XCTAssertEqual(rig.sent.count, 0, "Escape discards what was typed")
        // Again, and a click elsewhere: "so does a click outside, which does nothing else".
        try XCTUnwrap(try rig.playlistRow("Sunday Night").menuNow?.entry("Rename")).choose()
        let editor = try XCTUnwrap(rig.view.inlineEditor)
        try rig.retype("Sunday PM")
        let inside = editor.convert(NSPoint(x: 10, y: 10), to: nil)
        XCTAssertFalse(rig.window.commitFieldInPlace(ifClickedOutsideItAt: inside), "a click in the field is the field's")
        XCTAssertNotNil(rig.view.inlineEditor)
        let onACue = rig.view.grid.convert(NSPoint(x: rig.view.grid.bounds.midX, y: rig.view.grid.bounds.midY), to: nil)
        XCTAssertTrue(rig.window.commitFieldInPlace(ifClickedOutsideItAt: onACue), "the click that saves goes no further: it fires nothing")
        XCTAssertEqual(rig.commands, [["edit playlist \(Self.sundayNight) title \"Sunday PM\""]])
        XCTAssertNil(rig.view.inlineEditor)
    }

    /// "A commit that can't be sent, because the lock came on or the engine
    /// went away, leaves the field open with its text, the reason and Copy."
    func test_aCommitThatCannotBeSentLeavesTheFieldOpenWithItsTextTheReasonAndCopy() throws {
        let rig = try Rig()
        try XCTUnwrap(try rig.playlistRow("Sunday Night").menuNow?.entry("Rename")).choose()
        let editor = try XCTUnwrap(rig.view.inlineEditor)
        try rig.retype("Sunday PM")
        try rig.lock()
        let height = editor.frame.height
        rig.pressReturn(in: editor.field)
        XCTAssertTrue(rig.view.inlineEditor === editor, "the field stays")
        XCTAssertTrue(editor.isHeld)
        XCTAssertEqual(editor.shownProblem, "The station is locked.")
        XCTAssertEqual(editor.field.stringValue, "Sunday PM")
        XCTAssertGreaterThan(editor.frame.height, height, "a line taller, for the reason and Copy")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertEqual(Audit.unlabelled(in: editor), [])
        XCTAssertFalse(rig.view.commitOpenField(), "what waits on the field, ⌘Q among it, waits")
        // The lock comes off: the same Return saves it.
        try rig.lock(false)
        rig.pressReturn(in: editor.field)
        XCTAssertEqual(rig.commands, [["edit playlist \(Self.sundayNight) title \"Sunday PM\""]])
        XCTAssertNil(rig.view.inlineEditor)
        XCTAssertTrue(rig.view.commitOpenField(), "with no field open there is nothing to wait for")
    }

    /// "New playlist: the window's + button or ⌘N opens a title field in the tree; Return sends `edit playlist create "TITLE"`."
    func test_thePlusButtonOpensATitleFieldAndReturnMakesThePlaylist() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.view.left.newPlaylist.isEnabled)
        rig.view.left.newPlaylist.press()
        let editor = try XCTUnwrap(rig.view.inlineEditor)
        XCTAssertEqual(editor.field.placeholderString, "Playlist title")
        try rig.retype("Christmas Eve")
        rig.pressReturn(in: editor.field)
        XCTAssertEqual(rig.commands, [["edit playlist create \"Christmas Eve\""]])
        // An empty title makes nothing, and the field closes.
        rig.view.left.newPlaylist.press()
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        XCTAssertEqual(rig.sent.count, 1)
        XCTAssertNil(rig.view.inlineEditor)
        try rig.lock()
        XCTAssertFalse(rig.view.left.newPlaylist.isEnabled)
        XCTAssertEqual(rig.view.left.newPlaylist.reason, "The station is locked.")
    }

    func test_thePlaylistsOtherEntriesSendTheirEditsAndDeleteAsksFirst() throws {
        let rig = try Rig()
        let menu = try XCTUnwrap(try rig.playlistRow("Sunday Night").menuNow)
        try XCTUnwrap(menu.entry("Archive a Copy")).choose()
        try XCTUnwrap(menu.entry("Archive")).choose()
        XCTAssertEqual(rig.commands, [["edit playlist \(Self.sundayNight) archive"], ["edit playlist \(Self.sundayNight) archived true"]])
        rig.says = false
        try XCTUnwrap(menu.entry("Delete…")).choose()
        XCTAssertEqual(rig.asked, [.deletePlaylist(title: "Sunday Night", isLive: false)])
        XCTAssertEqual(rig.sent.count, 2, "Cancel deletes nothing")
        rig.says = true
        try XCTUnwrap(menu.entry("Delete…")).choose()
        XCTAssertEqual(rig.commands.last, ["edit playlist \(Self.sundayNight) delete"])
        // The live playlist: Archive is disabled, with why.
        let live = try XCTUnwrap(try rig.playlistRow("Sunday").menuNow)
        let archive = try XCTUnwrap(live.items.first { $0.title == "Archive" })
        XCTAssertFalse(archive.isEnabled)
        XCTAssertEqual(archive.toolTip, "It’s live. Archive a Copy works while it is.")
    }

    func test_duplicateAsksForTheNewTitleAndDateAndTimeSetsEachOrNone() throws {
        let rig = try Rig()
        let row = try rig.playlistRow("Sunday Night")
        try XCTUnwrap(row.menuNow?.entry("Duplicate…")).choose()
        let panel = try XCTUnwrap(rig.view.prompt)
        XCTAssertEqual(panel.heading.stringValue, "Duplicate “Sunday Night” as")
        XCTAssertEqual(Audit.unlabelled(in: panel), [])
        let title = try XCTUnwrap(panel.firstField as? ShowField)
        panel.commit()
        XCTAssertEqual(panel.shownProblem, "It needs a name.")
        XCTAssertEqual(rig.sent.count, 0)
        title.stringValue = "Sunday Night (youth)"
        panel.commit()
        XCTAssertEqual(rig.commands, [["edit playlist \(Self.sundayNight) duplicate \"Sunday Night (youth)\""]])
        XCTAssertNil(rig.view.prompt, "the panel closed")
        // Date and Time…: Sunday Night has a time, 18:00, and no date.
        let playlist = try XCTUnwrap(rig.model.store.catalog?.playlist(uuid: Self.sundayNight)?.playlist)
        let schedule = Prompts.schedule(playlist, model: rig.model)
        XCTAssertEqual(schedule.noDate.state, .on, "no date: None is ticked")
        XCTAssertEqual(schedule.noTime.state, .off)
        schedule.panel.finish()
        schedule.panel.commit()
        XCTAssertEqual(rig.sent.count, 1, "nothing changed, nothing sent")
        schedule.noDate.state = .off
        schedule.date.dateValue = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-08T00:00:00Z"))
        schedule.noTime.state = .on
        schedule.panel.commit()
        XCTAssertEqual(rig.commands.last, ["edit playlist \(Self.sundayNight) serviceDate \"2026-11-08\"", "edit playlist \(Self.sundayNight) serviceTime null"])
    }

    func test_anItemsMenuAddsAHeaderAboveRenamesAHeaderAndRemoves() throws {
        let rig = try Rig()
        rig.expand(Self.sundayNight)
        let items = try XCTUnwrap(rig.model.store.catalog?.playlist(uuid: Self.sundayNight)?.playlist.items)
        let header = try rig.playlistRow("Evening")
        XCTAssertEqual(header.menuNow?.titles, ["Remove from Playlist", "Add Header Above", "Rename"])
        try XCTUnwrap(header.menuNow?.entry("Rename")).choose()
        try rig.retype("Evening Service")
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        let song = try XCTUnwrap(rig.view.left.playlists.rows.first { $0.title.stringValue == "Doxology" })
        XCTAssertEqual(song.menuNow?.titles, ["Remove from Playlist", "Add Header Above", "Show in Library"])
        try XCTUnwrap(song.menuNow?.entry("Add Header Above")).choose()
        XCTAssertEqual(rig.view.inlineEditor?.field.placeholderString, "Header label")
        try rig.retype("Response")
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        try XCTUnwrap(song.menuNow?.entry("Remove from Playlist")).choose()
        XCTAssertEqual(rig.asked, [], "not the live item: undo is the way back")
        XCTAssertEqual(rig.commands, [
            ["edit playlist \(Self.sundayNight) item \(items[0].uuid.uuidString.lowercased()) label \"Evening Service\""],
            ["edit playlist \(Self.sundayNight) insert items 2 { \"kind\": \"header\", \"label\": \"Response\" }"],
            ["edit playlist \(Self.sundayNight) item \(items[2].uuid.uuidString.lowercased()) remove"],
        ])
    }

    // MARK: - The library (§5)

    func test_aListsMenuInTheLibrary() throws {
        let rig = try Rig()
        rig.model.toggle(folder: "Hymns")
        rig.view.layoutSubtreeIfNeeded()
        let row = try rig.libraryRow("Great Is Thy Faithfulness")
        let menu = try XCTUnwrap(row.menuNow)
        XCTAssertEqual(menu.titles, ["Add to Playlist", "  Sunday Night", "  Sunday", "Rename", "Duplicate", "Open in Text Editor", "Restore a Version…", "Delete…",
                                     "New List Here"])
        XCTAssertEqual(menu.items.first { $0.title == "Open in Text Editor" }?.isEnabled, false)
        XCTAssertEqual(menu.items.first { $0.title == "Open in Text Editor" }?.toolTip, "Not in this build yet.")
        try XCTUnwrap(menu.entry("Sunday Night")).choose()
        try XCTUnwrap(menu.entry("Duplicate")).choose()
        try XCTUnwrap(menu.entry("New List Here")).choose()
        try XCTUnwrap(menu.entry("Rename")).choose()
        try rig.retype("Great Is Thy Faithfulness (Runyan)")
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        XCTAssertEqual(rig.commands, [
            ["edit playlist \(Self.sundayNight) insert items 4 { \"kind\": \"linked\", \"list\": 42, \"listUuid\": \"\(Self.list42)\" }"],
            ["edit list 42 duplicate"], ["edit list create folder \"Hymns\""], ["edit list 42 title \"Great Is Thy Faithfulness (Runyan)\""],
        ])
        // "Delete… (`edit list N delete`, after a confirmation naming the playlists that link it, from `listUse`)".
        try XCTUnwrap(menu.entry("Delete…")).choose()
        XCTAssertEqual(rig.sent.last?.fields["what"], .string("listUse"))
        rig.answers[4](.answer(try ShowWindowTests.Rig.load("listUse-42")))
        guard case .deleteList(let title, let playlists)? = rig.asked.last else { return XCTFail("\(rig.asked)") }
        XCTAssertEqual(title, "Great Is Thy Faithfulness")
        XCTAssertEqual(playlists, ["Sunday Night", "Sunday", "Sunday 2026-11-01"])
        XCTAssertEqual(rig.commands.last, ["edit list 42 delete"])
    }

    func test_aFolderRenamesOnADoubleClickAndDeletesOnlyWhenEmpty() throws {
        let rig = try Rig()
        let folder = try rig.libraryRow("Hymns")
        let menu = try XCTUnwrap(folder.menuNow)
        XCTAssertEqual(menu.titles, ["Rename", "New Folder", "New List Here", "Delete Folder"])
        let delete = try XCTUnwrap(menu.items.first { $0.title == "Delete Folder" })
        XCTAssertFalse(delete.isEnabled, "it holds lists")
        XCTAssertEqual(delete.toolTip, "The folder isn’t empty.")
        // "Double-click or the menu renames one in place".
        try XCTUnwrap(folder.onDoubleClick)()
        XCTAssertEqual(rig.view.inlineEditor?.field.stringValue, "Hymns")
        try rig.retype("Old Hymns")
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        try XCTUnwrap(menu.entry("New Folder")).choose()
        XCTAssertEqual(rig.view.inlineEditor?.field.placeholderString, "Folder name")
        try rig.retype("Carols")
        rig.pressReturn(in: try XCTUnwrap(rig.view.inlineEditor).field)
        // The tree's empty space: a folder or a list at the top.
        let top = try XCTUnwrap(rig.view.left.library.makeMenu?())
        XCTAssertEqual(top.titles, ["New Folder", "New List Here"])
        try XCTUnwrap(top.entry("New List Here")).choose()
        XCTAssertEqual(rig.commands, [["edit folder \"Hymns\" rename \"Old Hymns\""], ["edit folder \"Hymns/Carols\" create"], ["edit list create"]])
    }

    // MARK: - A cue (§6, §10)

    func test_aCuesMenuAndItsPanels() throws {
        let rig = try Rig()
        let cell = try rig.cell("Verse 1", at: 1)
        let c = cell.cell.uuid
        let menu = rig.view.grid.cueMenu(for: cell)
        XCTAssertEqual(menu.titles, ["Fire", "Edit Text", "Edit Cue", "Note…", "Trigger", "  Go", "  Time after Previous…", "  Advance After…", "Duplicate Section"])
        XCTAssertEqual(menu.items.first { $0.title == "Edit Cue" }?.isEnabled, false, "edit mode is Area 14's")
        XCTAssertEqual(menu.items.first { $0.title == "Trigger" }?.submenu?.items.first?.state, .on, "its trigger, Go, is ticked")
        try XCTUnwrap(menu.entry("Note…")).choose()
        let note = try XCTUnwrap(rig.view.prompt)
        XCTAssertEqual(note.heading.stringValue, "Note on cue 2")
        (note.firstField as? ShowField)?.stringValue = "Wait for the pastor"
        note.commit()
        XCTAssertNil(rig.view.prompt)
        // "Time after Previous… (seconds)".
        try XCTUnwrap(menu.entry("Time after Previous…")).choose()
        let time = try XCTUnwrap(rig.view.prompt)
        (time.firstField as? ShowField)?.stringValue = "soon"
        time.commit()
        XCTAssertEqual(time.shownProblem, "Type a number of seconds, such as 8 or 2.5.")
        XCTAssertNotNil(rig.view.prompt, "it stays open until it holds a time")
        (time.firstField as? ShowField)?.stringValue = "2.5"
        time.commit()
        // "Advance After… (seconds or none)".
        let advance = Prompts.advanceAfter(cell.cell, in: cell.section, model: rig.model)
        XCTAssertEqual(advance.none.state, .on, "it has none")
        advance.panel.finish()
        advance.none.state = .off
        (advance.panel.firstField as? ShowField)?.stringValue = "12"
        advance.panel.commit()
        try XCTUnwrap(menu.entry("Duplicate Section")).choose()
        XCTAssertEqual(rig.commands, [
            ["edit list 42 cue \(c) note \"Wait for the pastor\""], ["edit list 42 cue \(c) trigger { \"ms\": 2500, \"type\": \"time\" }"],
            ["edit list 42 cue \(c) advanceAfterMs 12000"], ["edit list 42 cue \(c) section duplicate"],
        ])
        // The menu's first entry fires the cue, as a click does.
        try XCTUnwrap(menu.entry("Fire")).choose()
        XCTAssertEqual(rig.commands.last, ["item 2 cue 2"])
    }

    /// Spec 10 §10, "In-place text" — "Double-click on a text cue,
    /// ⌥-double-click, or Edit Text in its menu, opens a field over the cell
    /// holding the body of its text write. Return makes a new line; ⌘Return
    /// commits".
    func test_aDoubleClickOnATextCueEditsItsWordsInPlace() throws {
        let rig = try Rig()
        let cell = try rig.cell("Verse 1", at: 1)
        cell.press()
        XCTAssertEqual(rig.commands, [["item 2 cue 2"]], "its first press has already fired the cue, as every press does")
        XCTAssertNil(rig.view.inlineEditor)
        cell.press()
        let editor = try XCTUnwrap(rig.view.inlineEditor, "the second press of the double-click opens the field")
        XCTAssertEqual(rig.sent.count, 1, "and fires nothing")
        XCTAssertEqual(editor.field.stringValue, "There is no shadow\nof turning with Thee")
        XCTAssertEqual(editor.field.fieldKind, .inPlaceText)
        XCTAssertEqual(rig.view.topBar.hint.stringValue, "Editing: ⌘Return saves · Esc discards")
        XCTAssertEqual(editor.frame, rig.view.convert(cell.editRect, from: cell), "over the cell's picture")
        // Return is a new line, and sends nothing.
        let typing = try XCTUnwrap(rig.window.firstResponder as? NSTextView)
        typing.selectAll(nil)
        typing.insertText("There is no shadow", replacementRange: typing.selectedRange())
        XCTAssertTrue(editor.control(editor.field, textView: typing, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        typing.insertText("of turning", replacementRange: typing.selectedRange())
        XCTAssertEqual(rig.sent.count, 1)
        XCTAssertNotNil(rig.view.inlineEditor)
        // ⌘Return commits: one `edit.cueChannel`.
        XCTAssertTrue(editor.commitNow())
        XCTAssertEqual(rig.commands.last, ["edit list 42 cue \(cell.cell.uuid) channel 2 write text \"There is no shadow\\nof turning\""])
        XCTAssertNil(rig.view.inlineEditor)
    }

    func test_optionDoubleClickAndEditTextEditWithoutFiringAndALocalCopySaysWhy() throws {
        let rig = try Rig()
        let cell = try rig.cell("Chorus")
        cell.press(option: true)
        cell.press(option: true)
        XCTAssertNotNil(rig.view.inlineEditor, "⌥-double-click edits")
        XCTAssertEqual(rig.sent.count, 0, "without firing")
        rig.view.inlineEditor?.close()
        try XCTUnwrap(rig.view.grid.cueMenu(for: cell).entry("Edit Text")).choose()
        XCTAssertEqual(rig.view.inlineEditor?.field.stringValue, "Great is Thy faithfulness!\nGreat is Thy faithfulness!")
        XCTAssertEqual(rig.sent.count, 0)
        rig.view.inlineEditor?.close()
        // A cue of this Mac's own copy: it fires, and its words aren't edited.
        let local = try XCTUnwrap(rig.view.grid.document.cells.first { $0.section.isLocal })
        let menu = rig.view.grid.cueMenu(for: local)
        XCTAssertEqual(menu.items.first { $0.title == "Note…" }?.toolTip, "This Mac’s own copy can’t be edited in this version.")
        rig.view.grid.editText(local)
        XCTAssertNil(rig.view.inlineEditor)
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.grid.notice.stringValue, "Not sent. This Mac’s own copy can’t be edited in this version.")
        XCTAssertFalse(rig.view.grid.notice.isHidden)
    }

    // MARK: - A list header (§6, §10, §14)

    func test_aListHeadersMenuSetsAGradeAndRemovesTheItem() throws {
        let rig = try Rig()
        let header = try XCTUnwrap(rig.view.grid.document.headers.compactMap { $0.view as? ListHeaderView }.first { $0.section.listUuid == Self.list42 && !$0.section.isLocal })
        let menu = try XCTUnwrap(header.menuNow)
        XCTAssertEqual(Array(menu.titles.prefix(5)), ["Remove from Playlist", "Show in Library", "Open in Text Editor", "Grade for Channel 1 Background", "  None"])
        let grades = try XCTUnwrap(menu.items.first { $0.title == "Grade for Channel 2 Foreground" }?.submenu)
        XCTAssertEqual(grades.items.first?.state, .on, "None: the first write tracks no grade")
        let grade = try XCTUnwrap(grades.items.dropFirst().first as? ClosureMenuItem)
        grade.choose()
        XCTAssertEqual(rig.commands.count, 1)
        XCTAssertEqual(rig.commands.first?.first?.hasSuffix("grade 1 track"), true, rig.commands.first?.first ?? "")
        try XCTUnwrap(menu.entry("Remove from Playlist")).choose()
        XCTAssertEqual(rig.asked, [.removeLiveItem(title: "Great Is Thy Faithfulness")], "the live item: it says the song finishes first")
        XCTAssertEqual(rig.commands.last?.first?.hasSuffix("remove"), true)
    }

    /// Spec 10 §14 — "Restore a Version… on a list opens a sheet of its kept
    /// versions from the `versions` query, newest first ... Restore asks ...
    /// Then `system restore list N version V`."
    func test_restoreAVersionOpensTheSheetAsksAndRestores() throws {
        let rig = try Rig()
        let header = try XCTUnwrap(rig.view.grid.document.headers.compactMap { $0.view as? ListHeaderView }.first { $0.section.listUuid == Self.list42 && !$0.section.isLocal })
        try XCTUnwrap(header.menuNow?.entry("Restore a Version…")).choose()
        XCTAssertEqual(rig.sent.last?.fields["what"], .string("versions"))
        XCTAssertEqual(rig.sent.last?.fields["list"], .number(42))
        var answer = try ShowWindowTests.Rig.load("versions-42")
        answer["versions"] = .array([.object(["version": .number(16), "keptAt": .string("2026-11-01T09:12:00Z"), "title": .string("Great Is Thy Faithfulness"),
                                              "cues": .number(14)]),
                                     .object(["version": .number(15), "keptAt": .string("2026-10-25T08:40:00Z"), "title": .string("Great Is Thy Faithfulness"),
                                              "cues": .number(12)])])
        rig.answers[0](.answer(answer))
        let sheet = try XCTUnwrap(rig.view.sheetView)
        sheet.layoutSubtreeIfNeeded()
        XCTAssertEqual(sheet.heading.stringValue, "Kept versions of “Great Is Thy Faithfulness”")
        XCTAssertEqual(sheet.titles.count, 2)
        XCTAssertTrue(sheet.titles[0].stringValue.hasPrefix("Version 16, kept "), sheet.titles[0].stringValue)
        XCTAssertEqual(sheet.details[0].stringValue, "“Great Is Thy Faithfulness” · 14 cues")
        XCTAssertEqual(sheet.note.stringValue, "This list is on air: each cue takes a restored version at its next fire.", "the recorded state has it live")
        XCTAssertEqual(Audit.unlabelled(in: sheet), [])
        sheet.buttons[0].press()
        guard case .restoreVersion(let version, let title, _, let cues, let onAir)? = rig.asked.last else { return XCTFail("\(rig.asked)") }
        XCTAssertEqual([version, cues], [16, 14])
        XCTAssertEqual(title, "Great Is Thy Faithfulness")
        XCTAssertTrue(onAir)
        XCTAssertEqual(rig.commands.last, ["system restore list 42 version 16"])
        XCTAssertNil(rig.view.sheetView)
        // A refusal is said in the top bar, in plain words.
        rig.answers[1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "conflict", message: "list 42 was renumbered"))))
        XCTAssertEqual(rig.view.topBar.hint.stringValue, "It has changed since, so that can’t be put back.")
    }

    // MARK: - What comes back (§10)

    func test_aRefusalIsSaidInTheColumnWhereItWasTriedAndNothingIsClipped() throws {
        for transform in [{ $0 }, Pseudolanguage.accented, Pseudolanguage.longer] as [(String) -> String] {
            try ViewStrings.install(transform: transform)
            let rig = try Rig()
            rig.model.say(.rejected(EngineRejection(code: "duplicate", message: "")), at: .left)
            rig.model.say(.rejected(EngineRejection(code: "onAir", message: "")), at: .grid)
            rig.model.say(.done(undo: true, kind: .rename, object: .playlist("Sunday")), at: .top)
            rig.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(rig.view.left.notice.stringValue, transform("That name is taken."))
            XCTAssertEqual(rig.view.grid.notice.stringValue, transform("It’s on air: clear it or switch away first."))
            XCTAssertFalse(rig.view.topBar.hint.isHidden)
            XCTAssertFalse(Audit.isCutOff(rig.view.topBar.hint), "\"\(rig.view.topBar.hint.stringValue)\" is clipped")
            for label in [rig.view.left.notice, rig.view.grid.notice] {
                XCTAssertFalse(label.isHidden)
                XCTAssertGreaterThan(label.frame.width, 0)
                let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 200)).height ?? 0
                XCTAssertGreaterThanOrEqual(label.frame.height, needed - 0.5, "\"\(label.stringValue)\" is cut short")
            }
        }
        try ViewStrings.install()
    }
}

/// Spec 10 §4 and §10 — the menu bar's edits: New Playlist, New List, and
/// Undo and Redo named from the `history` topic.
@MainActor
final class EditMenuTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    @MainActor
    final class Rig {
        let controller: AppController
        let delegate = AppDelegate()
        var sent: [EngineRequest] = []
        var answers: [(Reply?) -> Void] = []
        var bar: MenuBar { delegate.menuBar! }

        init() throws {
            controller = AppController(rootsStore: MemoryRootsStore(), launcher: NoLauncher(), connector: NoConnector(),
                                       executable: URL(fileURLWithPath: "/nowhere/oengine"), releaseKey: FakeReleaseKey())
            delegate.openMainWindow(show: false, controller: controller)
            let store = controller.store
            store.connected(Hello(api: Hello.api, engine: OCore.appVersion, pid: 1, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2"))
            store.apply(catalog: try ShowWindowTests.Rig.load("catalog"))
            store.apply(media: try ShowWindowTests.Rig.load("media"))
            for name in ["list-42", "list-7", "list-local"] { store.apply(list: try ShowWindowTests.Rig.load(name)) }
            store.apply(state: try ShowWindowTests.Rig.load("state"), now: 0)
            controller.model.transmit = { [unowned self] request, answer in
                self.sent.append(request)
                self.answers.append(answer)
            }
        }

        func entry(_ menu: String, _ index: Int) throws -> ClosureMenuItem {
            bar.refresh()
            return try XCTUnwrap(bar.entries(of: menu)[index] as? ClosureMenuItem)
        }

        func history(undo: String?, redo: String? = nil) {
            func step(_ text: String?) -> JSONValue {
                guard let text else { return .null }
                return .object(["group": .string("g-1"), "commands": .number(1), "source": .object(["kind": .string("ui")]), "text": .string(text)])
            }
            controller.store.apply(event: "history", ["topic": .string("history"), "undo": step(undo), "redo": step(redo)], now: 0)
        }

        var commands: [String] {
            sent.compactMap { request in
                request.fields["command"].flatMap { try? JSONCoding.decode(Command.self, from: $0) }.flatMap(CommandText.print)
            }
        }
    }

    func test_undoAndRedoAreNamedFromTheHistoryAndSendTheirCommands() throws {
        let rig = try Rig()
        XCTAssertEqual(try rig.entry("Edit", 0).title, "Undo")
        XCTAssertFalse(try rig.entry("Edit", 0).validateMenuItem(try rig.entry("Edit", 0)), "nothing to undo")
        try rig.entry("Edit", 0).choose()
        XCTAssertEqual(rig.sent.count, 0)
        rig.history(undo: "edit list 42 title \"Great Is Thy Faithfulness (Runyan)\"")
        let undo = try rig.entry("Edit", 0)
        XCTAssertEqual(undo.title, "Undo Rename")
        XCTAssertEqual(undo.keyEquivalent, "z")
        XCTAssertTrue(undo.validateMenuItem(undo))
        XCTAssertEqual(try rig.entry("Edit", 1).title, "Redo")
        XCTAssertEqual(try rig.entry("Edit", 1).keyEquivalentModifierMask, [.shift, .command])
        undo.choose()
        XCTAssertEqual(rig.commands, ["undo"])
        rig.history(undo: nil, redo: "edit list 42 title \"Great Is Thy Faithfulness (Runyan)\"")
        rig.answers[0](.result(CommandOutcome(kind: .ok)))
        let top = rig.controller.windowController.regions.topBar
        XCTAssertEqual(top.hint.stringValue, "Undid the rename of the list Great Is Thy Faithfulness", "said for three seconds")
        XCTAssertEqual(try rig.entry("Edit", 1).title, "Redo Rename")
        try rig.entry("Edit", 1).choose()
        XCTAssertEqual(rig.commands, ["undo", "redo"])
    }

    /// "While a text field has the focus, ⌘Z and ⇧⌘Z undo its own typing instead (Spec 5 §8)".
    func test_whileAFieldHasTheFocusUndoIsTheFieldsOwn() throws {
        let rig = try Rig()
        rig.history(undo: "edit list 42 title \"X\"")
        let window = rig.controller.windowController.window
        XCTAssertTrue(window.makeFirstResponder(rig.controller.windowController.regions.grid.search))
        let undo = try rig.entry("Edit", 0)
        XCTAssertEqual(undo.title, "Undo", "not the library's step")
        undo.choose()
        XCTAssertEqual(rig.sent.count, 0, "the library's undo isn't sent from a field")
        window.handKeysBack()
        XCTAssertEqual(try rig.entry("Edit", 0).title, "Undo Rename")
    }

    func test_newPlaylistAndNewListFromTheFileMenu() throws {
        let rig = try Rig()
        let newPlaylist = try rig.entry("File", 0)
        XCTAssertEqual(newPlaylist.title + " " + newPlaylist.keyEquivalent, "New Playlist n")
        XCTAssertTrue(newPlaylist.isEnabled)
        newPlaylist.choose()
        XCTAssertEqual(rig.controller.windowController.regions.inlineEditor?.field.placeholderString, "Playlist title", "⌘N opens the title field in the tree")
        rig.controller.windowController.regions.inlineEditor?.close()
        // "New List (⇧⌘N ...) sends ... `edit list create` at the top".
        let newList = try rig.entry("File", 1)
        XCTAssertEqual(newList.keyEquivalentModifierMask, [.shift, .command])
        newList.choose()
        XCTAssertEqual(rig.commands, ["edit list create"])
        // The selected folder is the one the browsed library list is in.
        rig.controller.model.browse(.list(EditsViewTests.list42))
        try rig.entry("File", 1).choose()
        XCTAssertEqual(rig.commands.last, "edit list create folder \"Hymns\"")
    }

    /// Spec 10 §10 — "⌘Q, ⌘2 and Lock Station commit an open field first."
    func test_quitCommitsAnOpenFieldFirstAndWaitsWhenItCannot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = MemoryRootsStore()
        roots.roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        let controller = AppController(rootsStore: roots, launcher: NoLauncher(), connector: NoConnector(), executable: URL(fileURLWithPath: "/nowhere/oengine"),
                                       releaseKey: FakeReleaseKey())
        var alerts = 0
        controller.presentAlert = { _, _, _ in alerts += 1 }
        controller.start(showWindow: false)
        defer { controller.supervisor?.leaveEngineRunning() }
        let regions = controller.windowController.regions
        // A field is open, and its edit has no engine to go to.
        var committed: [String] = []
        regions.editInPlace(over: regions.left, text: "", label: "Title") { text in
            committed.append(text)
            return text.isEmpty ? nil : .unavailable(.engineAway)
        }
        let editor = try XCTUnwrap(regions.inlineEditor)
        editor.field.stringValue = "Christmas Eve"
        XCTAssertEqual(controller.shouldTerminate(systemAsked: false), .terminateCancel, "the field is committed first, and it couldn't be")
        XCTAssertEqual(committed, ["Christmas Eve"])
        XCTAssertEqual(alerts, 0, "so the quit isn't asked yet")
        XCTAssertTrue(regions.inlineEditor === editor)
        XCTAssertEqual(editor.shownProblem, "The engine is away.")
        // Emptied, there is nothing to save: the field closes and Quit asks its question.
        editor.field.stringValue = ""
        XCTAssertEqual(controller.shouldTerminate(systemAsked: false), .terminateLater)
        XCTAssertNil(regions.inlineEditor)
        XCTAssertEqual(alerts, 1)
    }
}
