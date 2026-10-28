// OCore — Spec 1 §5 and §8, the bridge between the value tree and Codable.
//
// Every format type describes its JSON once through `Codable`. Foundation's
// JSONEncoder and JSONDecoder run that description (the one use of Foundation
// beyond UUID that ADR 0005 allows: "Codable ... at the file boundary"); the
// tree and the canonical printer own the bytes, so the platform's own JSON
// formatting never reaches disk.

import Foundation

/// Spec 1 §5 — Codable values to and from the value tree.
public enum JSONCoding {
    /// Encode a value to a tree. The tree is what the canonical printer writes.
    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder()
        return try JSONValue.parse(try encoder.encode(value))
    }

    /// Decode a value from a tree.
    public static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try JSONDecoder().decode(type, from: JSONCanonical.data(value))
    }

    /// A readable description of a decoding error: the key path and the reason.
    public static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "" : keys.joined(separator: ".") + ": "
        }
        switch decoding {
        case .keyNotFound(let key, let context): return path(context) + "missing \(key.stringValue)"
        case .typeMismatch(_, let context): return path(context) + context.debugDescription
        case .valueNotFound(_, let context): return path(context) + context.debugDescription
        case .dataCorrupted(let context): return path(context) + context.debugDescription
        @unknown default: return "\(error)"
        }
    }
}

/// A coding key for any name, used for unknown keys and dynamic maps.
public struct AnyKey: CodingKey, Hashable, Sendable {
    public var stringValue: String
    public var intValue: Int? { nil }

    public init(_ string: String) { stringValue = string }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

extension Decoder {
    /// Spec 1 §8 — "every object keeps an opaque bag of keys it did not
    /// recognise": the members of this object whose keys are not `known`.
    func unknownKeys(besides known: Set<String>) throws -> [String: JSONValue] {
        let container = try container(keyedBy: AnyKey.self)
        var out: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return out
    }
}

extension Encoder {
    /// Spec 1 §8 — write the unknown keys back "unchanged". Called before the
    /// known keys, so a known key always wins a collision.
    func encode(unknownKeys: [String: JSONValue]) throws {
        guard !unknownKeys.isEmpty else { return }
        var container = container(keyedBy: AnyKey.self)
        for (key, value) in unknownKeys {
            try container.encode(value, forKey: AnyKey(key))
        }
    }
}

extension CodingKey where Self: CaseIterable {
    /// The set of key names a type knows, for the unknown-key bag.
    static var known: Set<String> { Set(allCases.map(\.stringValue)) }
}

extension KeyedDecodingContainer {
    /// Spec 1 §2 — fields with a documented default: absent or null reads as the default.
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }

    /// A lowercase or uppercase UUID string.
    func uuid(_ key: Key) throws -> UUID {
        let text = try decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a UUID: \(text)")
        }
        return uuid
    }

    func uuidIfPresent(_ key: Key) throws -> UUID? {
        guard let text = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a UUID: \(text)")
        }
        return uuid
    }
}

extension KeyedEncodingContainer {
    /// Spec 1 §5 — nullable fields are written as `null`, never omitted, so
    /// a document always shows its whole shape.
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }

    /// Spec 1 §9 — UUIDs are written lowercase.
    mutating func encode(uuid: UUID, forKey key: Key) throws {
        try encode(uuid.uuidString.lowercased(), forKey: key)
    }

    mutating func encodeNullable(uuid: UUID?, forKey key: Key) throws {
        try encodeNullable(uuid?.uuidString.lowercased(), forKey: key)
    }
}

extension JSONValue {
    // MARK: - Tree accessors

    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, index >= 0, index < items.count { return items[index] }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let members) = self { return members }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// The number as an integer, when it is one.
    public var intValue: Int? {
        guard case .number(let n) = self, n == n.rounded(), abs(n) < 9_007_199_254_740_992 else { return nil }
        return Int(n)
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// This object with one member set; anything else is returned unchanged.
    public func setting(_ key: String, to value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }

    /// This object without one member; anything else is returned unchanged.
    public func removing(_ key: String) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = nil
        return .object(members)
    }
}
