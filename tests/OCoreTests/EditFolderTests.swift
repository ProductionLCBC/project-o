import Foundation
import XCTest
@testable import OCore

/// Spec 7 §10 — "Folders. ... Create, rename, move and delete work with exact
/// inverses, and a rename is one directory rename. A rename onto an existing
/// path, into itself or under a missing parent is refused, and a change of
/// case alone is allowed. A folder holding only hidden files deletes, and one
/// holding a visible file is `notEmpty`." (The files themselves, moves that
/// arrive by sync and hidden folders on disk: LocalFilesTests and the engine's.)
final class EditFolderTests: XCTestCase {
    typealias F = FixtureLibrary

    /// "Creates the folder. Its parent must exist (`unknownObject` otherwise),
    /// so a deeper path is a group of creates". "A name can't be empty, start
    /// with a dot or contain a colon."
    func test_createNeedsItsParentAndAValidName() throws {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit folder \"Worship/Hymns\" create")?.reason, .unknownObject)
        let made = edits.apply("edit folder \"Worship\" create")
        XCTAssertEqual(made.first?.structure, [.makeFolder("Worship")])
        XCTAssertEqual(made.first?.inverse, EditCommand(.folder("Worship"), .delete))
        edits.apply("edit folder \"worship/Hymns\" create")
        XCTAssertEqual(edits.library.folders, ["Christmas", "Hymns", "Worship", "Worship/Hymns"], "the parent keeps its case")
        XCTAssertEqual(edits.refuse("edit folder \"WORSHIP\" create")?.reason, .duplicate, "names compare without regard to case")
        for bad in ["", "Worship/", "/Worship", ".hidden", "Worship/.x", "a:b", "Worship//Hymns"] {
            XCTAssertEqual(edits.refuse(EditCommand(.folder(bad), .create(body: nil, folder: nil, title: nil)))?.reason, .badValue, bad)
        }
    }

    /// "Renames the folder, or moves it when the parent changes, in one
    /// directory rename that carries everything in it".
    func test_aRenameIsOneDirectoryRenameCarryingItsLists() throws {
        var edits = Edits()
        edits.apply("edit folder \"Worship\" create")
        let renamed = edits.apply("edit folder \"Hymns\" rename \"Worship/Hymns\"")
        XCTAssertEqual(renamed.first?.structure, [.renameFolder(from: "Hymns", to: "Worship/Hymns")], "one rename")
        XCTAssertEqual(edits.library.folder(ofList: F.listUuid(42)), "Worship/Hymns")
        XCTAssertEqual(edits.library.folders, ["Christmas", "Worship", "Worship/Hymns"])
        XCTAssertEqual(renamed.first?.inverse, EditCommand(.folder("Worship/Hymns"), .rename(to: "Hymns")))
        XCTAssertTrue(renamed.first?.changes.contains { $0.object == "list" } == true, "the list it carries changed folder")
        // Subfolders and the files in them go along.
        edits.apply("edit folder \"Worship/Hymns/Old\" create")
        edits.library.otherFiles.insert("lists/Worship/Hymns/Old/notes.txt")
        edits.apply("edit folder \"Worship\" rename \"Music\"")
        XCTAssertEqual(edits.library.folders, ["Christmas", "Music", "Music/Hymns", "Music/Hymns/Old"])
        XCTAssertEqual(edits.library.otherFiles, ["lists/Music/Hymns/Old/notes.txt"])
        XCTAssertEqual(edits.library.folder(ofList: F.listUuid(42)), "Music/Hymns")
    }

    /// "A rename is refused with `duplicate` when the new path exists, ignoring
    /// case, unless only the case changes; with `badValue` when the new path is
    /// inside the old one; and with `unknownObject` when the new parent doesn't
    /// exist."
    func test_renameRefusals() throws {
        var edits = Edits()
        XCTAssertEqual(edits.refuse("edit folder \"Hymns\" rename \"CHRISTMAS\"")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit folder \"Hymns\" rename \"Hymns/Old\"")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit folder \"Hymns\" rename \"Easter/Hymns\"")?.reason, .unknownObject)
        XCTAssertEqual(edits.refuse("edit folder \"Easter\" rename \"Lent\"")?.reason, .unknownObject)
        let cased = edits.apply("edit folder \"Hymns\" rename \"HYMNS\"")
        XCTAssertEqual(cased.first?.structure, [.renameFolder(from: "Hymns", to: "HYMNS")], "a change of case alone is allowed")
        XCTAssertEqual(edits.library.folder(ofList: F.listUuid(42)), "HYMNS")
    }

    /// "Deletes the folder when it is empty: no lists, no visible files and no
    /// folders other than hidden ones. Hidden files and folders go with it ...
    /// Otherwise `notEmpty`."
    func test_deleteOnlyAnEmptyFolder() throws {
        var edits = Edits()
        // lists/Christmas/ holds only its hidden .keep.
        let deleted = edits.apply("edit folder \"Christmas\" delete")
        XCTAssertEqual(deleted.first?.structure, [.removeFolder("Christmas")])
        XCTAssertEqual(deleted.first?.inverse, EditCommand(.folder("Christmas"), .create(body: nil, folder: nil, title: nil)))
        XCTAssertEqual(edits.refuse("edit folder \"Hymns\" delete")?.reason, .notEmpty, "it holds list 42")
        edits.apply("edit folder \"Lent\" create")
        edits.library.otherFiles.insert("lists/Lent/cover.png")
        XCTAssertEqual(edits.refuse("edit folder \"Lent\" delete")?.reason, .notEmpty, "a visible file")
        edits.library.otherFiles.removeAll()
        edits.apply("edit folder \"Lent/Week 1\" create")
        XCTAssertEqual(edits.refuse("edit folder \"Lent\" delete")?.reason, .notEmpty, "a folder")
        XCTAssertEqual(edits.refuse("edit folder \"Lent\" colour \"red\"")?.reason, .unknownPath)
    }

    /// "On a case-sensitive volume two folders can differ only by case ...
    /// folder edits to that path are refused with `duplicate` until one is
    /// renamed."
    func test_foldersDifferingOnlyInCaseRefuseEditsToThatPath() throws {
        var edits = Edits()
        edits.library.folders = ["Christmas", "Hymns", "Worship", "worship"]
        XCTAssertEqual(edits.refuse("edit folder \"Worship\" delete")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit folder \"worship\" rename \"Songs\"")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit folder \"WORSHIP/Hymns\" create")?.reason, .duplicate)
        XCTAssertEqual(edits.refuse("edit list 42 folder \"Worship\"")?.reason, .duplicate)
    }
}
