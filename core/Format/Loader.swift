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

    public init(files: [String: Data] = [:]) {
        self.files = files
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
            return LoadedDocument(kind: header.kind, body: document, extras: extras, migratedFrom: migrated.migratedFrom, path: path)
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
        for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            if FileLayout.isIgnored(path: path) || path.hasPrefix("versions/") { continue }
            guard let expected = FileLayout.expectedKind(forPath: path), expected.belongsToLibrary else {
                report.add(.info, .ignoredFile, file: path, subject: path, message: "not a library document; ignored")
                continue
            }
            do {
                let loaded = try document(path: path, data: data)
                install(loaded, into: &library)
            } catch let failure as DocumentFailure {
                report.add(failure)
                if let previous { carryOver(path: path, kind: expected, from: previous, into: &library) }
            } catch {
                report.add(.error, .unreadableDocument, file: path, subject: path, message: "\(error)")
            }
        }
        sort(&library)
        return (library, report)
    }

    /// Spec 1 §5 — load a machine root, the same way. The loader also applies
    /// the stack rule of §9 and the slot ranges of §3, since it "enforces that form".
    public static func machine(from snapshot: RootSnapshot, previous: Machine? = nil) -> (machine: Machine, report: ValidationReport) {
        var machine = Machine()
        var report = ValidationReport()
        for (path, data) in snapshot.files.sorted(by: { $0.key < $1.key }) {
            if FileLayout.isIgnored(path: path) { continue }
            guard let expected = FileLayout.expectedKind(forPath: path), expected.belongsToMachine else {
                report.add(.info, .ignoredFile, file: path, subject: path, message: "not a machine document; ignored")
                continue
            }
            do {
                let loaded = try document(path: path, data: data)
                install(loaded, into: &machine)
            } catch let failure as DocumentFailure {
                report.add(failure)
                if let previous { carryOver(path: path, kind: expected, from: previous, into: &machine) }
            } catch {
                report.add(.error, .unreadableDocument, file: path, subject: path, message: "\(error)")
            }
        }
        sort(&machine)
        Validator.checkStacks(machine, into: &report, file: DocumentKind.stacks.fixedPath)
        return (machine, report)
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
        library.lists.sort { $0.number < $1.number }
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
