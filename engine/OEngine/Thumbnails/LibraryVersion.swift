// OEngine — Spec 4 §10, the thumbnail cache key's "library version".

import Foundation
import OCore

/// Spec 4 §10 — thumbnails are "keyed by (cue uuid, stack, library version)".
/// Spec 1 has no library-wide version, only a `version` per List "incremented
/// on every save", so the library version is a content hash of the documents
/// a render depends on: presets, grades, text styles, transitions, channels
/// and the media index's poster paths, plus the list's own version (Area 5
/// reading, approved 2026-11-03), and the list's title, author, copyright and
/// ccli, which field boxes fall back to (Spec 6 §3). The UX spec wants thumbnails "invalidated
/// when the cue, a preset or a grade changes", and these are the documents a
/// cue's picture is made of.
public enum LibraryVersion {
    /// Sixteen hex characters of FNV-1a over the canonical JSON of the
    /// rendering documents and the list's version; stable across runs.
    public static func hash(library: Library, list: List) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hash: UInt64 = 0xcbf29ce484222325
        func feed(_ data: Data) {
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
        }
        func feed<T: Encodable>(_ value: T) {
            feed((try? encoder.encode(value)) ?? Data())
            feed(Data([0x1F]))
        }
        feed(library.presets)
        feed(library.grades)
        feed(library.textStyles)
        feed(library.transitions)
        feed(library.channels)
        feed(library.mediaIndex.entries.map { PosterPath(id: $0.id, poster: $0.poster) }.sorted { $0.id < $1.id })
        feed(ListVersion(uuid: list.uuid.uuidString.lowercased(), version: list.version))
        // Spec 6 §3 — a field box with no such field in the write draws the list's title, author,
        // copyright or ccli, so they are part of what a thumbnail is made of, version or not.
        feed(ListMetadata(title: list.title, author: list.author, copyright: list.copyright, ccli: list.ccli))
        return String(format: "%016llx", hash)
    }

    private struct PosterPath: Encodable {
        var id: String
        var poster: String?
    }

    private struct ListVersion: Encodable {
        var uuid: String
        var version: Int
    }

    private struct ListMetadata: Encodable {
        var title: String
        var author: String
        var copyright: String
        var ccli: String
    }
}
