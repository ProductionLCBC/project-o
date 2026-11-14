// OCore — Spec 8 §5, poster frames and pool tiles: their names, and which to make.

/// Spec 8 §5 — "The poster (M2) is the frame at the video's default
/// in-point (`defaults.trimInMs`, or 0), taken exactly ... It's a PNG fitted
/// within 1920 × 1080, with alpha when the video has it ... Only video has a
/// poster file: an image is its own poster ... and audio has none." And
/// "Pool tiles (M3) are 480 px wide PNGs at
/// `machine/thumbnails/pool/<hex>-<in>.png` (`<in>` is 0 for an image), made
/// from the poster for video and from the image for an image. Audio has no
/// tile".
///
/// The names and the plan are pure; the media worker extracts, draws and
/// writes (Spec 8 §2, "The engine does all of it").
public enum MediaPosters {
    /// "fitted within 1920 × 1080".
    public static let posterBounds = (width: 1920, height: 1080)
    /// "480 px wide PNGs".
    public static let tileWidth = 480
    /// "at `machine/thumbnails/pool/`", relative to the machine root.
    public static let tileFolder = "thumbnails/pool"
    /// The folder posters sit in, beside their media.
    public static let posterFolder = ".posters"

    /// Spec 8 §5 — "the video's default in-point (`defaults.trimInMs`, or 0)".
    public static func inPoint(of entry: MediaEntry) -> Int {
        max(0, entry.defaults.trimInMs ?? 0)
    }

    /// The hex of a hash id: "`<hex>` being the hash without `sha256:`".
    /// Nil for an id that isn't a hash (a slide's uuid).
    public static func hex(of id: String) -> String? {
        guard id.hasPrefix(MediaID.hashPrefix) else { return nil }
        let hex = String(id.dropFirst(MediaID.hashPrefix.count))
        return hex.isEmpty ? nil : hex
    }

    /// Spec 8 §5 — "`.posters/<hex>-<in>.png` beside the media it belongs
    /// to": the path relative to the same folder as the entry's `path`.
    public static func posterPath(id: String, inMs: Int) -> String? {
        hex(of: id).map { "\(posterFolder)/\($0)-\(max(0, inMs)).png" }
    }

    /// The poster path an entry names when its poster is made: video only.
    public static func posterPath(of entry: MediaEntry) -> String? {
        entry.kind == .video ? posterPath(id: entry.id, inMs: inPoint(of: entry)) : nil
    }

    /// Spec 8 §5 — a tile's name in `thumbnails/pool/`: `<hex>-<in>.png`,
    /// "`<in>` is 0 for an image"; nil for audio, slides and templates, which
    /// have none (a slide's tile waits for the slide designer, §1).
    public static func tileName(of entry: MediaEntry) -> String? {
        guard let hex = hex(of: entry.id) else { return nil }
        switch entry.kind {
        case .video: return "\(hex)-\(inPoint(of: entry)).png"
        case .image: return "\(hex)-0.png"
        case .audio, .audioSet, .slide, .template: return nil
        }
    }

    /// The folder an entry's `path` and `poster` read against.
    public static func folder(of tier: MediaTier) -> MediaFolder {
        tier == .machine ? .machineMedia : .mediaRoot
    }

    /// Whether a poster file name belongs to an id, any in-point: the files
    /// that go once the new one is written ("The old file goes once the new
    /// one is written"), and the tiles a new tile replaces.
    public static func belongs(_ fileName: String, to id: String) -> Bool {
        guard let hex = hex(of: id), fileName.hasPrefix(hex + "-"), fileName.hasSuffix(".png") else { return false }
        let middle = fileName.dropFirst(hex.count + 1).dropLast(4)
        return !middle.isEmpty && middle.allSatisfy(\.isNumber)
    }

    /// Spec 8 §5 — one poster to extract, or only to name.
    public struct PosterTask: Equatable, Hashable, Sendable {
        public var id: String
        public var tier: MediaTier
        /// The video file: the entry's location, an override's target included.
        public var source: MediaLocation
        /// `.posters/<hex>-<in>.png` in the entry's folder.
        public var poster: MediaLocation
        public var inMs: Int
        /// "with alpha when the video has it".
        public var alpha: Bool
        /// False when the file is already there and only the entry doesn't name it yet.
        public var extract: Bool

        public init(id: String, tier: MediaTier, source: MediaLocation, poster: MediaLocation, inMs: Int, alpha: Bool, extract: Bool) {
            self.id = id
            self.tier = tier
            self.source = source
            self.poster = poster
            self.inMs = inMs
            self.alpha = alpha
            self.extract = extract
        }
    }

    /// Spec 8 §5 — one pool tile to draw: "made from the poster for video and
    /// from the image for an image".
    public struct TileTask: Equatable, Hashable, Sendable {
        public var id: String
        /// `<hex>-<in>.png` in `thumbnails/pool/`.
        public var name: String
        public var source: MediaLocation

        public init(id: String, name: String, source: MediaLocation) {
            self.id = id
            self.name = name
            self.source = source
        }
    }

    /// Spec 8 §5 — what a poster task did, for the control thread to apply:
    /// the entry's `poster` becomes `path`, or null "when extraction fails".
    public struct Made: Equatable, Hashable, Sendable {
        public var id: String
        public var tier: MediaTier
        public var inMs: Int
        public var path: String?

        public init(id: String, tier: MediaTier, inMs: Int, path: String?) {
            self.id = id
            self.tier = tier
            self.inMs = inMs
            self.path = path
        }
    }

    /// Spec 8 §5 — the posters to make: "When. At import, by the walk when
    /// one is missing, and after an edit changes `defaults.trimInMs`" (the
    /// new in-point gives a new name, so the file the entry should name is
    /// missing) "... Who. The machine that writes the entry's index, so
    /// library posters are written only on a writable machine." Only a
    /// present file is read; a poster that failed this run (`failed`, by
    /// path) waits for its file to change.
    public static func posters(library: MediaIndex, machine: MediaLocalIndex, libraryWritable: Bool,
                               state: (MediaLocation) -> MediaFileState, posterExists: (MediaLocation) -> Bool,
                               failed: Set<MediaLocation> = []) -> [PosterTask] {
        var tasks: [PosterTask] = []
        func visit(_ entry: MediaEntry, tier: MediaTier) {
            guard entry.kind == .video, !entry.isDeleted, let path = posterPath(of: entry),
                  let poster = MediaLocation(folder(of: tier), path) else { return }
            let exists = posterExists(poster)
            if exists, entry.poster == path { return }
            if !exists, failed.contains(poster) { return }
            let (location, _) = MediaResolver.location(of: entry, tier: tier, overrides: machine.overrides)
            guard let location, MediaResolver.presence(of: entry, at: location, state: state(location)) == .ok else { return }
            tasks.append(PosterTask(id: entry.id, tier: tier, source: location, poster: poster, inMs: inPoint(of: entry),
                                    alpha: entry.hasAlpha, extract: !exists))
        }
        if libraryWritable {
            for entry in library.entries { visit(entry, tier: .library) }
        }
        for entry in machine.entries { visit(entry, tier: .machine) }
        return tasks
    }

    /// Spec 8 §5 — the tiles to draw: "Tiles are a machine cache, never
    /// synced, and made again when missing", on every machine, for both
    /// indexes. A video's tile is drawn from the poster its in-point names,
    /// once that file is there (on a `readOnlyMasters` machine, once the
    /// library's poster has synced); an image's from the image, while it's
    /// present.
    public static func tiles(library: MediaIndex, machine: MediaLocalIndex, state: (MediaLocation) -> MediaFileState,
                             posterExists: (MediaLocation) -> Bool, tileExists: (String) -> Bool) -> [TileTask] {
        var tasks: [TileTask] = []
        func visit(_ entry: MediaEntry, tier: MediaTier) {
            guard let name = tileName(of: entry), !tileExists(name) else { return }
            switch entry.kind {
            case .video:
                guard let path = posterPath(of: entry), let poster = MediaLocation(folder(of: tier), path), posterExists(poster) else { return }
                tasks.append(TileTask(id: entry.id, name: name, source: poster))
            case .image:
                let (location, _) = MediaResolver.location(of: entry, tier: tier, overrides: machine.overrides)
                guard let location, MediaResolver.presence(of: entry, at: location, state: state(location)) == .ok else { return }
                tasks.append(TileTask(id: entry.id, name: name, source: location))
            default:
                return
            }
        }
        for entry in library.entries { visit(entry, tier: .library) }
        for entry in machine.entries { visit(entry, tier: .machine) }
        return tasks
    }

    /// Spec 8 §5 — a made poster joins its entry: "The entry's `poster` holds
    /// that path ...; it's null until extracted, and when extraction fails".
    /// Applied only while the entry is still in that index, not deleted, and
    /// at that in-point, so a trim edit meanwhile wins; never to the library
    /// index on a `readOnlyMasters` machine.
    public static func apply(_ made: [Made], library: inout MediaIndex, machine: inout MediaLocalIndex,
                             libraryWritable: Bool) -> [MediaIndexChange] {
        var changes: [MediaIndexChange] = []
        for m in made {
            func update(_ entry: inout MediaEntry) -> Bool {
                guard entry.kind == .video, !entry.isDeleted, inPoint(of: entry) == m.inMs, entry.poster != m.path else { return false }
                entry.poster = m.path
                return true
            }
            switch m.tier {
            case .library:
                guard libraryWritable, let i = library.position(of: m.id) else { continue }
                var entry = library.entries[i]
                if update(&entry) {
                    library.entries[i] = entry
                    changes.append(.poster(id: m.id, tier: .library, path: m.path))
                }
            case .machine:
                guard let i = machine.position(of: m.id) else { continue }
                var entry = machine.entries[i]
                if update(&entry) {
                    machine.entries[i] = entry
                    changes.append(.poster(id: m.id, tier: .machine, path: m.path))
                }
            }
        }
        return changes
    }
}
