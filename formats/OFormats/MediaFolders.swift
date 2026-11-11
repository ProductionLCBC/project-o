// OFormats — Spec 8 §2, the folders media lives in, at the file boundary.

import Foundation
import OCore

/// Spec 8 §2 — the two folders a location's relative path reads against:
/// the media root ("a folder inside the library root by default", which
/// machine settings' `mediaRoot` names relative to the machine root, Spec 1
/// §3 and §5) and the machine's own `machine/media/` ("local-only media ...
/// and the files overrides point at, never synced"). An absolute override
/// names its file itself.
public struct MediaFolders: Equatable, Sendable {
    public var mediaRoot: URL?
    public var machineMedia: URL?

    public init(mediaRoot: URL? = nil, machineMedia: URL? = nil) {
        self.mediaRoot = mediaRoot
        self.machineMedia = machineMedia
    }

    /// Spec 1 §3 and §5 — a machine root's media folders: `mediaRoot` as its
    /// settings name it, relative to the machine root, and `machine/media/`.
    public static func of(machineRoot: URL, settings: MachineSettings) -> MediaFolders {
        MediaFolders(mediaRoot: URL(fileURLWithPath: settings.mediaRoot, relativeTo: machineRoot).standardizedFileURL,
                     machineMedia: machineRoot.appendingPathComponent("media").standardizedFileURL)
    }

    /// Spec 8 §2 — the folder a location's path reads against; nil when it
    /// isn't known.
    public func folder(_ folder: MediaFolder) -> URL? {
        switch folder {
        case .mediaRoot: return mediaRoot
        case .machineMedia: return machineMedia
        case .absolute: return URL(fileURLWithPath: "/")
        }
    }

    /// Spec 8 §2 — the file a location names; nil when its folder isn't known.
    public func url(for location: MediaLocation) -> URL? {
        if location.folder == .absolute { return URL(fileURLWithPath: location.path) }
        return folder(location.folder)?.appendingPathComponent(location.path)
    }
}

extension LocalFiles {
    /// Spec 8 §2 and §9 — "Missing state is worked out per location": what is
    /// known of each location the two indexes name before a walk has hashed
    /// anything. A regular file there is `unhashed`, and counts present until
    /// the walk hashes it (Adam's answer of 2026-11-11, as Spec 9 §4 does for
    /// a restore); nothing there is `absent`. One look per location.
    public static func mediaStates(library: Library, machine: Machine?, folders: MediaFolders) -> [MediaLocation: MediaFileState] {
        var states: [MediaLocation: MediaFileState] = [:]
        let overrides = machine?.mediaLocal.overrides ?? [:]
        var entries: [(MediaEntry, MediaTier)] = library.mediaIndex.entries.map { ($0, .library) }
        entries += (machine?.mediaLocal.entries ?? []).map { ($0, .machine) }
        let fm = FileManager.default
        for (entry, tier) in entries {
            guard let location = MediaResolver.location(of: entry, tier: tier, overrides: overrides).location,
                  states[location] == nil else { continue }
            var isFolder: ObjCBool = false
            if let url = folders.url(for: location), fm.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue {
                states[location] = .unhashed
            } else {
                states[location] = .absent
            }
        }
        return states
    }

    /// Spec 8 §9 — the launch's missing set over both folders (Spec 3 §6,
    /// `missing`), from `mediaStates`.
    public static func missingMedia(library: Library, machine: Machine?, folders: MediaFolders) -> Set<String> {
        let states = mediaStates(library: library, machine: machine, folders: folders)
        return MediaResolver.missingIds(library: library, machine: machine, state: { states[$0] ?? .absent })
    }
}
