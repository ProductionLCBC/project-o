import Foundation
import XCTest
@testable import OCore

/// Spec 8 §3 — import's rules, pure: "Hash first (M4)", "Where an import
/// goes", numbered names, and the result joining the index. Spec 8 §11,
/// Import: "A known hash isn't copied and comes back `known`; a replaced hash
/// resolves to its replacement; a missing or deleted item's own hash brings it
/// back. A name that a file or another entry holds, a missing entry included,
/// gets a numbered name. ... Each row of §3's table holds, on both kinds of
/// machine." Spec 8 §4 — the launch's presence and the launch walk's pruning.
final class MediaImportTests: XCTestCase {
    typealias W = MediaWalkTests
    let a = W.id("a"), b = W.id("b"), c = W.id("c"), n = W.id("e")

    func decide(_ id: String, writable: Bool, library: MediaIndex, machine: MediaLocalIndex = MediaLocalIndex(),
                missing: Set<String> = []) -> MediaImport.Decision {
        MediaImport.decide(id: id, libraryWritable: writable, library: library, machine: machine,
                           presence: { missing.contains($0) ? .missing : .ok })
    }

    // MARK: - Where an import goes (§3's table), from outside both folders

    func test_fromOutsideANewIdIsCopiedIntoTheFolderTheMachineWrites() {
        XCTAssertEqual(decide(n, writable: true, library: MediaIndex()), .copy(into: .mediaRoot, tier: .library, bringsBack: nil),
                       "writable: copied into the media root; a library entry")
        XCTAssertEqual(decide(n, writable: false, library: MediaIndex()), .copy(into: .machineMedia, tier: .machine, bringsBack: nil),
                       "readOnlyMasters: copied into machine/media/; a machine entry")
    }

    func test_aKnownHashIsntCopied() {
        let library = MediaIndex(entries: [W.entry(a, "a.mov")])
        let machine = MediaLocalIndex(entries: [W.entry(b, "b.mov")])
        for writable in [true, false] {
            XCTAssertEqual(decide(a, writable: writable, library: library, machine: machine), .known(a))
            XCTAssertEqual(decide(b, writable: writable, library: library, machine: machine), .known(b))
        }
    }

    func test_aReplacedHashResolvesToItsReplacement() {
        let library = MediaIndex(entries: [W.entry(a, ""), W.entry(b, "b.mov")], replaced: [a: b])
        for writable in [true, false] {
            XCTAssertEqual(decide(a, writable: writable, library: library), .known(b))
        }
        // Through the machine index's map too, and even when the replaced entry was pruned.
        let pruned = MediaIndex(entries: [W.entry(b, "b.mov")])
        XCTAssertEqual(decide(a, writable: true, library: pruned, machine: MediaLocalIndex(replaced: [a: b])), .known(b))
    }

    /// "A deleted or missing item's own hash brings the item back", and the
    /// table's last row: "The id of a missing or deleted library item".
    func test_aMissingOrDeletedItemsOwnHashBringsItBack() {
        let library = MediaIndex(entries: [W.entry(a, "gone.mov"), W.entry(b, "", deletedAt: "2026-11-10T09:00:00Z")])
        let machine = MediaLocalIndex(entries: [W.entry(c, "", deletedAt: "2026-11-10T09:00:00Z")])
        XCTAssertEqual(decide(a, writable: true, library: library, machine: machine, missing: [a]), .copy(into: .mediaRoot, tier: .library, bringsBack: a))
        XCTAssertEqual(decide(b, writable: true, library: library, machine: machine), .copy(into: .mediaRoot, tier: .library, bringsBack: b))
        XCTAssertEqual(decide(a, writable: false, library: library, machine: machine, missing: [a]), .refused(.readOnlyLibrary))
        XCTAssertEqual(decide(b, writable: false, library: library, machine: machine), .refused(.readOnlyLibrary))
        for writable in [true, false] {
            XCTAssertEqual(decide(c, writable: writable, library: library, machine: machine), .copy(into: .machineMedia, tier: .machine, bringsBack: c),
                           "a machine item comes back on either kind of machine")
        }
    }

    // MARK: - Numbered names (§3, step 4)

    func test_aNameAFileOrAnEntryHoldsGetsANumberedName() {
        func at(_ name: String, sub: String = "", folder: String = "imports", taken: Set<String>) -> String? {
            MediaImport.destination(name: name, subfolder: sub, importFolder: folder, folder: .mediaRoot, taken: taken)?.path
        }
        XCTAssertEqual(at("Welcome.mov", taken: []), "imports/Welcome.mov")
        XCTAssertEqual(at("Welcome.mov", taken: ["imports/Welcome.mov"]), "imports/Welcome 2.mov")
        XCTAssertEqual(at("Welcome.mov", taken: ["imports/welcome.MOV", "imports/Welcome 2.mov"]), "imports/Welcome 3.mov",
                       "compared without regard to case")
        XCTAssertEqual(at("README", taken: ["imports/README"]), "imports/README 2")
        XCTAssertEqual(at("archive.tar.gz", taken: ["imports/archive.tar.gz"]), "imports/archive.tar 2.gz", "before the last extension, as the Finder does")
        XCTAssertEqual(at("countdown.mov", sub: "Easter/Openers", taken: []), "imports/Easter/Openers/countdown.mov",
                       "a dropped folder keeps its subfolders under the import folder")
        XCTAssertEqual(at("a.mov", folder: "", taken: []), "a.mov")
        XCTAssertEqual(at("a.mov", folder: "../outside", taken: []), "a.mov", "an import folder that would leave its folder puts the file at the top")
        // "another entry's path holds even while its file is missing": the caller puts every entry path in `taken`.
        let library = MediaIndex(entries: [W.entry(a, "imports/Welcome.mov")])
        XCTAssertEqual(at("Welcome.mov", taken: Set(library.entries.map(\.path))), "imports/Welcome 2.mov")
    }

    // MARK: - Step 5: the result joins the index

    func test_aCopiedFileBecomesAnEntryWithEmptyDefaults() throws {
        var library = MediaIndex()
        var machine = MediaLocalIndex()
        let location = MediaLocation(.mediaRoot, "imports/Welcome.mov")!
        let copied = MediaImport.Copied(location: location, file: MediaFoundFile(id: n, size: 10, modified: "m"), metadata: W.video,
                                        tier: .library, bringsBack: nil)
        let (outcome, changes) = MediaImport.apply(copied, library: &library, machine: &machine, libraryWritable: true, presence: { _ in .ok }, now: W.now)
        XCTAssertEqual(outcome, .imported(n))
        XCTAssertEqual(changes, [.added(id: n, tier: .library, location: location)])
        let entry = try XCTUnwrap(library.entry(n))
        XCTAssertEqual(entry.defaults, MediaDefaults())
        XCTAssertEqual(entry.addedAt, W.now)
        XCTAssertEqual(entry.folder, "imports")
        XCTAssertEqual(entry.size, 10)
        // Indexed meanwhile by another change: it resolves to that item, and nothing is added.
        let again = MediaImport.apply(copied, library: &library, machine: &machine, libraryWritable: true, presence: { _ in .ok }, now: W.now)
        XCTAssertEqual(again.0, .known(n))
        XCTAssertEqual(again.1, [])
        // A library entry is never written on a readOnlyMasters machine.
        var empty = MediaIndex()
        XCTAssertEqual(MediaImport.apply(copied, library: &empty, machine: &machine, libraryWritable: false, presence: { _ in .ok }, now: W.now).0,
                       .refused(.readOnlyLibrary, nil))
    }

    func test_aBroughtBackItemKeepsItsDefaults() throws {
        var library = MediaIndex(entries: [W.entry(a, "", defaults: W.defaults, deletedAt: "2026-11-10T09:00:00Z")])
        var machine = MediaLocalIndex()
        let location = MediaLocation(.mediaRoot, "imports/Welcome.mov")!
        let copied = MediaImport.Copied(location: location, file: MediaFoundFile(id: a, size: 10, modified: "m"), metadata: nil,
                                        tier: .library, bringsBack: a)
        let (outcome, changes) = MediaImport.apply(copied, library: &library, machine: &machine, libraryWritable: true, presence: { _ in .missing }, now: W.now)
        XCTAssertEqual(outcome, .imported(a))
        XCTAssertEqual(changes, [.broughtBack(id: a, tier: .library, location: location)])
        let back = try XCTUnwrap(library.entry(a))
        XCTAssertNil(back.deletedAt)
        XCTAssertEqual(back.path, "imports/Welcome.mov")
        XCTAssertEqual(back.defaults, W.defaults)
    }

    // MARK: - Already in a folder: "Indexed where it is"

    func inPlace(_ found: MediaFound?, at location: MediaLocation, library: MediaIndex, machine: MediaLocalIndex = MediaLocalIndex(),
                 writable: Bool, missing: Set<String> = []) -> MediaImportOutcome? {
        let walk = MediaWalk.plan(MediaWalk.Input(library: library, machine: machine, libraryWritable: writable,
                                                  found: found.map { [location: $0] } ?? [:], now: W.now))
        return MediaImport.inPlaceOutcome(at: location, found: found, before: (library, machine), presentBefore: { !missing.contains($0) },
                                          walk: walk, libraryWritable: writable)
    }

    func test_aFileAlreadyInTheMediaRoot() {
        let here = MediaLocation(.mediaRoot, "Welcome.mov")!
        let listed = MediaIndex(entries: [W.entry(a, "Welcome.mov")])
        // Writable: indexed where it is; a library entry.
        XCTAssertEqual(inPlace(W.file(n), at: here, library: MediaIndex(), writable: true), .imported(n))
        XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: listed, writable: true), .known(a))
        // readOnlyMasters: "`known` if the library index lists it, otherwise refused with `notListed`".
        XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: listed, writable: false), .known(a))
        XCTAssertEqual(inPlace(W.file(n), at: here, library: MediaIndex(), writable: false), .refused(.notListed, nil))
        // The id of a missing library item: brought back on a writable machine, refused on a read-only one.
        let elsewhere = MediaIndex(entries: [W.entry(a, "gone/Welcome.mov")])
        XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: elsewhere, writable: true, missing: [a]), .imported(a))
        XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: elsewhere, writable: false, missing: [a]), .refused(.readOnlyLibrary, nil))
        // A replaced hash resolves to its replacement.
        let replaced = MediaIndex(entries: [W.entry(a, ""), W.entry(b, "b.mov")], replaced: [a: b])
        XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: replaced, writable: true, missing: [a]), .known(b))
    }

    func test_aFileAlreadyInMachineMedia() {
        let here = MediaLocation(.machineMedia, "Local.mov")!
        for writable in [true, false] {
            XCTAssertEqual(inPlace(W.file(n), at: here, library: MediaIndex(), writable: writable), .imported(n))
            XCTAssertEqual(inPlace(W.file(a, read: nil), at: here, library: MediaIndex(), machine: MediaLocalIndex(entries: [W.entry(a, "Local.mov")]),
                                   writable: writable), .known(a))
        }
    }

    func test_inPlaceRefusalsAndWaits() {
        let here = MediaLocation(.mediaRoot, "notes.txt")!
        XCTAssertEqual(inPlace(W.file(n, read: .unsupported("plain text")), at: here, library: MediaIndex(), writable: true),
                       .refused(.unsupported, "plain text"))
        XCTAssertNil(inPlace(.pending, at: here, library: MediaIndex(), writable: true), "a file still being written waits for a later walk")
        XCTAssertEqual(inPlace(nil, at: here, library: MediaIndex(), writable: true), .refused(.changed, nil), "a file that went")
    }

    // MARK: - Launch (Spec 8 §2, §4)

    /// "The hash is known from this machine's cache record for that location
    /// when the file's size and modification date match it, otherwise from the
    /// entry's own size and date when they match"; before the walk has hashed
    /// it, a file at its location counts present.
    func test_presenceAtLaunch() {
        var entry = W.entry(a, "a.mov")
        entry.size = 100
        entry.modified = "entry-date"
        let library = MediaIndex(entries: [entry, W.entry(b, "b.mov"), W.entry(c, "c.mov")])
        let machine = MediaLocalIndex(overrides: [c: "fast/c.mov"])
        let cache = MediaCache(records: [MediaCacheRecord(location: MediaLocation(.mediaRoot, "b.mov")!, size: 5, modified: "cached", hash: n)])
        let files: [MediaLocation: MediaFileStat] = [
            MediaLocation(.mediaRoot, "a.mov")!: MediaFileStat(size: 100, modified: "entry-date"),
            MediaLocation(.mediaRoot, "b.mov")!: MediaFileStat(size: 5, modified: "cached"),
            MediaLocation(.machineMedia, "fast/c.mov")!: MediaFileStat(size: 7, modified: "new"),
        ]
        let states = MediaLaunch.states(library: library, machine: machine, stat: { files[$0] }, cache: cache)
        XCTAssertEqual(states[MediaLocation(.mediaRoot, "a.mov")!], .holds(a), "the entry's own size and date")
        XCTAssertEqual(states[MediaLocation(.mediaRoot, "b.mov")!], .holds(n), "the cache names other bytes, so b is missing")
        XCTAssertEqual(states[MediaLocation(.machineMedia, "fast/c.mov")!], .unhashed, "the override's target, not hashed yet")
        XCTAssertNil(states[MediaLocation(.mediaRoot, "c.mov")!], "an overridden entry is read at its override")
        let missing = MediaResolver.missingIds(library: Library(mediaIndex: library), machine: Machine(mediaLocal: machine), state: { states[$0] ?? .absent })
        XCTAssertEqual(missing, [b])
        XCTAssertEqual(MediaLaunch.states(library: library, machine: machine, stat: { _ in nil }, cache: cache).values.filter { $0 == .absent }.count, 3)
    }

    /// Spec 8 §11 — "Pathless, unnamed replaced entries are pruned by the
    /// launch walk only, and their ids still resolve."
    func test_theLaunchPrunesPathlessUnnamedReplacedEntriesOnly() {
        var library = MediaIndex(entries: [
            W.entry(a, ""),                   // replaced, pathless, unnamed: pruned
            W.entry(b, "b.mov"),              // the replacement
            W.entry(c, ""),                   // replaced, pathless, but named: kept
            W.entry(n, "gone.mov"),           // replaced, file gone, unnamed: pruned
        ], replaced: [a: b, c: b, n: b])
        library.entries[0].poster = ".posters/a-0.png"
        let machine = MediaLocalIndex(entries: [W.entry(W.id("f"), "")], replaced: [W.id("f"): b])
        let stateOf: (MediaLocation) -> MediaFileState = { $0.path == "b.mov" ? .holds(self.b) : .absent }
        let result = MediaLaunch.prune(library: library, machine: machine, libraryWritable: true, state: stateOf, named: [c])
        XCTAssertEqual(result.library.entries.map(\.id), [b, c].sorted())
        XCTAssertEqual(result.machine.entries, [])
        XCTAssertEqual(result.library.replaced, [a: b, c: b, n: b], "their mappings stay")
        XCTAssertEqual(MediaResolver.resolve(a, library: result.library, machine: result.machine)?.id, b, "their ids still resolve")
        XCTAssertEqual(Set(result.changes), [.pruned(id: a, tier: .library), .pruned(id: n, tier: .library), .pruned(id: W.id("f"), tier: .machine)])
        XCTAssertEqual(result.posters, [MediaLocation(.mediaRoot, ".posters/a-0.png")!])
        // A read-only library isn't pruned; the machine's own index is.
        let readOnly = MediaLaunch.prune(library: library, machine: machine, libraryWritable: false, state: stateOf, named: [])
        XCTAssertEqual(readOnly.library, library)
        XCTAssertEqual(readOnly.machine.entries, [])
        // Not a replaced entry, or its file still there: kept. The walk itself never prunes.
        let plain = MediaIndex(entries: [W.entry(a, "")])
        XCTAssertEqual(MediaLaunch.prune(library: plain, machine: MediaLocalIndex(), libraryWritable: true, state: { _ in .absent }, named: []).library, plain)
        let walked = MediaWalk.plan(MediaWalk.Input(library: library, machine: machine, libraryWritable: true, found: [:], now: W.now))
        XCTAssertEqual(walked.library.entries.count, 4)
    }

    /// Spec 8 §4 — "that nothing on this machine names": the fixture's references.
    func test_whatTheMachineNames() {
        let (library, machine, _) = FixtureLibrary.load()
        let named = MediaReferences.named(library: library, machine: machine)
        XCTAssertTrue(named.isSuperset(of: [FixtureLibrary.dawn, FixtureLibrary.mountains, FixtureLibrary.cross, FixtureLibrary.welcomeSlide]),
                      "\(named.sorted())")
        XCTAssertFalse(named.contains(FixtureLibrary.announcement))
        var held = library
        held.lists[0].cues[0].commands.append(GuardedCommand(.media(.delete(id: FixtureLibrary.announcement, files: nil))))
        XCTAssertTrue(MediaReferences.named(library: held, machine: machine).contains(FixtureLibrary.announcement), "a held media command names its item")
    }
}
