// OCore — Spec 8 §7 and Spec 10 §3, the `mediaUse` and `media` queries' answers.

import Foundation

/// Spec 8 §7 — "The use query answers the delete confirmation: `{"id": 63,
/// "type": "query", "what": "mediaUse", "media": "sha256:…"}` returns
/// `{"id": 63, "type": "answer", "cues": 12, "macros": 1, "presets": 0,
/// "keys": 2}`, counted over the library and machine documents on this
/// machine, key bindings and scheduler entries included, with references
/// that resolve to the item through a `replaced` map."
///
/// Each holder counts once: a cue (in a list or a local copy), a macro, a key
/// binding or a scheduler entry (both in `keys`, since the answer has no field
/// of its own for the scheduler). A reference is a write, or a cue's held
/// `edit.cueChannel` that writes, as `media replace` rewrites them (Spec 8
/// §6); it counts for the item it resolves to, so a reference to a replaced
/// item counts for its replacement, which is what plays and what deleting
/// would leave missing. Presets hold no media in v1.
public struct MediaUse: Equatable, Sendable {
    public var cues = 0
    public var macros = 0
    public var presets = 0
    public var keys = 0

    public init(cues: Int = 0, macros: Int = 0, presets: Int = 0, keys: Int = 0) {
        self.cues = cues
        self.macros = macros
        self.presets = presets
        self.keys = keys
    }

    /// Spec 10 §3 — "its uses as `mediaUse` counts them in all".
    public var total: Int { cues + macros + presets + keys }

    /// The answer's fields.
    public var fields: [String: JSONValue] {
        ["cues": .number(Double(cues)), "macros": .number(Double(macros)), "presets": .number(Double(presets)), "keys": .number(Double(keys))]
    }

    /// The uses of every item anything uses, by the id references resolve to.
    public static func all(library: Library, machine: Machine) -> [String: MediaUse] {
        var resolved: [String: String] = [:]
        func target(_ ref: String) -> String {
            if let known = resolved[ref] { return known }
            let reached = MediaResolver.chain(from: ref, library: library.mediaIndex, machine: machine.mediaLocal).reached
            resolved[ref] = reached
            return reached
        }
        func items(_ commands: [GuardedCommand], inCue: Bool) -> Set<String> {
            Set(commands.compactMap { MediaRefSites.ref(of: $0.command, inCue: inCue) }.map(target))
        }
        var uses: [String: MediaUse] = [:]
        for list in library.lists + machine.localLists {
            for cue in list.cues {
                for id in items(cue.commands, inCue: true) { uses[id, default: MediaUse()].cues += 1 }
            }
        }
        for macro in library.macros + machine.macros {
            for id in items(macro.commands, inCue: false) { uses[id, default: MediaUse()].macros += 1 }
        }
        for binding in machine.keys {
            guard let ref = MediaRefSites.ref(of: binding.command, inCue: false) else { continue }
            uses[target(ref), default: MediaUse()].keys += 1
        }
        return uses
    }

    /// One item's uses.
    public static func of(_ id: String, library: Library, machine: Machine) -> MediaUse {
        all(library: library, machine: machine)[id] ?? MediaUse()
    }
}

/// Spec 10 §3 — the `media` query: "Every entry of both indexes, each with
/// its index, its presence (`ok`, `missing` or `deleted`), what replaced it,
/// its uses as `mediaUse` counts them in all, and its tile's file". Each item
/// is its entry as the index holds it, with `index`, `presence` (of its own
/// file, at its own location), `replacedBy` (the item its `replaced` chain
/// ends at, null when nothing replaced it), `uses` and `tile` (the file's
/// absolute path, null while there is none).
public enum MediaCatalog {
    public static func entries(library: Library, machine: Machine, files: (MediaLocation) -> MediaFileState,
                               tile: (MediaEntry) -> String?) -> [JSONValue] {
        let uses = MediaUse.all(library: library, machine: machine)
        var out: [JSONValue] = []
        func add(_ entry: MediaEntry, tier: MediaTier) {
            guard case .object(var members)? = try? JSONCoding.encode(entry) else { return }
            let location = MediaResolver.location(of: entry, tier: tier, overrides: machine.mediaLocal.overrides).location
            let presence = MediaResolver.presence(of: entry, at: location, state: location.map(files) ?? .absent)
            let reached = MediaResolver.chain(from: entry.id, library: library.mediaIndex, machine: machine.mediaLocal).reached
            members["index"] = .string(tier.rawValue)
            members["presence"] = .string(presence.rawValue)
            members["replacedBy"] = reached == entry.id ? .null : .string(reached)
            members["uses"] = .number(Double(uses[entry.id]?.total ?? 0))
            members["tile"] = tile(entry).map(JSONValue.string) ?? .null
            out.append(.object(members))
        }
        for entry in library.mediaIndex.entries { add(entry, tier: .library) }
        for entry in machine.mediaLocal.entries { add(entry, tier: .machine) }
        return out
    }
}
