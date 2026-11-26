import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 10 §15 — "Keyboard navigation. Every action is reachable without
/// the mouse ... in a focused list, tree, grid or tile set ⌥ with the arrows
/// moves the selection; ⌥Return or ⌥Space presses or activates whatever has
/// the focus, a button, a tile, a cue or a row; and ⌃Return opens the
/// focused item's menu, which holds what a right-click offers." And what
/// VoiceOver hears and reads (§15, "VoiceOver"), Increase Contrast and
/// Reduce Motion. §18: "every action has a keyboard path".
@MainActor
final class KeyboardPathTests: XCTestCase {
    typealias Rig = DropsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private enum Key: UInt16 {
        case left = 123, right = 124, down = 125, up = 126, `return` = 36, space = 49
    }

    private func press(_ key: Key, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                       characters: key == .space ? " " : "", charactersIgnoringModifiers: key == .space ? " " : "", isARepeat: false,
                                       keyCode: key.rawValue))
    }

    /// Takes the keyboard's focus, as Tab reaching the region does, and hands back what its ⌃Return opens.
    private func focus(_ region: NSView, _ group: FocusGroup, in rig: Rig) -> () -> NSMenu? {
        XCTAssertTrue(rig.window.window.makeFirstResponder(region))
        XCTAssertTrue(rig.window.window.firstResponder === region)
        var opened: NSMenu?
        group.popUp = { menu, _ in opened = menu }
        return { opened }
    }

    // MARK: - The grid

    func test_theGridsFocusMovesWithOptionArrowsFiresWithOptionReturnAndOpensTheMenu() throws {
        let rig = try Rig()
        let grid = rig.view.grid
        let opened = focus(grid, grid.focus, in: rig)
        XCTAssertTrue(grid.focus.isActive)
        // It starts on the first list's header; ⌥→ goes on to its cues.
        XCTAssertTrue(grid.focus.ringedView is ListHeaderView, "the outline shows where the focus is")
        grid.keyDown(with: try press(.right, .option))
        let first = try XCTUnwrap(grid.focus.ringedView as? CueCellView)
        XCTAssertEqual(first.cell.number, 1)
        // The keys' rules leave these chords to the focus (§9: the keyboard's navigation is reserved).
        XCTAssertFalse(rig.window.keyTap.take(try press(.right, .option)), "the app's bindings don't take ⌥→")
        grid.keyDown(with: try press(.right, .option))
        XCTAssertEqual((grid.focus.ringedView as? CueCellView)?.cell.number, 2)
        grid.keyDown(with: try press(.left, .option))
        // ⌥↓ goes to the cue most nearly below, in the next row; ⌥↑ comes back.
        grid.keyDown(with: try press(.down, .option))
        let below = try XCTUnwrap(grid.focus.ringedView as? CueCellView)
        XCTAssertGreaterThan(below.frame.minY, first.frame.minY)
        XCTAssertEqual(below.frame.minX, first.frame.minX, accuracy: 1)
        grid.keyDown(with: try press(.up, .option))
        XCTAssertEqual((grid.focus.ringedView as? CueCellView)?.cell.number, 1)
        XCTAssertEqual(rig.sent.count, 0, "moving the focus fires nothing")
        // The focus outlasts the grid being drawn again.
        grid.refresh()
        let again = try XCTUnwrap(grid.focus.ringedView as? CueCellView)
        XCTAssertFalse(again === first)
        XCTAssertEqual(again.cell.uuid, first.cell.uuid)
        XCTAssertNotNil(again.window)
        // ⌃Return opens the cue's menu, without firing it.
        grid.keyDown(with: try press(.return, .control))
        XCTAssertEqual(opened()?.items.first?.title, "Fire")
        XCTAssertTrue(opened()?.titles.contains("Note…") ?? false)
        XCTAssertEqual(rig.sent.count, 0)
        // ⌥Return presses the cue, as a click does; ⌥Space too, once the double-click interval has passed.
        grid.keyDown(with: try press(.return, .option))
        XCTAssertEqual(rig.commands, [["item 2 cue 1"]])
        rig.clock.advance(by: 2)
        grid.keyDown(with: try press(.space, .option))
        XCTAssertEqual(rig.commands.count, 2)
        // A list's header: its menu, which a right-click offers.
        grid.keyDown(with: try press(.left, .option))
        XCTAssertTrue(grid.focus.ringedView is ListHeaderView)
        grid.keyDown(with: try press(.return, .control))
        XCTAssertTrue(opened()?.titles.contains("Restore a Version…") ?? false)
        // The focus leaves: the outline goes.
        XCTAssertTrue(rig.window.window.makeFirstResponder(rig.view))
        XCTAssertNil(grid.focus.ringedView)
    }

    // MARK: - The trees, the pool and the strip

    func test_aTreesFocusChoosesARowAndOpensItsMenu() throws {
        let rig = try Rig()
        let list = rig.view.left.playlists
        let opened = focus(list, list.focus, in: rig)
        let rows = list.rows.filter { !$0.content.isHeading }
        XCTAssertTrue(list.focus.ringedView === rows[0])
        list.keyDown(with: try press(.down, .option))
        XCTAssertTrue(list.focus.ringedView === rows[1])
        list.keyDown(with: try press(.up, .option))
        list.keyDown(with: try press(.up, .option))
        XCTAssertTrue(list.focus.ringedView === rows[0], "it stops at the first row")
        // ⌥Return chooses the row: the playlist is browsed.
        let night = try XCTUnwrap(list.rows.first { $0.title.stringValue.caseInsensitiveCompare("Sunday Night") == .orderedSame })
        while list.focus.ringedView !== night, list.focus.ringedView !== list.rows.last { list.keyDown(with: try press(.down, .option)) }
        list.keyDown(with: try press(.return, .option))
        XCTAssertEqual(rig.model.browse.shown, .playlist(EditsViewTests.sundayNight))
        // The row was drawn again, and the focus is still on it.
        XCTAssertEqual((list.focus.ringedView as? RowView)?.title.stringValue.lowercased(), "sunday night")
        list.keyDown(with: try press(.return, .control))
        XCTAssertEqual(opened()?.titles.first, "Make Live")
        XCTAssertEqual(list.accessibilityLabel(), "Playlists")
        XCTAssertEqual(rig.view.left.library.accessibilityLabel(), "Library")
    }

    func test_thePoolsFocusSelectsATileAndItsMenuFiresIt() throws {
        let rig = try Rig()
        let pool = rig.view.pool
        let opened = focus(pool, pool.focus, in: rig)
        XCTAssertTrue(pool.focus.ringedView === pool.tiles[0])
        pool.keyDown(with: try press(.right, .option))
        pool.keyDown(with: try press(.right, .option))
        XCTAssertEqual((pool.focus.ringedView as? PoolTileView)?.name.stringValue, "dawn.mp4")
        pool.keyDown(with: try press(.space, .option))
        XCTAssertEqual(rig.model.selectedMedia, try rig.tile("dawn.mp4").tile.id, "⌥Space selects, as a click does")
        XCTAssertEqual(rig.sent.count, 0, "There is no single-click firing")
        XCTAssertEqual((pool.focus.ringedView as? PoolTileView)?.name.stringValue, "dawn.mp4", "the tiles were drawn again; the focus stays")
        pool.keyDown(with: try press(.return, .control))
        try XCTUnwrap(opened()?.entry("Fire to Channel 1 Background")).choose()
        XCTAssertEqual(rig.commands.last?.first?.hasPrefix("channel 1 write media "), true, "the tile's menu is its way to air from the keyboard")
    }

    func test_theStripsFocusSelectsAChannelAndOpensItsMenu() throws {
        let rig = try Rig()
        let strip = rig.view.strip
        let opened = focus(strip, strip.focus, in: rig)
        XCTAssertEqual((strip.focus.ringedView as? StripCellView)?.cell.number, 1)
        strip.keyDown(with: try press(.down, .option))
        XCTAssertEqual((strip.focus.ringedView as? StripCellView)?.cell.number, 2)
        strip.keyDown(with: try press(.return, .option))
        XCTAssertEqual(rig.model.selection.channels, [2], "as a click on the thumbnail: that channel alone")
        XCTAssertEqual((strip.focus.ringedView as? StripCellView)?.cell.number, 2)
        strip.keyDown(with: try press(.return, .control))
        let titles = opened()?.titles ?? []
        XCTAssertTrue(titles.contains("Clear") && titles.contains("Select Only This Channel"), "\(titles)")
        try XCTUnwrap(opened()?.entry("Clear")).choose()
        XCTAssertEqual(rig.commands.last, ["channel 2 clear"])
    }

    // MARK: - Buttons

    /// "each button takes the keyboard focus like any other" (§8), and keeps
    /// it while its region is drawn again; ⌥Return and ⌥Space press it.
    func test_aFocusedButtonIsPressedWithOptionReturnAndKeepsTheFocusThroughARedraw() throws {
        let rig = try Rig()
        let window = rig.window.window
        let clear = try XCTUnwrap(try rig.stripCell(1).buttons.last)
        XCTAssertTrue(window.makeFirstResponder(clear))
        clear.keyDown(with: try press(.return, .option))
        XCTAssertEqual(rig.commands.last, ["channel 1 clear"])
        clear.keyDown(with: try press(.space, .option))
        XCTAssertEqual(rig.commands.count, 2)
        // A channel changes: the strip draws its cells again, and the focus is on the same button of the same cell.
        rig.view.strip.refresh()
        let after = try XCTUnwrap(window.firstResponder as? FlatButton)
        XCTAssertFalse(after === clear)
        XCTAssertTrue(after === (try rig.stripCell(1).buttons.last))
        XCTAssertEqual(after.title, clear.title)
        // The top bar's tags, which are drawn again at every tick of the clock.
        let tag = try XCTUnwrap(rig.view.topBar.tagButtons.first { $0.title == "Popup 1" })
        XCTAssertTrue(window.makeFirstResponder(tag))
        rig.view.topBar.refresh()
        XCTAssertEqual((window.firstResponder as? FlatButton)?.title, "Popup 1")
        XCTAssertFalse(window.firstResponder === tag)
        // A field being typed in is left alone.
        XCTAssertTrue(window.autorecalculatesKeyViewLoop, "Tab's order follows the controls as they are drawn again")
    }

    /// §18 — "every action has a keyboard path": every button takes the
    /// focus, and everything with a menu of its own is one of its region's
    /// focus items, so ⌃Return reaches that menu.
    func test_everyButtonTakesTheFocusAndEveryMenuHasItsFocusItem() throws {
        let rig = try Rig()
        rig.model.toggle(folder: "Hymns")
        rig.view.layoutSubtreeIfNeeded()
        var buttons = 0
        var waiting: [NSView] = [rig.view]
        var withMenus: [NSView] = []
        while let view = waiting.popLast() {
            if view.isHidden { continue }
            if let button = view as? FlatButton, button.isEnabled {
                buttons += 1
                XCTAssertTrue(button.acceptsFirstResponder, button.title)
            }
            if view is CueCellView || view is ListHeaderView || view is PoolTileView || view is StripCellView { withMenus.append(view) }
            if let row = view as? RowView, row.menuNow != nil { withMenus.append(row) }
            waiting.append(contentsOf: view.subviews)
        }
        XCTAssertGreaterThan(buttons, 20)
        let groups = [rig.view.grid.focus, rig.view.left.playlists.focus, rig.view.left.library.focus, rig.view.pool.rail.focus, rig.view.pool.focus, rig.view.strip.focus]
        let reachable = groups.flatMap { $0.entries().map(\.view) }
        XCTAssertGreaterThan(withMenus.count, 15)
        for view in withMenus { XCTAssertTrue(reachable.contains { $0 === view }, "\(type(of: view)) \(view.accessibilityLabel() ?? "")") }
        // Each region that holds them takes the focus itself, so Tab reaches it.
        for region in [rig.view.grid, rig.view.left.playlists, rig.view.left.library, rig.view.pool.rail, rig.view.pool, rig.view.strip] as [NSView] {
            XCTAssertTrue(region.acceptsFirstResponder, "\(type(of: region))")
        }
    }

    // MARK: - VoiceOver (Spec 10 §15)

    func test_theWindowTellsVoiceOverEachLiveChangeWithItsSource() throws {
        let rig = try Rig()
        var command = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["commands.navigation"]?.objectValue)
        command["command"] = .object(["cmd": .string("playlist.next")])
        command["source"] = .object(["kind": .string("osc")])
        rig.store.apply(event: "commands", command, now: rig.clock.now)
        var live = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["live.fired"]?.objectValue)
        live["cue"] = .string("22bb0000-0000-4000-8000-000000000002")
        live["label"] = .string("Verse 2")
        live["position"] = .object(["cue": .number(2), "item": .number(2)])
        rig.store.apply(event: "live", live, now: rig.clock.now)
        XCTAssertEqual(rig.view.spoken.last, "From OSC: Verse 2")
        rig.store.apply(event: "live", try XCTUnwrap(try ShowWindowTests.Rig.load("events")["live.armed"]?.objectValue), now: rig.clock.now)
        XCTAssertTrue(rig.view.spoken.contains("Auto in 0 seconds"), "\(rig.view.spoken)")
    }

    /// "Every control has a label and its state ("Channel 2 Foreground,
    /// text, "Great is Thy faithfulness", locked, in stacks 1 and 2"). The
    /// grid is a collection whose cells say their number, label, section,
    /// trigger, and "live" or "armed" ... The strip's meters and transition
    /// bars are left out of the spoken order."
    func test_aChannelAndACueAreSpokenWithTheirState() throws {
        let rig = try Rig()
        let first = try rig.stripCell(1)
        XCTAssertTrue(first.spoken.hasPrefix("Channel 1 Background, Video, “dawn.mp4”"), first.spoken)
        XCTAssertEqual(first.accessibilityLabel(), first.spoken)
        XCTAssertEqual(first.accessibilityRole(), .group)
        let stacks = first.cell.dots.filter { $0.state == .showing }.map(\.stack)
        if stacks.count == 1 { XCTAssertTrue(first.spoken.hasSuffix("in stack \(stacks[0])"), first.spoken) }
        if stacks.count > 1 { XCTAssertTrue(first.spoken.contains("in stacks "), first.spoken) }
        if first.cell.isLocked { XCTAssertTrue(first.spoken.contains(", locked"), first.spoken) }
        var meters = 0
        var waiting: [NSView] = [rig.view.strip]
        while let view = waiting.popLast() {
            if view is MeterView {
                meters += 1
                XCTAssertFalse(view.isAccessibilityElement(), "a meter is left out of the spoken order")
            }
            waiting.append(contentsOf: view.subviews)
        }
        XCTAssertGreaterThan(meters, 0)
        // The grid.
        XCTAssertEqual(rig.view.grid.document.accessibilityRole(), .list)
        XCTAssertEqual(rig.view.grid.document.accessibilityLabel(), "Cues")
        let cue = try rig.cell("Verse 1")
        let words = try XCTUnwrap(cue.accessibilityLabel())
        XCTAssertTrue(words.hasPrefix("Cue 1, Verse 1, live"), words)
        if let section = cue.cell.section, !section.isEmpty { XCTAssertTrue(words.contains("section " + section), words) }
        rig.store.apply(event: "live", try XCTUnwrap(try ShowWindowTests.Rig.load("events")["live.armed"]?.objectValue), now: rig.clock.now)
        let armed = try XCTUnwrap(rig.view.grid.document.cells.first { $0.cell.isArmed })
        XCTAssertTrue(armed.accessibilityLabel()?.contains("armed") ?? false, armed.accessibilityLabel() ?? "")
        rig.view.layoutSubtreeIfNeeded()
        for region in [rig.view.grid, rig.view.strip, rig.view.pool, rig.view.left, rig.view.topBar] as [NSView] { XCTAssertEqual(Audit.unlabeled(in: region), []) }
    }

    // MARK: - Increase Contrast and Reduce Motion (Spec 10 §15)

    /// "Increase Contrast thickens borders and outlines"; Reduce Motion
    /// "shows the transition bar's end state instead of running it".
    func test_theWindowFollowsIncreaseContrastAndReduceMotion() throws {
        addTeardownBlock { @MainActor in Look.increasesContrast = false }
        let rig = try Rig()
        let live = try XCTUnwrap(rig.view.grid.document.cells.first { $0.cell.isLive })
        XCTAssertEqual(live.drawnOutlineWidth, 2.5)
        rig.view.follow(increaseContrast: true, reduceMotion: true)
        let thicker = try XCTUnwrap(rig.view.grid.document.cells.first { $0.cell.isLive })
        XCTAssertEqual(thicker.drawnOutlineWidth, 3.75, "the live cue's outline, half as heavy again")
        XCTAssertEqual(Look.outlineScale, 1.5)
        XCTAssertTrue(rig.model.reducesMotion)
        rig.view.follow(increaseContrast: false, reduceMotion: false)
        XCTAssertEqual(try XCTUnwrap(rig.view.grid.document.cells.first { $0.cell.isLive }).drawnOutlineWidth, 2.5)
        XCTAssertFalse(rig.model.reducesMotion)
    }
}
