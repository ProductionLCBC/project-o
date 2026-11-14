// OCore — Spec 8 §4, the walk: what it does with each file it finds.

import Foundation

/// Spec 1 §7 — "Video and audio metadata read at import": "`durationMs`,
/// `fps` `{num, den}`, `width`, `height`", "`hasAudio`, `hasAlpha`,
/// `codec`", with the kind the file was found to be by opening it (Spec 8 §3,
/// "found by opening the file, not from its extension").
public struct MediaMetadata: Equatable, Sendable {
    public var kind: MediaKind
    public var durationMs: Int?
    public var fps: FrameRate?
    public var width: Int?
    public var height: Int?
    public var hasAudio: Bool
    public var hasAlpha: Bool
    public var codec: String?

    public init(kind: MediaKind, durationMs: Int? = nil, fps: FrameRate? = nil, width: Int? = nil, height: Int? = nil,
                hasAudio: Bool = false, hasAlpha: Bool = false, codec: String? = nil) {
        self.kind = kind
        self.durationMs = durationMs
        self.fps = fps
        self.width = width
        self.height = height
        self.hasAudio = hasAudio
        self.hasAlpha = hasAlpha
        self.codec = codec
    }
}

/// Spec 8 §3 — what opening a file found: a kind v1 takes, with its
/// metadata, or "refused with `unsupported`, naming the format".
public enum MediaRead: Equatable, Sendable {
    case media(MediaMetadata)
    case unsupported(String)
}

/// Spec 8 §4 — a settled file the walk found: its identity (the hash known
/// for it, or a slide's uuid), its size and modification date, and what
/// opening it found when the walk read it. The walk reads a file whose id no
/// index holds, and one whose entry lacks metadata; a file it knows already
/// has `read` nil.
public struct MediaFoundFile: Equatable, Sendable {
    public var id: String
    public var size: Int
    public var modified: String
    public var read: MediaRead?

    public init(id: String, size: Int, modified: String, read: MediaRead? = nil) {
        self.id = id
        self.size = size
        self.modified = modified
        self.read = read
    }
}

/// Spec 8 §4 — what the walk found at one location of the media root or
/// `machine/media/`.
public enum MediaFound: Equatable, Sendable {
    /// A settled file and its identity.
    case file(MediaFoundFile)
    /// "A file is read once its size and modification date have held for two
    /// seconds, and a file that doesn't open yet as a kind v1 takes, such as a
    /// video still being exported, is left for a later walk": a file is
    /// there, and what it holds isn't known yet.
    case pending

    var file: MediaFoundFile? {
        if case .file(let f) = self { return f }
        return nil
    }

    /// Spec 8 §2 — what this tells of the location's presence.
    public var state: MediaFileState {
        switch self {
        case .file(let f): return .holds(f.id)
        case .pending: return .unhashed
        }
    }
}

/// Spec 8 §4 — one change the walk made to an index: what the engine log
/// records "by id" (Spec 9 §2), and what the `library` event names.
public enum MediaIndexChange: Equatable, Hashable, Sendable {
    /// "A new id at a path no entry holds is a new entry with empty defaults";
    /// a landing's new id is a new entry too, "with the old item's defaults".
    case added(id: String, tier: MediaTier, location: MediaLocation)
    /// "A move ... the entry takes the new path and folder, and keeps its defaults".
    case moved(id: String, tier: MediaTier, from: String, location: MediaLocation)
    /// "A landing ... The old entry's `path` becomes empty ... and the index
    /// that holds it records old → landed in its `replaced` map."
    case landed(old: String, new: String, tier: MediaTier, location: MediaLocation)
    /// A landed id that was mapped "loses any mapping that leaves it".
    case unmapped(id: String, tier: MediaTier, was: String)
    /// "A deleted item's id ... brings the item back at that path, with its defaults".
    case broughtBack(id: String, tier: MediaTier, location: MediaLocation)
    /// "If the entry's file goes, a landing included, the entry takes the copy's path."
    case tookCopy(id: String, tier: MediaTier, from: String, location: MediaLocation)
    /// "The walk ... reads missing metadata."
    case metadata(id: String, tier: MediaTier)
    /// "Only the launch walk prunes: replaced entries whose file is gone and
    /// that nothing on this machine names".
    case pruned(id: String, tier: MediaTier)
    /// Spec 8 §5 — "The walk extracts missing posters": the entry's `poster`
    /// names the frame extracted at its in-point, or is null "when extraction
    /// fails, which is reported".
    case poster(id: String, tier: MediaTier, path: String?)

    /// The id of the entry the change made or changed.
    public var id: String {
        switch self {
        case .added(let id, _, _), .moved(let id, _, _, _), .unmapped(let id, _, _), .broughtBack(let id, _, _),
             .tookCopy(let id, _, _, _), .metadata(let id, _), .pruned(let id, _), .poster(let id, _, _):
            return id
        case .landed(let old, _, _, _):
            return old
        }
    }

    /// Spec 8 §4 — "When the walk maps an entry to another file or brings a
    /// deleted one back, it drops every undo and redo step that names that
    /// entry": the entry this change mapped or brought back, if it did.
    public var remapped: String? {
        switch self {
        case .landed(let old, _, _, _): return old
        case .broughtBack(let id, _, _): return id
        default: return nil
        }
    }

    /// Spec 5 §2 as Spec 8 §2 adds — the `library` event's `changed`, "naming
    /// the media by id": each entry the change touched.
    public var libraryChanges: [LibraryChange] {
        func media(_ id: String, _ paths: [String] = []) -> LibraryChange {
            LibraryChange(object: "media", address: ["media": .string(id)], paths: paths)
        }
        switch self {
        case .added(let id, _, _), .pruned(let id, _): return [media(id)]
        case .moved(let id, _, _, _), .tookCopy(let id, _, _, _): return [media(id, ["path", "folder"])]
        case .landed(let old, let new, _, _): return [media(old, ["path"]), media(new)]
        case .unmapped(let id, _, _): return [media(id)]
        case .broughtBack(let id, _, _): return [media(id, ["path", "folder", "deletedAt"])]
        case .metadata(let id, _): return [media(id)]
        case .poster(let id, _, _): return [media(id, ["poster"])]
        }
    }

    /// The engine log's words for the change (Spec 9 §2, "the media index
    /// changes of an import or the walk, by id").
    public var logText: String {
        func at(_ l: MediaLocation) -> String { "\(l.folder.rawValue) \(l.path)" }
        switch self {
        case .added(let id, let tier, let l): return "media: added \(id) to the \(tier.rawValue) index at \(at(l))"
        case .moved(let id, let tier, let from, let l): return "media: \(id) (\(tier.rawValue)) moved from \(from) to \(at(l))"
        case .landed(let old, let new, let tier, let l): return "media: \(new) landed at \(at(l)) over \(old) (\(tier.rawValue)); \(old) → \(new)"
        case .unmapped(let id, let tier, let was): return "media: \(id) (\(tier.rawValue)) no longer maps to \(was)"
        case .broughtBack(let id, let tier, let l): return "media: deleted \(id) (\(tier.rawValue)) brought back at \(at(l))"
        case .tookCopy(let id, let tier, let from, let l): return "media: \(id) (\(tier.rawValue)) took its copy at \(at(l)); its file at \(from) went"
        case .metadata(let id, let tier): return "media: read the metadata of \(id) (\(tier.rawValue))"
        case .pruned(let id, let tier): return "media: pruned replaced \(id) from the \(tier.rawValue) index"
        case .poster(let id, let tier, let path?): return "media: the poster of \(id) (\(tier.rawValue)) is \(path)"
        case .poster(let id, let tier, nil): return "media: no poster for \(id) (\(tier.rawValue)): its frame couldn't be extracted"
        }
    }
}

/// Spec 8 §4 — what the walk reports and leaves alone.
public enum MediaWalkNote: Equatable, Hashable, Sendable {
    /// "An id the other folder's index holds is left alone and reported".
    case otherFolder(id: String, location: MediaLocation)
    /// "Identical files at two paths in one folder are one entry ...; the
    /// other copy is reported."
    case copy(id: String, location: MediaLocation)
    /// "kinds v1 doesn't take, which the reference report lists".
    case unsupported(location: MediaLocation, format: String)

    /// The words the engine log and the reference report use.
    public var text: String {
        switch self {
        case .otherFolder(let id, let l): return "\(l.folder.rawValue) \(l.path) holds \(id), which the other folder's index holds; left alone"
        case .copy(let id, let l): return "\(l.folder.rawValue) \(l.path) is a copy of \(id)"
        case .unsupported(let l, let format): return "\(l.folder.rawValue) \(l.path) is \(format), which v1 doesn't take"
        }
    }
}

/// Spec 8 §4 — the walk's rules, pure: given both indexes, what the walk
/// found in each folder it read and what it found last time (the cache),
/// the indexes as the rules leave them, the changes, the notes and the
/// cache's new records.
public enum MediaWalk {
    /// Spec 8 §4's inputs.
    public struct Input: Sendable {
        public var library: MediaIndex
        public var machine: MediaLocalIndex
        /// Spec 8 §2 — "On a `readOnlyMasters` machine the walk writes nothing
        /// in the library".
        public var libraryWritable: Bool
        /// The files found in the folders this walk read, by location, the
        /// files overrides point at included.
        public var found: [MediaLocation: MediaFound]
        /// The folders this walk read; a folder it didn't read changes nothing,
        /// and its records stay in the cache.
        public var folders: Set<MediaFolder>
        /// Spec 8 §2 — "the walk never treats their files as entries": the
        /// locations overrides point at, whose files the rules skip and whose
        /// hashes the cache keeps.
        public var overrideTargets: Set<MediaLocation>
        /// Spec 8 §4 — "what it found last time, which the cache records".
        public var cache: MediaCache
        /// `addedAt` for the entries it makes (Spec 1 §7).
        public var now: String

        public init(library: MediaIndex, machine: MediaLocalIndex, libraryWritable: Bool, found: [MediaLocation: MediaFound],
                    folders: Set<MediaFolder> = [.mediaRoot, .machineMedia], overrideTargets: Set<MediaLocation> = [],
                    cache: MediaCache = MediaCache(), now: String) {
            self.library = library
            self.machine = machine
            self.libraryWritable = libraryWritable
            self.found = found
            self.folders = folders
            self.overrideTargets = overrideTargets
            self.cache = cache
            self.now = now
        }
    }

    /// Spec 8 §4's outputs.
    public struct Result: Equatable, Sendable {
        public var library: MediaIndex
        public var machine: MediaLocalIndex
        public var changes: [MediaIndexChange]
        public var notes: [MediaWalkNote]
        /// The cache after the walk: a record per file found in the folders it
        /// read, and the records of the folders it didn't.
        public var cache: MediaCache

        /// The entries mapped to another file or brought back (Spec 8 §4, "The walk and undo").
        public var remapped: [String] {
            var seen: Set<String> = []
            return changes.compactMap(\.remapped).filter { seen.insert($0).inserted }
        }
    }

    /// Spec 8 §4 — apply the walk's rules: the media root first, then
    /// `machine/media/`, each against the other folder's index as the walk
    /// has left it, so the result never depends on the order files were found.
    public static func plan(_ input: Input) -> Result {
        var library = input.library
        var machine = input.machine
        var changes: [MediaIndexChange] = []
        var notes: [MediaWalkNote] = []
        let lastSeen = input.cache.lastSeen
        for folder in [MediaFolder.mediaRoot, .machineMedia] where input.folders.contains(folder) {
            let files = input.found.filter { $0.key.folder == folder && !input.overrideTargets.contains($0.key) }
            var pass = FolderPass(folder: folder, files: files, lastSeen: lastSeen, now: input.now)
            if folder == .mediaRoot {
                var replaced = library.replaced
                var entries = library.entries
                pass.run(entries: &entries, replaced: &replaced, other: { machine.entry($0) != nil },
                         writable: input.libraryWritable)
                library.entries = entries
                library.replaced = replaced
            } else {
                var replaced = machine.replaced
                var entries = machine.entries
                pass.run(entries: &entries, replaced: &replaced, other: { library.entry($0) != nil }, writable: true)
                machine.entries = entries
                machine.replaced = replaced
            }
            changes += pass.changes
            notes += pass.notes
        }
        // Spec 8 §4 — "a record for every file the engine has hashed": the
        // files found in the folders read, and the other folders' records as they were.
        var records = input.cache.records.filter { !input.folders.contains($0.location.folder) }
        for (location, found) in input.found where input.folders.contains(location.folder) {
            guard let file = found.file else { continue }
            records.append(MediaCacheRecord(location: location, size: file.size, modified: file.modified, hash: file.id))
        }
        return Result(library: library, machine: machine, changes: changes, notes: notes,
                      cache: MediaCache(records: records, extra: input.cache.extra))
    }

    /// Spec 1 §7 — an entry for a file the walk or an import found: its
    /// metadata, `addedAt` and `folder`, and the defaults it is given.
    public static func entry(id: String, location: MediaLocation, file: MediaFoundFile, metadata: MediaMetadata,
                             defaults: MediaDefaults = MediaDefaults(), addedAt: String) -> MediaEntry {
        MediaEntry(id: id, path: location.path, kind: metadata.kind, size: file.size, modified: file.modified,
                   durationMs: metadata.durationMs, fps: metadata.fps, width: metadata.width, height: metadata.height,
                   hasAudio: metadata.hasAudio, hasAlpha: metadata.hasAlpha, codec: metadata.codec, poster: nil,
                   defaults: defaults, addedAt: addedAt, folder: location.parent)
    }
}

/// One folder's pass of the rules, in Spec 8 §4's order.
private struct FolderPass {
    let folder: MediaFolder
    let lastSeen: [MediaLocation: String]
    let now: String
    /// The settled, identified files, in path order.
    let files: [(location: MediaLocation, file: MediaFoundFile)]
    let found: [MediaLocation: MediaFound]
    var tier: MediaTier { folder == .machineMedia ? .machine : .library }
    var changes: [MediaIndexChange] = []
    var notes: [MediaWalkNote] = []
    /// Files a rule has dealt with.
    var consumed: Set<MediaLocation> = []

    init(folder: MediaFolder, files: [MediaLocation: MediaFound], lastSeen: [MediaLocation: String], now: String) {
        self.folder = folder
        self.lastSeen = lastSeen
        self.now = now
        self.found = files
        self.files = files.compactMap { location, found in found.file.map { (location, $0) } }.sorted { $0.location < $1.location }
    }

    func location(_ path: String) -> MediaLocation? {
        path.isEmpty ? nil : MediaLocation(folder, path)
    }

    /// Whether the file at `location` is the one with this id.
    func holds(_ location: MediaLocation?, _ id: String) -> Bool {
        guard let location, case .file(let f)? = found[location] else { return false }
        return f.id == id
    }

    func isPending(_ location: MediaLocation?) -> Bool {
        guard let location, case .pending? = found[location] else { return false }
        return true
    }

    /// The metadata a file can make an entry from, or nil.
    func metadata(_ file: MediaFoundFile) -> MediaMetadata? {
        if case .media(let m)? = file.read { return m }
        return nil
    }

    mutating func run(entries: inout [MediaEntry], replaced: inout [String: String], other: (String) -> Bool, writable: Bool) {
        var index: [String: Int] = [:]
        for (i, e) in entries.enumerated() { index[e.id] = i }
        // The entry holding each path, the first by id when two claim one.
        func holders() -> [String: String] {
            var out: [String: String] = [:]
            for e in entries where !e.path.isEmpty && !e.isDeleted && out[e.path] == nil { out[e.path] = e.id }
            return out
        }
        var holder = holders()
        func entry(_ id: String) -> MediaEntry? { index[id].map { entries[$0] } }
        func update(_ id: String, _ body: (inout MediaEntry) -> Void) {
            guard let i = index[id] else { return }
            body(&entries[i])
        }
        func place(_ id: String, at location: MediaLocation, file: MediaFoundFile) {
            update(id) { e in
                if !e.path.isEmpty, holder[e.path] == id { holder[e.path] = nil }
                e.path = location.path
                e.folder = location.parent
                e.size = file.size
                e.modified = file.modified
            }
            holder[location.path] = id
        }

        // Kinds v1 doesn't take are skipped, and reported.
        for (location, file) in files {
            if case .unsupported(let format)? = file.read, entry(file.id) == nil {
                notes.append(.unsupported(location: location, format: format))
                consumed.insert(location)
            }
        }
        // Left alone: "A file whose known hash is the id of the entry at that path".
        for (location, file) in files where holder[location.path] == file.id {
            consumed.insert(location)
            // "The walk ... reads missing metadata."
            if writable, let m = metadata(file), let e = entry(file.id), Self.lacksMetadata(e) {
                update(file.id) { Self.fill(&$0, m) }
                changes.append(.metadata(id: file.id, tier: tier))
            }
        }
        // 1. "An id the other folder's index holds is left alone and reported".
        for (location, file) in files where !consumed.contains(location) && entry(file.id) == nil && other(file.id) {
            notes.append(.otherFolder(id: file.id, location: location))
            consumed.insert(location)
        }
        guard writable else {
            // Spec 8 §4 — on a read-only folder the walk writes nothing: copies are still reported.
            for (location, file) in files where !consumed.contains(location) && entry(file.id) != nil {
                notes.append(.copy(id: file.id, location: location))
            }
            return
        }
        // "A landing ... replaces that entry (choice M-2). The old entry's
        // `path` becomes empty, so it counts as missing, and the index that
        // holds it records old → landed in its `replaced` map. ... A known id
        // keeps its own defaults and loses any mapping that leaves it, so ...
        // the walk never makes a loop". A new id loses one too: a pruned
        // entry's mapping stays (§4), and its bytes can land again.
        func land(_ old: String, _ new: String, at location: MediaLocation) {
            update(old) { $0.path = "" }
            if holder[location.path] == old { holder[location.path] = nil }
            if let was = replaced[new] {
                replaced[new] = nil
                changes.append(.unmapped(id: new, tier: tier, was: was))
            }
            replaced[old] = new
            changes.append(.landed(old: old, new: new, tier: tier, location: location))
        }

        // 2. "A deleted item's id, found anywhere in its own folder, brings the
        // item back at that path, with its defaults". An entry that still held
        // that path is landed on, as any file with another id lands.
        for (location, file) in files where !consumed.contains(location) {
            guard let e = entry(file.id), e.isDeleted else { continue }
            consumed.insert(location)
            if let old = holder[location.path], old != file.id { land(old, file.id, at: location) }
            update(file.id) { $0.deletedAt = nil }
            place(file.id, at: location, file: file)
            changes.append(.broughtBack(id: file.id, tier: tier, location: location))
        }
        // 3. "A move. An indexed id found at a path where the last walk didn't
        // see it, while its entry's path no longer holds it, is a move", to a
        // path no entry holds. A file still being written at its entry's path
        // doesn't hold it, so a file renamed away moves while a new one is
        // saved under its name.
        for (location, file) in files where !consumed.contains(location) {
            guard let e = entry(file.id), !e.isDeleted, holder[location.path] == nil, lastSeen[location] != file.id,
                  !holds(self.location(e.path), file.id) else { continue }
            let from = e.path
            place(file.id, at: location, file: file)
            changes.append(.moved(id: file.id, tier: tier, from: from, location: location))
            consumed.insert(location)
        }
        // 4. "A landing. Once moves are settled, a file with another id at a
        // path an entry still holds replaces that entry".
        for (location, file) in files where !consumed.contains(location) {
            guard let old = holder[location.path], old != file.id else { continue }
            let known = entry(file.id)
            // A new id needs what opening it found to become an entry; without
            // it nothing lands, and the old entry keeps its path.
            guard known != nil || metadata(file) != nil else { continue }
            consumed.insert(location)
            land(old, file.id, at: location)
            if let known {
                // "its entry takes the path unless its own file is still where
                // the entry says, which makes this file a copy."
                if known.path == location.path { continue }
                if holds(self.location(known.path), file.id) {
                    notes.append(.copy(id: file.id, location: location))
                } else {
                    let from = known.path
                    place(file.id, at: location, file: file)
                    if !from.isEmpty { changes.append(.moved(id: file.id, tier: tier, from: from, location: location)) }
                }
            } else if let m = metadata(file) {
                // "A new id becomes a new item there with the old item's defaults: the usual re-export."
                let defaults = entry(old)?.defaults ?? MediaDefaults()
                let made = MediaWalk.entry(id: file.id, location: location, file: file, metadata: m, defaults: defaults, addedAt: now)
                entries.append(made)
                index[file.id] = entries.count - 1
                holder[location.path] = file.id
            }
        }
        // 5. "Copies. ... If the entry's file goes, a landing included, the entry takes the copy's path."
        for (location, file) in files where !consumed.contains(location) {
            guard let e = entry(file.id), !e.isDeleted, holder[location.path] == nil else { continue }
            let own = self.location(e.path)
            if holds(own, file.id) || isPending(own) {
                notes.append(.copy(id: file.id, location: location))
            } else {
                let from = e.path
                place(file.id, at: location, file: file)
                changes.append(.tookCopy(id: file.id, tier: tier, from: from, location: location))
            }
            consumed.insert(location)
        }
        // 6. "A new id at a path no entry holds is a new entry with empty defaults."
        for (location, file) in files where !consumed.contains(location) {
            consumed.insert(location)
            if entry(file.id) != nil {
                notes.append(.copy(id: file.id, location: location))
                continue
            }
            guard holder[location.path] == nil, let m = metadata(file) else { continue }
            let made = MediaWalk.entry(id: file.id, location: location, file: file, metadata: m, addedAt: now)
            entries.append(made)
            index[file.id] = entries.count - 1
            holder[location.path] = file.id
            changes.append(.added(id: file.id, tier: tier, location: location))
        }
    }

    /// Spec 1 §7 — the metadata a video, an image or audio needs and an entry may lack.
    static func lacksMetadata(_ e: MediaEntry) -> Bool {
        switch e.kind {
        case .video: return e.durationMs == nil || e.width == nil || e.height == nil || e.codec == nil
        case .image: return e.width == nil || e.height == nil
        case .audio: return e.durationMs == nil
        case .audioSet, .slide, .template: return false
        }
    }

    static func fill(_ e: inout MediaEntry, _ m: MediaMetadata) {
        e.durationMs = e.durationMs ?? m.durationMs
        e.fps = e.fps ?? m.fps
        e.width = e.width ?? m.width
        e.height = e.height ?? m.height
        e.codec = e.codec ?? m.codec
        e.hasAudio = e.hasAudio || m.hasAudio
        e.hasAlpha = e.hasAlpha || m.hasAlpha
    }
}
