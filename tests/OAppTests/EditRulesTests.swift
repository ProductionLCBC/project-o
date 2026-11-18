import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §5 and §6 — what each menu offers, and when an entry is disabled
/// and why: "The menus show only what the engine would accept".
final class MenusTests: XCTestCase {
    private func kinds(_ entries: [MenuEntry]) -> [MenuEntry.Kind] { entries.map(\.kind).filter { $0 != .separator } }

    private func entry(_ kind: MenuEntry.Kind, in entries: [MenuEntry], file: StaticString = #filePath, line: UInt = #line) throws -> MenuEntry {
        try XCTUnwrap(entries.first { $0.kind == kind }, "\(kind)", file: file, line: line)
    }

    private func live(playlist: String?, fired: Bool = true) -> LiveStatus {
        var live = LiveStatus()
        live.playlist = playlist
        live.cue = fired ? "11aa" : nil
        return live
    }

    func test_aPlaylistsMenu() throws {
        let sunday = try XCTUnwrap(try Recorded.catalog().playlist(uuid: Recorded.sunday))
        let menu = Menus.playlist(sunday, live: live(playlist: nil), cannotSend: nil, cannotEdit: nil)
        XCTAssertEqual(kinds(menu), [.makeLive, .renamePlaylist, .dateAndTime, .duplicatePlaylist, .archiveCopy, .archive, .deletePlaylist])
        XCTAssertTrue(menu.allSatisfy(\.isEnabled))
        // "Archive (`… archived true`, disabled while it is live)"; Archive a Copy "works while it is live".
        let whileLive = Menus.playlist(sunday, live: live(playlist: Recorded.sunday), cannotSend: nil, cannotEdit: nil)
        XCTAssertEqual(try entry(.archive, in: whileLive).reason, .liveNow)
        XCTAssertTrue(try entry(.archiveCopy, in: whileLive).isEnabled)
        XCTAssertTrue(try entry(.deletePlaylist, in: whileLive).isEnabled, "it may be deleted while live: the confirmation says what happens")
        // Area 13 reading — Make Live on the playlist that is live and has fired would put the pointer back before cue 1.
        XCTAssertEqual(try entry(.makeLive, in: whileLive).reason, .alreadyLive)
        XCTAssertTrue(try entry(.makeLive, in: Menus.playlist(sunday, live: live(playlist: Recorded.sunday, fired: false), cannotSend: nil, cannotEdit: nil)).isEnabled,
                      "loaded and not yet fired, it is where Make Live would put it")
    }

    /// "an archived playlist offers only Make Live, Duplicate, Archive a Copy, Restore from Archive and Delete (Spec 7 §5)."
    func test_anArchivedPlaylistOffersOnlyWhatTheEngineWouldAccept() throws {
        let archived = try XCTUnwrap(try Recorded.catalog().playlists.first { $0.playlist.archived })
        let menu = Menus.playlist(archived, live: live(playlist: nil), cannotSend: nil, cannotEdit: nil)
        XCTAssertEqual(kinds(menu), [.makeLive, .duplicatePlaylist, .archiveCopy, .restoreFromArchive, .deletePlaylist])
        XCTAssertTrue(try entry(.makeLive, in: menu).isEnabled, "an archive can be run")
        // A playlist whose title loads another can't be made live: "Rename to fire" (§6).
        var twin = archived
        twin.named = false
        XCTAssertEqual(try entry(.makeLive, in: Menus.playlist(twin, live: live(playlist: nil), cannotSend: nil, cannotEdit: nil)).reason, .fire(.renameToFire))
        // Its items take no edit.
        let item = archived.playlist.items[1]
        XCTAssertEqual(try entry(.removeItem, in: Menus.item(item, in: archived, cannotEdit: nil)).reason, .archived)
    }

    func test_theEngineAwayTheLockAndReadOnlyMastersDisableWithTheirReason() throws {
        let catalog = try Recorded.catalog()
        let sunday = try XCTUnwrap(catalog.playlist(uuid: Recorded.sunday))
        let away = Menus.playlist(sunday, live: live(playlist: nil), cannotSend: .engineAway, cannotEdit: .engineAway)
        XCTAssertTrue(away.filter { $0.kind != .separator }.allSatisfy { $0.reason == .unavailable(.engineAway) })
        // Under the lock a playlist can still be made live, and nothing of it edited.
        let locked = Menus.playlist(sunday, live: live(playlist: nil), cannotSend: nil, cannotEdit: .locked)
        XCTAssertTrue(try entry(.makeLive, in: locked).isEnabled)
        XCTAssertEqual(try entry(.renamePlaylist, in: locked).reason, .unavailable(.locked))
        // Masters read-only: a list's own edits are off, and adding it to a playlist, a machine document, is not.
        let list = try XCTUnwrap(catalog.list(uuid: Recorded.list42))
        let readOnly = Menus.list(list, playlists: catalog.playlists, cannotEditMasters: .readOnlyMasters, cannotEditMachine: nil)
        XCTAssertEqual(try entry(.renameList, in: readOnly).reason, .unavailable(.readOnlyMasters))
        XCTAssertEqual(try entry(.deleteList, in: readOnly).reason, .unavailable(.readOnlyMasters))
        XCTAssertEqual(try entry(.newListHere, in: readOnly).reason, .unavailable(.readOnlyMasters))
        XCTAssertTrue(try entry(.addToPlaylistMenu, in: readOnly).isEnabled)
        XCTAssertTrue(try entry(.addToPlaylistMenu, in: readOnly).children.allSatisfy(\.isEnabled))
    }

    func test_anItemsMenu() throws {
        let sunday = try XCTUnwrap(try Recorded.catalog().playlist(uuid: Recorded.sunday))
        let header = sunday.playlist.items[0]
        let linked = sunday.playlist.items[1]
        let local = sunday.playlist.items[2]
        XCTAssertEqual(kinds(Menus.item(header, in: sunday, cannotEdit: nil)), [.removeItem, .addHeaderAbove, .renameHeader], "Rename, for a header")
        XCTAssertEqual(kinds(Menus.item(linked, in: sunday, cannotEdit: nil)), [.removeItem, .addHeaderAbove, .showInLibrary], "Show in Library, for a linked item")
        XCTAssertEqual(kinds(Menus.item(local, in: sunday, cannotEdit: nil)), [.removeItem, .addHeaderAbove])
    }

    func test_aListsMenuAndAListWhoseNumberAnotherShares() throws {
        let catalog = try Recorded.catalog()
        let list = try XCTUnwrap(catalog.list(uuid: Recorded.list42))
        let menu = Menus.list(list, playlists: catalog.playlists, cannotEditMasters: nil, cannotEditMachine: nil)
        XCTAssertEqual(kinds(menu), [.addToPlaylistMenu, .renameList, .duplicateList, .openInTextEditor, .restoreVersion, .deleteList, .newListHere])
        // "Add to Playlist ▸ (the playlists ...)": the ones that take an item, in the tree's order; an archived one takes none.
        XCTAssertEqual(try entry(.addToPlaylistMenu, in: menu).children.map(\.name), ["Sunday Night", "Sunday"])
        XCTAssertEqual(try entry(.openInTextEditor, in: menu).reason, .later, "Area 10's")
        // Adam's answer to the Area 13 plan — "A list whose number another shares: its edits are disabled too", with "Renumber to edit".
        var twin = list
        twin.named = false
        let shared = Menus.list(twin, playlists: catalog.playlists, cannotEditMasters: nil, cannotEditMachine: nil)
        for kind in [MenuEntry.Kind.renameList, .duplicateList, .restoreVersion, .deleteList] {
            XCTAssertEqual(try entry(kind, in: shared).reason, .renumberToEdit, "\(kind)")
        }
        XCTAssertTrue(try entry(.addToPlaylistMenu, in: shared).isEnabled, "an insert names the list by its uuid")
        XCTAssertEqual(Menus.cannotEdit(list: twin, cannotEditMasters: nil), .renumberToEdit)
        // "A local copy isn't editable in v1 (Spec 5 §3)."
        let local = try XCTUnwrap(catalog.list(uuid: Recorded.localCopy))
        XCTAssertEqual(Menus.cannotEdit(list: local, cannotEditMasters: nil), .localCopy)
        // With no playlist to add to, the submenu has nothing to offer.
        XCTAssertFalse(try entry(.addToPlaylistMenu, in: Menus.list(list, playlists: [], cannotEditMasters: nil, cannotEditMachine: nil)).isEnabled)
    }

    func test_aFoldersMenu() throws {
        XCTAssertEqual(kinds(Menus.folder(isEmpty: true, cannotEditMasters: nil)), [.renameFolder, .newFolder, .newListHere, .deleteFolder])
        XCTAssertTrue(try entry(.deleteFolder, in: Menus.folder(isEmpty: true, cannotEditMasters: nil)).isEnabled)
        XCTAssertEqual(try entry(.deleteFolder, in: Menus.folder(isEmpty: false, cannotEditMasters: nil)).reason, .folderNotEmpty,
                       "Delete Folder is enabled only for an empty folder")
        XCTAssertEqual(kinds(Menus.libraryTop(cannotEditMasters: nil)), [.newFolder, .newListHere])
    }

    /// "A cue's menu: Fire; Edit Text (for a text cue, without firing it);
    /// Edit Cue ...; Note… ...; Trigger ▸ Go, Time after Previous…
    /// (seconds), Advance After… (seconds or none); Duplicate Section ...;
    /// and Hold, on the armed cue".
    func test_aCuesMenu() throws {
        let text = Menus.cue(.init(hasText: true))
        XCTAssertEqual(kinds(text), [.fire, .editText, .editCue, .note, .triggerMenu, .duplicateSection])
        XCTAssertEqual(try entry(.editCue, in: text).reason, .later, "edit mode is Area 14's")
        let trigger = try entry(.triggerMenu, in: text).children
        XCTAssertEqual(kinds(trigger), [.triggerGo, .triggerTime, .advanceAfter])
        XCTAssertEqual(trigger.filter(\.isOn).map(\.kind), [.triggerGo], "the cue's trigger is ticked")
        let timed = Menus.cue(.init(hasText: false, trigger: .time(ms: 8000), advanceAfterMs: 12_000, isArmed: true))
        XCTAssertEqual(kinds(timed), [.fire, .editCue, .note, .triggerMenu, .duplicateSection, .hold], "no Edit Text on a cue with no text; Hold on the armed cue")
        XCTAssertEqual(try entry(.triggerMenu, in: timed).children.filter(\.isOn).map(\.kind), [.triggerTime, .advanceAfter])
        // A cue of a local copy fires and isn't edited.
        let local = Menus.cue(.init(edit: .localCopy, hasText: true))
        XCTAssertTrue(try entry(.fire, in: local).isEnabled)
        for kind in [MenuEntry.Kind.editText, .note, .duplicateSection] { XCTAssertEqual(try entry(kind, in: local).reason, .localCopy, "\(kind)") }
        XCTAssertEqual(try entry(.fire, in: Menus.cue(.init(fire: .fire(.renameToFire)))).reason, .fire(.renameToFire))
    }

    /// "Its menu: Remove from Playlist; Show in Library; Open in Text Editor
    /// ...; Grade for Channel N ▸ (§10, one submenu per channel the list
    /// writes content to); Restore a Version… (§14)."
    func test_aListHeadersMenu() throws {
        let grades = try Recorded.catalog().grades
        let channels = [Menus.GradeChoice(channel: 1, label: "Background", tracked: nil), Menus.GradeChoice(channel: 2, label: "Foreground", tracked: 1)]
        let menu = Menus.listHeader(inPlaylist: true, isLinked: true, removeItem: nil, edit: nil, channels: channels, grades: grades)
        XCTAssertEqual(kinds(menu), [.removeItem, .showInLibrary, .openInTextEditor, .gradeMenu(channel: 1), .gradeMenu(channel: 2), .restoreVersion])
        let two = try entry(.gradeMenu(channel: 2), in: menu)
        XCTAssertEqual(two.name, "Foreground")
        XCTAssertEqual(two.children.first?.kind, .grade(channel: 2, grade: nil), "None first")
        XCTAssertEqual(two.children.count, grades.count + 1)
        XCTAssertEqual(two.children.filter(\.isOn).map(\.kind), [.grade(channel: 2, grade: 1)], "the grade its first write tracks")
        XCTAssertEqual(try entry(.gradeMenu(channel: 1), in: menu).children.filter(\.isOn).map(\.kind), [.grade(channel: 1, grade: nil)])
        // From the library there is no playlist to remove it from; a local copy has no master to show, and isn't edited.
        let local = Menus.listHeader(inPlaylist: true, isLinked: false, removeItem: nil, edit: .localCopy, channels: channels, grades: grades)
        XCTAssertEqual(kinds(local), [.removeItem, .openInTextEditor, .gradeMenu(channel: 1), .gradeMenu(channel: 2), .restoreVersion])
        XCTAssertEqual(try entry(.restoreVersion, in: local).reason, .localCopy)
        XCTAssertTrue(try entry(.gradeMenu(channel: 1), in: local).children.allSatisfy { $0.reason == .localCopy })
        XCTAssertEqual(kinds(Menus.listHeader(inPlaylist: false, isLinked: true, removeItem: nil, edit: nil, channels: [], grades: grades)),
                       [.showInLibrary, .openInTextEditor, .restoreVersion])
    }

    /// "A tile's menu: Fire to Channel N (its drop channel); Fire to… (a
    /// channel); Defaults… ...; Replace with… ...; Reveal in Finder; Delete…".
    func test_aPoolTilesMenu() throws {
        let catalog = try Recorded.catalog()
        let media = try Recorded.media()
        let dawn = try XCTUnwrap(media.first { !$0.isMissing && $0.index == "library" })
        let menu = Menus.tile(dawn, dropChannel: 1, channels: catalog.channels, cannotSend: nil, cannotEditMasters: nil, cannotEditMachine: nil)
        XCTAssertEqual(kinds(menu), [.fireTo(channel: 1), .fireToMenu, .defaults, .replace, .reveal, .deleteMedia])
        XCTAssertEqual(try entry(.fireTo(channel: 1), in: menu).name, "Background")
        XCTAssertEqual(try entry(.fireToMenu, in: menu).children.map(\.kind), [.fireTo(channel: 1), .fireTo(channel: 2), .fireTo(channel: 3)])
        // With "Ask" for its kind there is no drop channel: only Fire to….
        XCTAssertEqual(kinds(Menus.tile(dawn, dropChannel: nil, channels: catalog.channels, cannotSend: nil, cannotEditMasters: nil, cannotEditMachine: nil)).first,
                       .fireToMenu)
        // Spec 8 §2 — on a read-only-masters machine a library item isn't replaced or deleted; this Mac's own media is.
        let readOnly = Menus.tile(dawn, dropChannel: 1, channels: catalog.channels, cannotSend: nil, cannotEditMasters: .readOnlyMasters, cannotEditMachine: nil)
        XCTAssertTrue(try entry(.fireTo(channel: 1), in: readOnly).isEnabled, "a live write is not an edit")
        for kind in [MenuEntry.Kind.defaults, .replace, .deleteMedia] {
            XCTAssertEqual(try entry(kind, in: readOnly).reason, .unavailable(.readOnlyMasters), "\(kind)")
        }
        let own = try XCTUnwrap(media.first { $0.index == "machine" })
        XCTAssertTrue(try entry(.deleteMedia, in: Menus.tile(own, dropChannel: 1, channels: catalog.channels, cannotSend: nil,
                                                            cannotEditMasters: .readOnlyMasters, cannotEditMachine: nil)).isEnabled)
        // A missing item can't go live or be shown, and can still be replaced or deleted.
        let missing = try XCTUnwrap(media.first(where: \.isMissing))
        let gone = Menus.tile(missing, dropChannel: 1, channels: catalog.channels, cannotSend: nil, cannotEditMasters: nil, cannotEditMachine: nil)
        XCTAssertEqual(try entry(.fireTo(channel: 1), in: gone).reason, .missing)
        XCTAssertEqual(try entry(.reveal, in: gone).reason, .missing)
        XCTAssertTrue(try entry(.replace, in: gone).isEnabled)
        XCTAssertTrue(try entry(.deleteMedia, in: gone).isEnabled)
    }
}

/// Spec 10 §10, "Undo and redo" — "Their names come from the `history`
/// topic's top groups, made plain from the first command's verb".
final class HistoryKindTests: XCTestCase {
    func test_aStepsKindFromItsFirstCommandsVerb() {
        let p = "b1a70000-0000-4000-8000-000000000001"
        let c = "22bb0000-0000-4000-8000-000000000002"
        let steps: [(String, HistoryKind)] = [
            ("edit list 42 title \"Great Is Thy Faithfulness (Runyan)\"", .rename),
            ("edit playlist \(p) title \"Sunday AM\"", .rename),
            ("edit playlist \(p) item ae3aafe3-0000-4000-8000-000000000000 label \"Gathering\"", .rename),
            ("edit folder \"Hymns\" rename \"Old Hymns\"", .rename),
            ("edit channel 2 label \"Lyrics\"", .rename),
            ("edit list 42 cue \(c) channel 2 write text \"Morning by morning\"", .typing),
            ("edit playlist create \"Christmas Eve\"", .add),
            ("edit playlist \(p) insert items 3 { \"kind\": \"header\", \"label\": \"Offering\" }", .add),
            ("edit folder \"Easter\" create", .add),
            ("edit list 42 delete", .remove),
            ("edit playlist \(p) item ae3aafe3-0000-4000-8000-000000000000 remove", .remove),
            ("edit list 42 cue \(c) section remove", .remove),
            ("edit playlist \(p) item ae3aafe3-0000-4000-8000-000000000000 move 3", .move),
            ("edit list 42 folder \"Hymns\"", .move),
            ("edit list 42 duplicate", .duplicate),
            ("edit playlist \(p) archive", .duplicate),
            ("edit list 42 cue \(c) section duplicate", .duplicate),
            ("media delete sha256:" + String(repeating: "ab", count: 32), .deleteMedia),
            ("system restore list 42 version 16", .restore),
            ("system restore snapshot \"2026-11-08T08-59-00Z-launch\"", .restore),
            ("edit list 42 cue \(c) note \"Wait\"", .change),
            ("edit list 42 cue \(c) channel 1 write media sha256:" + String(repeating: "ab", count: 32), .change),
            ("edit playlist \(p) archived true", .change),
            ("edit media sha256:" + String(repeating: "ab", count: 32) + " defaults.loop false", .change),
            ("edit channel 2 renumber 5", .change),
            ("something a newer build wrote", .change),
            ("", .change),
        ]
        for (text, kind) in steps { XCTAssertEqual(HistoryKind.of(text: text), kind, text) }
    }

    func test_whatAStepActedOnIsNamedFromTheCatalog() throws {
        let catalog = try Recorded.catalog()
        let media = try Recorded.media()
        let p = Recorded.sunday
        let c = "22bb0000-0000-4000-8000-000000000002"
        func object(_ text: String) -> EditedObject { EditedObject.of(text: text, catalog: catalog, media: media) }
        XCTAssertEqual(object("edit playlist \(p) title \"Sunday AM\""), .playlist("Sunday"))
        XCTAssertEqual(object("edit playlist create \"Christmas Eve\""), .playlist("Christmas Eve"), "a playlist that isn't made yet, by the title it will have")
        XCTAssertEqual(object("edit playlist \(p) insert items 3 { \"kind\": \"header\", \"label\": \"Offering\" }"), .item(playlist: "Sunday"))
        XCTAssertEqual(object("edit playlist \(p) item ae3aafe3-0000-4000-8000-000000000000 remove"), .item(playlist: "Sunday"))
        XCTAssertEqual(object("edit list 42 title \"X\""), .list("Great Is Thy Faithfulness"))
        XCTAssertEqual(object("edit list 42 cue \(c) note \"Wait\""), .cue(list: "Great Is Thy Faithfulness"))
        XCTAssertEqual(object("edit list 7 delete"), .list("Doxology"))
        XCTAssertEqual(object("edit folder \"Hymns\" rename \"Old Hymns\""), .folder("Hymns"))
        XCTAssertEqual(object("system restore list 42 version 16"), .list("Great Is Thy Faithfulness"))
        XCTAssertEqual(object("system restore snapshot \"x\""), .library)
        XCTAssertEqual(object("not a command"), .library)
        let item = try XCTUnwrap(media.first)
        XCTAssertEqual(object("media delete \(item.id)"), .media((item.entry.path as NSString).lastPathComponent))
        XCTAssertEqual(object("edit media \(item.id) defaults.loop false"), .media((item.entry.path as NSString).lastPathComponent))
    }
}

/// Spec 10 §5, §6, §10, §14 and §15 — the edits' words, every one from the string catalog.
@MainActor
final class EditWordingTests: XCTestCase {
    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    func test_everyMenuEntryHasItsTitle() throws {
        let catalog = try Recorded.catalog()
        let sunday = try XCTUnwrap(catalog.playlist(uuid: Recorded.sunday))
        XCTAssertEqual(Menus.playlist(sunday, live: LiveStatus(), cannotSend: nil, cannotEdit: nil).filter { $0.kind != .separator }.map(EditWording.title),
                       ["Make Live", "Rename", "Date and Time…", "Duplicate…", "Archive a Copy", "Archive", "Delete…"])
        let archived = try XCTUnwrap(catalog.playlists.first { $0.playlist.archived })
        XCTAssertEqual(Menus.playlist(archived, live: LiveStatus(), cannotSend: nil, cannotEdit: nil).filter { $0.kind != .separator }.map(EditWording.title),
                       ["Make Live", "Duplicate…", "Archive a Copy", "Restore from Archive", "Delete…"])
        XCTAssertEqual(Menus.item(sunday.playlist.items[0], in: sunday, cannotEdit: nil).map(EditWording.title), ["Remove from Playlist", "Add Header Above", "Rename"])
        let list = try XCTUnwrap(catalog.list(uuid: Recorded.list42))
        let listMenu = Menus.list(list, playlists: catalog.playlists, cannotEditMasters: nil, cannotEditMachine: nil)
        XCTAssertEqual(listMenu.filter { $0.kind != .separator }.map(EditWording.title),
                       ["Add to Playlist", "Rename", "Duplicate", "Open in Text Editor", "Restore a Version…", "Delete…", "New List Here"])
        XCTAssertEqual(listMenu[0].children.map(EditWording.title), ["Sunday Night", "Sunday"])
        XCTAssertEqual(Menus.folder(isEmpty: true, cannotEditMasters: nil).filter { $0.kind != .separator }.map(EditWording.title),
                       ["Rename", "New Folder", "New List Here", "Delete Folder"])
        let cue = Menus.cue(.init(hasText: true, isArmed: true))
        XCTAssertEqual(cue.filter { $0.kind != .separator }.map(EditWording.title),
                       ["Fire", "Edit Text", "Edit Cue", "Note…", "Trigger", "Duplicate Section", "Hold"])
        XCTAssertEqual(cue.first { $0.kind == .triggerMenu }?.children.filter { $0.kind != .separator }.map(EditWording.title),
                       ["Go", "Time after Previous…", "Advance After…"])
        let header = Menus.listHeader(inPlaylist: true, isLinked: true, removeItem: nil, edit: nil,
                                      channels: [.init(channel: 2, label: "Foreground", tracked: nil)], grades: catalog.grades)
        XCTAssertEqual(header.filter { $0.kind != .separator }.map(EditWording.title),
                       ["Remove from Playlist", "Show in Library", "Open in Text Editor", "Grade for Channel 2 Foreground", "Restore a Version…"])
        let gradeNames = try XCTUnwrap(header.first { $0.kind == .gradeMenu(channel: 2) }).children.map(EditWording.title)
        XCTAssertEqual(gradeNames.first, "None")
        XCTAssertEqual(Array(gradeNames.dropFirst()), catalog.grades.sorted { $0.number < $1.number }.map(\.label))
        let media = try XCTUnwrap(try Recorded.media().first)
        XCTAssertEqual(Menus.tile(media, dropChannel: 1, channels: catalog.channels, cannotSend: nil, cannotEditMasters: nil, cannotEditMachine: nil)
            .filter { $0.kind != .separator }.map(EditWording.title),
                       ["Fire to Channel 1 Background", "Fire to…", "Defaults…", "Replace with…", "Reveal in Finder", "Delete…"])
    }

    func test_whyAnEditCannotBeMade() {
        XCTAssertEqual([CannotEdit.unavailable(.engineAway), .unavailable(.engineSilent), .unavailable(.locked), .unavailable(.readOnlyMasters), .archived,
                        .localCopy, .renumberToEdit, .liveNow, .alreadyLive, .folderNotEmpty, .missing, .fire(.renameToFire), .fire(.renumberToFire), .later]
            .map(EditWording.reason),
                       ["The engine is away.", "The engine isn’t responding.", "The station is locked.", "Masters are read-only on this Mac.",
                        "Archived playlists can’t be changed.", "This Mac’s own copy can’t be edited in this version.", "Renumber to edit",
                        "It’s live. Archive a Copy works while it is.", "It’s already live.", "The folder isn’t empty.", "The file is missing.",
                        "Rename to fire", "Renumber to fire", "Not in this build yet."])
    }

    /// "one sentence for each code of Spec 5 §6 and Spec 8 §7."
    func test_everyRejectionCodeOfTheSpecsHasItsSentence() {
        // "`onAir` "It's on air: clear it or switch away first", `archived` "Archived playlists can't be changed",
        // `duplicate` "That name is taken", `operatorLock` "The station is locked"".
        XCTAssertEqual(EditWording.rejection(code: "onAir"), "It’s on air: clear it or switch away first.")
        XCTAssertEqual(EditWording.rejection(code: "archived"), "Archived playlists can’t be changed.")
        XCTAssertEqual(EditWording.rejection(code: "duplicate"), "That name is taken.")
        XCTAssertEqual(EditWording.rejection(code: "operatorLock"), "The station is locked.")
        // Spec 5 §6's codes, then Spec 8 §7's: a command's own and an import's refusals.
        let spec5 = ["unknownObject", "unknownPath", "readOnlyField", "badValue", "unknownReference", "duplicate", "danglingReferences", "protected", "onAir",
                     "archived", "notEmpty", "cycle", "operatorLock", "readOnlyLibrary", "conflict", "notInV1", "noTrash", "diskFull", "noPasscode", "keychain"]
        let spec8 = ["unreadable", "unknownObject", "onAir", "noTrash", "readOnlyLibrary", "operatorLock", "badValue", "conflict", "unsupported", "changed",
                     "diskFull", "notListed"]
        XCTAssertEqual(Set(EditWording.rejectionCodes), Set(spec5 + spec8))
        var sentences: Set<String> = []
        for code in Set(spec5 + spec8) {
            let sentence = EditWording.rejection(code: code)
            XCTAssertNotEqual(sentence, "The engine refused it (\(code)).", "\(code) has a sentence of its own")
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            sentences.insert(sentence)
        }
        XCTAssertEqual(sentences.count, Set(spec5 + spec8).count, "one sentence each")
        // Every code the edit path can answer with is one of OCore's reasons.
        for code in spec5 where !["noTrash", "diskFull", "noPasscode", "keychain", "notInV1"].contains(code) {
            XCTAssertNotNil(RejectionReason(rawValue: code), code)
        }
        XCTAssertEqual(EditWording.rejection(EngineRejection(code: "somethingNew", message: "a newer engine's words")), "The engine refused it (somethingNew).")
    }

    /// "Undo Rename, Undo Typing, ... with "(N changes)" for a group of
    /// several, and the source when it wasn't this app: "Undo Rename (from OSC)"."
    func test_undoAndRedoAreNamedFromTheTopStep() {
        func step(_ text: String, commands: Int = 1, source: String = "ui") -> HistoryStatus.Step {
            HistoryStatus.Step(group: "g-1", commands: commands, source: source, text: text)
        }
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: nil), "Undo")
        XCTAssertEqual(EditWording.menuTitle(undo: false, step: nil), "Redo")
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: step("edit list 42 title \"X\"")), "Undo Rename")
        XCTAssertEqual(EditWording.menuTitle(undo: false, step: step("edit list 42 title \"X\"")), "Redo Rename")
        let kinds = ["edit list 42 cue 22bb0000-0000-4000-8000-000000000002 channel 2 write text \"a\"", "edit folder \"Easter\" create", "edit list 42 delete",
                     "edit list 42 folder \"Hymns\"", "edit list 42 duplicate", "media delete sha256:" + String(repeating: "ab", count: 32),
                     "system restore list 42 version 16", "edit playlist b1a70000-0000-4000-8000-000000000001 archived true"]
        XCTAssertEqual(kinds.map { EditWording.menuTitle(undo: true, step: step($0)) },
                       ["Undo Typing", "Undo Add", "Undo Remove", "Undo Move", "Undo Duplicate", "Undo Delete Media", "Undo Restore", "Undo Change"])
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: step("edit list 42 cue 22bb0000-0000-4000-8000-000000000002 section duplicate", commands: 3)),
                       "Undo Duplicate (3 changes)")
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: step("edit list 42 title \"X\"", source: "osc")), "Undo Rename (from OSC)")
        XCTAssertEqual(EditWording.menuTitle(undo: false, step: step("edit list 42 title \"X\"", commands: 2, source: "api")), "Redo Rename (2 changes, from the API)")
        // The app's own sources aren't named: a key bound to an edit's undo, or the command bar.
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: step("edit list 42 title \"X\"", source: "commandbar")), "Undo Rename")
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: step("edit list 42 title \"X\"", source: "key")), "Undo Rename")
    }

    /// "After an undo or a redo, the window says for three seconds what changed: "Undid the rename of the playlist Sunday"."
    func test_whatAnUndoChangedInPlainWords() {
        XCTAssertEqual(EditWording.done(undo: true, kind: .rename, object: .playlist("Sunday")), "Undid the rename of the playlist Sunday")
        XCTAssertEqual(EditWording.done(undo: false, kind: .rename, object: .playlist("Sunday")), "Redid the rename of the playlist Sunday")
        XCTAssertEqual(EditWording.done(undo: true, kind: .typing, object: .cue(list: "Doxology")), "Undid the typing in a cue of Doxology")
        XCTAssertEqual(EditWording.done(undo: true, kind: .add, object: .item(playlist: "Sunday")), "Undid the adding of an item of the playlist Sunday")
        XCTAssertEqual(EditWording.done(undo: true, kind: .remove, object: .list("Doxology")), "Undid the removal of the list Doxology")
        XCTAssertEqual(EditWording.done(undo: true, kind: .move, object: .folder("Hymns")), "Undid the move of the folder Hymns")
        XCTAssertEqual(EditWording.done(undo: true, kind: .deleteMedia, object: .media("dawn.mp4")), "Undid the delete of the media file dawn.mp4")
        XCTAssertEqual(EditWording.done(undo: false, kind: .restore, object: .library), "Redid the restore of the library")
        let all = HistoryKind.allCases.flatMap { kind in [true, false].map { EditWording.done(undo: $0, kind: kind, object: .library) } }
        XCTAssertEqual(Set(all).count, 18, "a sentence for every kind, each way")
    }

    func test_theConfirmationsAskAsTheSpecWritesThem() {
        // "Delete "Ocean loop"? It's used by 12 cues, 1 macro and 2 keys; they'll show it missing."
        // Spec 10 §15 — "lists the system's list formatter": the spec's example is how a British Mac joins them, and a
        // Mac set to the United States writes the comma before "and".
        let british = Locale(identifier: "en_GB")
        let american = Locale(identifier: "en_US")
        let used = EditWording.words(.deleteMedia(name: "Ocean loop", use: MediaUseCount(cues: 12, macros: 1, presets: 0, keys: 2)), locale: british)
        XCTAssertEqual(used.title, "Delete “Ocean loop”?")
        XCTAssertEqual(used.body, ["It’s used by 12 cues, 1 macro and 2 keys; they’ll show it missing."])
        XCTAssertEqual(used.button, "Delete")
        XCTAssertEqual(EditWording.uses(MediaUseCount(cues: 12, macros: 1, presets: 0, keys: 2), locale: american), "12 cues, 1 macro, and 2 keys")
        XCTAssertEqual(EditWording.words(.deleteMedia(name: "Ocean loop", use: MediaUseCount())).body, ["Nothing uses it. Its file goes to the Trash."])
        XCTAssertEqual(EditWording.uses(MediaUseCount(cues: 1, presets: 2), locale: british), "1 cue and 2 presets")
        // "which says the service keeps running from the engine's copy when it is live".
        XCTAssertEqual(EditWording.words(.deletePlaylist(title: "Sunday", isLive: true)).body,
                       ["It’s live: the service keeps running from the engine’s copy. Undo puts it back."])
        XCTAssertEqual(EditWording.words(.deletePlaylist(title: "Sunday", isLive: false)).title, "Delete the playlist “Sunday”?")
        // "on the live item it says the song finishes first".
        XCTAssertEqual(EditWording.words(.removeLiveItem(title: "Doxology")).body, ["It’s live: the song finishes first."])
        XCTAssertEqual(EditWording.words(.removeLiveItem(title: "Doxology")).button, "Remove")
        // "a confirmation naming the playlists that link it, from `listUse`".
        XCTAssertEqual(EditWording.words(.deleteList(title: "Doxology", playlists: ["Sunday", "Sunday Night"]), locale: british).body,
                       ["2 playlists link it and will show it missing: Sunday and Sunday Night."])
        XCTAssertEqual(EditWording.words(.deleteList(title: "Doxology", playlists: ["Sunday"]), locale: british).body,
                       ["1 playlist links it and will show it missing: Sunday."])
        XCTAssertEqual(EditWording.words(.deleteList(title: "Doxology", playlists: [])).body, ["No playlist links it. Undo puts it back."])
        // Spec 10 §14 — "Restore version 16 of "Great Is Thy Faithfulness", kept Nov 1 at 09:12, with 14 cues? The current
        // version is kept, and Undo puts it back."
        let version = EditWording.words(.restoreVersion(version: 16, title: "Great Is Thy Faithfulness", keptAt: "Nov 1 at 09:12", cues: 14, onAir: true))
        XCTAssertEqual(version.title, "Restore version 16 of “Great Is Thy Faithfulness”, kept Nov 1 at 09:12, with 14 cues?")
        XCTAssertEqual(version.body, ["The current version is kept, and Undo puts it back.", "It’s on air: each cue takes the restored version at its next fire."])
        XCTAssertEqual(version.button, "Restore")
        // "Replace the library, and this machine's playlists, key bindings and macros, with the copies from Nov 8 at 08:59? ..."
        let snapshot = EditWording.words(.restoreSnapshot(takenAt: "Nov 8 at 08:59", mastersReadOnly: false))
        XCTAssertEqual(snapshot.title, "Replace the library, and this machine’s playlists, key bindings and macros, with the copies from Nov 8 at 08:59?")
        XCTAssertEqual(snapshot.body, ["Outputs, stacks and settings stay as they are. A snapshot of now is taken first, and Undo puts it back."])
        // "On a `readOnlyMasters` machine it names only this machine's playlists, key bindings and macros".
        XCTAssertEqual(EditWording.words(.restoreSnapshot(takenAt: "Nov 8 at 08:59", mastersReadOnly: true)).title,
                       "Replace this machine’s playlists, key bindings and macros with the copies from Nov 8 at 08:59?")
    }

    func test_whenSomethingWasKeptReadsAsADayAndATime() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let english = Locale(identifier: "en_US")
        // The system writes a narrow space before AM; what is compared is the words.
        func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(plain(EditWording.when("2026-11-01T09:12:00Z", locale: english, timeZone: utc)), "Nov 1 at 9:12 AM")
        XCTAssertEqual(plain(EditWording.when("2026-11-08T08:59:30.250Z", locale: english, timeZone: utc)), "Nov 8 at 8:59 AM")
        XCTAssertEqual(EditWording.when("2026-11-01T09:12:00Z", locale: Locale(identifier: "en_GB"), timeZone: utc), "1 Nov at 09:12", "as the Mac's region writes it")
        XCTAssertEqual(EditWording.when("some day", locale: english, timeZone: utc), "some day", "a date that doesn't read shows as it came")
    }
}
