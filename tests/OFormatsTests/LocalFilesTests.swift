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
            "presets/001-default.json", "presets/002-confidence.json", "presets/003-lower-third.json",
            "macros/001-welcome.json", "lists/007-doxology.json", "lists/042-great-is-thy-faithfulness.json",
            "versions/042/v0016.json", "media-index.json",
        ])
        XCTAssertEqual(Set(snapshot.files.keys), expected)
        XCTAssertEqual(snapshot.files["channels.json"], read("channels.json", in: root))

        let loaded = Loader.library(from: snapshot)
        XCTAssertEqual(loaded.report.issues, [])
        XCTAssertEqual(loaded.library.lists.map(\.number), [7, 42])
    }

    // MARK: - Writing

    func test_aCrashBetweenTemporaryWriteAndRenameLeavesTheOriginalReadable() throws {
        let root = try copyFixtureLibrary()
        let path = "lists/042-great-is-thy-faithfulness.json"
        let original = try XCTUnwrap(read(path, in: root))
        let loaded = Loader.library(from: try LocalFiles.snapshot(ofRoot: root))
        var list = try XCTUnwrap(loaded.library.list(number: 42))
        list.cues[0].label = "Verse 1 (edited)"
        let save = Writer.saveList(list, previous: original, currentPath: path)

        XCTAssertThrowsError(try LocalFiles.execute(save.plan, in: root, crashAfterTemporaryWrite: true)) { error in
            XCTAssertTrue(error is SimulatedCrash, "\(error)")
        }
        XCTAssertEqual(read(path, in: root), original, "the original is intact")
        XCTAssertNoThrow(try JSONValue.parse(try XCTUnwrap(read(path, in: root))))
        let leftovers = names(in: root.appendingPathComponent("lists")).filter { $0 != "007-doxology.json" && $0 != "042-great-is-thy-faithfulness.json" }
        XCTAssertFalse(leftovers.isEmpty, "the temporary file is left behind for the next launch to ignore")
        XCTAssertTrue(leftovers.allSatisfy { $0.hasPrefix(".") || $0.hasSuffix(".tmp") }, "\(leftovers)")
        XCTAssertEqual(Set(try LocalFiles.snapshot(ofRoot: root).files.keys).intersection(leftovers.map { "lists/" + $0 }), [])
        XCTAssertEqual(Loader.library(from: try LocalFiles.snapshot(ofRoot: root)).library.list(number: 42)?.version, 17, "the versions copy ran first, but the list itself did not change")

        try LocalFiles.execute(save.plan, in: root)
        let after = try XCTUnwrap(read(path, in: root))
        XCTAssertNotEqual(after, original)
        XCTAssertEqual(after, Writer.data(for: .list(save.list)))
        XCTAssertEqual(read("versions/042/v0017.json", in: root), original)
        XCTAssertEqual(names(in: root.appendingPathComponent("lists")), ["007-doxology.json", "042-great-is-thy-faithfulness.json"], "no temporary files remain")
        XCTAssertEqual(Loader.library(from: try LocalFiles.snapshot(ofRoot: root)).library.list(number: 42)?.version, 18)
    }

    func test_moveAndRemoveOperationsAndMissingFolders() throws {
        let root = try copyFixtureLibrary()
        let loaded = Loader.library(from: try LocalFiles.snapshot(ofRoot: root))
        var preset = try XCTUnwrap(loaded.library.preset(3))
        preset.label = "Lower third, wide"
        try LocalFiles.execute(Writer.save(.preset(preset), currentPath: "presets/003-lower-third.json"), in: root)
        XCTAssertEqual(names(in: root.appendingPathComponent("presets")), ["001-default.json", "002-confidence.json", "003-lower-third-wide.json"])
        XCTAssertEqual(read("presets/003-lower-third-wide.json", in: root), Writer.data(for: .preset(preset)))

        try LocalFiles.execute(WritePlan(operations: [.remove(path: "presets/003-lower-third-wide.json")]), in: root)
        XCTAssertEqual(names(in: root.appendingPathComponent("presets")), ["001-default.json", "002-confidence.json"])
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
        let existing = try LocalFiles.existingMediaPaths(mediaRoot: mediaRoot)
        XCTAssertTrue(existing.contains("backgrounds/dawn.mp4"))
        XCTAssertTrue(existing.contains("local/cross-fast.png"))
        XCTAssertFalse(existing.contains("backgrounds/mountains.mp4"))

        let library = Loader.library(from: try LocalFiles.snapshot(ofRoot: Self.fixtureRoot.appendingPathComponent("library"))).library
        let machine = Loader.machine(from: try LocalFiles.snapshot(ofRoot: Self.fixtureRoot.appendingPathComponent("machine"))).machine
        let report = Validator.validate(library: library, machine: machine, environment: ValidationEnvironment(existingMediaPaths: existing))
        XCTAssertEqual(report.issues.map(\.code), [.missingMedia])
        XCTAssertEqual(report.issues.first?.subject, "sha256:" + String(repeating: "9f2c6a1b", count: 8))
    }
}
