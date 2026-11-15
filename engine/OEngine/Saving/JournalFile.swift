// OEngine — Spec 9 §2, one log on disk: a file per day or per hour, appended to.

import Foundation

/// Spec 9 §2 — one of the three logs as files in a folder: `commands-…`,
/// `engine-…` or `blackbox-…`, a file per key (the local day, or the UTC
/// hour), each "a JSON line per entry". Lines are appended in the order they
/// are given, a batch in one write; the file is synced when its owner says;
/// a file whose last byte isn't a newline is ended before anything is added.
///
/// Confined to the one thread or queue that owns it.
final class JournalFile {
    let folder: URL
    let prefix: String
    let disk: Disk
    private var current: (key: String, file: Disk.Appender)?
    /// The newest key a file was opened for, so a late line for an older one
    /// (a typing run that closed after midnight) doesn't count as a new file.
    private(set) var newestKey: String?
    /// The keys of the files started since the last `takeStarted`.
    private var started: [String] = []

    init(folder: URL, prefix: String, disk: Disk) {
        self.folder = folder
        self.prefix = prefix
        self.disk = disk
    }

    func url(for key: String) -> URL {
        folder.appendingPathComponent("\(prefix)\(key).jsonl")
    }

    /// Spec 9 §2 — "A group's lines go out in one write ending in a newline":
    /// `text`, one or more whole lines, appended to the file of `key`.
    func append(_ text: String, key: String) throws {
        let file = try open(key)
        try file.append(Data(text.utf8))
    }

    private func open(_ key: String) throws -> Disk.Appender {
        if let current, current.key == key { return current.file }
        current?.file.close()
        current = nil
        let file = try disk.appender(at: url(for: key))
        current = (key, file)
        if newestKey.map({ key > $0 }) ?? true {
            newestKey = key
            started.append(key)
        }
        return file
    }

    /// Spec 9 §7 — the retention pass runs "when a day's or an hour's file
    /// starts": the keys started since this was last asked.
    func takeStarted() -> [String] {
        defer { started.removeAll() }
        return started
    }

    /// The size of the file being appended to, and its key.
    var currentFile: (key: String, bytes: Int64)? {
        current.map { ($0.key, $0.file.size) }
    }

    var isDirty: Bool { current?.file.isDirty ?? false }

    /// Spec 9 §2 — "each file is synced once a second".
    func sync() {
        current?.file.sync()
    }

    func close() {
        current?.file.close()
        current = nil
    }
}
