// OEngine — the harness's Trash: Spec 8 §11, delete and undelete tested without the real one.

import Foundation
import OFormats

/// Spec 8 §11 — "Free space, the watcher's events, the Trash and the clock
/// are seams, so the tests run without real volumes or waits." A folder
/// stands in for the Trash: a file moves into it under its own name, numbered
/// as the Trash numbers a second one. A test can refuse a file (`noTrash`),
/// fail one, empty the Trash, or hold every move until it says go.
public final class FakeTrash: MediaTrash, @unchecked Sendable {
    public let folder: URL
    private let lock = NSLock()
    private var refusing: Set<String> = []
    private var failing: Set<String> = []
    private var gate: DispatchSemaphore?
    private var moves = 0

    public init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Files of these names are on "a volume with no Trash".
    public func refuse(_ names: Set<String>) {
        lock.lock()
        refusing = names
        lock.unlock()
    }

    /// Files of these names fail to move.
    public func fail(_ names: Set<String>) {
        lock.lock()
        failing = names
        lock.unlock()
    }

    /// Every move waits until `release` (Spec 8 §6, "If the item went on air while its files moved").
    public func hold() {
        lock.lock()
        gate = DispatchSemaphore(value: 0)
        lock.unlock()
    }

    /// The held moves go on.
    public func release() {
        lock.lock()
        let held = gate
        gate = nil
        lock.unlock()
        for _ in 0..<64 { held?.signal() }
    }

    /// "if the Trash has been emptied".
    public func empty() {
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// The names in the Trash now.
    public var contents: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// How many files have moved into it.
    public var moveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return moves
    }

    public func trash(_ url: URL) -> Result<URL, MediaTrashFailure> {
        lock.lock()
        let held = gate
        let refused = refusing.contains(url.lastPathComponent)
        let failed = failing.contains(url.lastPathComponent)
        lock.unlock()
        held?.wait()
        if refused { return .failure(.noTrash) }
        if failed { return .failure(.failed("the test failed this move")) }
        let name = url.lastPathComponent
        let dot = name.lastIndex(of: ".") ?? name.endIndex
        var target = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(String(name[..<dot]) + " \(n)" + String(name[dot...]))
            n += 1
        }
        switch LocalFiles.moveMedia(url, to: target) {
        case .moved:
            lock.lock()
            moves += 1
            lock.unlock()
            return .success(target)
        case .taken: return .failure(.failed("taken"))
        case .failed(let why): return .failure(.failed(why))
        }
    }

    public func putBack(_ trashed: URL, to url: URL) -> Result<Void, MediaTrashFailure> {
        SystemTrash().putBack(trashed, to: url)
    }
}
