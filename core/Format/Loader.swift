// OCore — Spec 1 §5 and §8, the loader.
//
// The loader is pure: it takes a root's documents as bytes (`RootSnapshot`)
// and returns values and a report. The file adapter in formats/OFormats is
// what reads the folder.

import Foundation

/// Spec 1 §5 — a root's documents, relative path (forward slashes) to bytes.
/// The media folder is not part of it.
public struct RootSnapshot: Equatable, Sendable {
    public var files: [String: Data]
    /// Spec 7 §2 — the root's folders, empty ones included, as relative paths
    /// (`lists/Hymns`): the loader "records folders as well as files, so an
    /// empty folder survives a reload". Dot-folders are not walked.
    public var folders: Set<String>
    /// Spec 7 §2 — visible files that aren't documents (a note, a picture),
    /// which keep a folder from being empty.
    public var otherFiles: Set<String>
    /// Spec 7 §2 — each document's modification date, in milliseconds since
    /// 1970, for the tie-breaks between files that hold one list or playlist.
    public var modified: [String: Int64]
    /// Spec 9 §6 — the kept versions under `versions/`, by path, with their
    /// dates; their bytes aren't read.
    public var versions: [String: Int64]

    public init(files: [String: Data] = [:], folders: Set<String> = [], otherFiles: Set<String> = [],
                modified: [String: Int64] = [:], versions: [String: Int64] = [:]) {
        self.files = files
        self.folders = folders
        self.otherFiles = otherFiles
        self.modified = modified
        self.versions = versions
    }
}

/// Spec 1 §5 and §8 — reading documents and roots.
public enum Loader {
    // MARK: - One document

    /// Spec 1 §5 — parse, check the header, migrate (Spec 1 §8) and decode one
    /// document. Throws `DocumentFailure` for malformed JSON, a missing or
    /// unknown header, a schema outside what the app reads, a document whose
    /// kind does not match its place in the root, or a body of the wrong shape.
    public static func document(path: String, data: Data) throws -> LoadedDocument {
        let tree: JSONValue
        do {
            tree = try JSONValue.parse(data)
        } catch let error as JSONParseError {
            throw DocumentFailure.malformedJSON(path: path, line: error.line, column: error.column, message: error.message)
        }
        let header = try DocumentHeader.read(from: tree, path: path)
        if let expected = FileLayout.expectedKind(forPath: path), expected != header.kind {
            throw DocumentFailure.unreadable(path: path, message: "a \(header.kind.rawValue) document where a \(expected.rawValue) belongs")
        }
        let migrated = try Migrations.apply(tree, kind: header.kind, path: path)
        let body = migrated.document.removing("schema").removing("app").removing("kind")
        do {
            let (document, extras) = try decode(kind: header.kind, body: body)
            return LoadedDocument(kind: header.kind, body: document, extras: extras, migratedFrom: migrated.migratedFrom, path: path,
                                  issues: try issues(in: document, body: body, path: path))
        } catch let error as DecodingError {
            throw DocumentFailure.unreadable(path: path, message: JSONCoding.describe(error))
        }
    }

    /// Decode a body of one kind. Per-object kinds keep their unknown keys in
    /// the object; catalog kinds return theirs beside the collection.
    static func decode(kind: DocumentKind, body: JSONValue) throws -> (Document, [String: JSONValue]) {
        func collection<T: Decodable>(_ type: T.Type) throws -> (T, [String: JSONValue]) {
            let key = kind.collectionKey ?? kind.rawValue
            let items = try JSONCoding.decode(type, from: body[key] ?? .array([]))
            return (items, body.removing(key).objectValue ?? [:])
        }
        switch kind {
        case .library: return (.library(try JSONCoding.decode(LibraryInfo.self, from: body)), [:])
        case .channels: let (items, extras) = try collection([Channel].self); return (.channels(items), extras)
        case .textStyles: let (items, extras) = try collection([TextStyle].self); return (.textStyles(items), extras)
        case .grades: let (items, extras) = try collection([Grade].self); return (.grades(items), extras)
        case .transitions: let (items, extras) = try collection([Transition].self); return (.transitions(items), extras)
        case .audioTransitions: let (items, extras) = try collection([AudioTransition].self); return (.audioTransitions(items), extras)
        case .preset: return (.preset(try JSONCoding.decode(Preset.self, from: body)), [:])
        case .macro: return (.macro(try JSONCoding.decode(Macro.self, from: body)), [:])
        case .list: return (.list(try JSONCoding.decode(List.self, from: body)), [:])
        case .mediaIndex: return (.mediaIndex(try JSONCoding.decode(MediaIndex.self, from: body)), [:])
        case .machine: return (.machine(try JSONCoding.decode(MachineSettings.self, from: body)), [:])
        case .stacks: let (items, extras) = try collection([Stack].self); return (.stacks(items), extras)
        case .outputs: let (items, extras) = try collection([Output].self); return (.outputs(items), extras)
        case .audioOutputs: let (items, extras) = try collection([AudioOutput].self); return (.audioOutputs(items), extras)
        case .inputs: let (items, extras) = try collection([Input].self); return (.inputs(items), extras)
        case .clocks: return (.clocks(body), [:])
        case .keys: let (items, extras) = try collection([KeyBinding].self); return (.keys(items), extras)
        case .mediaLocal: return (.mediaLocal(try JSONCoding.decode(MediaLocalIndex.self, from: body)), [:])
        case .playlist: return (.playlist(try JSONCoding.decode(Playlist.self, from: body)), [:])
        case .state:
            let state = try JSONCoding.decode(ShowState.self, from: body["state"] ?? .object([:]))
            return (.state(state), body.removing("state").objectValue ?? [:])
        case .mediaCache: return (.mediaCache(try JSONCoding.decode(MediaCache.self, from: body)), [:])
        }
    }

    /// Spec 7 §3 — "An item whose uuid repeats an earlier item's is treated
    /// as having none, and is reported." The decoded playlist has already
    /// given such an item a uuid of its own; the report says which one.
    static func issues(in document: Document, body: JSONValue, path: String) throws -> [ValidationIssue] {
        guard case .playlist(let playlist) = document else { return [] }
        let drafts = try JSONCoding.decode([PlaylistItem.Draft].self, from: body["items"] ?? .array([]))
        return PlaylistItem.assigningUuids(to: drafts, namespace: playlist.uuid).repeated.map { index in
            ValidationIssue(severity: .warning, code: .repeatedItemUuid, file: path, subject: "playlist \(playlist.title) item \(index + 1)",
                            message: "repeats the uuid of an earlier item; given one of its own until the next save")
        }
    }

    // MARK: - Roots

    /// Spec 1 §5 — load a library root. Every document that reads installs
    /// its objects; a document that fails hard (§8) is reported and, when a
    /// `previous` library is given, its previous contents stay in place.
    /// Files the layout does not know are reported and skipped; a sync tool's
    /// temporary files are skipped silently. Objects come back in number order.
    public static func library(from snapshot: RootSnapshot, previous: Library? = nil) -> (library: Library, report: ValidationReport) {
        var library = Library()
        var report = ValidationReport()
        var lists: [(list: List, path: String)] = []
        for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            if FileLayout.isIgnored(path: path) || path.hasPrefix("versions/") { continue }
            guard let expected = FileLayout.expectedKind(forPath: path), expected.belongsToLibrary else {
                report.add(.info, .ignoredFile, file: path, subject: path, message: "not a library document; ignored")
                continue
            }
            do {
                let loaded = try document(path: path, data: data)
                if case .list(let list) = loaded.body {
                    lists.append((list, path))
                } else {
                    install(loaded, into: &library)
                }
                report.add(loaded.issues)
            } catch let failure as DocumentFailure {
                report.add(failure)
                if let previous { carryOver(path: path, kind: expected, from: previous, into: &library) }
                // Spec 7 §2 — a file that didn't load is still a file: it keeps
                // its folder from being empty and its name from being taken.
                if path.hasPrefix("lists/") { library.otherFiles.insert(path) }
            } catch {
                report.add(.error, .unreadableDocument, file: path, subject: path, message: "\(error)")
                if path.hasPrefix("lists/") { library.otherFiles.insert(path) }
            }
        }
        // Spec 7 §2 — "The Library window's folder tree is the tree of folders
        // under `lists/`", empty ones included; dot-folders are not walked.
        library.folders = snapshot.folders.compactMap { folder in
            guard folder.hasPrefix("lists/"), !FileLayout.isIgnored(path: folder) else { return nil }
            return String(folder.dropFirst("lists/".count))
        }.sorted()
        library.otherFiles.formUnion(snapshot.otherFiles.filter { $0.hasPrefix("lists/") && !FileLayout.isIgnored(path: $0) })
        reportCaseClashes(library.folders, into: &report)
        install(lists: lists, snapshot: snapshot, into: &library, report: &report)
        sort(&library)
        return (library, report)
    }

    /// Spec 7 §2 — "When two files hold the same list (the same uuid), one
    /// loads. The engine prefers the file whose name is the one it would write
    /// for that list, then the higher `version`, then the later modification
    /// date, then the path that sorts first. The other file is reported." And
    /// "Two different lists with the same number both load ... Anything that
    /// names the number alone ... gets the one that comes first in the same
    /// order": lists sharing a number keep that order until they reload.
    static func install(lists candidates: [(list: List, path: String)], snapshot: RootSnapshot,
                        into library: inout Library, report: inout ValidationReport) {
        func rank(_ candidate: (list: List, path: String)) -> (Int, Int, Int64, String) {
            Loader.rank(list: candidate.list, path: candidate.path, modified: snapshot.modified[candidate.path] ?? 0)
        }
        var groups: [UUID: [(list: List, path: String)]] = [:]
        var order: [UUID] = []
        for candidate in candidates {
            if groups[candidate.list.uuid] == nil { order.append(candidate.list.uuid) }
            groups[candidate.list.uuid, default: []].append(candidate)
        }
        var kept: [(list: List, path: String)] = []
        for uuid in order {
            let ranked = (groups[uuid] ?? []).sorted { rank($0) < rank($1) }
            guard let winner = ranked.first else { continue }
            kept.append(winner)
            for loser in ranked.dropFirst() {
                report.add(.warning, .duplicateFile, file: loser.path, subject: "list \(loser.list.number)",
                           message: "another file holds this list (\(uuid.uuidString.lowercased())): \(winner.path) is loaded, and this file is never written over")
                library.otherFiles.insert(loser.path)
            }
        }
        kept.sort { a, b in a.list.number != b.list.number ? a.list.number < b.list.number : rank(a) < rank(b) }
        for candidate in kept {
            library.lists.append(candidate.list)
            library.documentPaths[FileLayout.documentKey(list: candidate.list.uuid)] = candidate.path
        }
    }

    /// Spec 7 §2 — the order two files holding one list are preferred in,
    /// least first: "the file whose name is the one it would write for that
    /// list, then the higher `version`, then the later modification date,
    /// then the path that sorts first". A reload ranks them the same way.
    static func rank(list: List, path: String, modified: Int64) -> (Int, Int, Int64, String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let own = name == FileLayout.numbered(list.number, list.title) + ".json"
        return (own ? 0 : 1, -list.version, -modified, path)
    }

    /// Spec 7 §3 — "the file named with the plain slug of its title, then the
    /// later modification date, then the path that sorts first".
    static func rank(playlist: Playlist, path: String, modified: Int64) -> (Int, Int64, String) {
        let plain = path == FileLayout.plainPath(forPlaylist: playlist)
        return (plain ? 0 : 1, -modified, path)
    }

    /// Spec 7 §2 — "On a case-sensitive volume two folders can differ only by
    /// case. The tree shows them as one folder, the report names them".
    static func reportCaseClashes(_ folders: [String], into report: inout ValidationReport) {
        var first: [String: String] = [:]
        for folder in folders.sorted() {
            let key = folder.lowercased()
            if let earlier = first[key] {
                report.add(.warning, .folderCaseClash, file: "lists/" + folder, subject: "folder \(folder)",
                           message: "differs from folder \(earlier) only in case; it shows as one folder, and folder edits to it are refused until one is renamed")
            } else {
                first[key] = folder
            }
        }
    }

    /// Spec 1 §5 — load a machine root, the same way. The loader also applies
    /// the stack rule of §9 and the slot ranges of §3, since it "enforces that form".
    public static func machine(from snapshot: RootSnapshot, previous: Machine? = nil) -> (machine: Machine, report: ValidationReport) {
        var machine = Machine()
        var report = ValidationReport()
        var playlists: [(playlist: Playlist, path: String)] = []
        for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            // Spec 8 §4 — the media cache: "the loader leaves it alone".
            if FileLayout.isIgnored(path: path) || path == DocumentKind.mediaCache.fixedPath { continue }
            guard let expected = FileLayout.expectedKind(forPath: path), expected.belongsToMachine else {
                report.add(.info, .ignoredFile, file: path, subject: path, message: "not a machine document; ignored")
                continue
            }
            do {
                let loaded = try document(path: path, data: data)
                if case .playlist(let playlist) = loaded.body {
                    playlists.append((playlist, path))
                } else {
                    install(loaded, into: &machine)
                }
                report.add(loaded.issues)
            } catch let failure as DocumentFailure {
                report.add(failure)
                if let previous { carryOver(path: path, kind: expected, from: previous, into: &machine) }
            } catch {
                report.add(.error, .unreadableDocument, file: path, subject: path, message: "\(error)")
            }
        }
        install(playlists: playlists, snapshot: snapshot, into: &machine, report: &report)
        sort(&machine)
        Validator.checkStacks(machine, into: &report, file: DocumentKind.stacks.fixedPath)
        return (machine, report)
    }

    /// Spec 7 §3 — "Two files with the same playlist uuid load as one: the
    /// file named with the plain slug of its title, then the later
    /// modification date, then the path that sorts first; the other is
    /// reported."
    static func install(playlists candidates: [(playlist: Playlist, path: String)], snapshot: RootSnapshot,
                        into machine: inout Machine, report: inout ValidationReport) {
        func rank(_ candidate: (playlist: Playlist, path: String)) -> (Int, Int64, String) {
            Loader.rank(playlist: candidate.playlist, path: candidate.path, modified: snapshot.modified[candidate.path] ?? 0)
        }
        var groups: [UUID: [(playlist: Playlist, path: String)]] = [:]
        var order: [UUID] = []
        for candidate in candidates {
            if groups[candidate.playlist.uuid] == nil { order.append(candidate.playlist.uuid) }
            groups[candidate.playlist.uuid, default: []].append(candidate)
        }
        for uuid in order {
            let ranked = (groups[uuid] ?? []).sorted { rank($0) < rank($1) }
            guard let winner = ranked.first else { continue }
            machine.playlists.append(winner.playlist)
            machine.documentPaths[FileLayout.documentKey(playlist: uuid)] = winner.path
            for loser in ranked.dropFirst() {
                report.add(.warning, .duplicateFile, file: loser.path, subject: "playlist \(loser.playlist.title)",
                           message: "another file holds this playlist (\(uuid.uuidString.lowercased())): \(winner.path) is loaded")
                machine.otherFiles.insert(loser.path)
            }
        }
    }

    // MARK: - Installing documents

    static func install(_ loaded: LoadedDocument, into library: inout Library) {
        if let key = FileLayout.documentKey(for: loaded.body) { library.documentPaths[key] = loaded.path }
        if !loaded.extras.isEmpty { library.documentExtras[loaded.kind] = loaded.extras }
        switch loaded.body {
        case .library(let info): library.info = info
        case .channels(let items): library.channels = items
        case .textStyles(let items): library.textStyles = items
        case .grades(let items): library.grades = items
        case .transitions(let items): library.transitions = items
        case .audioTransitions(let items): library.audioTransitions = items
        case .preset(let preset): library.presets.append(preset)
        case .macro(let macro): library.macros.append(macro)
        case .list(let list): library.lists.append(list)
        case .mediaIndex(let index): library.mediaIndex = index
        default: break
        }
    }

    static func install(_ loaded: LoadedDocument, into machine: inout Machine) {
        if let key = FileLayout.documentKey(for: loaded.body) { machine.documentPaths[key] = loaded.path }
        if !loaded.extras.isEmpty { machine.documentExtras[loaded.kind] = loaded.extras }
        switch loaded.body {
        case .machine(let settings): machine.settings = settings
        case .stacks(let items): machine.stacks = items
        case .outputs(let items): machine.outputs = items
        case .audioOutputs(let items): machine.audioOutputs = items
        case .inputs(let items): machine.inputs = items
        case .clocks(let body): machine.clocks = body
        case .keys(let items): machine.keys = items
        case .mediaLocal(let index): machine.mediaLocal = index
        case .macro(let macro): machine.macros.append(macro)
        case .playlist(let playlist): machine.playlists.append(playlist)
        case .list(let list): machine.localLists.append(list)
        case .state(let state): machine.lastState = state
        default: break
        }
    }

    /// Spec 1 §8 — "leave the previous good state in place": the previous
    /// library's contents for a document that failed to load.
    static func carryOver(path: String, kind: DocumentKind, from previous: Library, into library: inout Library) {
        if let extras = previous.documentExtras[kind] { library.documentExtras[kind] = extras }
        switch kind {
        case .library: library.info = previous.info
        case .channels: library.channels = previous.channels
        case .textStyles: library.textStyles = previous.textStyles
        case .grades: library.grades = previous.grades
        case .transitions: library.transitions = previous.transitions
        case .audioTransitions: library.audioTransitions = previous.audioTransitions
        case .mediaIndex: library.mediaIndex = previous.mediaIndex
        case .preset:
            if let p = previous.presets.first(where: { previous.documentPaths["preset/\($0.number)"] == path }) {
                library.presets.append(p)
                library.documentPaths["preset/\(p.number)"] = path
            }
        case .macro:
            if let m = previous.macros.first(where: { previous.documentPaths["macro/\($0.number)"] == path }) {
                library.macros.append(m)
                library.documentPaths["macro/\(m.number)"] = path
            }
        case .list:
            if let l = previous.lists.first(where: { previous.documentPaths["list/" + $0.uuid.uuidString.lowercased()] == path }) {
                library.lists.append(l)
                library.documentPaths["list/" + l.uuid.uuidString.lowercased()] = path
            }
        default: break
        }
    }

    static func carryOver(path: String, kind: DocumentKind, from previous: Machine, into machine: inout Machine) {
        if let extras = previous.documentExtras[kind] { machine.documentExtras[kind] = extras }
        switch kind {
        case .machine: machine.settings = previous.settings
        case .stacks: machine.stacks = previous.stacks
        case .outputs: machine.outputs = previous.outputs
        case .audioOutputs: machine.audioOutputs = previous.audioOutputs
        case .inputs: machine.inputs = previous.inputs
        case .clocks: machine.clocks = previous.clocks
        case .keys: machine.keys = previous.keys
        case .mediaLocal: machine.mediaLocal = previous.mediaLocal
        case .state: machine.lastState = previous.lastState
        case .macro:
            if let m = previous.macros.first(where: { previous.documentPaths["macro/\($0.number)"] == path }) {
                machine.macros.append(m)
                machine.documentPaths["macro/\(m.number)"] = path
            }
        case .playlist:
            if let p = previous.playlists.first(where: { previous.documentPaths["playlist/" + $0.uuid.uuidString.lowercased()] == path }) {
                machine.playlists.append(p)
                machine.documentPaths["playlist/" + p.uuid.uuidString.lowercased()] = path
            }
        case .list:
            if let l = previous.localLists.first(where: { previous.documentPaths["local/" + $0.uuid.uuidString.lowercased()] == path }) {
                machine.localLists.append(l)
                machine.documentPaths["local/" + l.uuid.uuidString.lowercased()] = path
            }
        default: break
        }
    }

    /// Spec 1 §4 — "the default ordering everywhere is by number".
    static func sort(_ library: inout Library) {
        library.channels.sort { $0.number < $1.number }
        library.textStyles.sort { $0.number < $1.number }
        library.grades.sort { $0.number < $1.number }
        library.transitions.sort { $0.number < $1.number }
        library.audioTransitions.sort { $0.number < $1.number }
        library.presets.sort { $0.number < $1.number }
        library.macros.sort { $0.number < $1.number }
        // Spec 7 §2 — lists sharing a number keep the order they loaded in.
        library.lists = library.lists.enumerated()
            .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
            .map(\.element)
    }

    static func sort(_ machine: inout Machine) {
        machine.stacks.sort { $0.number < $1.number }
        machine.outputs.sort { $0.number < $1.number }
        machine.audioOutputs.sort { $0.number < $1.number }
        machine.inputs.sort { $0.number < $1.number }
        machine.macros.sort { $0.number < $1.number }
        machine.playlists.sort { ($0.serviceDate ?? "", $0.title.lowercased()) < ($1.serviceDate ?? "", $1.title.lowercased()) }
        machine.localLists.sort { $0.number < $1.number }
    }
}
