// OCore — Spec 1 §5 and §8, documents: kinds, headers, file names.

import Foundation

/// Spec 1 §5 — the document kinds of the two roots, by the `kind` in every
/// header. The single-document catalogs live at fixed names; presets, macros,
/// lists and playlists are one file per object.
public enum DocumentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case library, channels, textStyles, grades, transitions, audioTransitions, preset, macro, list, mediaIndex
    case machine, stacks, outputs, audioOutputs, inputs, clocks, keys, mediaLocal, playlist, state

    /// Spec 1 §8 — "The app knows the highest schema it writes".
    public var currentSchema: Int { OCore.schemaVersion }

    /// Spec 1 §8 — "and the lowest it can read". Only lists have a schema 0
    /// (the migration fixture of §10); every other kind starts at 1.
    public var lowestReadableSchema: Int { self == .list ? 0 : 1 }

    /// The hyphenated name used for catalog files and schema files.
    public var fileStem: String {
        switch self {
        case .textStyles: return "text-styles"
        case .audioTransitions: return "audio-transitions"
        case .mediaIndex: return "media-index"
        case .audioOutputs: return "audio-outputs"
        case .mediaLocal: return "media-local"
        default: return rawValue
        }
    }

    /// Spec 1 §5 — the fixed path of a single-document kind in its root; nil
    /// for the per-object kinds.
    public var fixedPath: String? {
        switch self {
        case .preset, .macro, .list, .playlist: return nil
        case .state: return "state/last.json"
        default: return fileStem + ".json"
        }
    }

    /// The array key of a catalog document (`channels`, `stacks`, ...).
    public var collectionKey: String? {
        switch self {
        case .channels, .textStyles, .grades, .transitions, .audioTransitions, .stacks, .outputs, .audioOutputs, .inputs:
            return rawValue
        case .keys: return "bindings"
        default: return nil
        }
    }

    /// The kinds a library root holds (Spec 1 §5). Macros belong to both roots.
    public var belongsToLibrary: Bool {
        switch self {
        case .library, .channels, .textStyles, .grades, .transitions, .audioTransitions, .preset, .macro, .list, .mediaIndex:
            return true
        default: return false
        }
    }

    /// The kinds a machine root holds (Spec 1 §5).
    public var belongsToMachine: Bool {
        switch self {
        case .machine, .stacks, .outputs, .audioOutputs, .inputs, .clocks, .keys, .mediaLocal, .macro, .playlist, .list, .state:
            return true
        default: return false
        }
    }
}

/// Spec 1 §5 — "Every document starts with the same header.
/// `{ "schema": 1, "app": "0.1.0", "kind": "list", ... }`"
public struct DocumentHeader: Equatable, Sendable {
    public var schema: Int
    public var app: String
    public var kind: DocumentKind

    public init(schema: Int, app: String, kind: DocumentKind) {
        self.schema = schema
        self.app = app
        self.kind = kind
    }

    /// Read the header of a parsed document; what lacks one is not a document.
    public static func read(from tree: JSONValue, path: String) throws -> DocumentHeader {
        guard case .object = tree else { throw DocumentFailure.notADocument(path: path, message: "not a JSON object") }
        guard let schema = tree["schema"]?.intValue else { throw DocumentFailure.notADocument(path: path, message: "no schema field") }
        guard let kindName = tree["kind"]?.stringValue else { throw DocumentFailure.notADocument(path: path, message: "no kind field") }
        guard let kind = DocumentKind(rawValue: kindName) else { throw DocumentFailure.notADocument(path: path, message: "unknown kind \(kindName)") }
        return DocumentHeader(schema: schema, app: tree["app"]?.stringValue ?? "", kind: kind)
    }
}

/// Spec 1 §5 — the body of one document of each kind.
public enum Document: Equatable, Sendable {
    case library(LibraryInfo)
    case channels([Channel])
    case textStyles([TextStyle])
    case grades([Grade])
    case transitions([Transition])
    case audioTransitions([AudioTransition])
    case preset(Preset)
    case macro(Macro)
    case list(List)
    case mediaIndex(MediaIndex)
    case machine(MachineSettings)
    case stacks([Stack])
    case outputs([Output])
    case audioOutputs([AudioOutput])
    case inputs([Input])
    /// Spec 1 §5 — `clocks.json` is reserved; the body is kept as read.
    case clocks(JSONValue)
    case keys([KeyBinding])
    case mediaLocal(MediaLocalIndex)
    case playlist(Playlist)
    case state(ShowState)

    public var kind: DocumentKind {
        switch self {
        case .library: return .library
        case .channels: return .channels
        case .textStyles: return .textStyles
        case .grades: return .grades
        case .transitions: return .transitions
        case .audioTransitions: return .audioTransitions
        case .preset: return .preset
        case .macro: return .macro
        case .list: return .list
        case .mediaIndex: return .mediaIndex
        case .machine: return .machine
        case .stacks: return .stacks
        case .outputs: return .outputs
        case .audioOutputs: return .audioOutputs
        case .inputs: return .inputs
        case .clocks: return .clocks
        case .keys: return .keys
        case .mediaLocal: return .mediaLocal
        case .playlist: return .playlist
        case .state: return .state
        }
    }
}

/// A document as the loader returns it: its kind, its body, the unknown
/// top-level keys of a catalog document, where it came from, and the schema
/// it was migrated from (Spec 1 §8: "migrated in memory and written back at
/// the current schema the next time it is saved, never on load alone").
public struct LoadedDocument: Equatable, Sendable {
    public var kind: DocumentKind
    public var body: Document
    public var extras: [String: JSONValue]
    public var migratedFrom: Int?
    public var path: String

    public init(kind: DocumentKind, body: Document, extras: [String: JSONValue] = [:], migratedFrom: Int? = nil, path: String) {
        self.kind = kind
        self.body = body
        self.extras = extras
        self.migratedFrom = migratedFrom
        self.path = path
    }
}

/// Spec 1 §8 — "Hard failures are only malformed JSON and a schema newer
/// than the app can read. Both leave the previous good state in place and
/// surface a plain message naming the file." A well-formed file of the wrong
/// shape is unreadable in the same way, naming where inside the file.
public enum DocumentFailure: Error, Equatable, Sendable {
    case malformedJSON(path: String, line: Int, column: Int, message: String)
    case notADocument(path: String, message: String)
    case schemaTooNew(path: String, found: Int, supported: Int)
    case schemaTooOld(path: String, found: Int, lowest: Int)
    case unreadable(path: String, message: String)

    public var path: String {
        switch self {
        case .malformedJSON(let path, _, _, _), .notADocument(let path, _), .schemaTooNew(let path, _, _),
             .schemaTooOld(let path, _, _), .unreadable(let path, _):
            return path
        }
    }

    /// The plain message, naming the file.
    public var message: String {
        switch self {
        case .malformedJSON(let path, let line, let column, let message):
            return "\(path) is not valid JSON (line \(line), column \(column): \(message))"
        case .notADocument(let path, let message):
            return "\(path) is not a document (\(message))"
        case .schemaTooNew(let path, let found, let supported):
            return "\(path) was written by a newer version (schema \(found); this app reads up to \(supported))"
        case .schemaTooOld(let path, let found, let lowest):
            return "\(path) is older than this app can read (schema \(found); the oldest readable is \(lowest))"
        case .unreadable(let path, let message):
            return "\(path) could not be read (\(message))"
        }
    }
}

/// Spec 1 §5 — the folder layout and the file-naming rule: "File names carry
/// the number and a slug of the label for human reading only; the loader
/// identifies a file by the `number` inside it and renames the file to match
/// on save."
public enum FileLayout {
    /// A lowercase ASCII slug of a label: letters and digits, runs of anything
    /// else become one hyphen, diacritics are stripped, at most 60 characters.
    public static func slug(_ label: String) -> String {
        var out = ""
        var pendingHyphen = false
        for scalar in label.decomposedStringWithCanonicalMapping.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 0x30 && value <= 0x39
            let isUpper = value >= 0x41 && value <= 0x5A
            let isLower = value >= 0x61 && value <= 0x7A
            if isDigit || isLower {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(scalar)
            } else if isUpper {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(Unicode.Scalar(value + 0x20) ?? scalar)
            } else if value < 0x300 || value > 0x36F {
                // Combining marks (U+0300–U+036F) vanish; anything else separates.
                pendingHyphen = true
            }
        }
        if out.count > 60 {
            out = String(out.prefix(60))
            while out.hasSuffix("-") { out.removeLast() }
        }
        return out
    }

    /// A three-digit number, wider when it needs to be: `003`, `042`, `1234`.
    public static func number(_ n: Int) -> String {
        let text = String(n)
        return text.count >= 3 ? text : String(repeating: "0", count: 3 - text.count) + text
    }

    static func numbered(_ n: Int, _ label: String) -> String {
        let s = slug(label)
        return s.isEmpty ? number(n) : number(n) + "-" + s
    }

    /// Spec 1 §5 — the canonical relative path of a document in its root.
    public static func path(for document: Document) -> String {
        switch document {
        case .preset(let p): return "presets/\(numbered(p.number, p.label)).json"
        case .macro(let m): return "macros/\(numbered(m.number, m.label)).json"
        case .list(let l): return (l.isLocalCopy ? "lists-local/" : "lists/") + numbered(l.number, l.title) + ".json"
        case .playlist(let p):
            let s = slug(p.title)
            if let date = p.serviceDate, !date.isEmpty {
                return "playlists/" + date + (s.isEmpty ? "" : "-" + s) + ".json"
            }
            return "playlists/" + (s.isEmpty ? p.uuid.uuidString.lowercased() : s) + ".json"
        default:
            return document.kind.fixedPath ?? document.kind.fileStem + ".json"
        }
    }

    /// Spec 1 §5 — `versions/042/v0017.json`.
    public static func versionPath(list number: Int, version: Int) -> String {
        let v = String(version)
        return "versions/\(self.number(number))/v" + (v.count >= 4 ? v : String(repeating: "0", count: 4 - v.count) + v) + ".json"
    }

    /// Spec 1 §5 — "The loader and the folder watcher ignore a sync tool's
    /// temporary and partial files (names beginning with a dot or ending in
    /// .tmp)".
    public static func isIgnored(path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.hasPrefix(".") || name.hasSuffix(".tmp")
    }

    /// The kind a path's place in a root implies, or nil for a path the
    /// layout does not know.
    public static func expectedKind(forPath path: String) -> DocumentKind? {
        for kind in DocumentKind.allCases where kind.fixedPath == path {
            return kind
        }
        guard path.hasSuffix(".json") else { return nil }
        if path.hasPrefix("presets/") { return .preset }
        if path.hasPrefix("macros/") { return .macro }
        if path.hasPrefix("lists/") || path.hasPrefix("lists-local/") || path.hasPrefix("versions/") { return .list }
        if path.hasPrefix("playlists/") { return .playlist }
        return nil
    }

    /// The key `documentPaths` uses for a per-object document.
    public static func documentKey(for document: Document) -> String? {
        switch document {
        case .preset(let p): return "preset/\(p.number)"
        case .macro(let m): return "macro/\(m.number)"
        case .list(let l): return (l.isLocalCopy ? "local/" : "list/") + l.uuid.uuidString.lowercased()
        case .playlist(let p): return "playlist/" + p.uuid.uuidString.lowercased()
        default: return nil
        }
    }
}
