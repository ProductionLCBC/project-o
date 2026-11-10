import Foundation
import XCTest
@testable import OCore

/// Spec 1 §4 as Spec 7 and Spec 9 corrected it, Spec 5 §2 (choice E-3) and
/// Spec 9 §6 — what one write of a list master does: its version, the copy it
/// keeps in `versions/<list uuid>/`, and the name of its file.
final class SavePlannerTests: XCTestCase {
    typealias F = FixtureLibrary

    static let path = "lists/Hymns/042-great-is-thy-faithfulness.json"
    static let minute: Int64 = 60_000

    var list42: List { F.load().library.list(number: 42) ?? List(uuid: F.listUuid(42), number: 42, title: "", cues: []) }

    func version(_ v: Int) -> String { "versions/a9f00000-0000-4000-8000-00000000002a/v" + String(format: "%04d", v) + ".json" }

    /// Spec 9 §6 — "Kept versions are filed by list uuid, at
    /// `library/versions/<list uuid>/vNNNN.json`"; the snapshot's names and
    /// dates are the index.
    func test_keptVersionsAreFiledByListUuidAndReadFromTheirNames() {
        XCTAssertEqual(FileLayout.versionPath(list: F.listUuid(42), version: 16), version(16))
        let kept = KeptVersions.reading([version(16): 1_000, version(3): 500, "versions/not-a-uuid/v0001.json": 9, version(16) + ".tmp": 4])
        XCTAssertEqual(kept.highest(F.listUuid(42)), 16)
        XCTAssertEqual(kept.lastKeptAt(F.listUuid(42)), 1_000)
        XCTAssertTrue(kept.has(F.listUuid(42), version: 3))
        XCTAssertFalse(kept.has(F.listUuid(42), version: 4))
        XCTAssertNil(kept.highest(F.listUuid(7)))
    }

    /// Spec 1 §4 — "A save writes the previous document to the versions
    /// folder ... before overwriting when the last copy there is more than ten
    /// minutes old" (E-3); "`version` still counts every save".
    func test_aSaveKeepsThePreviousFileOnlyWhenTheLastCopyIsMoreThanTenMinutesOld() {
        var list = list42
        list.cues[0].label = "Verse 1 (edited)"
        let kept = KeptVersions(lists: [F.listUuid(42): [16: 0]])

        let late = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: kept, now: 11 * Self.minute, taken: [])
        XCTAssertEqual(late.list.version, 18)
        XCTAssertEqual(late.path, Self.path)
        XCTAssertEqual(late.plan.operations.count, 2)
        XCTAssertEqual(late.plan.operations[0], .copy(from: Self.path, to: version(17)))
        guard case .replace(let path, let data) = late.plan.operations[1] else { return XCTFail("\(late.plan)") }
        XCTAssertEqual(path, Self.path)
        XCTAssertEqual(try JSONValue.parse(data)["version"], .number(18))
        XCTAssertEqual(late.kept.lastKeptAt(F.listUuid(42)), 11 * Self.minute)
        XCTAssertTrue(late.kept.has(F.listUuid(42), version: 17))

        let soon = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: kept, now: 9 * Self.minute, taken: [])
        XCTAssertEqual(soon.list.version, 18, "the version counts every save")
        XCTAssertEqual(soon.plan.operations.map(\.isReplace), [true], "no copy within ten minutes of the last")
        XCTAssertEqual(soon.kept, kept)

        let never = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: KeptVersions(), now: 0, taken: [])
        XCTAssertEqual(never.plan.operations.first, .copy(from: Self.path, to: version(17)), "a list with nothing kept keeps its first")
    }

    /// Spec 9 §6 — "no save writes over a kept version: a list whose `version`
    /// is at or below the highest kept for it saves one above that, whatever
    /// brought it there, a restore, a Finder copy of an old file or a sync that
    /// rolled it back"; Spec 1 §4 — "a previous document whose version is
    /// already kept isn't copied again".
    func test_noSaveWritesOverAKeptVersion() {
        var list = list42
        list.version = 15   // rolled back by a sync
        let kept = KeptVersions(lists: [F.listUuid(42): [15: 0, 16: 0, 17: 0]])
        let save = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: kept, now: 60 * Self.minute, taken: [])
        XCTAssertEqual(save.list.version, 18)
        XCTAssertEqual(save.plan.operations.map(\.isReplace), [true], "version 15 is kept already")
    }

    /// Spec 1 §4 — "A new list is written at the version it has", unless that
    /// is a version already kept for it.
    func test_aNewListIsWrittenAtItsVersion() {
        var list = list42
        list.version = 1
        let fresh = SavePlanner.saveList(list, currentPath: nil, folder: "Hymns", kept: KeptVersions(), now: 0, taken: [])
        XCTAssertEqual(fresh.list.version, 1)
        XCTAssertEqual(fresh.path, Self.path)
        XCTAssertEqual(fresh.plan.operations.map(\.isReplace), [true])

        let back = SavePlanner.saveList(list, currentPath: nil, folder: "", kept: KeptVersions(lists: [F.listUuid(42): [3: 0]]), now: 0, taken: [])
        XCTAssertEqual(back.list.version, 4)
        XCTAssertEqual(back.path, "lists/042-great-is-thy-faithfulness.json")
    }

    /// Spec 7 §2 — "a save renames the file within its folder", and "A save
    /// that would rename a list's file onto a name another file holds keeps
    /// its old name".
    func test_aSaveRenamesWithinItsFolderButNeverOntoAnotherFile() {
        var list = list42
        list.title = "Great Is Thy Faithfulness (1923)"
        let renamed = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: KeptVersions(lists: [F.listUuid(42): [16: 0]]),
                                           now: Self.minute, taken: [])
        XCTAssertEqual(renamed.path, "lists/Hymns/042-great-is-thy-faithfulness-1923.json")
        XCTAssertEqual(renamed.plan.operations.first, .move(from: Self.path, to: renamed.path))

        let held = SavePlanner.saveList(list, currentPath: Self.path, folder: "Hymns", kept: KeptVersions(lists: [F.listUuid(42): [16: 0]]),
                                        now: Self.minute, taken: ["lists/Hymns/042-Great-Is-Thy-Faithfulness-1923.json"])
        XCTAssertEqual(held.path, Self.path, "the name another file holds, compared ignoring case")
        XCTAssertEqual(held.plan.operations.map(\.isReplace), [true])
    }
}
