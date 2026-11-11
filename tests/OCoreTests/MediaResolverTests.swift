import Foundation
import XCTest
@testable import OCore

/// Spec 8 §2 — where a file is, resolving an id, present or missing; Spec 1 §7
/// as Spec 8 corrected it — the index entry's `deletedAt` and the machine
/// index's own `replaced` map. Spec 8 §11, Resolver: "Library, machine and
/// override locations, absolute overrides included, resolve to the right
/// file. An entry whose location holds other bytes is missing ... A slide is
/// present by its uuid." Spec 8 §11, the walk: "Eight weekly re-exports in
/// place still resolve from the first id to the last, and a hand-made loop in
/// the map stops and is reported."
final class MediaResolverTests: XCTestCase {
    /// A distinct `sha256:` id per digit or letter.
    static func id(_ c: Character) -> String { "sha256:" + String(repeating: String(c), count: 64) }
    let a = id("a"), b = id("b"), c = id("c"), d = id("d"), e = id("e")

    func entry(_ id: String, _ path: String, kind: MediaKind = .video, deletedAt: String? = nil) -> MediaEntry {
        MediaEntry(id: id, path: path, kind: kind, size: 1, deletedAt: deletedAt)
    }

    // MARK: - The index model (Spec 1 §7, Spec 8 §6)

    /// Spec 8 §6 — "the entry stays, with `deletedAt` set and its `path`
    /// empty". The key is written only when it is set, so indexes written
    /// before Spec 8 come back byte for byte.
    func test_deletedAtRoundTripsAndIsWrittenOnlyWhenSet() throws {
        let live = entry(a, "x.mov")
        let gone = entry(b, "", deletedAt: "2026-11-11T09:00:00Z")
        let index = MediaIndex(entries: [gone, live])
        let text = JSONCanonical.line(try JSONCoding.encode(index))
        XCTAssertEqual(text.components(separatedBy: "deletedAt").count, 2, "only the deleted entry carries the key")
        let back = try JSONCoding.decode(MediaIndex.self, from: try JSONCoding.encode(index))
        XCTAssertEqual(back, index)
        XCTAssertEqual(back.entry(b)?.deletedAt, "2026-11-11T09:00:00Z")
        XCTAssertTrue(back.entry(b)?.isDeleted == true)
        XCTAssertFalse(back.entry(a)?.isDeleted == true)
    }

    /// Spec 1 §7 — "`machine/media-local.json` holds `entries`, `overrides`
    /// ... and its own `replaced` map", written only while it holds a mapping.
    func test_theMachineIndexHasItsOwnReplacedMap() throws {
        let empty = MediaLocalIndex()
        XCTAssertFalse(JSONCanonical.line(try JSONCoding.encode(empty)).contains("replaced"))
        let mapped = MediaLocalIndex(entries: [entry(a, "x.png", kind: .image)], replaced: [b: a])
        let back = try JSONCoding.decode(MediaLocalIndex.self, from: try JSONCoding.encode(mapped))
        XCTAssertEqual(back.replaced, [b: a])
        XCTAssertEqual(back, mapped)
    }

    /// Spec 1 §7 — entries "in id order", whatever order they were added or
    /// edited in, so a lookup can search.
    func test_entriesStayInIdOrder() {
        var index = MediaIndex(entries: [entry(c, "c"), entry(a, "a")])
        XCTAssertEqual(index.entries.map(\.id), [a, c])
        XCTAssertTrue(index.add(entry(b, "b")))
        XCTAssertFalse(index.add(entry(b, "b again")), "one entry per identity (Spec 1 §4)")
        XCTAssertEqual(index.entries.map(\.id), [a, b, c])
        index.entries.append(entry(d, "d"))
        index.entries.insert(entry(e, "e"), at: 0)
        XCTAssertEqual(index.entries.map(\.id), [a, b, c, d, e])
        for id in [a, b, c, d, e] { XCTAssertEqual(index.entry(id)?.id, id) }
        XCTAssertNil(index.entry(Self.id("f")))
        var local = MediaLocalIndex(entries: [entry(d, "d"), entry(b, "b")])
        local.entries.append(entry(a, "a"))
        XCTAssertEqual(local.entries.map(\.id), [a, b, d])
        XCTAssertEqual(local.entry(a)?.path, "a")
    }

    // MARK: - Locations (Spec 8 §2)

    func test_locationsNeverLeaveTheirFolder() {
        XCTAssertNotNil(MediaLocation(.mediaRoot, "backgrounds/dawn.mp4"))
        XCTAssertNotNil(MediaLocation(.absolute, "/Users/Shared/Media/clip.mov"))
        for bad in ["", "/backgrounds/dawn.mp4", "../dawn.mp4", "a/../../b.mov", "a//b.mov", "./a.mov", "a/", "a/./b.mov"] {
            XCTAssertNil(MediaLocation(.mediaRoot, bad), bad)
            XCTAssertNil(MediaLocation(.machineMedia, bad), bad)
        }
        for bad in ["", "relative.mov", "/Users/../etc/x", "/Users//x", "/"] {
            XCTAssertNil(MediaLocation(.absolute, bad), bad)
        }
        XCTAssertEqual(MediaLocation.override("/Users/Shared/x.png")?.folder, .absolute)
        XCTAssertEqual(MediaLocation.override("fast/x.png"), MediaLocation(.machineMedia, "fast/x.png"))
        XCTAssertEqual(MediaLocation(.mediaRoot, "a/b/c.mov")?.parent, "a/b")
        XCTAssertEqual(MediaLocation(.mediaRoot, "a/b/c.mov")?.name, "c.mov")
    }

    // MARK: - Resolving an id (Spec 8 §2)

    /// "a library entry's `path` is relative to the media root; a
    /// machine-index entry's `path` is relative to `machine/media/`; an
    /// override ... is a path relative to `machine/media/`, or an absolute
    /// one, and wins over its entry's `path`."
    func test_libraryMachineAndOverrideLocations() {
        let library = MediaIndex(entries: [entry(a, "backgrounds/a.mov"), entry(b, "b.png", kind: .image), entry(c, "c.png", kind: .image)])
        let machine = MediaLocalIndex(entries: [entry(d, "local/d.png", kind: .image)],
                                      overrides: [b: "fast/b.png", c: "/Users/Shared/Media/c.png"])
        XCTAssertEqual(MediaResolver.resolve(a, library: library, machine: machine)?.location, MediaLocation(.mediaRoot, "backgrounds/a.mov"))
        XCTAssertEqual(MediaResolver.resolve(a, library: library, machine: machine)?.tier, .library)
        XCTAssertEqual(MediaResolver.resolve(d, library: library, machine: machine)?.location, MediaLocation(.machineMedia, "local/d.png"))
        XCTAssertEqual(MediaResolver.resolve(d, library: library, machine: machine)?.tier, .machine)
        let overridden = MediaResolver.resolve(b, library: library, machine: machine)
        XCTAssertEqual(overridden?.location, MediaLocation(.machineMedia, "fast/b.png"))
        XCTAssertEqual(overridden?.tier, .library, "an override moves the file, not the entry")
        XCTAssertEqual(overridden?.overridden, true)
        XCTAssertEqual(MediaResolver.resolve(c, library: library, machine: machine)?.location, MediaLocation(.absolute, "/Users/Shared/Media/c.png"))
        XCTAssertNil(MediaResolver.resolve(e, library: library, machine: machine), "an id neither index holds")
    }

    /// Spec 1 §7 — "Resolve an id in the machine index first, then the library index."
    func test_theMachineIndexAnswersFirst() {
        let library = MediaIndex(entries: [entry(a, "lib/a.mov")])
        let machine = MediaLocalIndex(entries: [entry(a, "mine/a.mov")])
        let resolved = MediaResolver.resolve(a, library: library, machine: machine)
        XCTAssertEqual(resolved?.tier, .machine)
        XCTAssertEqual(resolved?.location, MediaLocation(.machineMedia, "mine/a.mov"))
    }

    /// "An id first follows the `replaced` maps, the machine index's and then
    /// the library's, whether or not an index still holds an entry for it,
    /// until it reaches an id neither maps."
    func test_theChainFollowsBothMapsToTheEnd() {
        let library = MediaIndex(entries: [entry(d, "d.mov")], replaced: [a: b, c: d, b: e])
        let machine = MediaLocalIndex(replaced: [b: c])
        let chain = MediaResolver.chain(from: a, library: library, machine: machine)
        XCTAssertEqual(chain.ids, [a, b, c, d], "the machine's b → c wins over the library's b → e")
        XCTAssertNil(chain.loop)
        XCTAssertEqual(MediaResolver.resolve(a, library: library, machine: machine)?.id, d)
        XCTAssertEqual(MediaResolver.resolve(a, library: library, machine: machine)?.chain.ids, [a, b, c, d])
        XCTAssertNil(MediaResolver.resolve(a, library: library, machine: nil), "without the machine's map the chain ends at e, which no index holds")
    }

    /// Spec 8 §11 — "Eight weekly re-exports in place still resolve from the
    /// first id to the last", past the eight steps `main` allowed.
    func test_eightWeeklyReExportsResolveFromTheFirstToTheLast() {
        let weeks = (0...9).map { Self.id(Character(String($0))) }
        var replaced: [String: String] = [:]
        for (old, new) in zip(weeks, weeks.dropFirst()) { replaced[old] = new }
        let library = MediaIndex(entries: [entry(weeks[9], "welcome.mov")], replaced: replaced)
        let resolved = MediaResolver.resolve(weeks[0], library: library, machine: MediaLocalIndex())
        XCTAssertEqual(resolved?.id, weeks[9])
        XCTAssertEqual(resolved?.chain.ids, weeks)
    }

    /// "A chain that comes back to an id it has passed stops at the id before
    /// the repeat, and the reference report names the loop".
    func test_aLoopStopsAtTheIdBeforeTheRepeat() {
        let library = MediaIndex(entries: [entry(a, "a"), entry(b, "b"), entry(c, "c")], replaced: [a: b, b: c, c: a])
        let fromA = MediaResolver.chain(from: a, library: library, machine: nil)
        XCTAssertEqual(fromA.ids, [a, b, c])
        XCTAssertEqual(fromA.loop, [a, b, c])
        XCTAssertEqual(MediaResolver.resolve(a, library: library, machine: nil)?.id, c)
        XCTAssertEqual(MediaResolver.resolve(b, library: library, machine: nil)?.id, a)
        let selfMap = MediaIndex(entries: [entry(a, "a")], replaced: [a: a])
        XCTAssertEqual(MediaResolver.chain(from: a, library: selfMap, machine: nil).ids, [a])
        XCTAssertEqual(MediaResolver.chain(from: a, library: selfMap, machine: nil).loop, [a])
    }

    // MARK: - Present or missing (Spec 8 §2)

    func test_presenceComesFromTheHashKnownForTheLocation() {
        let library = MediaIndex(entries: [entry(a, "a.mov"), entry(b, "", deletedAt: "2026-11-11T09:00:00Z"), entry(c, "")])
        let resolved = MediaResolver.resolve(a, library: library, machine: nil)
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .holds(self.a) }), .ok)
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .holds(self.d) }), .missing,
                       "an entry whose location holds other bytes is missing")
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .absent }), .missing)
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .unhashed }), .ok,
                       "a file not hashed yet counts present (answer of 2026-11-11)")
        XCTAssertEqual(MediaResolver.presence(MediaResolver.resolve(b, library: library, machine: nil), state: { _ in .holds(self.b) }), .deleted)
        XCTAssertEqual(MediaResolver.presence(MediaResolver.resolve(c, library: library, machine: nil), state: { _ in .unhashed }), .missing,
                       "an entry another file took the place of has no location")
        XCTAssertEqual(MediaResolver.presence(nil, state: { _ in .unhashed }), .missing)
    }

    /// "A slide's id is its embedded uuid, so a slide is present when the file
    /// at its location parses and carries that uuid."
    func test_aSlideIsPresentByItsUuid() {
        let slide = "slide:51de0000-0000-4000-8000-000000000001"
        let library = MediaIndex(entries: [entry(slide, "slides/welcome.oslide", kind: .slide)])
        let resolved = MediaResolver.resolve(slide, library: library, machine: nil)
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .holds(slide) }), .ok)
        XCTAssertEqual(MediaResolver.presence(resolved, state: { _ in .holds("slide:51de0000-0000-4000-8000-000000000002") }), .missing)
    }

    /// Spec 3 §6's `missing` as Spec 8 §2 works it out: every id the indexes
    /// name whose resolution isn't present, a replaced id included.
    func test_theMissingSetCoversEntriesAndReplacedIds() {
        let library = Library(mediaIndex: MediaIndex(entries: [entry(a, "a.mov"), entry(b, "b.mov"), entry(c, "", deletedAt: "2026-11-11T09:00:00Z")],
                                                     replaced: [d: a, e: b]))
        let files: [MediaLocation: MediaFileState] = [MediaLocation(.mediaRoot, "a.mov")!: .holds(a)]
        let missing = MediaResolver.missingIds(library: library, machine: nil, state: { files[$0] ?? .absent })
        XCTAssertEqual(missing, [b, c, e], "b's file is absent, c is deleted, and e resolves to b; d resolves to a, which is there")
    }

    // MARK: - Where media may live (Spec 8 §2, choice M-8)

    func test_mediaLivesOnTheStartupVolumeOutsideTheGuardedFolders() {
        let places = MediaPlaces(home: "/Users/av", isOnStartupVolume: { !$0.hasPrefix("/Users/av/elsewhere") })
        XCTAssertNil(places.problem(with: "/Users/av/Project O/library/media"))
        XCTAssertNil(places.problem(with: "/Users/Shared/Media"))
        XCTAssertNil(places.problem(with: "/Users/av/DesktopArchive/media"), "a name that only starts like a guarded folder")
        XCTAssertEqual(places.problem(with: "/Users/av/Desktop/media"), .guardedFolder("Desktop"))
        XCTAssertEqual(places.problem(with: "/Users/av/documents"), .guardedFolder("Documents"), "names compare without regard to case")
        XCTAssertEqual(places.problem(with: "/Users/av/Downloads/new/clip.mov"), .guardedFolder("Downloads"))
        XCTAssertEqual(places.problem(with: "/Volumes/Media/library"), .otherVolume)
        XCTAssertEqual(places.problem(with: "/net/server/share"), .otherVolume)
        XCTAssertEqual(places.problem(with: "/Network/Servers/x"), .otherVolume)
        XCTAssertEqual(places.problem(with: "/Users/av/elsewhere/media"), .otherVolume, "what the volume facts say")
        XCTAssertEqual(places.problem(with: "../library/media"), .notAbsolute)
    }
}
