// OCore — Spec 9 §3, what a snapshot holds: its documents and its manifest.
//
// Pure: the roots in, paths and bytes out. The engine zips them on a worker
// (`engine/OEngine/Saving`); nothing here touches a file or a clock.

import Foundation

/// Spec 9 §3 — the manifest, `snapshot.json`:
///
/// ```json
/// { "schema": 1, "app": "0.1.0", "kind": "snapshot", "id": "2026-11-08-085959",
///   "takenAt": "2026-11-08T08:59:59.120-05:00", "reason": "playlist",
///   "machine": "7d1e…", "campus": "Manheim", "library": "c3f0…", "run": "51e2…", "seq": 4821,
///   "folders": ["Hymns", "Worship/New"] }
/// ```
///
/// "`run` and `seq` name the last command logged before it; `folders` lists
/// the library's folders, so an empty one survives a restore (Spec 7 §2)."
/// Keys this app doesn't know survive a read and a write (Spec 1 §8).
public struct SnapshotManifest: Equatable, Sendable {
    /// Spec 9 §3 — "`reason` is `launch`, `playlist`, `timer`, `command` or `restore`".
    public enum Reason: String, Sendable, CaseIterable {
        case launch, playlist, timer, command, restore

        /// Spec 9 §3 — "An automatic snapshot (`launch`, `playlist` or
        /// `timer`)": not written when nothing changed, paused on a low disk,
        /// and noted (§2).
        public var isAutomatic: Bool {
            switch self {
            case .launch, .playlist, .timer: return true
            case .command, .restore: return false
            }
        }
    }

    /// The manifest's place in the zip.
    public static let path = "snapshot.json"
    /// The schema this app writes, and the highest it reads.
    public static let schema = 1

    public var schema: Int
    public var app: String
    public var id: String
    public var takenAt: String
    /// As written: a later app's reason is kept as read.
    public var reason: String
    public var machine: String?
    public var campus: String?
    public var library: String?
    public var run: String?
    public var seq: Int?
    public var folders: [String]
    public var extra: [String: JSONValue]

    public init(id: String, takenAt: String, reason: Reason, machine: UUID?, campus: String?, library: UUID?, run: UUID?, seq: Int?,
                folders: [String]) {
        self.schema = Self.schema
        self.app = OCore.appVersion
        self.id = id
        self.takenAt = takenAt
        self.reason = reason.rawValue
        self.machine = machine?.uuidString.lowercased()
        self.campus = campus
        self.library = library?.uuidString.lowercased()
        self.run = run?.uuidString.lowercased()
        self.seq = seq
        self.folders = folders.sorted()
        self.extra = [:]
    }

    private static let known: Set<String> = ["schema", "app", "kind", "id", "takenAt", "reason", "machine", "campus", "library", "run",
                                             "seq", "folders"]

    /// Spec 9 §6 — "Each document is read as the loader reads it": the
    /// manifest too. Nil for bytes that aren't a snapshot's manifest, or one
    /// from a schema this app can't read.
    public init?(data: Data) {
        guard case .object(let members)? = try? JSONValue.parse(data), members["kind"] == .string("snapshot"),
              let schema = members["schema"]?.intValue, schema >= 1, schema <= Self.schema,
              let id = members["id"]?.stringValue else { return nil }
        self.schema = schema
        app = members["app"]?.stringValue ?? ""
        self.id = id
        takenAt = members["takenAt"]?.stringValue ?? ""
        reason = members["reason"]?.stringValue ?? ""
        machine = members["machine"]?.stringValue
        campus = members["campus"]?.stringValue
        library = members["library"]?.stringValue
        run = members["run"]?.stringValue
        seq = members["seq"]?.intValue
        folders = (members["folders"]?.arrayValue ?? []).compactMap(\.stringValue)
        extra = members.filter { !Self.known.contains($0.key) }
    }

    public var json: JSONValue {
        var members = extra
        members["schema"] = .number(Double(schema))
        members["app"] = .string(app)
        members["kind"] = .string("snapshot")
        members["id"] = .string(id)
        members["takenAt"] = .string(takenAt)
        members["reason"] = .string(reason)
        if let machine { members["machine"] = .string(machine) }
        if let campus { members["campus"] = .string(campus) }
        if let library { members["library"] = .string(library) }
        if let run { members["run"] = .string(run) }
        if let seq { members["seq"] = .number(Double(seq)) }
        members["folders"] = .array(folders.map(JSONValue.string))
        return .object(members)
    }

    /// The manifest's canonical bytes (Spec 1 §5).
    public var data: Data { JSONCanonical.data(json) }
}

/// Spec 9 §3 — "A snapshot is one zip file holding the documents of both
/// roots, as the engine holds them at that moment, unwritten edits included.
/// Inside the zip they sit under `library/` and `machine/` at the paths Spec
/// 1 §5 gives them, with a manifest".
public struct Snapshot: Equatable, Sendable {
    public var manifest: SnapshotManifest
    /// Every document by its path in the zip, `library/…` or `machine/…`.
    public var documents: [String: Data]

    public init(manifest: SnapshotManifest, documents: [String: Data]) {
        self.manifest = manifest
        self.documents = documents
    }

    /// Why a zip's files aren't a snapshot this app reads.
    public struct Unreadable: Error, Equatable, Sendable {
        public var message: String
    }

    // MARK: - Taking one

    /// Spec 9 §3 — the documents of both roots as bytes, each at its path in
    /// the zip. "Left out: `media/`, `logs/`, `snapshots/`, `thumbnails/`,
    /// the black box, the machine's own media folder ... and the media cache,
    /// as G1 says, and also `versions/`, `conflicts/` and `state/` (choice
    /// G-6), and the app's `view.json` and the engine's socket and lock":
    /// none of those is a document the roots hold but the last state, which
    /// is skipped here. A document sits where its file is, or where its
    /// first save will put it.
    public static func documents(library: Library, machine: Machine) -> [String: Data] {
        var files: [String: Data] = [:]
        func put(_ data: Data, _ root: String, _ path: String) {
            var candidate = root + path
            var n = 2
            // Two documents can't share a path in the zip: the second takes `-2`, as a new file would.
            while files[candidate] != nil {
                candidate = root + String(path.dropLast(".json".count)) + "-\(n).json"
                n += 1
            }
            files[candidate] = data
        }
        func fixed(_ document: Document, _ root: String, _ extras: [DocumentKind: [String: JSONValue]]) {
            put(Writer.data(for: document, extras: extras[document.kind] ?? [:]), root, FileLayout.path(for: document))
        }

        fixed(.library(library.info), "library/", library.documentExtras)
        fixed(.channels(library.channels), "library/", library.documentExtras)
        fixed(.textStyles(library.textStyles), "library/", library.documentExtras)
        fixed(.grades(library.grades), "library/", library.documentExtras)
        fixed(.transitions(library.transitions), "library/", library.documentExtras)
        fixed(.audioTransitions(library.audioTransitions), "library/", library.documentExtras)
        fixed(.mediaIndex(library.mediaIndex), "library/", library.documentExtras)
        for preset in library.presets {
            put(Writer.data(for: .preset(preset)), "library/", library.documentPaths["preset/\(preset.number)"] ?? FileLayout.path(for: .preset(preset)))
        }
        for macro in library.macros {
            put(Writer.data(for: .macro(macro)), "library/", library.documentPaths["macro/\(macro.number)"] ?? FileLayout.path(for: .macro(macro)))
        }
        for list in library.lists {
            let path = library.documentPaths[FileLayout.documentKey(list: list.uuid)] ?? FileLayout.listPath(for: list, folder: "")
            put(Writer.data(for: .list(list)), "library/", path)
        }

        fixed(.machine(machine.settings), "machine/", machine.documentExtras)
        fixed(.stacks(machine.stacks), "machine/", machine.documentExtras)
        fixed(.outputs(machine.outputs), "machine/", machine.documentExtras)
        fixed(.audioOutputs(machine.audioOutputs), "machine/", machine.documentExtras)
        fixed(.inputs(machine.inputs), "machine/", machine.documentExtras)
        fixed(.clocks(machine.clocks), "machine/", machine.documentExtras)
        fixed(.keys(machine.keys), "machine/", machine.documentExtras)
        fixed(.mediaLocal(machine.mediaLocal), "machine/", machine.documentExtras)
        for macro in machine.macros {
            put(Writer.data(for: .macro(macro)), "machine/", machine.documentPaths["macro/\(macro.number)"] ?? FileLayout.path(for: .macro(macro)))
        }
        for playlist in machine.playlists {
            let path = machine.documentPaths[FileLayout.documentKey(playlist: playlist.uuid)] ?? FileLayout.plainPath(forPlaylist: playlist)
            put(Writer.data(for: .playlist(playlist)), "machine/", path)
        }
        for list in machine.localLists {
            let path = machine.documentPaths["local/" + list.uuid.uuidString.lowercased()] ?? FileLayout.path(for: .list(list))
            put(Writer.data(for: .list(list), extras: machine.documentExtras[.list] ?? [:]), "machine/", path)
        }
        return files
    }

    /// Spec 9 §3 — a snapshot of the roots as they are: the documents, and
    /// the manifest naming the machine, its campus, the library, the last
    /// command logged before it and the library's folders.
    public static func taking(id: String, takenAt: String, reason: SnapshotManifest.Reason, library: Library, machine: Machine,
                              run: UUID?, seq: Int?) -> Snapshot {
        let manifest = SnapshotManifest(id: id, takenAt: takenAt, reason: reason, machine: machine.settings.uuid,
                                        campus: machine.settings.campusName.isEmpty ? nil : machine.settings.campusName,
                                        library: library.info.uuid, run: run, seq: seq, folders: library.folders)
        return Snapshot(manifest: manifest, documents: documents(library: library, machine: machine))
    }

    /// The files of the zip, the manifest first and the documents in path order.
    public var files: [(path: String, data: Data)] {
        [(SnapshotManifest.path, manifest.data)] + documents.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Reading one

    /// A zip's files as a snapshot: the manifest, and what sits under
    /// `library/` and `machine/`. Anything else in the zip is left alone.
    public init(files: [(path: String, data: Data)]) throws {
        guard let found = files.first(where: { $0.path == SnapshotManifest.path }) else {
            throw Unreadable(message: "it has no \(SnapshotManifest.path)")
        }
        guard let manifest = SnapshotManifest(data: found.data) else {
            throw Unreadable(message: "its \(SnapshotManifest.path) isn't one this app reads")
        }
        self.manifest = manifest
        var documents: [String: Data] = [:]
        for file in files where file.path.hasPrefix("library/") || file.path.hasPrefix("machine/") { documents[file.path] = file.data }
        self.documents = documents
    }

    /// Spec 9 §3 — "An automatic snapshot ... whose documents equal the
    /// newest snapshot's isn't written": the same documents, byte for byte,
    /// and the same folders, so a folder made or removed since counts as a
    /// change too.
    public func holdsTheSame(as other: Snapshot) -> Bool {
        documents == other.documents && Set(manifest.folders) == Set(other.manifest.folders)
    }

    /// One root's documents as the loader takes a root: paths within the
    /// root, and the library's folders from the manifest.
    public func root(_ name: String) -> RootSnapshot {
        let prefix = name + "/"
        var files: [String: Data] = [:]
        for (path, data) in documents where path.hasPrefix(prefix) { files[String(path.dropFirst(prefix.count))] = data }
        var folders: Set<String> = []
        if name == "library" {
            for folder in manifest.folders {
                // A folder's parents are folders too.
                var path = ""
                for part in folder.split(separator: "/") {
                    path += (path.isEmpty ? "" : "/") + part
                    folders.insert("lists/" + path)
                }
            }
        }
        return RootSnapshot(files: files, folders: folders)
    }
}
