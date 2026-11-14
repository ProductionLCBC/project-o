import Foundation
import XCTest
import OCore
import OFormats

/// Spec 1 §5 — Writing: "Every save writes to a temporary file in the same
/// folder, fsyncs, and renames over the original, so a crash mid-write leaves
/// the previous file intact." Spec 1 §10 — Atomic writes: "A simulated crash
/// between temp-file write and rename leaves the original readable." The
/// adapter in `formats/OFormats` is the only code that touches disk; these
/// tests run it against a temporary copy of the fixture library.
final class LocalFilesTests: XCTestCase {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OFormatsTests
            .deletingLastPathComponent()   // tests
            .deletingLastPathComponent()   // root
    }
    static var fixtureRoot: URL { repoRoot.appendingPathComponent("tests/fixtures/library-v1") }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("o-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func copyFixtureLibrary() throws -> URL {
        let root = scratch.appendingPathComponent("library")
        try FileManager.default.copyItem(at: Self.fixtureRoot.appendingPathComponent("library"), to: root)
        return root
    }

    private func write(_ text: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ relative: String, in root: URL) -> Data? {
        FileManager.default.contents(atPath: root.appendingPathComponent(relative).path)
    }

    private func names(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    // MARK: - Reading

    /// Spec 1 §5 — "The loader and the folder watcher ignore a sync tool's
    /// temporary and partial files (names beginning with a dot or ending in
    /// .tmp...)"; the media folder holds media, not documents.
    func test_snapshotReadsDocumentsAndIgnoresMediaTemporariesAndDotFiles() throws {
        let root = try copyFixtureLibrary()
        try write("{", to: "lists/042-great-is-thy-faithfulness.json.tmp", in: root)
        try write("{", to: "lists/.syncthing.042.json", in: root)
        try write("garbage", to: ".DS_Store", in: root)
        try write("{\"a\": 1}", to: "media/not-a-document.json", in: root)

        let snapshot = try LocalFiles.snapshot(ofRoot: root)
        let expected = Set([
            "library.json", "channels.json", "text-styles.json", "grades.json", "transitions.json", "audio-transitions.json",
            "presets/001-default.json", "presets/002-clock.json", "presets/003-lower-third.json", "presets/004-credits.json",
            "macros/001-welcome.json", "lists/007-doxology.json", "lists/Hymns/042-great-is-thy-faithfulness.json",
            "media-index.json",
        ])
        XCTAssertEqual(Set(snapshot.files.keys), expected)
        XCTAssertEqual(snapshot.files["channels.json"], read("channels.json", in: root))

        let loaded = Loader.library(from: snapshot)
        XCTAssertEqual(loaded.report.issues, [])
        XCTAssertEqual(loaded.library.lists.map(\.number), [7, 42])
    }

    /// Spec 7 §2 — "The loader walks `lists/` and the folders in it, skipping
    /// any folder whose name starts with a dot, and ignores hidden files and
    /// anything that isn't `.json`. It records folders as well as files, so an
    /// empty folder survives a reload." Spec 7 §2's tie-breaks read each file's
    /// modification date; Spec 9 §6's versions are read as names and dates,
    /// and Spec 5 §10's conflicts folder is never read.
    func test_snapshotRecordsFoldersOtherFilesDatesAndVersions() throws {
        let root = try copyFixtureLibrary()
        try write("notes", to: "lists/Hymns/notes.txt", in: root)
        try write("{}", to: "lists/.stversions/042-old.json", in: root)
        try write("{}", to: "conflicts/2026-11-08-084112-042.json", in: root)

        let snapshot = try LocalFiles.snapshot(ofRoot: root)
        XCTAssertEqual(Set(snapshot.folders.filter { $0.hasPrefix("lists/") }), ["lists/Christmas", "lists/Hymns"])
        XCTAssertEqual(snapshot.otherFiles, ["lists/Hymns/notes.txt"])
        XCTAssertEqual(Set(snapshot.versions.keys), ["versions/a9f00000-0000-4000-8000-00000000002a/v0016.json"])
        XCTAssertNil(snapshot.files["versions/a9f00000-0000-4000-8000-00000000002a/v0016.json"], "a kept version's bytes aren't read")
        XCTAssertFalse(snapshot.files.keys.contains { $0.hasPrefix("conflicts/") })
        XCTAssertEqual(Set(snapshot.modified.keys), Set(snapshot.files.keys))
        let date = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("lists/007-doxology.json").path)[.modificationDate] as? Date
        XCTAssertEqual(snapshot.modified["lists/007-doxology.json"], date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) })
    }

    // MARK: - Writing

    func test_aCrashBetweenTemporaryWriteAndRenameLeavesTheOriginalReadable() throws {
        let root = try copyFixtureLibrary()
        let path = "lists/Hymns/042-great-is-thy-faithfulness.json"
        let original = try XCTUnwrap(read(path, in: root))
        let loaded = Loader.library(from: try LocalFiles.snapshot(ofRoot: root))
        var list = try XCTUnwrap(loaded.library.list(number: 42))
        list.cues[0].label = "Verse 1 (edited)"
        let save = SavePlanner.saveList(list, currentPath: path, folder: "Hymns", kept: KeptVersions(), now: 0, taken: [])

        XCTAssertThrowsError(try LocalFiles.execute(save.plan, in: root, crashAfterTemporaryWriteOf: path)) { error in
            XCTAssertTrue(error is SimulatedCrash, "\(error)")
        }
        XCTAssertEqual(read(path, in: root), original, "the original is intact")
        XCTAssertNoThrow(try JSONValue.parse(try XCTUnwrap(read(path, in: root))))
        let leftovers = names(in: root.appendingPathComponent("lists/Hymns")).filter { $0 != "042-great-is-thy-faithfulness.json" }
        XCTAssertFalse(leftovers.isEmpty, "the temporary file is left behind for the next launch to ignore")
        XCTAssertTrue(leftovers.allSatisfy { $0.hasPrefix(".") || $0.hasSuffix(".tmp") }, "\(leftovers)")
        XCTAssertEqual(Set(try LocalFiles.snapshot(ofRoot: root).files.keys).intersection(leftovers.map { "lists/Hymns/" + $0 }), [])
        XCTAssertEqual(Loader.library(from: try LocalFiles.snapshot(ofRoot: root)).library.list(number: 42)?.version, 17, "the versions copy ran first, but the list itself did not change")

        try LocalFiles.execute(save.plan, in: root)
        let after = try XCTUnwrap(read(path, in: root))
        XCTAssertNotEqual(after, original)
        XCTAssertEqual(after, Writer.data(for: .list(save.list)))
        XCTAssertEqual(read("versions/a9f00000-0000-4000-8000-00000000002a/v0017.json", in: root), original)
        XCTAssertEqual(names(in: root.appendingPathComponent("lists/Hymns")), ["042-great-is-thy-faithfulness.json"], "no temporary files remain")
        XCTAssertEqual(Loader.library(from: try LocalFiles.snapshot(ofRoot: root)).library.list(number: 42)?.version, 18)
    }

    /// Spec 7 §2 — "Other files are never replaced. A save that would rename
    /// a list's file onto a name another file holds keeps its old name, and a
    /// move onto one is refused"; Spec 9 §6 — "no save writes over a kept
    /// version"; the folder edits: "Its parent must exist", "one directory
    /// rename that carries everything in it", and a delete "when it is empty:
    /// no lists, no visible files and no folders other than hidden ones.
    /// Hidden files and folders go with it".
    func test_movesAndCopiesNeverReplaceAndFolderOperationsKeepTheirRules() throws {
        let root = try copyFixtureLibrary()
        let list42 = "lists/Hymns/042-great-is-thy-faithfulness.json"
        let doxology = "lists/007-doxology.json"
        let original42 = try XCTUnwrap(read(list42, in: root))
        let originalDoxology = try XCTUnwrap(read(doxology, in: root))

        // A move onto another file is refused, and both stay as they were.
        XCTAssertThrowsError(try LocalFiles.execute(WritePlan(operations: [.move(from: list42, to: doxology)]), in: root))
        XCTAssertEqual(read(list42, in: root), original42)
        XCTAssertEqual(read(doxology, in: root), originalDoxology)
        // A move into a folder that isn't there is refused: no move makes a folder on the way.
        XCTAssertThrowsError(try LocalFiles.execute(WritePlan(operations: [.move(from: list42, to: "lists/Gone/042.json")]), in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("lists/Gone").path))
        try LocalFiles.execute(WritePlan(operations: [.move(from: list42, to: "lists/Christmas/042-great-is-thy-faithfulness.json")]), in: root)
        XCTAssertEqual(read("lists/Christmas/042-great-is-thy-faithfulness.json", in: root), original42)

        // A copy never writes over what is there, and makes the folders it needs.
        let kept = "versions/a9f00000-0000-4000-8000-00000000002a/v0016.json"
        let keptBytes = try XCTUnwrap(read(kept, in: root))
        try LocalFiles.execute(WritePlan(operations: [.copy(from: doxology, to: kept)]), in: root)
        XCTAssertEqual(read(kept, in: root), keptBytes, "a kept version is never written over")
        try LocalFiles.execute(WritePlan(operations: [.copy(from: doxology, to: "versions/a9f00000-0000-4000-8000-000000000007/v0003.json")]), in: root)
        XCTAssertEqual(read("versions/a9f00000-0000-4000-8000-000000000007/v0003.json", in: root), originalDoxology)

        // Folders.
        XCTAssertThrowsError(try LocalFiles.execute(WritePlan(operations: [.makeFolder(path: "lists/Worship/Hymns")]), in: root),
                             "its parent must exist")
        try LocalFiles.execute(WritePlan(operations: [.makeFolder(path: "lists/Worship")]), in: root)
        XCTAssertThrowsError(try LocalFiles.execute(WritePlan(operations: [.renameFolder(from: "lists/Worship", to: "lists/Christmas")]), in: root))
        try LocalFiles.execute(WritePlan(operations: [.renameFolder(from: "lists/Christmas", to: "lists/Worship/Christmas")]), in: root)
        XCTAssertEqual(read("lists/Worship/Christmas/042-great-is-thy-faithfulness.json", in: root), original42, "one rename carries everything in it")
        try LocalFiles.execute(WritePlan(operations: [.renameFolder(from: "lists/Worship", to: "lists/worship")]), in: root)
        XCTAssertTrue(names(in: root.appendingPathComponent("lists")).contains("worship"), "a change of case alone is a rename")

        try write("x", to: "lists/Empty/.keep", in: root)
        try write("x", to: "lists/Empty/.sync/state", in: root)
        try LocalFiles.execute(WritePlan(operations: [.removeFolder(path: "lists/Empty")]), in: root)
        XCTAssertFalse(names(in: root.appendingPathComponent("lists")).contains("Empty"), "hidden files and folders go with it")
        try write("x", to: "lists/Full/notes.txt", in: root)
        XCTAssertThrowsError(try LocalFiles.execute(WritePlan(operations: [.removeFolder(path: "lists/Full")]), in: root)) { error in
            XCTAssertEqual((error as? FileError)?.reason, "not empty")
        }
        XCTAssertNotNil(read("lists/Full/notes.txt", in: root))
    }

    func test_moveAndRemoveOperationsAndMissingFolders() throws {
        let root = try copyFixtureLibrary()
        let loaded = Loader.library(from: try LocalFiles.snapshot(ofRoot: root))
        var preset = try XCTUnwrap(loaded.library.preset(3))
        preset.label = "Lower third, wide"
        try LocalFiles.execute(Writer.save(.preset(preset), currentPath: "presets/003-lower-third.json"), in: root)
        XCTAssertEqual(names(in: root.appendingPathComponent("presets")), ["001-default.json", "002-clock.json", "003-lower-third-wide.json", "004-credits.json"])
        XCTAssertEqual(read("presets/003-lower-third-wide.json", in: root), Writer.data(for: .preset(preset)))

        try LocalFiles.execute(WritePlan(operations: [.remove(path: "presets/003-lower-third-wide.json")]), in: root)
        XCTAssertEqual(names(in: root.appendingPathComponent("presets")), ["001-default.json", "002-clock.json", "004-credits.json"])
        XCTAssertNoThrow(try LocalFiles.execute(WritePlan(operations: [.remove(path: "presets/gone.json")]), in: root), "removing what is not there is not an error")

        try LocalFiles.execute(WritePlan(operations: [.replace(path: "new/folder/doc.json", data: Data("{}\n".utf8))]), in: root)
        XCTAssertEqual(read("new/folder/doc.json", in: root), Data("{}\n".utf8), "folders are created as needed")
    }

    /// Everything the loader read writes back byte for byte through the file system.
    func test_theFixtureLibraryRoundTripsThroughTheFileSystem() throws {
        let source = try copyFixtureLibrary()
        let target = scratch.appendingPathComponent("written")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let loaded = Loader.library(from: try LocalFiles.snapshot(ofRoot: source))
        let files = Writer.snapshot(of: loaded.library).files
        let plan = WritePlan(operations: files.sorted { $0.key < $1.key }.map { .replace(path: $0.key, data: $0.value) })
        try LocalFiles.execute(plan, in: target)
        for (path, data) in files {
            XCTAssertEqual(read(path, in: target), data, path)
            XCTAssertEqual(read(path, in: source), data, path)
        }
    }

    // MARK: - Media

    func test_hashingAFileMatchesTheIndexAndMissingFilesAreFound() throws {
        let mediaRoot = Self.fixtureRoot.appendingPathComponent("library/media")
        XCTAssertEqual(try LocalFiles.hash(fileAt: mediaRoot.appendingPathComponent("backgrounds/dawn.mp4")),
                       "sha256:55c84469c37e1e6a72a9b8938422cd6536b302b583a5c127241c8304246f3527")
        let machineRoot = Self.fixtureRoot.appendingPathComponent("machine")
        let library = Loader.library(from: try LocalFiles.snapshot(ofRoot: Self.fixtureRoot.appendingPathComponent("library"))).library
        let machine = Loader.machine(from: try LocalFiles.snapshot(ofRoot: machineRoot)).machine
        // Spec 8 §2 — a library entry reads against the media root, a machine
        // entry and a relative override against `machine/media/`.
        let folders = MediaFolders.of(machineRoot: machineRoot, settings: machine.settings)
        XCTAssertEqual(folders.mediaRoot?.standardizedFileURL, mediaRoot.standardizedFileURL)
        XCTAssertEqual(folders.machineMedia?.lastPathComponent, "media")
        let states = LocalFiles.mediaStates(library: library, machine: machine, folders: folders)
        XCTAssertEqual(states[MediaLocation(.mediaRoot, "backgrounds/dawn.mp4")!], .unhashed)
        XCTAssertEqual(states[MediaLocation(.machineMedia, "cross-fast.png")!], .unhashed, "cross's override")
        XCTAssertEqual(states[MediaLocation(.machineMedia, "announcement.png")!], .unhashed)
        XCTAssertEqual(states[MediaLocation(.mediaRoot, "backgrounds/mountains.mp4")!], .absent)
        XCTAssertNil(states[MediaLocation(.mediaRoot, "backgrounds/cross.png")!], "an overridden entry's own path isn't where it is read")
        XCTAssertEqual(LocalFiles.missingMedia(library: library, machine: machine, folders: folders), ["sha256:" + String(repeating: "9f2c6a1b", count: 8)])
        XCTAssertEqual(LocalFiles.missingMedia(library: library, machine: machine, folders: MediaFolders(mediaRoot: folders.mediaRoot)).count, 3,
                       "without machine/media/, mountains, announcement and cross (by its override) are missing")

        let report = Validator.validate(library: library, machine: machine,
                                        environment: ValidationEnvironment(mediaState: { states[$0] ?? .absent }))
        XCTAssertEqual(report.issues.map(\.code), [.missingMedia])
        XCTAssertEqual(report.issues.first?.subject, "sha256:" + String(repeating: "9f2c6a1b", count: 8))
    }
}
