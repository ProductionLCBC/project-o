// OCore — Spec 8 §2 and §4, presence before the launch walk and the launch walk's pruning.

import Foundation

/// What a look at a location found, before anything is read: the file's size
/// and modification date, or nothing there.
public struct MediaFileStat: Equatable, Sendable {
    public var size: Int
    public var modified: String

    public init(size: Int, modified: String) {
        self.size = size
        self.modified = modified
    }
}

/// Spec 8 §2 and §4 — the launch, before the walk has read anything.
public enum MediaLaunch {
    /// Every location the two indexes name: each entry's (an override's
    /// target in its place), with the entries that name it.
    public static func locations(library: MediaIndex, machine: MediaLocalIndex) -> [MediaLocation: [MediaEntry]] {
        var out: [MediaLocation: [MediaEntry]] = [:]
        func add(_ entry: MediaEntry, _ tier: MediaTier) {
            guard let location = MediaResolver.location(of: entry, tier: tier, overrides: machine.overrides).location else { return }
            out[location, default: []].append(entry)
        }
        for entry in library.entries where !entry.isDeleted { add(entry, .library) }
        for entry in machine.entries where !entry.isDeleted { add(entry, .machine) }
        return out
    }

    /// Spec 8 §2 — "The hash is known from this machine's cache record for
    /// that location when the file's size and modification date match it,
    /// otherwise from the entry's own size and date when they match,
    /// otherwise by hashing the file (§4)." Before the walk has hashed a file,
    /// it counts present (Adam's answer of 2026-11-11, as Spec 9 §4 counts
    /// media for a restore): a matching cache record names its hash, an entry
    /// whose own size and date match names its id, and anything else is
    /// `unhashed`. Nothing there is `absent`.
    public static func states(library: MediaIndex, machine: MediaLocalIndex, stat: (MediaLocation) -> MediaFileStat?,
                              cache: MediaCache) -> [MediaLocation: MediaFileState] {
        var states: [MediaLocation: MediaFileState] = [:]
        for (location, entries) in locations(library: library, machine: machine) {
            guard let file = stat(location) else {
                states[location] = .absent
                continue
            }
            if let hash = cache.hash(at: location, size: file.size, modified: file.modified) {
                states[location] = .holds(hash)
            } else if let entry = entries.first(where: { $0.size == file.size && $0.modified == file.modified }) {
                states[location] = .holds(entry.id)
            } else {
                states[location] = .unhashed
            }
        }
        return states
    }

    /// Spec 8 §4 — "Only the launch walk prunes, before anything can be
    /// undone: replaced entries whose file is gone and that nothing on this
    /// machine names, with their posters. Their mappings stay, so anything
    /// still naming them resolves." A replaced entry is one a `replaced` map
    /// leads from; its file is gone when it has no path or nothing is at its
    /// location. Only the indexes this machine writes are pruned. Returns the
    /// indexes, what was pruned, and the posters of the pruned entries, for
    /// the worker to remove.
    public static func prune(library: MediaIndex, machine: MediaLocalIndex, libraryWritable: Bool,
                             state: (MediaLocation) -> MediaFileState, named: Set<String>)
        -> (library: MediaIndex, machine: MediaLocalIndex, changes: [MediaIndexChange], posters: [MediaLocation]) {
        var library = library
        var machine = machine
        var changes: [MediaIndexChange] = []
        var posters: [MediaLocation] = []
        let replaced = Set(library.replaced.keys).union(machine.replaced.keys)
        let overrides = machine.overrides
        func gone(_ entry: MediaEntry, _ tier: MediaTier) -> Bool {
            guard let location = MediaResolver.location(of: entry, tier: tier, overrides: overrides).location else { return true }
            if case .absent = state(location) { return true }
            return false
        }
        func prunable(_ entry: MediaEntry, _ tier: MediaTier) -> Bool {
            replaced.contains(entry.id) && !named.contains(entry.id) && gone(entry, tier)
        }
        func poster(_ entry: MediaEntry, _ folder: MediaFolder) {
            if let path = entry.poster, let location = MediaLocation(folder, path) { posters.append(location) }
        }
        let prunedLibrary = libraryWritable ? library.entries.filter { prunable($0, .library) } : []
        let prunedLocal = machine.entries.filter { prunable($0, .machine) }
        for entry in prunedLibrary {
            poster(entry, .mediaRoot)
            changes.append(.pruned(id: entry.id, tier: .library))
        }
        for entry in prunedLocal {
            poster(entry, .machineMedia)
            changes.append(.pruned(id: entry.id, tier: .machine))
        }
        let goneLibrary = Set(prunedLibrary.map(\.id))
        let goneLocal = Set(prunedLocal.map(\.id))
        if !goneLibrary.isEmpty { library.entries.removeAll { goneLibrary.contains($0.id) } }
        if !goneLocal.isEmpty { machine.entries.removeAll { goneLocal.contains($0.id) } }
        return (library, machine, changes, posters)
    }
}

/// Spec 8 §4 and §7 — the media the documents on this machine name.
public enum MediaReferences {
    /// Every media id something on this machine names, as written: the
    /// commands of every cue (master lists and local copies), macro, key
    /// binding and scheduler entry, an edit or media command they hold
    /// included, and the content of the last state (Spec 9 §4). Read from
    /// each command's object form, so whatever a newer command holds is seen too.
    public static func named(library: Library, machine: Machine) -> Set<String> {
        var ids: Set<String> = []
        func collect(_ value: JSONValue) {
            switch value {
            case .string(let s): if MediaID.isValid(s) { ids.insert(s) }
            case .array(let items): items.forEach(collect)
            case .object(let members): members.values.forEach(collect)
            default: break
            }
        }
        func commands(_ entries: [GuardedCommand]) {
            for entry in entries {
                if let ref = entry.command.mediaRef {
                    ids.insert(ref)
                    continue
                }
                if let tree = try? JSONCoding.encode(entry) { collect(tree) }
            }
        }
        for list in library.lists + machine.localLists {
            for cue in list.cues { commands(cue.commands) }
        }
        for macro in library.macros + machine.macros { commands(macro.commands) }
        commands(machine.keys.map { GuardedCommand($0.command) })
        if let state = machine.lastState, let tree = try? JSONCoding.encode(state) { collect(tree) }
        return ids
    }
}
