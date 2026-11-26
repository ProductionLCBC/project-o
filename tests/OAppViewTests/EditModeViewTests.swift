import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 11 §13, "Area 14, the frame" and "the Cues page" — the window in
/// edit mode, on no screen, over the engine's recorded answers: where the
/// regions sit, what the top bar, the Browser and the monitors show, and
/// what a click, a key, a drop and each of the inspector's controls does.
@MainActor
final class EditModeViewTests: XCTestCase {
    typealias Rig = DropsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private let c = ["11aa0000-0000-4000-8000-000000000001", "22bb0000-0000-4000-8000-000000000002",
                     "33cc0000-0000-4000-8000-000000000003", "44dd0000-0000-4000-8000-000000000004"]
    private let list7 = "a9f00000-0000-4000-8000-000000000007"

    /// A rig with edit mode open on the live list, list 42 in the playlist Sunday.
    private func editing() throws -> Rig {
        let rig = try Rig()
        rig.view.enterEdit()
        rig.view.layoutSubtreeIfNeeded()
        return rig
    }

    /// The last command sent, in canonical text, and how many were sent: the
    /// Preview monitor's `render` queries go between them and aren't commands.
    private func last(_ rig: Rig) -> [String]? { rig.commands.last { !$0.isEmpty } }
    private func count(_ rig: Rig) -> Int { rig.commands.filter { !$0.isEmpty }.count }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    /// A press of the pointer on the cue grid, at a point of the grid measured from its top left.
    private func click(_ grid: CueGridView, x: Double, y: Double, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) throws {
        let point = grid.convert(NSPoint(x: x, y: y), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: 0, windowNumber: grid.window?.windowNumber ?? 0,
                                                     context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        grid.mouseDown(with: event)
        grid.mouseUp(with: event)
    }

    /// A press, a drag and a release on the cue grid.
    private func drag(_ grid: CueGridView, from: (x: Double, y: Double), to: (x: Double, y: Double)) throws {
        func event(_ type: NSEvent.EventType, _ at: (x: Double, y: Double)) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: grid.convert(NSPoint(x: at.x, y: at.y), to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: grid.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        grid.mouseDown(with: try event(.leftMouseDown, from))
        grid.mouseDragged(with: try event(.leftMouseDragged, ((from.x + to.x) / 2, to.y)))
        grid.mouseDragged(with: try event(.leftMouseDragged, to))
        grid.mouseUp(with: try event(.leftMouseUp, to))
    }

    /// The middle of a cell, or of a cue's header for a nil row.
    private func middle(_ grid: CueGridView, cue: Int, row: Int?) -> (x: Double, y: Double) {
        let g = grid.geometry
        let x = g.x(cue: cue) + g.column / 2
        guard let row else { return (x, CueGridGeometry.band + g.header / 2) }
        return (x, g.y(row: row) + g.rowHeight(row) / 2)
    }

    // MARK: - The frame (Spec 11 §2)

    func test_editModeLaysTheWindowOutInItsRegionsAndShowModesComeBackOnLeaving() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.view.banner.isHidden)
        XCTAssertTrue(rig.view.browser.isHidden, "show mode shows none of edit mode's regions")
        rig.view.topBar.edit.press()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.model.mode, .edit)
        XCTAssertEqual(rig.view.topBar.frame, NSRect(x: 0, y: 0, width: 1440, height: 44))
        XCTAssertEqual(rig.view.browser.frame, NSRect(x: 4, y: 48, width: 260, height: 848))
        XCTAssertEqual(rig.view.workspace.frame, NSRect(x: 268, y: 48, width: 804, height: 594))
        XCTAssertEqual(rig.view.inspector.frame, NSRect(x: 268, y: 646, width: 1168, height: 250))
        XCTAssertEqual(rig.view.previewPanel.frame.origin, NSPoint(x: 1076, y: 48))
        XCTAssertEqual(rig.view.previewPanel.frame.width, 360)
        XCTAssertEqual(rig.view.programPanel.frame.maxY, 642)
        XCTAssertEqual(rig.view.programPanel.frame.minY, rig.view.previewPanel.frame.maxY + 4)
        // "Its left column, media pool panel and right column aren't shown in edit mode".
        for view in [rig.view.grid, rig.view.pool, rig.view.preview, rig.view.nextRow, rig.view.tabs, rig.view.strip] as [NSView] {
            XCTAssertTrue(view.isHidden, "\(type(of: view))")
        }
        for view in [rig.view.browser, rig.view.workspace, rig.view.previewPanel, rig.view.programPanel, rig.view.inspector] as [NSView] {
            XCTAssertFalse(view.isHidden, "\(type(of: view))")
        }
        // Leaving by Show: show mode's regions come back, and nothing was fired.
        rig.view.topBar.show.press()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertEqual(rig.view.topBar.frame.height, 44, "the same bar in both modes (Spec 10 §4)")
        XCTAssertFalse(rig.view.grid.isHidden)
        XCTAssertFalse(rig.view.strip.isHidden)
        XCTAssertTrue(rig.view.inspector.isHidden)
        XCTAssertNil(rig.view.left.tab)
        XCTAssertEqual(rig.view.left.frame.minY, 44 + 4, "the left column is the whole column again, a panel of its own")
        XCTAssertEqual(rig.view.left.outline, Palette.hairline)
        XCTAssertEqual(count(rig), 0, "no command was sent on the way in or out")
        // A wider, taller window: the monitors stop at 380 points and the workspace takes the rest.
        rig.view.enterEdit()
        rig.view.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.previewPanel.frame.width, 380)
        XCTAssertEqual(rig.view.workspace.frame.width, 1920 - 268 - 4 - 380 - 4)
        XCTAssertEqual(rig.view.inspector.frame, NSRect(x: 268, y: 1080 - 254, width: 1920 - 272, height: 250))
    }

    func test_theTopBarNamesWhatIsEditedHoldsThePagePickerAndAShortStatus() throws {
        let rig = try editing()
        let bar = rig.view.topBar
        XCTAssertTrue(bar.edit.isOn)
        XCTAssertFalse(bar.show.isOn)
        XCTAssertEqual(bar.crumb.stringValue, "Sunday › Great Is Thy Faithfulness")
        XCTAssertTrue(bar.position.isHidden, "the live position is said under the Program monitor")
        // "Center: the page picker: Cues, Text, Stacks, Channels, Presets, Objects. Text is disabled until Area 10 lands".
        XCTAssertEqual(bar.pagePicker.segments.map(\.title), ["Cues", "Text", "Stacks", "Channels", "Presets", "Objects"])
        XCTAssertEqual(bar.pagePicker.selected, 0)
        XCTAssertEqual(bar.pagePicker.segments.map(\.isEnabled), [true, false, true, true, true, true])
        // "Beside it, the Live toggle": off, "which edit mode always opens with"; "drawn in the live red while it is on".
        XCTAssertEqual(bar.liveToggle.title, "Live")
        XCTAssertFalse(bar.liveToggle.isHidden)
        XCTAssertEqual(bar.liveToggle.style, .quiet)
        XCTAssertEqual(bar.liveToggle.accessibilityValue() as? Int, 0)
        bar.liveToggle.press()
        XCTAssertTrue(rig.model.editing.isLive)
        XCTAssertEqual(bar.liveToggle.style, .live)
        XCTAssertEqual(bar.liveToggle.accessibilityValue() as? Int, 1)
        bar.liveToggle.press()
        XCTAssertFalse(rig.model.editing.isLive)
        XCTAssertEqual(bar.liveToggle.style, .quiet)
        // "Right: the time of day; the saving pill, which reads "Saved" ...; and the engine pill".
        XCTAssertEqual(bar.saved.title, "Saved")
        XCTAssertEqual(bar.engine.title, "Engine")
        XCTAssertEqual(bar.engine.accessibilityLabel(), "Engine: connected, and every output is presenting")
        // "an output that isn't presenting ... shows as its show-mode dot, and each of show mode's tags shows while it applies".
        XCTAssertEqual(bar.shownOutputs, [], "output 1 is presenting: the pill says so")
        XCTAssertEqual(bar.shownTags, ["Audio lost", "Popup 1"])
        XCTAssertEqual(bar.outputsMenu.items.map(\.title), ["1 Main · stack 1"], "a click on the engine pill lists every output")
        var output = try XCTUnwrap(try ShowWindowTests.Rig.load("state").items("events")?.compactMap(\.objectValue).first { $0.text("topic") == "outputs" && $0["output"] != nil })
        output["state"] = .string("paused")
        rig.store.apply(event: "outputs", output, now: rig.clock.now)
        XCTAssertEqual(bar.shownOutputs, ["1 Main · lost"])
        XCTAssertEqual(bar.engine.accessibilityLabel(), "Engine: connected. An output or a warning needs a look")
        // The picker picks a page, which the workspace and the crumb follow; ⌥⌘N does the same from the View menu.
        bar.pagePicker.segments[2].press()
        XCTAssertEqual(rig.model.editing.page, .stacks)
        XCTAssertEqual(bar.pagePicker.selected, 2)
        XCTAssertEqual(bar.crumb.stringValue, "Stacks")
        XCTAssertFalse(rig.view.workspace.stacks.isHidden)
        XCTAssertTrue(rig.view.workspace.grid.isHidden)
        bar.pagePicker.segments[5].press()
        XCTAssertEqual(rig.model.editing.page, .objects)
        XCTAssertFalse(rig.view.workspace.objects.isHidden)
        XCTAssertTrue(rig.view.workspace.stacks.isHidden)
        rig.view.enterEdit(page: .cues)
        XCTAssertEqual(bar.pagePicker.selected, 0)
        XCTAssertFalse(rig.view.workspace.grid.isHidden)
    }

    // MARK: - The Browser (Spec 11 §2)

    func test_theBrowsersTabsPickTheListAndShowTheMediaPool() throws {
        let rig = try editing()
        let browser = rig.view.browser
        XCTAssertEqual(browser.tabs.segments.map(\.title), ["Playlists", "Library", "Media"])
        XCTAssertEqual(browser.tabs.selected, 0)
        XCTAssertEqual(rig.view.left.tab, .playlists)
        XCTAssertFalse(rig.view.left.playlists.isHidden)
        XCTAssertTrue(rig.view.left.library.isHidden)
        XCTAssertEqual(rig.view.left.frame.minY, rig.view.browser.frame.minY + 1 + 36, "the tab's window sits under the Browser's tabs, inside its edge")
        XCTAssertEqual(rig.model.expandedPlaylists, ["b1a70000-0000-4000-8000-000000000001"], "the edited list's playlist is open to its items")
        // The edited list's item is the row marked.
        let row = { (title: String) in try XCTUnwrap(rig.view.left.playlists.rows.first { $0.title.stringValue == title }, title) }
        XCTAssertTrue(try row("Great Is Thy Faithfulness").content.isSelected)
        // "A click on a linked item ... makes it the list the Cues and Text pages edit, which the Cues page shows at once".
        try row("Doxology").onClick?(false)
        XCTAssertEqual(rig.model.editing.listUuid, list7)
        XCTAssertEqual(rig.view.workspace.title.stringValue, "Doxology")
        XCTAssertEqual(rig.view.topBar.crumb.stringValue, "Sunday › Doxology")
        XCTAssertEqual(rig.model.browse.shown, .playlist("b1a70000-0000-4000-8000-000000000001"), "the show grid stays on what it browses")
        XCTAssertTrue(rig.sent.filter { $0.type == "command" }.isEmpty, "nothing in the Browser fires")
        // The Library tab: a click on a list, and a double-click from another page.
        browser.tabs.segments[1].press()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.view.left.tab, .library)
        XCTAssertFalse(rig.view.left.library.isHidden)
        XCTAssertTrue(rig.view.left.playlists.isHidden)
        rig.model.toggle(folder: "Hymns")
        let hymn = try XCTUnwrap(rig.view.left.library.rows.first { $0.title.stringValue == "Great Is Thy Faithfulness" })
        hymn.onClick?(false)
        XCTAssertEqual(rig.view.topBar.crumb.stringValue, "Library › Great Is Thy Faithfulness")
        rig.model.editing.show(page: .channels)
        try XCTUnwrap(rig.view.left.library.rows.first { $0.title.stringValue == "Doxology" }).onDoubleClick?()
        XCTAssertEqual(rig.model.editing.page, .cues, "a double-click opens the Cues page on it from any page")
        XCTAssertEqual(rig.model.editing.listUuid, list7)
        // The Media tab: the pool at the Browser's width, as a grid of two to a row, or a list.
        browser.tabs.segments[2].press()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(rig.view.left.isHidden)
        XCTAssertFalse(browser.search.isHidden)
        XCTAssertEqual(browser.count.stringValue, "\(rig.model.poolTiles.count) items")
        XCTAssertEqual(browser.tiles.count, rig.model.poolTiles.count)
        XCTAssertEqual(browser.tiles[0].frame.minY, browser.tiles[1].frame.minY, "two tiles to a row")
        XCTAssertEqual(browser.tiles[0].dragPayload, .media(browser.tiles[0].tile.id))
        browser.views.segments[1].press()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.model.settings.mediaView, .list)
        XCTAssertEqual(browser.rows.count, rig.model.poolTiles.count)
        XCTAssertTrue(browser.tiles.isEmpty)
        // "An item's menu has Defaults…, Replace with…, Reveal in Finder and Delete…": nothing that fires.
        let titles = browser.itemMenu(for: browser.rows[0].tile.id, at: browser.rows[0]).titles
        XCTAssertFalse(titles.contains { $0.hasPrefix("Fire") }, "\(titles)")
        XCTAssertTrue(titles.contains("Reveal in Finder"), "\(titles)")
        // The filter menu holds show mode's kinds, its folders, Used in This List, Replaced and the sort.
        let filter = try XCTUnwrap(browser.filter.dropMenu).items.map(\.title)
        XCTAssertEqual(browser.filter.title, "All", "the button says what is filtered by; the menu lists only the choices")
        for word in ["All", "Video", "Image", "Audio", "All Media", "Used in this list", "Replaced", "Name", "Date Added"] {
            XCTAssertTrue(filter.contains(word), "\(word) in \(filter)")
        }
    }

    // MARK: - The cue grid (Spec 11 §4)

    func test_theGridSaysWhatEachHeaderAndCellHoldsAndAClickSelects() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        XCTAssertEqual(rig.view.workspace.title.stringValue, "Great Is Thy Faithfulness")
        XCTAssertEqual(rig.view.workspace.meta.stringValue, "4 cues · version 17")
        // VoiceOver's table: the cues' headers, then each channel's row with its cells.
        let spoken = grid.spoken
        XCTAssertEqual(spoken[0], "Cue 1, Verse 1, Go, live")
        XCTAssertEqual(spoken[2], "Cue 3, Verse 1, +8 s · adv 12 s")
        // Each row's name, then its eye (Spec 11 §4, corrected 2026-11-24), then its cells.
        XCTAssertEqual(spoken[4], "1 Background")
        XCTAssertEqual(spoken[5], "Hide 1 Background from the Preview")
        XCTAssertEqual(spoken[6], "Cue 1, channel 1 Background: writes dawn.mp4, Dissolve 1 second")
        XCTAssertEqual(spoken[7], "Cue 2, channel 1 Background: holds dawn.mp4 from cue 1")
        XCTAssertEqual(spoken[9], "Cue 4, channel 1 Background: holds dawn.mp4 from cue 1, -6 dB")
        XCTAssertEqual(spoken[10], "2 Foreground")
        XCTAssertEqual(spoken[16], "3 Clock, folded")
        XCTAssertEqual(spoken[18], "Cue 1, channel 3 Clock: holds nothing")
        // Opened on the live cue, on the text channel's row.
        XCTAssertEqual(rig.view.inspector.title.stringValue, "Cue 1 of 4")
        // A click on a cell selects its cue and channel; on a header, its cue and the header row.
        var at = middle(grid, cue: 2, row: 0)
        try click(grid, x: at.x, y: at.y)
        XCTAssertEqual(rig.model.editing.selection.ordered(in: c), [c[2]])
        XCTAssertEqual(rig.model.editing.selection.row, .channel(1))
        XCTAssertEqual(rig.view.inspector.title.stringValue, "Cue 3 of 4")
        at = middle(grid, cue: 3, row: nil)
        try click(grid, x: at.x, y: at.y, flags: .shift)
        XCTAssertEqual(rig.model.editing.selection.ordered(in: c), [c[2], c[3]], "⇧-click selects a range")
        XCTAssertEqual(rig.view.inspector.title.stringValue, "2 cues of 4")
        at = middle(grid, cue: 0, row: nil)
        try click(grid, x: at.x, y: at.y, flags: .command)
        XCTAssertEqual(rig.model.editing.selection.cues.count, 3, "⌘-click adds one")
        try click(grid, x: at.x, y: at.y)
        XCTAssertEqual(rig.model.editing.selection.row, .header)
        XCTAssertEqual(rig.model.editing.selection.channel, 1, "the inspector keeps the channel it showed")
        // The fold control, and the + after the last cue.
        try click(grid, x: 10, y: CueGridGeometry.band + grid.geometry.header + 10)
        XCTAssertEqual(rig.model.editing.grid.rows.map(\.isFolded), [true, false, true])
        XCTAssertEqual(rig.model.settings.foldedRows, [1: true])
        let plus = grid.geometry.x(cue: 4) + 20
        try click(grid, x: plus, y: CueGridGeometry.band + 20)
        XCTAssertTrue(last(rig)?.first?.hasPrefix("edit list 42 insert cues 4 {") ?? false, "\(rig.commands)")
        // The zoom: the header's slider, held to its range; below 96 points the headers' and tiles' text is dropped.
        rig.view.workspace.zoom.doubleValue = 80
        rig.view.workspace.zoom.sendAction(rig.view.workspace.zoom.action, to: rig.view.workspace.zoom.target)
        XCTAssertEqual(rig.model.settings.gridZoom, 80)
        XCTAssertFalse(grid.geometry.showsText)
        XCTAssertEqual(grid.geometry.column, 80)
    }

    func test_theArrowsAndDeleteAreTheGridsWhileItHasTheFocusAndEverythingElseIsTheShows() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        rig.window.window.makeFirstResponder(grid)
        // "the arrows move the selection in the grid, ⇧ extending it across cues": they never reach the bindings.
        for (code, flags) in [(UInt16(124), NSEvent.ModifierFlags()), (124, .shift), (125, []), (126, [])] {
            let event = try key(code, flags)
            XCTAssertFalse(rig.window.keyTap.take(event), "the bindings don't take key \(code)")
            grid.keyDown(with: event)
        }
        XCTAssertEqual(rig.model.editing.selection.ordered(in: c), [c[1], c[2]], "→ then ⇧→")
        XCTAssertEqual(rig.model.editing.selection.row, .channel(2), "↓ to channel 3's row, then ↑ back")
        XCTAssertTrue(rig.sent.filter { $0.type == "command" }.isEmpty, "stepping through cues never fires `next` or `previous`")
        // Delete on a channel's row "returns the selected cells to Hold".
        let delete = try key(51)
        XCTAssertFalse(rig.window.keyTap.take(delete))
        grid.keyDown(with: delete)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[1]) channel 2 hold", "edit list 42 cue \(c[2]) channel 2 hold"])
        // "while every other binding still fires: Space sends `next`, and ⇧⎋ clears all".
        XCTAssertTrue(rig.window.keyTap.take(try key(49)))
        XCTAssertEqual(last(rig), ["next"])
        XCTAssertTrue(rig.window.keyTap.take(try key(53, .shift)))
        XCTAssertEqual(last(rig), ["system clearall"])
        // "The Browser keeps show mode's keys": with the focus there, → fires its binding.
        rig.window.window.makeFirstResponder(rig.view)
        XCTAssertTrue(rig.window.keyTap.take(try key(124)))
        XCTAssertEqual(last(rig), ["next"])
        // Digits "fire cue N of the live list, whatever the page shows".
        rig.model.editing.choose(list: list7, from: .list(list7), item: nil)
        XCTAssertTrue(rig.window.keyTap.take(try key(20)))
        XCTAssertEqual(rig.view.programPanel.goTo.stringValue, "3", "the digits wait in the Program panel's field")
        XCTAssertEqual(rig.view.programPanel.line.stringValue, "Great Is Thy Faithfulness", "showing the live list's title")
        XCTAssertTrue(rig.window.keyTap.take(try key(36)))
        XCTAssertEqual(last(rig), ["cue 3"])
        // "Escape ... then leaves edit mode", and fires nothing.
        let before = count(rig)
        XCTAssertTrue(rig.window.keyTap.take(try key(53)))
        XCTAssertEqual(rig.model.mode, .edit, "the edits sent above wait for the engine's answer first")
        XCTAssertTrue(rig.window.keyTap.take(try key(53)))
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertEqual(count(rig), before)
        XCTAssertEqual(rig.model.browse.shown, .list(list7), "the grid browses where its list came from")
    }

    func test_aCuesMenuAndADropOnACell() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        // A cell's menu: "Write…, or Edit Content… on a write, then Clear and Hold, then the header's items".
        XCTAssertEqual(grid.menuNow.titles, ["Edit Content…", "Clear", "Hold", "Fire", "New Cue After", "Duplicate", "Duplicate Section", "Move Earlier",
                                             "Move Later", "Delete", "Open in Text Editor"])
        XCTAssertEqual(grid.menuNow.items.first { $0.title == "Open in Text Editor" }?.isEnabled, false, "until Area 10")
        try XCTUnwrap(grid.menuNow.entry("Clear")).choose()
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[0]) channel 2 clear"])
        rig.model.editing.click(cue: 2, row: .header)
        XCTAssertEqual(grid.menuNow.titles.first, "Fire", "a header's menu has no Write, Clear or Hold")
        try XCTUnwrap(grid.menuNow.entry("Fire")).choose()
        XCTAssertEqual(last(rig), ["item 2 cue 3"], "what a show-mode click sends where the list came from")
        try XCTUnwrap(grid.menuNow.entry("Move Earlier")).choose()
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[2]) move 1"])
        // "A media item dragged from the Browser onto a cell writes it there".
        let ocean = try XCTUnwrap(rig.store.media.first { $0.id.hasPrefix("sha256:9f2c") })
        XCTAssertTrue(grid.accept(.media(ocean.id), cue: 1, row: 0))
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[1]) channel 1 write media \(ocean.id) grade 1 once"])
        XCTAssertEqual(rig.model.editing.selection.row, .channel(1), "and the cell is selected")
        // A list dragged from the Library isn't something a cell takes.
        XCTAssertFalse(grid.accept(.list(list7), cue: 1, row: 0))
        // A file from the Finder "is imported, then written ... without the channel popover, since the cell names the channel".
        let before = count(rig)
        XCTAssertTrue(grid.accept(.files(["/Users/op/Desktop/ocean.mov"]), cue: 2, row: 0))
        XCTAssertNil(rig.view.picker, "no list of channels opens")
        XCTAssertEqual(count(rig), before + 1)
        XCTAssertTrue(last(rig)?.first?.hasPrefix("media import") ?? false, "\(last(rig) ?? [])")
        // Under the lock nothing is taken.
        try rig.lock()
        XCTAssertEqual(rig.model.mode, .show, "the lock closes edit mode")
    }

    // MARK: - The inspector (Spec 11 §4)

    func test_theInspectorsColumnsShowTheCueAndEachControlSendsItsEdit() throws {
        let rig = try editing()
        let inspector = rig.view.inspector
        rig.model.editing.click(cue: 3, row: .channel(1))
        XCTAssertEqual(inspector.title.stringValue, "Cue 4 of 4")
        XCTAssertEqual(inspector.fireNote.stringValue, "Fires in Sunday")
        XCTAssertEqual(inspector.labelField.stringValue, "Chorus")
        XCTAssertEqual(inspector.sectionField.stringValue, "Chorus")
        XCTAssertEqual(inspector.noteField.stringValue, "Build the lights here")
        XCTAssertEqual(inspector.goRadio.state, .on)
        XCTAssertEqual(inspector.timeField.stringValue, "")
        // The Channel column: the row's channel, its state, what it holds and the four chips.
        XCTAssertEqual(inspector.stateControl.selected, 2, "Hold")
        XCTAssertEqual(inspector.contentButton.title, "dawn.mp4 · From cue 1")
        XCTAssertEqual(inspector.chipButtons.map(\.title), ["+ Transition", "+ Audio transition", "+ Grade", "-6 dB · from here on"])
        // A field commits on Return: one edit.
        inspector.labelField.stringValue = "Refrain"
        inspector.labelField.sendAction(inspector.labelField.action, to: inspector.labelField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[3]) label \"Refrain\""])
        // The engine refuses it: the line says why, and the field is outlined.
        rig.answers[rig.answers.count - 1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "readOnlyLibrary", message: "no"))))
        XCTAssertFalse(inspector.notice.isHidden)
        XCTAssertEqual(inspector.notice.stringValue, EditWording.rejection(code: "readOnlyLibrary"))
        XCTAssertTrue(inspector.labelField.isRefused)
        XCTAssertEqual(inspector.labelField.stringValue, "Chorus", "the control is put back")
        // The trigger: Time after previous takes seconds to a tenth; Advance after, emptied, is none.
        rig.model.editing.click(cue: 2, row: .channel(1))
        XCTAssertEqual(inspector.timeRadio.state, .on)
        XCTAssertEqual(inspector.timeField.stringValue, "8")
        XCTAssertEqual(inspector.advanceField.stringValue, "12")
        inspector.timeField.stringValue = "2.5"
        inspector.timeField.sendAction(inspector.timeField.action, to: inspector.timeField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[2]) trigger { \"ms\": 2500, \"type\": \"time\" }"])
        inspector.advanceField.stringValue = ""
        inspector.advanceField.sendAction(inspector.advanceField.action, to: inspector.advanceField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[2]) advanceAfterMs null"])
        inspector.goRadio.performClick(nil)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[2]) trigger { \"type\": \"go\" }"])
        // The three-way control: Clear sends at once; Write opens the content popover and sends nothing yet.
        rig.model.editing.click(cue: 1, row: .channel(1))
        inspector.stateControl.segments[1].press()
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[1]) channel 1 clear"])
        let before = count(rig)
        inspector.stateControl.segments[0].press()
        XCTAssertEqual(count(rig), before, "Write on a held cell writes nothing until something is chosen")
        let content = try XCTUnwrap(rig.view.prompt, "the content popover")
        XCTAssertEqual(content.heading.stringValue, "Cue 2 · channel 1 Background")
        // A chip opens its small form; Save sends one edit.
        inspector.chipButtons[2].press()
        let chip = try XCTUnwrap(rig.view.prompt)
        XCTAssertEqual(chip.heading.stringValue, "Grade")
        chip.commit()
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[1]) channel 1 grade 0 hold"], "None is the form's first choice")
        // ‹ and › move the selection, never the pointer; Fire fires.
        inspector.next.press()
        XCTAssertEqual(inspector.title.stringValue, "Cue 3 of 4")
        inspector.fire.press()
        XCTAssertEqual(last(rig), ["item 2 cue 3"])
    }

    /// Spec 11 §4 as corrected 2026-11-24 — "an eye that hides the channel from the Preview monitor's picture alone ...
    /// its cells dim, the monitor's header says how many are hidden ("Hiding 2 channels")".
    func test_aRowsEyeHidesItsChannelFromThePreviewAndThePillSaysHowMany() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        let g = grid.geometry
        let eye = (x: CueGridGeometry.channelColumn - 6, y: g.y(row: 1) + g.rowHeight(1) / 2)
        XCTAssertTrue(rig.view.previewPanel.hiding.isHidden)
        try click(grid, x: eye.x, y: eye.y)
        XCTAssertEqual(rig.model.settings.hiddenRows, [2])
        XCTAssertFalse(rig.view.previewPanel.hiding.isHidden)
        XCTAssertEqual(rig.view.previewPanel.hiding.title, "Hiding 1 channel")
        XCTAssertTrue(grid.spoken.contains("2 Foreground, hidden from the Preview"), "\(grid.spoken)")
        XCTAssertTrue(grid.spoken.contains("Show 2 Foreground in the Preview"))
        XCTAssertEqual(count(rig), 0, "nothing goes to air")
        try click(grid, x: eye.x, y: eye.y)
        XCTAssertTrue(rig.view.previewPanel.hiding.isHidden)
        XCTAssertTrue(grid.spoken.contains("Hide 2 Foreground from the Preview"))
    }

    /// Spec 11 §2 as corrected 2026-11-24 — "The gaps beside the Browser, the monitors and the inspector drag to resize
    /// them ... `view.json` keeps the sizes."
    func test_theGapsDragToResizeTheBrowserTheMonitorsAndTheInspector() throws {
        let rig = try editing()
        let view = rig.view
        XCTAssertFalse(view.browserDivider.isHidden)
        let (browser, monitors, inspector) = (view.browser.frame.width, view.previewPanel.frame.width, view.inspector.frame.height)
        view.browserDivider.onBegin?()
        view.browserDivider.onDrag?(40)
        view.monitorsDivider.onBegin?()
        view.monitorsDivider.onDrag?(-30)
        view.inspectorDivider.onBegin?()
        view.inspectorDivider.onDrag?(-20)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.browser.frame.width, browser + 40)
        XCTAssertEqual(view.previewPanel.frame.width, monitors + 30, "dragged left, the monitors widen")
        XCTAssertEqual(view.inspector.frame.height, inspector + 20, "dragged up, the inspector grows")
        XCTAssertEqual(rig.model.settings.editBrowserWidth, Double(browser + 40))
        XCTAssertEqual(rig.model.settings.editMonitorsWidth, Double(monitors + 30))
        XCTAssertEqual(rig.model.settings.editInspectorHeight, Double(inspector + 20))
        // Show mode has none of them.
        rig.model.editing.leave()
        XCTAssertTrue(view.browserDivider.isHidden && view.monitorsDivider.isHidden && view.inspectorDivider.isHidden)
    }

    /// Spec 11 §4 as corrected 2026-11-24 — "A click on a band selects its run's cues", and "A drag that starts on a
    /// selected header, or on a band, moves every selected cue, in their order, as one group".
    func test_aBandSelectsItsCuesAndADragMovesEverySelectedCue() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        let g = grid.geometry
        // The band over cues 1 to 3, "Verse 1".
        try click(grid, x: g.x(cue: 1) + g.column / 2, y: CueGridGeometry.band / 2)
        XCTAssertEqual(rig.model.editing.selection.ordered(in: c), [c[0], c[1], c[2]])
        XCTAssertEqual(rig.model.editing.selection.row, .header)
        // A drag from one of the selected headers to the end moves all three, as one group.
        try drag(grid, from: middle(grid, cue: 1, row: nil), to: (g.x(cue: 3) + g.column - 1, CueGridGeometry.band + g.header / 2))
        let moved = try XCTUnwrap(last(rig))
        XCTAssertTrue(moved.allSatisfy { $0.contains(" move ") }, "\(moved)")
        for cue in c[0...2] { XCTAssertTrue(moved.contains { $0.contains(cue) }, "cue \(cue) moves with the others: \(moved)") }
        // A drag that starts on the band moves its cues too.
        let before = count(rig)
        try drag(grid, from: (g.x(cue: 0) + g.column / 2, CueGridGeometry.band / 2), to: (g.x(cue: 3) + g.column - 1, CueGridGeometry.band / 2))
        XCTAssertEqual(count(rig), before + 1)
        // A plain click on one of several selected headers, with no drag, selects it alone.
        rig.model.editing.clickBand(cue: 0)
        let one = middle(grid, cue: 1, row: nil)
        try click(grid, x: one.x, y: one.y)
        XCTAssertEqual(rig.model.editing.selection.ordered(in: c), [c[1]])
    }

    /// Spec 11 §2 and §4 as corrected 2026-11-24 — "Return opens the selected cell's content", the popover "hangs from
    /// that cell in the grid", the text has "the cursor at its end", and there "Return commits and closes the popover,
    /// ⇧Return makes a line".
    func test_returnOnACellOpensItsContentBesideItAndReturnInTheTextCommits() throws {
        let rig = try editing()
        let grid = rig.view.workspace.grid
        rig.window.window.makeFirstResponder(grid)
        rig.model.editing.click(cue: 0, row: .channel(2))
        let enter = try key(36)
        XCTAssertFalse(rig.window.keyTap.take(enter), "the focused grid takes Return")
        grid.keyDown(with: enter)
        let content = try XCTUnwrap(rig.view.prompt, "the content popover")
        XCTAssertTrue(rig.view.promptAnchor === grid, "it hangs from the cell, not from the inspector")
        let body = try XCTUnwrap(content.firstField as? CommandsTextView, "the text takes the focus")
        let typed = body.string
        XCTAssertFalse(typed.isEmpty)
        let before = count(rig)
        body.keyDown(with: try key(36, .shift))
        XCTAssertEqual(count(rig), before, "⇧Return makes a line and sends nothing")
        XCTAssertEqual(body.string.filter { $0 == "\n" }.count, typed.filter { $0 == "\n" }.count + 1)
        body.keyDown(with: try key(36))
        XCTAssertEqual(count(rig), before + 1, "Return commits")
        XCTAssertNil(rig.view.prompt, "and closes the popover")
        // The inspector's Content button opens it at the cell too.
        rig.view.inspector.contentButton.press()
        XCTAssertTrue(rig.view.promptAnchor === grid)
    }

    /// Adam's try of 2026-11-24: a label committed with Return was sent again as the old text a moment later, when the
    /// field lost the focus, because the window redrew from the library before the engine's answer came back.
    func test_aFieldSendsWhatWasTypedOnceAndNeverTheOldTextBack() throws {
        let rig = try editing()
        let inspector = rig.view.inspector
        rig.model.editing.click(cue: 3, row: .channel(1))
        inspector.labelField.stringValue = "Refrain"
        inspector.labelField.sendAction(inspector.labelField.action, to: inspector.labelField.target)
        XCTAssertEqual(last(rig), ["edit list 42 cue \(c[3]) label \"Refrain\""])
        let sent = count(rig)
        // A redraw before the engine's answer: the library still says "Chorus".
        inspector.refresh()
        XCTAssertEqual(inspector.labelField.stringValue, "Refrain", "the field keeps what it sent until the engine answers")
        // The field loses the focus with nothing typed since: nothing is sent.
        inspector.labelField.sendAction(inspector.labelField.action, to: inspector.labelField.target)
        XCTAssertEqual(count(rig), sent, "\(rig.commands)")
        // Another cue shows its own label.
        rig.model.editing.click(cue: 2, row: .channel(1))
        XCTAssertNotEqual(inspector.labelField.stringValue, "Refrain")
        // And a field left alone sends nothing when it loses the focus.
        inspector.noteField.sendAction(inspector.noteField.action, to: inspector.noteField.target)
        XCTAssertEqual(count(rig), sent, "\(rig.commands)")
    }

    func test_theCommandsColumnThePaletteAndCommandsAsText() throws {
        let rig = try editing()
        let inspector = rig.view.inspector
        rig.model.editing.choose(list: list7, from: .list(list7), item: nil)
        rig.model.editing.click(cue: 2, row: .header)
        let out = "77aa0000-0000-4000-8000-000000000003"
        // Doxology's last cue runs macro 1 between its channel commands: the one row of the column.
        XCTAssertEqual(inspector.commandRows.map { $0.name.stringValue }, [KeyWording.plain(.macro(1))])
        XCTAssertEqual(try XCTUnwrap(inspector.commandRows.first?.menuNow).titles, ["Edit…", "Move Up", "Move Down", "Remove"])
        try XCTUnwrap(inspector.commandRows.first?.menuNow?.entry("Remove")).choose()
        XCTAssertEqual(last(rig), ["edit list 7 cue \(out) remove commands 1"])
        // The palette: grouped by what they touch, only for what exists; a macro is added at once, at the end.
        var presented: [PromptView] = []
        let palette = EditPopovers.palette(model: rig.model, after: nil) { presented.append($0) }
        XCTAssertEqual(palette.items.map(\.title), ["Stacks and outputs", "Macros", "Timers", "Popups", "System"])
        let macros = try XCTUnwrap(palette.items[1].submenu)
        XCTAssertEqual(macros.titles, ["1 · Welcome", "2 · Preshow"])
        try XCTUnwrap(macros.items.first as? ClosureMenuItem).choose()
        XCTAssertEqual(last(rig), ["edit list 7 cue \(out) insert commands 3 { \"cmd\": \"macro.run\", \"macro\": 1 }"])
        // One that needs asking opens a small form with pickers; Add inserts it.
        try XCTUnwrap(palette.items[0].submenu?.entry("Black Out a Stack…")).choose()
        let form = try XCTUnwrap(presented.last)
        XCTAssertEqual(form.heading.stringValue, "Black Out a Stack")
        XCTAssertEqual(form.save.title, "Add")
        form.commit()
        XCTAssertEqual(last(rig), ["edit list 7 cue \(out) insert commands 3 { \"cmd\": \"stack.blackout\", \"stack\": 1, \"state\": \"on\" }"])
        // Commands as text: the cue's whole list, a line a command; an error keeps it from being sent.
        inspector.asText.performClick(nil)
        XCTAssertTrue(inspector.showsText)
        XCTAssertEqual(inspector.textArea.string, "channel 2 clear\nmacro 1\nchannel 1 write slide:51de0000-0000-4000-8000-000000000001 build 2")
        inspector.textArea.string = "channel 2 clear\nmacro banana"
        inspector.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertTrue(inspector.textErrors.stringValue.hasPrefix("Line 2: "), inspector.textErrors.stringValue)
        let before = count(rig)
        inspector.textArea.onCommit?()
        XCTAssertEqual(count(rig), before, "with an error, nothing is sent")
        inspector.textArea.string = "channel 2 clear\nmacro 2"
        inspector.textDidChange(Notification(name: NSText.didChangeNotification))
        XCTAssertEqual(inspector.textErrors.stringValue, "")
        inspector.textArea.onCommit?()
        XCTAssertEqual(count(rig), before + 1)
        XCTAssertEqual(last(rig)?.first?.hasPrefix("edit list 7 cue \(out) commands ["), true, "\(last(rig) ?? [])")
    }

    // MARK: - The monitors (Spec 11 §2, §4)

    func test_previewAsksTheEngineForItsPictureAndProgramKeepsTheShowRunning() throws {
        let rig = try editing()
        // "from `render` with `subject.kind` `cue` at the monitor's width in pixels, on the stack its picker names".
        let asked = rig.sent.filter { $0.fields["what"] == .string("render") }
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked[0].fields["subject"]?["cue"], .string(c[0]))
        XCTAssertEqual(asked[0].fields["subject"]?["stack"], .number(1))
        let scale = rig.view.window?.backingScaleFactor ?? 2
        XCTAssertEqual(asked[0].fields["width"], .number(Double(Int((rig.view.previewPanel.picture.frame.width * scale).rounded()))))
        XCTAssertEqual(rig.view.previewPanel.picker.titleOfSelectedItem, "Stack 1 · Main")
        XCTAssertEqual(rig.view.previewPanel.picker.itemTitles, ["Stack 1 · Main", "Stack 2 · Confidence"])
        // Program: the same stack, with the outputs that show it; the picker changes both.
        let program = rig.view.programPanel
        XCTAssertEqual(program.pill.title, "On air · Out 1")
        XCTAssertEqual(program.line.stringValue, "Sunday · Great Is Thy Faithfulness · 1 Verse 1")
        rig.view.previewPanel.picker.selectItem(withTag: 2)
        rig.view.previewPanel.picker.sendAction(rig.view.previewPanel.picker.action, to: rig.view.previewPanel.picker.target)
        XCTAssertEqual(rig.model.previewStack, 2)
        XCTAssertEqual(program.pill.title, "Preview only")
        XCTAssertEqual(rig.sent.filter { $0.fields["what"] == .string("render") }.last?.fields["subject"]?["stack"], .number(2))
        // "the go-to field ... fires cue N of the live list ...; Next (`next`) ...; and Clear All (`system clearall`)".
        program.go(to: "3")
        XCTAssertEqual(last(rig), ["cue 3"])
        program.next.press()
        XCTAssertEqual(last(rig), ["next"])
        program.clearAll.press()
        XCTAssertEqual(last(rig), ["system clearall"])
        XCTAssertTrue(program.next.isEnabled)
    }

    // MARK: - The lock (Spec 11 §2)

    func test_theLockClosesEditModeAndDisablesEveryWayIn() throws {
        let rig = try editing()
        try rig.lock()
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(rig.model.mode, .show)
        XCTAssertTrue(rig.view.inspector.isHidden)
        XCTAssertFalse(rig.view.topBar.edit.isEnabled)
        XCTAssertNotNil(rig.view.topBar.edit.reason)
        rig.view.enterEdit()
        rig.view.enterEdit(page: .stacks)
        XCTAssertEqual(rig.model.mode, .show)
        let cell = try rig.cell("Verse 1")
        XCTAssertEqual(rig.view.grid.cueMenu(for: cell).items.first { $0.title == "Edit Cue" }?.isEnabled, false)
    }

    // MARK: - A macro tile's menu, and a list deleted under the page

    func test_aMacroTilesMenuRunsItAndOpensEditModeOnObjects() throws {
        let rig = try Rig()
        rig.view.tabs.show(.macros)
        // "A tile's menu: Run; Bind a Key… ...; Edit (edit mode's macro editor ...)" (Spec 10 §7).
        let menu = rig.view.tabs.macroMenu(1)
        XCTAssertEqual(menu.titles, ["Run", "Bind a Key…", "Edit"])
        XCTAssertEqual(menu.items.map(\.isEnabled), [true, false, true], "key bindings are a later area's")
        try XCTUnwrap(menu.entry("Run")).choose()
        XCTAssertEqual(last(rig), ["macro 1"])
        try XCTUnwrap(menu.entry("Edit")).choose()
        XCTAssertEqual(rig.model.mode, .edit)
        XCTAssertEqual(rig.model.editing.page, .objects, "Edit on a macro tile opens Objects")
        XCTAssertEqual(rig.model.editing.selectedObject, ObjectKey(.macro, 1), "on that macro")
        // Under the lock Edit is disabled with the reason; Run is a show command, which the lock leaves alone.
        try rig.lock()
        XCTAssertEqual(rig.view.tabs.macroMenu(1).items.map(\.isEnabled), [true, false, false])
        XCTAssertNotNil(rig.view.tabs.macroMenu(1).items.last?.toolTip)
    }

    func test_aListDeletedUnderThePageSaysSo() throws {
        let rig = try editing()
        rig.model.editing.choose(list: list7, from: .list(list7), item: nil)
        XCTAssertFalse(rig.view.workspace.grid.isHidden)
        // Another station deletes the list: "A page whose object is deleted under it says "Deleted"".
        var catalog = try ShowWindowTests.Rig.load("catalog")
        catalog["lists"] = .array((catalog["lists"]?.arrayValue ?? []).filter { $0["uuid"] != .string(list7) })
        rig.store.apply(catalog: catalog)
        XCTAssertTrue(rig.view.workspace.grid.isHidden)
        XCTAssertEqual(rig.view.workspace.message.stringValue, "Deleted")
        XCTAssertTrue(rig.view.workspace.undo.isHidden, "Undo shows only while that delete is the history's top group")
    }

    // MARK: - The Stacks page (Spec 11 §6)

    /// Spec 11 §2 and §6, G-30 as corrected 2026-11-24 — the stacks in the page's list with New Stack as its + row; the
    /// workspace's two tall columns, the slots with Add Channel and the stack's fields, then the outputs and the audio
    /// routing; no inspector.
    func test_theStacksPageShowsTheStackAndEachControlSendsItsEdit() throws {
        let rig = try editing()
        let view = rig.view
        rig.model.editing.show(page: .stacks)
        view.layoutSubtreeIfNeeded()
        // "The Stacks, Channels, Presets and Objects pages put their own list in its place"; "the Stacks and Channels
        // pages have none" (an inspector).
        XCTAssertTrue(view.browser.isHidden)
        XCTAssertFalse(view.pageList.isHidden)
        XCTAssertTrue(view.inspector.isHidden)
        XCTAssertTrue(view.presetInspector.isHidden)
        XCTAssertTrue(view.inspectorDivider.isHidden)
        XCTAssertEqual(view.workspace.frame.maxY, view.programPanel.frame.maxY, accuracy: 0.5, "the workspace runs to the window's foot")
        let list = view.pageList
        XCTAssertEqual(list.title.stringValue, "Stacks")
        let rows = try XCTUnwrap(list.sections.first?.rows)
        XCTAssertEqual(rows.map(\.name.stringValue), ["Main", "Confidence"])
        XCTAssertEqual(rows.map(\.isLive), [true, false], "the live dot on what is on air")
        XCTAssertEqual(rows.map(\.isSelected), [true, false], "the stack output 1 shows")
        XCTAssertEqual(list.sections.first?.add.title, "+  New Stack")
        XCTAssertEqual(view.workspace.title.stringValue, "1 Main")
        // A row's ⋯ lists only its choices: Delete is refused while an output shows the stack.
        let rowMenu = try XCTUnwrap(rows[0].more.dropMenu)
        XCTAssertEqual(rowMenu.items.filter { !$0.isSeparatorItem }.map(\.title), ["Duplicate", "Renumber…", "Delete…"])
        XCTAssertEqual(rowMenu.items.last?.isEnabled, false)
        // The slots, top first, the opacity's slider with a field beside it.
        let stacks = view.workspace.stacks
        XCTAssertEqual(stacks.rows.map(\.name.stringValue), ["Foreground", "Background"])
        XCTAssertEqual(stacks.rows.first?.percent.stringValue, "100%")
        stacks.rows[0].preset.choose(tag: 1)
        XCTAssertEqual(last(rig), ["edit stack 1 slot 2 preset 1"])
        stacks.rows[1].percent.stringValue = "50"
        stacks.rows[1].percent.sendAction(stacks.rows[1].percent.action, to: stacks.rows[1].percent.target)
        XCTAssertEqual(last(rig), ["edit stack 1 slot 1 opacity 0.5"])
        stacks.rows[1].opacity.doubleValue = 0.25
        stacks.rows[1].opacity.sendAction(stacks.rows[1].opacity.action, to: stacks.rows[1].opacity.target)
        XCTAssertEqual(last(rig), ["edit stack 1 slot 1 opacity 0.25"])
        XCTAssertEqual(stacks.rows[0].more.dropMenu?.items.first?.title, "Move Up", "a slot's ⋯ lists only its choices")
        // The stack's own fields.
        stacks.base.segments[1].press()
        XCTAssertEqual(last(rig), ["edit stack 1 base \"transparent\""])
        stacks.gamma.toggle()
        XCTAssertEqual(last(rig), ["edit stack 1 gammaBlend true"])
        // "Add Channel, offers the library's channels the stack doesn't hold"; one chosen adds a slot at the top, asking
        // first on a stack an output shows.
        let add = try XCTUnwrap(stacks.addChannel.dropMenu)
        XCTAssertEqual(add.items.map(\.title), ["3 Clock"])
        var asked: [Confirmation] = []
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(true)
        }
        add.performActionForItem(at: 0)
        XCTAssertEqual(asked, [.slotOnAir(channel: 3, label: "Clock", outputs: [1], adding: true)])
        XCTAssertEqual(last(rig), ["edit stack 1 insert slots 2 { \"channel\": 3, \"mute\": false, \"opacity\": 1, \"preset\": null }"])
        // The second column: the outputs, then the stacks none shows; the selected output; the audio routing.
        let outputs = stacks.outputs
        XCTAssertEqual(outputs.outputRows.map(\.title), ["1 Main · stack 1"], "as the top bar's outputs menu says it")
        XCTAssertEqual(outputs.stackRows.map(\.title), ["2 Confidence"])
        XCTAssertEqual(outputs.defaultStack.titleOfSelectedItem, "1 Main")
        outputs.defaultStack.choose(tag: 2)
        XCTAssertEqual(last(rig), ["edit output 1 defaultStack 2"])
        XCTAssertEqual(outputs.audioBoxes.map { $0.map(\.state) }.first, [.on, .off])
        outputs.audioBoxes[0][1].toggle()
        XCTAssertEqual(last(rig), ["edit channel 1 audioOutputs [1, 2]"])
        // A click on a row selects its stack; the + row adds one.
        rows[1].onSelect?()
        XCTAssertEqual(view.workspace.title.stringValue, "2 Confidence")
        XCTAssertEqual(stacks.rows.map(\.name.stringValue), ["Clock", "Foreground"])
        list.sections[0].add.press()
        XCTAssertEqual(last(rig), ["edit stack create"])
        // Back to the Cues page: the Browser, and its inspector under the workspace.
        rig.model.editing.show(page: .cues)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.browser.isHidden)
        XCTAssertTrue(view.pageList.isHidden)
        XCTAssertFalse(view.inspector.isHidden)
        XCTAssertTrue(view.workspace.stacks.isHidden)
        XCTAssertFalse(view.workspace.grid.isHidden)
    }

    // MARK: - The Channels page (Spec 11 §7)

    /// Spec 11 §7 and G-31 as corrected 2026-11-24 — the channels in the page's list with New Channel as its + row; the
    /// channel's form in one tall column, the stacks that hold it beside it; no inspector.
    func test_theChannelsPageListsTheChannelsAndTheFormSendsEachField() throws {
        let rig = try editing()
        let view = rig.view
        rig.model.editing.show(page: .channels)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.pageList.isHidden)
        XCTAssertTrue(view.inspector.isHidden)
        let list = view.pageList
        let rows = try XCTUnwrap(list.sections.first?.rows)
        XCTAssertEqual(rows.map(\.name.stringValue), ["Background", "Foreground", "Clock"])
        XCTAssertEqual(rows.map(\.detail.stringValue), ["Media · stacks 1", "Text · stacks 1, 2", "Any · stacks 2"])
        XCTAssertEqual(rows.map(\.isLive), [true, true, false], "channels 1 and 2 hold content in stack 1, on output 1")
        XCTAssertEqual(list.sections.first?.add.title, "+  New Channel")
        let sheet = view.workspace.channels
        XCTAssertFalse(sheet.isHidden)
        // A click on a row selects its channel; the Preview's picker follows.
        rows[2].onSelect?()
        XCTAssertEqual(rig.model.editing.sheetChannel, 3)
        XCTAssertEqual(rows.map(\.isSelected), [false, false, true])
        XCTAssertEqual(view.workspace.title.stringValue, "3 Clock")
        XCTAssertEqual(view.previewPanel.picker.titleOfSelectedItem, "3 Clock")
        XCTAssertEqual(sheet.label.stringValue, "Clock")
        XCTAssertEqual(sheet.number.stringValue, "3")
        // Each field is an `edit.set` on commit.
        sheet.label.stringValue = "Timer"
        sheet.label.sendAction(sheet.label.action, to: sheet.label.target)
        XCTAssertEqual(last(rig), ["edit channel 3 label \"Timer\""])
        sheet.usual.segments[1].press()
        XCTAssertEqual(last(rig), ["edit channel 3 usualContent \"text\""])
        sheet.decoderCap.segments[2].press()
        XCTAssertEqual(last(rig), ["edit channel 3 decoderCap 3"])
        sheet.gain.stringValue = "-6 dB"
        sheet.gain.sendAction(sheet.gain.action, to: sheet.gain.target)
        XCTAssertEqual(last(rig), ["edit channel 3 defaults.gain -6"])
        // Custom render size shows the width and height and sends nothing until they are given.
        let before = count(rig)
        XCTAssertTrue(sheet.width.isHidden)
        sheet.renderSize.segments[1].press()
        XCTAssertEqual(count(rig), before)
        XCTAssertFalse(sheet.width.isHidden)
        sheet.width.stringValue = "1280"
        sheet.height.stringValue = "720"
        sheet.height.sendAction(sheet.height.action, to: sheet.height.target)
        XCTAssertEqual(last(rig), ["edit channel 3 renderSize { \"height\": 720, \"width\": 1280 }"])
        // The number: "Before it sends, a popover says what doesn't follow".
        sheet.number.stringValue = "7"
        sheet.number.sendAction(sheet.number.action, to: sheet.number.target)
        let panel = try XCTUnwrap(view.prompt)
        XCTAssertEqual(panel.heading.stringValue, "Renumber channel 3 to 7?")
        XCTAssertEqual(panel.save.title, "Renumber")
        panel.commit()
        XCTAssertEqual(last(rig), ["edit channel 3 renumber 7"])
        // Beside the form: the stacks that hold it, with Remove; Add to Stack, the + row, offers the others at their top.
        let holders = sheet.holders
        XCTAssertEqual(holders.holderNames.map(\.stringValue), ["2 Confidence"])
        let add = try XCTUnwrap(holders.addToStack.dropMenu)
        XCTAssertEqual(add.items.map(\.title), ["1 Main"], "the menu lists only its choices")
        var asked: [Confirmation] = []
        rig.model.confirm = { confirmation, answer in
            asked.append(confirmation)
            answer(true)
        }
        add.performActionForItem(at: 0)
        XCTAssertEqual(asked, [.slotOnAir(channel: 3, label: "Clock", outputs: [1], adding: true)], "stack 1 is on output 1")
        XCTAssertEqual(last(rig), ["edit stack 1 insert slots 2 { \"channel\": 3, \"mute\": false, \"opacity\": 1, \"preset\": null }"])
        holders.removeButtons[0].press()
        XCTAssertEqual(last(rig), ["edit stack 2 slot 3 remove"])
        // Channel 1 holds dawn.mp4 on output 1: its row's Delete is refused, and its number is refused before anything
        // is asked, the header's notice line saying why.
        XCTAssertEqual(rows[0].more.dropMenu?.items.last?.isEnabled, false)
        rows[0].onSelect?()
        let sent = count(rig)
        sheet.number.stringValue = "9"
        sheet.number.sendAction(sheet.number.action, to: sheet.number.target)
        XCTAssertEqual(count(rig), sent)
        XCTAssertFalse(view.workspace.notice.isHidden)
        XCTAssertEqual(view.workspace.notice.stringValue, EditWording.rejection(code: "onAir"))
        XCTAssertEqual(sheet.number.stringValue, "1", "the field is put back")
        // The + row adds a channel.
        list.sections[0].add.press()
        XCTAssertEqual(last(rig), ["edit channel create"])
    }

    // MARK: - The Presets page (Spec 11 §8)

    /// Spec 11 §8 and G-32 as corrected 2026-11-24 — the presets and the boxes in the page's list, each with its + row;
    /// the layout tabs and the canvas, whose boxes select, nudge and drag; the inspector's three columns, the box's
    /// properties with its reference point, its text style, and the preset.
    func test_thePresetsPageShowsTheLayoutAndEachControlSendsItsEdit() throws {
        let rig = try editing()
        let view = rig.view
        rig.model.editing.show(page: .presets)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.presetInspector.isHidden)
        XCTAssertTrue(view.inspector.isHidden)
        XCTAssertFalse(view.pageList.isHidden)
        let list = view.pageList
        XCTAssertEqual(list.sections.count, 2)
        XCTAssertEqual(list.sections[0].rows.map(\.name.stringValue), ["Default", "Clock", "Lower third", "Credits"])
        XCTAssertEqual(list.sections[0].add.title, "+  New Preset")
        XCTAssertEqual(list.sections[0].rows[0].more.dropMenu?.items.last?.isEnabled, false, "Preset 1 can't be deleted")
        let page = view.workspace.presets
        XCTAssertFalse(page.isHidden)
        XCTAssertEqual(view.workspace.title.stringValue, "1 Default")
        // "a tab for the `*` layout and one per stack this machine has, each naming the stacks it draws on this machine
        // ..., with the live dot on those an output shows".
        XCTAssertEqual(page.tabs.map(\.title), ["● Any stack: 1 Main", "● 1 Main", "2 Confidence"])
        XCTAssertEqual(page.layoutNote.stringValue, "Drawn at 1 Main")
        let render = try XCTUnwrap(rig.sent.last { $0.fields["what"] == .string("render") && $0.fields["canvas"] == .string("layout") })
        XCTAssertEqual(render.fields["subject"]?.objectValue?["layout"], .string("*"))
        // A click selects the topmost box under it: the body box over the full-frame pixel box.
        let canvas = page.canvas
        let middle = canvas.rect(of: Frame(x: 0.5, y: 0.5, w: 0, h: 0)).origin
        canvas.press(at: middle)
        canvas.release()
        XCTAssertEqual(rig.model.editing.presetState.box, 1)
        let boxes = list.sections[1]
        XCTAssertEqual(boxes.rows.map(\.name.stringValue), ["body", "pixels"])
        XCTAssertEqual(boxes.rows.map(\.isSelected), [true, false])
        // ⇧→ nudges by ten pixels of the stack, sent once when the key is released.
        let before = count(rig)
        canvas.keyDown(with: try key(124, .shift))
        canvas.keyDown(with: try key(124, .shift))
        XCTAssertEqual(count(rig), before, "nothing until the key is released")
        let up = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        canvas.keyUp(with: up)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.frame { \"h\": 0.8, \"w\": 0.9, \"x\": 0.0604, \"y\": 0.1 }"])
        // The box's properties.
        let inspector = view.presetInspector
        inspector.offset.segments[1].press()
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.offset 1"])
        inspector.frameW.stringValue = "50"
        inspector.frameW.sendAction(inspector.frameW.action, to: inspector.frameW.target)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.frame { \"h\": 0.8, \"w\": 0.5, \"x\": 0.05, \"y\": 0.1 }"], "about the top left")
        // The reference point: X and Y say where the centre sits, and a new width keeps it in place.
        inspector.anchor.choose(.center)
        XCTAssertEqual(rig.model.settings.boxAnchor, .center)
        XCTAssertEqual(inspector.frameX.stringValue, "50")
        XCTAssertEqual(inspector.frameY.stringValue, "50")
        inspector.frameW.stringValue = "60"
        inspector.frameW.sendAction(inspector.frameW.action, to: inspector.frameW.target)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.frame { \"h\": 0.8, \"w\": 0.6, \"x\": 0.2, \"y\": 0.1 }"], "about the centre")
        inspector.anchor.choose(.topLeft)
        inspector.fallback.toggle()
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.fallback false"])
        // Spec 11 §8 as corrected 2026-11-25 — "Channel's, which a new box takes, or cut or dissolve ... as the box's
        // own": Preset 1's body box takes the channel's; a dissolve chosen is its own, and Channel's takes it back.
        XCTAssertEqual(inspector.transition.titleOfSelectedItem, "Channel’s")
        XCTAssertTrue(inspector.transitionMs.isHidden, "no duration of its own while it takes the channel's")
        inspector.transition.choose(tag: 2)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.transition { \"ms\": null, \"ref\": 2 }"])
        inspector.transition.choose(tag: 0)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.transition null"])
        // Its text style.
        XCTAssertTrue(inspector.fromStyle.stringValue.hasPrefix("From 1 Body"), inspector.fromStyle.stringValue)
        XCTAssertEqual(inspector.applyStyle.dropMenu?.items.map(\.title), ["1 Body", "2 Caption"], "the menu lists only its choices")
        inspector.allCaps.toggle()
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.textStyle.allCaps true"])
        inspector.size.stringValue = "60"
        inspector.size.sendAction(inspector.size.action, to: inspector.size.target)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.textStyle.size.value 60"])
        inspector.align.segments[0].press()
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.textStyle.alignment \"left\""])
        inspector.color.choose(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.textStyle.color { \"a\": 1, \"b\": 0, \"g\": 0, \"r\": 1 }"])
        // A drag moves the box: past the edge, it stops at it.
        let stack = canvas.stackRect
        canvas.press(at: middle)
        canvas.drag(to: NSPoint(x: middle.x + stack.width * 0.1, y: middle.y), snapping: false)
        canvas.release()
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.frame { \"h\": 0.8, \"w\": 0.9, \"x\": 0.1, \"y\": 0.1 }"])
        // The pixel box has no text style.
        boxes.rows[1].onSelect?()
        XCTAssertFalse(inspector.noStyle.isHidden)
        XCTAssertTrue(inspector.size.isHidden)
        // The boxes' + row, Add Box, offers Pixels, Field ▸ and Static Text, and inserts at the top.
        let addBox = try XCTUnwrap(boxes.add.dropMenu)
        XCTAssertEqual(addBox.items.map(\.title), ["Pixels", "Field", "Static Text"])
        addBox.performActionForItem(at: 0)
        XCTAssertEqual(last(rig)?.first?.hasPrefix("edit preset 1 insert layouts.*.boxes 2 {"), true)
        // A box row dropped above the top moves it there: the pixel box, at the bottom, to the top of two.
        list.drop(0, inList: 1, atRow: 0)
        XCTAssertEqual(last(rig), ["edit preset 1 move layouts.*.boxes 0 1"])
        // Stack 1's tab uses the * layout, and offers Copy from *.
        page.tabs[1].press()
        XCTAssertEqual(page.layoutNote.stringValue, "Uses the * layout")
        XCTAssertFalse(page.copyFromAny.isHidden)
        XCTAssertFalse(list.sections[1].add.isEnabled)
        page.copyFromAny.press()
        XCTAssertEqual(last(rig)?.first?.hasPrefix("edit preset 1 layouts.1 { \"boxes\": ["), true)
        // The sample: Empty asks for the picture again with nothing in the channel.
        page.tabs[0].press()
        page.sampleKind.segments[2].press()
        let empty = try XCTUnwrap(rig.sent.last { $0.fields["what"] == .string("render") })
        XCTAssertEqual(empty.fields["subject"]?.objectValue?["sample"], .object(["content": .object(["kind": .string("empty")])]))
        // A click on a preset in the list picks it.
        list.sections[0].rows[1].onSelect?()
        XCTAssertEqual(view.workspace.title.stringValue, "2 Clock")
        XCTAssertEqual(page.tabs.map(\.title), ["● Any stack: 1 Main, 2 Confidence", "● 1 Main", "2 Confidence"])
        XCTAssertEqual(list.sections[1].rows.map(\.name.stringValue), ["static · [Time]"])
    }

    // MARK: - The Objects page (Spec 11 §9)

    /// Spec 11 §9 — the groups in the page's list, + rows but for Transitions; each editor in the workspace with what
    /// every object shares beside it; the Preview showing a grade beside the item without it, or a transition's curve.
    func test_theObjectsPageListsTheGroupsAndEachEditorSendsItsEdit() throws {
        let rig = try editing()
        let view = rig.view
        let editing = rig.model.editing
        editing.show(page: .objects)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.inspector.isHidden)
        XCTAssertTrue(view.presetInspector.isHidden)
        XCTAssertTrue(view.browser.isHidden)
        let list = view.pageList
        XCTAssertFalse(list.isHidden)
        XCTAssertEqual(list.sections.map(\.heading.stringValue), ["GRADES", "TRANSITIONS", "AUDIO TRANSITIONS", "TEXT STYLES", "MACROS"])
        XCTAssertEqual(list.sections.map { $0.rows.map(\.name.stringValue) }, [["Warm"], ["Cut", "Dissolve", "Fade through black"],
                                                                             ["Cut", "Crossfade", "Fade through silence"], ["Body", "Caption"], ["Welcome", "Preshow"]])
        XCTAssertEqual(list.sections.map(\.add.isHidden), [false, true, false, false, false], "no + for transitions")
        XCTAssertEqual(list.sections[0].add.title, "+  New Grade")
        XCTAssertNil(list.sections[1].rows[0].more.dropMenu, "a transition has no menu")
        XCTAssertEqual(list.sections[0].rows[0].more.dropMenu?.items.map(\.title), ["Duplicate", "Renumber…", "", "Delete…"])
        let page = view.workspace.objects
        XCTAssertFalse(page.isHidden)
        XCTAssertEqual(view.workspace.title.stringValue, "Grade 1 Warm")
        // A grade: its sliders and fields, each one edit; its picture beside the item without it.
        XCTAssertEqual(page.sliders[.brightness]?.doubleValue ?? 0, 95, accuracy: 1e-9)
        XCTAssertEqual(page.gradeFields[.contrast]?.stringValue, "110")
        page.sliders[.brightness]?.release(at: 120)
        XCTAssertEqual(last(rig), ["edit grade 1 brightness 0.2"])
        let opacity = try XCTUnwrap(page.gradeFields[.opacity])
        opacity.stringValue = "50"
        opacity.sendAction(opacity.action, to: opacity.target)
        XCTAssertEqual(last(rig), ["edit grade 1 opacity 0.5"])
        let renders = rig.sent.filter { $0.fields["what"] == .string("render") }.map { $0.fields["canvas"] }
        XCTAssertTrue(renders.contains(.string("grade")) && renders.contains(.string("ungraded")), "\(renders)")
        XCTAssertFalse(view.previewPanel.graded.isHidden)
        XCTAssertEqual(view.previewPanel.picker.numberOfItems, editing.gradeMediaChoices.count, "the item picked under the preview")
        XCTAssertEqual(page.number.stringValue, "1")
        XCTAssertTrue(page.number.isEnabled)
        // A transition: duration and easing only, its number fixed; the Preview draws its curve.
        list.sections[1].rows[1].onSelect?()
        XCTAssertEqual(view.workspace.title.stringValue, "Transition 2 Dissolve")
        XCTAssertFalse(page.number.isEnabled)
        XCTAssertFalse(page.fixedNote.isHidden)
        XCTAssertTrue(page.sliders[.brightness]?.isHidden ?? false)
        page.ms.stringValue = "750"
        page.ms.sendAction(page.ms.action, to: page.ms.target)
        XCTAssertEqual(last(rig), ["edit transition 2 ms 750"])
        page.easing.choose(tag: 2)
        XCTAssertEqual(last(rig), ["edit transition 2 easing \"easeOut\""])
        XCTAssertFalse(view.previewPanel.curve.isHidden)
        XCTAssertEqual(view.previewPanel.curve.caption.stringValue, "Ease in and out over 0.5 s", "the recorded dissolve, until the library event")
        // An audio transition: its type and its offset.
        list.sections[2].rows[1].onSelect?()
        XCTAssertFalse(page.offset.isHidden)
        page.offset.stringValue = "-250"
        page.offset.sendAction(page.offset.action, to: page.offset.target)
        XCTAssertEqual(last(rig), ["edit audiotransition 2 offsetMs -250"])
        page.audioType.choose(tag: 2)
        XCTAssertEqual(last(rig), ["edit audiotransition 2 type \"fadeThroughSilence\""])
        // A text style: the style form, and Re-apply to Boxes with how many name it.
        list.sections[3].rows[0].onSelect?()
        XCTAssertFalse(page.style.size.isHidden)
        page.style.size.stringValue = "60"
        page.style.size.sendAction(page.style.size.action, to: page.style.size.target)
        XCTAssertEqual(last(rig), ["edit textstyle 1 size.value 60"])
        XCTAssertFalse(page.reapply.isHidden)
        XCTAssertTrue(page.reapply.isEnabled)
        XCTAssertFalse(view.previewPanel.caption.isHidden, "no picture for a style")
        // A macro: its commands, the palette with a Channels group, the scope, the tile.
        list.sections[4].rows[0].onSelect?()
        XCTAssertEqual(page.commands.rows.count, 4)
        XCTAssertEqual(page.scope.stringValue, Strings.text(.editObjectScopeLibrary))
        let palette = page.commands.paletteNow
        XCTAssertEqual(palette.items.first?.title, "Channels")
        XCTAssertEqual(palette.items.first?.submenu?.items.map(\.title),
                       ["Write Media…", "Write Text…", "Clear…", "Reset…", "Grade…", "Transition…", "Audio Transition…", "Gain…"])
        let rowMenu = try XCTUnwrap(page.commands.rows[0].menuNow)
        XCTAssertEqual(rowMenu.items.map(\.title), ["Edit…", "Move Up", "Move Down", "Remove"])
        rowMenu.performActionForItem(at: 2)
        XCTAssertEqual(last(rig), ["edit macro 1 move commands 0 1"])
        page.tileLabel.stringValue = "Hi"
        page.tileLabel.sendAction(page.tileLabel.action, to: page.tileLabel.target)
        XCTAssertEqual(last(rig), ["edit macro 1 tileLabel \"Hi\""])
        list.sections[4].rows[1].onSelect?()
        XCTAssertEqual(page.scope.stringValue, Strings.text(.editObjectScopeMachine), "Preshow names an output and a stack")
        // The + row of a group makes one.
        list.sections[2].add.press()
        XCTAssertEqual(last(rig), ["edit audiotransition create"])
    }

    // MARK: - Accessibility and strings (Spec 11 §10)

    /// Spec 11 §10 — "Spec 10 §15 holds in edit mode, from the first build": on every page, every control has a label,
    /// and at 1440 by 900, under the accented pseudolanguage and one 40% longer, nothing of the app's own wording is
    /// clipped (Spec 10 §18). A label that holds what the operator or the library wrote is marked, and may truncate.
    func test_everyEditPageLabelsItsControlsAndClipsNothingUnderEitherPseudolanguage() throws {
        let plain: (String) -> String = { $0 }
        for (index, transform) in [plain, Pseudolanguage.accented, Pseudolanguage.longer].enumerated() {
            try ViewStrings.install(transform: transform)
            let rig = try editing()
            let view = rig.view
            func check(_ what: String) {
                view.refreshAll()
                view.layoutSubtreeIfNeeded()
                if index == 0 { XCTAssertEqual(Audit.unlabelled(in: view), [], "every control has a label (\(what))") }
                for button in Audit.all(FlatButton.self, in: view) where button.frame.width > 0 {
                    XCTAssertTrue(button.titleFits, "\"\(button.title)\" is clipped (\(what))")
                }
                for label in Audit.all(NSTextField.self, in: view)
                where !label.isEditable && label.tag != Kit.mayTruncate && label.maximumNumberOfLines == 1 && label.frame.width > 0 {
                    XCTAssertFalse(Audit.isCutOff(label), "\"\(label.stringValue)\" is clipped: \(label.frame.width) of \(Kit.width(of: label)) points (\(what))")
                }
            }
            rig.model.editing.click(cue: 2, row: .channel(2))
            check("cues")
            rig.model.editing.show(page: .stacks)
            check("stacks")
            rig.model.editing.show(page: .channels)
            check("channels")
            rig.model.editing.show(page: .presets)
            rig.model.editing.selectBox(1)
            check("presets, a text box")
            rig.model.editing.show(page: .objects)
            for key in [ObjectKey(.grade, 1), ObjectKey(.transition, 3), ObjectKey(.audioTransition, 2), ObjectKey(.textStyle, 1), ObjectKey(.macro, 2)] {
                rig.model.editing.selectObject(key)
                check("objects, \(key.kind) \(key.number)")
            }
        }
        try ViewStrings.install()
    }

    /// Spec 11 §10, "Keyboard" — "the cue grid, lists and canvases with the arrows (§2) ... a selected thing's menu with
    /// ⌃Return"; and "On a canvas each box is an element that says its binding, offset and frame in percent, with actions
    /// to move and resize it by 1% of the stack."
    func test_theListsTakeTheArrowsAndTheCanvasBoxesAreElementsWithActions() throws {
        let rig = try editing()
        let view = rig.view
        let editing = rig.model.editing
        editing.show(page: .objects)
        view.layoutSubtreeIfNeeded()
        let list = view.pageList
        // A click gives the list the keys; ↓ walks the groups as one list.
        list.sections[0].rows[0].mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                                  windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        XCTAssertTrue(view.window?.firstResponder === list)
        list.keyDown(with: try key(125))
        XCTAssertEqual(editing.selectedObject, ObjectKey(.transition, 1), "from the grade into the transitions")
        list.keyDown(with: try key(125))
        list.keyDown(with: try key(126))
        XCTAssertEqual(editing.selectedObject, ObjectKey(.transition, 1))
        XCTAssertTrue(list.sections[1].rows[0].isAccessibilitySelected())
        // The canvas: its boxes, top first, each saying itself, each with eight actions.
        editing.show(page: .presets)
        view.layoutSubtreeIfNeeded()
        let canvas = view.workspace.presets.canvas
        let boxes = try XCTUnwrap(canvas.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(boxes.map { $0.accessibilityLabel() ?? "" }, ["body, x 5%, y 10%, width 90%, height 80%", "pixels, x 0%, y 0%, width 100%, height 100%"])
        let actions = boxes[0].accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name), ["Move Left 1%", "Move Right 1%", "Move Up 1%", "Move Down 1%", "Wider 1%", "Narrower 1%", "Taller 1%", "Shorter 1%"])
        XCTAssertTrue(actions[1].handler?() ?? false)
        XCTAssertEqual(last(rig), ["edit preset 1 layouts.*.boxes.1.frame { \"h\": 0.8, \"w\": 0.9, \"x\": 0.06, \"y\": 0.1 }"])
    }

    // MARK: - A picture of it

    func test_theEditWindowDrawsIntoAPicture() throws {
        let rig = try editing()
        rig.model.editing.click(cue: 2, row: .channel(2))
        rig.view.layoutSubtreeIfNeeded()
        let view = rig.view
        let picture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: picture)
        let data = try XCTUnwrap(picture.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 20_000, "something was drawn")
        guard let folder = ProcessInfo.processInfo.environment["O_RENDER_DIR"] else { return }
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window.png"))
        // The Media tab, the chorus's held channel selected, and the grid zoomed out.
        rig.model.editing.show(tab: .media)
        rig.model.editing.click(cue: 3, row: .channel(1))
        rig.model.editing.zoom(to: 72)
        rig.view.layoutSubtreeIfNeeded()
        let second = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: second)
        try XCTUnwrap(second.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-media.png"))
        // Commands as text, on Doxology's last cue from the Library.
        rig.model.editing.zoom(to: 140)
        rig.model.editing.show(tab: .library)
        rig.model.editing.choose(list: list7, from: .list(list7), item: nil)
        rig.model.editing.click(cue: 2, row: .channel(1))
        rig.view.layoutSubtreeIfNeeded()
        let third = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: third)
        try XCTUnwrap(third.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-library.png"))
        // The Stacks page, on stack 1.
        rig.model.editing.show(page: .stacks)
        rig.view.layoutSubtreeIfNeeded()
        let fourth = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: fourth)
        try XCTUnwrap(fourth.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-stacks.png"))
        // The Channels page, on channel 2, whose text shows in the Preview.
        rig.model.editing.show(page: .channels)
        rig.model.editing.selectChannel(2)
        rig.view.layoutSubtreeIfNeeded()
        let fifth = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: fifth)
        try XCTUnwrap(fifth.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-channels.png"))
        // The Presets page, the body box selected.
        rig.model.editing.show(page: .presets)
        rig.model.editing.selectBox(1)
        rig.view.layoutSubtreeIfNeeded()
        let sixth = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: sixth)
        try XCTUnwrap(sixth.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-presets.png"))
        // The Objects page: a grade, an audio transition, a text style and a macro.
        rig.model.editing.show(page: .objects)
        for (key, name) in [(ObjectKey(.grade, 1), "grade"), (ObjectKey(.audioTransition, 2), "audio"), (ObjectKey(.textStyle, 1), "style"),
                            (ObjectKey(.macro, 2), "macro")] {
            rig.model.editing.selectObject(key)
            rig.view.layoutSubtreeIfNeeded()
            let shot = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: shot)
            try XCTUnwrap(shot.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent("edit-window-objects-\(name).png"))
        }
    }
}
