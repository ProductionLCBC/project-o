import Foundation
import XCTest
@testable import OCore

/// Spec 7 §2 — lists and folders: "A list's folder is where its file is ...
/// The List has no folder field. ... Folders are directories, so an empty
/// folder exists".
final class ListFolderTests: XCTestCase {
    typealias F = FixtureLibrary

    /// "`lists/Worship/Hymns/042-great-is-thy-faithfulness.json` is list 42
    /// in the folder "Worship/Hymns", and a file directly in `lists/` is in no
    /// folder." Spec 7 §8 — "List 42 moves into a folder ... and list 7 stays
    /// at the top, so both cases load. An empty folder, `lists/Christmas/`, is
    /// held in git by a hidden `.keep` file that the loader ignores."
    func test_aListInAFolderLoadsThereAndAnEmptyFolderIsRecorded() {
        let (library, _, report) = F.load()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(library.lists.map(\.number), [7, 42])
        XCTAssertEqual(library.folder(ofList: F.listUuid(42)), "Hymns")
        XCTAssertEqual(library.folder(ofList: F.listUuid(7)), "")
        XCTAssertEqual(library.folders, ["Christmas", "Hymns"])
        XCTAssertEqual(library.otherFiles, [])
    }

    /// "The loader walks `lists/` and the folders in it, skipping any folder
    /// whose name starts with a dot, and ignores hidden files and anything
    /// that isn't `.json`."
    func test_hiddenFoldersAndFilesAreNotLoaded() throws {
        var snapshot = F.librarySnapshot
        let list42 = try XCTUnwrap(snapshot.files["lists/Hymns/042-great-is-thy-faithfulness.json"])
        snapshot.files["lists/.stversions/042-great-is-thy-faithfulness.json"] = list42
        snapshot.files["lists/Hymns/.042-copy.json"] = list42
        snapshot.folders.insert("lists/.stversions")
        snapshot.otherFiles.insert("lists/Hymns/notes.txt")
        let (library, report) = Loader.library(from: snapshot)
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(library.lists.map(\.number), [7, 42])
        XCTAssertEqual(library.folders, ["Christmas", "Hymns"], "a dot-folder isn't one of the library's folders")
        XCTAssertEqual(library.otherFiles, ["lists/Hymns/notes.txt"], "a visible file that isn't a list keeps its folder from being empty")
    }

    // MARK: - Two files, one list; two lists, one number

    static let list42Path = "lists/Hymns/042-great-is-thy-faithfulness.json"

    /// List 42's document with a field or two changed.
    func list42(_ change: (inout JSONValue) -> Void = { _ in }) throws -> Data {
        var tree = try JSONValue.parse(try XCTUnwrap(F.librarySnapshot.files[Self.list42Path]))
        change(&tree)
        return JSONCanonical.data(tree)
    }

    func load(_ snapshot: RootSnapshot) -> (library: Library, report: ValidationReport) {
        let (library, report) = Loader.library(from: snapshot)
        return (library, report)
    }

    /// "When two files hold the same list (the same uuid), one loads. The
    /// engine prefers the file whose name is the one it would write for that
    /// list, then the higher `version`, then the later modification date,
    /// then the path that sorts first. The other file is reported (Spec 1
    /// §8), so a copy made in the Finder ("… copy.json") never replaces the
    /// original (choice Q-5)."
    func test_ofTwoFilesHoldingOneListTheEnginesOwnNameWinsThenVersionThenDateThenPath() throws {
        let finderCopy = "lists/Hymns/042-great-is-thy-faithfulness copy.json"
        var snapshot = F.librarySnapshot
        snapshot.files[finderCopy] = try list42 { $0 = $0.setting("version", to: .number(99)) }
        var (library, report) = load(snapshot)
        XCTAssertEqual(library.list(uuid: F.listUuid(42))?.version, 17, "the engine's own name beats a higher version")
        XCTAssertEqual(library.documentPaths[FileLayout.documentKey(list: F.listUuid(42))], Self.list42Path)
        XCTAssertEqual(library.lists.filter { $0.number == 42 }.count, 1)
        XCTAssertEqual(report.issues(.duplicateFile).map(\.file), [finderCopy])
        XCTAssertTrue(library.otherFiles.contains(finderCopy), "the copy is never written over")

        // Both with the name the engine would write (a move in flight): the higher version.
        let moved = "lists/042-great-is-thy-faithfulness.json"
        snapshot = F.librarySnapshot
        snapshot.files[moved] = try list42 { $0 = $0.setting("version", to: .number(18)) }
        (library, report) = load(snapshot)
        XCTAssertEqual(library.list(uuid: F.listUuid(42))?.version, 18)
        XCTAssertEqual(library.folder(ofList: F.listUuid(42)), "")
        XCTAssertEqual(report.issues(.duplicateFile).map(\.file), [Self.list42Path])

        // The same version: the later modification date.
        snapshot.files[moved] = try list42()
        snapshot.modified[moved] = 2_000
        snapshot.modified[Self.list42Path] = 1_000
        XCTAssertEqual(load(snapshot).library.folder(ofList: F.listUuid(42)), "")
        snapshot.modified[moved] = 500
        XCTAssertEqual(load(snapshot).library.folder(ofList: F.listUuid(42)), "Hymns")

        // The same date: the path that sorts first.
        snapshot.modified[moved] = 1_000
        XCTAssertEqual(load(snapshot).library.folder(ofList: F.listUuid(42)), "", "lists/042… sorts before lists/Hymns/…")
    }

    /// "Two different lists with the same number both load, as on `main`. A
    /// playlist link finds the right one by its uuid (§3). Anything that names
    /// the number alone, such as `list 57 cue 3` or an edit, gets the one that
    /// comes first in the same order, and the report names the clash".
    func test_twoListsWithOneNumberBothLoadAndTheNumberReachesTheFirst() throws {
        let other = F.uuid("5ec0", 42)
        var snapshot = F.librarySnapshot
        snapshot.files["lists/042-another-hymn copy.json"] = try list42 {
            $0 = $0.setting("uuid", to: .string(other.uuidString.lowercased())).setting("title", to: .string("Another Hymn"))
                .setting("version", to: .number(40))
        }
        let library = load(snapshot).library
        XCTAssertEqual(library.lists.filter { $0.number == 42 }.map(\.uuid), [F.listUuid(42), other],
                       "the engine's own name first, though the other has the higher version")
        XCTAssertEqual(library.list(number: 42)?.uuid, F.listUuid(42))
        XCTAssertEqual(library.list(for: .linked(list: 42, listUuid: other))?.uuid, other)
        XCTAssertEqual(Validator.validate(library: library, machine: nil).issues(.duplicateNumber).map(\.subject), ["list 42"])

        // Both named as the engine would name them: the higher version comes first.
        snapshot.files["lists/042-another-hymn.json"] = snapshot.files.removeValue(forKey: "lists/042-another-hymn copy.json")
        XCTAssertEqual(load(snapshot).library.list(number: 42)?.uuid, other)
    }

    /// "On a case-sensitive volume two folders can differ only by case. The
    /// tree shows them as one folder, the report names them".
    func test_foldersThatDifferOnlyInCaseAreReported() {
        var snapshot = F.librarySnapshot
        snapshot.folders.formUnion(["lists/Worship", "lists/worship"])
        let (library, report) = load(snapshot)
        XCTAssertEqual(library.folders, ["Christmas", "Hymns", "Worship", "worship"])
        XCTAssertEqual(report.issues(.folderCaseClash).map(\.subject), ["folder worship"])
    }

    /// "a save renames the file within its folder" (Spec 7 §2); Spec 1 §5 —
    /// "renames the file to match on save, keeping a list in its folder".
    func test_aSaveKeepsAListInItsFolder() throws {
        let (library, _, _) = F.load()
        var list = try XCTUnwrap(library.list(number: 42))
        list.title = "Great Is Thy Faithfulness (1923)"
        let plan = Writer.save(.list(list), currentPath: "lists/Hymns/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(plan.operations.first, .move(from: "lists/Hymns/042-great-is-thy-faithfulness.json",
                                                    to: "lists/Hymns/042-great-is-thy-faithfulness-1923.json"))
        XCTAssertEqual(FileLayout.folder(ofListPath: "lists/Worship/Hymns/042-x.json"), "Worship/Hymns")
        XCTAssertEqual(FileLayout.folder(ofListPath: "lists/007-doxology.json"), "")
        XCTAssertEqual(FileLayout.listPath(for: list, folder: "Worship/Hymns"), "lists/Worship/Hymns/042-great-is-thy-faithfulness-1923.json")
        XCTAssertEqual(FileLayout.listPath(for: list, folder: ""), "lists/042-great-is-thy-faithfulness-1923.json")
    }
}
