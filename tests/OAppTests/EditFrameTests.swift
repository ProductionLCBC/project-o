import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §13, "Area 14, the frame" — "edit mode lays the window out in its
/// regions at their sizes, at 1440 by 900 and wider", and "`view.json`
/// brings back the page, its selection, the Browser's tab and media view,
/// the zoom and the folded rows".
final class EditFrameTests: XCTestCase {
    // MARK: - The regions (Spec 11 §2)

    func test_theRegionsAtTheSmallestWindow() {
        let frame = EditFrame.make(width: 1440, height: 900)
        // "Top bar ... 44 points high".
        XCTAssertEqual(frame.topBar, EditFrame.Box(x: 0, y: 0, width: 1440, height: 44))
        // "Browser ... 260 points wide, the full height under the top bar"; panels "4 points apart".
        XCTAssertEqual(frame.browser, EditFrame.Box(x: 4, y: 48, width: 260, height: 848))
        // "Inspector ... 250 points high, under the workspace and the monitors".
        XCTAssertEqual(frame.inspector, EditFrame.Box(x: 268, y: 646, width: 1168, height: 250))
        // "Monitors ... A quarter of the window's width, from 300 to 380 points": 360 here.
        XCTAssertEqual(frame.preview.x, 1076)
        XCTAssertEqual(frame.preview.width, 360)
        XCTAssertEqual(frame.preview.y, 48)
        XCTAssertEqual(frame.program.x, 1076)
        XCTAssertEqual(frame.program.y, frame.preview.y + frame.preview.height + 4)
        XCTAssertEqual(frame.program.y + frame.program.height, 642, "Program takes the rest, down to the inspector")
        // "Workspace ... The rest".
        XCTAssertEqual(frame.workspace, EditFrame.Box(x: 268, y: 48, width: 804, height: 594))
        // The Preview panel holds its header and a 16 by 9 picture inside its padding.
        XCTAssertEqual(frame.preview.height, EditFrame.panelHeader + 12 + (360 - 24) * 9 / 16 + 12)
    }

    func test_theMonitorsWidthIsHeldBetween300And380() {
        XCTAssertEqual(EditFrame.monitorsWidth(window: 1000), 300)
        XCTAssertEqual(EditFrame.monitorsWidth(window: 1440), 360)
        XCTAssertEqual(EditFrame.monitorsWidth(window: 1920), 380)
        // A wider window gives the workspace the difference, and the inspector follows it.
        let wide = EditFrame.make(width: 1920, height: 1080)
        XCTAssertEqual(wide.workspace.width, 1920 - 268 - 4 - 380 - 4)
        XCTAssertEqual(wide.inspector.width, 1920 - 268 - 4)
        XCTAssertEqual(wide.inspector.y, 1080 - 4 - 250)
        XCTAssertEqual(wide.browser.height, 1080 - 48 - 4)
    }

    /// Spec 11 §2 as corrected 2026-11-24 — "The gaps beside the Browser, the monitors and the inspector drag to resize
    /// them: the Browser from 200 to 420 points wide, the monitors from 260 to 560, the inspector from 180 to 420 points
    /// high, the workspace keeping at least 360 by 200".
    func test_thePanelsResizeWithinTheirLimitsAndTheWorkspaceKeepsItsRoom() {
        let sized = EditFrame.make(width: 1440, height: 900, browser: 320, monitors: 420, inspector: 300)
        XCTAssertEqual(sized.browser.width, 320)
        XCTAssertEqual(sized.preview.width, 420)
        XCTAssertEqual(sized.program.width, 420)
        XCTAssertEqual(sized.inspector.height, 300)
        XCTAssertEqual(sized.inspector.y, 900 - 4 - 300)
        XCTAssertEqual(sized.workspace.x, 4 + 320 + 4)
        XCTAssertEqual(sized.workspace.width, 1440 - 4 * 4 - 320 - 420)
        XCTAssertEqual(sized.inspector.x, sized.workspace.x)
        // Each held to its limits.
        let limits = EditFrame.make(width: 1920, height: 1080, browser: 100, monitors: 900, inspector: 50)
        XCTAssertEqual(limits.browser.width, 200)
        XCTAssertEqual(limits.preview.width, 560)
        XCTAssertEqual(limits.inspector.height, 180)
        // The workspace keeps 360 points: the monitors give way first, down to theirs, then the Browser.
        let tight = EditFrame.make(width: 1100, height: 900, browser: 420, monitors: 560)
        XCTAssertEqual(tight.workspace.width, 360)
        XCTAssertEqual(tight.browser.width, 420)
        XCTAssertEqual(tight.preview.width, 1100 - 16 - 420 - 360)
        let tighter = EditFrame.make(width: 900, height: 900, browser: 420, monitors: 560)
        XCTAssertEqual(tighter.workspace.width, 360)
        XCTAssertEqual(tighter.preview.width, 260)
        XCTAssertEqual(tighter.browser.width, 900 - 16 - 260 - 360)
        // And 200 points of height: the inspector gives way.
        let short = EditFrame.make(width: 1440, height: 650, inspector: 420)
        XCTAssertEqual(short.workspace.height, 200)
        XCTAssertEqual(short.inspector.height, 650 - 48 - 200 - 4 - 4)
    }

    func test_aBannerOverTheBarPushesEveryRegionDown() {
        // Spec 10 §2's banner stands over the top bar in both modes.
        let frame = EditFrame.make(width: 1440, height: 900, top: 30)
        XCTAssertEqual(frame.topBar.y, 30)
        XCTAssertEqual(frame.browser.y, 78)
        XCTAssertEqual(frame.browser.height, 818)
        XCTAssertEqual(frame.inspector.y, 646, "the inspector keeps to the window's foot")
        XCTAssertEqual(frame.workspace.height, 564)
    }

    // MARK: - The pages (Spec 11 §2)

    func test_thePagesInTheirOrder() {
        XCTAssertEqual(EditPage.allCases, [.cues, .text, .stacks, .channels, .presets, .objects])
        // "in the View menu with ⌥⌘1 to ⌥⌘6".
        XCTAssertEqual(EditPage.allCases.map(\.shortcut), [1, 2, 3, 4, 5, 6])
        // Area 10 built the Text page (Spec 11 §11): every page opens.
        XCTAssertEqual(EditPage.allCases.filter(\.isBuilt), EditPage.allCases)
        // "the Cues and Presets pages keep the inspector ...; nor has the Text page" (§2, G-46).
        XCTAssertEqual(EditPage.allCases.filter(\.hasInspector), [.cues, .presets])
        XCTAssertEqual(EditPage.allCases.filter(\.usesBrowser), [.cues, .text])
        XCTAssertEqual(BrowserTab.allCases, [.playlists, .library, .media])
    }

    // MARK: - view.json (Spec 10 §4, Spec 11 §2)

    func test_viewSettingsKeepEditModesPlace() throws {
        var settings = ViewSettings()
        // The defaults: the Cues page, the Playlists tab, media as a grid, the zoom at 140, no folds set.
        XCTAssertEqual(settings.editPage, .cues)
        XCTAssertEqual(settings.browserTab, .playlists)
        XCTAssertEqual(settings.mediaView, .grid)
        XCTAssertEqual(settings.gridZoom, 140)
        XCTAssertEqual(settings.foldedRows, [:])
        XCTAssertNil(settings.editList)
        settings.editPage = .stacks
        settings.browserTab = .media
        settings.mediaView = .list
        settings.gridZoom = 88
        settings.foldedRows = [1: true, 3: false]
        // "`view.json` keeps the sizes" (corrected 2026-11-24); nil monitors are a quarter of the window.
        XCTAssertEqual(settings.editBrowserWidth, 260)
        XCTAssertNil(settings.editMonitorsWidth)
        XCTAssertEqual(settings.editInspectorHeight, 250)
        settings.editBrowserWidth = 300
        settings.editMonitorsWidth = 400
        settings.editInspectorHeight = 320
        settings.editPlaylist = Recorded.sunday
        settings.editItem = "ae3aafe3-0000-4000-8000-000000000000"
        settings.editList = Recorded.list42
        settings.editCue = Recorded.cues42[2]
        settings.editChannel = 2
        let back = ViewSettingsFile.settings(from: try ViewSettingsFile.data(settings))
        XCTAssertEqual(back, settings)
    }

    func test_whatDoesNotReadKeepsItsDefault() throws {
        let text = """
        { "editPage": "holograms", "browserTab": 7, "gridZoom": 9000, "foldedRows": { "2": true, "x": false }, "mediaView": "list" }
        """
        let settings = ViewSettingsFile.settings(from: Data(text.utf8))
        XCTAssertEqual(settings.editPage, .cues, "a page this build doesn't know")
        XCTAssertEqual(settings.browserTab, .playlists)
        XCTAssertEqual(settings.gridZoom, 480, "held inside the zoom's range")
        XCTAssertEqual(settings.mediaView, .list)
        XCTAssertEqual(settings.foldedRows, [:], "a map that doesn't read whole is left out")
    }
}
