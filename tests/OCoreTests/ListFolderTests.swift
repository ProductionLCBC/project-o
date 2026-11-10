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
