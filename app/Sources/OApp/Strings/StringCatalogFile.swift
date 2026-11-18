// OApp — Spec 10 §15, the string catalog read as a file.

import Foundation

/// Spec 10 §15 — the string catalog, `app/Shell/Localizable.xcstrings`, read
/// as the JSON it is. The app itself reads the catalog Xcode compiled into
/// its bundle; under `swift test` there is no such bundle, so the tests read
/// the file, which also lets them check it against the keys the code uses.
public struct StringCatalogFile: Sendable {
    public struct Entry: Equatable, Sendable {
        /// The note for a translator.
        public var comment: String
        /// The English, or for a count its `other` form.
        public var value: String
        /// The English for a count of one, where the key has plural variants.
        public var one: String?

        public var isPlural: Bool { one != nil }
    }

    public var entries: [String: Entry]

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let strings = root["strings"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var entries: [String: Entry] = [:]
        for (key, value) in strings {
            guard let fields = value as? [String: Any], let localizations = fields["localizations"] as? [String: Any],
                  let english = localizations["en"] as? [String: Any] else { continue }
            let comment = fields["comment"] as? String ?? ""
            func text(_ holder: Any?) -> String? {
                ((holder as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            if let plain = text(english) {
                entries[key] = Entry(comment: comment, value: plain, one: nil)
            } else if let plural = (english["variations"] as? [String: Any])?["plural"] as? [String: Any], let other = text(plural["other"]) {
                entries[key] = Entry(comment: comment, value: other, one: text(plural["one"]))
            }
        }
        self.entries = entries
    }

    /// The format for `key`, the count choosing English's plural form, as
    /// `Strings.lookup` wants it.
    public func format(_ key: String, count: Int?) -> String? {
        guard let entry = entries[key] else { return nil }
        if count == 1, let one = entry.one { return one }
        return entry.value
    }
}
