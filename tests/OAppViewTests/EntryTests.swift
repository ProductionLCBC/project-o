import AppKit
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// The string catalog file, for the views' tests: `swift test` has no bundle of the app's to read it from.
@MainActor
enum ViewStrings {
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // OAppViewTests
        .deletingLastPathComponent()   // tests
        .deletingLastPathComponent()   // root
        .appendingPathComponent("app/Shell/Localizable.xcstrings")

    static func install(transform: ((String) -> String)? = nil) throws {
        let file = try StringCatalogFile(contentsOf: url)
        Strings.lookup = { key, count in file.format(key, count: count) }
        Strings.transform = transform
    }
}

/// Roots kept in memory, as the app keeps them in its preferences.
@MainActor
final class MemoryRootsStore: RootsStore {
    var roots: EngineRoots?
    var campus: String?
}

/// A launcher that starts nothing and a connector nothing answers: the views' tests never start or find an engine.
final class NoLauncher: EngineLauncher, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [EngineLaunch] = []
    private var killed: [Int32] = []
    var launches: [EngineLaunch] { lock.lock(); defer { lock.unlock() }; return started }
    var kills: [Int32] { lock.lock(); defer { lock.unlock() }; return killed }

    private final class Watch: ProcessWatch, @unchecked Sendable {
        func cancel() {}
    }

    func start(_ launch: EngineLaunch) throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        started.append(launch)
        return 4000 + Int32(started.count)
    }

    func watch(pid: Int32, onExit: @escaping @Sendable (EngineExit) -> Void) -> any ProcessWatch { Watch() }
    func isRunning(pid: Int32) -> Bool { true }
    func executablePath(pid: Int32) -> String? { nil }
    func kill(pid: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        killed.append(pid)
        return false
    }
}

struct NoConnector: EngineConnector {
    func connect(to socket: URL) -> Result<any EngineTransport, ConnectFailure> { .failure(.noSocket) }
}

/// Spec 10 §4, "One main window" and "Menus" — the app's views live in a
/// package target, so `swift test` builds them and lays them out offscreen
/// with no app running and no engine (Area 13 plan: the Xcode project is a
/// shell).
@MainActor
final class EntryTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    private func controller(roots: EngineRoots? = nil) -> (AppController, MemoryRootsStore, NoLauncher) {
        let store = MemoryRootsStore()
        store.roots = roots
        let launcher = NoLauncher()
        return (AppController(rootsStore: store, launcher: launcher, connector: NoConnector(), executable: URL(fileURLWithPath: "/nowhere/oengine")), store, launcher)
    }

    func test_theDelegateOpensOneMainWindowInTheDarkAppearance() throws {
        let delegate = AppDelegate()
        delegate.openMainWindow(show: false, controller: controller().0)
        let window = try XCTUnwrap(delegate.mainWindow)
        XCTAssertEqual(window.appearance?.name, .darkAqua, "Spec 10 §4: dark only in v1")
        XCTAssertEqual(window.title, "Project O")
        delegate.openMainWindow(show: false, controller: controller().0)
        XCTAssertTrue(delegate.mainWindow === window, "one main window, however often it is asked for")
        XCTAssertGreaterThanOrEqual(window.minSize.width, min(1440, NSScreen.main?.visibleFrame.width ?? 1440) - 1, "at least 1440 by 900, or the screen's visible area")
    }

    func test_theWindowCannotBeHiddenMinimizedOrZoomedAndClosingItIsQuit() throws {
        let delegate = AppDelegate()
        delegate.openMainWindow(show: false, controller: controller().0)
        let window = try XCTUnwrap(delegate.mainWindow as? MainWindow)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, true)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isHidden, true)
        window.miniaturize(nil)
        XCTAssertFalse(window.isMiniaturized)
        let menu = try XCTUnwrap(NSApplication.shared.mainMenu)
        let titles = menu.items.flatMap { $0.submenu?.items.map(\.title) ?? [] }
        XCTAssertEqual(menu.items.first?.submenu?.items.last?.title, "Quit Project O")
        XCTAssertEqual(menu.items.first?.submenu?.items.last?.keyEquivalent, "q")
        XCTAssertFalse(titles.contains { $0.contains("Hide") || $0.contains("Minimize") || $0.contains("Zoom") }, "no Hide, Minimize or Zoom items")
        XCTAssertFalse(menu.items.contains { $0.submenu?.title == "Window" }, "and no Window menu")
    }

    /// Spec 10 §4, "Menus" — "The menu bar holds every app-level action,
    /// with these shortcuts." An entry whose area isn't built yet is there
    /// and disabled (Spec 10 §16).
    func test_theMenuBarHoldsEveryMenuAndEntryOfTheSpec() throws {
        let delegate = AppDelegate()
        delegate.openMainWindow(show: false, controller: controller().0)
        let bar = try XCTUnwrap(delegate.menuBar)
        XCTAssertEqual(bar.titles, ["Project O", "File", "Edit", "View", "Go", "Mode", "Help"])
        func entries(_ menu: String) -> [String] { bar.entries(of: menu).map { $0.title + ($0.keyEquivalent.isEmpty ? "" : " " + $0.keyEquivalent) } }
        XCTAssertEqual(entries("Project O"), ["About Project O", "Settings… ,", "Lock Station l", "Quit Project O q"])
        XCTAssertEqual(entries("File"), ["New Playlist n", "New List n", "Import Media… i", "Take Snapshot", "Restore a Snapshot…"])
        XCTAssertEqual(entries("Edit"), ["Undo z", "Redo z", "Cut x", "Copy c", "Paste v", "Select All a", "Find in List f"])
        // "in edit mode, its six pages, ⌥⌘1 to ⌥⌘6 (Spec 11 §2)".
        XCTAssertEqual(entries("View"), ["Multiviewer m", "Show Archived Playlists", "Compact Grid", "Collapse Panel", "Reset Layout", "Enter Full Screen",
                                         "Cues 1", "Text 2", "Stacks 3", "Channels 4", "Presets 5", "Objects 6"])
        XCTAssertEqual(bar.entries(of: "View").first { $0.title == "Text" }?.isEnabled, true, "the text editor, since Area 10")
        XCTAssertEqual(bar.entries(of: "View").first { $0.title == "Cues" }?.keyEquivalentModifierMask, [.option, .command])
        XCTAssertEqual(entries("Go"), ["Back to Live l", "Go to Cue… j", "Hold Auto-Advance", "Command Bar k"])
        XCTAssertEqual(entries("Mode"), ["Show 1", "Edit 2"])
        XCTAssertEqual(entries("Help"), ["Keys /", "Release Output from This Screen \u{1B}"])
        XCTAssertEqual(bar.entries(of: "Mode").first { $0.title == "Edit" }?.isEnabled, true, "Mode ▸ Edit opens edit mode (Spec 11 §2)")
        let later = ["Settings…", "Lock Station"]
        for menu in bar.titles {
            for item in bar.entries(of: menu) where later.contains(item.title) && item.submenu == nil {
                XCTAssertFalse(item.isEnabled, "\(item.title) waits for its area")
                XCTAssertEqual(item.toolTip, "Not in this build yet.")
            }
        }
        // Spec 10 §5, §6, §10, §14 — New Playlist, New List, Import Media…, the snapshot entries, Undo and Redo are the app's own now, and say nothing of a later build.
        for title in ["New Playlist", "New List", "Import Media…", "Take Snapshot", "Restore a Snapshot…", "Undo", "Redo"] {
            let item = (bar.entries(of: "File") + bar.entries(of: "Edit")).first { $0.title == title }
            XCTAssertNotNil(item, title)
            XCTAssertNil(item?.toolTip, title)
        }
        // Spec 10 §9 — the keys overlay and ⌃⌥⌘⎋ are there from the keys' build; the command bar's entry follows the machine's setting.
        for item in bar.entries(of: "Help") { XCTAssertTrue(item.isEnabled, item.title) }
        XCTAssertEqual(bar.entries(of: "Help").last?.keyEquivalentModifierMask, [.control, .option, .command], "⌃⌥⌘⎋")
        XCTAssertEqual(bar.entries(of: "Go").last?.isEnabled, false, "the command bar is off by default (`commandBar`)")
        let mods = bar.entries(of: "View").first?.keyEquivalentModifierMask
        XCTAssertEqual(mods, [.option, .command], "Multiviewer ⌥⌘M")
    }

    func test_withNoRootsYetTheFirstRunSheetAsksForThem() throws {
        let (controller, _, launcher) = controller()
        controller.start(showWindow: false)
        XCTAssertNotNil(controller.firstRun, "Spec 10 §13: a sheet asks for the campus name and where to keep the library")
        XCTAssertNil(controller.supervisor, "and no engine is looked for until it is answered")
        XCTAssertEqual(launcher.launches.count, 0)
    }

    func test_withRootsItStartsTheEngineAndSaysSo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        let (controller, _, launcher) = controller(roots: roots)
        controller.start(showWindow: false)
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertEqual(launcher.launches.first?.executable.path, "/nowhere/oengine")
        XCTAssertEqual(controller.windowController.banner.shownText, "Starting the engine…")
        XCTAssertNil(controller.firstRun)
        controller.supervisor?.leaveEngineRunning()
    }

    /// Spec 10 §2, "Quitting" — "⌘Q, or closing the main window, asks ...
    /// A logout, a restart or a shutdown doesn't ask". Spec 10 §4 — "every
    /// confirmation and file dialog is a sheet on the main window", so the
    /// app's answer to the system waits for the sheet's.
    func test_quitAsksInASheetAndALogoutOrShutdownDoesNotAsk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))

        let (system, _, _) = controller(roots: roots)
        var systemAlerts = 0
        system.presentAlert = { _, _, _ in systemAlerts += 1 }
        system.start(showWindow: false)
        XCTAssertEqual(system.shouldTerminate(systemAsked: true), .terminateNow, "the system's request is not questioned")
        XCTAssertEqual(systemAlerts, 0)
        XCTAssertFalse(system.isQuitting)

        let (asked, _, launcher) = controller(roots: roots)
        var alerts: [(alert: NSAlert, window: NSWindow, answer: @MainActor (NSApplication.ModalResponse) -> Void)] = []
        var replies: [Bool] = []
        asked.presentAlert = { alert, window, answer in alerts.append((alert, window, answer)) }
        asked.replyToTerminate = { replies.append($0) }
        asked.start(showWindow: false)
        XCTAssertEqual(asked.shouldTerminate(systemAsked: false), .terminateLater, "the answer waits for the sheet")
        XCTAssertEqual(alerts.count, 1)
        let question = try XCTUnwrap(alerts.first)
        XCTAssertEqual(question.alert.messageText, "Quit Project O? The outputs will stop.")
        XCTAssertEqual(question.alert.buttons.map(\.title), ["Cancel", "Quit", "Keep outputs running"])
        XCTAssertEqual(question.alert.buttons.map(\.keyEquivalent), ["\u{1B}", "", ""],
                       "Spec 10 §9: a button that quits is never the default, so Return can't press it; Escape cancels")
        XCTAssertTrue(question.window === asked.windowController.window, "Spec 10 §4: a sheet on the main window")
        XCTAssertEqual(asked.shouldTerminate(systemAsked: false), .terminateLater)
        XCTAssertEqual(alerts.count, 1, "a second ⌘Q asks nothing more")

        question.answer(.alertFirstButtonReturn)
        XCTAssertEqual(replies, [false], "Cancel: the app goes on")
        XCTAssertFalse(asked.isQuitting)

        XCTAssertEqual(asked.shouldTerminate(systemAsked: false), .terminateLater)
        XCTAssertEqual(alerts.count, 2, "and can be asked again")
        alerts[1].answer(.alertThirdButtonReturn)
        XCTAssertEqual(replies, [false, true], "Keep outputs running: the app quits")
        XCTAssertEqual(launcher.kills, [], "and the engine is left as it is")

        let (firstRun, _, _) = controller()
        var firstRunAlerts = 0
        firstRun.presentAlert = { _, _, _ in firstRunAlerts += 1 }
        firstRun.start(showWindow: false)
        XCTAssertEqual(firstRun.shouldTerminate(systemAsked: false), .terminateNow, "with no engine there is nothing to stop, so nothing to ask")
        XCTAssertEqual(firstRunAlerts, 0)
    }

    /// Spec 10 §2, "When it doesn't answer" — Restart the engine "says the
    /// screens go black for a moment"; Spec 10 §9 — Return can't press it.
    func test_restartTheEngineAsksFirstInASheetAndCancelLeavesTheEngineAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        let (controller, _, launcher) = controller(roots: roots)
        var alerts: [(alert: NSAlert, answer: @MainActor (NSApplication.ModalResponse) -> Void)] = []
        controller.presentAlert = { alert, _, answer in alerts.append((alert, answer)) }
        controller.start(showWindow: false)
        controller.askToRestart()
        let question = try XCTUnwrap(alerts.first)
        XCTAssertEqual(question.alert.messageText, "Restart the engine?")
        XCTAssertEqual(question.alert.informativeText, "The screens go black for a moment.")
        XCTAssertEqual(question.alert.buttons.map(\.title), ["Cancel", "Restart the engine"])
        XCTAssertEqual(question.alert.buttons.map(\.keyEquivalent), ["\u{1B}", ""], "Return can't press Restart the engine; Escape cancels")
        question.answer(.alertFirstButtonReturn)
        XCTAssertEqual(launcher.launches.count, 1, "Cancel: nothing is started again")
        XCTAssertEqual(launcher.kills, [])
        controller.supervisor?.leaveEngineRunning()
    }

    /// Spec 10 §9 — "A button that deletes, restores or quits is never a
    /// sheet's default, so Return can't press it". AppKit gives Escape to a
    /// button called "Cancel" in English; the app sets the keys itself, so
    /// the rule holds in a language where it is called something else.
    func test_returnPressesNoButtonOnAConfirmationWhateverTheLanguage() throws {
        try ViewStrings.install(transform: Pseudolanguage.accented)
        addTeardownBlock { @MainActor in try? ViewStrings.install() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oapp-view-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let roots = EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        let (controller, _, _) = controller(roots: roots)
        var alerts: [NSAlert] = []
        controller.presentAlert = { alert, _, _ in alerts.append(alert) }
        controller.replyToTerminate = { _ in }
        controller.start(showWindow: false)
        controller.askToRestart()
        _ = controller.shouldTerminate(systemAsked: false)
        XCTAssertEqual(alerts.count, 2)
        for alert in alerts {
            XCTAssertNotEqual(alert.buttons.first?.title, "Cancel", "the pseudolanguage renames it")
            XCTAssertEqual(alert.buttons.first?.keyEquivalent, "\u{1B}", "Escape cancels")
            XCTAssertEqual(alert.buttons.dropFirst().map(\.keyEquivalent).filter { !$0.isEmpty }, [], "and no other button has a key")
        }
        controller.supervisor?.leaveEngineRunning()
    }

    func test_theWindowShowsEachPlaceTheAppCanStandWithTheEngine() {
        let window = MainWindowController()
        window.show(.connected)
        XCTAssertTrue(window.banner.isHidden)
        window.show(.restarting(ends: 1, console: []))
        XCTAssertEqual(window.banner.shownText, "The engine stopped. Restarting…")
        XCTAssertFalse(window.banner.offersRestart)
        window.show(.restarting(ends: 3, console: ["line one", "line two"]))
        XCTAssertEqual(window.banner.shownText, "The engine has stopped 3 times. Restarting…")
        XCTAssertEqual(window.banner.shownConsole, "line one\nline two")
        window.show(.notResponding)
        XCTAssertEqual(window.banner.shownText, "The engine isn’t responding")
        XCTAssertTrue(window.banner.offersRestart)
        var pressed = 0
        window.banner.onRestart = { pressed += 1 }
        window.banner.pressRestart()
        XCTAssertEqual(pressed, 1)
    }

    /// Spec 10 §2, "Versions" — with an engine of another build connected
    /// "the banner says so and offers Restart the engine for as long as the
    /// builds differ": a line that interrupts nothing, over a window that
    /// works as it does with any engine.
    func test_anEngineOfAnotherBuildIsSaidInTheBannerWhileTheWindowWorks() {
        let window = MainWindowController()
        window.show(.connected, anotherBuild: AnotherBuild(engine: "0.9.0", app: "1.0.0"))
        XCTAssertFalse(window.banner.isHidden)
        XCTAssertEqual(window.banner.shownText, "The engine running is version 0.9.0 and this is Project O 1.0.0. Restart it when the screens can go black for a moment.")
        XCTAssertTrue(window.banner.offersRestart)
        window.show(.connected, anotherBuild: nil)
        XCTAssertTrue(window.banner.isHidden, "the same build: no banner")
    }

    func test_whileAnOutputCoversTheWindowPointerEventsAreDroppedAndKeysAreNot() {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown, .scrollWheel] {
            XCTAssertTrue(MainWindow.isPointerEvent(type), "presses, drags and scrolls")
        }
        for type: NSEvent.EventType in [.keyDown, .keyUp, .flagsChanged, .mouseMoved] {
            XCTAssertFalse(MainWindow.isPointerEvent(type), "the keys keep working")
        }
        let window = MainWindowController().window
        XCTAssertTrue(window.takesClicks)
    }

    func test_everyControlInTheWindowHasALabelForVoiceOver() throws {
        let window = MainWindowController()
        for phase: EngineSupervisor.Phase in [.starting, .notResponding, .noSocket(console: ["a line"]), .restarting(ends: 4, console: ["a line"]), .wrongAPI(engine: "0.9.0")] {
            window.show(phase)
            XCTAssertEqual(Audit.unlabeled(in: try XCTUnwrap(window.window.contentView)), [], "Spec 10 §15: every control has a label (\(phase))")
            XCTAssertEqual(window.banner.accessibilityLabel(), window.banner.shownText)
        }
    }

    func test_nothingInTheBannerIsClippedUnderEitherPseudolanguage() throws {
        // Spec 10 §18 — "at 1440 by 900, under the accented pseudolanguage and one 40% longer, nothing is clipped".
        for transform in [Pseudolanguage.accented, Pseudolanguage.longer] {
            try ViewStrings.install(transform: transform)
            let banner = BannerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 60))
            for phase: EngineSupervisor.Phase in [.starting, .notResponding, .noSocket(console: []), .noHello, .restarting(ends: 12, console: []),
                                                  .wrongAPI(engine: "10.20.30"), .firstRunRefused(console: []), .connected] {
                banner.show(EngineBanner.make(for: phase, anotherBuild: AnotherBuild(engine: "10.20.30", app: "10.20.31")))
                banner.layoutSubtreeIfNeeded()
                var widest: CGFloat = 0
                func walk(_ view: NSView) {
                    if let field = view as? NSTextField, !field.isHidden, field.maximumNumberOfLines == 1 || field.lineBreakMode == .byTruncatingTail {
                        widest = max(widest, field.intrinsicContentSize.width)
                    }
                    for subview in view.subviews { walk(subview) }
                }
                walk(banner)
                XCTAssertLessThan(widest, 1440 - 28 - 200, "\(phase): the sentence fits beside the button at 1440 points")
            }
        }
        try ViewStrings.install()
    }

    func test_theFirstRunSheetsModelStartsFromTheDefaultsAndNamesWhatIsWrong() throws {
        let home = URL(fileURLWithPath: "/Users/operator")
        let places = MediaPlaces(home: home.path, isOnStartupVolume: { _ in true })
        let model = FirstRunModel(home: home, places: places, contents: { _ in nil })
        XCTAssertEqual(model.folder.path, "/Users/operator/Project O")
        XCTAssertEqual(model.sentences, ["Enter the campus name."])
        model.campus = "Manheim"
        XCTAssertEqual(model.problems, [])
        XCTAssertEqual(model.choice?.roots.machine.path, "/Users/operator/Project O/machine")
        model.mode = .existing
        XCTAssertNil(model.choice, "no folder is picked for the library yet")
        XCTAssertEqual(model.sentences, ["Choose a folder for the library."])
        model.library = home.appendingPathComponent("Synced/LCBC Library")
        XCTAssertEqual(model.sentences, ["That folder holds no library: there is no library.json in it."])
    }
}
