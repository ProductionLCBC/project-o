import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §5, §6 and §10 — the edits that ask first, look something up
/// first or show something after, and the fields that commit: what each
/// sends, and when it sends nothing.
@MainActor
final class ShowModelFlowTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    /// A rig whose window answers each question as the test says, and records what was asked.
    @MainActor
    final class Asking {
        let rig: Rig
        var asked: [Confirmation] = []
        var answer = true

        init() throws {
            rig = try Rig()
            rig.model.confirm = { [unowned self] confirmation, reply in
                self.asked.append(confirmation)
                reply(self.answer)
            }
        }
    }

    private let sunday = "b1a70000-0000-4000-8000-000000000001"

    private func lock(_ rig: Rig, _ on: Bool = true) throws {
        var engine = try RecordedAPI.event("engine")
        engine["lock"] = .bool(on)
        rig.store.apply(event: "engine", engine, now: rig.clock.now)
    }

    // MARK: - Questions first

    func test_deletingAPlaylistAsksFirstAndSaysWhatHappensWhenItIsLive() throws {
        let asking = try Asking()
        let rig = asking.rig
        asking.answer = false
        rig.model.deletePlaylist(sunday)
        XCTAssertEqual(asking.asked, [.deletePlaylist(title: "Sunday", isLive: true)], "the recorded state has Sunday live")
        XCTAssertEqual(rig.sent.count, 0, "Cancel sends nothing")
        asking.answer = true
        rig.model.deletePlaylist(Recorded.sundayNight)
        XCTAssertEqual(asking.asked.last, .deletePlaylist(title: "Sunday Night", isLive: false))
        XCTAssertEqual(rig.commands, [["edit playlist \(Recorded.sundayNight) delete"]])
        // With no window to ask, nothing that needs asking is done.
        rig.model.confirm = nil
        rig.model.deletePlaylist(sunday)
        XCTAssertEqual(rig.sent.count, 1)
    }

    /// "Remove from Playlist (`… item I remove`; on the live item it says the song finishes first, Spec 7 §4)".
    func test_removingAnItemAsksOnlyForTheLiveOne() throws {
        let asking = try Asking()
        let rig = asking.rig
        let items = try XCTUnwrap(rig.store.catalog?.playlist(uuid: sunday)?.playlist.items)
        let last = items[4].uuid.uuidString.lowercased()
        rig.model.removeItem(last, from: sunday)
        XCTAssertEqual(asking.asked, [], "undo is the way back from any other item")
        XCTAssertEqual(rig.commands, [["edit playlist \(sunday) item \(last) remove"]])
        let live = try XCTUnwrap(rig.store.live.item)
        rig.model.removeItem(live, from: sunday)
        XCTAssertEqual(asking.asked, [.removeLiveItem(title: "Great Is Thy Faithfulness")])
        XCTAssertEqual(rig.commands.last, ["edit playlist \(sunday) item \(live) remove"])
    }

    /// "Delete… (`edit list N delete`, after a confirmation naming the playlists that link it, from `listUse`)".
    func test_deletingAListLooksUpThePlaylistsThatLinkItThenAsks() throws {
        let asking = try Asking()
        let rig = asking.rig
        rig.model.deleteList(Recorded.list42)
        XCTAssertEqual(rig.sent.first?.type, "query")
        XCTAssertEqual(rig.sent.first?.fields["what"], .string("listUse"))
        XCTAssertEqual(rig.sent.first?.fields["listUuid"], .string(Recorded.list42))
        XCTAssertEqual(asking.asked, [], "it asks once it knows")
        rig.answers[0](.answer(try RecordedAPI.load("listUse-42")))
        guard case .deleteList(let title, let playlists)? = asking.asked.first else { return XCTFail("\(asking.asked)") }
        XCTAssertEqual(title, "Great Is Thy Faithfulness")
        XCTAssertFalse(playlists.isEmpty, "the playlists the recorded answer names")
        XCTAssertEqual(rig.commands.last, ["edit list 42 delete"])
    }

    /// "New List ... browses the new, empty list, which its result names (§3)".
    func test_aNewListIsBrowsedOnceItsResultNamesIt() throws {
        let rig = try Rig()
        XCTAssertNil(rig.model.newList(in: "Hymns", title: "Amazing Grace"))
        XCTAssertEqual(rig.commands, [["edit list create folder \"Hymns\" { \"title\": \"Amazing Grace\" }"]])
        let made = "a9f00000-0000-4000-8000-000000000039"
        let command: JSONValue = .object(["cmd": .string("edit.create"), "object": .string("list"), "list": .number(57), "folder": .string("Hymns"),
                                          "value": .object(["uuid": .string(made), "number": .number(57)])])
        rig.answers[0](.result(CommandOutcome(kind: .ok, group: "g-2", applied: [AppliedEdit(command: command, inverse: nil)])))
        XCTAssertEqual(rig.model.browse.shown, .list(made))
        XCTAssertNil(rig.model.newList(in: nil, title: "  "))
        XCTAssertEqual(rig.commands.last, ["edit list create { \"title\": \"New List\" }"])
    }

    func test_addToPlaylistAppendsALinkedItemNamedByItsUuid() throws {
        let rig = try Rig()
        rig.model.add(list: Recorded.list7, toPlaylist: Recorded.sundayNight)
        XCTAssertEqual(rig.commands, [["edit playlist \(Recorded.sundayNight) insert items 4 { \"kind\": \"linked\", \"list\": 7, \"listUuid\": \"\(Recorded.list7)\" }"]],
                       "after its four items")
        rig.model.add(list: Recorded.list7, toPlaylist: sunday, at: 1)
        XCTAssertEqual(rig.commands.last?.first?.contains("insert items 1 "), true)
    }

    // MARK: - Fields that commit

    /// "Text fields in show mode ... each send one edit when they commit, never while typing".
    func test_aRenameSendsOneEditAndAnEmptyOrUnchangedNameSendsNothing() throws {
        let rig = try Rig()
        XCTAssertNil(rig.model.rename(playlist: sunday, to: "  Sunday AM "))
        XCTAssertEqual(rig.commands, [["edit playlist \(sunday) title \"Sunday AM\""]], "what was typed, without the spaces around it")
        XCTAssertNil(rig.model.rename(playlist: sunday, to: "Sunday"))
        XCTAssertNil(rig.model.rename(playlist: sunday, to: "   "))
        XCTAssertNil(rig.model.rename(list: Recorded.list42, to: "Great Is Thy Faithfulness"))
        XCTAssertNil(rig.model.rename(folder: "Hymns", to: "Hymns"))
        XCTAssertNil(rig.model.newPlaylist(title: ""))
        XCTAssertEqual(rig.sent.count, 1, "nothing changed, nothing sent, and the field may close")
        XCTAssertNil(rig.model.newPlaylist(title: "Christmas Eve"))
        XCTAssertNil(rig.model.rename(list: Recorded.list42, to: "Great Is Thy Faithfulness (Runyan)"))
        XCTAssertNil(rig.model.rename(folder: "Hymns", to: "Old Hymns"))
        XCTAssertNil(rig.model.duplicate(playlist: sunday, as: "Sunday copy"))
        XCTAssertNil(rig.model.schedule(playlist: sunday, date: "2026-11-08", time: "09:00"))
        let items = try XCTUnwrap(rig.store.catalog?.playlist(uuid: sunday)?.playlist.items)
        XCTAssertNil(rig.model.addHeader("Offering", above: items[3].uuid.uuidString.lowercased(), in: sunday))
        XCTAssertNil(rig.model.rename(header: items[0].uuid.uuidString.lowercased(), in: sunday, to: "Gathering"))
        XCTAssertNil(rig.model.rename(header: items[1].uuid.uuidString.lowercased(), in: sunday, to: "Not a header"), "a linked item has no label")
        XCTAssertEqual(Array(rig.commands.dropFirst()), [
            ["edit playlist create \"Christmas Eve\""],
            ["edit list 42 title \"Great Is Thy Faithfulness (Runyan)\""],
            ["edit folder \"Hymns\" rename \"Old Hymns\""],
            ["edit playlist \(sunday) duplicate \"Sunday copy\""],
            ["edit playlist \(sunday) serviceDate \"2026-11-08\"", "edit playlist \(sunday) serviceTime \"09:00\""],
            ["edit playlist \(sunday) insert items 3 { \"kind\": \"header\", \"label\": \"Offering\" }"],
            ["edit playlist \(sunday) item \(items[0].uuid.uuidString.lowercased()) label \"Gathering\""],
        ])
    }

    /// "A commit that can't be sent, because the lock came on or the engine
    /// went away, leaves the field open with its text, the reason and Copy."
    func test_aCommitThatCannotBeSentSaysWhyAndSendsNothing() throws {
        let rig = try Rig()
        try lock(rig)
        XCTAssertEqual(rig.model.rename(playlist: sunday, to: "Sunday AM"), .unavailable(.locked))
        XCTAssertEqual(rig.model.newPlaylist(title: "Christmas Eve"), .unavailable(.locked))
        XCTAssertEqual(rig.model.rename(folder: "Hymns", to: "Old Hymns"), .unavailable(.locked))
        try lock(rig, false)
        rig.store.disconnected()
        XCTAssertEqual(rig.model.rename(playlist: sunday, to: "Sunday AM"), .unavailable(.engineAway))
        XCTAssertEqual(rig.sent.count, 0)
        // The same name back is still nothing to send, whatever stands in the way.
        XCTAssertNil(rig.model.rename(playlist: sunday, to: "Sunday"))
    }

    func test_aNewFolderIsMadeWhereItWasAskedForAndItsParentOpened() throws {
        let rig = try Rig()
        XCTAssertFalse(rig.model.settings.openFolders.contains("Christmas"))
        XCTAssertNil(rig.model.newFolder("Carols", in: "Christmas"))
        XCTAssertEqual(rig.commands, [["edit folder \"Christmas/Carols\" create"]])
        XCTAssertTrue(rig.model.settings.openFolders.contains("Christmas"), "so the new folder shows")
        XCTAssertNil(rig.model.newFolder("Easter", in: ""))
        XCTAssertEqual(rig.commands.last, ["edit folder \"Easter\" create"])
        XCTAssertNil(rig.model.newFolder("  ", in: ""))
        XCTAssertEqual(rig.sent.count, 2)
    }

    func test_whetherAFolderIsEmpty() throws {
        let rig = try Rig()
        let folders = try XCTUnwrap(rig.store.catalog?.lists.filter { !$0.local }.map(\.folder))
        for folder in Set(folders) where !folder.isEmpty { XCTAssertFalse(rig.model.isEmpty(folder: folder), folder) }
        XCTAssertTrue(rig.model.isEmpty(folder: "Nothing In Here"))
    }

    // MARK: - A cue's edits

    func test_aCuesEditsNameItsListByNumberAndTheCueByItsUuid() throws {
        let rig = try Rig()
        let (verse, section) = rig.cell(1, 1)
        let c = verse.uuid
        XCTAssertNil(rig.model.note("Wait for the pastor", cell: verse, in: section))
        XCTAssertNil(rig.model.note("", cell: verse, in: section), "the note it has: nothing to send")
        XCTAssertNil(rig.model.trigger(.time(ms: 8000), cell: verse, in: section))
        XCTAssertNil(rig.model.trigger(.go, cell: verse, in: section), "it is Go already")
        XCTAssertNil(rig.model.advanceAfter(ms: 12_000, cell: verse, in: section))
        XCTAssertNil(rig.model.advanceAfter(ms: nil, cell: verse, in: section), "it has none already")
        XCTAssertNil(rig.model.duplicateSection(cell: verse, in: section))
        XCTAssertEqual(rig.commands, [["edit list 42 cue \(c) note \"Wait for the pastor\""], ["edit list 42 cue \(c) trigger { \"ms\": 8000, \"type\": \"time\" }"],
                                      ["edit list 42 cue \(c) advanceAfterMs 12000"], ["edit list 42 cue \(c) section duplicate"]])
    }

    /// Spec 10 §10, "In-place text".
    func test_inPlaceTextOpensOnTheBodyAndCommitsOneEdit() throws {
        let rig = try Rig()
        let (verse, section) = rig.cell(1, 1)
        XCTAssertEqual(rig.model.textBody(of: verse, in: section), "There is no shadow\nof turning with Thee")
        XCTAssertTrue(rig.model.cueContext(verse, in: section).hasText)
        XCTAssertNil(rig.model.commitText("There is no shadow\nof turning with Thee", cell: verse, in: section))
        XCTAssertEqual(rig.sent.count, 0, "unchanged: nothing sent")
        XCTAssertNil(rig.model.commitText("There is no shadow\nof turning", cell: verse, in: section))
        XCTAssertEqual(rig.commands, [["edit list 42 cue \(verse.uuid) channel 2 write text \"There is no shadow\\nof turning\""]])
        try lock(rig)
        XCTAssertEqual(rig.model.commitText("x", cell: verse, in: section), .unavailable(.locked))
        XCTAssertEqual(rig.sent.count, 1)
    }

    /// "A local copy isn't editable in v1 (Spec 5 §3)."
    func test_aLocalCopysCuesFireAndAreNotEdited() throws {
        let rig = try Rig()
        let (cue, section) = rig.cell(2, 0)
        XCTAssertTrue(section.isLocal)
        let context = rig.model.cueContext(cue, in: section)
        XCTAssertNil(context.fire)
        XCTAssertEqual(context.edit, .localCopy)
        XCTAssertEqual(rig.model.note("x", cell: cue, in: section), .localCopy)
        XCTAssertEqual(rig.model.commitText("x", cell: cue, in: section), .localCopy)
        XCTAssertEqual(rig.model.duplicateSection(cell: cue, in: section), .localCopy)
        XCTAssertEqual(rig.sent.count, 0)
    }

    // MARK: - A list header

    func test_aListHeadersMenuOffersAGradeForEachChannelTheListWritesContentTo() throws {
        let rig = try Rig()
        let section = rig.model.grid.sections[1]
        let menu = rig.model.headerMenu(for: section)
        XCTAssertEqual(menu.filter { $0.kind != .separator }.map(EditWording.title),
                       ["Remove from Playlist", "Show in Library", "Open in Text Editor", "Grade for Channel 1 Background", "Grade for Channel 2 Foreground",
                        "Restore a Version…"])
        // The local copy: no master to show in the library, and no edit of it.
        let local = rig.model.headerMenu(for: rig.model.grid.sections[2])
        XCTAssertFalse(local.contains { $0.kind == .showInLibrary })
        XCTAssertEqual(local.first { $0.kind == .restoreVersion }?.reason, .localCopy)
        XCTAssertTrue(local.first { $0.kind == .removeItem }?.isEnabled ?? false, "its item is the playlist's, and can be removed")
    }

    func test_theGradePickerSendsOneEditAndTheSameGradeNothing() throws {
        let rig = try Rig()
        let section = rig.model.grid.sections[1]
        let first = try XCTUnwrap(rig.store.lists[Recorded.list42]?.list.cues.first).uuid.uuidString.lowercased()
        XCTAssertNil(rig.model.grade(nil, channel: 2, in: section), "None, and it tracks none")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertNil(rig.model.grade(3, channel: 2, in: section))
        XCTAssertEqual(rig.commands, [["edit list 42 cue \(first) channel 2 write text \"Great is Thy faithfulness,\\nO God my Father\" grade 3 track"]])
        XCTAssertEqual(rig.model.grade(1, channel: 2, in: rig.model.grid.sections[2]), .localCopy)
    }
}
