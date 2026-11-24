// OEngine — Spec 4 §10, the thumbnail cache key's "library version".

import Foundation
import OCore

/// Spec 4 §10 — thumbnails are "keyed by (cue uuid, stack, library version)",
/// and "a cue's library version is a content hash of the documents a render
/// depends on (presets, grades, text styles, transitions and channels, and
/// the thumbnail stack with the size it is drawn at), the list's own fields
/// other than its version number, and the list's cues from the first through
/// this one and as many after it as the thumbnail stack's boxes look ahead
/// (Spec 6 §3), with the resolved id, poster path and presence of each media
/// item those cues use (Spec 8 §9)". So "an edit to a cue redraws its
/// thumbnail and those of the cues after it, and the cues before it stay
/// cached" (corrected 2026-11-24); and "a re-export or a trim edit redraws
/// the thumbnails of the cues that use the item and of the cues after them,
/// and an import elsewhere redraws none" (Spec 8 §9). The list's own fields
/// include its title, author, copyright and ccli, which field boxes fall back
/// to (Spec 6 §3). The media a cue uses are the ids its writes name, the
/// macros it runs included.
public enum LibraryVersion {
    /// Each cue's version, in list order: sixteen hex characters of FNV-1a
    /// over the canonical JSON of the rendering documents, the list's own
    /// fields, and the cues through this one and `lookAhead` more, each with
    /// its media's state; stable across runs. Spec 8 §5 — each video's poster
    /// notes whether its file was found (`posters`), so "a change under
    /// `.posters/` ... redraws the tiles and thumbnails that went without it".
    public static func versions(library: Library, machine: Machine?, list: List, missing: Set<String>,
                                posters: Set<MediaLocation> = [], lookAhead: Int = 0) -> [String] {
        let states = prefixes(library: library, machine: machine, list: list, missing: missing, posters: posters).cues
        guard let final = states.last else { return [] }
        let ahead = max(0, lookAhead)
        return states.indices.map { index in
            let through = index + ahead
            return text(through < states.count ? states[through] : final)
        }
    }

    /// The version of a list as a whole: its last cue's, which every cue of it
    /// is in; an empty list's is that of its documents and fields alone.
    public static func hash(library: Library, machine: Machine?, list: List, missing: Set<String>, posters: Set<MediaLocation> = []) -> String {
        let found = prefixes(library: library, machine: machine, list: list, missing: missing, posters: posters)
        return text(found.cues.last ?? found.head)
    }

    /// The hash after the documents and the list's fields (`head`), and after
    /// each cue in turn (`cues`): a cue's version is the hash after the cue
    /// its thumbnail reads furthest.
    private static func prefixes(library: Library, machine: Machine?, list: List, missing: Set<String>,
                                 posters: Set<MediaLocation>) -> (head: UInt64, cues: [UInt64]) {
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
        // Spec 5 §2 and Spec 11 §6 — the stack a thumbnail is drawn on is edited too: its slots and their presets,
        // its base, and the shape it is drawn at (Spec 4 §5).
        if let machine, let stack = machine.stack(machine.settings.thumbnailStack) {
            feed(stack)
            let size = MachineGeometry(library: library, machine: machine).stackSize(stack.number)
            feed(Data("\(size.width)x\(size.height)".utf8))
        }
        // "the list's own fields other than its version number": its title, author, copyright and ccli for field
        // boxes (Spec 6 §3), `trackThrough` for the fold (Spec 3 §7), and the rest as they stand.
        var fields = list
        fields.version = 0
        fields.cues = []
        feed(fields)
        let head = hash
        var cues: [UInt64] = []
        cues.reserveCapacity(list.cues.count)
        for cue in list.cues {
            feed(cue)
            feed(media(of: cue.commands, library: library, machine: machine).sorted().map { ref -> MediaState in
                let chain = MediaResolver.chain(from: ref, library: library.mediaIndex, machine: machine?.mediaLocal)
                let found = MediaResolver.entry(for: chain.reached, library: library.mediaIndex, machine: machine?.mediaLocal)
                let entry = found?.entry
                let poster = found.flatMap { f in f.entry.poster.flatMap { MediaLocation(MediaPosters.folder(of: f.tier), $0) } }
                return MediaState(ref: ref, id: chain.reached, poster: entry?.poster,
                                  present: entry != nil && entry?.isDeleted == false && !missing.contains(chain.reached),
                                  posterFound: poster.map(posters.contains) ?? false)
            })
            cues.append(hash)
        }
        return (head, cues)
    }

    private static func text(_ hash: UInt64) -> String { String(format: "%016llx", hash) }

    /// The media ids a list's cues name in their writes, and in the writes of
    /// the macros they run, to the depth macros nest (Spec 2 §5).
    static func media(of list: List, library: Library, machine: Machine?) -> Set<String> {
        list.cues.reduce(into: Set<String>()) { $0.formUnion(media(of: $1.commands, library: library, machine: machine)) }
    }

    /// The media ids one cue's commands name, its macros' included.
    static func media(of commands: [GuardedCommand], library: Library, machine: Machine?) -> Set<String> {
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
        visit(commands, depth: 0)
        return refs
    }

    private struct MediaState: Encodable {
        var ref: String
        var id: String
        var poster: String?
        var present: Bool
        var posterFound: Bool
    }
}
