// OCore — Spec 8 §2, resolving an id and its presence; Spec 1 §7, lookup order.

import Foundation

/// Spec 1 §7 — the two index tiers: "a library index (`library/media-index.json`
/// ...) for media that belongs to the library, and a machine index
/// (`machine/media-local.json`)".
public enum MediaTier: String, Codable, Equatable, Hashable, Sendable {
    case machine, library
}

/// Spec 8 §2 — "Resolving an id. An id first follows the `replaced` maps, the
/// machine index's and then the library's, whether or not an index still
/// holds an entry for it, until it reaches an id neither maps. A chain that
/// comes back to an id it has passed stops at the id before the repeat, and
/// the reference report names the loop".
public struct MediaChain: Equatable, Sendable {
    /// Every id the chain passed: the one asked for first, the one it reached last.
    public var ids: [String]
    /// When the chain came back to an id it had passed: the ids of the loop,
    /// in the order the chain met them.
    public var loop: [String]?

    public init(ids: [String], loop: [String]? = nil) {
        self.ids = ids
        self.loop = loop
    }

    /// Spec 8 §2 — "the last id", whose entry gives the location.
    public var reached: String { ids.last ?? "" }
}

/// Spec 8 §2 — what resolving an id found: the chain it followed, "the entry
/// for the last id", the tier holding it, and the location that entry gives.
public struct MediaResolution: Equatable, Sendable {
    public var chain: MediaChain
    public var entry: MediaEntry
    public var tier: MediaTier
    /// Nil when the entry has no path (another file took its place, or it was
    /// deleted, Spec 8 §4 and §6) or its path would leave its folder.
    public var location: MediaLocation?
    /// Spec 1 §7 — whether an override gave the location.
    public var overridden: Bool

    public init(chain: MediaChain, entry: MediaEntry, tier: MediaTier, location: MediaLocation?, overridden: Bool) {
        self.chain = chain
        self.entry = entry
        self.tier = tier
        self.location = location
        self.overridden = overridden
    }

    /// The id resolved to, the end of the chain.
    public var id: String { entry.id }
}

/// Spec 8 §2 — what this machine knows of the file at a location: "The hash
/// is known from this machine's cache record for that location when the
/// file's size and modification date match it, otherwise from the entry's own
/// size and date when they match, otherwise by hashing the file."
public enum MediaFileState: Equatable, Sendable {
    /// No file is there.
    case absent
    /// A file is there and its bytes aren't known yet. Until the walk hashes
    /// it, it counts present (Adam's answer of 2026-11-11, as Spec 9 §4 counts
    /// media for a restore).
    case unhashed
    /// A file is there holding these bytes: its `sha256:` id, or for a slide
    /// the `slide:` id of the uuid it carries.
    case holds(String)
}

/// Spec 8 §2 — "Present or missing", in Spec 10 §3's words: an item's
/// presence is `ok`, `missing` or `deleted`.
public enum MediaPresence: String, Codable, Equatable, Sendable {
    case ok, missing, deleted
}

/// Spec 1 §7 — the resolver, and Spec 8 §2 — where a file is and whether it is
/// there. Missing state is computed, never stored.
public enum MediaResolver {
    /// Spec 8 §2 — the chain from `id` through the `replaced` maps: at each
    /// step the machine index's map, then the library's, "whether or not an
    /// index still holds an entry for it, until it reaches an id neither
    /// maps"; a repeat stops it "at the id before the repeat".
    public static func chain(from id: String, library: MediaIndex, machine: MediaLocalIndex?) -> MediaChain {
        var ids = [id]
        var seen: Set<String> = [id]
        var current = id
        while let next = machine?.replaced[current] ?? library.replaced[current] {
            if seen.contains(next) {
                let start = ids.firstIndex(of: next) ?? 0
                return MediaChain(ids: ids, loop: Array(ids[start...]))
            }
            ids.append(next)
            seen.insert(next)
            current = next
        }
        return MediaChain(ids: ids)
    }

    /// Spec 1 §7 — "Resolve an id in the machine index first, then the
    /// library index": the entry for `id` itself, without following any map.
    public static func entry(for id: String, library: MediaIndex, machine: MediaLocalIndex?) -> (entry: MediaEntry, tier: MediaTier)? {
        if let entry = machine?.entry(id) { return (entry, .machine) }
        if let entry = library.entry(id) { return (entry, .library) }
        return nil
    }

    /// Spec 8 §2 — the location an entry gives: "a library entry's `path` is
    /// relative to the media root; a machine-index entry's `path` is relative
    /// to `machine/media/`; an override ... is a path relative to
    /// `machine/media/`, or an absolute one, and wins over its entry's `path`."
    public static func location(of entry: MediaEntry, tier: MediaTier, overrides: [String: String]) -> (location: MediaLocation?, overridden: Bool) {
        if let override = overrides[entry.id] { return (MediaLocation.override(override), true) }
        guard !entry.path.isEmpty else { return (nil, false) }
        return (MediaLocation(tier == .machine ? .machineMedia : .mediaRoot, entry.path), false)
    }

    /// Spec 8 §2 — "Resolving an id": follow the chain, then "The entry for
    /// the last id gives the location". Nil when neither index holds an
    /// entry for the id the chain reaches.
    public static func resolve(_ id: String, library: MediaIndex, machine: MediaLocalIndex?) -> MediaResolution? {
        let chain = chain(from: id, library: library, machine: machine)
        guard let (entry, tier) = entry(for: chain.reached, library: library, machine: machine) else { return nil }
        let (location, overridden) = location(of: entry, tier: tier, overrides: machine?.overrides ?? [:])
        return MediaResolution(chain: chain, entry: entry, tier: tier, location: location, overridden: overridden)
    }

    /// Spec 8 §2 — `resolve` over a library and a machine's indexes.
    public static func resolve(_ id: String, library: Library, machine: Machine?) -> MediaResolution? {
        resolve(id, library: library.mediaIndex, machine: machine?.mediaLocal)
    }

    /// Spec 8 §2 — "An entry is present when the hash known for its location
    /// equals its id, and it isn't deleted (§6)." A slide's id is its embedded
    /// uuid, so a slide is present when the file at its location carries it.
    public static func presence(of entry: MediaEntry, at location: MediaLocation?, state: MediaFileState) -> MediaPresence {
        if entry.isDeleted { return .deleted }
        guard location != nil else { return .missing }
        switch state {
        case .absent: return .missing
        case .unhashed: return .ok
        case .holds(let id): return id == entry.id ? .ok : .missing
        }
    }

    /// Spec 8 §2 — the presence of what an id resolves to; an id that
    /// resolves to no entry is missing.
    public static func presence(_ resolution: MediaResolution?, state: (MediaLocation) -> MediaFileState) -> MediaPresence {
        guard let resolution else { return .missing }
        return presence(of: resolution.entry, at: resolution.location, state: resolution.location.map(state) ?? .absent)
    }

    /// Every id the two indexes name: their entries' ids, and the ids their
    /// `replaced` maps lead from and to.
    public static func knownIds(library: MediaIndex, machine: MediaLocalIndex?) -> Set<String> {
        var ids = Set(library.entries.map(\.id))
        ids.formUnion(library.replaced.keys)
        ids.formUnion(library.replaced.values)
        if let machine {
            ids.formUnion(machine.entries.map(\.id))
            ids.formUnion(machine.replaced.keys)
            ids.formUnion(machine.replaced.values)
        }
        return ids
    }

    /// Spec 8 §9 — "Missing state is worked out per location", the set a
    /// caller passes the projection (Spec 3 §6, `missing`): every id the
    /// indexes name whose resolution isn't present, deleted items included.
    public static func missingIds(library: Library, machine: Machine?, state: (MediaLocation) -> MediaFileState) -> Set<String> {
        var missing: Set<String> = []
        for id in knownIds(library: library.mediaIndex, machine: machine?.mediaLocal) {
            let resolution = resolve(id, library: library, machine: machine)
            if presence(resolution, state: state) != .ok { missing.insert(id) }
        }
        return missing
    }
}
