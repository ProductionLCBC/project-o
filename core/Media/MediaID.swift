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

    /// Spec 1 §7 — "Designed slides and templates are JSON files in the media
    /// root with the extensions `.oslide` and `.otemplate`"; Spec 8 §2 — "A
    /// slide's id is its embedded uuid, so a slide is present when the file
    /// at its location parses and carries that uuid."
    public static func isSlideFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".oslide") || lower.hasSuffix(".otemplate")
    }

    /// Spec 8 §2 — the id a slide or template file carries: `slide:` and its
    /// `uuid`, or nil when the file doesn't parse or carries none.
    public static func slideIdentity(of data: Data) -> String? {
        guard let tree = try? JSONValue.parse(data), case .string(let text)? = tree["uuid"],
              let uuid = UUID(uuidString: text) else { return nil }
        return slide(uuid)
    }

    /// Spec 8 §2 — the identity of a media file's bytes: a slide's or
    /// template's embedded uuid, any other file's SHA-256.
    public static func identity(of data: Data, path: String) -> String? {
        isSlideFile(path) ? slideIdentity(of: data) : sha256(of: data)
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
