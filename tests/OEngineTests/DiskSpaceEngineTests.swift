import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §7 — a low disk, a full disk and the `saving` topic. Spec 9 §10, A
/// low or full disk: "Under 1 GB free, automatic snapshots and the black
/// box's tick and present lines pause and everything else is written. After
/// a write fails, `state/last.json` is removed, the logs go to memory and
/// come back in order with any loss noted, snapshots pause, `system snapshot`
/// and the restore commands are `diskFull`, and edits apply; when a retried
/// write succeeds, the documents and the last state are written. A stop on a
/// full disk names what it couldn't write in its answer. The `saving` topic
/// is sent on subscribe and reports each change." Free space and the write
/// failures are the disk seam's (§8): no test fills a disk or waits.
final class DiskSpaceEngineTests: XCTestCase {
    static let start = Date(timeIntervalSince1970: 1_793_368_800)   // 2026-10-30T10:00:00-04:00
    static let launch = "2026-10-30-100000"
    static let second = 60   // ticks, at the harness's 60 fps

    var disk: DiskFixture!
    let saving = EventRecorder()
    var library: Library { disk.engine.engine.library }

    override func setUpWithError() throws {
        disk = try DiskFixture(wallClock: Self.start, launch: true)
        disk.settleSaving()
    }

    override func tearDown() {
        disk = nil
    }

    func subscribe() {
        let saving = self.saving
        disk.engine.engine.publisher.subscribe(["saving"]) { saving.record($0) }
    }

    /// Ticks of engine time, then every writer done and a tick that reads what they reported.
    func pass(seconds: Int) {
        disk.engine.tick(count: seconds * Self.second + 2)
        settle()
    }

    func settle() {
        disk.engine.waitForWrites()
        disk.engine.settleLogs()
        disk.engine.settleState()
        disk.engine.waitForSnapshots()
        disk.engine.tick()
        disk.engine.waitForWrites()
        disk.engine.settleLogs()
        disk.engine.settleState()
    }

    @discardableResult
    func run(_ text: String, source: SourceKind = .ui) -> RejectionReason? {
        let before = disk.control.rejections.count
        disk.send(text, source: source)
        disk.engine.tick()
        settle()
        return disk.control.rejections.count > before ? disk.control.rejections.last?.reason : nil
    }

    /// The command log's lines as the file holds them now.
    func lines() -> [LogLine] { disk.commandLog() }

    /// A write fails for want of space: an edit's, on a disk that refuses every write.
    func fill() {
        disk.disk.full = true
        XCTAssertNil(run("edit list 7 title \"Typed On A Full Disk\""))
        XCTAssertTrue(disk.control.diskFull, "the edit's write failed for want of space")
    }

    // MARK: - The saving topic

    /// "sent when a client subscribes and whenever a value changes".
    func test_theSavingTopicIsSentOnSubscribeAndReportsEachChange() throws {
        subscribe()
        XCTAssertEqual(saving.all.count, 1, "on subscribe")
        XCTAssertEqual(saving.all[0]["topic"], .string("saving"))
        XCTAssertEqual(saving.all[0]["unsaved"], .number(0))
        XCTAssertEqual(saving.all[0]["disk"], .string("ok"))
        XCTAssertEqual(saving.all[0]["log"], .string("file"))
        XCTAssertEqual(saving.all[0]["lastSnapshot"], .string(Self.launch))
        XCTAssertEqual(Set(saving.all[0].keys), ["type", "topic", "unsaved", "disk", "log", "lastSnapshot", "seq"])

        // A snapshot.
        disk.clock.now = Self.start.addingTimeInterval(60)
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(saving.all.count, 2)
        XCTAssertEqual(saving.all[1]["lastSnapshot"], .string("2026-10-30-100100"))
        XCTAssertEqual(saving.all[1]["seq"]?.intValue, disk.control.commandLog.lastSeq)

        // An edit written within its second changes nothing the badge reads.
        XCTAssertNil(run("edit list 7 title \"Praise God\""))
        pass(seconds: 2)
        XCTAssertEqual(saving.all.count, 2)

        // Less than 1 GB free, then space again.
        disk.disk.freeBytes = (1 << 30) - 1
        pass(seconds: 2)
        XCTAssertEqual(saving.all.last?["disk"], .string("low"), "the topic warns")
        disk.disk.freeBytes = 1 << 40
        pass(seconds: 2)
        XCTAssertEqual(saving.all.last?["disk"], .string("ok"))
        XCTAssertEqual(saving.all.count, 4)

        // A full disk: a document waits past its second, the logs go to memory.
        fill()
        pass(seconds: 2)
        XCTAssertEqual(saving.all.last?["disk"], .string("full"))
        XCTAssertEqual(saving.all.last?["log"], .string("memory"))
        XCTAssertEqual(saving.all.last?["unsaved"], .number(1))
        // And back.
        disk.disk.full = false
        pass(seconds: 31)
        XCTAssertEqual(saving.all.last?["disk"], .string("ok"))
        XCTAssertEqual(saving.all.last?["log"], .string("file"))
        XCTAssertEqual(saving.all.last?["unsaved"], .number(0))

        // A later subscriber gets the values as they are now.
        let late = EventRecorder()
        disk.engine.engine.publisher.subscribe(["saving"]) { late.record($0) }
        XCTAssertEqual(late.all.count, 1)
        XCTAssertEqual(late.all[0]["lastSnapshot"], .string("2026-10-30-100100"))
    }

    // MARK: - A low disk

    /// "automatic snapshots and the black box's tick and present lines pause ... The minute records go on
    /// in the engine log, and everything else is written as usual."
    func test_underOneGigabyteFreeEverythingElseIsWritten() throws {
        disk.disk.freeBytes = (1 << 30) - 1
        pass(seconds: 2)
        XCTAssertEqual(disk.engine.engine.diskStatus?.low, true)
        XCTAssertEqual(disk.control.diskFull, false)

        XCTAssertNil(run("edit list 7 title \"Praise God\""))
        XCTAssertNil(run("list 42 cue 1", source: .osc))
        pass(seconds: 2)
        XCTAssertEqual(disk.list(at: "lists/007-praise-god.json")?.title, "Praise God", "documents are written")
        XCTAssertTrue(lines().contains { $0.entry?.text == "list 42 cue 1" }, "the command log is written")
        XCTAssertTrue(disk.exists(.machine, "state/last.json"), "the last state is written")
        XCTAssertFalse(disk.engineLog().isEmpty, "the engine log is written")

        // Automatic snapshots pause; one that is asked for is written.
        disk.clock.now = Self.start.addingTimeInterval(60)
        XCTAssertNil(run("playlist \"Sunday\""))
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [Self.launch])
        disk.send("system snapshot")
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [Self.launch, "2026-10-30-100100"])
    }

    /// The black box under 1 GB free: tick and present lines pause, minute records go on; on a full disk it stops.
    func test_theBlackBoxPausesItsTickAndPresentLinesAndStopsOnAFullDisk() throws {
        let folder = disk.machineRoot.appendingPathComponent("blackbox")
        let status = try XCTUnwrap(disk.engine.engine.diskStatus)
        let box = BlackBox(folder: folder, disk: disk.disk.disk)
        box.status = status
        let at = Date(timeIntervalSince1970: 1_793_368_800)
        func written() -> [String] {
            let name = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.first ?? ""
            let text = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                (try? JSONValue.parse(String(line)))?["kind"]?.stringValue
            }
        }
        let present = PresentRecord(output: 1, frame: 1, rePresented: false, latencyNs: 1, completion: nil, dropsSinceStart: 0)
        func minute(_ n: Int) -> MinuteRecord {
            MinuteRecord(minute: n, memoryBytes: 0, decoderSessions: 0, textCacheHitRate: 1, audioUnderruns: 0, watchdogEvents: 0,
                         watchdogRecoveries: 0)
        }
        try box.append(TickRecord(), at: at)
        try box.append(present, at: at)
        XCTAssertEqual(written(), ["tick", "present"])

        disk.disk.freeBytes = (1 << 30) - 1
        status.measure()
        try box.append(TickRecord(), at: at)
        try box.append(present, at: at)
        try box.append(minute(1), at: at)
        XCTAssertEqual(written(), ["tick", "present", "minute"], "tick and present lines pause; the minute record goes on")

        disk.disk.freeBytes = 1 << 40
        status.measure()
        try box.append(TickRecord(), at: at)
        XCTAssertEqual(written(), ["tick", "present", "minute", "tick"])

        // "the black box stops", quietly: its thread asks ten times a second, and nothing is thrown.
        disk.disk.full = true
        XCTAssertNoThrow(try box.append(TickRecord(), at: at), "the write that finds the disk full")
        XCTAssertTrue(status.full)
        XCTAssertNoThrow(try box.append(minute(2), at: at))
        XCTAssertNoThrow(try box.append(TickRecord(), at: at))
        XCTAssertEqual(written(), ["tick", "present", "minute", "tick"])
        disk.disk.full = false
        status.wrote()
        try box.append(TickRecord(), at: at)
        XCTAssertEqual(written().count, 5, "it goes on once the full state has ended")
    }

    // MARK: - A full disk

    /// "When a write fails for want of space: The engine removes `state/last.json` ... The logs go to
    /// memory ... Snapshots aren't written, and `system snapshot` and the restore commands are refused
    /// with `diskFull`. Edits keep applying, and the documents they change wait to be written".
    func test_afterAWriteFailsTheStateFileGoesTheLogsGoToMemoryAndEditsStillApply() throws {
        XCTAssertNil(run("list 42 cue 1", source: .osc))
        pass(seconds: 2)
        XCTAssertTrue(disk.exists(.machine, "state/last.json"))
        let onDisk = disk.commandLogText()

        fill()
        pass(seconds: 2)
        // The state file.
        XCTAssertFalse(disk.exists(.machine, "state/last.json"), "removed, so a stale last state can't come back")
        XCTAssertNil(run("next", source: .osc))
        pass(seconds: 90)
        XCTAssertFalse(disk.exists(.machine, "state/last.json"), "and not written again while the disk is full")
        // The logs.
        XCTAssertEqual(disk.engine.engine.logs?.inMemory, true)
        XCTAssertEqual(disk.commandLogText(), onDisk, "nothing reaches the file")
        XCTAssertTrue(disk.control.commandLog.lines.contains { $0.note?.event == "logToMemory" }, "the note is logged, in memory")
        // Edits.
        XCTAssertEqual(library.list(number: 7)?.title, "Typed On A Full Disk", "the edit applied")
        XCTAssertNil(run("edit list 42 ccli \"1\""), "and edits keep applying")
        XCTAssertEqual(library.list(number: 42)?.ccli, "1")
        XCTAssertEqual(disk.list(at: "lists/007-doxology.json")?.title, "Doxology", "their documents wait")
        XCTAssertEqual(disk.control.unsavedDocuments.count, 2)
        // Snapshots and restores.
        XCTAssertNil(run("playlist \"Sunday\""))
        disk.settleSaving()
        XCTAssertEqual(disk.snapshotIDs, [Self.launch], "automatic snapshots aren't written")
        XCTAssertEqual(run("system snapshot"), .diskFull)
        XCTAssertEqual(run("system restore snapshot \"\(Self.launch)\""), .diskFull)
        XCTAssertEqual(run("system restore list 42 version 16"), .diskFull)
        // "Output is untouched": the cue is still on air.
        XCTAssertNotEqual(disk.engine.state.channels[2]?.content, .empty)
    }

    /// "Every 30 seconds the engine tries the waiting writes again. When one succeeds, the full state
    /// ends: the waiting documents and `last.json` are written, the logs go back to their files in order,
    /// and `logToFile` notes any lines lost."
    func test_whenARetriedWriteSucceedsEverythingIsWrittenAndTheLogsComeBackInOrder() throws {
        XCTAssertNil(run("list 42 cue 1", source: .osc))
        pass(seconds: 2)
        fill()
        XCTAssertNil(run("channel 1 lock", source: .osc))
        pass(seconds: 2)
        let attempts = disk.disk.writes.count

        // Still full at the first try.
        pass(seconds: 31)
        XCTAssertTrue(disk.control.diskFull)
        XCTAssertEqual(disk.disk.writes.count, attempts, "nothing could be written")
        XCTAssertNil(disk.list(at: "lists/007-typed-on-a-full-disk.json"))

        disk.disk.full = false
        pass(seconds: 15)
        XCTAssertTrue(disk.control.diskFull, "between tries the engine doesn't know yet")
        pass(seconds: 20)
        XCTAssertFalse(disk.control.diskFull, "a retried write succeeded: the full state ends")
        pass(seconds: 2)

        XCTAssertEqual(disk.list(at: "lists/007-typed-on-a-full-disk.json")?.title, "Typed On A Full Disk", "the waiting document")
        XCTAssertTrue(disk.control.unsavedDocuments.isEmpty)
        XCTAssertTrue(disk.exists(.machine, "state/last.json"), "the last state")
        XCTAssertEqual(disk.engine.engine.logs?.inMemory, false)

        // The log's lines are all there, in order, the notes of the full disk among them.
        let all = lines()
        XCTAssertEqual(all.map(\.seq), Array(1...all.count), "in order, none missing")
        let events = all.compactMap(\.note?.event)
        XCTAssertEqual(events.filter { $0 == "logToMemory" || $0 == "logToFile" }, ["logToMemory", "logToFile"])
        let texts = all.compactMap(\.entry?.text)
        XCTAssertTrue(texts.contains("edit list 7 title \"Typed On A Full Disk\""))
        XCTAssertTrue(texts.contains("channel 1 lock"))
        let toMemory = try XCTUnwrap(all.first { $0.note?.event == "logToMemory" }?.note)
        let toFile = try XCTUnwrap(all.first { $0.note?.event == "logToFile" }?.note)
        XCTAssertEqual(toMemory.source, CommandSource(kind: .engine))
        XCTAssertEqual(toMemory.note["lost"], .number(0))
        XCTAssertEqual(toFile.note["lost"], .number(0), "nothing was lost: it all fitted")
        XCTAssertLessThan(toMemory.seq, toFile.seq)
    }

    /// "the command log up to 64 MB of lines ... `logToFile` notes any lines lost": past its limit the log
    /// drops its oldest lines (the plan's reading), and the note says how many.
    func test_linesPastTheMemoryLimitAreLostOldestFirstAndTheNoteCountsThem() throws {
        disk = try DiskFixture(wallClock: Self.start)
        disk.launch(logMemory: (commands: 2_000, engine: 200))
        disk.settleSaving()
        let before = lines().count
        fill()
        for k in 0..<40 {
            disk.send("popup 1 set \"line \(k)\"", source: .osc)
            disk.engine.tick()
        }
        settle()
        disk.disk.full = false
        pass(seconds: 35)
        pass(seconds: 2)

        let all = lines()
        let note = try XCTUnwrap(all.last { $0.note?.event == "logToFile" }?.note)
        let lost = try XCTUnwrap(note.note["lost"]?.intValue)
        XCTAssertGreaterThan(lost, 0)
        // The lines that reached the file are in order, and the newest are among them.
        XCTAssertEqual(all.map(\.seq), all.map(\.seq).sorted())
        XCTAssertTrue(all.contains { $0.entry?.text == "popup 1 set \"line 39\"" }, "the newest lines were kept")
        XCTAssertFalse(all.contains { $0.entry?.text == "popup 1 set \"line 0\"" }, "the oldest went")
        // What is missing from the command log's file is what the note counts, less the engine log's share.
        let missing = (all.last?.seq ?? 0) - all.count
        XCTAssertGreaterThan(missing, 0)
        XCTAssertLessThanOrEqual(missing, lost)
        XCTAssertGreaterThanOrEqual(all.count, before)
    }

    /// "When the engine stops on request, it tries once more. Documents it still can't write are named in
    /// its answer to the request that stopped it and in the engine's unified log".
    func test_aStopOnAFullDiskNamesWhatItCouldNotWrite() throws {
        fill()
        let report = disk.engine.stop()
        XCTAssertEqual(report.unsaved, ["library/lists/007-doxology.json"], "by its root and where its file still is")
        XCTAssertTrue(disk.log.contains("not written when the engine stopped: library/lists/007-doxology.json"))
        XCTAssertFalse(disk.exists(.machine, "state/last.json"), "no last state on a disk that couldn't take one")
        XCTAssertEqual(disk.list(at: "lists/007-doxology.json")?.title, "Doxology")

        // The next launch finds no last state, and the edit that was never written isn't there.
        disk.disk.full = false
        let next = try DiskFixture(continuing: disk, launch: false)
        XCTAssertEqual(next.launch().previous, "none")
        XCTAssertEqual(next.engine.engine.library.list(number: 7)?.title, "Doxology")
    }

    /// A stop that finds space again writes what waited, and ends cleanly.
    func test_aStopWithSpaceAgainWritesWhatWaited() throws {
        fill()
        disk.disk.full = false
        let report = disk.engine.stop()
        XCTAssertEqual(report.unsaved, [])
        XCTAssertEqual(disk.list(at: "lists/007-typed-on-a-full-disk.json")?.title, "Typed On A Full Disk")
        XCTAssertTrue(disk.exists(.machine, "state/last.json"))
        XCTAssertTrue(lines().contains { $0.note?.event == "stop" }, "the logs went back to their files first")
    }
}
