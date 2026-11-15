import Foundation
import XCTest
@testable import OCore

/// Spec 8 §4 — the walk's rules, pure: what it does with each file it finds,
/// against both indexes and what it found last time. Spec 8 §11, The walk:
/// "A move keeps the defaults. A file exported over an item becomes a new
/// item with its defaults, and the old id's cues play it, also when an
/// identical copy of the old file sits elsewhere in the media root; a stall
/// mid-export still ends with the old id resolving to the finished file. A
/// file restored over the export, from one version back or several, makes no
/// loop, and cues naming any version play it. A file renamed away and a new
/// one saved under its name is a move and a new item. Eight weekly
/// re-exports in place still resolve from the first id to the last ...
/// Identical copies are one entry. A vanished file leaves its entry missing
/// with its defaults. A deleted file put back from the Trash brings its item
/// back ... A file whose id the other folder's index holds is left alone and
/// reported. On a `readOnlyMasters` machine nothing in the library is
/// written, and an unlisted file in the media root is left alone."
/// (The walks that run at launch, on `media rebuild` and from the watcher,
/// the settle, the skips and the cache's spared hash are the engine's tests.)
final class MediaWalkTests: XCTestCase {
    static func id(_ c: Character) -> String { "sha256:" + String(repeating: String(c), count: 64) }
    static func id(_ n: Int) -> String { "sha256:" + String(repeating: "0", count: 56) + String(format: "%08x", n) }

    static let now = "2026-11-11T12:00:00Z"
    static let video = MediaMetadata(kind: .video, durationMs: 10_000, fps: FrameRate(num: 30), width: 64, height: 36, codec: "avc1")
    static let defaults = MediaDefaults(trimInMs: 1500, trimOutMs: 9000, loop: true, gain: -3, grade: nil, syncOffsetMs: 40, defaultChannel: 1)

    static func loc(_ path: String, _ folder: MediaFolder = .mediaRoot) -> MediaLocation {
        MediaLocation(folder, path) ?? MediaLocation(folder, "invalid")!
    }

    /// A settled file the walk found and read.
    static func file(_ id: String, size: Int = 100, modified: String = "2026-11-11T09:00:00.000000000Z",
                     read: MediaRead? = .media(MediaWalkTests.video)) -> MediaFound {
        .file(MediaFoundFile(id: id, size: size, modified: modified, read: read))
    }

    static func entry(_ id: String, _ path: String, defaults: MediaDefaults = MediaDefaults(), deletedAt: String? = nil) -> MediaEntry {
        MediaEntry(id: id, path: path, kind: .video, size: 100, durationMs: 10_000, fps: FrameRate(num: 30), width: 64, height: 36,
                   codec: "avc1", defaults: defaults, addedAt: "2026-11-01T09:00:00Z", deletedAt: deletedAt)
    }

    /// A machine's indexes and cache, walked again and again.
    struct World {
        var library = MediaIndex()
        var machine = MediaLocalIndex()
        var cache = MediaCache()
        var writable = true
        var last: MediaWalk.Result?

        @discardableResult
        mutating func walk(_ found: [MediaLocation: MediaFound], overrides: Set<MediaLocation> = [],
                           folders: Set<MediaFolder> = [.mediaRoot, .machineMedia]) -> MediaWalk.Result {
            let result = MediaWalk.plan(MediaWalk.Input(library: library, machine: machine, libraryWritable: writable, found: found,
                                                        folders: folders, overrideTargets: overrides, cache: cache, now: MediaWalkTests.now))
            library = result.library
            machine = result.machine
            cache = result.cache
            last = result
            return result
        }

        func resolved(_ id: String) -> String? {
            MediaResolver.resolve(id, library: library, machine: machine)?.id
        }

        /// Spec 8 §2 — the presence of what `id` resolves to, given what was found.
        func presence(_ id: String, _ found: [MediaLocation: MediaFound]) -> MediaPresence {
            MediaResolver.presence(MediaResolver.resolve(id, library: library, machine: machine), state: { found[$0]?.state ?? .absent })
        }
    }

    let a = id("a"), b = id("b"), c = id("c"), d = id("d"), n = id("e")

    // MARK: - Left alone, and new ids

    func test_aFileAtItsEntrysPathIsLeftAloneAndRecorded() {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "backgrounds/a.mov", defaults: Self.defaults)])
        let before = world.library
        let result = world.walk([Self.loc("backgrounds/a.mov"): Self.file(a, read: nil)])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(world.library, before)
        XCTAssertEqual(world.cache.record(at: Self.loc("backgrounds/a.mov"))?.hash, a)
    }

    /// "A new id at a path no entry holds is a new entry with empty defaults."
    func test_aNewIdIsANewEntryWithEmptyDefaults() throws {
        var world = World()
        let result = world.walk([Self.loc("imports/Welcome.mov"): Self.file(a)])
        XCTAssertEqual(result.changes, [.added(id: a, tier: .library, location: Self.loc("imports/Welcome.mov"))])
        let made = try XCTUnwrap(world.library.entry(a))
        XCTAssertEqual(made.path, "imports/Welcome.mov")
        XCTAssertEqual(made.folder, "imports")
        XCTAssertEqual(made.defaults, MediaDefaults())
        XCTAssertEqual(made.addedAt, Self.now)
        XCTAssertEqual(made.kind, .video)
        XCTAssertEqual(made.durationMs, 10_000)
        XCTAssertEqual(made.codec, "avc1")
        XCTAssertNil(made.poster, "the poster comes with Stop 3's extraction")
        // In machine/media/, a machine entry.
        let local = world.walk([Self.loc("imports/Welcome.mov"): Self.file(a), Self.loc("Local.mov", .machineMedia): Self.file(b)])
        XCTAssertEqual(local.changes, [.added(id: b, tier: .machine, location: Self.loc("Local.mov", .machineMedia))])
        XCTAssertEqual(world.machine.entry(b)?.path, "Local.mov")
    }

    /// Spec 8 §11 — "Identical copies are one entry."
    func test_identicalCopiesAreOneEntry() {
        var world = World()
        let result = world.walk([Self.loc("b/copy.mov"): Self.file(a), Self.loc("a/first.mov"): Self.file(a)])
        XCTAssertEqual(world.library.entries.map(\.path), ["a/first.mov"])
        XCTAssertEqual(result.notes, [.copy(id: a, location: Self.loc("b/copy.mov"))])
        let again = world.walk([Self.loc("b/copy.mov"): Self.file(a), Self.loc("a/first.mov"): Self.file(a)])
        XCTAssertEqual(again.changes, [])
        XCTAssertEqual(again.notes, [.copy(id: a, location: Self.loc("b/copy.mov"))], "the other copy is reported at every walk")
    }

    // MARK: - Moves

    /// Spec 8 §11 — "A move keeps the defaults."
    func test_aMoveKeepsTheDefaults() throws {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "old/a.mov", defaults: Self.defaults)])
        world.walk([Self.loc("old/a.mov"): Self.file(a, read: nil)])
        let result = world.walk([Self.loc("new/renamed.mov"): Self.file(a, read: nil)])
        XCTAssertEqual(result.changes, [.moved(id: a, tier: .library, from: "old/a.mov", location: Self.loc("new/renamed.mov"))])
        let moved = try XCTUnwrap(world.library.entry(a))
        XCTAssertEqual(moved.path, "new/renamed.mov")
        XCTAssertEqual(moved.folder, "new")
        XCTAssertEqual(moved.defaults, Self.defaults)
        XCTAssertEqual(world.library.replaced, [:])
        XCTAssertEqual(result.remapped, [], "a move maps nothing")
    }

    /// Spec 8 §11 — "A file renamed away and a new one saved under its name is
    /// a move and a new item", also while the new one is still being written.
    func test_aFileRenamedAwayAndANewOneSavedUnderItsName() {
        for slowSave in [false, true] {
            var world = World()
            world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults)])
            world.walk([Self.loc("Welcome.mov"): Self.file(a, read: nil)])
            if slowSave {
                let first = world.walk([Self.loc("Welcome old.mov"): Self.file(a, read: nil), Self.loc("Welcome.mov"): .pending])
                XCTAssertEqual(first.changes, [.moved(id: a, tier: .library, from: "Welcome.mov", location: Self.loc("Welcome old.mov"))])
            }
            world.walk([Self.loc("Welcome old.mov"): Self.file(a, read: nil), Self.loc("Welcome.mov"): Self.file(n)])
            XCTAssertEqual(world.library.entry(a)?.path, "Welcome old.mov", "slow save \(slowSave)")
            XCTAssertEqual(world.library.entry(a)?.defaults, Self.defaults)
            XCTAssertEqual(world.library.entry(n)?.path, "Welcome.mov")
            XCTAssertEqual(world.library.entry(n)?.defaults, MediaDefaults(), "a new item, not a re-export")
            XCTAssertEqual(world.library.replaced, [:])
        }
    }

    // MARK: - Landings (choice M-2)

    /// Spec 8 §11 — "A file exported over an item becomes a new item with its
    /// defaults, and the old id's cues play it".
    func test_aReExportBecomesANewItemWithTheOldDefaults() throws {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults)])
        world.walk([Self.loc("Welcome.mov"): Self.file(a, read: nil)])
        let found: [MediaLocation: MediaFound] = [Self.loc("Welcome.mov"): Self.file(n)]
        let result = world.walk(found)
        XCTAssertEqual(result.changes, [.landed(old: a, new: n, tier: .library, location: Self.loc("Welcome.mov"))])
        XCTAssertEqual(world.library.entry(a)?.path, "", "the old entry is pathless, so missing")
        XCTAssertEqual(world.library.entry(a)?.defaults, Self.defaults, "and keeps its defaults")
        XCTAssertEqual(world.library.replaced, [a: n])
        let made = try XCTUnwrap(world.library.entry(n))
        XCTAssertEqual(made.path, "Welcome.mov")
        XCTAssertEqual(made.defaults, Self.defaults, "the re-export takes the old item's defaults")
        XCTAssertEqual(world.resolved(a), n, "the old id's cues play it")
        XCTAssertEqual(world.presence(a, found), .ok)
        XCTAssertEqual(result.remapped, [a])
    }

    /// "... also when an identical copy of the old file sits elsewhere in the
    /// media root; a stall mid-export still ends with the old id resolving to
    /// the finished file."
    func test_aReExportWithACopyElsewhereAndAStallMidExport() throws {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults)])
        let copy = Self.loc("Backup/Welcome copy.mov")
        let first = world.walk([Self.loc("Welcome.mov"): Self.file(a, read: nil), copy: Self.file(a, read: nil)])
        XCTAssertEqual(first.notes, [.copy(id: a, location: copy)])
        // The export starts over the old file and stalls: nothing changes, and the copy isn't taken.
        let stalled = world.walk([Self.loc("Welcome.mov"): .pending, copy: Self.file(a, read: nil)])
        XCTAssertEqual(stalled.changes, [])
        XCTAssertEqual(world.library.entry(a)?.path, "Welcome.mov")
        // A stall long enough that the half-written file read as a video: it lands, and then the finished file does.
        world.walk([Self.loc("Welcome.mov"): Self.file(b, size: 40), copy: Self.file(a, read: nil)])
        XCTAssertEqual(world.resolved(a), b)
        let found: [MediaLocation: MediaFound] = [Self.loc("Welcome.mov"): Self.file(n, size: 200), copy: Self.file(a, read: nil)]
        world.walk(found)
        XCTAssertEqual(world.resolved(a), n, "the old id resolves to the finished file")
        XCTAssertEqual(world.resolved(b), n)
        XCTAssertEqual(world.library.entry(n)?.defaults, Self.defaults)
        XCTAssertEqual(world.library.entry(a)?.path, "Backup/Welcome copy.mov", "the old entry took its copy's path once landed on")
        XCTAssertEqual(world.presence(a, found), .ok)
    }

    /// "A file restored over the export, from one version back or several,
    /// makes no loop, and cues naming any version play it."
    func test_aFileRestoredOverTheExportMakesNoLoop() {
        for back in 1...3 {
            var world = World()
            let versions = (0...3).map { Self.id($0 + 1) }
            world.library = MediaIndex(entries: [Self.entry(versions[0], "Welcome.mov", defaults: Self.defaults)])
            for version in versions {
                world.walk([Self.loc("Welcome.mov"): Self.file(version, read: version == versions[0] ? nil : .media(Self.video))])
            }
            let restored = versions[3 - back]
            let result = world.walk([Self.loc("Welcome.mov"): Self.file(restored, read: nil)])
            XCTAssertTrue(result.changes.contains(.landed(old: versions[3], new: restored, tier: .library, location: Self.loc("Welcome.mov"))))
            for version in versions {
                let chain = MediaResolver.chain(from: version, library: world.library, machine: world.machine)
                XCTAssertNil(chain.loop, "\(back) back: \(version)")
                XCTAssertEqual(world.resolved(version), restored, "\(back) back: cues naming \(version) play the restored file")
            }
            XCTAssertNil(world.library.replaced[restored], "the restored id lost the mapping that left it")
            XCTAssertEqual(world.library.entry(restored)?.path, "Welcome.mov")
            XCTAssertEqual(world.library.entry(restored)?.defaults, Self.defaults)
        }
    }

    /// Spec 8 §11 — "Eight weekly re-exports in place still resolve from the
    /// first id to the last", each taking the defaults before it.
    func test_eightWeeklyReExportsInPlace() {
        var world = World()
        let weeks = (0...8).map { Self.id($0 + 100) }
        world.library = MediaIndex(entries: [Self.entry(weeks[0], "Announcements.mov", defaults: Self.defaults)])
        for (week, id) in weeks.enumerated() {
            world.walk([Self.loc("Announcements.mov"): Self.file(id, read: week == 0 ? nil : .media(Self.video))])
        }
        XCTAssertEqual(world.resolved(weeks[0]), weeks[8])
        XCTAssertEqual(MediaResolver.chain(from: weeks[0], library: world.library, machine: world.machine).ids, weeks)
        XCTAssertEqual(world.library.entry(weeks[8])?.defaults, Self.defaults)
    }

    /// A landing over an entry that already has a mapping (it took its copy's
    /// path after an earlier landing) replaces that mapping.
    func test_aLandingOverAMappedEntryReplacesItsMapping() {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults)])
        let copy = Self.loc("Welcome copy.mov")
        world.walk([Self.loc("Welcome.mov"): Self.file(a, read: nil), copy: Self.file(a, read: nil)])
        world.walk([Self.loc("Welcome.mov"): Self.file(n), copy: Self.file(a, read: nil)])
        XCTAssertEqual(world.library.replaced[a], n)
        XCTAssertEqual(world.library.entry(a)?.path, copy.path)
        world.walk([Self.loc("Welcome.mov"): Self.file(n, read: nil), copy: Self.file(c)])
        XCTAssertEqual(world.library.replaced[a], c, "saved over where the item's file was")
        XCTAssertEqual(world.library.entry(c)?.defaults, Self.defaults)
    }

    // MARK: - Vanished, deleted, the other folder, read-only

    /// Spec 8 §11 — "A vanished file leaves its entry missing with its defaults."
    func test_aVanishedFileLeavesItsEntryMissingWithItsDefaults() {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults)])
        let before = world.library
        let result = world.walk([:])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(world.library, before)
        XCTAssertEqual(world.presence(a, [:]), .missing)
    }

    /// Spec 8 §11 — "A deleted file put back from the Trash brings its item
    /// back" (its undo step is Area 12's): anywhere in its own folder, with
    /// its defaults.
    func test_aDeletedFilePutBackBringsItsItemBack() throws {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "", defaults: Self.defaults, deletedAt: "2026-11-10T09:00:00Z")])
        let found: [MediaLocation: MediaFound] = [Self.loc("Put back/Welcome.mov"): Self.file(a, read: nil)]
        XCTAssertEqual(world.presence(a, found), .deleted)
        let result = world.walk(found)
        XCTAssertEqual(result.changes, [.broughtBack(id: a, tier: .library, location: Self.loc("Put back/Welcome.mov"))])
        let back = try XCTUnwrap(world.library.entry(a))
        XCTAssertNil(back.deletedAt)
        XCTAssertEqual(back.path, "Put back/Welcome.mov")
        XCTAssertEqual(back.defaults, Self.defaults)
        XCTAssertEqual(result.remapped, [a], "the walk names it for Area 12's undo steps")
        XCTAssertEqual(world.presence(a, found), .ok)
    }

    /// Spec 9 §2 — the engine log's `media` line is "an index change, with
    /// its operation and ids"; Spec 8 §2 — "The engine log records them, by
    /// id". Every kind of change names its operation, its id and its index,
    /// and none carries a path.
    func test_anIndexChangesRecordNamesItsOperationAndIdsAndNoPath() {
        let (a, n) = (Self.id("a"), Self.id("b"))
        let at = Self.loc("Private folder/Welcome.mov")
        let changes: [(MediaIndexChange, String, [String: JSONValue])] = [
            (.added(id: a, tier: .library, location: at), "added", [:]),
            (.moved(id: a, tier: .machine, from: "Old/Welcome.mov", location: at), "moved", [:]),
            (.landed(old: a, new: n, tier: .library, location: at), "landed", ["new": .string(n)]),
            (.unmapped(id: a, tier: .library, was: n), "unmapped", ["was": .string(n)]),
            (.broughtBack(id: a, tier: .library, location: at), "broughtBack", [:]),
            (.tookCopy(id: a, tier: .library, from: "Old/Welcome.mov", location: at), "tookCopy", [:]),
            (.metadata(id: a, tier: .library), "metadata", [:]),
            (.pruned(id: a, tier: .library), "pruned", [:]),
            (.poster(id: a, tier: .library, path: ".posters/aaaa-0.png"), "poster", ["made": .bool(true)]),
            (.poster(id: a, tier: .library, path: nil), "poster", ["made": .bool(false)]),
        ]
        for (change, op, more) in changes {
            var expected = more
            expected["op"] = .string(op)
            expected["id"] = .string(a)
            expected["index"] = .string(op == "moved" ? "machine" : "library")
            XCTAssertEqual(change.record, expected, op)
            XCTAssertFalse(JSONCanonical.line(.object(change.record)).contains("Welcome"), "\(op): no path")
            XCTAssertFalse(JSONCanonical.line(.object(change.record)).contains(".posters"), "\(op): no path")
        }
    }

    /// Spec 8 §11 — "A file whose id the other folder's index holds is left
    /// alone and reported", either way round.
    func test_aFileWhoseIdTheOtherFoldersIndexHoldsIsLeftAlone() {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "a.mov")])
        world.machine = MediaLocalIndex(entries: [Self.entry(b, "b.mov")])
        let result = world.walk([Self.loc("a.mov"): Self.file(a, read: nil), Self.loc("b.mov", .machineMedia): Self.file(b, read: nil),
                                 Self.loc("from-the-machine.mov"): Self.file(b, read: nil), Self.loc("from-the-library.mov", .machineMedia): Self.file(a, read: nil)])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(Set(result.notes), [.otherFolder(id: b, location: Self.loc("from-the-machine.mov")),
                                           .otherFolder(id: a, location: Self.loc("from-the-library.mov", .machineMedia))])
        XCTAssertEqual(world.library.entries.map(\.id), [a])
        XCTAssertEqual(world.machine.entries.map(\.id), [b])
        // Nor does it land over an entry: that entry's file is gone.
        let landed = world.walk([Self.loc("a.mov"): Self.file(b, read: nil)])
        XCTAssertEqual(landed.changes, [])
        XCTAssertEqual(world.library.replaced, [:])
        XCTAssertEqual(world.presence(a, [Self.loc("a.mov"): Self.file(b, read: nil)]), .missing)
    }

    /// Spec 8 §11 — "On a `readOnlyMasters` machine nothing in the library is
    /// written, and an unlisted file in the media root is left alone"; its
    /// own folder is indexed.
    func test_onAReadOnlyMachineNothingInTheLibraryIsWritten() {
        var world = World()
        world.writable = false
        world.library = MediaIndex(entries: [Self.entry(a, "Welcome.mov", defaults: Self.defaults),
                                             Self.entry(d, "", defaults: Self.defaults, deletedAt: "2026-11-10T09:00:00Z")])
        let before = world.library
        let result = world.walk([Self.loc("Welcome.mov"): Self.file(n), Self.loc("unlisted.mov"): Self.file(b),
                                 Self.loc("put back.mov"): Self.file(d, read: nil), Self.loc("moved/Welcome.mov"): Self.file(a, read: nil),
                                 Self.loc("Local.mov", .machineMedia): Self.file(c)])
        XCTAssertEqual(world.library, before)
        XCTAssertEqual(result.changes, [.added(id: c, tier: .machine, location: Self.loc("Local.mov", .machineMedia))])
        XCTAssertEqual(world.machine.entry(c)?.path, "Local.mov")
        XCTAssertEqual(world.cache.record(at: Self.loc("unlisted.mov"))?.hash, b, "its cache is kept")
    }

    // MARK: - Skips, kinds, metadata and the cache

    /// Spec 8 §4 — "the walk never treats their files as entries": an
    /// override's target is neither an entry nor a copy, and the cache keeps it.
    func test_overrideTargetsAreSkippedAndCached() {
        var world = World()
        world.library = MediaIndex(entries: [Self.entry(a, "backgrounds/cross.png")])
        world.machine = MediaLocalIndex(overrides: [a: "cross-fast.png"])
        let target = Self.loc("cross-fast.png", .machineMedia)
        let result = world.walk([target: Self.file(a, read: nil)], overrides: [target])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.notes, [])
        XCTAssertEqual(world.cache.record(at: target)?.hash, a)
    }

    /// Spec 8 §4 — "kinds v1 doesn't take, which the reference report lists".
    func test_kindsV1DoesntTakeAreReportedNotIndexed() {
        var world = World()
        let result = world.walk([Self.loc("notes.txt"): Self.file(a, read: .unsupported("plain text"))])
        XCTAssertEqual(result.changes, [])
        XCTAssertEqual(result.notes, [.unsupported(location: Self.loc("notes.txt"), format: "plain text")])
        XCTAssertEqual(world.cache.record(at: Self.loc("notes.txt"))?.hash, a)
    }

    /// Spec 8 §4 — "The walk ... reads missing metadata."
    func test_theWalkReadsMissingMetadata() throws {
        var world = World()
        var bare = Self.entry(a, "a.mov")
        bare.durationMs = nil
        bare.codec = nil
        world.library = MediaIndex(entries: [bare])
        let result = world.walk([Self.loc("a.mov"): Self.file(a)])
        XCTAssertEqual(result.changes, [.metadata(id: a, tier: .library)])
        XCTAssertEqual(world.library.entry(a)?.durationMs, 10_000)
        XCTAssertEqual(world.library.entry(a)?.codec, "avc1")
    }

    /// Spec 8 §11 — "the same path in both folders keeps two records"; a folder
    /// the walk didn't read keeps its records.
    func test_theCacheKeepsARecordPerLocation() {
        var world = World()
        world.walk([Self.loc("a.mov"): Self.file(a), Self.loc("a.mov", .machineMedia): Self.file(b)])
        XCTAssertEqual(world.cache.records.count, 2)
        XCTAssertEqual(world.cache.record(at: Self.loc("a.mov"))?.hash, a)
        XCTAssertEqual(world.cache.record(at: Self.loc("a.mov", .machineMedia))?.hash, b)
        world.walk([Self.loc("c.mov", .machineMedia): Self.file(c)], folders: [.machineMedia])
        XCTAssertEqual(world.cache.record(at: Self.loc("a.mov"))?.hash, a, "the media root wasn't read")
        XCTAssertNil(world.cache.record(at: Self.loc("a.mov", .machineMedia)))
        XCTAssertEqual(world.library.entry(a)?.path, "a.mov")
    }

    // MARK: - Properties

    /// Walking again what a walk left changes nothing; no walk makes a loop;
    /// and the result never depends on the order the files were found in
    /// (the input is keyed by location, so the rules run in path order).
    func test_walkingAgainChangesNothingAndNoLoopForms() {
        var generator = SplitMix(seed: 0x8_2026)
        let ids = (0..<6).map { Self.id($0 + 500) }
        let paths = ["a.mov", "b.mov", "c/d.mov", "c/e.mov", "f.mov"]
        var exercised: Set<String> = []
        defer {
            XCTAssertEqual(exercised, ["added", "moved", "landed", "unmapped", "broughtBack", "tookCopy"],
                           "the random walks exercised every rule that changes an index")
        }
        for round in 0..<400 {
            var world = World()
            world.writable = generator.next() % 4 != 0
            var free = paths
            for id in ids where generator.next() % 2 == 0 {
                let deleted = generator.next() % 6 == 0 || free.isEmpty
                let path = deleted ? "" : free.remove(at: Int(generator.next() % UInt64(free.count)))
                world.library.add(Self.entry(id, path, deletedAt: deleted ? "2026-11-01T00:00:00Z" : nil))
            }
            for _ in 0..<3 {
                var found: [MediaLocation: MediaFound] = [:]
                for path in paths where generator.next() % 3 != 0 {
                    let pending = generator.next() % 7 == 0
                    found[Self.loc(path)] = pending ? .pending : Self.file(ids[Int(generator.next() % 6)])
                }
                for change in world.walk(found).changes {
                    exercised.insert(String(String(describing: change).prefix { $0 != "(" }))
                }
                let again = world.walk(found)
                XCTAssertEqual(again.changes, [], "round \(round): walking again changed \(again.changes)")
                for id in MediaResolver.knownIds(library: world.library, machine: world.machine) {
                    XCTAssertNil(MediaResolver.chain(from: id, library: world.library, machine: world.machine).loop, "round \(round)")
                }
                for e in world.library.entries where !e.path.isEmpty {
                    XCTAssertEqual(world.library.entries.filter { $0.path == e.path && !$0.isDeleted }.count, 1, "round \(round): one entry per path")
                }
            }
        }
    }
}

/// A small deterministic generator for the property test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
