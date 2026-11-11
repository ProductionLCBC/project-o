// OEngine — Spec 1 §8 and Spec 5 §10, the folder watcher.

import CoreServices
import Foundation

/// Spec 1 §8 — "When a document changes on disk under the app (a master
/// arriving by sync, a hand edit), the app reloads it". FSEvents on the two
/// roots; an event under the library root's `lists/` or the machine root's
/// `playlists/` or `lists-local/`, or on either media index (Spec 8 §2),
/// asks the writer's queue to scan. The event only says that something
/// changed there; the scan finds what, and knows the engine's own writes
/// (`DocumentWriter`). Spec 8 §4 — the walk runs "whenever its watcher
/// reports a change under either folder", the media root and
/// `machine/media/`: an event there goes to `onMedia`, the media worker's
/// walk. Events for the rest of the roots (logs, thumbnails, the black box,
/// the media cache) are ignored.
public final class DiskWatcher: @unchecked Sendable {
    /// FSEvents gathers what happens in this long into one callback.
    public static let latency: TimeInterval = 0.2

    private let roots: [String]
    private let folders: [String]
    private let files: Set<String>
    private let mediaFolders: [String]
    private let onChange: @Sendable () -> Void
    private let onMedia: @Sendable () -> Void
    private let queue = DispatchQueue(label: "o.engine.watcher", qos: .utility)
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    /// Spec 1 §8 — a watcher on the two roots and, outside them, the media
    /// root; `onChange` and `onMedia` run on the watcher's own queue when
    /// something under the watched documents or media folders changed.
    public init(libraryRoot: URL, machineRoot: URL, media: [URL] = [], onChange: @escaping @Sendable () -> Void,
                onMedia: @escaping @Sendable () -> Void = {}) {
        let library = Self.realPath(libraryRoot)
        let machine = Self.realPath(machineRoot)
        let mediaFolders = media.map(Self.realPath)
        var roots = [library, machine]
        for folder in mediaFolders where !roots.contains(where: { folder == $0 || folder.hasPrefix($0 + "/") }) {
            roots.append(folder)
        }
        self.roots = roots
        folders = [library + "/lists", machine + "/playlists", machine + "/lists-local"]
        files = [library + "/media-index.json", machine + "/media-local.json"]
        self.mediaFolders = mediaFolders
        self.onChange = onChange
        self.onMedia = onMedia
    }

    /// FSEvents names files by their real path (`/private/var/...`). A path
    /// that doesn't exist yet keeps its nearest existing folder's real path.
    static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if realpath(url.path, &buffer) != nil { return String(cString: buffer) }
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        guard parent.path != url.standardizedFileURL.path, parent.path != "/" else { return url.standardizedFileURL.path }
        return realPath(parent) + "/" + url.lastPathComponent
    }

    /// Whether an event's path is in a watched folder, or is one, or is a media index.
    func matches(_ path: String) -> Bool {
        files.contains(path) || folders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Spec 8 §4 — whether an event's path is under a media folder.
    func matchesMedia(_ path: String) -> Bool {
        mediaFolders.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func handle(_ paths: [String]) {
        if paths.contains(where: matches) { onChange() }
        if paths.contains(where: matchesMedia) { onMedia() }
    }

    /// Starts the stream; false when FSEvents refused it.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DiskWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
            watcher.handle(list.compactMap { $0 as? String })
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    /// Spec 1 §8 — the watcher stops with the engine.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
