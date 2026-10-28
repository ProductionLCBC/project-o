import Foundation
import XCTest
@testable import OCore

/// Spec 1 §5 — file names, the versions folder and the write plan behind
/// "Every save writes to a temporary file in the same folder, fsyncs, and
/// renames over the original"; Spec 1 §4 — "Saving writes the previous
/// document to the versions folder before overwriting". The plan is pure; the
/// OFormats adapter executes it (its own tests cover the crash).
final class WriterTests: XCTestCase {
    typealias F = FixtureLibrary

    // MARK: - Names

    func test_fileNamesCarryTheNumberAndASlugOfTheLabel() {
        XCTAssertEqual(FileLayout.slug("Great Is Thy Faithfulness"), "great-is-thy-faithfulness")
        XCTAssertEqual(FileLayout.slug("Great Is Thy Faithfulness (Manheim)"), "great-is-thy-faithfulness-manheim")
        XCTAssertEqual(FileLayout.slug("  Lower   third!  "), "lower-third")
        XCTAssertEqual(FileLayout.slug("Ünïcode ✓ Stück"), "unicode-stuck")
        XCTAssertEqual(FileLayout.slug("---"), "")
        XCTAssertEqual(FileLayout.slug(String(repeating: "x", count: 100)).count, 60, "slugs are bounded")

        let (library, machine, _) = F.load()
        XCTAssertEqual(FileLayout.path(for: .preset(library.presets[2])), "presets/003-lower-third.json")
        XCTAssertEqual(FileLayout.path(for: .list(library.lists[1])), "lists/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(FileLayout.path(for: .list(machine.localLists[0])), "lists-local/042-great-is-thy-faithfulness-manheim.json")
        XCTAssertEqual(FileLayout.path(for: .macro(library.macros[0])), "macros/001-welcome.json")
        XCTAssertEqual(FileLayout.path(for: .macro(machine.macros[0])), "macros/002-preshow.json")
        XCTAssertEqual(FileLayout.path(for: .playlist(machine.playlists[0])), "playlists/2026-11-01-sunday.json")
        var undated = machine.playlists[0]
        undated.serviceDate = nil
        undated.title = "Sunday Night"
        XCTAssertEqual(FileLayout.path(for: .playlist(undated)), "playlists/sunday-night.json")
        var unlabeled = library.presets[2]
        unlabeled.label = ""
        unlabeled.number = 1234
        XCTAssertEqual(FileLayout.path(for: .preset(unlabeled)), "presets/1234.json")
        XCTAssertEqual(FileLayout.versionPath(list: 42, version: 16), "versions/042/v0016.json")
        XCTAssertEqual(FileLayout.path(for: .channels([])), "channels.json")
        XCTAssertEqual(FileLayout.path(for: .mediaLocal(MediaLocalIndex())), "media-local.json")
        XCTAssertEqual(FileLayout.path(for: .state(ShowState())), "state/last.json")
    }

    /// Spec 1 §5 — "the loader identifies a file by the `number` inside it and
    /// renames the file to match on save."
    func test_savingRenamesAFileWhoseLabelChanged() {
        let (library, _, _) = F.load()
        var preset = library.presets[2]
        preset.label = "Lower third, wide"
        let plan = Writer.save(.preset(preset), currentPath: "presets/003-lower-third.json")
        XCTAssertEqual(plan.operations.count, 2)
        XCTAssertEqual(plan.operations[0], .move(from: "presets/003-lower-third.json", to: "presets/003-lower-third-wide.json"))
        guard case .replace(let path, let data) = plan.operations[1] else { return XCTFail("\(plan)") }
        XCTAssertEqual(path, "presets/003-lower-third-wide.json")
        XCTAssertEqual(data, Writer.data(for: .preset(preset)))

        let unchanged = Writer.save(.preset(library.presets[2]), currentPath: "presets/003-lower-third.json")
        XCTAssertEqual(unchanged.operations, [.replace(path: "presets/003-lower-third.json", data: Writer.data(for: .preset(library.presets[2])))])
        let first = Writer.save(.preset(preset), currentPath: nil)
        XCTAssertEqual(first.operations.map(\.isReplace), [true], "a new document has nothing to rename")
    }

    /// Spec 1 §4 — "Every List master carries an integer `version` that
    /// increments on each save. Saving writes the previous document to the
    /// versions folder before overwriting, which is the whole version-history
    /// mechanism."
    func test_savingAListBumpsTheVersionAndKeepsThePreviousDocument() throws {
        let (library, _, _) = F.load()
        let previous = try XCTUnwrap(F.librarySnapshot.files["lists/042-great-is-thy-faithfulness.json"])
        var list = library.lists[1]
        list.cues[0].label = "Verse 1 (edited)"
        let saved = Writer.saveList(list, previous: previous, currentPath: "lists/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(saved.list.version, 18)
        XCTAssertEqual(saved.plan.operations.count, 2)
        XCTAssertEqual(saved.plan.operations[0], .replace(path: "versions/042/v0017.json", data: previous))
        guard case .replace(let path, let data) = saved.plan.operations[1] else { return XCTFail("\(saved.plan)") }
        XCTAssertEqual(path, "lists/042-great-is-thy-faithfulness.json")
        let tree = try JSONValue.parse(data)
        XCTAssertEqual(tree["version"], .number(18))
        XCTAssertEqual(tree["cues"]?[0]?["label"], .string("Verse 1 (edited)"))

        let firstSave = Writer.saveList(list, previous: nil, currentPath: nil)
        XCTAssertEqual(firstSave.plan.operations.count, 1, "a new master has no previous version to keep")
        XCTAssertEqual(firstSave.list.version, 18)

        list.title = "Great Is Thy Faithfulness (new)"
        let renamed = Writer.saveList(list, previous: previous, currentPath: "lists/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(renamed.plan.operations.map(\.isReplace), [true, false, true])
        XCTAssertEqual(renamed.plan.operations[1], .move(from: "lists/042-great-is-thy-faithfulness.json", to: "lists/042-great-is-thy-faithfulness-new.json"))
    }

    /// The plan is data: executing it in order is the adapter's whole job, and
    /// nothing in it is a partial write.
    func test_aPlanIsAnOrderedListOfWholeFileOperations() {
        let (library, _, _) = F.load()
        let plan = Writer.save(.channels(library.channels), currentPath: "channels.json")
        XCTAssertEqual(plan.operations, [.replace(path: "channels.json", data: Writer.data(for: .channels(library.channels)))])
        for operation in plan.operations {
            if case .replace(_, let data) = operation {
                XCTAssertTrue(data.last == UInt8(ascii: "\n"))
            }
        }
    }

    /// A catalog document carries its unknown top-level keys through a save.
    func test_documentLevelUnknownKeysAreKept() throws {
        var tree = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files["grades.json"]))
        tree = tree.setting("zzFuture", to: .object(["a": .number(1)]))
        let loaded = try Loader.document(path: "grades.json", data: JSONCanonical.data(tree))
        XCTAssertEqual(loaded.extras, ["zzFuture": .object(["a": .number(1)])])
        let library = Loader.library(from: RootSnapshot(files: ["grades.json": JSONCanonical.data(tree)])).library
        XCTAssertEqual(library.documentExtras[.grades], ["zzFuture": .object(["a": .number(1)])])
        XCTAssertEqual(Writer.snapshot(of: library).files["grades.json"], JSONCanonical.data(tree))
    }
}

extension FileOperation {
    var isReplace: Bool {
        if case .replace = self { return true }
        return false
    }
}
