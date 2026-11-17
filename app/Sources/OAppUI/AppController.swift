// OAppUI — Spec 10 §2, the app's dealing with the engine, shown: the window, the questions it asks, the curtains.

import AppKit
import SwiftUI
import OApp
import OCore

/// Spec 10 §2 — ties the supervisor to what the operator sees: the banner,
/// the first-run sheet, what Restart the engine and Quit ask first, the
/// curtains on the output screens, and the window while an output covers it.
@MainActor
final class AppController {
    let store = ShowStore()
    let windowController = MainWindowController()
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
    /// Spec 10 §9 — the screens the app released while it runs; the fixed key fills it (stage 3).
    var releasedScreens: [String] = []
    /// Spec 10 §2, "Versions" — the offer to restart an engine of another build, and the run it was last made for.
    private var anotherBuild = AnotherBuildOffer()

    init(rootsStore: any RootsStore = DefaultsRootsStore(), launcher: any EngineLauncher = PosixEngineLauncher(),
         connector: any EngineConnector = UnixEngineConnector(), clock: any AppClock = SystemAppClock(),
         executable: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/oengine")) {
        self.rootsStore = rootsStore
        self.launcher = launcher
        self.connector = connector
        self.clock = clock
        self.executable = executable
        windowController.banner.onRestart = { [weak self] in self?.askToRestart() }
        store.observe { [weak self] changes in
            if !changes.isDisjoint(with: [.catalog, .outputs, .devices, .connection]) { self?.screensChanged() }
            if changes.contains(.live) { self?.offerRestartOfAnotherBuild() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
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
        self.supervisor = supervisor
        supervisor.start()
        phaseChanged(supervisor.phase)
    }

    private func phaseChanged(_ phase: EngineSupervisor.Phase) {
        windowController.show(phase)
        screensChanged()
        // Adam's answer, 2026-11-17 — a refused first run stops and shows the sheet again.
        if case .firstRunRefused = phase { askForRoots() }
        offerRestartOfAnotherBuild()
    }

    /// Spec 10 §2, "Versions" — "When the app finds an engine of another
    /// build running, as after Keep outputs running and an update, it offers
    /// to restart it while nothing is live, so the new build's Keychain
    /// prompt comes while someone is there (R2)." `AnotherBuildOffer`
    /// decides; the sheet waits while another sheet is up or the window isn't shown.
    private func offerRestartOfAnotherBuild() {
        guard let supervisor, let hello = store.hello,
              let question = anotherBuild.question(anotherBuild: supervisor.isAnotherBuild, hasState: store.hasState, live: store.live,
                                                   hello: hello, app: OCore.appVersion),
              windowController.window.attachedSheet == nil, windowController.window.isVisible else { return }
        anotherBuild.asked(run: hello.run)
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.body
        alert.addButton(withTitle: question.cancel)
        alert.addButton(withTitle: question.restart)
        alert.beginSheetModal(for: windowController.window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.supervisor?.restartEngine() }
        }
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
    /// quits is never a sheet's default, so Return can't press it": Cancel is.
    func askToRestart() {
        let words = RestartConfirmation.make(unsaved: store.saving.unsaved)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = words.title
        alert.informativeText = words.body.joined(separator: "\n")
        alert.addButton(withTitle: Strings.text(.cancel))
        alert.addButton(withTitle: Strings.text(.engineRestart))
        alert.beginSheetModal(for: windowController.window) { [weak self] response in
            if response == .alertSecondButtonReturn { self?.supervisor?.restartEngine() }
        }
    }

    // MARK: - Quitting (Spec 10 §2, choice U-2)

    /// "⌘Q, or closing the main window, asks ... with Quit, Keep outputs
    /// running and Cancel." "A logout, a restart or a shutdown doesn't ask,
    /// and the engine stops on the system's request."
    func shouldTerminate(systemAsked: Bool) -> NSApplication.TerminateReply {
        guard let supervisor, !systemAsked else {
            supervisor?.leaveEngineRunning()
            return .terminateNow
        }
        let words = QuitQuestion.make(unsaved: store.saving.unsaved)
        let alert = NSAlert()
        alert.messageText = words.title
        if let detail = words.detail { alert.informativeText = detail }
        // Cancel is the default, on Return and on Escape; Quit and Keep outputs running each need their own press.
        alert.addButton(withTitle: words.cancel)
        alert.addButton(withTitle: words.quit)
        alert.addButton(withTitle: words.keepOutputs)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            windowController.banner.show(EngineBanner(text: Strings.text(.quitStopping), tone: .working, console: [], offersRestart: false))
            supervisor.stopEngine { [weak self] unsaved in
                self?.showUnsaved(unsaved ?? [])
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            supervisor.leaveEngineRunning()
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// "shows the documents the answer names as unsaved (Spec 9 §7), then quits".
    private func showUnsaved(_ documents: [String]) {
        guard !documents.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.text(.quitNotSavedTitle)
        alert.informativeText = Strings.counted(.quitNotSavedBody, documents.count, ListFormatter.localizedString(byJoining: documents))
        alert.addButton(withTitle: Strings.text(.ok))
        alert.runModal()
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
    }

    /// Spec 10 §9 — whether the main window is raised one level above the outputs; the fixed key raises it (stage 3).
    var isRaised: Bool { windowController.window.level == OutputLevels.aboveOutputs }

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
