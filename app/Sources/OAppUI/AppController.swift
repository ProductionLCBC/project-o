// OAppUI — Spec 10 §2, the app's dealing with the engine, shown: the window, the questions it asks, the curtains.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OApp
import OCore

/// Spec 10 §2 — ties the supervisor to what the operator sees: the banner,
/// the first-run sheet, what Restart the engine and Quit ask first, the
/// curtains on the output screens, and the window while an output covers it.
@MainActor
final class AppController {
    let store = ShowStore()
    /// The show-mode window's model, the Mach channel it draws from, and the window.
    let model: ShowModel
    let mach: MachLink
    let windowController: MainWindowController
    private let rootsStore: any RootsStore
    private let launcher: any EngineLauncher
    private let connector: any EngineConnector
    private let clock: any AppClock
    private let executable: URL
    private(set) var supervisor: EngineSupervisor?
    private var curtains: [String: NSWindow] = [:]
    private var notePanel: NSPanel?
    private var noteTask: (any ClockTask)?
    private var coveredBy: Int?
    /// The first-run sheet's model while the sheet is up (Spec 10 §13).
    private(set) var firstRun: FirstRunModel?
    /// Spec 10 §9, "Fixed keys" — ⌃⌥⌘⎋: what it does, and how the system is asked for the key.
    let releaser: ScreenReleaser
    private let releaseKey: any ReleaseKey
    /// "The app remembers the screens it released while it runs".
    var releasedScreens: [String] { releaser.released }
    /// Which engine the window drives (Spec 10 §2).
    private let wiring: SessionWiring
    /// Spec 10 §4 — what writes `machine/view.json` "a second after the last change".
    private var saver: ViewSettingsSaver?

    init(rootsStore: any RootsStore = DefaultsRootsStore(), launcher: any EngineLauncher = PosixEngineLauncher(),
         connector: any EngineConnector = UnixEngineConnector(), clock: any AppClock = SystemAppClock(),
         executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oengine"),
         releaseKey: any ReleaseKey = SystemReleaseKey()) {
        self.rootsStore = rootsStore
        self.launcher = launcher
        self.connector = connector
        self.clock = clock
        self.executable = executable
        self.releaseKey = releaseKey
        model = ShowModel(store: store, clock: clock)
        mach = MachLink(clock: clock)
        releaser = ScreenReleaser(clock: clock)
        wiring = SessionWiring(model: model, mach: mach, releaser: releaser)
        windowController = MainWindowController(model: model, mach: mach, clock: clock)
        model.doubleClickInterval = { NSEvent.doubleClickInterval }
        windowController.banner.onRestart = { [weak self] in self?.askToRestart() }
        // Spec 10 §4 — "every confirmation and file dialog is a sheet on the main window".
        model.confirm = { [weak self] confirmation, answer in self?.ask(confirmation, answer) }
        windowController.regions.chooseFiles = { [weak self] choice, answer in self?.chooseFiles(choice, answer) }
        windowController.regions.reveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        releaser.onRaised = { [weak self] raised in self?.raiseWindow(raised) }
        // "If the engine doesn't answer within two seconds, the window stays raised with the not-responding banner (§2)".
        releaser.onSilent = { [weak self] in self?.supervisor?.engineIsSilent() }
        store.observe { [weak self] changes in
            if !changes.isDisjoint(with: [.catalog, .outputs, .devices, .connection]) { self?.screensChanged() }
        }
        // Spec 10 §15 — Increase Contrast and Reduce Motion, at launch and whenever the operator changes them.
        followDisplayOptions()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followDisplayOptions() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // "moved by hand": the window landed on another screen.
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: windowController.window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - Starting

    /// Spec 10 §2 — with roots in the preferences the engine is found or
    /// started; without, Spec 10 §13's sheet asks for them first.
    func start(showWindow: Bool = true) {
        if showWindow {
            windowController.window.center()
            windowController.window.makeKeyAndOrderFront(nil)
            // Spec 10 §4, "Focus" — no field has the keys until the operator puts the cursor in one.
            windowController.window.makeFirstResponder(windowController.regions)
        }
        if let roots = rootsStore.roots {
            startEngine(roots)
        } else {
            askForRoots()
        }
    }

    private func startEngine(_ roots: EngineRoots) {
        let supervisor = EngineSupervisor(roots: roots, store: store, launcher: launcher, connector: connector, clock: clock,
                                          settings: .init(executable: executable))
        supervisor.operatorScreen = { [weak self] in (self?.windowController.window.screen ?? NSScreen.main)?.deviceName }
        supervisor.releasedScreens = { [weak self] in self?.releasedScreens ?? [] }
        supervisor.campus = { [weak self] in self?.rootsStore.campus }
        supervisor.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        supervisor.onConnected = { [weak self] session in self?.connected(session) }
        // Spec 10 §13 — the app starts a first run when the machine root has no `machine.json` yet.
        model.isFirstRun = roots.isFirstRun
        windowController.regions.machineRoot = roots.machine
        startViewSettings(roots)
        // Spec 8 §3, "Staged" — a file from outside the folders the engine reads is copied into the staging folder first.
        if let staging = FileStager.standardFolder {
            model.imports.stager = FileStager(staging: staging) { [weak self] in
                [roots.library, roots.machine] + (self?.model.mediaRoot(machineRoot: roots.machine).map { [$0] } ?? [])
            }
        }
        self.supervisor = supervisor
        supervisor.start()
        phaseChanged(supervisor.phase)
    }

    /// Spec 10 §2 — the window says where the app stands with the engine,
    /// and, with an engine of another build connected, that: the banner
    /// "says so and offers Restart the engine for as long as the builds
    /// differ" ("Versions").
    /// Spec 10 §2 — a session with an engine: the window's actions go
    /// through it, it holds the lists the grid shows, and the Mach channel
    /// its `hello` names carries the pictures.
    private func connected(_ session: EngineSession) {
        wiring.connected(session)
    }

    private func phaseChanged(_ phase: EngineSupervisor.Phase) {
        // Spec 10 §2 — nothing is sent while the engine is away, and nothing kept for later.
        wiring.phaseChanged(phase)
        windowController.show(phase, anotherBuild: supervisor?.anotherBuild)
        screensChanged()
        // Adam's answer, 2026-11-17 — a refused first run stops and shows the sheet again.
        if case .firstRunRefused = phase { askForRoots() }
    }

    // MARK: - Sheets (Spec 10 §4)

    /// Spec 10 §4 — "every confirmation and file dialog is a sheet on the
    /// main window". How an alert is put up, as a seam, so a test can read
    /// the alert and give its answer with no window on a screen.
    var presentAlert: @MainActor (NSAlert, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void = { alert, window, answer in
        alert.beginSheetModal(for: window) { response in answer(response) }
    }

    /// Spec 10 §9 — "A button that deletes, restores or quits is never a
    /// sheet's default, so Return can't press it". The first button, Cancel,
    /// takes Escape and no button takes Return, set here and not left to
    /// AppKit, which goes by the button's title in English.
    static func keepReturnFromPressing(_ alert: NSAlert) {
        for (index, button) in alert.buttons.enumerated() {
            button.keyEquivalent = index == 0 ? "\u{1B}" : ""
        }
    }

    /// Spec 10 §5, §10, §14 — asks before a delete or a restore: a sheet
    /// with Cancel and the button that does it. Escape cancels, and Return
    /// presses nothing (§9).
    func ask(_ confirmation: Confirmation, _ answer: @escaping @MainActor (Bool) -> Void) {
        let words = EditWording.words(confirmation)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.title
        alert.informativeText = words.body.joined(separator: "\n")
        alert.addButton(withTitle: Strings.text(.cancel))
        alert.addButton(withTitle: words.button)
        Self.keepReturnFromPressing(alert)
        presentAlert(alert, sheetParent) { response in answer(response == .alertSecondButtonReturn) }
    }

    /// How the app answers the system once Quit's question is answered; a seam, since the real one ends the process.
    var replyToTerminate: @MainActor (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) }

    /// The window a new sheet goes on: the main window, or the sheet already on it.
    private var sheetParent: NSWindow {
        windowController.window.attachedSheet ?? windowController.window
    }

    // MARK: - The system's accessibility settings (Spec 10 §15)

    private func followDisplayOptions() {
        windowController.regions.follow(increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    // MARK: - View settings (Spec 10 §4)

    /// Spec 10 §4, "View settings" — reads `machine/view.json`, puts the
    /// window where it was, and from then on writes the file "a second
    /// after the last change". It is the one file the app writes in the
    /// roots, and not before the engine's first run has made the machine's
    /// documents (§13).
    private func startViewSettings(_ roots: EngineRoots) {
        let loaded = ViewSettingsFile.read(machineRoot: roots.machine)
        model.load(settings: loaded)
        let window = windowController.window
        let screens = NSScreen.screens.map { WindowPlacement.Rect(x: Double($0.frame.minX), y: Double($0.frame.minY), width: Double($0.frame.width), height: Double($0.frame.height)) }
        if let frame = WindowPlacement.restored(loaded.windowFrame, screens: screens, minimum: (Double(window.minSize.width), Double(window.minSize.height))) {
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: true)
        }
        let saver = ViewSettingsSaver(clock: clock) { settings in
            guard !roots.isFirstRun else { return false }
            return ViewSettingsFile.write(settings, machineRoot: roots.machine)
        }
        self.saver = saver
        model.onSettings = { [weak saver] settings in saver?.changed(settings) }
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMoved() }
            }
        }
    }

    /// "the window's frame": kept as the window is moved or sized, but not while it is full screen.
    private func windowMoved() {
        let window = windowController.window
        guard window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        let frame = window.frame
        model.windowMoved(to: [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)])
    }

    /// Writes what is waiting, as the app does before it quits.
    func saveViewSettingsNow() {
        saver?.flush()
    }

    // MARK: - File dialogs (Spec 10 §4, §6)

    /// How a file dialog is put up, as a seam, as `presentAlert` is: "every
    /// confirmation and file dialog is a sheet on the main window".
    var presentOpenPanel: @MainActor (NSOpenPanel, NSWindow, @escaping @MainActor ([URL]) -> Void) -> Void = { panel, window, answer in
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .OK ? panel.urls : []) }
        }
    }

    /// Spec 10 §6 — Import… "(⌘I, a file dialog)" takes any number of files
    /// and folders (Spec 8 §3, "A dropped folder"); Replace with… takes one
    /// file. The dialog offers what the pool can hold: video, stills and
    /// sound. What the engine can't play it still refuses, with its reason.
    func chooseFiles(_ choice: FileChoice, _ answer: @escaping @MainActor ([String]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .image, .audio]
        switch choice {
        case .importMedia:
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.prompt = Strings.text(.importChoose)
        case .replace(let name):
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.prompt = Strings.text(.replaceChoose)
            panel.message = Strings.text(.replaceMessage, name)
        }
        presentOpenPanel(panel, sheetParent) { urls in answer(urls.map(\.path)) }
    }

    // MARK: - First run (Spec 10 §13)

    private func askForRoots() {
        guard firstRun == nil else { return }
        let model = FirstRunModel()
        if let campus = rootsStore.campus { model.campus = campus }
        firstRun = model
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: FirstRunSheet(model: model) { [weak self] choice in
            self?.answered(choice)
        }))
        sheet.styleMask = [.titled]
        windowController.window.beginSheet(sheet)
    }

    private func answered(_ choice: FirstRunChoice) {
        if let sheet = windowController.window.attachedSheet { windowController.window.endSheet(sheet) }
        firstRun = nil
        // "The app stores both paths (§2) and starts the engine with `--campus`."
        rootsStore.roots = choice.roots
        rootsStore.campus = choice.campus.trimmingCharacters(in: .whitespacesAndNewlines)
        if let supervisor, case .firstRunRefused = supervisor.phase, supervisor.store === store {
            self.supervisor = nil
        }
        startEngine(choice.roots)
    }

    // MARK: - Restart the engine (Spec 10 §2)

    /// "offers "Restart the engine", which says the screens go black for a
    /// moment and, while the `saving` topic counts unsaved documents, that
    /// they will be lost." Spec 10 §9 — "A button that deletes, restores or
    /// quits is never a sheet's default, so Return can't press it": Escape
    /// cancels, and Return presses nothing.
    func askToRestart() {
        let words = RestartConfirmation.make(unsaved: store.saving.unsaved)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.title
        alert.informativeText = words.body.joined(separator: "\n")
        alert.addButton(withTitle: Strings.text(.cancel))
        alert.addButton(withTitle: Strings.text(.engineRestart))
        Self.keepReturnFromPressing(alert)
        presentAlert(alert, sheetParent) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.supervisor?.restartEngine() }
        }
    }

    // MARK: - Quitting (Spec 10 §2, choice U-2)

    /// "⌘Q, or closing the main window, asks ... with Quit, Keep outputs
    /// running and Cancel." "A logout, a restart or a shutdown doesn't ask,
    /// and the engine stops on the system's request."
    ///
    /// Spec 10 §4 — "every confirmation and file dialog is a sheet on the
    /// main window": the question is a sheet there, over any sheet that is
    /// already up, and the app's answer to the system waits for it.
    func shouldTerminate(systemAsked: Bool) -> NSApplication.TerminateReply {
        guard supervisor != nil, !systemAsked else {
            supervisor?.leaveEngineRunning()
            return .terminateNow
        }
        // Asked already: the question is up, or the engine is being stopped.
        guard !isQuitting else { return .terminateLater }
        // Spec 10 §10 — "⌘Q, ⌘2 and Lock Station commit an open field first." A field whose text can't be saved
        // stays open with its reason, and the quit waits for the operator (Area 13 reading, with the plan).
        guard windowController.regions.commitOpenField() else { return .terminateCancel }
        isQuitting = true
        let words = QuitQuestion.make(unsaved: store.saving.unsaved)
        let alert = NSAlert()
        alert.messageText = words.title
        if let detail = words.detail { alert.informativeText = detail }
        // Escape cancels and Return presses nothing: Quit and Keep outputs running each need their own press.
        alert.addButton(withTitle: words.cancel)
        alert.addButton(withTitle: words.quit)
        alert.addButton(withTitle: words.keepOutputs)
        Self.keepReturnFromPressing(alert)
        presentAlert(alert, sheetParent) { [weak self] response in
            self?.quitAnswered(response)
        }
        return .terminateLater
    }

    /// Whether Quit has been asked and not cancelled.
    private(set) var isQuitting = false

    private func quitAnswered(_ response: NSApplication.ModalResponse) {
        guard let supervisor else {
            replyToTerminate(true)
            return
        }
        switch response {
        case .alertSecondButtonReturn:
            windowController.banner.show(EngineBanner(text: Strings.text(.quitStopping), tone: .working, console: [], offersRestart: false))
            let reply = replyToTerminate
            supervisor.stopEngine { [weak self] unsaved in
                guard let self else {
                    reply(true)
                    return
                }
                self.showUnsaved(unsaved ?? []) { reply(true) }
            }
        case .alertThirdButtonReturn:
            supervisor.leaveEngineRunning()
            replyToTerminate(true)
        default:
            isQuitting = false
            replyToTerminate(false)
        }
    }

    /// "shows the documents the answer names as unsaved (Spec 9 §7), then quits".
    private func showUnsaved(_ documents: [String], then quit: @escaping @MainActor () -> Void) {
        guard !documents.isEmpty else {
            quit()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.text(.quitNotSavedTitle)
        alert.informativeText = Strings.counted(.quitNotSavedBody, documents.count, ListFormatter.localizedString(byJoining: documents))
        alert.addButton(withTitle: Strings.text(.ok))
        presentAlert(alert, sheetParent) { _ in quit() }
    }

    // MARK: - About (Spec 10 §2, "Versions")

    /// "An app and an engine of different versions work together while `api` matches; About shows both."
    func showAbout() {
        let versions = store.isConnected ? Strings.text(.aboutVersions, OCore.appVersion, store.hello?.engine ?? "") : Strings.text(.aboutEngineAway, OCore.appVersion)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationName: Strings.text(.appName), .applicationVersion: versions, .version: ""])
    }

    // MARK: - The screens (Spec 10 §2)

    private var situation: ScreenSituation {
        ScreenSituation(outputs: store.catalog?.outputs ?? [], statuses: store.outputs, screens: Set(NSScreen.screens.compactMap(\.deviceName)),
                        windowScreen: windowController.window.screen?.deviceName, released: Set(releasedScreens))
    }

    private func screensChanged() {
        let situation = self.situation
        // "From its first catalog on, the app keeps a black, borderless curtain ... on the screen of each display output other than the main window's".
        let wanted = store.catalog == nil ? [] : CurtainPlan.screens(in: situation)
        for (screen, window) in curtains where !wanted.contains(screen) {
            window.close()
            curtains[screen] = nil
        }
        for screen in wanted where curtains[screen] == nil {
            guard let place = NSScreen.named(screen) else { continue }
            curtains[screen] = Self.makeCurtain(on: place)
        }
        for (screen, window) in curtains {
            if let place = NSScreen.named(screen) { window.setFrame(place.frame, display: true) }
        }

        // "When an output covers the app".
        let covering = CoveredWindow.coveringOutput(in: situation, connected: store.isConnected)
        windowController.window.takesClicks = CoveredWindow.takesClicks(in: situation, connected: store.isConnected, raised: isRaised)
        if let covering, covering != coveredBy { showBehindNote(output: covering) }
        coveredBy = covering
        placeWindowSoon()
    }

    // MARK: - Where the window stands (Spec 10 §4)

    private var placeTask: (any ClockTask)?

    /// Spec 10 §4, "One main window" — "The app opens it on a screen no
    /// output uses, and moves it to one when it ends up on an output's
    /// screen, moved by hand or by a change of screens, if such a screen
    /// exists." A window being dragged is left alone until it is let go.
    func placeWindowSoon() {
        placeTask?.cancel()
        guard NSEvent.pressedMouseButtons == 0 else {
            placeTask = clock.after(0.25) { [weak self] in self?.placeWindowSoon() }
            return
        }
        let window = windowController.window
        guard window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        let screens = NSScreen.screens.compactMap { screen in
            screen.deviceName.map { WindowPlacement.Screen(name: $0, area: Double(screen.frame.width * screen.frame.height)) }
        }
        let outputs = WindowPlacement.outputScreens(store.catalog?.outputs ?? [], released: Set(releasedScreens))
        guard let name = WindowPlacement.target(window: window.screen?.deviceName, screens: screens, outputs: outputs),
              let screen = NSScreen.named(name) else { return }
        let room = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, room.width), height: min(window.frame.height, room.height))
        window.setFrame(NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }

    // MARK: - ⌃⌥⌘⎋ (Spec 10 §9, "Fixed keys")

    /// Spec 10 §9 — whether the main window is raised one level above the outputs.
    var isRaised: Bool { releaser.isRaised }

    /// Starts reading the app's keys and asks the system for ⌃⌥⌘⎋. Done
    /// once, when the app has launched; a test's window never does it, so
    /// no test takes a key from the whole Mac.
    func startKeys() {
        windowController.keyTap.install()
        let registered = releaseKey.register { [weak self] in self?.releaseThisScreen() }
        // "the overlay says so" when the system didn't give the key: then it works only while the app is active, from Help's entry.
        windowController.regions.releaseKeyRegistered = registered
    }

    /// ⌃⌥⌘⎋, or Help ▸ Release Output from This Screen: "takes every output
    /// off the screen that holds the app's window, lock or not."
    func releaseThisScreen() {
        guard let screen = windowScreenName() else { return }
        releaser.release(screen: screen)
    }

    /// The screen that holds the app's window, as the engine names it; a seam, since a test's window is on no screen.
    lazy var windowScreenName: @MainActor () -> String? = { [weak self] in
        (self?.windowController.window.screen ?? NSScreen.main)?.deviceName
    }

    /// How the window is put in front of everything on its screen; a seam, since a test's window is on no screen.
    var bringForward: @MainActor (NSWindow) -> Void = { window in
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// "the app raises its main window one level above the outputs on that
    /// screen ... and the window drops back to its level."
    private func raiseWindow(_ raised: Bool) {
        let window = windowController.window
        window.level = raised ? OutputLevels.aboveOutputs : .normal
        if raised { bringForward(window) }
        // Raised, the window takes clicks; and a released screen has no curtain and no output to move away from.
        screensChanged()
    }

    /// "a black, borderless curtain, on every Space ... one level below the
    /// outputs ... takes any click that lands on it so the desktop never
    /// gets one, and closes when the app quits."
    static func makeCurtain(on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.level = OutputLevels.curtain
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.setAccessibilityElement(false)
        window.orderFront(nil)
        return window
    }

    /// "For ten seconds after an output starts covering it, a note above the
    /// output says "Project O is behind output 2. Press ⌃⌥⌘⎋ to take it off
    /// this screen.""
    private func showBehindNote(output: Int) {
        guard let screen = windowController.window.screen else { return }
        notePanel?.close()
        noteTask?.cancel()
        let label = NSTextField(labelWithString: Strings.text(.engineBehindOutput, output))
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = Palette.text
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: label.frame.height + 24)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 60)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = Palette.panel
        panel.level = OutputLevels.aboveOutputs
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        label.frame.origin = NSPoint(x: 20, y: 12)
        panel.contentView?.addSubview(label)
        panel.setAccessibilityLabel(label.stringValue)
        panel.orderFrontRegardless()
        notePanel = panel
        noteTask = clock.after(10) { [weak self] in
            self?.notePanel?.close()
            self?.notePanel = nil
        }
    }

    /// Closes what the app put on the screens: "closes when the app quits".
    func closeScreens() {
        for window in curtains.values { window.close() }
        curtains = [:]
        notePanel?.close()
    }
}
