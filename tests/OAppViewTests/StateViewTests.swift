import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 10 §14 — the saving and engine tags, the last state's banner and the
/// snapshots sheet as the window shows them; §8 — the tags that open
/// something; §4 — `view.json` as the app reads and writes it.
@MainActor
final class StateViewTests: XCTestCase {
    typealias Rig = DropsViewTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private func engine(_ rig: Rig, _ change: (inout [String: JSONValue]) -> Void) throws {
        var event = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["engine"]?.objectValue)
        event["run"] = .string("51e2")
        change(&event)
        rig.store.apply(event: "engine", event, now: rig.clock.now)
    }

    private func saving(_ rig: Rig, unsaved: Int, disk: String = "ok", log: String = "file") throws {
        var event = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["saving"]?.objectValue)
        event["unsaved"] = .number(Double(unsaved))
        event["disk"] = .string(disk)
        event["log"] = .string(log)
        rig.store.apply(event: "saving", event, now: rig.clock.now)
    }

    /// The saving and engine tags that show; the recorded state's own two, "Audio lost" and "Popup 1", stand throughout.
    private func tags(_ rig: Rig) -> [String] {
        rig.view.topBar.shownTags.filter { !["Audio lost", "Popup 1"].contains($0) }
    }

    private func button(_ title: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> FlatButton {
        try XCTUnwrap(rig.view.topBar.tagButtons.first { $0.title == title }, title, file: file, line: line)
    }

    // MARK: - The tags (Spec 10 §8, §14)

    /// "amber "Unsaved (3)" when documents have waited more than five
    /// seconds to be written ... A click lists how many documents are waiting ..., with Reveal
    /// in Finder for the machine folder."
    func test_theSavingTagShowsAfterItsWaitAndAClickListsWhatWaits() throws {
        let rig = try Rig()
        try saving(rig, unsaved: 3)
        XCTAssertEqual(tags(rig), [], "a write that is a moment late says nothing")
        rig.clock.advance(by: 5.1)
        XCTAssertEqual(tags(rig), ["Unsaved (3)"])
        XCTAssertEqual(rig.view.topBar.shownTags.last, "Unsaved (3)", "the saving tag comes last (§8)")
        let tag = try button("Unsaved (3)", in: rig)
        XCTAssertEqual(tag.tagStyle, .amber)
        let menu = rig.view.topBar.savingMenu
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["3 documents are waiting to be written", "Reveal the Machine Folder in Finder"])
        XCTAssertEqual(menu.items.first?.isEnabled, false, "a line to read, not to choose")
        try XCTUnwrap(menu.entry("Reveal the Machine Folder in Finder")).choose()
        XCTAssertEqual(rig.revealed.map(\.path), ["/tmp/o/machine"])
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(Audit.unlabelled(in: rig.view.topBar), [])
        XCTAssertGreaterThan(tag.frame.width, 20)
        // "red "Disk full: changes not saved" with the log in memory."
        try saving(rig, unsaved: 2, disk: "full", log: "memory")
        XCTAssertEqual(tags(rig), ["Disk full: changes not saved"])
        XCTAssertEqual(try button("Disk full: changes not saved", in: rig).tagStyle, .red)
        XCTAssertEqual(rig.view.topBar.savingMenu.items.prefix(3).map(\.title),
                       ["2 documents are waiting to be written", "The disk is full: changes are kept in memory and aren’t saved.", "The log is kept in memory until the disk has room."])
        try saving(rig, unsaved: 0, disk: "low")
        XCTAssertEqual(tags(rig), ["Disk low"])
        try saving(rig, unsaved: 0)
        XCTAssertEqual(tags(rig), [])
    }

    /// "the engine tag while a badge stands, which lists them (§14)"; ""Popup
    /// 1" while a slot is set, which opens the Popups tab".
    func test_theEngineTagListsItsBadgesAndThePopupTagOpensThePopupsTab() throws {
        let rig = try Rig()
        try engine(rig) { $0["badges"] = .array([.object(["kind": .string("thermal"), "level": .string("serious")]), .object(["kind": .string("gpu")])]) }
        XCTAssertEqual(tags(rig), ["2 engine notices"])
        XCTAssertEqual(rig.view.topBar.engineMenu.items.map(\.title), ["The Mac is hot and may slow down", "The graphics card was reset"])
        XCTAssertTrue(try button("2 engine notices", in: rig).acceptsFirstResponder, "the tag is a button, and takes the keyboard focus like any other")
        XCTAssertEqual(try button("2 engine notices", in: rig).tagStyle, .amber)
        // The popup tag, which the recorded state shows.
        let popup = try button("Popup 1", in: rig)
        rig.model.change { $0.tabbedPanelCollapsed = true }
        try button("Popup 1", in: rig).press()
        XCTAssertEqual(rig.view.tabs.tab, .popups)
        XCTAssertFalse(rig.model.settings.tabbedPanelCollapsed, "a panel that was folded away is opened")
        XCTAssertEqual(popup.tagStyle, .quiet)
        // "Audio lost" opens nothing, and is a word alone.
        XCTAssertTrue(rig.view.topBar.shownTags.contains("Audio lost"))
        XCTAssertFalse(rig.view.topBar.tagButtons.contains { $0.title == "Audio lost" })
    }

    // MARK: - The last state (Spec 10 §14)

    func test_theBannerOverTheGridSaysWhatWasPutBackAndIsDismissedForTheRun() throws {
        let rig = try Rig()
        XCTAssertNil(rig.view.grid.restoreLine)
        // A timer was running when the engine ended; the next engine puts the last state back.
        var timer = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["timers.set"]?.objectValue)
        timer["state"] = .string("running")
        rig.store.apply(event: "timers", timer, now: rig.clock.now)
        rig.store.disconnected()
        rig.store.connected(Hello(api: Hello.api, engine: OCore.appVersion, pid: 2, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2"))
        rig.store.apply(state: try ShowWindowTests.Rig.load("state"), now: rig.clock.now)
        try engine(rig) {
            $0["lastState"] = .object(["restored": .bool(true), "writtenAt": .null,
                                       "left": .array([.object(["kind": .string("channel"), "number": .number(4), "why": .string("gone")])])])
        }
        rig.view.layoutSubtreeIfNeeded()
        let line = try XCTUnwrap(rig.view.grid.restoreLine)
        XCTAssertEqual(line.text.stringValue,
                       "Picked up where the engine stopped. Video started again from the top. Channel 4 no longer exists. Timers came back unset.")
        XCTAssertFalse(line.setTimers.isHidden)
        XCTAssertTrue(line.fireAgain.isHidden)
        XCTAssertEqual(Audit.unlabelled(in: line), [])
        XCTAssertFalse(Audit.isCutOff(line.text), "the banner grows rather than cut a sentence short")
        XCTAssertEqual(line.frame.minY, 0, "over the grid's header")
        XCTAssertGreaterThanOrEqual(rig.view.grid.title.frame.minY, line.frame.maxY)
        line.setTimers.press()
        XCTAssertEqual(rig.commands.last, ["timer 1 set 5:00", "timer 1 start"])
        XCTAssertEqual(try XCTUnwrap(rig.view.grid.restoreLine).setTimers.isHidden, true, "offered once")
        try XCTUnwrap(rig.view.grid.restoreLine).dismiss.press()
        XCTAssertNil(rig.view.grid.restoreLine)
        XCTAssertEqual(rig.model.settings.dismissedRestoreRun, "51e2", "it stays away for that run")
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(rig.view.grid.title.frame.minY, 30, "and the grid takes its place back")
    }

    func test_whenNothingWasPutBackTheBannerOffersToFireAgain() throws {
        let rig = try Rig()
        rig.store.disconnected()
        rig.store.connected(Hello(api: Hello.api, engine: OCore.appVersion, pid: 2, machine: "7a7a", run: "51e2", mach: "org.lcbc.projecto.engine.51e2"))
        var state = try ShowWindowTests.Rig.load("state")
        state["events"] = .array((state["events"]?.arrayValue ?? []).filter { $0.objectValue?["topic"] != .string("live") })
        rig.store.apply(state: state, now: rig.clock.now)
        rig.store.apply(event: "live", ["topic": .string("live"), "gone": .array([])], now: rig.clock.now)
        try engine(rig) { $0["lastState"] = .object(["restored": .bool(false), "reason": .string("old")]) }
        let line = try XCTUnwrap(rig.view.grid.restoreLine)
        XCTAssertEqual(line.text.stringValue, "Nothing was put back: what was on the screens was saved more than two hours ago.")
        XCTAssertEqual(line.fireAgain.title, "Fire 1 Verse 1 again")
        XCTAssertTrue(line.setTimers.isHidden)
        line.fireAgain.press()
        XCTAssertEqual(rig.commands.last, ["playlist \"Sunday\"", "item 2 cue 1"])
        XCTAssertEqual(try XCTUnwrap(rig.view.grid.restoreLine).fireAgain.isHidden, true)
    }

    // MARK: - Snapshots (Spec 10 §14)

    /// "Restore a Snapshot… ... opens the snapshots ... Restore asks ... the
    /// sheet shows it working until its result. A refusal is shown with its
    /// reason in plain words".
    func test_theSnapshotsSheetRestoresAndShowsItWorkingAndARefusal() throws {
        let rig = try Rig()
        rig.view.restoreSnapshot()
        XCTAssertEqual(rig.sent.first?.fields["what"], .string("snapshots"))
        XCTAssertNil(rig.view.sheetView, "the sheet opens once the engine has answered")
        rig.answers[0](.answer(try ShowWindowTests.Rig.load("snapshots")))
        let sheet = try XCTUnwrap(rig.view.sheetView)
        XCTAssertEqual(sheet.heading.stringValue, "Snapshots")
        XCTAssertEqual(sheet.titles.count, 1)
        XCTAssertTrue(sheet.details[0].stringValue.hasPrefix("taken at launch · "), sheet.details[0].stringValue)
        sheet.layoutSubtreeIfNeeded()
        XCTAssertEqual(Audit.unlabelled(in: sheet), [])
        sheet.buttons[0].press()
        XCTAssertEqual(rig.asked.count, 1)
        guard case .restoreSnapshot? = rig.asked.first else { return XCTFail("\(rig.asked)") }
        XCTAssertEqual(rig.commands.last, ["system restore snapshot \"2026-10-30-100000\""])
        XCTAssertEqual(sheet.status.stringValue, "Restoring…")
        XCTAssertFalse(sheet.buttons[0].isEnabled, "one restore at a time")
        XCTAssertNotNil(rig.view.sheetView, "the sheet stays up until the result")
        rig.answers[1](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "onAir", message: "channel 2 is on air in stack 1"))))
        XCTAssertEqual(sheet.status.stringValue, "Not restored. " + EditWording.rejection(code: "onAir") + " The engine says: channel 2 is on air in stack 1")
        XCTAssertEqual(sheet.status.textColor, Palette.live)
        XCTAssertTrue(sheet.buttons[0].isEnabled, "and it can be tried again")
        sheet.buttons[0].press()
        rig.answers[2](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(sheet.status.stringValue, "Restored. Undo puts it back.")
        sheet.close.press()
        XCTAssertNil(rig.view.sheetView)
        // With no snapshot yet, the sheet says so.
        rig.view.restoreSnapshot()
        rig.answers[3](.answer(["snapshots": .array([])]))
        XCTAssertEqual(try XCTUnwrap(rig.view.sheetView).empty.stringValue, "There are no snapshots yet.")
        XCTAssertEqual(rig.view.sheetView?.empty.isHidden, false)
        rig.view.closeSheet()
        // Under the lock the picker doesn't open (§12).
        try rig.lock()
        rig.view.restoreSnapshot()
        XCTAssertEqual(rig.sent.count, 4)
        XCTAssertNil(rig.view.sheetView)
    }

    /// File ▸ Take Snapshot and Restore a Snapshot… (Spec 10 §4, §12).
    func test_theFileMenusSnapshotEntriesFollowTheLock() throws {
        let rig = try EditMenuTests.Rig()
        func entry(_ title: String) throws -> ClosureMenuItem {
            rig.bar.refresh()
            return try XCTUnwrap(rig.bar.entries(of: "File").first { $0.title == title } as? ClosureMenuItem, title)
        }
        XCTAssertTrue(try entry("Take Snapshot").isEnabled)
        XCTAssertTrue(try entry("Restore a Snapshot…").isEnabled)
        XCTAssertTrue(try entry("Import Media…").isEnabled)
        try entry("Take Snapshot").choose()
        XCTAssertEqual(rig.sent.last?.fields["command"]?.objectValue?["cmd"], .string("system.snapshot"))
        try entry("Restore a Snapshot…").choose()
        XCTAssertEqual(rig.sent.last?.fields["what"], .string("snapshots"))
        var locked = try XCTUnwrap(try ShowWindowTests.Rig.load("events")["engine"]?.objectValue)
        locked["lock"] = .bool(true)
        rig.controller.store.apply(event: "engine", locked, now: 0)
        XCTAssertTrue(try entry("Take Snapshot").isEnabled, "Take Snapshot works under the lock")
        XCTAssertFalse(try entry("Restore a Snapshot…").isEnabled)
        XCTAssertFalse(try entry("Import Media…").isEnabled)
    }

    // MARK: - view.json (Spec 10 §4; §18, "view settings")

    /// "the app writes nothing else in the roots but the console log it
    /// opens"; and what `view.json` held at launch is the window's layout.
    func test_theAppReadsViewJsonAtLaunchAndWritesNothingElseInTheRoots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        try FileManager.default.createDirectory(at: roots.library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: roots.machine, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: roots.machine.appendingPathComponent("machine.json"))
        var saved = ViewSettings()
        saved.leftColumnWidth = 300
        saved.multiviewer = true
        XCTAssertTrue(ViewSettingsFile.write(saved, machineRoot: roots.machine))

        let store = MemoryRootsStore()
        store.roots = roots
        let controller = AppController(rootsStore: store, launcher: NoLauncher(), connector: NoConnector(), executable: URL(fileURLWithPath: "/nowhere/oengine"),
                                       releaseKey: FakeReleaseKey())
        controller.start(showWindow: false)
        defer { controller.supervisor?.leaveEngineRunning() }
        XCTAssertEqual(controller.model.settings, saved, "the file's settings take the defaults' place")
        controller.windowController.regions.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.windowController.regions.left.frame.width, 300)
        // A change is written, here at once as the app does before it quits.
        controller.model.change { $0.showsNotes = true }
        XCTAssertEqual(ViewSettingsFile.read(machineRoot: roots.machine), saved, "not before its second is up")
        controller.saveViewSettingsNow()
        saved.showsNotes = true
        XCTAssertEqual(ViewSettingsFile.read(machineRoot: roots.machine), saved)
        // Everything in both roots: the documents that were there, `view.json`, and at most the engine's console log.
        var files: [String] = []
        for root in [roots.library, roots.machine] {
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1)))
            }
        }
        XCTAssertEqual(Set(files).subtracting(["machine/logs/engine-console.log"]), ["machine/machine.json", "machine/view.json"])
    }

    /// Before the engine's first run has made the machine's documents, the app writes nothing there (§13).
    func test_nothingIsWrittenBeforeTheFirstRunHasMadeTheMachine() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        try FileManager.default.createDirectory(at: roots.machine, withIntermediateDirectories: true)
        let store = MemoryRootsStore()
        store.roots = roots
        store.campus = "Manheim"
        let controller = AppController(rootsStore: store, launcher: NoLauncher(), connector: NoConnector(), executable: URL(fileURLWithPath: "/nowhere/oengine"),
                                       releaseKey: FakeReleaseKey())
        controller.start(showWindow: false)
        defer { controller.supervisor?.leaveEngineRunning() }
        controller.model.change { $0.showsNotes = true }
        controller.saveViewSettingsNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ViewSettingsFile.url(machineRoot: roots.machine).path))
        // Once the engine has written `machine.json`, the change that waited is written.
        try Data("{}".utf8).write(to: roots.machine.appendingPathComponent("machine.json"))
        controller.saveViewSettingsNow()
        XCTAssertTrue(ViewSettingsFile.read(machineRoot: roots.machine).showsNotes)
    }
}
