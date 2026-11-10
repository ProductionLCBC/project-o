// OCore — Spec 1 §4, Spec 5 §2 (choice E-3), Spec 7 §2 and Spec 9 §6: what
// one write of a list master does.
//
// Pure, like the writer: it takes a list, where its file is, what is kept for
// it and the time, and returns the list as written, its path, the plan and
// what is kept after it. The engine calls it on the control thread, so the
// version a write gives a list is in the library before the write happens.

import Foundation

/// Spec 9 §6 — the kept versions of every list, "filed by list uuid, at
/// `library/versions/<list uuid>/vNNNN.json`": each kept version and when it
/// was kept, in milliseconds since 1970 (a file's modification date).
public struct KeptVersions: Equatable, Sendable {
    public var lists: [UUID: [Int: Int64]]

    public init(lists: [UUID: [Int: Int64]] = [:]) {
        self.lists = lists
    }

    /// The index a root's versions folder gives: `versions/<uuid>/vNNNN.json`
    /// to its date. Anything else under `versions/` is not a kept version.
    public static func reading(_ versions: [String: Int64]) -> KeptVersions {
        var kept = KeptVersions()
        for (path, date) in versions {
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "versions", let uuid = UUID(uuidString: String(parts[1])) else { continue }
            let name = parts[2]
            guard name.hasPrefix("v"), name.hasSuffix(".json"), let version = Int(name.dropFirst().dropLast(".json".count)) else { continue }
            kept.lists[uuid, default: [:]][version] = date
        }
        return kept
    }

    public func highest(_ list: UUID) -> Int? { lists[list]?.keys.max() }
    public func lastKeptAt(_ list: UUID) -> Int64? { lists[list]?.values.max() }
    public func has(_ list: UUID, version: Int) -> Bool { lists[list]?[version] != nil }
}

/// What `SavePlanner.saveList` decided: the list as written, the path it is
/// written at, the whole-file plan, and the kept versions after it.
public struct ListSave: Equatable, Sendable {
    public var list: List
    public var path: String
    public var plan: WritePlan
    public var kept: KeptVersions
}

/// Spec 1 §4, Spec 5 §2, Spec 7 §2, Spec 9 §6 — a list master's write.
public enum SavePlanner {
    /// Spec 5 §12, choice E-3 — "A save copies the previous file to
    /// `versions/` only when the last copy is more than ten minutes old."
    public static let keepInterval: Int64 = 10 * 60_000

    /// Spec 1 §4 — "Every List master carries an integer `version` that
    /// increments on each save that replaces its file. A new list is written
    /// at the version it has ... A save writes the previous document to the
    /// versions folder before overwriting when the last copy there is more
    /// than ten minutes old ... No save writes over a kept version: a list at
    /// or below the highest version kept for it saves one above that, and a
    /// previous document whose version is already kept isn't copied again."
    /// Spec 7 §2 — "a save renames the file within its folder", but "A save
    /// that would rename a list's file onto a name another file holds keeps
    /// its old name". `currentPath` is where its file is now, or nil for a
    /// list not yet written; `folder` is where a new one goes; `taken` holds
    /// the paths other files hold, compared ignoring case; `now` is the time
    /// in milliseconds since 1970.
    public static func saveList(_ list: List, extras: [String: JSONValue] = [:], currentPath: String?, folder: String,
                                kept: KeptVersions, now: Int64, taken: Set<String>) -> ListSave {
        var saved = list
        var after = kept
        var plan = WritePlan()
        let highest = kept.highest(list.uuid) ?? 0
        if let currentPath {
            saved.version = max(list.version, highest) + 1
            // The previous document, at the version its file carries.
            let lastKept = kept.lastKeptAt(list.uuid)
            if lastKept.map({ now - $0 > keepInterval }) ?? true, !kept.has(list.uuid, version: list.version) {
                plan.operations.append(.copy(from: currentPath, to: FileLayout.versionPath(list: list.uuid, version: list.version)))
                after.lists[list.uuid, default: [:]][list.version] = now
            }
        } else if list.version <= highest {
            saved.version = highest + 1
        }
        let home = currentPath.map(FileLayout.folder(ofListPath:)) ?? folder
        var path = FileLayout.listPath(for: saved, folder: home)
        let others = Set(taken.map { $0.lowercased() })
        if let currentPath, path != currentPath {
            if others.contains(path.lowercased()) {
                path = currentPath
            } else {
                plan.operations.append(.move(from: currentPath, to: path))
            }
        } else if currentPath == nil, others.contains(path.lowercased()) {
            // A new list never writes over a file it doesn't own: the first
            // free name, as a playlist takes one (Spec 7 §3).
            let stem = String(path.dropLast(".json".count))
            var n = 2
            while others.contains((stem + "-" + String(n) + ".json").lowercased()) { n += 1 }
            path = stem + "-" + String(n) + ".json"
        }
        plan.operations.append(.replace(path: path, data: Writer.data(for: .list(saved), extras: extras)))
        return ListSave(list: saved, path: path, plan: plan, kept: after)
    }
}
