import Foundation
import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 9 §6 — kept versions and `system restore list N version V` in the
/// engine. Spec 9 §10, Versions: "A save keeps versions in the list's uuid
/// folder; after a renumber they stay with the list, and a list that takes
/// the freed number writes to its own folder. A list copied back over itself
/// from an old version and then edited twice writes its next versions above
/// every kept one, and no kept file changes." List restore: "A kept version
/// comes back with the list's current number, uuid and folder and a `version`
/// above every kept one; the current document is kept first whatever the
/// ten-minute rule says; undo brings back exactly what was replaced. No such
/// version is `unknownObject`; a deleted list can't be restored; a local copy
/// is `notInV1`; a `readOnlyMasters` machine is `readOnlyLibrary`; a full
/// disk is `diskFull`; operator lock refuses it, and inside a cue it's
/// `blocked`." And the `versions` query (§6, "Picking one"). On temporary
/// copies of the fixture, whose list 42 is at version 17 with v0016 kept.
final class ListRestoreEngineTests: XCTestCase {
    static let list42 = "a9f00000-0000-4000-8000-00000000002a"
    static let hymn = "lists/Hymns/042-great-is-thy-faithfulness.json"
    static let versions = "versions/" + list42

    var disk: DiskFixture!
    var library: Library { disk.engine.engine.library }

    override func setUpWithError() throws {
        disk = try DiskFixture(launch: true)
        disk.settleSaving()
    }

    override func tearDown() {
        disk = nil
    }

    func entries() -> [LogEntry] { disk.commandLog().compactMap(\.entry) }

    /// A command sent and everything it starts settled; the reason it was rejected with, if it was.
    @discardableResult
    func run(_ text: String, source: SourceKind = .ui) -> RejectionReason? {
        let before = disk.control.rejections.count
        disk.send(text, source: source)
        disk.settleSaving()
        return disk.control.rejections.count > before ? disk.control.rejections.last?.reason : nil
    }

    func kept() -> [String] { disk.files(.library, under: Self.versions) }

    func query(_ members: [String: JSONValue]) -> [String: JSONValue] {
        var request = members
        request["id"] = .number(7)
        request["type"] = .string("query")
        return disk.engine.engine.publisher.query(.object(request)).objectValue ?? [:]
    }

    // MARK: - Versions

    /// "A save keeps versions in the list's uuid folder; after a renumber they stay with the list, and a
    /// list that takes the freed number writes to its own folder."
    func test_afterARenumberVersionsStayWithTheListAndTheFreedNumberGetsItsOwnFolder() throws {
        // An hour on from the fixture's kept copy, so each save here keeps the file it replaces (choice E-3).
        disk = try DiskFixture(wallClock: Date().addingTimeInterval(3600))
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.settle()
        XCTAssertEqual(kept(), ["\(Self.versions)/v0016.json", "\(Self.versions)/v0017.json"])

        disk.send("edit list 42 renumber 43")
        disk.nextSecond()
        disk.clock.now = disk.clock.now.addingTimeInterval(11 * 60)
        disk.send("edit list 43 author \"T. Chisholm\"")
        disk.nextSecond()
        XCTAssertEqual(kept().count, 3, "kept with the list that made them, whatever its number is now")
        XCTAssertTrue(kept().allSatisfy { $0.hasPrefix(Self.versions + "/") })

        // Another list takes the freed number.
        disk.send("edit list 42 create {\"title\": \"A New Song\"}")
        disk.nextSecond()
        let taker = try XCTUnwrap(library.list(number: 42))
        XCTAssertNotEqual(taker.uuid.uuidString.lowercased(), Self.list42)
        disk.clock.now = disk.clock.now.addingTimeInterval(11 * 60)
        disk.send("edit list 42 author \"Someone\"")
        disk.nextSecond()
        let own = "versions/" + taker.uuid.uuidString.lowercased()
        XCTAssertEqual(disk.files(.library, under: own).count, 1, "its own folder")
        XCTAssertEqual(kept().count, 3, "and the first list's folder is as it was")
    }

    /// "A list copied back over itself from an old version and then edited twice writes its next versions
    /// above every kept one, and no kept file changes."
    func test_aListCopiedBackFromAnOldVersionSavesAboveEveryKeptOne() throws {
        disk = try DiskFixture(wallClock: Date().addingTimeInterval(3600))
        let old = try XCTUnwrap(disk.data(.library, "\(Self.versions)/v0016.json"))
        // A Finder copy of the kept file over the list's own.
        try disk.write(.library, Self.hymn, old)
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 42)?.version, 16)

        disk.send("edit list 42 author \"First\"")
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 17, "above the kept 16")
        disk.clock.now = disk.clock.now.addingTimeInterval(11 * 60)
        disk.send("edit list 42 author \"Second\"")
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 18)
        XCTAssertEqual(disk.data(.library, "\(Self.versions)/v0016.json"), old, "no kept file changes")
        XCTAssertEqual(kept(), ["\(Self.versions)/v0016.json", "\(Self.versions)/v0017.json"])
        guard case .list(let seventeen)? = disk.document(.library, "\(Self.versions)/v0017.json") else { return XCTFail("v0017 isn't a list") }
        XCTAssertEqual(seventeen.author, "First", "the file the second save replaced")
    }

    // MARK: - A list restore

    /// "A kept version comes back with the list's current number, uuid and folder and a `version` above
    /// every kept one; the current document is kept first whatever the ten-minute rule says".
    func test_aKeptVersionComesBackAndTheCurrentDocumentIsKeptFirst() throws {
        let before = try XCTUnwrap(disk.data(.library, Self.hymn))
        let current = try XCTUnwrap(library.list(number: 42))
        XCTAssertEqual(current.cues.count, 4)
        let revision = disk.control.revision

        XCTAssertNil(run("system restore list 42 version 16"))
        let restored = try XCTUnwrap(library.list(number: 42))
        XCTAssertEqual(restored.cues.count, 2, "version 16 had two cues")
        XCTAssertEqual(restored.uuid, current.uuid)
        XCTAssertEqual(restored.number, 42)
        XCTAssertEqual(disk.list(at: Self.hymn)?.cues.count, 2, "in the folder it is in now")
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 18, "above every kept one: 16 and now 17")
        // The fixture's kept copy is minutes old on this clock, so E-3 alone would have kept nothing.
        XCTAssertEqual(kept(), ["\(Self.versions)/v0016.json", "\(Self.versions)/v0017.json"])
        XCTAssertEqual(disk.document(.library, "\(Self.versions)/v0017.json"), .list(current), "the document it replaced, as its file held it")
        XCTAssertEqual(try XCTUnwrap(disk.data(.library, "\(Self.versions)/v0017.json")).count, before.count)

        // One edit group: a line with its inverse, one `library` event with cause `restore`, the revision up by one.
        let line = try XCTUnwrap(entries().last)
        XCTAssertEqual(line.text, "system restore list 42 version 16")
        XCTAssertEqual(line.kind, .edit)
        XCTAssertEqual(line.undo, .edit)
        XCTAssertEqual(line.result, .ok)
        XCTAssertEqual(line.inverse, .systemRestoreList(list: 42, version: 17))
        XCTAssertEqual(disk.control.revision, revision + 1)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("restore"))
        XCTAssertEqual(disk.events.all.last?["group"], .string(line.group.rawValue))
        XCTAssertEqual(disk.events.all.last?["changed"]?.arrayValue?.first?["list"], .number(42))
    }

    /// "undo brings back exactly what was replaced": the restore's inverse restores the version it kept.
    func test_undoBringsBackExactlyWhatWasReplaced() throws {
        let current = try XCTUnwrap(library.list(number: 42))
        XCTAssertNil(run("system restore list 42 version 16"))
        let group = try XCTUnwrap(entries().last?.group)

        XCTAssertNil(run("undo"))
        var back = try XCTUnwrap(library.list(number: 42))
        XCTAssertEqual(back.cues, current.cues)
        back.version = current.version
        XCTAssertEqual(back, current, "everything but its `version`")
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 19, "its save goes above every kept one again")
        XCTAssertEqual(kept().count, 3, "the restored document was kept in its turn, as v0018")
        let lines = entries().suffix(2)
        XCTAssertEqual(lines.map(\.text), ["undo", "system restore list 42 version 17"])
        XCTAssertEqual(lines.last?.undoes, group)
        XCTAssertEqual(lines.last?.source.kind, .restore)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("undo"))

        XCTAssertNil(run("redo"))
        XCTAssertEqual(library.list(number: 42)?.cues.count, 2)
        XCTAssertEqual(entries().last?.redoes, group)
    }

    /// The plan's reading — a document with unwritten edits is kept under the next number above every
    /// kept one, so the kept file holds those edits and none is written over.
    func test_aDocumentWithUnwrittenEditsIsKeptAboveEveryKeptOne() throws {
        disk.send("edit list 42 author \"Written\"")
        disk.settle()
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 18)
        // A second edit inside the same second waits for its write; the restore arrives before it.
        disk.send("edit list 42 author \"Not Written Yet\"")
        disk.engine.tick()
        XCTAssertEqual(disk.list(at: Self.hymn)?.author, "Written")
        XCTAssertNil(run("system restore list 42 version 16"))

        XCTAssertEqual(entries().last?.inverse, .systemRestoreList(list: 42, version: 19))
        guard case .list(let nineteen)? = disk.document(.library, "\(Self.versions)/v0019.json") else { return XCTFail("v0019 wasn't kept") }
        XCTAssertEqual(nineteen.author, "Not Written Yet", "the edits that were never written are kept")
        XCTAssertEqual(nineteen.version, 19)
        XCTAssertFalse(disk.exists(.library, "\(Self.versions)/v0018.json"), "18 is the file's own number, and the file didn't hold this document")
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 20)
        XCTAssertEqual(disk.list(at: Self.hymn)?.cues.count, 2)
    }

    /// A version a sync brought after launch counts: the worker finds it, and nothing is written over it.
    func test_aVersionThatArrivedAfterLaunchIsNeverWrittenOver() throws {
        let arrived = Data("{\"kept\": \"at another campus\"}\n".utf8)
        try disk.write(.library, "\(Self.versions)/v0017.json", arrived)
        XCTAssertNil(run("system restore list 42 version 16"))
        XCTAssertEqual(disk.data(.library, "\(Self.versions)/v0017.json"), arrived)
        XCTAssertEqual(entries().last?.inverse, .systemRestoreList(list: 42, version: 18))
        XCTAssertTrue(disk.exists(.library, "\(Self.versions)/v0018.json"))
        XCTAssertEqual(disk.list(at: Self.hymn)?.version, 19)
    }

    /// "A list on air takes the new content as any edit of it would: each cue on its next fire (Spec 5 §2)."
    func test_aListOnAirTakesTheRestoredContentOnItsNextFire() throws {
        disk.send("list 42 cue 1", source: .osc)
        disk.settle()
        let state = disk.engine.state
        XCTAssertNil(run("system restore list 42 version 16"))
        XCTAssertEqual(disk.engine.state, state, "a restore changes the library and never ShowState")
        XCTAssertEqual(disk.engine.state.pointer?.listUuid?.uuidString.lowercased(), Self.list42)
    }

    // MARK: - Refusals

    func test_noSuchVersionIsUnknownObjectAndADeletedListCannotBeRestored() throws {
        let before = library
        XCTAssertEqual(run("system restore list 42 version 3"), .unknownObject, "the file with that list's uuid and version")
        XCTAssertEqual(library, before)
        XCTAssertEqual(kept(), ["\(Self.versions)/v0016.json"], "nothing was kept for a restore that didn't happen")

        // List 7 has no local copy of its number, so once it is deleted nothing is list 7.
        XCTAssertNil(run("edit list 7 delete"))
        XCTAssertEqual(run("system restore list 7 version 3"), .unknownObject, "only lists that exist (choice G-11)")
        // "a deleted one comes back by undo in the same run".
        XCTAssertNil(run("undo"))
        XCTAssertNotNil(library.list(number: 7))
    }

    func test_aLocalCopyIsNotInV1AndReadOnlyMastersIsReadOnlyLibrary() throws {
        disk = try DiskFixture(prepare: { folder in
            let url = folder.appendingPathComponent("machine/lists-local/042-great-is-thy-faithfulness-manheim.json")
            guard case .object(var members) = try JSONValue.parse(try Data(contentsOf: url)) else { return }
            members["number"] = .number(99)
            try JSONCanonical.data(.object(members)).write(to: url)
        }, launch: true)
        disk.settleSaving()
        XCTAssertEqual(run("system restore list 99 version 16"), .notInV1)

        disk = try DiskFixture(configure: { $0.settings.libraryMode = .readOnlyMasters }, launch: true)
        disk.settleSaving()
        XCTAssertEqual(run("system restore list 42 version 16"), .readOnlyLibrary)
        XCTAssertEqual(library.list(number: 42)?.cues.count, 4)
    }

    func test_aFullDiskIsDiskFullAndOperatorLockRefusesIt() throws {
        disk.control.diskFull = true
        XCTAssertEqual(run("system restore list 42 version 16"), .diskFull)
        disk.control.diskFull = false

        disk = try DiskFixture(configure: { $0.settings.operatorLock.enabled = true }, launch: true)
        disk.settleSaving()
        for source: SourceKind in [.ui, .api, .osc] {
            XCTAssertEqual(run("system restore list 42 version 16", source: source), .operatorLock, "\(source)")
        }
        XCTAssertEqual(library.list(number: 42)?.cues.count, 4)
        XCTAssertEqual(kept(), ["\(Self.versions)/v0016.json"])
    }

    /// "held by a cue, macro, key binding or scheduler entry, a refusal is `blocked` and the rest of the
    /// group runs (Spec 5 §2)"; one that passes applies after the rest.
    func test_insideACueItIsBlockedWhenRefusedAndAppliesAfterTheRestWhenNot() throws {
        disk.engine.send(group: ["system restore list 42 version 3", "channel 1 lock"], source: .key)
        disk.settleSaving()
        let blocked = entries().suffix(2)
        XCTAssertEqual(Set(blocked.map(\.text)), ["system restore list 42 version 3", "channel 1 lock"])
        XCTAssertEqual(blocked.first { $0.command.isRestore }?.result, .blocked)
        XCTAssertEqual(disk.engine.state.channels[1]?.lock, true, "the rest of the group ran")
        XCTAssertTrue(disk.log.contains("blocked key edit system restore list 42 version 3: unknownObject"))
        XCTAssertEqual(library.list(number: 42)?.cues.count, 4)

        disk.engine.send(group: ["system restore list 42 version 16", "channel 2 lock"], source: .scheduler)
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state.channels[2]?.lock, true, "the rest runs at once")
        disk.settleSaving()
        XCTAssertEqual(library.list(number: 42)?.cues.count, 2, "and the restore applies after it")
        XCTAssertEqual(entries().last?.source.kind, .scheduler)
        XCTAssertEqual(entries().last?.result, .ok)
    }

    // MARK: - The versions query

    /// "`{ "type": "query", "what": "versions", "list": 42 }` returns that list's kept versions, newest
    /// first, each with `version`, `keptAt` (the file's date), `title` and `cues`, how many it has."
    func test_theVersionsQueryListsNewestFirstWithTheirFields() throws {
        XCTAssertNil(run("edit list 42 title \"Renamed\""))
        XCTAssertNil(run("system restore list 42 version 16"))
        let answer = query(["what": .string("versions"), "list": .number(42)])
        XCTAssertEqual(answer["type"], .string("answer"))
        XCTAssertEqual(answer["id"], .number(7))
        let versions = try XCTUnwrap(answer["versions"]?.arrayValue)
        XCTAssertEqual(versions.map { $0["version"]?.intValue }, [18, 16], "newest first")
        XCTAssertEqual(versions[0]["title"], .string("Renamed"))
        XCTAssertEqual(versions[0]["cues"], .number(4))
        XCTAssertEqual(versions[1]["title"], .string("Great Is Thy Faithfulness"))
        XCTAssertEqual(versions[1]["cues"], .number(2))
        for version in versions {
            let keptAt = try XCTUnwrap(version["keptAt"]?.stringValue)
            XCTAssertNotNil(CivilTime.milliseconds(keptAt), "\(keptAt) is a stamp in the machine's zone")
        }
        XCTAssertEqual(Set(versions[0].objectValue?.keys.map { $0 } ?? []), ["version", "keptAt", "title", "cues"])

        XCTAssertEqual(query(["what": .string("versions"), "list": .number(7)])["versions"], .array([]), "a list with none kept")
        XCTAssertEqual(query(["what": .string("versions"), "list": .number(999)])["result"], .string("rejected"))
        XCTAssertEqual(query(["what": .string("versions")])["result"], .string("rejected"))
    }
}
