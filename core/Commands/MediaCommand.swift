// OCore — Spec 8 §2, the media commands (a Spec 2 §3 addition).

import Foundation

/// Spec 8 §6 — one reference `media replace` rewrote: "The logged command
/// lists the references it rewrote, each named as Spec 5 §3 addresses it".
/// `object` is the kind of thing holding the reference (`cue`, `macro`,
/// `keys`), `address` its address as Spec 5 §4's object form carries it
/// (`list` and `cue` for a cue; `macro` for a macro; `device` and `key` for a
/// key binding; `at`, its position, for a scheduler entry, which has no
/// identity of its own, Spec 5 §3), and `path` the dotted path to the ref
/// inside it (`commands.2.content.ref`). Encoded flat: `object`, the address
/// keys and `path`.
public struct MediaReference: Codable, Equatable, Sendable {
    public var object: String
    public var address: [String: JSONValue]
    public var path: String

    public init(object: String, address: [String: JSONValue], path: String) {
        self.object = object
        self.address = address
        self.path = path
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        object = try c.decode(String.self, forKey: Key("object"))
        path = try c.decode(String.self, forKey: Key("path"))
        address = try decoder.unknownKeys(besides: ["object", "path"])
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: address)
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(object, forKey: Key("object"))
        try c.encode(path, forKey: Key("path"))
    }
}

/// Spec 8 §6 — one mapping in a `replaced` map: `from` → `to` in the index
/// that holds it.
public struct MediaMapping: Codable, Equatable, Hashable, Sendable {
    public var index: MediaTier
    public var from: String
    public var to: String

    public init(index: MediaTier, from: String, to: String) {
        self.index = index
        self.from = from
        self.to = to
    }
}

/// Spec 8 §6 — "the mappings it removed or added".
public struct MediaMappingChanges: Codable, Equatable, Sendable {
    public var removed: [MediaMapping]
    public var added: [MediaMapping]

    public init(removed: [MediaMapping] = [], added: [MediaMapping] = []) {
        self.removed = removed
        self.added = added
    }

    private enum CodingKeys: String, CodingKey { case removed, added }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        removed = try c.decodeIfPresent([MediaMapping].self, forKey: .removed) ?? []
        added = try c.decodeIfPresent([MediaMapping].self, forKey: .added) ?? []
    }
}

/// Spec 8 §6 — what a `media replace` did, which its logged form records and
/// its inverse, `media unreplace`, puts back: "the references it rewrote ...,
/// the mappings it removed or added, and NEW's defaults before the command".
/// `defaults` is null when NEW kept its own (choice M-3).
public struct MediaReplaceRecord: Equatable, Sendable {
    public var refs: [MediaReference]
    public var mapping: MediaMappingChanges
    public var defaults: MediaDefaults?

    public init(refs: [MediaReference] = [], mapping: MediaMappingChanges = MediaMappingChanges(), defaults: MediaDefaults? = nil) {
        self.refs = refs
        self.mapping = mapping
        self.defaults = defaults
    }

    /// The keys of the object form it fills.
    public static let keys = ["refs", "mapping", "defaults"]
}

/// Spec 8 §6 — one file a `media delete` moved: "the command is logged with
/// where each file came from and where the Trash put it". Encoded flat:
/// `folder`, `path` and `trash`.
public struct MediaTrashedFile: Codable, Equatable, Hashable, Sendable {
    public var location: MediaLocation
    /// The absolute path the Trash gave the file.
    public var trash: String

    public init(location: MediaLocation, trash: String) {
        self.location = location
        self.trash = trash
    }

    private enum CodingKeys: String, CodingKey { case folder, path, trash }

    public init(from decoder: Decoder) throws {
        location = try MediaLocation(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trash = try c.decode(String.self, forKey: .trash)
    }

    public func encode(to encoder: Encoder) throws {
        try location.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trash, forKey: .trash)
    }
}

/// Spec 8 §2 — the media commands, as Spec 2 §3 lists them:
///
/// | Text | Object |
/// | --- | --- |
/// | `media import "PATH"` | `media.import` `{path}` |
/// | `media rebuild` | `media.rebuild` |
/// | `media replace HASH HASH` | `media.replace` `{old, new}` |
/// | `media delete HASH` | `media.delete` `{id}` |
/// | `media undelete HASH {…}` | `media.undelete` `{id, files}` |
/// | `media unreplace HASH HASH {…}` | `media.unreplace` `{old, new, refs, mapping, defaults}` |
///
/// "The two inverses carry their recorded details as a JSON body, as Spec 5's
/// edit forms do". As logged, `media replace` and `media delete` carry what
/// they did the same way (Spec 8 §6), so the text form prints it as one JSON
/// object at the end, as an edit's picks print (Spec 5 §4), and
/// `parse(print(x)) == x` holds for the logged form too.
public enum MediaCommand: Equatable, Sendable {
    case importFile(path: String)
    case rebuild
    case replace(old: String, new: String, record: MediaReplaceRecord?)
    case delete(id: String, files: [MediaTrashedFile]?)
    case undelete(id: String, files: [MediaTrashedFile])
    case unreplace(old: String, new: String, record: MediaReplaceRecord)

    /// Spec 2 §3 — every `cmd` of the family.
    public static let commandNames: Set<String> = [
        "media.import", "media.rebuild", "media.replace", "media.delete", "media.undelete", "media.unreplace",
    ]

    /// Spec 2 §4 — `cmd` is `target.verb`.
    public var cmd: String {
        switch self {
        case .importFile: return "media.import"
        case .rebuild: return "media.rebuild"
        case .replace: return "media.replace"
        case .delete: return "media.delete"
        case .undelete: return "media.undelete"
        case .unreplace: return "media.unreplace"
        }
    }

    /// Spec 8 §2 — "`media replace`, `media delete` and their inverses are
    /// ordinary edits, undone and redone through Spec 5 §8"; import and
    /// rebuild are logged and not undoable.
    public var isEdit: Bool {
        switch self {
        case .importFile, .rebuild: return false
        case .replace, .delete, .undelete, .unreplace: return true
        }
    }

    /// The media ids the command names, in the order it names them.
    public var ids: [String] {
        switch self {
        case .importFile, .rebuild: return []
        case .replace(let old, let new, _), .unreplace(let old, let new, _): return [old, new]
        case .delete(let id, _), .undelete(let id, _): return [id]
        }
    }

    // MARK: - The object form (Spec 2 §4)

    /// Spec 2 §4 — the command from its object form's parameters; a
    /// `DecodingError` when they don't fit.
    public init(cmd: String, fields: [String: JSONValue]) throws {
        func string(_ key: String) throws -> String {
            guard case .string(let s)? = fields[key] else { throw MediaCommand.bad(cmd, "\(key) must be a string") }
            return s
        }
        func decoded<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
            guard let value = fields[key], value != .null else { return nil }
            return try JSONCoding.decode(type, from: value)
        }
        func record() throws -> MediaReplaceRecord? {
            guard MediaReplaceRecord.keys.contains(where: { fields[$0] != nil }) else { return nil }
            return MediaReplaceRecord(refs: try decoded([MediaReference].self, "refs") ?? [],
                                      mapping: try decoded(MediaMappingChanges.self, "mapping") ?? MediaMappingChanges(),
                                      defaults: try decoded(MediaDefaults.self, "defaults"))
        }
        switch cmd {
        case "media.import": self = .importFile(path: try string("path"))
        case "media.rebuild": self = .rebuild
        case "media.replace": self = .replace(old: try string("old"), new: try string("new"), record: try record())
        case "media.delete": self = .delete(id: try string("id"), files: try decoded([MediaTrashedFile].self, "files"))
        case "media.undelete":
            guard let files = try decoded([MediaTrashedFile].self, "files") else { throw MediaCommand.bad(cmd, "files is missing") }
            self = .undelete(id: try string("id"), files: files)
        case "media.unreplace":
            self = .unreplace(old: try string("old"), new: try string("new"), record: try record() ?? MediaReplaceRecord())
        default:
            throw MediaCommand.bad(cmd, "not a media command")
        }
    }

    static func bad(_ cmd: String, _ message: String) -> DecodingError {
        DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "\(cmd): \(message)"))
    }

    /// Spec 2 §4 — the object form's parameters, everything but `cmd`.
    public var fields: [String: JSONValue] {
        func encoded<T: Encodable>(_ value: T) -> JSONValue { (try? JSONCoding.encode(value)) ?? .null }
        func record(_ r: MediaReplaceRecord, into fields: inout [String: JSONValue]) {
            fields["refs"] = encoded(r.refs)
            fields["mapping"] = encoded(r.mapping)
            fields["defaults"] = r.defaults.map(encoded) ?? .null
        }
        var out: [String: JSONValue] = [:]
        switch self {
        case .importFile(let path): out["path"] = .string(path)
        case .rebuild: break
        case .replace(let old, let new, let r):
            out["old"] = .string(old)
            out["new"] = .string(new)
            if let r { record(r, into: &out) }
        case .unreplace(let old, let new, let r):
            out["old"] = .string(old)
            out["new"] = .string(new)
            record(r, into: &out)
        case .delete(let id, let files):
            out["id"] = .string(id)
            if let files { out["files"] = encoded(files) }
        case .undelete(let id, let files):
            out["id"] = .string(id)
            out["files"] = encoded(files)
        }
        return out
    }
}
