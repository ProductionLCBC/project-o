// OApp — Spec 10 §13, first run's app side: where the roots go, checked before any engine is started.

import Foundation
import OCore

/// Spec 10 §13, "The roots" — what the first-run sheet asks: "the campus
/// name and where to keep the library, with `~/Project O/` as the default,
/// `library/` and `machine/` going inside it. The sheet can instead use a
/// library that is already there, such as one synced from central".
public struct FirstRunChoice: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        /// A new library: `library/` and `machine/` go inside this folder.
        case new(folder: URL)
        /// "a library that is already there": its folder, and where the machine root goes.
        case existing(library: URL, machine: URL)
    }

    public var campus: String
    public var place: Place

    public init(campus: String, place: Place) {
        self.campus = campus
        self.place = place
    }

    /// "with `~/Project O/` as the default".
    public static func defaultFolder(home: URL) -> URL {
        home.appendingPathComponent("Project O")
    }

    /// "the machine root goes in `~/Project O/machine/`, unless they pick another place".
    public static func defaultMachineRoot(home: URL) -> URL {
        defaultFolder(home: home).appendingPathComponent("machine")
    }

    /// The two roots this choice names.
    public var roots: EngineRoots {
        switch place {
        case .new(let folder):
            return EngineRoots(library: folder.appendingPathComponent("library"), machine: folder.appendingPathComponent("machine"))
        case .existing(let library, let machine):
            return EngineRoots(library: library, machine: machine)
        }
    }
}

/// Spec 10 §13 — why the sheet can't go on; each has one sentence in the string catalog.
public enum FirstRunProblem: Equatable, Sendable {
    /// "a sheet asks for the campus name": Bonjour and the snapshots show it, and the library is named from it.
    case campusMissing
    /// "Both places must be on the startup volume, outside Desktop, Documents and Downloads (Spec 8 §2)".
    case libraryPlace(MediaPlaceProblem)
    case machinePlace(MediaPlaceProblem)
    /// "and short enough for the socket (§2)": the bytes `engine.sock`'s path would take, over the 103 macOS allows.
    case socketPathTooLong(bytes: Int)
    /// "the operator picks its folder, which must hold `library.json` (the
    /// sheet says what it found otherwise, so a wrong folder never gets a
    /// first-run library)": what the folder holds instead, a few names of it.
    case noLibraryThere(found: [String])
    /// "never inside the synced folder".
    case machineInsideLibrary
}

/// Spec 10 §13 (Area 19 reading, at its stop 3) — "Who checks the place: the
/// app's sheet; the engine checks only that the socket's path fits." The
/// checks, as a function of the choice and of what is on disk.
public enum FirstRunCheck {
    /// The problems with a choice, in the order the sheet shows them; none means the engine can be started.
    ///
    /// `places` is this Mac's home and startup volume (the check Area 8
    /// built, Spec 8 §2). `contents` lists a folder's names, or nil when the
    /// folder isn't there.
    public static func problems(with choice: FirstRunChoice, places: MediaPlaces, contents: (URL) -> [String]?) -> [FirstRunProblem] {
        var problems: [FirstRunProblem] = []
        if choice.campus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append(.campusMissing) }
        let roots = choice.roots
        let library = roots.library.standardizedFileURL.path
        let machine = roots.machine.standardizedFileURL.path
        if let problem = places.problem(with: library) { problems.append(.libraryPlace(problem)) }
        if let problem = places.problem(with: machine) { problems.append(.machinePlace(problem)) }
        let socket = roots.socket.standardizedFileURL.path.utf8.count
        if socket > EngineSocketPath.limit { problems.append(.socketPathTooLong(bytes: socket)) }
        if case .existing = choice.place {
            let found = contents(roots.library) ?? []
            if !found.contains("library.json") {
                problems.append(.noLibraryThere(found: Array(found.filter { !$0.hasPrefix(".") }.sorted().prefix(5))))
            }
            if machine == library || machine.hasPrefix(library + "/") { problems.append(.machineInsideLibrary) }
        }
        return problems
    }
}
