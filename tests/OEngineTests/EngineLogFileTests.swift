import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §2 — the engine log on disk: "`machine/logs/engine-YYYY-MM-DD.jsonl`
/// | What the engine's log writes, Spec 4 §12's detail ...; a copy of each
/// minute record (Spec 4 §13); and the media index changes of an import or
/// the walk, by id (Spec 8 §2) | By local day". "Engine log lines each carry
/// `ts` and the run's uuid ... `kind` says what follows: `start` (opening each
/// run's part of the file, with the app version and the machine), `log` (with
/// `level`, `category` and `message`, as the engine's log has them), `minute`
/// (the minute record's fields) or `media` (an index change, with its
/// operation and ids)." Spec 9 §8 — "`EngineLog` also writes its lines to the
/// engine log." Spec 9 §10, The logs.
final class EngineLogFileTests: XCTestCase {
    func run(of disk: DiskFixture) -> JSONValue { .string(disk.engine.engine.run.uuidString.lowercased()) }

    /// Spec 9 §10 — "The engine log gets the engine's log lines ... each with
    /// `ts` and the run".
    func test_theEngineLogGetsTheEnginesLogLinesEachWithTsAndTheRun() throws {
        let disk = try DiskFixture(launch: true)
        disk.log.warning("the projector is warm")
        disk.log.error("could not open the organ")
        disk.log.severe("the organ is on fire")

        XCTAssertEqual(disk.logFiles.filter { $0.hasPrefix("engine-") }, ["engine-2026-10-30.jsonl"])
        let lines = disk.engineLog()
        XCTAssertTrue(lines.allSatisfy { $0["run"] == run(of: disk) }, "every line names the run")
        XCTAssertTrue(lines.allSatisfy { $0["ts"]?.stringValue?.hasPrefix("2026-10-30T10:00:00.000-04:00") == true })
        // "`start` (opening each run's part of the file, with the app version and the machine)".
        XCTAssertEqual(lines.first?["kind"], .string("start"))
        XCTAssertEqual(lines.first?["app"], .string(OCore.appVersion))
        XCTAssertEqual(lines.first?["machine"], .string("7a7a0000-0000-4000-8000-000000000001"))
        let logged = lines.filter { $0["kind"] == .string("log") }
        let warm = try XCTUnwrap(logged.first { $0["message"] == .string("the projector is warm") })
        XCTAssertEqual(warm["level"], .string("warning"))
        XCTAssertEqual(warm["category"], .string("harness"))
        XCTAssertEqual(Set(warm.keys), ["ts", "run", "kind", "level", "category", "message"])
        XCTAssertEqual(logged.first { $0["message"] == .string("could not open the organ") }?["level"], .string("error"))
        XCTAssertEqual(logged.first { $0["message"] == .string("the organ is on fire") }?["level"], .string("severe"))
        // In the order they were logged.
        let order = logged.compactMap { $0["message"]?.stringValue }
        XCTAssertEqual(order.filter { $0.contains("organ") || $0.contains("projector") },
                       ["the projector is warm", "could not open the organ", "the organ is on fire"])
        // The memory the tests and the watchdog read is as before.
        XCTAssertTrue(disk.log.contains("the projector is warm"))
    }

    /// Spec 9 §8 — what the engine logged before its file opened is written
    /// too, after the run's `start` line, with the time it was logged.
    func test_linesLoggedBeforeTheFileOpenedAreWritten() throws {
        let disk = try DiskFixture()
        disk.log.info("warm-up: 12 channel pipelines")
        XCTAssertTrue(disk.logFiles.isEmpty, "nothing is written before the launch")
        disk.launch()
        disk.log.info("after the launch")
        let lines = disk.engineLog()
        XCTAssertEqual(lines.first?["kind"], .string("start"))
        let messages = lines.compactMap { $0["message"]?.stringValue }
        let before = try XCTUnwrap(messages.firstIndex(of: "warm-up: 12 channel pipelines"))
        let after = try XCTUnwrap(messages.firstIndex(of: "after the launch"))
        XCTAssertLessThan(before, after)
        XCTAssertEqual(messages.filter { $0 == "warm-up: 12 channel pipelines" }.count, 1, "written once")
    }

    /// Spec 9 §10 — "each minute record"; Spec 4 §13 — "with the minute
    /// records copied to the engine log".
    func test_eachMinuteRecordIsCopiedToTheEngineLog() throws {
        let disk = try DiskFixture(launch: true)
        let folder = disk.folder.appendingPathComponent("box")
        let engine = disk.engine.engine
        let recorder = BlackBoxRecorder(box: BlackBox(folder: folder), ticks: MetricsRing(capacity: 16), presents: [],
                                        tickNanoseconds: 16_666_667, sources: BlackBoxRecorder.MinuteSources(decoderSessions: { 2 }),
                                        log: disk.log, onMinute: { record, _ in engine.recordMinute(record) })
        recorder.writeMinute()
        recorder.writeMinute()
        let minutes = disk.engineLog().filter { $0["kind"] == .string("minute") }
        XCTAssertEqual(minutes.count, 2)
        XCTAssertEqual(minutes.map { $0["minute"] }, [.number(0), .number(1)])
        XCTAssertEqual(minutes.first?["decoderSessions"], .number(2))
        XCTAssertNotNil(minutes.first?["footprintBytes"])
        XCTAssertNotNil(minutes.first?["thermalState"])
        XCTAssertTrue(minutes.allSatisfy { $0["run"] == run(of: disk) && $0["ts"] != nil })
        // The black box still has its own.
        let boxed = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(boxed.count, 1)
    }

    /// Spec 9 §10 — "and the walk's index changes by id ...; the command log
    /// gets none of them." Spec 8 §2 — "The engine log records them, by id".
    func test_theWalksIndexChangesAreWrittenByIdAndTheCommandLogGetsNoneOfThem() throws {
        let media = try MediaFixture(launching: true)
        try media.write(.mediaRoot, "backgrounds/new.png", "new picture bytes")
        media.walk()
        let id = MediaFixture.id("new picture bytes")

        let day = media.engine.variables.today()
        media.engine.settleLogs()
        let text = try String(contentsOf: media.machineRoot.appendingPathComponent("logs/engine-\(day).jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").compactMap { (try? JSONValue.parse(String($0)))?.objectValue }
        let changes = lines.filter { $0["kind"] == .string("media") }
        let added = try XCTUnwrap(changes.first { $0["id"] == .string(id) })
        XCTAssertEqual(added["op"], .string("added"))
        XCTAssertEqual(added["index"], .string("library"))
        XCTAssertNotNil(added["ts"])
        XCTAssertEqual(added["run"], .string(media.engine.engine.run.uuidString.lowercased()))
        XCTAssertFalse(added.values.contains { $0.stringValue?.contains("new.png") == true }, "by id, with no path")
        // An index change is written once: as its `media` line, not as a `log` line beside it.
        let worded = lines.filter { $0["kind"] == .string("log") }.compactMap { $0["message"]?.stringValue }
        XCTAssertEqual(worded.filter { $0.hasPrefix("media: added \(id)") }, [])
        // The engine's memory still says it in words.
        XCTAssertTrue(media.engine.log.contains("media: added \(id)"))

        // The command log: the start note and nothing of the walk's.
        let commands = try String(contentsOf: media.machineRoot.appendingPathComponent("logs/commands-\(day).jsonl"), encoding: .utf8)
        XCTAssertFalse(commands.contains(id))
        XCTAssertEqual(LogLine.reading(commands).compactMap(\.note).map(\.event), ["start"])
        XCTAssertTrue(LogLine.reading(commands).compactMap(\.entry).isEmpty)
        // And the engine log has no command.
        XCTAssertFalse(lines.contains { $0["command"] != nil })
    }

    /// A day's lines land in that day's file, as the command log's do.
    func test_theEngineLogSplitsByLocalDay() throws {
        let disk = try DiskFixture(wallClock: try CommandLogFileTests.date("2026-11-08T23:59:59.000-05:00"), launch: true)
        disk.log.info("Sunday's last line")
        disk.clock.now = try CommandLogFileTests.date("2026-11-09T00:00:01.000-05:00")
        disk.log.info("Monday's first line")
        XCTAssertEqual(disk.logFiles.filter { $0.hasPrefix("engine-") }, ["engine-2026-11-08.jsonl", "engine-2026-11-09.jsonl"])
        XCTAssertTrue(disk.engineLog(day: "2026-11-08").contains { $0["message"] == .string("Sunday's last line") })
        XCTAssertEqual(disk.engineLog(day: "2026-11-09").compactMap { $0["message"]?.stringValue }, ["Monday's first line"])
    }
}
