import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §4, "View settings" (S8), and §18's line: "`view.json`
/// round-trips every view setting; an unreadable file gives defaults; Reset
/// Layout restores them; ... the app writes nothing else in the roots but
/// the console log it opens."
@MainActor
final class ViewSettingsFileTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    private var folder = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() async throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("o-view-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("machine"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var machine: URL { folder.appendingPathComponent("machine") }

    /// Every setting away from its default.
    private func changed() -> ViewSettings {
        var settings = ViewSettings()
        settings.leftColumnWidth = 300
        settings.rightColumnWidth = 420
        settings.leftSplit = 0.35
        settings.panel = .expanded
        settings.tabbedPanelCollapsed = true
        settings.previewStack = 2
        settings.multiviewer = true
        settings.showsThumbnails = false
        settings.showsChips = false
        settings.showsTriggers = false
        settings.showsNotes = true
        settings.poolFolder = "backgrounds"
        settings.poolSort = .dateAdded
        settings.poolKind = .video
        settings.poolTileSize = .large
        settings.stripStack = 1
        settings.showsArchivedPlaylists = true
        settings.openFolders = ["Christmas", "Hymns"]
        settings.recentMedia = ["sha256:aa", "sha256:bb"]
        settings.windowFrame = [120, 80, 1500, 950]
        settings.lastBrowsedPlaylist = Recorded.sundayNight
        settings.lastBrowsedList = Recorded.list42
        settings.dismissedRestoreRun = "51e2"
        // Spec 11 §2 — edit mode's place.
        settings.editPage = .presets
        settings.editPlaylist = Recorded.sunday
        settings.editItem = "ae3aafe3-0000-4000-8000-000000000000"
        settings.editList = Recorded.list7
        settings.editCue = Recorded.cues42[1]
        settings.editChannel = 3
        settings.browserTab = .media
        settings.mediaView = .list
        settings.gridZoom = 88
        settings.foldedRows = [2: true]
        settings.hiddenRows = [2, 3]
        settings.editStack = 2
        settings.editOutput = 1
        settings.editPreset = 3
        settings.editLayout = 2
        settings.editBrowserWidth = 300
        settings.editMonitorsWidth = 420
        settings.editInspectorHeight = 320
        return settings
    }

    func test_theFileRoundTripsEveryViewSetting() throws {
        let settings = changed()
        let data = try ViewSettingsFile.data(settings)
        XCTAssertEqual(ViewSettingsFile.settings(from: data), settings)
        // Every stored setting is in the file: one added to the struct and forgotten here or in the reading fails this.
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = Mirror(reflecting: settings).children.compactMap(\.label)
        XCTAssertEqual(Set(written.keys), Set(stored))
        // And each is away from its default here, or its round trip would prove nothing.
        let defaults = try XCTUnwrap(try JSONSerialization.jsonObject(with: try ViewSettingsFile.data(ViewSettings())) as? [String: Any])
        for key in written.keys { XCTAssertNotEqual(written[key] as? NSObject, defaults[key] as? NSObject, key) }
        // On disk.
        XCTAssertTrue(ViewSettingsFile.write(settings, machineRoot: machine))
        XCTAssertEqual(ViewSettingsFile.read(machineRoot: machine), settings)
    }

    /// The repository's JSON on disk: sorted keys, two-space indent, LF.
    func test_theFileIsWrittenAsTheRepositoryWritesJSON() throws {
        let text = try XCTUnwrap(String(data: try ViewSettingsFile.data(changed()), encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("{\n  \"browserTab\" : \"media\",\n  \"dismissedRestoreRun\" : \"51e2\",\n  \"editBrowserWidth\" : 300,\n  \"editChannel\""), String(text.prefix(80)))
        XCTAssertTrue(text.hasSuffix("\n}\n"))
        XCTAssertFalse(text.contains("\r"))
        XCTAssertFalse(text.contains("\\/"), "a folder's path is written plain")
        let keys = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  \"") else { return nil }
            return String(line.dropFirst(3).prefix { $0 != "\"" })
        }
        XCTAssertEqual(keys, keys.sorted())
    }

    /// "unknown keys are ignored, a file that doesn't read means defaults".
    func test_aFileThatDoesNotReadGivesDefaultsAndUnknownKeysAreIgnored() throws {
        XCTAssertEqual(ViewSettingsFile.read(machineRoot: machine), ViewSettings(), "no file")
        try Data("not json at all".utf8).write(to: ViewSettingsFile.url(machineRoot: machine))
        XCTAssertEqual(ViewSettingsFile.read(machineRoot: machine), ViewSettings())
        XCTAssertEqual(ViewSettingsFile.settings(from: Data("[1, 2]".utf8)), ViewSettings())
        // A key from a later build, and one whose value this build can't read: the rest is taken.
        let mixed = #"{ "futureSetting": { "a": 1 }, "multiviewer": true, "panel": "sideways", "leftColumnWidth": "wide", "showsNotes": true }"#
        var expected = ViewSettings()
        expected.multiviewer = true
        expected.showsNotes = true
        XCTAssertEqual(ViewSettingsFile.settings(from: Data(mixed.utf8)), expected)
        // What was read is held to what the window allows.
        let wild = #"{ "leftColumnWidth": 9000, "rightColumnWidth": 1, "leftSplit": 7, "windowFrame": [1, 2, 3], "recentMedia": [\#((1...30).map { "\"m\($0)\"" }.joined(separator: ","))] }"#
        let read = ViewSettingsFile.settings(from: Data(wild.utf8))
        XCTAssertEqual(read.leftColumnWidth, ViewSettings.leftWidth.max)
        XCTAssertEqual(read.rightColumnWidth, ViewSettings.rightWidth.min)
        XCTAssertEqual(read.leftSplit, 0.8)
        XCTAssertNil(read.windowFrame, "a frame is four numbers")
        XCTAssertEqual(read.recentMedia.count, 20)
    }

    /// "the app writes nothing else in the roots": the write leaves one file, and never makes the machine folder.
    func test_theWriteLeavesOneFileAndNeverMakesTheMachineFolder() throws {
        try Data("{}".utf8).write(to: machine.appendingPathComponent("machine.json"))
        XCTAssertTrue(ViewSettingsFile.write(changed(), machineRoot: machine))
        XCTAssertTrue(ViewSettingsFile.write(ViewSettings(), machineRoot: machine), "written again, over itself")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: machine.path).sorted(), ["machine.json", "view.json"], "no temporary file is left beside it")
        let nowhere = folder.appendingPathComponent("not-made")
        XCTAssertFalse(ViewSettingsFile.write(changed(), machineRoot: nowhere))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nowhere.path))
    }

    /// "The app writes the file a second after the last change".
    func test_theFileIsWrittenASecondAfterTheLastChange() throws {
        let clock = ManualClock()
        var written: [ViewSettings] = []
        var works = true
        let saver = ViewSettingsSaver(clock: clock) { settings in
            if works { written.append(settings) }
            return works
        }
        var settings = ViewSettings()
        settings.leftColumnWidth = 260
        saver.changed(settings)
        clock.advance(by: 0.9)
        XCTAssertEqual(written, [], "not yet")
        // A divider still being dragged puts the write off.
        settings.leftColumnWidth = 280
        saver.changed(settings)
        clock.advance(by: 0.9)
        XCTAssertEqual(written, [])
        clock.advance(by: 0.2)
        XCTAssertEqual(written, [settings], "once, with the last of them")
        XCTAssertFalse(saver.isWaiting)
        clock.advance(by: 10)
        XCTAssertEqual(written.count, 1, "nothing changed: nothing is written again")
        // Before the app quits, what waits is written at once.
        settings.multiviewer = true
        saver.changed(settings)
        saver.flush()
        XCTAssertEqual(written.count, 2)
        clock.advance(by: 2)
        XCTAssertEqual(written.count, 2, "and not a second time")
        // A write that couldn't be made is tried again at the next change.
        works = false
        settings.showsNotes = true
        saver.changed(settings)
        clock.advance(by: 1.1)
        XCTAssertTrue(saver.isWaiting)
        works = true
        saver.flush()
        XCTAssertEqual(written.last, settings)
    }

    // MARK: - The model's settings

    func test_everyChangeOfAViewSettingIsToldAndReadingTheFileIsNot() throws {
        let rig = try Rig()
        var told: [ViewSettings] = []
        rig.model.onSettings = { told.append($0) }
        rig.model.load(settings: changed())
        XCTAssertEqual(told, [], "what the file held isn't a change")
        XCTAssertEqual(rig.model.settings, changed())
        XCTAssertEqual(rig.model.poolFilter.sort, .dateAdded, "the pool's header follows what was read")
        XCTAssertEqual(rig.model.poolFilter.kind, .video)
        XCTAssertEqual(rig.model.poolFilter.folder, "backgrounds")
        rig.model.toggle(folder: "Hymns")
        rig.model.change { $0.multiviewer = false }
        rig.model.resize { $0.leftColumnWidth = 250 }
        rig.model.setPool { $0.sort = .name }
        rig.model.goLive(media: try XCTUnwrap(rig.store.media.first?.id), on: 1)
        rig.model.windowMoved(to: [10, 20, 1440, 900])
        rig.model.browse(.list(Recorded.list42))
        XCTAssertEqual(told.count, 7, "each is told")
        XCTAssertEqual(told.last, rig.model.settings)
        XCTAssertEqual(rig.model.settings.lastBrowsed, .list(Recorded.list42), "the last thing browsed")
        XCTAssertNil(rig.model.settings.lastBrowsedPlaylist)
        // The same value again is no change.
        rig.model.windowMoved(to: [10, 20, 1440, 900])
        rig.model.change { $0.multiviewer = false }
        XCTAssertEqual(told.count, 7)
    }

    /// "View ▸ Reset Layout puts the defaults back; it's a UI action, not a command."
    func test_resetLayoutPutsTheDefaultsBack() throws {
        let rig = try Rig()
        rig.model.load(settings: changed())
        rig.model.resetLayout()
        var expected = ViewSettings()
        // Where the window stands and what the operator last did aren't layout.
        expected.windowFrame = [120, 80, 1500, 950]
        expected.recentMedia = ["sha256:aa", "sha256:bb"]
        expected.lastBrowsedPlaylist = Recorded.sundayNight
        expected.lastBrowsedList = Recorded.list42
        expected.dismissedRestoreRun = "51e2"
        XCTAssertEqual(rig.model.settings, expected)
        XCTAssertEqual(rig.model.poolFilter.sort, .name)
        XCTAssertNil(rig.model.poolFilter.folder)
        XCTAssertEqual(rig.sent.count, 0, "nothing is sent")
    }

    /// Area 13 reading — with nothing live, the grid opens on the last thing browsed, when the catalog still has it.
    func test_withNothingLiveTheGridOpensOnTheLastThingBrowsed() throws {
        let rig = try Rig(connected: false)
        var settings = ViewSettings()
        settings.lastBrowsed = .playlist(Recorded.sundayNight)
        rig.model.load(settings: settings)
        rig.store.connected(Hello.test())
        rig.store.apply(catalog: try RecordedAPI.load("catalog"))
        var state = try RecordedAPI.load("state")
        state["events"] = .array((state.items("events") ?? []).filter { $0.objectValue?.text("topic") != "live" })
        rig.store.apply(state: state, now: rig.clock.now)
        XCTAssertEqual(rig.model.browse.shown, .playlist(Recorded.sundayNight))
        XCTAssertFalse(rig.model.isBrowsing, "With nothing live there is no amber.")

        // Something live wins; and a playlist the catalog no longer has is not opened.
        let live = try Rig(connected: false)
        live.model.load(settings: settings)
        try live.connect()
        XCTAssertEqual(live.model.browse.shown, .playlist(Recorded.sunday))
        let gone = try Rig(connected: false)
        settings.lastBrowsed = .playlist("b1a70000-0000-4000-8000-0000000000ff")
        gone.model.load(settings: settings)
        gone.store.connected(Hello.test())
        gone.store.apply(catalog: try RecordedAPI.load("catalog"))
        gone.store.apply(state: state, now: gone.clock.now)
        XCTAssertNil(gone.model.browse.shown)
    }

    /// "the window's frame": taken when the window can be reached there.
    func test_theSavedWindowFrameIsTakenWhenItsTitleBarIsOnAScreen() {
        let laptop = WindowPlacement.Rect(x: 0, y: 0, width: 1440, height: 900)
        let external = WindowPlacement.Rect(x: 1440, y: 0, width: 1920, height: 1080)
        let minimum = (width: 1440.0, height: 900.0)
        XCTAssertEqual(WindowPlacement.restored([1500, 40, 1600, 1000], screens: [laptop, external], minimum: minimum),
                       WindowPlacement.Rect(x: 1500, y: 40, width: 1600, height: 1000))
        XCTAssertNil(WindowPlacement.restored([1500, 40, 1600, 1000], screens: [laptop], minimum: minimum), "the screen it stood on is gone")
        XCTAssertNil(WindowPlacement.restored(nil, screens: [laptop], minimum: minimum))
        XCTAssertNil(WindowPlacement.restored([0, 0, 100], screens: [laptop], minimum: minimum))
        XCTAssertEqual(WindowPlacement.restored([0, 0, 800, 600], screens: [laptop], minimum: minimum),
                       WindowPlacement.Rect(x: 0, y: 0, width: 1440, height: 900), "never smaller than the window may be")
    }
}
