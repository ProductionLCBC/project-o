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
    var launches: [EngineLaunch] { lock.lock(); defer { lock.unlock() }; return started }

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
    func kill(pid: Int32) -> Bool { false }
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
        XCTAssertEqual(titles.filter { !$0.isEmpty }, ["About Project O", "Quit Project O"])
        XCTAssertEqual(menu.items.first?.submenu?.items.last?.keyEquivalent, "q")
        XCTAssertFalse(titles.contains { $0.contains("Hide") || $0.contains("Minimize") || $0.contains("Zoom") }, "no Hide, Minimize or Zoom items")
        XCTAssertEqual(menu.items.count, 1, "and no Window menu")
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

    func test_theWindowShowsEachPlaceTheAppCanStandWithTheEngine() {
        let window = MainWindowController()
        window.show(.connected)
        XCTAssertTrue(window.banner.isHidden)
        XCTAssertEqual(window.shownStatus, "Connected to the engine.")
        window.show(.restarting(ends: 1, console: []))
        XCTAssertEqual(window.banner.shownText, "The engine stopped. Restarting…")
        XCTAssertFalse(window.banner.offersRestart)
        XCTAssertEqual(window.shownStatus, "")
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
            var unlabelled: [String] = []
            func walk(_ view: NSView) {
                if let control = view as? NSControl, !control.isHidden {
                    let label = control.accessibilityLabel() ?? (control as? NSButton)?.title ?? (control as? NSTextField)?.stringValue ?? ""
                    if label.isEmpty { unlabelled.append("\(type(of: control))") }
                }
                for subview in view.subviews { walk(subview) }
            }
            walk(try XCTUnwrap(window.window.contentView))
            XCTAssertEqual(unlabelled, [], "Spec 10 §15: every control has a label (\(phase))")
            XCTAssertEqual(window.banner.accessibilityLabel(), window.banner.shownText)
        }
    }

    func test_nothingInTheBannerIsClippedUnderEitherPseudolanguage() throws {
        // Spec 10 §18 — "at 1440 by 900, under the accented pseudolanguage and one 40% longer, nothing is clipped".
        for transform in [Pseudolanguage.accented, Pseudolanguage.longer] {
            try ViewStrings.install(transform: transform)
            let banner = BannerView(frame: NSRect(x: 0, y: 0, width: 1440, height: 60))
            for phase: EngineSupervisor.Phase in [.starting, .notResponding, .noSocket(console: []), .noHello, .restarting(ends: 12, console: []),
                                                  .wrongAPI(engine: "10.20.30"), .firstRunRefused(console: [])] {
                banner.show(EngineBanner.make(for: phase))
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
