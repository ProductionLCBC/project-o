// OCore — JSON helpers for integer-keyed maps.

/// Spec 1 §5 — JSON on disk has string keys. Swift encodes `[Int: V]` as a
/// flat array, so ShowState maps are written through this helper as objects
/// keyed by the number's decimal text, which also keeps keys sortable.
enum IntKeyedCoding {
    static func stringKeyed<V>(_ map: [Int: V]) -> [String: V] {
        var out: [String: V] = [:]
        out.reserveCapacity(map.count)
        for (k, v) in map { out[String(k)] = v }
        return out
    }

    static func intKeyed<V>(_ map: [String: V], at path: [CodingKey]) throws -> [Int: V] {
        var out: [Int: V] = [:]
        out.reserveCapacity(map.count)
        for (k, v) in map {
            guard let n = Int(k) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: path, debugDescription: "key \(k) is not an integer"))
            }
            out[n] = v
        }
        return out
    }
}
