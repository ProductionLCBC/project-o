// OCore — Spec 1 §4, media identity.

import Foundation

/// Spec 1 §4 — "A media file's identity is the SHA-256 of its bytes, written
/// as `sha256:` followed by 64 lowercase hex characters... Authored documents
/// (designed slides and templates) ... each carries an embedded `uuid` in its
/// JSON and is referenced as `slide:` followed by the UUID."
public enum MediaID {
    public static let hashPrefix = "sha256:"
    public static let slidePrefix = "slide:"

    /// The id of a file's bytes.
    public static func sha256(of data: Data) -> String {
        hashPrefix + SHA256.hex(SHA256.digest(data))
    }

    /// The id of an authored document, lowercase.
    public static func slide(_ uuid: UUID) -> String {
        slidePrefix + uuid.uuidString.lowercased()
    }

    public static func isSlide(_ id: String) -> Bool {
        id.hasPrefix(slidePrefix)
    }

    /// True for the two forms §4 defines, exactly.
    public static func isValid(_ id: String) -> Bool {
        if id.hasPrefix(hashPrefix) {
            let hex = id.dropFirst(hashPrefix.count)
            return hex.count == 64 && hex.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") }
        }
        if id.hasPrefix(slidePrefix) {
            let text = String(id.dropFirst(slidePrefix.count))
            return UUID(uuidString: text) != nil && text == text.lowercased()
        }
        return false
    }
}
