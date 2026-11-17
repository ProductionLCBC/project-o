// OApp — Spec 10 §2, what the window says about the engine, in the spec's own words.

import Foundation

/// Spec 10 §2 — the banner across the window for each place the app can
/// stand with the engine: "Starting the engine…", "The engine stopped.
/// Restarting…", "The engine isn't responding" with "Restart the engine",
/// and the console log's last lines where the spec shows them.
public struct EngineBanner: Equatable, Sendable {
    /// What the banner's colour says (Spec 10 §4: "red for live and for
    /// errors ... amber ... for warnings"); never the only signal, since the
    /// sentence says it too (§15).
    public enum Tone: Equatable, Sendable {
        /// The app is doing something that will pass by itself.
        case working
        /// Something is wrong and the operator may have to act.
        case failure
    }

    public var text: String
    public var tone: Tone
    /// "the console log's last lines", oldest first; empty where none are shown.
    public var console: [String]
    /// Whether the banner carries the Restart the engine button.
    public var offersRestart: Bool

    public init(text: String, tone: Tone, console: [String], offersRestart: Bool) {
        self.text = text
        self.tone = tone
        self.console = console
        self.offersRestart = offersRestart
    }

    /// The banner for a phase, or nil when the window needs none.
    @MainActor
    public static func make(for phase: EngineSupervisor.Phase) -> EngineBanner? {
        switch phase {
        case .idle, .connected, .quitting:
            return nil
        case .starting:
            return EngineBanner(text: Strings.text(.engineStarting), tone: .working, console: [], offersRestart: false)
        case .notResponding:
            return EngineBanner(text: Strings.text(.engineNotResponding), tone: .failure, console: [], offersRestart: true)
        case .wrongAPI(let engine):
            return EngineBanner(text: Strings.text(.engineWrongAPI, engine), tone: .failure, console: [], offersRestart: true)
        case .noSocket(let console):
            return EngineBanner(text: Strings.text(.engineNoSocket), tone: .failure, console: console, offersRestart: true)
        case .noHello:
            return EngineBanner(text: Strings.text(.engineNoHello), tone: .failure, console: [], offersRestart: true)
        case .restarting(let ends, let console):
            // "From the third such end the banner says how many there have been and shows the console log's last lines".
            let text = ends >= EngineSupervisor.endsBeforeConsole ? Strings.counted(.engineStoppedCount, ends) : Strings.text(.engineStopped)
            return EngineBanner(text: text, tone: .failure, console: console, offersRestart: false)
        case .firstRunRefused(let console):
            return EngineBanner(text: Strings.text(.engineFirstRunRefused), tone: .failure, console: console, offersRestart: false)
        }
    }
}

/// Spec 10 §2, "When it doesn't answer" — what Restart the engine asks
/// first: it "says the screens go black for a moment and, while the `saving`
/// topic counts unsaved documents, that they will be lost."
public struct RestartConfirmation: Equatable, Sendable {
    public var title: String
    /// One whole sentence a line.
    public var body: [String]

    @MainActor
    public static func make(unsaved: Int) -> RestartConfirmation {
        var body = [Strings.text(.engineRestartBody)]
        if unsaved > 0 { body.append(Strings.counted(.engineRestartUnsaved, unsaved)) }
        return RestartConfirmation(title: Strings.text(.engineRestartTitle), body: body)
    }
}

/// Spec 10 §2, "Versions" — "When the app finds an engine of another build
/// running, as after Keep outputs running and an update, it offers to
/// restart it while nothing is live, so the new build's Keychain prompt
/// comes while someone is there (R2)."
///
/// Area 13 reading — "nothing is live" as Spec 10 §7 defines the words, "no
/// playlist loaded and no list fired from the library"; and the offer is
/// made once for each engine run, so a Cancel isn't asked again.
public struct AnotherBuildOffer: Equatable, Sendable {
    /// What the offer asks. Escape cancels it and Return presses nothing (Spec 10 §9).
    public struct Question: Equatable, Sendable {
        public var title: String
        public var body: String
        public var cancel: String
        public var restart: String
    }

    /// The engine run the offer was last made for.
    public private(set) var askedRun: String?

    public init() {}

    /// The question to ask now, or nil while there is none to ask:
    /// `anotherBuild` is the supervisor's `isAnotherBuild`, `hasState`
    /// whether the engine's `state` answer has arrived, so `live` is known.
    @MainActor
    public func question(anotherBuild: Bool, hasState: Bool, live: LiveStatus, hello: Hello?, app: String) -> Question? {
        guard anotherBuild, hasState, !live.isSomethingLive, let hello, hello.run != askedRun else { return nil }
        return Question(title: Strings.text(.engineAnotherBuild, hello.engine, app), body: Strings.text(.engineRestartBody),
                        cancel: Strings.text(.cancel), restart: Strings.text(.engineRestart))
    }

    /// Records that the question was asked of this engine run.
    public mutating func asked(run: String) {
        askedRun = run
    }
}

/// Spec 10 §2, "Quitting" (choice U-2) — "⌘Q, or closing the main window,
/// asks "Quit Project O? The outputs will stop.", adding "3 changes aren't
/// saved yet" while the `saving` topic counts any, with Quit, Keep outputs
/// running and Cancel."
public struct QuitQuestion: Equatable, Sendable {
    public var title: String
    public var detail: String?
    public var quit: String
    public var keepOutputs: String
    public var cancel: String

    @MainActor
    public static func make(unsaved: Int) -> QuitQuestion {
        QuitQuestion(title: Strings.text(.quitTitle), detail: unsaved > 0 ? Strings.counted(.quitUnsaved, unsaved) : nil,
                     quit: Strings.text(.quitQuit), keepOutputs: Strings.text(.quitKeepOutputs), cancel: Strings.text(.cancel))
    }
}

/// Spec 10 §13 — the first-run sheet's sentence for each problem with a choice.
public enum FirstRunWording {
    @MainActor
    public static func sentence(for problem: FirstRunProblem) -> String {
        switch problem {
        case .campusMissing:
            return Strings.text(.firstRunProblemCampus)
        case .libraryPlace(.guardedFolder(let name)):
            return Strings.text(.firstRunProblemLibraryGuarded, name)
        case .machinePlace(.guardedFolder(let name)):
            return Strings.text(.firstRunProblemMachineGuarded, name)
        case .libraryPlace(.otherVolume):
            return Strings.text(.firstRunProblemLibraryOtherVolume)
        case .machinePlace(.otherVolume):
            return Strings.text(.firstRunProblemMachineOtherVolume)
        case .libraryPlace(.notAbsolute):
            return Strings.text(.firstRunProblemLibraryNotAbsolute)
        case .machinePlace(.notAbsolute):
            return Strings.text(.firstRunProblemMachineNotAbsolute)
        case .socketPathTooLong(let bytes):
            return Strings.text(.firstRunProblemSocket, bytes)
        case .noLibraryThere(let found):
            // "lists the system's list formatter" (Spec 10 §15).
            return found.isEmpty ? Strings.text(.firstRunProblemNoLibrary)
                : Strings.text(.firstRunProblemNoLibraryFound, ListFormatter.localizedString(byJoining: found))
        case .machineInsideLibrary:
            return Strings.text(.firstRunProblemInside)
        }
    }
}

/// Spec 10 §1 — the reason shown on a disabled control.
public enum UnavailableWording {
    @MainActor
    public static func sentence(for reason: Unavailable) -> String {
        switch reason {
        case .engineAway: return Strings.text(.unavailableEngineAway)
        case .locked: return Strings.text(.unavailableLocked)
        case .readOnlyMasters: return Strings.text(.unavailableReadOnlyMasters)
        }
    }
}
