import Foundation
import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 9 §6 — `system restore snapshot "ID"` in the engine. Spec 9 §10,
/// Snapshot restore: "Exactly the documents §6 lists are replaced, created or
/// deleted, archived playlists included, and the rest are byte-identical;
/// restored lists get versions above every kept one; a pre-restore snapshot
/// is taken and undo restores it; an unreadable document and another
/// library's snapshot each refuse with `badValue`; another machine's snapshot
/// restores; a channel renumbered or swapped since refuses with `conflict`,
/// naming it; deleting a channel on air refuses with `onAir`; the live list
/// may go and the pointer goes on from its kept copy; a reference the restore
/// breaks is flagged by the reference report; a `readOnlyMasters` machine
/// replaces only the machine documents and warns. While the worker runs, cues
/// keep firing and a lyric edit waits, then lands after the restore; a
/// failure while the pre-restore snapshot is written leaves every document as
/// it was; held in a cue, the cue's other commands run at once." Undo and
/// redo: "Two quick undos after a snapshot restore undo it and then the group
/// below, in that order, each against the state the one before left." And
/// the `snapshots` query. On temporary copies of the fixture, launched, so
/// each starts with the launch's snapshot.
final class SnapshotRestoreEngineTests: XCTestCase {
    static let start = Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-30T10:00:00-04:00
    static let launch = "2026-10-30-100000"
    static let hymn = "lists/Hymns/042-great-is-thy-faithfulness.json"
    static let doxology = "lists/007-doxology.json"
    static let list42 = "a9f00000-0000-4000-8000-00000000002a"
    static let sunday = "b1a70000-0000-4000-8000-000000000001"

    /// Holds the snapshot worker before it reads, until released.
    final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func release() { semaphore.signal() }
        /// What the worker calls before it reads: it waits here.
        var hold: @Sendable () -> Void {
            let semaphore = self.semaphore
            return { semaphore.wait() }
        }
    }

    var disk: DiskFixture!
    var library: Library { disk.engine.engine.library }
    var machine: Machine { disk.engine.engine.machine }

    override func setUpWithError() throws {
        disk = try DiskFixture(wallClock: Self.start, launch: true)
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [Self.launch])
    }

    override func tearDown() {
        disk = nil
    }

    func entries() -> [LogEntry] { disk.commandLog().compactMap(\.entry) }

    /// The wall clock moved on, so the next snapshot's id is its own.
    func later(_ seconds: TimeInterval) {
        disk.clock.now = disk.clock.now.addingTimeInterval(seconds)
    }

    @discardableResult
    func run(_ text: String, source: SourceKind = .ui) -> Rejection? {
        let before = disk.control.rejections.count
        disk.send(text, source: source)
        disk.settleSaving()
        return disk.control.rejections.count > before ? disk.control.rejections.last : nil
    }

    func restore(_ id: String) -> Rejection? {
        later(60)
        return run("system restore snapshot \"\(id)\"")
    }

    /// A snapshot put in `machine/snapshots/` by hand: the launch's, changed, as another time or another
    /// machine would have made it.
    func plant(_ id: String, _ change: (inout Snapshot) throws -> Void) throws {
        var snapshot = try disk.snapshot(Self.launch)
        snapshot.manifest.id = id
        try change(&snapshot)
        let data = try Zip.archive(snapshot.files.map { Zip.Entry(path: $0.path, data: $0.data) }, modified: Self.start, timeZone: .current)
        try data.write(to: disk.snapshotsFolder.appendingPathComponent(id + ".zip"))
    }

    /// One document of a snapshot with its JSON changed.
    func rewrite(_ snapshot: inout Snapshot, _ path: String, _ change: (inout [String: JSONValue]) -> Void) throws {
        guard let data = snapshot.documents[path], case .object(var members) = try JSONValue.parse(data) else {
            throw XCTSkip("\(path) isn't in the snapshot")
        }
        change(&members)
        snapshot.documents[path] = JSONCanonical.data(.object(members))
    }

    /// The channels document of a snapshot, each channel changed or dropped.
    func channels(_ snapshot: inout Snapshot, _ change: (inout [String: JSONValue]) -> Bool) throws {
        try rewrite(&snapshot, "library/channels.json") { members in
            var out: [JSONValue] = []
            for channel in members["channels"]?.arrayValue ?? [] {
                guard var object = channel.objectValue else { continue }
                if change(&object) { out.append(.object(object)) }
            }
            members["channels"] = .array(out)
        }
    }

    /// The bytes of every file under these places of the two roots, by path.
    func bytes(_ places: [(DocumentWriter.Root, String)]) -> [String: Data] {
        var out: [String: Data] = [:]
        for (root, path) in places { out[root.rawValue + "/" + path] = disk.data(root, path) }
        return out
    }

    /// The documents a snapshot restore leaves alone (Spec 9 §6's right-hand column).
    static let left: [(DocumentWriter.Root, String)] = [
        (.machine, "machine.json"), (.machine, "stacks.json"), (.machine, "outputs.json"), (.machine, "audio-outputs.json"),
        (.machine, "inputs.json"), (.machine, "clocks.json"), (.machine, "media-local.json"), (.library, "media-index.json"),
    ]

    /// Changes of every kind since the launch's snapshot; what was made.
    func changeEverything() throws -> (list: UUID, playlist: UUID) {
        XCTAssertNil(run("edit list 42 title \"Edited Since\""))
        XCTAssertNil(run("edit list 7 delete"))
        XCTAssertNil(run("edit folder \"Worship\" create"))
        XCTAssertNil(run("edit list 57 create folder \"Worship\""))
        XCTAssertNil(run("edit playlist create \"Evening\""))
        XCTAssertNil(run("edit playlist \(Self.sunday) title \"Sunday Morning\""))
        // An archived playlist, which no edit may change (Spec 5 §6), changed by a file that arrived.
        let archived = "playlists/sunday-2026-11-01.json"
        try disk.write(.machine, archived, try disk.edited(.machine, archived, "serviceTime", .string("23:00")))
        disk.engine.scanDisk()
        disk.nextSecond()
        let list = try XCTUnwrap(library.list(number: 57)).uuid
        let playlist = try XCTUnwrap(machine.playlists.first { $0.title == "Evening" }).uuid
        return (list, playlist)
    }

    // MARK: - What is replaced

    /// "Exactly the documents §6 lists are replaced, created or deleted, archived playlists included, and
    /// the rest are byte-identical; restored lists get versions above every kept one".
    func test_theAuthoredDocumentsAreReplacedCreatedOrDeletedAndTheRestAreByteIdentical() throws {
        let first = (library: library, machine: machine)
        let archivedBefore = try XCTUnwrap(disk.data(.machine, "playlists/sunday-2026-11-01.json"))
        let made = try changeEverything()
        let untouched = bytes(Self.left)
        let revision = disk.control.revision
        XCTAssertTrue(disk.exists(.library, "lists/Worship/057.json"))
        XCTAssertFalse(disk.exists(.library, Self.doxology))

        XCTAssertNil(restore(Self.launch))
        disk.nextSecond()

        // Replaced.
        XCTAssertEqual(library.list(number: 42)?.title, "Great Is Thy Faithfulness")
        XCTAssertEqual(disk.list(at: Self.hymn)?.title, "Great Is Thy Faithfulness", "its file has its name again")
        XCTAssertFalse(disk.exists(.library, "lists/Hymns/042-edited-since.json"))
        XCTAssertEqual(machine.playlist(uuid: try XCTUnwrap(UUID(uuidString: Self.sunday)))?.title, "Sunday")
        XCTAssertTrue(disk.exists(.machine, "playlists/sunday.json"))
        XCTAssertEqual(disk.data(.machine, "playlists/sunday-2026-11-01.json"), archivedBefore, "an archived playlist is replaced like any other")
        // Created: "comes back with its uuid".
        XCTAssertEqual(library.list(number: 7)?.uuid, first.library.list(number: 7)?.uuid)
        XCTAssertEqual(disk.list(at: Self.doxology)?.title, "Doxology")
        // Deleted: "a list made since ... is deleted", with its folder and the playlist made since.
        XCTAssertNil(library.list(uuid: made.list))
        XCTAssertFalse(disk.exists(.library, "lists/Worship/057.json"))
        XCTAssertFalse(disk.exists(.library, "lists/Worship"))
        XCTAssertEqual(library.folders, ["Christmas", "Hymns"])
        XCTAssertNil(machine.playlist(uuid: made.playlist))
        XCTAssertFalse(disk.exists(.machine, "playlists/evening.json"))

        // The roots are the snapshot's again, a list's `version` aside.
        func versionless(_ lists: [List]) -> [List] {
            lists.map { list in
                var copy = list
                copy.version = 0
                return copy
            }
        }
        XCTAssertEqual(versionless(library.lists), versionless(first.library.lists))
        XCTAssertEqual(machine.playlists, first.machine.playlists)
        XCTAssertEqual(machine.keys, first.machine.keys)
        XCTAssertEqual(machine.macros, first.machine.macros)
        XCTAssertEqual(machine.localLists, first.machine.localLists)
        XCTAssertEqual(library.presets, first.library.presets)
        XCTAssertEqual(library.channels, first.library.channels)

        // "the rest are byte-identical".
        XCTAssertEqual(bytes(Self.left), untouched)
        // "restored lists get versions above every kept one".
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 19, "18 after the edit's save; its restore's save goes above")
        XCTAssertGreaterThan(try XCTUnwrap(disk.list(at: Self.doxology)).version, 0)

        // One edit group: its line with its inverse, one event with cause `restore`, the revision up by one.
        let line = try XCTUnwrap(entries().last { $0.command.isRestore })
        XCTAssertEqual(line.text, "system restore snapshot \"\(Self.launch)\"")
        XCTAssertEqual(line.kind, .edit)
        XCTAssertEqual(line.result, .ok)
        XCTAssertEqual(disk.control.revision, revision + 1)
        let event = try XCTUnwrap(disk.events.all.last { $0["cause"] == .string("restore") })
        XCTAssertEqual(event["group"], .string(line.group.rawValue))
        let objects = Set((event["changed"]?.arrayValue ?? []).compactMap { $0["object"]?.stringValue })
        XCTAssertEqual(objects, ["list", "folder", "playlist"])
    }

    /// "Before it replaces anything, the engine takes a snapshot with reason `restore`, and the inverse
    /// restores that one"; "a pre-restore snapshot is taken and undo restores it".
    func test_aSnapshotIsTakenBeforeTheRestoreAndUndoRestoresIt() throws {
        let made = try changeEverything()
        XCTAssertNil(restore(Self.launch))
        disk.nextSecond()

        let before = "2026-10-30-100100"
        XCTAssertEqual(disk.snapshotIDs, [Self.launch, before])
        let taken = try disk.snapshot(before)
        XCTAssertEqual(taken.manifest.reason, "restore")
        XCTAssertNotNil(taken.documents["library/lists/Hymns/042-edited-since.json"], "the documents as they were about to be replaced")
        XCTAssertNotNil(taken.documents["library/lists/Worship/057.json"])
        XCTAssertNil(taken.documents["library/" + Self.doxology])
        XCTAssertEqual(taken.manifest.folders, ["Christmas", "Hymns", "Worship"])
        let line = try XCTUnwrap(entries().last { $0.command.isRestore })
        XCTAssertEqual(line.inverse, .systemRestoreSnapshot(id: before))
        XCTAssertTrue(disk.notes("snapshot").allSatisfy { $0.note["reason"] != .string("restore") }, "only automatic snapshots are noted")

        later(60)
        XCTAssertNil(run("undo"))
        disk.nextSecond()
        XCTAssertEqual(library.list(number: 42)?.title, "Edited Since")
        XCTAssertNil(library.list(number: 7))
        XCTAssertFalse(disk.exists(.library, Self.doxology))
        XCTAssertNotNil(library.list(uuid: made.list))
        XCTAssertTrue(disk.exists(.library, "lists/Worship/057.json"))
        XCTAssertEqual(library.folders, ["Christmas", "Hymns", "Worship"])
        XCTAssertNotNil(machine.playlist(uuid: made.playlist))
        XCTAssertEqual(machine.playlist(uuid: try XCTUnwrap(UUID(uuidString: Self.sunday)))?.title, "Sunday Morning")
        XCTAssertEqual(disk.document(.machine, "playlists/sunday-2026-11-01.json").flatMap { document -> String? in
            if case .playlist(let playlist) = document { return playlist.serviceTime }
            return nil
        }, "23:00")
        let lines = entries().suffix(2)
        XCTAssertEqual(lines.map(\.text), ["undo", "system restore snapshot \"\(before)\""])
        XCTAssertEqual(lines.last?.undoes, line.group)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("undo"))
        // The plan's reading — an undo's restore takes its own snapshot first.
        XCTAssertEqual(disk.snapshotIDs.count, 3)
        XCTAssertEqual(try disk.snapshot(try XCTUnwrap(disk.snapshotIDs.last)).manifest.reason, "restore")
        // Spec 9 §7 — the snapshots the steps name are the ones retention keeps for the run.
        XCTAssertEqual(disk.control.history.snapshotIDs, [Self.launch, before])
    }

    /// "Two quick undos after a snapshot restore undo it and then the group below, in that order, each
    /// against the state the one before left."
    func test_twoQuickUndosUndoTheRestoreAndThenTheGroupBelow() throws {
        XCTAssertNil(run("edit list 7 title \"Praise God\""))
        disk.nextSecond()
        let edit = try XCTUnwrap(entries().last?.group)
        XCTAssertNil(restore(Self.launch))
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology")
        let restored = try XCTUnwrap(entries().last?.group)

        later(60)
        disk.send("undo")
        disk.send("undo")
        disk.engine.tick()
        XCTAssertNotNil(disk.control.mediaPark, "the first waits for its snapshot to be read, the second behind it")
        disk.settleSaving()

        // The first put back the edited title; the second then undid that edit.
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology")
        let lines = entries().suffix(4)
        XCTAssertEqual(lines.map(\.text), ["undo", "system restore snapshot \"2026-10-30-100100\"", "undo", "edit list 7 title \"Doxology\""])
        XCTAssertEqual(lines.map(\.undoes), [nil, restored, nil, edit])
        XCTAssertNil(disk.control.history.undoTop)
        XCTAssertEqual(disk.control.history.redo.count, 2)
        XCTAssertTrue(disk.control.rejections.isEmpty)
    }

    // MARK: - What refuses it

    /// "Refused with `unknownObject` for an id with no file"; "one the app can't read refuses the restore
    /// with `badValue`, naming it"; "A snapshot of another library is refused with `badValue`."
    func test_noSuchSnapshotAnUnreadableDocumentAndAnotherLibraryAreRefused() throws {
        let before = (library, machine)
        XCTAssertEqual(restore("2026-01-01-000000")?.reason, .unknownObject)

        try plant("2026-10-29-090000") { snapshot in
            snapshot.documents["library/lists/007-doxology.json"] = Data("{ not json".utf8)
        }
        let unreadable = restore("2026-10-29-090000")
        XCTAssertEqual(unreadable?.reason, .badValue)
        XCTAssertTrue(unreadable?.message.contains("library/lists/007-doxology.json") ?? false, unreadable?.message ?? "")

        try plant("2026-10-29-100000") { snapshot in
            let other = UUID().uuidString.lowercased()
            snapshot.manifest.library = other
            try rewrite(&snapshot, "library/library.json") { $0["uuid"] = .string(other) }
        }
        XCTAssertEqual(restore("2026-10-29-100000")?.reason, .badValue)

        try Data("not a zip".utf8).write(to: disk.snapshotsFolder.appendingPathComponent("2026-10-29-110000.zip"))
        XCTAssertEqual(restore("2026-10-29-110000")?.reason, .badValue)

        XCTAssertEqual(library, before.0)
        XCTAssertEqual(machine, before.1)
        XCTAssertTrue(entries().isEmpty, "a rejected command isn't logged")
    }

    /// "A snapshot another machine took restores here like this machine's own, such as a replacement Mac
    /// taking the old one's playlists and key bindings; the `snapshots` query names its campus".
    func test_anotherMachinesSnapshotRestoresAndTheQueryNamesItsCampus() throws {
        let settings = try XCTUnwrap(disk.data(.machine, "machine.json"))
        try plant("2026-10-29-090000") { snapshot in
            snapshot.manifest.machine = "0ld0ld00-0000-4000-8000-000000000009"
            snapshot.manifest.campus = "Harrisburg"
            snapshot.manifest.takenAt = "2026-10-29T09:00:00.000-04:00"
            try rewrite(&snapshot, "machine/machine.json") { members in
                members["uuid"] = .string("01d01d00-0000-4000-8000-000000000009")
                members["campusName"] = .string("Harrisburg")
            }
            try rewrite(&snapshot, "machine/playlists/sunday.json") { $0["title"] = .string("Harrisburg Sunday") }
        }
        XCTAssertNil(restore("2026-10-29-090000"))
        disk.nextSecond()
        XCTAssertEqual(machine.playlist(uuid: try XCTUnwrap(UUID(uuidString: Self.sunday)))?.title, "Harrisburg Sunday")
        XCTAssertEqual(machine.settings.campusName, "Manheim", "this machine's setup stays")
        XCTAssertEqual(disk.data(.machine, "machine.json"), settings)

        let answer = disk.engine.engine.publisher.query(.object(["id": .number(3), "type": .string("query"), "what": .string("snapshots")]))
        XCTAssertEqual(answer["type"], .string("answer"))
        let listed = try XCTUnwrap(answer["snapshots"]?.arrayValue)
        XCTAssertEqual(listed.map { $0["id"]?.stringValue }, ["2026-10-30-100100", Self.launch, "2026-10-29-090000"], "newest first")
        XCTAssertEqual(listed.map { $0["reason"]?.stringValue }, ["restore", "launch", "launch"])
        XCTAssertEqual(listed[2]["campus"], .string("Harrisburg"))
        XCTAssertEqual(listed[2]["machine"], .string("0ld0ld00-0000-4000-8000-000000000009"))
        XCTAssertEqual(listed[2]["takenAt"], .string("2026-10-29T09:00:00.000-04:00"))
        XCTAssertEqual(listed[1]["campus"], .string("Manheim"))
        XCTAssertEqual(listed[1]["machine"], .string("7a7a0000-0000-4000-8000-000000000001"))
        XCTAssertEqual(listed[1]["takenAt"], .string("2026-10-30T10:00:00.000-04:00"))
        for entry in listed {
            let size = try XCTUnwrap(entry["bytes"]?.intValue)
            let id = try XCTUnwrap(entry["id"]?.stringValue)
            XCTAssertEqual(size, try Data(contentsOf: disk.snapshotsFolder.appendingPathComponent(id + ".zip")).count)
            XCTAssertEqual(Set(entry.objectValue?.keys.map { $0 } ?? []), ["id", "takenAt", "reason", "bytes", "machine", "campus"])
        }
    }

    /// "a renumber or a swap since the snapshot refuses the restore with `conflict`, naming the objects;
    /// renumbering them back, or restoring a later snapshot, gets past it."
    func test_anObjectRenumberedOrSwappedSinceRefusesWithConflictNamingIt() throws {
        // A list renumbered since.
        XCTAssertNil(run("edit list 7 renumber 70"))
        let renumbered = restore(Self.launch)
        XCTAssertEqual(renumbered?.reason, .conflict)
        XCTAssertTrue(renumbered?.message.contains("list 70 (7 in the snapshot)") ?? false, renumbered?.message ?? "")
        XCTAssertNotNil(library.list(number: 70), "nothing changed")
        // "renumbering them back ... gets past it."
        XCTAssertNil(run("edit list 70 renumber 7"))
        XCTAssertNil(restore(Self.launch))

        // Channels swapped since, as a snapshot from before the swap sees it.
        try plant("2026-10-29-090000") { snapshot in
            try channels(&snapshot) { channel in
                if channel["number"] == .number(2) {
                    channel["number"] = .number(3)
                } else if channel["number"] == .number(3) {
                    channel["number"] = .number(2)
                }
                return true
            }
        }
        let swapped = restore("2026-10-29-090000")
        XCTAssertEqual(swapped?.reason, .conflict)
        XCTAssertTrue(swapped?.message.contains("channel 2 (3 in the snapshot)") ?? false, swapped?.message ?? "")
        XCTAssertTrue(swapped?.message.contains("channel 3 (2 in the snapshot)") ?? false, swapped?.message ?? "")
    }

    /// "A restore that would delete a channel on air, with content in a stack an output shows or sounding
    /// on an audio output, is refused with `onAir`"; and "A snapshot that adds, removes or resizes a channel
    /// restores like any other: the engine rebuilds its channel textures and ShowState's entries between
    /// ticks, as it does for an edit of the same channels (Spec 5 §2, Spec 4 §5). A channel that comes back
    /// starts empty, and a channel on air that would go still answers `onAir`."
    func test_aSnapshotWithAnotherChannelListRestoresAndAChannelOnAirIsOnAir() throws {
        try plant("2026-10-29-090000") { snapshot in
            try channels(&snapshot) { $0["number"] != .number(2) }
        }
        // Cue 1 of list 42 writes channel 2, which stack 1 holds and both outputs show.
        XCTAssertNil(run("list 42 cue 1", source: .osc))
        XCTAssertNotEqual(disk.engine.state.channels[2]?.content, .empty)
        XCTAssertEqual(restore("2026-10-29-090000")?.reason, .onAir)
        XCTAssertEqual(library.channels.count, 3)

        // Off air, the channel goes: its textures and its entry in the state with it.
        XCTAssertNil(run("channel 2 clear", source: .osc))
        XCTAssertNotNil(disk.control.channelTextures[2])
        XCTAssertNil(restore("2026-10-29-090000"))
        XCTAssertEqual(library.channels.map(\.number), [1, 3])
        XCTAssertNil(disk.control.channelTextures[2])
        XCTAssertNil(disk.control.pictureSurfaces[2])
        XCTAssertNil(disk.engine.state.channels[2])
        XCTAssertNil(disk.engine.lastPlan?.channelPasses.first { $0.channel == 2 })

        // Undoing the restore brings it back: empty, with textures of its own.
        XCTAssertNil(run("undo"))
        XCTAssertEqual(library.channels.map(\.number), [1, 2, 3])
        XCTAssertNotNil(disk.control.channelTextures[2])
        XCTAssertEqual(disk.control.pictureSurfaces[2]?.count, 3)
        XCTAssertEqual(disk.engine.state.channels[2]?.content, .empty, "a channel that comes back starts empty")
    }

    /// "the live list may go", "and the pointer goes on from its kept copies when its playlist, item or
    /// list goes (Spec 7 §4)"; "a reference the restore breaks is flagged by the reference report".
    func test_theLiveListMayGoAndThePointerGoesOnFromItsKeptCopy() throws {
        XCTAssertNil(run("list 42 cue 1", source: .osc))
        let firstCue = disk.engine.state.pointer?.cueUuid
        try plant("2026-10-29-090000") { snapshot in
            snapshot.documents.removeValue(forKey: "library/" + Self.hymn)
        }
        XCTAssertNil(restore("2026-10-29-090000"))
        disk.nextSecond()
        XCTAssertNil(library.list(number: 42), "the live list went")
        XCTAssertFalse(disk.exists(.library, Self.hymn))
        XCTAssertEqual(disk.engine.state.pointer?.listUuid?.uuidString.lowercased(), Self.list42, "a restore never moves the pointer")

        XCTAssertNil(run("next", source: .osc))
        XCTAssertNotEqual(disk.engine.state.pointer?.cueUuid, firstCue, "the song finishes from the copy the engine keeps")
        XCTAssertEqual(disk.engine.state.pointer?.listUuid?.uuidString.lowercased(), Self.list42)

        // The snapshot's playlists still link the list it didn't hold: the report says so.
        let report = Validator.validate(library: library, machine: machine)
        XCTAssertFalse(report.issues(.missingList).isEmpty, report.lines.joined(separator: "\n"))
    }

    /// "On a `readOnlyMasters` machine only the machine documents are replaced, and the result warns that
    /// the library was left as it was (choice G-7)."
    func test_onReadOnlyMastersOnlyTheMachineDocumentsAreReplacedAndTheResultWarns() throws {
        disk = try DiskFixture(wallClock: Self.start, configure: { $0.settings.libraryMode = .readOnlyMasters }, launch: true)
        disk.settleSaving()
        // The library as it would be had it changed since (it can't be edited here): a snapshot of an older library.
        try plant("2026-10-29-090000") { snapshot in
            try rewrite(&snapshot, "library/lists/007-doxology.json") { $0["title"] = .string("An Older Title") }
        }
        XCTAssertNil(run("edit playlist create \"Evening\""))
        disk.nextSecond()
        let hymnal = try XCTUnwrap(disk.data(.library, Self.doxology))

        later(60)
        disk.send("system restore snapshot \"2026-10-29-090000\"")
        disk.engine.tick()
        disk.engine.waitForSnapshots()
        disk.engine.tick()
        let line = try XCTUnwrap(disk.engine.lastExecuted.first { $0.command.isRestore })
        XCTAssertEqual(line.result, .ok)
        XCTAssertEqual(line.warnings.count, 1)
        XCTAssertTrue(line.warnings[0].contains("the library was left as it was"), line.warnings[0])
        disk.settleSaving()
        disk.nextSecond()
        XCTAssertNil(machine.playlists.first { $0.title == "Evening" }, "the machine documents are the snapshot's")
        XCTAssertFalse(disk.exists(.machine, "playlists/evening.json"))
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology", "the library is left")
        XCTAssertEqual(disk.data(.library, Self.doxology), hymnal)
    }

    // MARK: - On a worker

    /// "Meanwhile runtime commands keep flowing, and edits, undos and redos wait in the queue behind it,
    /// so nothing lands in documents the restore is about to replace": "While the worker runs, cues keep
    /// firing and a lyric edit waits, then lands after the restore".
    func test_whileTheWorkerRunsCuesKeepFiringAndALyricEditWaitsThenLands() throws {
        XCTAssertNil(run("edit list 7 title \"Before The Restore\""))
        let gate = Gate()
        disk.control.snapshots?.beforeRead = gate.hold

        later(60)
        disk.send("system restore snapshot \"\(Self.launch)\"")
        disk.engine.tick()
        XCTAssertNotNil(disk.control.mediaPark, "the restore is validated, and waits for its worker")
        XCTAssertEqual(library.list(number: 7)?.title, "Before The Restore", "nothing is replaced yet")

        disk.send("list 42 cue 1", source: .osc)
        disk.send("edit list 7 author \"Typed Meanwhile\"")
        disk.send("next", source: .osc)
        disk.engine.tick(count: 30)
        XCTAssertEqual(disk.engine.state.pointer?.listUuid?.uuidString.lowercased(), Self.list42, "cues keep firing")
        XCTAssertNotEqual(disk.engine.state.channels[2]?.content, .empty)
        XCTAssertNotEqual(library.list(number: 7)?.author, "Typed Meanwhile", "the edit waits behind the restore")
        XCTAssertNotNil(disk.control.mediaPark)

        gate.release()
        disk.settleSaving()
        XCTAssertNil(disk.control.mediaPark)
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology", "the restore applied in one step")
        XCTAssertEqual(library.list(number: 7)?.author, "Typed Meanwhile", "and the edit landed after it, on what it restored")
        let texts = entries().map(\.text)
        let restored = try XCTUnwrap(texts.firstIndex { $0.hasPrefix("system restore snapshot") })
        let typed = try XCTUnwrap(texts.firstIndex { $0.contains("Typed Meanwhile") })
        let fired = try XCTUnwrap(texts.firstIndex(of: "list 42 cue 1"))
        XCTAssertLessThan(fired, restored, "the cue was logged while the restore waited")
        XCTAssertLessThan(restored, typed)
    }

    /// "a failure while the pre-restore snapshot is written leaves every document as it was".
    func test_aFailureWhileThePreRestoreSnapshotIsWrittenLeavesEveryDocumentAsItWas() throws {
        _ = try changeEverything()
        let before = (library, machine)
        let files = disk.files(.library, under: "lists") + disk.files(.machine, under: "playlists")
        let contents = bytes(files.map { ($0.hasPrefix("lists") ? .library : .machine, $0) })

        disk.disk.full = true
        let rejection = restore(Self.launch)
        disk.disk.full = false
        XCTAssertEqual(rejection?.reason, .diskFull)
        disk.nextSecond()
        XCTAssertEqual(library, before.0)
        XCTAssertEqual(machine, before.1)
        XCTAssertEqual(disk.files(.library, under: "lists") + disk.files(.machine, under: "playlists"), files)
        XCTAssertEqual(bytes(files.map { ($0.hasPrefix("lists") ? .library : .machine, $0) }), contents)
        XCTAssertEqual(disk.snapshotIDs, [Self.launch], "no snapshot was written, so nothing could be undone to")
        XCTAssertNil(disk.control.history.undoTop.flatMap { $0.commands.first?.isRestore == true ? $0 : nil })
    }

    /// "Held by a cue, macro, key binding or scheduler entry, the rest of the group runs at once and the
    /// restore applies after it, or is logged `blocked` if it fails, as Spec 8 §2 does for a held `media delete`."
    func test_heldInACueTheOtherCommandsRunAtOnceAndAFailureIsBlocked() throws {
        XCTAssertNil(run("edit list 7 title \"Before The Restore\""))
        let gate = Gate()
        disk.control.snapshots?.beforeRead = gate.hold
        later(60)
        disk.engine.send(group: ["system restore snapshot \"\(Self.launch)\"", "channel 1 lock"], source: .key)
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state.channels[1]?.lock, true, "the rest of the group runs at once")
        XCTAssertEqual(library.list(number: 7)?.title, "Before The Restore")
        gate.release()
        disk.control.snapshots?.beforeRead = nil
        disk.settleSaving()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology", "the restore applies after it")
        let line = try XCTUnwrap(entries().last { $0.command.isRestore })
        XCTAssertEqual(line.source.kind, .key)
        XCTAssertEqual(line.result, .ok)

        disk.engine.send(group: ["system restore snapshot \"2026-01-01-000000\"", "channel 2 lock"], source: .scheduler)
        disk.settleSaving()
        XCTAssertEqual(disk.engine.state.channels[2]?.lock, true)
        let blocked = try XCTUnwrap(entries().last { $0.command.isRestore })
        XCTAssertEqual(blocked.result, .blocked)
        XCTAssertEqual(blocked.source.kind, .scheduler)
        XCTAssertTrue(disk.log.contains("blocked scheduler edit system restore snapshot \"2026-01-01-000000\": unknownObject"))
        XCTAssertTrue(disk.control.rejections.isEmpty, "a held refusal rejects nothing")
    }

    /// The plan's reading — a worker that never answers is a failure after thirty seconds, with `conflict`.
    func test_aWorkerThatDoesNotAnswerInThirtySecondsIsAConflict() throws {
        let gate = Gate()
        disk.control.snapshots?.beforeRead = gate.hold
        later(60)
        disk.send("system restore snapshot \"\(Self.launch)\"")
        disk.send("edit list 7 author \"Waited\"")
        disk.engine.tick(count: 29 * 60)
        XCTAssertNotNil(disk.control.mediaPark)
        XCTAssertTrue(disk.control.rejections.isEmpty)
        disk.engine.tick(count: 70)
        XCTAssertNil(disk.control.mediaPark)
        XCTAssertEqual(disk.control.rejections.last?.reason, .conflict)
        XCTAssertEqual(library.list(number: 7)?.author, "Waited", "what waited behind it runs")
        gate.release()
        disk.settleSaving()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology")
        XCTAssertTrue(entries().allSatisfy { !$0.command.isRestore }, "what the worker read too late is dropped")
    }

    /// "Both are refused with `diskFull` while the disk is full (§7)", and operator lock refuses it (Spec 5 §7).
    func test_aFullDiskAndOperatorLockRefuseIt() throws {
        disk.fillDisk()
        XCTAssertEqual(run("system restore snapshot \"\(Self.launch)\"")?.reason, .diskFull)
        disk.freeDisk()

        disk = try DiskFixture(wallClock: Self.start, configure: { $0.settings.operatorLock.enabled = true }, launch: true)
        disk.settleSaving()
        XCTAssertEqual(run("system restore snapshot \"\(Self.launch)\"")?.reason, .operatorLock)
        XCTAssertEqual(disk.snapshotIDs, [Self.launch], "refused before anything was read or written")
    }

    /// An arriving file is looked at after the restore applies (the plan's reading), and then meets
    /// Spec 5 §10 like any arrival.
    func test_aFileThatArrivesWhileTheRestoreIsReadIsLookedAtAfterIt() throws {
        XCTAssertNil(run("edit list 7 title \"Before The Restore\""))
        disk.nextSecond()
        let gate = Gate()
        disk.control.snapshots?.beforeRead = gate.hold
        later(60)
        disk.send("system restore snapshot \"\(Self.launch)\"")
        disk.engine.tick()
        // A sync changes list 42 meanwhile.
        try disk.write(.library, Self.hymn, try disk.edited(.library, Self.hymn, "author", .string("Arrived Meanwhile")))
        disk.engine.scanDisk()
        XCTAssertNotEqual(library.list(number: 42)?.author, "Arrived Meanwhile", "not while the restore is read")
        gate.release()
        disk.settleSaving()
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology")
        XCTAssertEqual(library.list(number: 42)?.author, "Arrived Meanwhile", "after it, as any arrival")
    }
}
