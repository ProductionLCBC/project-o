import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 5 §2 — "Writing. The engine writes a changed document with Spec 1
/// §5's atomic write within one second of each change, and at most once a
/// second ... Each write of a list master increments its `version`"; Spec 1
/// §4 and choice E-3 — the previous file is kept in `versions/` "only when the
/// last copy is more than ten minutes old", and "No save writes over a kept
/// version"; Spec 7 §2 — folders, moves and deletes on disk, where "Moving a
/// list or a folder is a rename on disk, not a save"; Spec 7 §3 — playlist
/// files named from their titles; Spec 5 §10 — the engine's edits win, and an
/// arriving file is kept in `machine/conflicts/`. On a temporary copy of the
/// fixture.
final class DocumentWriterTests: XCTestCase {
    static let list42 = "a9f00000-0000-4000-8000-00000000002a"
    static let list7 = "a9f00000-0000-4000-8000-000000000007"
    static let sunday = "b1a70000-0000-4000-8000-000000000001"
    static let hymn = "lists/Hymns/042-great-is-thy-faithfulness.json"
    static let doxology = "lists/007-doxology.json"

    var library: Library { disk.engine.engine.library }
    var machine: Machine { disk.engine.engine.machine }
    var disk: DiskFixture!

    override func setUpWithError() throws {
        disk = try DiskFixture()
    }

    override func tearDown() {
        disk = nil
    }

    // MARK: - Content

    /// "within one second of each change": the first change is written at
    /// once, its version one higher, and "a save renames the file within its
    /// folder" (Spec 7 §2).
    func test_anEditIsWrittenAndTheListsVersionRises() throws {
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.settle()
        let path = "lists/Hymns/042-faithfulness.json"
        XCTAssertEqual(disk.list(at: path)?.title, "Faithfulness")
        XCTAssertEqual(disk.list(at: path)?.version, 18, "17 on disk before the write")
        XCTAssertFalse(disk.exists(.library, Self.hymn), "renamed, not copied")
        XCTAssertEqual(library.list(number: 42)?.version, 18, "the version rises in memory with the write")
        XCTAssertEqual(library.documentPaths["list/" + Self.list42], path)
        XCTAssertEqual(disk.files(.library, under: "versions/" + Self.list42), ["versions/\(Self.list42)/v0016.json"],
                       "the kept copy is younger than ten minutes on this clock: nothing new is kept")
    }

    /// "Typing therefore writes at most once a second, and the last
    /// keystroke always lands."
    func test_typingWritesAtMostOnceASecondAndTheLastKeystrokeLands() throws {
        for title in ["G", "Gr", "Gre", "Grea", "Great"] {
            disk.send("edit list 7 title \"\(title)\"", client: "app")
            disk.engine.tick()
        }
        disk.engine.waitForWrites()
        XCTAssertEqual(disk.list(at: "lists/007-g.json")?.version, 4, "the first change, at once")
        XCTAssertEqual(disk.files(.library, under: "lists").filter { $0.hasPrefix("lists/007") }, ["lists/007-g.json"])
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: "lists/007-great.json")?.title, "Great")
        XCTAssertEqual(disk.list(at: "lists/007-great.json")?.version, 5, "two writes in all")
        XCTAssertEqual(disk.files(.library, under: "lists").filter { $0.hasPrefix("lists/007") }, ["lists/007-great.json"])
    }

    /// Choice E-3 — "A save copies the previous file to `versions/` only when
    /// the last copy is more than ten minutes old."
    func test_thePreviousFileIsKeptWhenTheLastCopyIsOlderThanTenMinutes() throws {
        disk = try DiskFixture(wallClock: Date().addingTimeInterval(3600))
        let before = try XCTUnwrap(disk.data(.library, Self.hymn))
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.settle()
        XCTAssertEqual(disk.data(.library, "versions/\(Self.list42)/v0017.json"), before, "the file the write replaced, as it was")
        disk.send("edit list 42 author \"T. Chisholm\"")
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: "lists/Hymns/042-faithfulness.json")?.version, 19)
        XCTAssertFalse(disk.exists(.library, "versions/\(Self.list42)/v0018.json"), "the last copy is a second old")
        XCTAssertEqual(disk.control.documents?.kept.highest(try XCTUnwrap(UUID(uuidString: Self.list42))), 17)
    }

    /// Spec 9 §6 — "No save writes over a kept version": a version already
    /// kept isn't copied again, and the list saves above it.
    func test_aKeptVersionIsNeverWrittenOver() throws {
        let planted = Data("{\"kept\": \"elsewhere\"}\n".utf8)
        disk = try DiskFixture(wallClock: Date().addingTimeInterval(3600), prepare: { folder in
            try planted.write(to: folder.appendingPathComponent("library/versions/\(Self.list42)/v0017.json"))
        })
        disk.send("edit list 42 title \"Faithfulness\"")
        disk.settle()
        XCTAssertEqual(disk.data(.library, "versions/\(Self.list42)/v0017.json"), planted)
        XCTAssertEqual(disk.list(at: "lists/Hymns/042-faithfulness.json")?.version, 18)
    }

    // MARK: - File work (Spec 7 §2)

    /// Folder edits and list moves happen at once, in order, and "Moving a
    /// list or a folder is a rename on disk, not a save: no `version` goes up
    /// and nothing is copied to `versions/`".
    func test_foldersAndMovesAreRenamesOnDisk() throws {
        disk = try DiskFixture(wallClock: Date().addingTimeInterval(3600))
        disk.engine.send(group: ["edit folder \"Worship\" create", "edit list 42 folder \"Worship\""], source: .ui)
        disk.settle()
        let moved = "lists/Worship/042-great-is-thy-faithfulness.json"
        XCTAssertEqual(disk.list(at: moved)?.version, 17)
        XCTAssertFalse(disk.exists(.library, Self.hymn))
        XCTAssertTrue(disk.exists(.library, "lists/Hymns"), "the folder it left stays, empty")
        XCTAssertEqual(disk.files(.library, under: "versions/" + Self.list42), ["versions/\(Self.list42)/v0016.json"])

        disk.send("edit folder \"Worship\" rename \"Music\"")
        disk.settle()
        XCTAssertEqual(disk.list(at: "lists/Music/042-great-is-thy-faithfulness.json")?.version, 17)
        XCTAssertFalse(disk.exists(.library, "lists/Worship"))

        disk.send("edit folder \"Christmas\" delete")
        disk.settle()
        XCTAssertFalse(disk.exists(.library, "lists/Christmas"), "its hidden .keep goes with it")
        XCTAssertTrue(disk.log.recent.filter { $0.level == .error }.isEmpty, "\(disk.log.recent)")
    }

    /// A new list is written in its folder at the version it has; a delete
    /// removes its file.
    func test_aNewListIsWrittenInItsFolderAndADeleteRemovesIt() throws {
        disk.send("edit list 57 create folder \"Hymns\"")
        disk.settle()
        XCTAssertEqual(disk.list(at: "lists/Hymns/057.json")?.version, 1)
        disk.send("edit list 57 delete")
        disk.settle()
        XCTAssertFalse(disk.exists(.library, "lists/Hymns/057.json"))
        XCTAssertNil(library.list(number: 57))
    }

    /// Spec 7 §3 — "A playlist's file name is a slug of its title ... and
    /// keeps it until the title changes"; a created, archived or deleted
    /// playlist's file comes and goes with it.
    func test_playlistFilesFollowTheirTitles() throws {
        disk.send("edit playlist \(Self.sunday) title \"Sunday Morning\"")
        disk.settle()
        XCTAssertEqual(disk.playlist(at: "playlists/sunday-morning.json")?.title, "Sunday Morning")
        XCTAssertFalse(disk.exists(.machine, "playlists/sunday.json"))

        disk.send("edit playlist create \"Easter\"")
        disk.settle()
        let easter = try XCTUnwrap(machine.playlist(titled: "Easter"))
        XCTAssertEqual(disk.playlist(at: "playlists/easter.json")?.uuid, easter.uuid)
        disk.send("edit playlist \(easter.uuid.uuidString.lowercased()) delete")
        disk.settle()
        XCTAssertFalse(disk.exists(.machine, "playlists/easter.json"))

        disk.send("edit playlist \(Self.sunday) archive")
        disk.settle()
        XCTAssertEqual(disk.playlist(at: "playlists/sunday-morning-2026-11-01.json")?.archived, true)
    }

    /// Spec 1 §4 — "every internal reference in the library and the machine
    /// root is rewritten in the same save": a renumber writes the list and
    /// every playlist that links it, archived ones included, and the roots
    /// read back from disk are the roots in memory.
    func test_aRenumberWritesEveryDocumentItRewrote() throws {
        disk.send("edit list 7 renumber 8")
        disk.settle()
        XCTAssertEqual(disk.list(at: "lists/008-doxology.json")?.version, 4)
        XCTAssertFalse(disk.exists(.library, Self.doxology))
        for file in ["playlists/sunday.json", "playlists/sunday-night.json", "playlists/sunday-2026-11-01.json"] {
            let links = disk.playlist(at: file)?.items.compactMap { item -> Int? in
                if case .linked(let list, _) = item.kind { return list } else { return nil }
            }
            XCTAssertEqual(links?.contains(8), true, file)
            XCTAssertEqual(links?.contains(7), false, file)
        }
        let reread = try LoadedRoots.load(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot)
        XCTAssertEqual(reread.library.lists, library.lists)
        XCTAssertEqual(reread.machine.playlists, machine.playlists)
        XCTAssertEqual(reread.library.documentPaths.filter { $0.key.hasPrefix("list/") },
                       library.documentPaths.filter { $0.key.hasPrefix("list/") })
    }

    // MARK: - Failures and conflicts

    /// "A failed write is logged and tried again": the document keeps its
    /// file's name until a write lands.
    func test_aFailedWriteIsLoggedAndTriedAgain() throws {
        let lists = disk.url(.library, "lists").path
        XCTAssertEqual(chmod(lists, 0o555), 0)
        defer { chmod(lists, 0o755) }
        disk.send("edit list 7 title \"Gloria\"")
        disk.settle()
        XCTAssertTrue(disk.log.contains("could not write list \(Self.list7)"), "\(disk.log.recent)")
        XCTAssertEqual(disk.list(at: Self.doxology)?.title, "Doxology")
        XCTAssertEqual(library.documentPaths["list/" + Self.list7], Self.doxology, "named where its file still is")

        XCTAssertEqual(chmod(lists, 0o755), 0)
        disk.nextSecond()
        XCTAssertEqual(disk.list(at: "lists/007-gloria.json")?.title, "Gloria")
        XCTAssertFalse(disk.exists(.library, Self.doxology))
        XCTAssertTrue(disk.log.contains("wrote list \(Self.list7) again"))
    }

    /// Spec 9 §4 — every unwritten edit is written before the engine stops.
    func test_unwrittenEditsAreWrittenWhenTheEngineStops() throws {
        disk.send("edit list 7 title \"A\"")
        disk.settle()
        disk.send("edit list 7 title \"B\"")
        disk.engine.tick()
        XCTAssertEqual(disk.control.documents?.dirty.count, 1, "a second hasn't passed")
        disk.control.flushDocuments(now: disk.engine.clock.now())
        XCTAssertEqual(disk.list(at: "lists/007-b.json")?.title, "B")
    }

    /// Spec 5 §10 — "Unwritten edits. The engine's edits win. It keeps the
    /// arriving file in `machine/conflicts/`, named with the time and the
    /// file's name, writes its own document, and logs both": a file that
    /// changed on disk since the engine last read or wrote it, found when the
    /// engine writes over it.
    func test_aFileThatChangedBeforeTheWriteIsKeptInConflicts() throws {
        disk.send("edit list 7 title \"A\"")
        disk.settle()
        disk.send("edit list 7 title \"B\"")
        disk.engine.tick()
        let arriving = try disk.edited(.library, "lists/007-a.json", "author", .string("Someone Else"))
        try disk.write(.library, "lists/007-a.json", arriving)
        disk.nextSecond()
        XCTAssertEqual(disk.data(.machine, "conflicts/2026-10-30-100000-007-a.json"), arriving)
        let written = try XCTUnwrap(disk.list(at: "lists/007-b.json"))
        XCTAssertEqual(written.title, "B")
        XCTAssertNotEqual(written.author, "Someone Else", "nothing is merged")
        XCTAssertTrue(disk.log.contains("is kept as conflicts/2026-10-30-100000-007-a.json"), "\(disk.log.recent)")
        let reread = try LoadedRoots.load(libraryRoot: disk.libraryRoot, machineRoot: disk.machineRoot)
        XCTAssertEqual(reread.library.lists.count, library.lists.count, "the loader ignores conflicts/")
    }
}
