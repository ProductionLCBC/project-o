// OFormats — Spec 8 §2, the folders media lives in, at the file boundary.

import Foundation
import OCore
#if canImport(Glibc)
import Glibc
#endif

/// Spec 8 §2 — the two folders a location's relative path reads against:
/// the media root ("a folder inside the library root by default", which
/// machine settings' `mediaRoot` names relative to the machine root, Spec 1
/// §3 and §5) and the machine's own `machine/media/` ("local-only media ...
/// and the files overrides point at, never synced"). An absolute override
/// names its file itself.
///
/// Spec 8 §2, choice M-8 — "the media root and override targets sit on the
/// startup volume, outside those three folders": with `places` given, a
/// media root anywhere else isn't read (`mediaRoot` is nil and `refused`
/// says why, for the report and the engine log), and nor is an absolute
/// override that points elsewhere. Without `places`, as in the test
/// harness, media is read wherever it is.
public struct MediaFolders: Sendable {
    public var mediaRoot: URL?
    public var machineMedia: URL?
    public var places: MediaPlaces?
    /// Spec 8 §2 — the media root's path and why media may not live there.
    public var refused: (path: String, problem: MediaPlaceProblem)?

    public init(mediaRoot: URL? = nil, machineMedia: URL? = nil, places: MediaPlaces? = nil) {
        self.mediaRoot = mediaRoot
        self.machineMedia = machineMedia
        self.places = places
    }

    /// Spec 1 §3 and §5 — a machine root's media folders: `mediaRoot` as its
    /// settings name it, relative to the machine root, and `machine/media/`.
    public static func of(machineRoot: URL, settings: MachineSettings, places: MediaPlaces? = nil) -> MediaFolders {
        let root = URL(fileURLWithPath: settings.mediaRoot, relativeTo: machineRoot).standardizedFileURL
        var folders = MediaFolders(mediaRoot: root, machineMedia: machineRoot.appendingPathComponent("media").standardizedFileURL, places: places)
        if let places, let problem = places.problem(with: root.path) {
            folders.mediaRoot = nil
            folders.refused = (root.path, problem)
        }
        return folders
    }

    /// Spec 8 §2 — the folder a location's path reads against; nil when it
    /// isn't known or isn't read.
    public func folder(_ folder: MediaFolder) -> URL? {
        switch folder {
        case .mediaRoot: return mediaRoot
        case .machineMedia: return machineMedia
        case .absolute: return URL(fileURLWithPath: "/")
        }
    }

    /// Spec 8 §2 — the file a location names; nil when its folder isn't known
    /// or isn't read, or an absolute override points where media may not live.
    public func url(for location: MediaLocation) -> URL? {
        if location.folder == .absolute {
            if let places, places.problem(with: location.path) != nil { return nil }
            return URL(fileURLWithPath: location.path)
        }
        return folder(location.folder)?.appendingPathComponent(location.path)
    }
}

extension LocalFiles {
    /// Spec 8 §4 — a file's size and modification date as the walk and the
    /// cache compare them; nil when nothing is there or it isn't a regular
    /// file (a symbolic link is never followed).
    public static func mediaStat(_ url: URL) -> MediaFileStat? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if canImport(Glibc)
        let time = info.st_mtim
        #else
        let time = info.st_mtimespec
        #endif
        return MediaFileStat(size: Int(info.st_size), modified: modifiedText(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec)))
    }

    /// `mediaStat`, with the modification date also as seconds since 1970,
    /// for the walk's two seconds (Spec 8 §4).
    public static func mediaStatTime(_ url: URL) -> (stat: MediaFileStat, modified: Double)? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if canImport(Glibc)
        let time = info.st_mtim
        #else
        let time = info.st_mtimespec
        #endif
        let stat = MediaFileStat(size: Int(info.st_size), modified: modifiedText(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec)))
        return (stat, Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    /// What a media move did.
    public enum MediaMove: Equatable, Sendable {
        case moved
        /// The new name is taken: nothing moved.
        case taken
        case failed(String)
    }

    /// Spec 8 §3 — a file renamed into place, never over another ("an
    /// import never shares a path with another entry or replaces it"), and
    /// made durable.
    public static func moveMedia(_ from: URL, to: URL) -> MediaMove {
        if renameNoReplace(from.path, to.path) == 0 {
            syncFolder(from.deletingLastPathComponent())
            syncFolder(to.deletingLastPathComponent())
            return .moved
        }
        let failure = errno
        return failure == EEXIST ? .taken : .failed(String(cString: strerror(failure)))
    }

    /// Spec 1 §5 — "dates are ISO 8601": a modification date at the precision
    /// the file system keeps, `2026-11-11T09:00:00.123456789Z`, so two writes
    /// within one second still differ.
    public static func modifiedText(seconds: Int64, nanoseconds: Int64) -> String {
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let rest = seconds - days * 86_400
        // Days since 1970-01-01 to a civil date (Howard Hinnant's algorithm).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        func two(_ n: Int64) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let nanos = String(nanoseconds)
        return "\(year)-\(two(month))-\(two(day))T\(two(rest / 3600)):\(two(rest / 60 % 60)):\(two(rest % 60))."
            + String(repeating: "0", count: max(0, 9 - nanos.count)) + nanos + "Z"
    }

    /// Spec 8 §4 — the machine's hash cache, `machine/media-cache.json`;
    /// empty when there is none or it doesn't read (it is only a cache).
    public static func mediaCache(machineRoot: URL) -> MediaCache {
        let path = DocumentKind.mediaCache.fixedPath ?? "media-cache.json"
        guard let data = FileManager.default.contents(atPath: machineRoot.appendingPathComponent(path).path),
              case .mediaCache(let cache)? = try? Loader.document(path: path, data: data).body else { return MediaCache() }
        return cache
    }

    /// Spec 8 §2 and §9 — "Missing state is worked out per location": what is
    /// known of each location the two indexes name before the walk has read
    /// anything (`MediaLaunch.states`), from one look at each file and the
    /// cache. A location whose folder isn't read holds nothing.
    public static func mediaStates(library: Library, machine: Machine?, folders: MediaFolders,
                                   cache: MediaCache = MediaCache()) -> [MediaLocation: MediaFileState] {
        MediaLaunch.states(library: library.mediaIndex, machine: machine?.mediaLocal ?? MediaLocalIndex(),
                           stat: { folders.url(for: $0).flatMap(mediaStat) }, cache: cache)
    }

    /// Spec 8 §9 — the launch's missing set over both folders (Spec 3 §6,
    /// `missing`), from `mediaStates`.
    public static func missingMedia(library: Library, machine: Machine?, folders: MediaFolders,
                                    cache: MediaCache = MediaCache()) -> Set<String> {
        let states = mediaStates(library: library, machine: machine, folders: folders, cache: cache)
        return MediaResolver.missingIds(library: library, machine: machine, state: { states[$0] ?? .absent })
    }
}
