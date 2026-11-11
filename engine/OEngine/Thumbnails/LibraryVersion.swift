// OEngine — Spec 4 §10, the thumbnail cache key's "library version".

import Foundation
import OCore

/// Spec 4 §10 — thumbnails are "keyed by (cue uuid, stack, library version)".
/// Spec 1 has no library-wide version, only a `version` per List "incremented
/// on every save", so the library version is a content hash of "the documents
/// a render depends on (presets, grades, text styles, transitions and
/// channels), the resolved id, poster path and presence of each media item
/// the list's cues use (Spec 8 §9), and the list's own version", and the
/// list's title, author, copyright and ccli, which field boxes fall back to
/// (Spec 6 §3). So "a re-export or a trim edit redraws the lists that use the
/// item, and an import elsewhere redraws none" (Spec 8 §9). The media a
/// list's cues use are the ids its writes name, the macros they run
/// included.
public enum LibraryVersion {
    /// Sixteen hex characters of FNV-1a over the canonical JSON of the
    /// rendering documents, the list's media and the list's version; stable
    /// across runs.
    public static func hash(library: Library, machine: Machine?, list: List, missing: Set<String>) -> String {
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
        feed(media(of: list, library: library, machine: machine).sorted().map { ref -> MediaState in
            let chain = MediaResolver.chain(from: ref, library: library.mediaIndex, machine: machine?.mediaLocal)
            let entry = MediaResolver.entry(for: chain.reached, library: library.mediaIndex, machine: machine?.mediaLocal)?.entry
            return MediaState(ref: ref, id: chain.reached, poster: entry?.poster,
                              present: entry != nil && entry?.isDeleted == false && !missing.contains(chain.reached))
        })
        feed(ListVersion(uuid: list.uuid.uuidString.lowercased(), version: list.version))
        // Spec 6 §3 — a field box with no such field in the write draws the list's title, author,
        // copyright or ccli, so they are part of what a thumbnail is made of, version or not.
        feed(ListMetadata(title: list.title, author: list.author, copyright: list.copyright, ccli: list.ccli))
        return String(format: "%016llx", hash)
    }

    /// The media ids a list's cues name in their writes, and in the writes of
    /// the macros they run, to the depth macros nest (Spec 2 §5).
    static func media(of list: List, library: Library, machine: Machine?) -> Set<String> {
        var refs: Set<String> = []
        var seen: Set<Int> = []
        func visit(_ commands: [GuardedCommand], depth: Int) {
            for entry in commands {
                if let ref = entry.command.mediaRef { refs.insert(ref) }
                if case .macro(let number) = entry.command, depth < 8, seen.insert(number).inserted,
                   let macro = machine.flatMap({ MacroCalls.macro(number, library: library, machine: $0) }) ?? library.macro(number) {
                    visit(macro.commands, depth: depth + 1)
                }
            }
        }
        for cue in list.cues { visit(cue.commands, depth: 0) }
        return refs
    }

    private struct MediaState: Encodable {
        var ref: String
        var id: String
        var poster: String?
        var present: Bool
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
