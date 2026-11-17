// OApp — Spec 10 §15, every string the app shows, by its key in the string catalog.

import Foundation

/// Spec 10 §15, "Localization" — "Every string shown is in the app's string
/// catalog, English only in v1, and built from whole sentences with
/// placeholders rather than pieces joined in code, so another language can
/// reorder them. Counts use the catalog's plural variants".
///
/// A case is a key of `app/Shell/Localizable.xcstrings`, where its English
/// and a note for a translator live; `StringCatalogTests` fails when a key
/// is in one and not the other. Nothing in the app shows text that didn't
/// come through `Strings.text`, apart from what the operator and the library
/// wrote themselves.
public enum StringKey: String, CaseIterable, Sendable {
    case appName = "app.name"

    // The engine (Spec 10 §2)
    case engineStarting = "engine.starting"
    case engineConnected = "engine.connected"
    case engineStopped = "engine.stopped"
    case engineStoppedCount = "engine.stopped.count"
    case engineNotResponding = "engine.notResponding"
    case engineWrongAPI = "engine.wrongAPI"
    case engineNoSocket = "engine.noSocket"
    case engineNoHello = "engine.noHello"
    case engineFirstRunRefused = "engine.firstRunRefused"
    case engineAnotherBuild = "engine.anotherBuild"
    case engineConsoleLabel = "engine.console.label"
    case engineRestart = "engine.restart"
    case engineRestartTitle = "engine.restart.title"
    case engineRestartBody = "engine.restart.body"
    case engineRestartUnsaved = "engine.restart.unsaved"
    case engineBehindOutput = "engine.behindOutput"

    // Quitting (Spec 10 §2, choice U-2)
    case quitTitle = "quit.title"
    case quitUnsaved = "quit.unsaved"
    case quitQuit = "quit.quit"
    case quitKeepOutputs = "quit.keepOutputs"
    case quitStopping = "quit.stopping"
    case quitNotSavedTitle = "quit.notSaved.title"
    case quitNotSavedBody = "quit.notSaved.body"
    case cancel = "common.cancel"
    case ok = "common.ok"

    // First run (Spec 10 §13)
    case firstRunTitle = "firstRun.title"
    case firstRunIntro = "firstRun.intro"
    case firstRunCampus = "firstRun.campus"
    case firstRunCampusPlaceholder = "firstRun.campus.placeholder"
    case firstRunNewLibrary = "firstRun.newLibrary"
    case firstRunExistingLibrary = "firstRun.existingLibrary"
    case firstRunFolder = "firstRun.folder"
    case firstRunLibraryFolder = "firstRun.libraryFolder"
    case firstRunMachineFolder = "firstRun.machineFolder"
    case firstRunChoose = "firstRun.choose"
    case firstRunStart = "firstRun.start"
    case firstRunProblemCampus = "firstRun.problem.campus"
    case firstRunProblemLibraryGuarded = "firstRun.problem.library.guarded"
    case firstRunProblemMachineGuarded = "firstRun.problem.machine.guarded"
    case firstRunProblemLibraryOtherVolume = "firstRun.problem.library.otherVolume"
    case firstRunProblemMachineOtherVolume = "firstRun.problem.machine.otherVolume"
    case firstRunProblemLibraryNotAbsolute = "firstRun.problem.library.notAbsolute"
    case firstRunProblemMachineNotAbsolute = "firstRun.problem.machine.notAbsolute"
    case firstRunProblemSocket = "firstRun.problem.socket"
    case firstRunProblemNoLibrary = "firstRun.problem.noLibrary"
    case firstRunProblemNoLibraryFound = "firstRun.problem.noLibrary.found"
    case firstRunProblemInside = "firstRun.problem.inside"

    // Why something can't be done now (Spec 10 §1)
    case unavailableEngineAway = "unavailable.engineAway"
    case unavailableLocked = "unavailable.locked"
    case unavailableReadOnlyMasters = "unavailable.readOnlyMasters"

    // Menus (Spec 10 §4)
    case menuAbout = "menu.about"
    case menuQuit = "menu.quit"
    case aboutVersions = "about.versions"
    case aboutEngineAway = "about.engineAway"
}

/// The table the keys are looked up in, and what is done to a string on its
/// way out. On the main thread, like everything that shows text.
@MainActor
public enum Strings {
    /// Where a key's format comes from: the count picks a plural variant
    /// where the key has them. The app reads its bundle's compiled catalog;
    /// a test reads the catalog file itself, since under `swift test` no
    /// bundle of the app's exists.
    public static var lookup: (_ key: String, _ count: Int?) -> String? = { key, _ in
        let found = Bundle.main.localizedString(forKey: key, value: "\u{0}", table: nil)
        return found == "\u{0}" ? nil : found
    }

    /// Spec 10 §18 — "under the accented pseudolanguage and one 40% longer,
    /// nothing is clipped": a transform every string passes through (Area 13
    /// reading: both pseudolanguages are the app's own, applied here).
    public static var transform: ((String) -> String)?

    /// The string for `key`, its placeholders filled in order. A key the
    /// table doesn't hold shows as the key itself, which a test catches and
    /// an operator can at least report.
    public static func text(_ key: StringKey, _ arguments: CVarArg...) -> String {
        format(key, count: nil, arguments)
    }

    /// The string for a key with plural variants, chosen by `count`, which
    /// is also its first placeholder: "3 changes aren't saved yet".
    public static func counted(_ key: StringKey, _ count: Int, _ arguments: CVarArg...) -> String {
        format(key, count: count, [count] + arguments)
    }

    private static func format(_ key: StringKey, count: Int?, _ arguments: [CVarArg]) -> String {
        let format = lookup(key.rawValue, count) ?? key.rawValue
        let text = arguments.isEmpty ? format : String(format: format, locale: Locale.current, arguments: arguments)
        return transform?(text) ?? text
    }
}

/// Spec 10 §18 — the two pseudolanguages the clipping test lays the window
/// out under.
public enum Pseudolanguage {
    /// Every letter that has one takes an accent, so a string that didn't
    /// come from the table stands out as plain, and tall marks test line
    /// heights.
    public static func accented(_ text: String) -> String {
        let pairs: [Character: Character] = ["a": "á", "e": "é", "i": "í", "o": "ó", "u": "ú", "A": "Á", "E": "É", "I": "Í", "O": "Ó", "U": "Ú",
                                             "c": "ç", "n": "ñ", "y": "ý", "C": "Ç", "N": "Ñ", "Y": "Ý"]
        return String(text.map { pairs[$0] ?? $0 })
    }

    /// "one 40% longer": the string with two fifths of its length again,
    /// padded with a letter that never appears in the app's own strings.
    public static func longer(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text + String(repeating: "~", count: Int((Double(text.count) * 0.4).rounded(.up)))
    }
}
