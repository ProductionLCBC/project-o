import Foundation
import XCTest
@testable import OCore

/// Spec 7 §10 — "Lists. Create at a number, in a folder, with a body, and
/// without a number (one past the highest used or referenced). Metadata.
/// Delete while a playlist links the list: the item is missing, flagged and
/// skipped by `next`, and the inverse puts the list back whole, in its folder,
/// with its version. Renumber rewrites the links in active and archived
/// playlists. Duplicate gives new uuids in the same folder."
final class EditListTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_createAtANumberInAFolderAndWithABody() throws {
        var edits = Edits()
        let made = edits.apply("edit list 57 create")
        let list = try XCTUnwrap(edits.list(57))
        XCTAssertEqual(list.uuid, Edits.pick(1))
        XCTAssertEqual(list.cues, [])
        XCTAssertFalse(list.trackThrough)
        XCTAssertEqual(list.version, 1, "without a body: no cues, trackThrough off and version 1")
        XCTAssertEqual(edits.library.folder(ofList: list.uuid), "", "at the top of lists/")
        XCTAssertEqual(made.first?.logged, EditCommand(.list(57), .create(body: .object(["uuid": .string(Edits.text(Edits.pick(1)))]),
                                                                            folder: nil, title: nil)),
                       "the logged command records the uuid it picked")
        XCTAssertEqual(made.first?.inverse, EditCommand(.list(57), .delete))
        XCTAssertEqual(made.first?.changes, [LibraryChange(object: "list", address: ["list": .number(57), "listUuid": .string(Edits.text(list.uuid))])])

        edits.apply("edit list 58 create folder \"hymns\"")
        let filed = try XCTUnwrap(edits.list(58))
        XCTAssertEqual(edits.library.folder(ofList: filed.uuid), "Hymns", "a folder named ignoring case, kept as made")
        XCTAssertEqual(edits.library.documentPaths[FileLayout.documentKey(list: filed.uuid)], "lists/Hymns/058.json")

        let cue = Edits.text(F.uuid("c0c0", 1))
        edits.apply("edit list 59 create { \"cues\": [{ \"label\": \"Verse 1\", \"uuid\": \"\(cue)\" }], \"title\": \"Be Thou My Vision\", \"trackThrough\": true, \"version\": 4 }")
        let bodied = try XCTUnwrap(edits.list(59))
        XCTAssertEqual(bodied.title, "Be Thou My Vision")
        XCTAssertTrue(bodied.trackThrough)
        XCTAssertEqual(bodied.version, 4, "a body's fields win, its cues and version included")
        XCTAssertEqual(bodied.cues.map(\.label), ["Verse 1"])
        XCTAssertEqual(edits.library.documentPaths[FileLayout.documentKey(list: bodied.uuid)], "lists/059-be-thou-my-vision.json")
    }

    /// "A number the engine picks ... is one more than the highest of that
    /// type in use or named by any reference, so a new object never takes over
    /// references meant for a deleted one."
    func test_createWithoutANumberGoesPastEveryNumberInUseOrNamed() throws {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit list create").first?.logged.address, .list(43), "42 is the highest in use")
        edits.machine.keys.append(KeyBinding(device: "keyboard", key: "f5", command: .listCue(list: 60, cue: 1)))
        XCTAssertEqual(edits.apply("edit list create").first?.logged.address, .list(61), "a key binding names list 60")
        let p = Edits.text(F.playlistUuid)
        edits.apply("edit playlist \(p) insert items 0 { \"kind\": \"linked\", \"list\": 61 }")
        edits.apply("edit list 61 delete")
        XCTAssertEqual(edits.apply("edit list create").first?.logged.address, .list(62), "a playlist link names deleted list 61")
        XCTAssertEqual(LibraryEditor.nextListNumber(library: edits.library, machine: edits.machine), 63)
    }

    func test_metadataIsSetLikeAnyField() throws {
        var edits = Edits()
        let set = edits.apply("edit list 42 copyright \"Hope Publishing\"")
        XCTAssertEqual(edits.list(42)?.copyright, "Hope Publishing")
        XCTAssertEqual(set.first?.inverse, EditCommand(.list(42), .set(path: "copyright", value: .string("Public domain"))))
        XCTAssertEqual(set.first?.changes.first?.paths, ["copyright"])
        edits.apply("edit list 42 trackThrough true")
        XCTAssertEqual(edits.list(42)?.trackThrough, true)
        XCTAssertEqual(edits.apply("edit list 42 trackThrough true").first?.isNoop, true)

        XCTAssertEqual(edits.refuse("edit list 42 trackThrough \"yes\"")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 title 4")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit list 42 version 99")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 number 43")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 uuid \"x\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 cues []")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 cues.0.label \"x\"")?.reason, .readOnlyField)
        XCTAssertEqual(edits.refuse("edit list 42 timeline {}")?.reason, .notInV1)
        XCTAssertEqual(edits.refuse("edit list 42 colour \"red\"")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit list 42 unset title")?.reason, .badValue)
    }

    /// "Delete removes the list's file. Linked items that name it stay, show
    /// as missing (choice Q-4) and are flagged by the reference report ...
    /// The inverse puts the list back in its folder."
    func test_deleteWhileLinkedLeavesTheItemsMissingAndTheInverseBringsItBackWhole() throws {
        var edits = Edits()
        let original = try XCTUnwrap(edits.list(42))
        let deleted = edits.apply("edit list 42 delete")
        XCTAssertNil(edits.list(42))
        XCTAssertEqual(deleted.first?.structure, [.removeList(original.uuid, path: "lists/Hymns/042-great-is-thy-faithfulness.json")])
        let warning = deleted.first?.warnings.joined() ?? ""
        for title in ["\"Sunday\"", "\"Sunday Night\"", "\"Sunday 2026-11-01\""] {
            XCTAssertTrue(warning.contains(title), "the warning names \(title): \(warning)")
        }
        XCTAssertNil(CueAddressing.list(forItem: 2, in: edits.night, library: edits.library, machine: edits.machine))
        let report = Validator.validate(library: edits.library, machine: edits.machine)
        XCTAssertTrue(report.issues(.missingList).map(\.subject).contains("playlist Sunday Night item 2"), "\(report.lines)")

        // `next` from a loaded Sunday Night skips both missing items: the first cue is list 7's.
        var state = ShowState.fresh(library: edits.library, machine: edits.machine)
        state.pointer = LivePointer(playlist: F.sundayNightUuid)
        let context = ProjectionContext(frame: 0, library: edits.library, machine: edits.machine, source: CommandSource(kind: .osc))
        state = project(state, [.next], context: context).0
        XCTAssertEqual(state.pointer?.listUuid, F.listUuid(7))
        state = project(state, [.next, .next, .next], context: context).0
        XCTAssertEqual(state.pointer?.cueUuid, F.list7Cues[2], "and stops at list 7's end: item 4 is missing too")

        edits.undo(deleted)
        let back = try XCTUnwrap(edits.list(42))
        XCTAssertEqual(back, original, "whole, with its version")
        XCTAssertEqual(edits.library.folder(ofList: back.uuid), "Hymns", "in its folder")
        XCTAssertNotNil(CueAddressing.list(forItem: 2, in: edits.night, library: edits.library, machine: edits.machine))
    }

    /// "Renumber and swap rewrite the links in every playlist, archived ones
    /// included, along with every other reference (Spec 1 §4)."
    func test_renumberRewritesTheLinksInActiveAndArchivedPlaylists() throws {
        var edits = Edits()
        let renumbered = edits.apply("edit list 42 renumber 43")
        XCTAssertEqual(edits.list(43)?.uuid, F.listUuid(42))
        for playlist in [edits.sunday, edits.night, edits.archived] {
            let links = playlist.items.compactMap { item -> Int? in
                if case .linked(let n, F.listUuid(42)?) = item.kind { return n }
                return nil
            }
            XCTAssertFalse(links.isEmpty, playlist.title)
            XCTAssertEqual(Set(links), [43], playlist.title)
        }
        XCTAssertEqual(renumbered.first?.inverse, EditCommand(.list(43), .renumber(to: 42)))
        XCTAssertEqual(edits.refuse("edit list 43 renumber 7")?.reason, .duplicate, "a taken number offers a swap")

        edits.apply("edit list 43 swap 7")
        XCTAssertEqual(edits.list(7)?.uuid, F.listUuid(42))
        XCTAssertEqual(edits.list(43)?.uuid, F.listUuid(7))
        XCTAssertEqual(edits.sunday.items[1].kind, .linked(list: 7, listUuid: F.listUuid(42)))
        XCTAssertEqual(edits.sunday.items[4].kind, .linked(list: 43, listUuid: F.listUuid(7)))
    }

    /// "`edit list 42 duplicate`, or `… duplicate 57`, copies the list into
    /// the same folder with a new uuid for the list and every cue, the same
    /// title and `version` 1."
    func test_duplicateGivesNewUuidsInTheSameFolder() throws {
        var edits = Edits()
        let source = try XCTUnwrap(edits.list(42))
        let made = edits.apply("edit list 42 duplicate")
        let copy = try XCTUnwrap(edits.list(43))
        XCTAssertEqual(copy.uuid, Edits.pick(1))
        XCTAssertEqual(copy.cues.map(\.uuid), (2...5).map(Edits.pick))
        XCTAssertEqual(copy.cues.map(\.commands), source.cues.map(\.commands))
        XCTAssertEqual(copy.title, source.title)
        XCTAssertEqual(copy.version, 1)
        XCTAssertEqual(edits.library.folder(ofList: copy.uuid), "Hymns")
        XCTAssertEqual(made.first?.logged, EditCommand(.list(42), .duplicate(to: 43, title: nil,
                                                                            picks: EditPicks(uuid: Edits.pick(1), cueUuids: (2...5).map(Edits.pick)))))
        XCTAssertEqual(edits.apply("edit list 42 duplicate 57").first?.logged.address, .list(42))
        XCTAssertNotNil(edits.list(57))
        XCTAssertEqual(edits.refuse("edit list 42 duplicate 7")?.reason, .duplicate)
    }

    /// Spec 7 §2 — "`edit list 42 folder "Worship/Hymns"` Moves the list's file
    /// into an existing folder; `""` moves it to the top ... Moving a list or a
    /// folder is a rename on disk, not a save: no `version` goes up".
    func test_aListMovesBetweenFoldersAsARename() throws {
        var edits = Edits()
        let list = try XCTUnwrap(edits.list(42))
        let moved = edits.apply("edit list 42 folder \"christmas\"")
        XCTAssertEqual(edits.library.folder(ofList: list.uuid), "Christmas")
        XCTAssertEqual(edits.list(42)?.version, 17, "no version goes up")
        XCTAssertEqual(moved.first?.structure, [.moveList(list.uuid, from: "lists/Hymns/042-great-is-thy-faithfulness.json",
                                                          to: "lists/Christmas/042-great-is-thy-faithfulness.json")])
        XCTAssertEqual(moved.first?.inverse, EditCommand(.list(42), .folder("Hymns")))
        edits.apply("edit list 42 folder \"\"")
        XCTAssertEqual(edits.library.folder(ofList: list.uuid), "")
        XCTAssertEqual(edits.refuse("edit list 42 folder \"Easter\"")?.reason, .unknownObject)
        // "a move onto one [another file's name] is refused with `duplicate`".
        edits.library.otherFiles.insert("lists/Hymns/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(edits.refuse("edit list 42 folder \"Hymns\"")?.reason, .duplicate)
    }

    /// Spec 7 §2 — "Anything that names the number alone, such as `list 57 cue
    /// 3` or an edit, gets the one that comes first".
    func test_anEditOfANumberTwoListsShareReachesTheFirst() throws {
        var edits = Edits()
        var second = try XCTUnwrap(edits.list(42))
        second.uuid = F.uuid("5ec0", 42)
        second.title = "The second 42"
        edits.library.lists.insert(second, at: 2)
        edits.apply("edit list 42 author \"First\"")
        XCTAssertEqual(edits.library.list(uuid: F.listUuid(42))?.author, "First")
        XCTAssertEqual(edits.library.list(uuid: second.uuid)?.author, "Thomas Chisholm")
    }
}

extension Edits {
    static func text(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }
}
