// OCore — Spec 8 §2, where media may live (choice M-8).

import Foundation

/// Spec 8 §2 — why media may not live at a path.
public enum MediaPlaceProblem: Equatable, Sendable {
    /// The path isn't absolute, so it can't be checked.
    case notAbsolute
    /// The path is on an external drive, a network volume or another volume
    /// than the startup volume.
    case otherVolume
    /// The path is in the Desktop, Documents or Downloads folder (the name).
    case guardedFolder(String)

    /// The words the reference report and a refusal use.
    public var description: String {
        switch self {
        case .notAbsolute: return "isn't an absolute path"
        case .otherVolume: return "isn't on the startup volume"
        case .guardedFolder(let name): return "is in the \(name) folder"
        }
    }
}

/// Spec 8 §2 — "Where media may live (choice M-8). ... macOS asks each process
/// before it reads the Desktop, Documents and Downloads folders, external
/// drives and network volumes, and it asks an ad-hoc-signed engine again
/// after every update (ADR 0007). So in v1 the media root and override
/// targets sit on the startup volume, outside those three folders: setting
/// `mediaRoot` anywhere else is refused with `badValue`, and the reference
/// report lists an override that points elsewhere. The library and machine
/// roots have the same need."
///
/// The check reads nothing from the disk itself. Paths under `/Volumes`,
/// `/net` and `/Network` are other volumes by their name alone, so a share
/// that has gone away is never asked about; for any other path the caller's
/// `isOnStartupVolume` answers, from facts it reads safely. Folder names
/// compare without regard to case, as the startup volume does by default.
public struct MediaPlaces: Sendable {
    /// The user's home folder, whose Desktop, Documents and Downloads folders
    /// macOS guards.
    public var home: String
    /// Whether an absolute path, already clear of the names above, is on the
    /// startup volume.
    public var isOnStartupVolume: @Sendable (String) -> Bool

    public static let guardedFolders = ["Desktop", "Documents", "Downloads"]
    public static let otherVolumeFolders = ["/Volumes", "/net", "/Network"]

    public init(home: String, isOnStartupVolume: @escaping @Sendable (String) -> Bool) {
        self.home = home
        self.isOnStartupVolume = isOnStartupVolume
    }

    /// Spec 8 §2 — why media may not live at `path`, or nil when it may. The
    /// path is absolute and standardized (no `.` or `..` parts).
    public func problem(with path: String) -> MediaPlaceProblem? {
        guard path.hasPrefix("/") else { return .notAbsolute }
        let folded = path.lowercased()
        for folder in Self.otherVolumeFolders where MediaPlaces.isAt(folded, or: folder.lowercased()) {
            return .otherVolume
        }
        let homeFolded = (home.hasSuffix("/") ? String(home.dropLast()) : home).lowercased()
        for name in Self.guardedFolders where MediaPlaces.isAt(folded, or: homeFolded + "/" + name.lowercased()) {
            return .guardedFolder(name)
        }
        return isOnStartupVolume(path) ? nil : .otherVolume
    }

    /// Whether `path` is `folder` or inside it.
    static func isAt(_ path: String, or folder: String) -> Bool {
        path == folder || path.hasPrefix(folder + "/")
    }
}
