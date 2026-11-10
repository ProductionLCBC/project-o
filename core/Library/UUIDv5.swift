// OCore — Spec 7 §3, name-based uuids.

import Foundation

extension UUID {
    /// Spec 7 §3 — "a UUIDv5 with the playlist's uuid as its namespace and,
    /// as its name, the UTF-8 text `KIND:KEY:N`". RFC 9562 §5.5: the SHA-1 of
    /// the namespace's sixteen bytes followed by the name, its first sixteen
    /// bytes with the version set to 5 and the variant to the RFC's.
    public static func v5(namespace: UUID, name: String) -> UUID {
        var hasher = SHA1()
        let space = namespace.uuid
        hasher.update([space.0, space.1, space.2, space.3, space.4, space.5, space.6, space.7,
                       space.8, space.9, space.10, space.11, space.12, space.13, space.14, space.15])
        hasher.update(Array(name.utf8))
        var b = hasher.finalize()
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
