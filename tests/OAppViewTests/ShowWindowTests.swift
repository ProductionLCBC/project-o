import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// What VoiceOver would find wrong in a view: Spec 10 §15, "Every control
/// has a label and its state".
@MainActor
enum Audit {
    /// Each visible control or accessibility element under `view` that has no label, by its type.
    static func unlabelled(in view: NSView) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            // A line of text reads itself, and a scroll area is not a control: everything else VoiceOver stops on needs a label.
            let isStaticText = (view as? NSTextField).map { !$0.isEditable } ?? false
            let isContainer = view is NSScrollView || view is NSScroller || view is NSClipView
            if view.isAccessibilityElement(), !isStaticText, !isContainer {
                let label = view.accessibilityLabel() ?? (view as? NSButton)?.title ?? (view as? NSTextField)?.placeholderString ?? ""
                if label.isEmpty { found.append("\(type(of: view))") }
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return found
    }

    /// Every visible view of a type under `view`.
    static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let match = view as? T { found.append(match) }
            for subview in view.subviews { walk(subview) }
        }
        walk(view)
        return found
    }
}

/// Spec 10 §4–§8 — the show-mode window laid out with no screen, over a
/// store fed the engine's recorded answers (`tests/fixtures/api-v1/`).
@MainActor
final class ShowWindowTests: XCTestCase {
    static let sunday = "b1a70000-0000-4000-8000-000000000001"
    static let list7 = "a9f00000-0000-4000-8000-000000000007"

    /// A window, its model and every command it sent.
    @MainActor
    final class Rig {
        let store = ShowStore()
        let model: ShowModel
        let window: MainWindowController
        var sent: [EngineRequest] = []
        var view: ShowWindowView { window.regions }

        init(size: NSSize = NSSize(width: 1440, height: 900)) throws {
            model = ShowModel(store: store, clock: SystemAppClock())
            window = MainWindowController(model: model, mach: nil)
            model.transmit = { [unowned self] request, _ in self.sent.append(request) }
            store.connected(Hello(api: Hello.api, engine: OCore.appVersion, pid: 1, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2"))
            store.apply(catalog: try Self.load("catalog"))
            store.apply(media: try Self.load("media"))
            for name in ["list-42", "list-7", "list-local"] { store.apply(list: try Self.load(name)) }
            store.apply(state: try Self.load("state"), now: 0)
            resize(size)
        }

        func resize(_ size: NSSize) {
            view.frame = NSRect(origin: .zero, size: size)
            view.refreshAll()
            view.layoutSubtreeIfNeeded()
        }

        static func load(_ name: String) throws -> [String: JSONValue] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("fixtures/api-v1/\(name).json")
            return try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)).objectValue)
        }

        /// The commands sent, in canonical text, one request each.
        var commands: [[String]] {
            sent.map { request in
                let values = request.fields["commands"]?.arrayValue ?? request.fields["command"].map { [$0] } ?? []
                return values.compactMap { (try? JSONCoding.decode(Command.self, from: $0)).flatMap(CommandText.print) }
            }
        }
    }

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    // MARK: - The regions (Spec 10 §4)

    func test_theWindowHasItsRegionsAtTheSpecsSizes() throws {
        let rig = try Rig()
        let view = rig.view
        XCTAssertEqual(view.topBar.frame.height, 38, "Top bar: 38 points high")
        XCTAssertEqual(view.left.frame.width, 248, "Left column: 248 points wide by default")
        XCTAssertEqual(view.bounds.width - view.grid.frame.maxX, 380, "Right column: 380 points wide by default")
        XCTAssertEqual(view.grid.frame.minX, 248)
        XCTAssertEqual(view.pool.frame.minX, view.grid.frame.minX, "the Media pool panel under the grid")
        XCTAssertEqual(view.pool.frame.minY, view.grid.frame.maxY)
        XCTAssertLessThan(view.preview.frame.maxY, view.nextRow.frame.minY + 1, "Preview, next row, tabbed panel, channel strip")
        XCTAssertLessThan(view.nextRow.frame.maxY, view.tabs.frame.minY + 1)
        XCTAssertLessThan(view.tabs.frame.maxY, view.strip.frame.minY + 1)
        XCTAssertGreaterThan(view.strip.frame.height, 150)
    }

    func test_underAThousandPointsTheTabbedPanelIsItsBarAndTheStripTakesTheSpace() throws {
        let rig = try Rig()
        XCTAssertTrue(rig.view.tabs.isCollapsed, "900 points: collapsed whatever the setting says")
        XCTAssertEqual(rig.view.tabs.frame.height, TabsView.barHeight)
        let shortStrip = rig.view.strip.frame.height
        rig.resize(NSSize(width: 1440, height: 1100))
        XCTAssertFalse(rig.view.tabs.isCollapsed, "above that, the setting applies")
        XCTAssertGreaterThan(rig.view.tabs.frame.height, TabsView.barHeight)
        rig.model.change { $0.tabbedPanelCollapsed = true }
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(rig.view.tabs.isCollapsed)
        XCTAssertGreaterThan(rig.view.strip.frame.height, shortStrip)
    }

    // MARK: - The top bar (Spec 10 §8)

    func test_theTopBarSaysWhatIsLiveItsOutputsAndItsTags() throws {
        let rig = try Rig()
        let bar = rig.view.topBar
        XCTAssertEqual(bar.position.stringValue, "Sunday · Great Is Thy Faithfulness · 1 Verse 1")
        XCTAssertEqual(bar.shownOutputs, ["1 Main · stack 1"])
        XCTAssertEqual(bar.shownTags, ["Audio lost", "Popup 1"],
                       "each shown only while it applies: the recorded engine has no audio device, so the output channel 1 routes to is silent")
        XCTAssertTrue(bar.backToLive.isHidden, "Back to Live only while browsing")
        XCTAssertFalse(bar.edit.isEnabled, "edit mode is a later area's")
        rig.model.browse(.list(Self.list7))
        XCTAssertFalse(bar.backToLive.isHidden)
        bar.backToLive.press()
        XCTAssertEqual(rig.model.browse.shown, .playlist(Self.sunday))
        bar.activeElsewhere = "Finder"
        XCTAssertEqual(bar.notActive.stringValue, "Project O isn’t the active app: keys are going to Finder. Click here to come back.")
        XCTAssertTrue(bar.position.isHidden, "the whole bar says so")
    }

    // MARK: - The left column (Spec 10 §5)

    func test_theTreesShowThePlaylistsAndTheLibraryAndAClickBrowses() throws {
        let rig = try Rig()
        let left = rig.view.left
        XCTAssertEqual(left.playlists.rows.map(\.title.stringValue), ["Sunday Night", "Sunday"])
        left.playlists.rows[0].onClick?(false)
        XCTAssertEqual(rig.model.browse.shown, .playlist("b1a70000-0000-4000-8000-000000000010"))
        XCTAssertEqual(left.playlists.rows.map(\.title.stringValue), ["Sunday Night", "EVENING", "Great Is Thy Faithfulness", "Doxology", "Great Is Thy Faithfulness",
                                                                    "Sunday"], "one playlist expanded at a time")
        XCTAssertEqual(left.library.rows.map(\.title.stringValue), ["Christmas", "Hymns", "Doxology"])
        left.library.rows[1].onClick?(false)
        XCTAssertEqual(left.library.rows.map(\.title.stringValue), ["Christmas", "Hymns", "Great Is Thy Faithfulness", "Doxology"])
        left.library.rows[3].onClick?(false)
        XCTAssertEqual(rig.model.browse.shown, .list(Self.list7))
        XCTAssertEqual(rig.view.grid.title.stringValue, "Doxology")
        XCTAssertEqual(rig.sent.count, 0, "browsing sends nothing")
    }

    // MARK: - The grid (Spec 10 §6)

    func test_theGridShowsTheLivePlaylistWithTheLiveCueOutlinedAndNoTag() throws {
        let rig = try Rig()
        let grid = rig.view.grid
        XCTAssertEqual(grid.title.stringValue, "Sunday")
        XCTAssertEqual(grid.detail.stringValue.hasSuffix("3 lists"), true)
        XCTAssertEqual(grid.document.cells.count, 9, "four, two and three cues")
        let live = grid.document.cells.filter { $0.outline != nil }
        XCTAssertEqual(live.map(\.cell.label), ["Verse 1"], "a red outline on the live cue")
        XCTAssertEqual(live.first?.outlineWidth, 2.5, "heavier than any other outline in the grid")
        XCTAssertEqual(live.first?.shownTags, [], "and no \"Live\" tag (Adam, 2026-11-17)")
        XCTAssertEqual(live.first?.accessibilityLabel()?.contains("live"), true, "the word is there for VoiceOver: colour is never the only signal")
        XCTAssertEqual(grid.document.cells[2].trigger.stringValue, "+8 s · adv 12 s")
        XCTAssertEqual(grid.document.cells[4].section.isLocal, true)
        XCTAssertEqual(Audit.all(ListHeaderView.self, in: grid).map(\.title.stringValue), ["Great Is Thy Faithfulness", "Great Is Thy Faithfulness (Manheim)", "Doxology"])
        XCTAssertEqual(Audit.all(ListHeaderView.self, in: grid)[1].shownTags, ["local"])
        XCTAssertEqual(grid.document.cells[6].shownTags, ["missing"], "mountains.mp4 is missing")
        XCTAssertEqual(Audit.all(ChipView.self, in: grid.document.cells[0]).count, 3, "one chip a channel")
    }

    func test_aPressOnACueFiresItAndASecondPressDoesNot() throws {
        let rig = try Rig()
        let cell = rig.view.grid.document.cells[1]
        XCTAssertTrue(cell.accessibilityPerformPress())
        XCTAssertEqual(rig.commands, [["item 2 cue 2"]])
        XCTAssertFalse(cell.accessibilityPerformPress(), "within the double-click interval")
        XCTAssertEqual(rig.sent.count, 1)
    }

    func test_browsingTurnsTheGridsEdgeAmberAndItsHeaderSaysSo() throws {
        let rig = try Rig()
        XCTAssertNil(rig.view.grid.outline)
        rig.model.browse(.list(Self.list7))
        XCTAssertEqual(rig.view.grid.outline, Palette.browsing)
        XCTAssertEqual(Audit.all(TagView.self, in: rig.view.grid).map(\.text).contains("Browsing"), true)
        XCTAssertEqual(rig.view.grid.detail.stringValue, "3 cues")
        XCTAssertFalse(rig.view.grid.fromLibrary.isHidden)
        XCTAssertEqual(rig.view.grid.fromLibrary.stringValue, "From the library: Next stops at its last cue")
    }

    func test_theViewMenusChoicesChangeWhatACellShows() throws {
        let rig = try Rig()
        let tall = rig.view.grid.document.cells[0].frame.height
        rig.model.change { $0.showsThumbnails = false }
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(rig.view.grid.document.cells[0].frame.height, tall, "Compact drops the thumbnails")
        rig.model.change { $0.showsChips = false }
        XCTAssertEqual(Audit.all(ChipView.self, in: rig.view.grid).count, 0)
    }

    // MARK: - The right column (Spec 10 §7)

    func test_nextLastAndTheGoToFieldSendTheirCommands() throws {
        let rig = try Rig()
        let row = rig.view.nextRow
        XCTAssertTrue(row.next.isEnabled)
        row.next.press()
        row.last.press()
        row.go(to: "3")
        row.go(to: "")
        XCTAssertEqual(rig.commands, [["next"], ["previous"], ["cue 3"]], "Return on an empty field does nothing")
        XCTAssertTrue(row.hold.isHidden, "Hold only while a trigger is armed")
        rig.store.disconnected()
        XCTAssertFalse(row.next.isEnabled)
        XCTAssertEqual(row.next.reason, "The engine is away.")
    }

    func test_theClearsTilesSendTheirCommandsAndLightWhileOn() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        let tabs = rig.view.tabs
        tabs.show(.clears)
        XCTAssertEqual(tabs.controls.map(\.title), ["Clear All", "Blackout Stack 1", "Blackout All", "Mute All Audio", "Reset Channels", "Clear Popups"])
        XCTAssertEqual(tabs.controls.map(\.lit), [.off, .off, .some, .some, .off, .off], "stack 2 is blacked out and audio output 1 muted in the recorded state")
        tabs.controls[0].press()
        tabs.controls[3].press()
        XCTAssertEqual(rig.commands, [["system clearall"], ["audio all mute toggle"]])
    }

    func test_theTransportTabFollowsTheSelection() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        let tabs = rig.view.tabs
        tabs.show(.transport)
        XCTAssertEqual(tabs.labels.map(\.stringValue), ["No transport"])
        rig.model.selectOnly(1)
        XCTAssertEqual(tabs.controls.map(\.title), ["Pause", "Stop", "Loop", "Hold", "Clear"])
        tabs.controls[0].press()
        tabs.controls[3].press()
        XCTAssertEqual(rig.commands, [["channel 1 pause"], ["channel 1 end hold"]])
    }

    func test_thePopupsTabSendsADraftAndClearsASlot() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        let tabs = rig.view.tabs
        tabs.show(.popups)
        let drafts = Audit.all(DraftField.self, in: tabs)
        XCTAssertEqual(drafts.count, 8, "four popup slots and four timers in the fixture")
        drafts[1].type("Car lights on")
        let send = try XCTUnwrap(tabs.controls.filter { $0.title == "Send" }.dropFirst().first)
        send.press()
        XCTAssertEqual(rig.commands, [["popup 2 set \"Car lights on\""]])
        XCTAssertEqual(drafts[1].stringValue, "", "Send empties the draft")
        drafts[4].type("5:00")
        try XCTUnwrap(tabs.controls.first { $0.title == "Set" }).press()
        XCTAssertEqual(rig.commands.last, ["timer 1 set 5:00"])
    }

    func test_theStripSelectsWithItsBadgesAndClearsInNumberOrder() throws {
        let rig = try Rig()
        let strip = rig.view.strip
        XCTAssertEqual(strip.cells.map(\.cell.number), [1, 2, 3])
        XCTAssertFalse(strip.clearSelected.isEnabled, "enabled only with a selection")
        strip.cells[1].badge.press()
        rig.view.strip.cells[0].badge.press()
        XCTAssertTrue(rig.view.strip.clearSelected.isEnabled)
        rig.view.strip.clearSelected.press()
        rig.view.strip.clearAll.press()
        XCTAssertEqual(rig.commands, [["channel 1 clear", "channel 2 clear"], ["system clearall"]])
        XCTAssertFalse(rig.view.strip.clearPopups.isHidden, "a popup slot is set, so Clear Popups shows beside Clear All")
        XCTAssertEqual(rig.view.strip.cells[0].buttons.map(\.title), ["Pause", "Stop", "Clear"])
        rig.view.strip.cells[0].dots[0].press()
        XCTAssertEqual(rig.commands.last, ["stack 1 mute 1 toggle"])
        XCTAssertFalse(rig.view.strip.cells[0].dots[1].isEnabled, "inert where the stack doesn't hold the channel")
    }

    func test_thePreviewShowsTheThumbnailStackAndTheMultiviewerEveryStack() throws {
        let rig = try Rig()
        XCTAssertEqual(rig.view.preview.shownStacks, [1])
        XCTAssertEqual(rig.view.preview.feeds.stringValue, "feeds 1 Main")
        rig.model.change { $0.multiviewer = true }
        XCTAssertEqual(rig.view.preview.shownStacks, [1, 2], "assigned or not, by stack number")
        XCTAssertEqual([1, 2, 4, 5, 9, 10].map(PreviewView.columns), [1, 2, 2, 3, 3, 4])
        rig.model.change { $0.previewStack = 2; $0.multiviewer = false }
        XCTAssertEqual(rig.view.preview.feeds.stringValue, "preview only")
    }

    // MARK: - The pool (Spec 10 §6)

    func test_thePoolShowsItsTilesAndADoubleClickGoesLive() throws {
        let rig = try Rig()
        let pool = rig.view.pool
        XCTAssertEqual(pool.tiles.map(\.name.stringValue), ["announcement.png", "cross.png", "dawn.mp4", "mountains.mp4", "welcome.oslide"])
        pool.tiles[2].onClick?(1, NSEvent())
        XCTAssertEqual(rig.sent.count, 0, "There is no single-click firing")
        XCTAssertEqual(rig.model.selectedMedia, pool.tiles[2].tile.id)
        rig.view.pool.tiles[2].onClick?(2, NSEvent())
        XCTAssertEqual(rig.commands.count, 1)
        XCTAssertEqual(rig.commands.first?.first?.hasPrefix("channel 1 write media sha256:55c8"), true)
        XCTAssertFalse(pool.importMedia.isEnabled, "importing comes with the drops")
    }

    // MARK: - Accessibility and strings (Spec 10 §15, §18)

    func test_everyControlInEveryRegionHasALabel() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        for tab in TabsView.Tab.allCases {
            rig.view.tabs.show(tab)
            XCTAssertEqual(Audit.unlabelled(in: rig.view), [], "Spec 10 §15: every control has a label (\(tab))")
        }
        rig.model.selectOnly(1)
        rig.view.tabs.show(.transport)
        rig.model.change { $0.multiviewer = true }
        rig.model.browse(.list(Self.list7))
        XCTAssertEqual(Audit.unlabelled(in: rig.view), [])
    }

    func test_nothingOfTheAppsOwnIsClippedAt1440By900UnderEitherPseudolanguage() throws {
        // Spec 10 §18 — "at 1440 by 900, under the accented pseudolanguage and one 40% longer, nothing is clipped".
        // Every button's title and every label of the app's own wording must show whole. A label that holds what the
        // operator or the library wrote (a title, a file's name) is marked, and may end in an ellipsis.
        let plain: (String) -> String = { $0 }
        for transform in [plain, Pseudolanguage.accented, Pseudolanguage.longer] {
            try ViewStrings.install(transform: transform)
            let rig = try Rig()
            func check(_ what: String) {
                rig.resize(NSSize(width: 1440, height: 900))
                for button in Audit.all(FlatButton.self, in: rig.view) where button.frame.width > 0 {
                    XCTAssertTrue(button.titleFits, "\"\(button.title)\" is clipped (\(what))")
                }
                for label in Audit.all(NSTextField.self, in: rig.view)
                where !label.isEditable && label.tag != Kit.mayTruncate && label.maximumNumberOfLines == 1 && label.frame.width > 0 {
                    XCTAssertTrue(Kit.fits(label), "\"\(label.stringValue)\" is clipped: \(label.frame.width) of \(Kit.width(of: label)) points (\(what))")
                }
            }
            for tab in TabsView.Tab.allCases {
                rig.view.tabs.isCollapsed = false
                rig.view.tabs.show(tab)
                check("\(tab)")
            }
            rig.model.selectOnly(1)
            rig.view.tabs.show(.transport)
            check("transport with a channel")
            rig.model.change { $0.multiviewer = true; $0.showsNotes = true }
            rig.model.browse(.list(Self.list7))
            check("browsing a library list, with the multiviewer")
        }
        try ViewStrings.install()
    }

    /// Draws the window into a picture, with no screen: what the stops' reports show Adam.
    func test_theWindowDrawsIntoAPicture() throws {
        let rig = try Rig()
        let view = rig.view
        let picture = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: picture)
        XCTAssertEqual(picture.pixelsWide >= 1440, true)
        let data = try XCTUnwrap(picture.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 20_000, "something was drawn")
        if let folder = ProcessInfo.processInfo.environment["O_RENDER_DIR"] {
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("show-window.png"))
        }
    }
}
