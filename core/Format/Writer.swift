// OCore — Spec 1 §4 and §5, the writer.
//
// The writer is pure: it turns documents into canonical bytes and a save into
// a plan of whole-file operations. The file adapter in formats/OFormats
// executes a plan with the temp-file, fsync and rename of §5.

import Foundation

/// Spec 1 §5 — one whole-file operation of a save. `replace` is atomic in
/// the adapter: "writes to a temporary file in the same folder, fsyncs, and
/// renames over the original".
public enum FileOperation: Equatable, Sendable {
    case replace(path: String, data: Data)
    case move(from: String, to: String)
    case remove(path: String)
}

/// Spec 1 §5 — an ordered list of file operations; executing them in order
/// is the whole of a save.
public struct WritePlan: Equatable, Sendable {
    public var operations: [FileOperation]

    public init(operations: [FileOperation] = []) {
        self.operations = operations
    }
}

/// Spec 1 §5 — documents to bytes, and saves to plans.
public enum Writer {
    // MARK: - Documents

    /// Spec 1 §5 — the document tree: the header stamped by this app, the
    /// body, and a catalog document's unknown top-level keys.
    public static func tree(for document: Document, extras: [String: JSONValue] = [:]) -> JSONValue {
        var members = extras
        func merge(_ value: JSONValue) {
            for (key, member) in value.objectValue ?? [:] { members[key] = member }
        }
        switch document {
        case .library(let info): merge(encode(info))
        case .channels(let items): members["channels"] = encode(items)
        case .textStyles(let items): members["textStyles"] = encode(items)
        case .grades(let items): members["grades"] = encode(items)
        case .transitions(let items): members["transitions"] = encode(items)
        case .audioTransitions(let items): members["audioTransitions"] = encode(items)
        case .preset(let preset): merge(encode(preset))
        case .macro(let macro): merge(encode(macro))
        case .list(let list): merge(encode(list))
        case .mediaIndex(let index): merge(encode(index))
        case .machine(let settings): merge(encode(settings))
        case .stacks(let items): members["stacks"] = encode(items)
        case .outputs(let items): members["outputs"] = encode(items)
        case .audioOutputs(let items): members["audioOutputs"] = encode(items)
        case .inputs(let items): members["inputs"] = encode(items)
        case .clocks(let body): merge(body)
        case .keys(let items): members["bindings"] = encode(items)
        case .mediaLocal(let index): merge(encode(index))
        case .playlist(let playlist): merge(encode(playlist))
        case .state(let state): members["state"] = encode(state)
        }
        members["schema"] = .number(Double(document.kind.currentSchema))
        members["app"] = .string(OCore.appVersion)
        members["kind"] = .string(document.kind.rawValue)
        return .object(members)
    }

    /// The canonical bytes of a document (Spec 1 §5).
    public static func data(for document: Document, extras: [String: JSONValue] = [:]) -> Data {
        JSONCanonical.data(tree(for: document, extras: extras))
    }

    /// The canonical bytes of a loaded document, at the current schema
    /// whatever schema it was read from (Spec 1 §8).
    public static func data(for loaded: LoadedDocument) -> Data {
        data(for: loaded.body, extras: loaded.extras)
    }

    /// Encode one of the format's own values. The format's encoders cannot
    /// fail: every field is a finite number, a string, a bool, a nested value
    /// or null, and non-finite doubles are written as strings rather than
    /// refused. The fallback is unreachable and keeps the writer total.
    static func encode<T: Encodable>(_ value: T) -> JSONValue {
        (try? JSONCoding.encode(value)) ?? .null
    }

    // MARK: - Saves

    /// Spec 1 §5 — save one document: rename its file to match its number and
    /// label if it moved ("renames the file to match on save"), then replace
    /// it atomically.
    public static func save(_ document: Document, extras: [String: JSONValue] = [:], currentPath: String? = nil) -> WritePlan {
        var plan = WritePlan()
        let path = FileLayout.path(for: document)
        if let currentPath, currentPath != path {
            plan.operations.append(.move(from: currentPath, to: path))
        }
        plan.operations.append(.replace(path: path, data: data(for: document, extras: extras)))
        return plan
    }

    /// Spec 1 §4 — "Every List master carries an integer `version` that
    /// increments on each save. Saving writes the previous document to the
    /// versions folder (section 5) before overwriting." Returns the list as
    /// saved, one version on, and the plan: the previous bytes into
    /// `versions/NNN/vNNNN.json`, a rename if the title changed, the new
    /// document. A local copy keeps its versions beside the masters' too.
    public static func saveList(_ list: List, extras: [String: JSONValue] = [:], previous: Data?, currentPath: String?) -> (list: List, plan: WritePlan) {
        var saved = list
        saved.version = list.version + 1
        var plan = WritePlan()
        if let previous {
            plan.operations.append(.replace(path: FileLayout.versionPath(list: list.number, version: list.version), data: previous))
        }
        plan.operations.append(contentsOf: save(.list(saved), extras: extras, currentPath: currentPath).operations)
        return (saved, plan)
    }

    // MARK: - Whole roots

    /// Every document of a library root at its canonical path, as bytes.
    /// Previous versions are not loaded, so they are not written.
    public static func snapshot(of library: Library) -> RootSnapshot {
        var files: [String: Data] = [:]
        func put(_ document: Document) {
            files[FileLayout.path(for: document)] = data(for: document, extras: library.documentExtras[document.kind] ?? [:])
        }
        put(.library(library.info))
        put(.channels(library.channels))
        put(.textStyles(library.textStyles))
        put(.grades(library.grades))
        put(.transitions(library.transitions))
        put(.audioTransitions(library.audioTransitions))
        put(.mediaIndex(library.mediaIndex))
        for preset in library.presets { put(.preset(preset)) }
        for macro in library.macros { put(.macro(macro)) }
        for list in library.lists { put(.list(list)) }
        return RootSnapshot(files: files)
    }

    /// Every document of a machine root at its canonical path, as bytes.
    public static func snapshot(of machine: Machine) -> RootSnapshot {
        var files: [String: Data] = [:]
        func put(_ document: Document) {
            files[FileLayout.path(for: document)] = data(for: document, extras: machine.documentExtras[document.kind] ?? [:])
        }
        put(.machine(machine.settings))
        put(.stacks(machine.stacks))
        put(.outputs(machine.outputs))
        put(.audioOutputs(machine.audioOutputs))
        put(.inputs(machine.inputs))
        put(.clocks(machine.clocks))
        put(.keys(machine.keys))
        put(.mediaLocal(machine.mediaLocal))
        for macro in machine.macros { put(.macro(macro)) }
        for playlist in machine.playlists { put(.playlist(playlist)) }
        for list in machine.localLists { put(.list(list)) }
        if let state = machine.lastState { put(.state(state)) }
        return RootSnapshot(files: files)
    }
}
