import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §3 — snapshots in the engine: what one holds, the file, when one is
/// taken, and `system snapshot`. Spec 9 §10, Snapshots: "The zip holds
/// exactly the documents §3 lists, unwritten edits included, under
/// `library/` and `machine/`, with the manifest and its folders; it opens
/// with `unzip`. One is taken at launch before the startup macro, on a
/// playlist load, on the ten-minute timer when something changed and not when
/// nothing did, on `system snapshot` (always, its result naming the id once
/// the file is complete) ... Two in one second get `-2`. A half-written zip
/// never shows under its final name. Automatic ones pause under 1 GB free."
/// Each on a temporary copy of the fixture, launched as the engine process
/// launches.
final class SnapshotEngineTests: XCTestCase {
    static let start = Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-30T10:00:00-04:00
    static let hymn = "library/lists/Hymns/042-great-is-thy-faithfulness.json"

    func fixture(startupMacro: Int? = nil, prepare: (URL) throws -> Void = { _ in },
                 configure: @escaping (inout Machine) -> Void = { _ in }) throws -> DiskFixture {
        try DiskFixture(wallClock: Self.start, prepare: prepare, configure: { machine in
            machine.settings.startupMacro = startupMacro
            configure(&machine)
        }, launch: true)
    }

    func list(_ snapshot: Snapshot, _ path: String) throws -> List {
        let data = try XCTUnwrap(snapshot.documents[path], "\(path) isn't in the snapshot")
        guard case .list(let list) = try Loader.document(path: String(path.dropFirst("library/".count)), data: data).body else {
            throw XCTSkip("\(path) isn't a list")
        }
        return list
    }

    func entries(_ disk: DiskFixture) -> [LogEntry] { disk.commandLog().compactMap(\.entry) }

    // MARK: - At launch

    /// "At launch, after the last state and before the startup macro (§4)": the launch's own snapshot,
    /// noted with its id and reason (§2), holding the roots as they loaded.
    func test_oneIsTakenAtLaunchBeforeTheStartupMacro() throws {
        // The fixture's preshow macro, made to edit a list, as the startup macro.
        let disk = try DiskFixture(wallClock: Self.start, prepare: { folder in
            let url = folder.appendingPathComponent("machine/macros/002-preshow.json")
            guard case .object(var members) = try JSONValue.parse(try Data(contentsOf: url)) else { return }
            members["commands"] = .array([.object(["cmd": .string("edit.set"), "object": .string("list"), "list": .number(7),
                                                    "path": .string("title"), "value": .string("Changed By The Startup Macro")])])
            try JSONCanonical.data(.object(members)).write(to: url)
        }, configure: { $0.settings.startupMacro = 2 }, launch: true)
        disk.settleSaving()

        XCTAssertEqual(disk.engine.engine.library.list(number: 7)?.title, "Changed By The Startup Macro", "the macro ran")
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000"], "the local date and time to the second")
        let snapshot = try disk.snapshot("2026-10-30-100000")
        XCTAssertEqual(snapshot.manifest.reason, "launch")
        XCTAssertEqual(try list(snapshot, "library/lists/007-doxology.json").title, "Doxology", "taken before the macro's edit")

        let note = try XCTUnwrap(disk.notes("snapshot").first)
        XCTAssertEqual(note.note["id"], .string("2026-10-30-100000"))
        XCTAssertEqual(note.note["reason"], .string("launch"))
        XCTAssertEqual(note.source, CommandSource(kind: .engine))
        // In the log: start, the snapshot's note, then the macro.
        let lines = disk.commandLog()
        let macro = try XCTUnwrap(lines.firstIndex { $0.entry?.source.kind == .startup })
        XCTAssertLessThan(try XCTUnwrap(lines.firstIndex { $0.note?.event == "snapshot" }), macro)
    }

    // MARK: - What one holds

    /// "A snapshot is one zip file holding the documents of both roots, as the engine holds them at that
    /// moment, unwritten edits included ... with a manifest"; "It uses deflate, so the Finder and `unzip` open it."
    func test_theZipHoldsTheDocumentsOfBothRootsWithUnwrittenEditsAndOpensWithUnzip() throws {
        let disk = try fixture()
        disk.settleSaving()
        let before = try XCTUnwrap(disk.engine.engine.library.list(number: 42)).version
        let seq = disk.control.commandLog.lastSeq
        // The edit and the snapshot land on one tick: the snapshot is copied before the edit's write.
        disk.send("edit list 42 title \"Edited And Not Yet Written\"")
        disk.send("system snapshot")
        disk.clock.now = Self.start.addingTimeInterval(5)
        disk.settleSaving()

        let id = try XCTUnwrap(disk.snapshotIDs.last)
        XCTAssertEqual(id, "2026-10-30-100005")
        let snapshot = try disk.snapshot(id)
        XCTAssertEqual(Set(snapshot.documents.keys), [
            "library/audio-transitions.json", "library/channels.json", "library/grades.json", "library/library.json",
            "library/lists/007-doxology.json", Self.hymn, "library/macros/001-welcome.json", "library/media-index.json",
            "library/presets/001-default.json", "library/presets/002-clock.json", "library/presets/003-lower-third.json",
            "library/presets/004-credits.json", "library/text-styles.json", "library/transitions.json",
            "machine/audio-outputs.json", "machine/clocks.json", "machine/inputs.json", "machine/keys.json",
            "machine/lists-local/042-great-is-thy-faithfulness-manheim.json", "machine/machine.json",
            "machine/macros/002-preshow.json", "machine/media-local.json", "machine/outputs.json",
            "machine/playlists/sunday-2026-11-01.json", "machine/playlists/sunday-night.json", "machine/playlists/sunday.json",
            "machine/stacks.json",
        ], "no media, logs, snapshots, thumbnails, versions, conflicts or last state")
        let held = try list(snapshot, Self.hymn)
        XCTAssertEqual(held.title, "Edited And Not Yet Written")
        XCTAssertEqual(held.version, before, "as the engine held it, before its write raised the version")
        XCTAssertEqual(disk.list(at: "lists/Hymns/042-edited-and-not-yet-written.json")?.version, before + 1, "the file, written since")

        let manifest = snapshot.manifest
        XCTAssertEqual(manifest.id, id)
        XCTAssertEqual(manifest.reason, "command")
        XCTAssertEqual(manifest.takenAt, "2026-10-30T10:00:05.000-04:00")
        XCTAssertEqual(manifest.machine, "7a7a0000-0000-4000-8000-000000000001")
        XCTAssertEqual(manifest.library, disk.engine.engine.library.info.uuid.uuidString.lowercased())
        XCTAssertEqual(manifest.campus, disk.engine.engine.machine.settings.campusName)
        XCTAssertEqual(manifest.run, disk.engine.engine.run.uuidString.lowercased())
        XCTAssertEqual(manifest.seq, seq + 1, "the last command logged before it: the edit")
        XCTAssertEqual(manifest.folders, ["Christmas", "Hymns"], "an empty folder is listed")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", disk.snapshotsFolder.appendingPathComponent(id + ".zip").path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "unzip tests every entry")
    }

    // MARK: - system snapshot

    /// "`system snapshot` always writes one; its result arrives once the file is complete and names it".
    func test_systemSnapshotAlwaysWritesOneAndIsLoggedOnceTheFileIsComplete() throws {
        let disk = try fixture()
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 1, "the launch's")

        disk.clock.now = Self.start.addingTimeInterval(60)
        disk.send("system snapshot", source: .ui)
        disk.engine.tick()
        XCTAssertTrue(entries(disk).filter { $0.command == .systemSnapshot }.isEmpty, "not logged before its file is complete")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000", "2026-10-30-100100"], "nothing had changed, and it is written all the same")
        let line = try XCTUnwrap(entries(disk).last { $0.command == .systemSnapshot })
        XCTAssertEqual(line.result, .ok)
        XCTAssertEqual(line.kind, .runtime)
        XCTAssertEqual(line.source.kind, .ui)
        XCTAssertEqual(disk.control.lastSnapshot, "2026-10-30-100100")
        XCTAssertEqual(disk.notes("snapshot").count, 1, "only automatic snapshots are noted (Spec 9 §2)")
    }

    /// Its result names the id (Spec 9 §3: `"snapshot": "2026-11-08-085959"`).
    func test_itsResultNamesTheSnapshot() throws {
        let disk = try fixture()
        disk.settleSaving()
        disk.clock.now = Self.start.addingTimeInterval(60)
        disk.send("system snapshot")
        disk.engine.tick()
        disk.engine.waitForSnapshots()
        disk.engine.tick()
        let executed = try XCTUnwrap(disk.engine.lastExecuted.first { $0.command == .systemSnapshot })
        XCTAssertEqual(executed.result, .ok)
        XCTAssertEqual(executed.snapshot, "2026-10-30-100100")
    }

    /// Adam's answer of 2026-11-14 — "A direct group holding it waits whole; held by a cue, macro or key,
    /// the rest runs at once. It never holds edits back."
    func test_aDirectGroupWaitsWholeAHeldOneRunsTheRestAtOnceAndEditsAreNeverHeldBack() throws {
        let disk = try fixture()
        disk.settleSaving()

        disk.engine.send(group: ["system snapshot", "channel 1 lock"], source: .ui)
        disk.send("edit list 7 title \"Not Held Back\"")
        disk.engine.tick()
        XCTAssertNotEqual(disk.engine.state.channels[1]?.lock, true, "the group waits whole")
        XCTAssertEqual(disk.engine.engine.library.list(number: 7)?.title, "Not Held Back", "an edit sent meanwhile lands at once")
        disk.settleSaving()
        XCTAssertEqual(disk.engine.state.channels[1]?.lock, true, "and applies with its file")
        let group = try XCTUnwrap(entries(disk).last { $0.command == .systemSnapshot }?.group)
        XCTAssertEqual(entries(disk).filter { $0.group == group }.map(\.text), ["system snapshot", "channel 1 lock"])

        disk.engine.send(group: ["system snapshot", "channel 2 lock"], source: .key)
        disk.engine.tick()
        XCTAssertEqual(disk.engine.state.channels[2]?.lock, true, "the rest runs at once")
        let before = entries(disk).filter { $0.command == .systemSnapshot }.count
        disk.settleSaving()
        let held = entries(disk).filter { $0.command == .systemSnapshot }
        XCTAssertEqual(held.count, before + 1, "its line follows its file")
        XCTAssertEqual(held.last?.source.kind, .key)
        XCTAssertEqual(held.last?.result, .ok)
    }

    /// "The id is the local date and time to the second ... with `-2` and on added for a second snapshot in the same second."
    func test_twoInOneSecondGetDashTwo() throws {
        let disk = try fixture()
        disk.settleSaving()
        disk.clock.now = Self.start.addingTimeInterval(30.2)
        disk.send("system snapshot")
        disk.clock.now = Self.start.addingTimeInterval(30.7)
        disk.send("system snapshot")
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000", "2026-10-30-100030", "2026-10-30-100030-2", "2026-10-30-100030-3"])
        XCTAssertEqual(try disk.snapshot("2026-10-30-100030-2").manifest.id, "2026-10-30-100030-2", "the manifest names the file's id")
    }

    /// "written ... under a hidden name renamed when complete (Spec 1 §5)": a write that fails leaves no
    /// zip, the command is rejected, and a leftover with a hidden name is never taken for a snapshot.
    func test_aHalfWrittenZipNeverShowsUnderItsFinalName() throws {
        let disk = try fixture()
        disk.settleSaving()
        // What a crash mid-write leaves: the temporary file, synced and not yet renamed.
        let leftover = disk.snapshotsFolder.appendingPathComponent(".2026-10-30-100100.zip.1a2b3c4d.tmp")
        try Data("half a zip".utf8).write(to: leftover)
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000"])
        let listed = disk.engine.engine.publisher.query(.object(["id": .number(1), "type": .string("query"), "what": .string("snapshots")]))
        XCTAssertEqual(listed["snapshots"]?.arrayValue?.count, 1)

        disk.disk.full = true
        disk.clock.now = Self.start.addingTimeInterval(120)
        let rejected = disk.control.rejections.count
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000"], "nothing under a final name")
        XCTAssertEqual(disk.control.rejections.count, rejected + 1, "a failed write rejects it")
        XCTAssertEqual(disk.control.rejections.last?.reason, .diskFull)
        XCTAssertTrue(entries(disk).filter { $0.command == .systemSnapshot }.isEmpty, "a rejected command isn't logged")

        // Its writes go through the atomic writer: every snapshot that was written arrived whole, under its name.
        disk.disk.full = false
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.disk.writes.filter { $0.name.hasSuffix(".zip") }.map(\.name), ["2026-10-30-100000.zip", "2026-10-30-100200.zip"])
        XCTAssertNoThrow(try disk.snapshot("2026-10-30-100200"))
    }

    // MARK: - A playlist load

    /// "When a playlist is loaded (`playlist "TITLE"`, Spec 7 §3), the v1 stand-in for a service start";
    /// "An automatic snapshot ... whose documents equal the newest snapshot's isn't written".
    func test_oneIsTakenOnAPlaylistLoadWhenSomethingChanged() throws {
        let disk = try fixture()
        disk.settleSaving()
        disk.clock.now = Self.start.addingTimeInterval(300)
        disk.send("playlist \"Sunday\"")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000"], "nothing changed since the launch's, so none is written")
        XCTAssertEqual(disk.notes("snapshot").count, 1)

        disk.send("edit list 7 title \"Praise God\"")
        disk.settle()
        disk.clock.now = Self.start.addingTimeInterval(600)
        disk.send("playlist \"Sunday Night\"")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100000", "2026-10-30-101000"])
        let snapshot = try disk.snapshot("2026-10-30-101000")
        XCTAssertEqual(snapshot.manifest.reason, "playlist")
        XCTAssertEqual(try list(snapshot, "library/lists/007-praise-god.json").title, "Praise God")
        XCTAssertEqual(disk.notes("snapshot").last?.note["reason"], .string("playlist"))
        XCTAssertEqual(disk.notes("snapshot").last?.note["id"], .string("2026-10-30-101000"))
    }

    // MARK: - The timer

    /// "Every ten minutes (choice G-4)", on engine time (the plan's reading).
    func test_theTimerIsTenMinutesOfEngineTime() throws {
        let disk = try fixture()
        disk.settleSaving()
        XCTAssertEqual(disk.control.snapshotInterval, 600_000_000_000)
        disk.send("edit list 7 title \"Changed\"")
        disk.settle()
        // Ten minutes of ticks at 60 a second, less a few seconds: nothing yet.
        disk.engine.tick(count: 600 * 60 - 300)
        disk.engine.waitForSnapshots()
        disk.engine.tick()
        XCTAssertEqual(disk.snapshotIDs.count, 1)
        disk.engine.tick(count: 320)
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 2)
        XCTAssertEqual(try disk.snapshot(try XCTUnwrap(disk.snapshotIDs.last)).manifest.reason, "timer")
        XCTAssertEqual(disk.notes("snapshot").last?.note["reason"], .string("timer"))
    }

    /// "so the ten-minute timer writes one only when something has changed": from any source (choice G-4).
    func test_theTimerWritesOneWhenSomethingChangedAndNotWhenNothingDid() throws {
        let disk = try fixture()
        disk.settleSaving()
        // The same rule on a shorter interval, so the test doesn't run an hour of ticks.
        disk.control.snapshotInterval = 2_000_000_000
        disk.control.nextTimerSnapshot = disk.engine.clock.now().advanced(by: 2_000_000_000)

        disk.engine.tick(count: 5 * 60)
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 1, "nothing changed: none, however many intervals pass")

        disk.clock.now = Self.start.addingTimeInterval(700)
        disk.send("edit list 7 title \"Changed\"", source: .osc)
        disk.engine.tick(count: 150)
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 2, "something changed: one")
        XCTAssertEqual(try disk.snapshot(try XCTUnwrap(disk.snapshotIDs.last)).manifest.reason, "timer")

        disk.clock.now = Self.start.addingTimeInterval(800)
        disk.engine.tick(count: 5 * 60)
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 2, "and no more until something changes again")
    }

    // MARK: - A low disk (Spec 9 §7)

    /// "When free space on the machine root's volume falls under 1 GB ..., automatic snapshots ... pause";
    /// `system snapshot` still writes one.
    func test_automaticOnesPauseUnderOneGigabyteFree() throws {
        let disk = try DiskFixture(wallClock: Self.start)
        disk.disk.freeBytes = (1 << 30) - 1
        disk.launch()
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [], "no launch snapshot")
        XCTAssertTrue(disk.notes("snapshot").isEmpty)

        disk.send("edit list 7 title \"Changed\"")
        disk.send("playlist \"Sunday\"")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [], "no playlist snapshot")

        disk.clock.now = Self.start.addingTimeInterval(60)
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, ["2026-10-30-100100"], "one that was asked for is written")

        // With space again, the next automatic one is taken.
        disk.disk.freeBytes = 1 << 40
        disk.send("edit list 7 title \"Changed Again\"")
        disk.clock.now = Self.start.addingTimeInterval(120)
        disk.send("playlist \"Sunday Night\"")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.last, "2026-10-30-100200")
    }

    // MARK: - Settings

    /// "`snapshots.cadence` and `snapshots.retention` (Spec 1 §3) have one value each in v1 ... Any other
    /// value is kept as written, read as the v1 one, and reported."
    func test_anotherCadenceIsReadAsTheV1OneAndReported() throws {
        let disk = try fixture(configure: { machine in
            machine.settings.snapshots.cadence = "hourly"
            machine.settings.snapshots.retention = "forever"
        })
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs.count, 1, "the v1 cadence: one at launch")
        XCTAssertTrue(disk.log.contains("snapshots.cadence \"hourly\" is read as launchAndService"))
        XCTAssertTrue(disk.log.contains("snapshots.retention \"forever\" is read as 7d-daily-weekly"))
        XCTAssertEqual(disk.engine.engine.machine.settings.snapshots.cadence, "hourly", "kept as written")
    }

    /// An engine that was only built, with no machine root on disk, writes no snapshot and says so.
    func test_anEngineWithNoRootsOnDiskRefusesSystemSnapshot() throws {
        let disk = try DiskFixture()
        let rejected = disk.control.rejections.count
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.control.rejections.count, rejected + 1)
        XCTAssertEqual(disk.control.rejections.last?.reason, .conflict)
        XCTAssertFalse(disk.exists(.machine, "snapshots"))
    }
}
