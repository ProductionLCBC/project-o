import Foundation
import XCTest
@testable import OCore

/// Spec 9 §6 — the restore commands' rules, pure: the roots and what the
/// engine's worker read in, the roots after the restore, its inverse, what
/// changed and the file work out. Spec 9 §10, "List restore" and "Snapshot
/// restore", before the engine reads a file for them.
final class RestoreRulesTests: XCTestCase {
    typealias F = FixtureLibrary

    /// The fixture's roots, on a machine whose library is writable (the fixture's own is `readOnlyMasters`).
    static let (library, machine): (Library, Machine) = {
        var (library, machine, _) = F.load()
        machine.settings.libraryMode = .writable
        return (library, machine)
    }()
    var library: Library { Self.library }
    var machine: Machine { Self.machine }
    let list42 = F.listUuid(42)

    func snapshot(_ library: Library = RestoreRulesTests.library, _ machine: Machine = RestoreRulesTests.machine,
                  id: String = "2026-11-08-085959") -> Snapshot {
        Snapshot.taking(id: id, takenAt: "2026-11-08T08:59:59.120-05:00", reason: .playlist, library: library, machine: machine,
                        run: UUID(), seq: 1)
    }

    func restore(_ snapshot: Snapshot, library: Library = RestoreRulesTests.library, machine: Machine = RestoreRulesTests.machine,
                 state: ShowState? = nil) -> Result<Restores.Outcome, Rejection> {
        Restores.apply(.systemRestoreSnapshot(id: snapshot.manifest.id), material: .snapshot(snapshot, before: "2026-11-08-091500"),
                       library: library, machine: machine, state: state, inputs: RestoreInputs())
    }

    func reason<T>(_ result: Result<T, Rejection>) -> RejectionReason? {
        if case .failure(let rejection) = result { return rejection.reason }
        return nil
    }

    func message<T>(_ result: Result<T, Rejection>) -> String {
        if case .failure(let rejection) = result { return rejection.message }
        return ""
    }

    func retitled(_ library: Library, _ number: Int, _ title: String) -> Library {
        var out = library
        if let index = out.lists.firstIndex(where: { $0.number == number }) { out.lists[index].title = title }
        return out
    }

    // MARK: - First checks

    func test_aListRestoreNamesTheVersionFileToRead() throws {
        let key = try Restores.check(.systemRestoreList(list: 42, version: 16), library: library, machine: machine, inputs: RestoreInputs()).get()
        XCTAssertEqual(key, .version(list: list42, version: 16))
        let other = try Restores.check(.systemRestoreSnapshot(id: "2026-11-08-085959"), library: library, machine: machine,
                                       inputs: RestoreInputs()).get()
        XCTAssertEqual(other, .snapshot("2026-11-08-085959"))
    }

    /// "refused under operator lock (Spec 5 §7)"; "Both are refused with `diskFull` while the disk is full".
    func test_lockAndAFullDiskRefuseBoth() {
        var locked = machine
        locked.settings.operatorLock.enabled = true
        for command: Command in [.systemRestoreList(list: 42, version: 16), .systemRestoreSnapshot(id: "2026-11-08-085959")] {
            XCTAssertEqual(reason(Restores.check(command, library: library, machine: locked, inputs: RestoreInputs())), .operatorLock)
            XCTAssertEqual(reason(Restores.check(command, library: library, machine: machine, inputs: RestoreInputs(diskFull: true))), .diskFull)
        }
    }

    /// "Only lists that exist can be restored (choice G-11) ... Refused with `notInV1` for a local copy
    /// (Spec 5 §3) and `readOnlyLibrary` on a `readOnlyMasters` machine (Spec 5 §7)."
    func test_aListThatIsGoneALocalCopyAndReadOnlyMastersAreRefused() throws {
        XCTAssertEqual(reason(Restores.check(.systemRestoreList(list: 999, version: 1), library: library, machine: machine,
                                             inputs: RestoreInputs())), .unknownObject)
        var withLocal = machine
        var copy = try XCTUnwrap(machine.localLists.first)
        copy.number = 99
        copy.uuid = UUID()
        withLocal.localLists.append(copy)
        XCTAssertEqual(reason(Restores.check(.systemRestoreList(list: 99, version: 1), library: library, machine: withLocal,
                                             inputs: RestoreInputs())), .notInV1)
        var readOnly = machine
        readOnly.settings.libraryMode = .readOnlyMasters
        XCTAssertEqual(reason(Restores.check(.systemRestoreList(list: 42, version: 16), library: library, machine: readOnly,
                                             inputs: RestoreInputs())), .readOnlyLibrary)
        XCTAssertNil(reason(Restores.check(.systemRestoreSnapshot(id: "2026-11-08-085959"), library: library, machine: readOnly,
                                           inputs: RestoreInputs())), "a snapshot restores the machine documents there (choice G-7)")
    }

    func test_anIdThatCouldNameAnotherFolderIsNoSnapshot() {
        for id in ["", "../machine", "a/b", ".hidden", "2026..11", "with space"] {
            XCTAssertEqual(reason(Restores.check(.systemRestoreSnapshot(id: id), library: library, machine: machine, inputs: RestoreInputs())),
                           .unknownObject, id)
        }
    }

    // MARK: - A list version

    func kept(_ title: String, version: Int = 16) throws -> List {
        var list = try XCTUnwrap(library.list(number: 42))
        list.title = title
        list.version = version
        list.cues.removeLast()
        return list
    }

    /// "Everything in the version comes back but the list's number, uuid and folder ... and its `version`,
    /// which goes above every kept one"; "The current document is kept as a version first ... The inverse
    /// restores that version."
    func test_aVersionComesBackAndTheCurrentDocumentIsKeptUnderItsOwnNumber() throws {
        let current = try XCTUnwrap(library.list(number: 42))
        let old = try kept("As It Was")
        let outcome = try Restores.apply(.systemRestoreList(list: 42, version: 16), material: .version(old, kept: [16]), library: library,
                                         machine: machine, state: nil,
                                         inputs: RestoreInputs(kept: KeptVersions(lists: [list42: [16: 0]]))).get()
        let restored = try XCTUnwrap(outcome.library.list(number: 42))
        XCTAssertEqual(restored.title, "As It Was")
        XCTAssertEqual(restored.cues, old.cues)
        XCTAssertEqual(restored.uuid, current.uuid)
        XCTAssertEqual(restored.number, 42)
        XCTAssertGreaterThanOrEqual(restored.version, current.version, "its save takes the next above every kept one")
        XCTAssertEqual(outcome.library.documentPaths, library.documentPaths, "its folder stays")
        XCTAssertEqual(outcome.logged, .systemRestoreList(list: 42, version: 16))
        XCTAssertEqual(outcome.inverse, .systemRestoreList(list: 42, version: current.version))
        XCTAssertEqual(outcome.changes, [.list(restored)])
        guard case .keepVersion(let uuid, let version, let data)? = outcome.structure.first, outcome.structure.count == 1 else {
            return XCTFail("\(outcome.structure)")
        }
        XCTAssertEqual(uuid, list42)
        XCTAssertEqual(version, current.version)
        XCTAssertEqual(data, Writer.data(for: .list(current)), "the document as its file holds it")
        XCTAssertEqual(outcome.machine, machine)
    }

    /// The plan's reading — with unwritten edits, or its own number kept already, the current document
    /// goes under the next number above every kept one, so no kept file is written over.
    func test_aDocumentWithUnwrittenEditsOrAKeptNumberIsKeptAboveEveryKeptOne() throws {
        let current = try XCTUnwrap(library.list(number: 42))
        let old = try kept("As It Was")

        let unwritten = try Restores.apply(.systemRestoreList(list: 42, version: 16), material: .version(old, kept: [16]), library: library,
                                           machine: machine, state: nil,
                                           inputs: RestoreInputs(kept: KeptVersions(lists: [list42: [16: 0]]), unwritten: [list42])).get()
        XCTAssertEqual(unwritten.inverse, .systemRestoreList(list: 42, version: current.version + 1))

        // The worker found versions the engine didn't know: they count too.
        let taken = try Restores.apply(.systemRestoreList(list: 42, version: 16),
                                       material: .version(old, kept: [16, current.version, current.version + 4]), library: library,
                                       machine: machine, state: nil, inputs: RestoreInputs()).get()
        XCTAssertEqual(taken.inverse, .systemRestoreList(list: 42, version: current.version + 5))
        guard case .keepVersion(_, let version, let data)? = taken.structure.first else { return XCTFail("\(taken.structure)") }
        XCTAssertEqual(version, current.version + 5)
        var before = current
        before.version = current.version + 5
        XCTAssertEqual(data, Writer.data(for: .list(before)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(taken.library.list(number: 42)).version, current.version + 5)
    }

    /// "The version is the file with that list's uuid and `version` V; without one, the command is refused with `unknownObject`."
    func test_aFileOfAnotherListIsNotThisListsVersion() throws {
        var other = try kept("Another")
        other.uuid = UUID()
        XCTAssertEqual(reason(Restores.apply(.systemRestoreList(list: 42, version: 16), material: .version(other, kept: [16]),
                                             library: library, machine: machine, state: nil, inputs: RestoreInputs())), .unknownObject)
    }

    // MARK: - A snapshot: what is replaced

    /// A snapshot of the roots as they are changes nothing, and has no inverse.
    func test_aSnapshotOfTheRootsAsTheyAreChangesNothing() throws {
        let outcome = try restore(snapshot()).get()
        XCTAssertTrue(outcome.isNoop)
        XCTAssertEqual(outcome.library, library)
        XCTAssertEqual(outcome.machine, machine)
        XCTAssertEqual(outcome.changes, [])
        XCTAssertEqual(outcome.structure, [])
    }

    /// "A document the snapshot holds replaces the current one, or comes back with its uuid; a document of
    /// a replaced kind that the snapshot doesn't hold, such as a list made since, is deleted."
    func test_listsAreReplacedComeBackAndGo() throws {
        let then = snapshot()
        var now = retitled(library, 42, "Edited Since")
        // List 7 was deleted since, and a list was made.
        let seven = try XCTUnwrap(library.list(number: 7))
        now.lists.removeAll { $0.number == 7 }
        now.documentPaths.removeValue(forKey: FileLayout.documentKey(list: seven.uuid))
        var made = seven
        made.uuid = UUID()
        made.number = 50
        made.title = "Made Since"
        now.lists.append(made)
        now.documentPaths[FileLayout.documentKey(list: made.uuid)] = "lists/050-made-since.json"

        let outcome = try restore(then, library: now).get()
        XCTAssertEqual(outcome.library.list(number: 42)?.title, library.list(number: 42)?.title)
        XCTAssertEqual(outcome.library.list(uuid: seven.uuid)?.title, seven.title, "comes back with its uuid")
        XCTAssertEqual(outcome.library.documentPaths[FileLayout.documentKey(list: seven.uuid)], "lists/007-doxology.json")
        XCTAssertNil(outcome.library.list(uuid: made.uuid), "a list made since is deleted")
        XCTAssertNil(outcome.library.documentPaths[FileLayout.documentKey(list: made.uuid)])
        XCTAssertTrue(outcome.structure.contains(.removeList(made.uuid, path: "lists/050-made-since.json")))
        XCTAssertEqual(outcome.logged, .systemRestoreSnapshot(id: "2026-11-08-085959"))
        XCTAssertEqual(outcome.inverse, .systemRestoreSnapshot(id: "2026-11-08-091500"), "the one taken before it replaced anything")
        let changed = Set(outcome.changes.filter { $0.object == "list" }.compactMap { $0.address["listUuid"]?.stringValue })
        XCTAssertEqual(changed, [list42, seven.uuid, made.uuid].reduce(into: Set<String>()) { $0.insert($1.uuidString.lowercased()) })
    }

    /// "Restored lists take versions above every kept one": a list's `version` never goes down in memory,
    /// and its save takes the next (Spec 1 §4).
    func test_aRestoredListsVersionNeverGoesDown() throws {
        let then = snapshot()
        var now = retitled(library, 42, "Edited Since")
        let index = try XCTUnwrap(now.lists.firstIndex { $0.number == 42 })
        now.lists[index].version += 5
        let outcome = try restore(then, library: now).get()
        XCTAssertEqual(outcome.library.list(number: 42)?.version, now.lists[index].version)
        XCTAssertEqual(outcome.library.list(number: 42)?.title, library.list(number: 42)?.title)
    }

    /// "the lists and their folders": a list goes back to the folder it was in, a folder made since goes
    /// once it is empty, one removed since comes back, and a folder that still holds another file stays.
    func test_foldersComeBackAndGoAndAListGoesBackToItsFolder() throws {
        let then = snapshot()
        var now = library
        let key = FileLayout.documentKey(list: list42)
        now.folders = ["Hymns", "Worship", "Worship/New", "Notes"]      // Christmas removed; three made
        now.documentPaths[key] = "lists/Worship/New/042-great-is-thy-faithfulness.json"
        now.otherFiles = ["lists/Notes/readme.txt"]

        let outcome = try restore(then, library: now).get()
        XCTAssertEqual(outcome.library.folders, ["Christmas", "Hymns", "Notes"])
        XCTAssertEqual(outcome.library.documentPaths[key], "lists/Hymns/042-great-is-thy-faithfulness.json")
        XCTAssertEqual(outcome.library.otherFiles, ["lists/Notes/readme.txt"])
        XCTAssertEqual(outcome.structure, [
            .makeFolder("Christmas"),
            .moveList(list42, from: "lists/Worship/New/042-great-is-thy-faithfulness.json", to: "lists/Hymns/042-great-is-thy-faithfulness.json"),
            .removeFolder("Worship/New"),
            .removeFolder("Worship"),
        ])
        XCTAssertEqual(Set(outcome.changes.filter { $0.object == "folder" }.compactMap { $0.address["folder"]?.stringValue }),
                       ["Christmas", "Worship", "Worship/New"])
    }

    /// The catalogs, presets and portable macros of the snapshot replace today's; the media index stays.
    func test_catalogsPresetsAndMacrosAreReplacedAndTheMediaIndexIsLeft() throws {
        let then = snapshot()
        var now = library
        now.info.name = "Renamed Since"
        now.channels[0].label = "Relabelled"
        now.textStyles[0].label = "Restyled"
        now.presets.removeAll { $0.number == 4 }
        now.documentPaths.removeValue(forKey: "preset/4")
        var made = try XCTUnwrap(library.preset(3))
        made.number = 9
        made.uuid = UUID()
        now.presets.append(made)
        now.documentPaths["preset/9"] = "presets/009-lower-third.json"
        now.macros[0].label = "Changed"
        now.mediaIndex.entries.removeLast()

        let outcome = try restore(then, library: now).get()
        XCTAssertEqual(outcome.library.info, library.info)
        XCTAssertEqual(outcome.library.channels, library.channels)
        XCTAssertEqual(outcome.library.textStyles, library.textStyles)
        XCTAssertEqual(outcome.library.presets, library.presets)
        XCTAssertEqual(outcome.library.macros, library.macros)
        XCTAssertEqual(outcome.library.mediaIndex, now.mediaIndex, "both media indexes are left, which the walk keeps true to the files")
        XCTAssertTrue(outcome.structure.contains(.removeDocument(.preset(9), path: "presets/009-lower-third.json")))
        XCTAssertEqual(outcome.library.documentPaths["preset/1"], library.documentPaths["preset/1"])
        XCTAssertNil(outcome.library.documentPaths["preset/9"])
        let objects = Set(outcome.changes.map(\.object))
        XCTAssertTrue(objects.isSuperset(of: ["library", "channel", "textstyle", "preset", "macro"]), "\(objects)")
        XCTAssertEqual(Set(DocumentChanges.between((now, machine), (outcome.library, outcome.machine))),
                       [.libraryInfo, .channels, .textStyles, .preset(4), .libraryMacro(1)])
    }

    /// "Key bindings and the scheduler, machine macros, playlists (archived ones too) and local copies" are
    /// replaced; "`machine.json`, stacks, outputs, audio outputs, inputs and clocks" are left.
    func test_theMachinesAuthoredDocumentsAreReplacedAndItsSetupIsLeft() throws {
        let then = snapshot()
        var now = machine
        now.keys.removeLast()
        now.macros[0].label = "Changed"
        let archived = try XCTUnwrap(now.playlists.firstIndex { $0.uuid == F.archivedSundayUuid })
        now.playlists[archived].title = "Changed Though Archived"
        let night = try XCTUnwrap(machine.playlist(uuid: F.sundayNightUuid))
        now.playlists.removeAll { $0.uuid == F.sundayNightUuid }
        now.documentPaths.removeValue(forKey: FileLayout.documentKey(playlist: F.sundayNightUuid))
        var made = night
        made.uuid = UUID()
        made.title = "Made Since"
        now.playlists.append(made)
        now.documentPaths[FileLayout.documentKey(playlist: made.uuid)] = "playlists/made-since.json"
        now.localLists[0].title = "Local Edited"
        // The setup, which a restore never moves.
        now.settings.campusName = "Another Campus"
        now.stacks[0].label = "Moved Stack"
        now.outputs[0].label = "Moved Output"
        now.mediaLocal.entries.removeAll()

        let outcome = try restore(then, machine: now).get()
        XCTAssertEqual(outcome.machine.keys, machine.keys)
        XCTAssertEqual(outcome.machine.macros, machine.macros)
        XCTAssertEqual(Set(outcome.machine.playlists.map(\.uuid)), Set(machine.playlists.map(\.uuid)))
        XCTAssertEqual(outcome.machine.playlist(uuid: F.archivedSundayUuid), machine.playlist(uuid: F.archivedSundayUuid),
                       "an archived playlist is replaced like any other")
        XCTAssertEqual(outcome.machine.playlist(uuid: F.sundayNightUuid), night)
        XCTAssertEqual(outcome.machine.localLists, machine.localLists)
        XCTAssertTrue(outcome.structure.contains(.removePlaylist(made.uuid, path: "playlists/made-since.json")))
        XCTAssertEqual(outcome.machine.settings, now.settings)
        XCTAssertEqual(outcome.machine.stacks, now.stacks)
        XCTAssertEqual(outcome.machine.outputs, now.outputs)
        XCTAssertEqual(outcome.machine.audioOutputs, now.audioOutputs)
        XCTAssertEqual(outcome.machine.inputs, now.inputs)
        XCTAssertEqual(outcome.machine.clocks, now.clocks)
        XCTAssertEqual(outcome.machine.mediaLocal, now.mediaLocal)
        XCTAssertEqual(outcome.library, library, "nothing of the library differed")
    }

    // MARK: - A snapshot: what refuses it

    /// "A snapshot of another library is refused with `badValue`."
    func test_anotherLibrarysSnapshotIsRefused() {
        var other = library
        other.info.uuid = UUID()
        XCTAssertEqual(reason(restore(snapshot(other))), .badValue)
        var noLibrary = snapshot()
        noLibrary.documents.removeValue(forKey: "library/library.json")
        XCTAssertEqual(reason(restore(noLibrary)), .badValue)
    }

    /// "one the app can't read refuses the restore with `badValue`, naming it."
    func test_aDocumentThatCannotBeReadRefusesTheRestoreAndIsNamed() {
        var broken = snapshot()
        broken.documents["library/lists/007-doxology.json"] = Data("{ not json".utf8)
        let result = restore(broken)
        XCTAssertEqual(reason(result), .badValue)
        XCTAssertTrue(message(result).contains("library/lists/007-doxology.json"), message(result))

        var later = snapshot()
        later.documents["machine/keys.json"] = Data(#"{"schema":99,"app":"9.0.0","kind":"keys","bindings":[]}"#.utf8)
        let newer = restore(later)
        XCTAssertEqual(reason(newer), .badValue)
        XCTAssertTrue(message(newer).contains("machine/keys.json"), message(newer))
    }

    /// "A snapshot another machine took restores here like this machine's own".
    func test_anotherMachinesSnapshotRestores() throws {
        var theirs = machine
        theirs.settings.uuid = UUID()
        theirs.settings.campusName = "Harrisburg"
        theirs.keys.removeLast()
        let outcome = try restore(snapshot(library, theirs)).get()
        XCTAssertEqual(outcome.machine.keys, theirs.keys)
        XCTAssertEqual(outcome.machine.settings, machine.settings, "this machine's settings stay")
    }

    /// "a renumber or a swap since the snapshot refuses the restore with `conflict`, naming the objects".
    func test_aChannelRenumberedOrSwappedSinceRefusesWithConflictNamingIt() {
        let then = snapshot()
        var renumbered = library
        renumbered.channels[2].number = 8
        let first = restore(then, library: renumbered)
        XCTAssertEqual(reason(first), .conflict)
        XCTAssertTrue(message(first).contains("channel 8 (3 in the snapshot)"), message(first))

        var swapped = library
        swapped.channels[0].number = 2
        swapped.channels[1].number = 1
        let second = restore(then, library: swapped)
        XCTAssertEqual(reason(second), .conflict)
        XCTAssertTrue(message(second).contains("channel 1 (2 in the snapshot)"), message(second))
        XCTAssertTrue(message(second).contains("channel 2 (1 in the snapshot)"), message(second))
    }

    /// The plan's reading — every numbered type of both roots, stacks and outputs included.
    func test_theRenumberCheckCoversListsPresetsMacrosAndTheMachinesObjects() {
        let then = snapshot()
        var lists = library
        lists.lists[0].number = 70
        XCTAssertEqual(reason(restore(then, library: lists)), .conflict)
        var presets = library
        presets.presets[1].number = 20
        XCTAssertEqual(reason(restore(then, library: presets)), .conflict)
        var stacks = machine
        stacks.stacks[1].number = 5
        let result = restore(then, machine: stacks)
        XCTAssertEqual(reason(result), .conflict)
        XCTAssertTrue(message(result).contains("stack 5 (2 in the snapshot)"), message(result))
        var macros = machine
        macros.macros[0].number = 30
        XCTAssertEqual(reason(restore(then, machine: macros)), .conflict)
    }

    /// "A restore that would delete a channel with content in a stack an output shows is refused with
    /// `onAir`, as Spec 5 §6 refuses that delete".
    func test_deletingAChannelOnAirRefusesWithOnAir() throws {
        var older = library
        older.channels.removeAll { $0.number == 1 }
        let then = snapshot(older)
        var state = ShowState.fresh(library: library, machine: machine)
        state.channels[1]?.content = .text(TextInstance(fields: ["body": "Great is thy faithfulness"]))
        XCTAssertEqual(reason(restore(then, state: state)), .onAir)
    }

    /// Adam's answer of 2026-11-14 — a snapshot that adds, removes or resizes a channel is refused with
    /// `notInV1`, naming the channels, until Area 14; a channel on air still answers `onAir` first.
    func test_aSnapshotWithAnotherChannelListIsRefusedUntilArea14() throws {
        let empty = ShowState.fresh(library: library, machine: machine)
        var fewer = library
        fewer.channels.removeAll { $0.number == 3 }
        let removed = restore(snapshot(fewer), state: empty)
        XCTAssertEqual(reason(removed), .notInV1)
        XCTAssertTrue(message(removed).contains("channel 3 removed"), message(removed))

        var more = library
        var extra = more.channels[2]
        extra.number = 4
        extra.uuid = UUID()
        more.channels.append(extra)
        let added = restore(snapshot(more), state: empty)
        XCTAssertEqual(reason(added), .notInV1)
        XCTAssertTrue(message(added).contains("channel 4 added"), message(added))

        var resized = library
        resized.channels[1].renderSize = resized.channels[1].renderSize == .largest ? .size(width: 640, height: 360) : .largest
        let size = restore(snapshot(resized), state: empty)
        XCTAssertEqual(reason(size), .notInV1)
        XCTAssertTrue(message(size).contains("channel 2 resized"), message(size))

        // A label, a default or a decoder cap is read live, so it restores.
        var relabelled = library
        relabelled.channels[1].label = "Lyrics Then"
        relabelled.channels[1].decoderCap = 3
        XCTAssertEqual(try restore(snapshot(relabelled), state: empty).get().library.channels[1].label, "Lyrics Then")
    }

    /// "On a `readOnlyMasters` machine only the machine documents are replaced, and the result warns that
    /// the library was left as it was (choice G-7)."
    func test_onReadOnlyMastersOnlyTheMachineDocumentsAreReplacedWithAWarning() throws {
        let then = snapshot()
        let nowLibrary = retitled(library, 42, "Edited Since")
        var nowMachine = machine
        nowMachine.settings.libraryMode = .readOnlyMasters
        nowMachine.keys.removeLast()
        let outcome = try restore(then, library: nowLibrary, machine: nowMachine).get()
        XCTAssertEqual(outcome.library, nowLibrary, "the library was left as it was")
        XCTAssertEqual(outcome.machine.keys, machine.keys)
        XCTAssertEqual(outcome.warnings.count, 1)
        XCTAssertTrue(outcome.warnings[0].contains("library was left as it was"), outcome.warnings[0])
        XCTAssertFalse(outcome.changes.contains { $0.object == "list" })
    }

    /// "A restore puts documents back as they were, so it may leave a broken reference, which the reference
    /// report flags, as an undo may (Spec 5 §6)."
    func test_aReferenceTheRestoreBreaksIsFlaggedByTheReferenceReport() throws {
        // Then, list 7 existed; since, the Sunday playlist came to hold it and nothing else changed there.
        // A restore to a time before list 7 leaves the playlist's own document as the snapshot had it, so
        // build the break the other way: the snapshot lacks list 7, which today's left-alone stack setup
        // doesn't name, but the restored playlists (from the snapshot) are consistent. A macro left on the
        // machine settings is what breaks: the snapshot has no machine macro 2, which `startupMacro` names.
        var older = machine
        older.macros.removeAll { $0.number == 2 }
        let outcome = try restore(snapshot(library, older)).get()
        XCTAssertNil(outcome.machine.macro(2))
        XCTAssertEqual(outcome.machine.settings.startupMacro, 2, "the machine's settings are left as they are")
        let report = Validator.validate(library: outcome.library, machine: outcome.machine)
        XCTAssertFalse(report.issues(.missingMacro).isEmpty, report.lines.joined(separator: "\n"))
    }

    // MARK: - Ids (Spec 9 §3)

    func test_twoInOneSecondGetDashTwoAndIdsSortOldestFirst() {
        XCTAssertEqual(SnapshotID.free("2026-11-08-085959", taken: []), "2026-11-08-085959")
        XCTAssertEqual(SnapshotID.free("2026-11-08-085959", taken: ["2026-11-08-085959"]), "2026-11-08-085959-2")
        XCTAssertEqual(SnapshotID.free("2026-11-08-085959", taken: ["2026-11-08-085959", "2026-11-08-085959-2"]), "2026-11-08-085959-3")
        XCTAssertEqual(SnapshotID.sorted(["2026-11-08-090000", "2026-11-08-085959-10", "2026-11-08-085959", "2026-11-08-085959-2",
                                          "2026-11-07-235959"]),
                       ["2026-11-07-235959", "2026-11-08-085959", "2026-11-08-085959-2", "2026-11-08-085959-10", "2026-11-08-090000"])
        XCTAssertTrue(SnapshotID.isPlausible("2026-11-08-085959-2"))
    }
}
