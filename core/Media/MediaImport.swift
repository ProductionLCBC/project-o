// OCore — Spec 8 §3, import: where a file goes, its name, and its outcome.

import Foundation

/// Spec 8 §7 — "`outcome` is `imported`, `known` or `refused`, a refusal with
/// its `reason` (`unsupported`, `changed`, `diskFull`, `notListed` or
/// `readOnlyLibrary`)".
public enum MediaImportRefusal: String, Codable, Equatable, Sendable {
    case unsupported, changed, diskFull, notListed, readOnlyLibrary
}

/// Spec 8 §7 — a file's final outcome, with the id it resolved to.
public enum MediaImportOutcome: Equatable, Sendable {
    case imported(String)
    case known(String)
    /// The reason, and what it names (the format a kind refusal names, Spec 8 §3).
    case refused(MediaImportRefusal, String?)

    /// The `outcome` word of the `media` topic's `done` event.
    public var word: String {
        switch self {
        case .imported: return "imported"
        case .known: return "known"
        case .refused: return "refused"
        }
    }

    public var id: String? {
        switch self {
        case .imported(let id), .known(let id): return id
        case .refused: return nil
        }
    }
}

/// Spec 8 §3 — import's rules, pure: what happens to a file once it is
/// hashed, where its copy goes and what it is called, and how its result
/// joins the index.
public enum MediaImport {
    /// Spec 8 §3 — what to do with a file from outside both folders, once hashed.
    public enum Decision: Equatable, Sendable {
        /// "A hash the index already knows isn't copied: the import resolves to
        /// that item, with outcome `known`. A hash that a `replaced` map names
        /// resolves to its replacement".
        case known(String)
        /// Copy it into `folder`'s import folder, its entry in `tier`: a new
        /// entry, or the deleted or missing item it brings back.
        case copy(into: MediaFolder, tier: MediaTier, bringsBack: String?)
        case refused(MediaImportRefusal)
    }

    /// Spec 8 §3, steps 2 and 4 and the table "Where an import goes", for a
    /// file "From outside both folders" with id `id`:
    ///
    /// 1. an id a `replaced` map names resolves to its replacement, `known`;
    /// 2. "A deleted or missing item's own hash brings the item back: the file
    ///    is copied in, and the entry takes the copy's path and keeps its
    ///    defaults" — into the folder of the index that holds it; a library
    ///    item on a `readOnlyMasters` machine is refused with `readOnlyLibrary`;
    /// 3. any other id the index knows is `known`;
    /// 4. a new id is copied "into the media root; a library entry" on a
    ///    writable machine, "into `machine/media/`; a machine entry" on a
    ///    `readOnlyMasters` one.
    public static func decide(id: String, libraryWritable: Bool, library: MediaIndex, machine: MediaLocalIndex,
                              presence: (String) -> MediaPresence) -> Decision {
        let chain = MediaResolver.chain(from: id, library: library, machine: machine)
        if chain.ids.count > 1, let resolved = MediaResolver.resolve(id, library: library, machine: machine) {
            return .known(resolved.id)
        }
        if let (entry, tier) = MediaResolver.entry(for: id, library: library, machine: machine) {
            let state = entry.isDeleted ? MediaPresence.deleted : presence(id)
            guard state != .ok else { return .known(id) }
            if tier == .library, !libraryWritable { return .refused(.readOnlyLibrary) }
            return .copy(into: tier == .library ? .mediaRoot : .machineMedia, tier: tier, bringsBack: id)
        }
        return libraryWritable ? .copy(into: .mediaRoot, tier: .library, bringsBack: nil)
                               : .copy(into: .machineMedia, tier: .machine, bringsBack: nil)
    }

    /// Spec 8 §3, step 4 — "The file goes into the import folder
    /// (`defaultImportFolder`) of the folder the table below names. A name
    /// that a file holds, or that another entry's path holds even while its
    /// file is missing, gets a space and `2`, `3` and so on before its
    /// extension, as the Finder names copies". A dropped folder "keeps its
    /// subfolders under the import folder", given as `subfolder`. `taken`
    /// holds the paths in `folder` that files or entries hold; names compare
    /// without regard to case, as the startup volume does by default. An
    /// import folder that would leave its folder puts the file at the top.
    public static func destination(name: String, subfolder: String = "", importFolder: String, folder: MediaFolder,
                                   taken: Set<String>) -> MediaLocation? {
        var parts: [String] = []
        if !importFolder.isEmpty, MediaLocation(folder, importFolder) != nil { parts.append(importFolder) }
        if !subfolder.isEmpty { parts.append(subfolder) }
        let prefix = parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
        let lowered = Set(taken.map { $0.lowercased() })
        let (stem, ext) = split(name)
        var candidate = prefix + name
        var n = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = prefix + stem + " " + String(n) + ext
            n += 1
        }
        return MediaLocation(folder, candidate)
    }

    /// A name's stem and its last extension with the dot: `Welcome.mov` →
    /// (`Welcome`, `.mov`); `README` → (`README`, ``).
    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// Spec 8 §3 — a copied file, ready for step 5: its id, where its copy
    /// is, its size and date, its kind and metadata, the tier its entry goes
    /// in, and the item it brings back.
    public struct Copied: Equatable, Sendable {
        public var location: MediaLocation
        public var file: MediaFoundFile
        public var metadata: MediaMetadata?
        public var tier: MediaTier
        public var bringsBack: String?
        /// Spec 8 §3, step 5 — "extracts the poster (§5), writes the entry":
        /// the poster made for a new video, relative to the copy's folder.
        public var poster: String?

        public init(location: MediaLocation, file: MediaFoundFile, metadata: MediaMetadata?, tier: MediaTier, bringsBack: String?,
                    poster: String? = nil) {
            self.location = location
            self.file = file
            self.metadata = metadata
            self.tier = tier
            self.bringsBack = bringsBack
            self.poster = poster
        }
    }

    /// Spec 8 §3, step 5 — "Index. The engine ... writes the entry with empty
    /// defaults, `addedAt` and `folder`", or brings back the item it named,
    /// with its defaults, at the copy's path. Applied through the one queue
    /// against the indexes as they are then: an id that an earlier change has
    /// indexed meanwhile resolves to that item, `known`, and its copy is a
    /// copy the walk reports.
    public static func apply(_ copied: Copied, library: inout MediaIndex, machine: inout MediaLocalIndex, libraryWritable: Bool,
                             presence: (String) -> MediaPresence, now: String) -> (MediaImportOutcome, [MediaIndexChange]) {
        let id = copied.file.id
        if copied.tier == .library, !libraryWritable { return (.refused(.readOnlyLibrary, nil), []) }
        if let back = copied.bringsBack, back == id,
           let (entry, tier) = MediaResolver.entry(for: id, library: library, machine: machine), tier == copied.tier,
           entry.isDeleted || presence(id) != .ok {
            func bringBack(_ e: inout MediaEntry) {
                e.deletedAt = nil
                e.path = copied.location.path
                e.folder = copied.location.parent
                e.size = copied.file.size
                e.modified = copied.file.modified
            }
            if tier == .library, let i = library.position(of: id) {
                bringBack(&library.entries[i])
            } else if tier == .machine, let i = machine.position(of: id) {
                bringBack(&machine.entries[i])
            }
            return (.imported(id), [.broughtBack(id: id, tier: tier, location: copied.location)])
        }
        if MediaResolver.entry(for: id, library: library, machine: machine) != nil {
            return (.known(MediaResolver.resolve(id, library: library, machine: machine)?.id ?? id), [])
        }
        guard let metadata = copied.metadata else { return (.refused(.unsupported, nil), []) }
        var entry = MediaWalk.entry(id: id, location: copied.location, file: copied.file, metadata: metadata, addedAt: now)
        if entry.kind == .video { entry.poster = copied.poster }
        if copied.tier == .library { library.add(entry) } else { machine.add(entry) }
        return (.imported(id), [.added(id: id, tier: copied.tier, location: copied.location)])
    }

    /// Spec 8 §3, the table's rows "Already in the media root" and "Already
    /// in `machine/media/`": a file imported where it lies is "Indexed where
    /// it is", by the walk that reads it, and its outcome comes from what that
    /// walk found and did at its location; nil while its file isn't settled.
    /// On a `readOnlyMasters` machine a file in the media root is "`known` if
    /// the library index lists it, otherwise refused with `notListed`", and a
    /// missing or deleted library item's id is refused with `readOnlyLibrary`.
    ///
    /// In order: a kind v1 doesn't take is refused; an id a `replaced` map
    /// names resolves to its replacement, `known`; an item that was present
    /// before the walk is `known`; an entry the walk made, brought back or
    /// moved to this location is `imported`; any other indexed id is `known`,
    /// but a missing or deleted library item on a `readOnlyMasters` machine,
    /// which is refused with `readOnlyLibrary`; and nothing indexed is
    /// `notListed`. A file that went before the walk read it is `changed`.
    public static func inPlaceOutcome(at location: MediaLocation, found: MediaFound?, before: (library: MediaIndex, machine: MediaLocalIndex),
                                      presentBefore: (String) -> Bool, walk: MediaWalk.Result, libraryWritable: Bool) -> MediaImportOutcome? {
        guard let found else { return .refused(.changed, nil) }
        guard case .file(let file) = found else { return nil }
        let id = file.id
        let after = (library: walk.library, machine: walk.machine)
        if case .unsupported(let format)? = file.read, MediaResolver.entry(for: id, library: after.library, machine: after.machine) == nil {
            return .refused(.unsupported, format)
        }
        let resolved = MediaResolver.resolve(id, library: after.library, machine: after.machine)
        if MediaResolver.chain(from: id, library: after.library, machine: after.machine).ids.count > 1, let resolved {
            return .known(resolved.id)
        }
        if let (entry, _) = MediaResolver.entry(for: id, library: before.library, machine: before.machine), !entry.isDeleted, presentBefore(id) {
            return .known(id)
        }
        guard let (entry, tier) = MediaResolver.entry(for: id, library: after.library, machine: after.machine) else {
            return .refused(.notListed, nil)
        }
        if !entry.isDeleted, entry.path == location.path, tier == (location.folder == .machineMedia ? .machine : .library) {
            return .imported(id)
        }
        if tier == .library, !libraryWritable { return .refused(.readOnlyLibrary, nil) }
        return .known(resolved?.id ?? id)
    }
}
