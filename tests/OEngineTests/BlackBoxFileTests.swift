import Foundation
import XCTest
import OCore
@testable import OEngine

/// Spec 9 §2 — the black box on disk: "`machine/blackbox/blackbox-YYYY-MM-DD-HH.jsonl`
/// | Every tick, present and minute record (Spec 4 §13) | By UTC hour ... It
/// has its own folder and a file an hour so the cap holds within a day and a
/// sync tool sending `logs/` upward doesn't carry it." Spec 9 §8 — "The black
/// box in `machine/blackbox/` in the engine's normal runs, a file an hour,
/// with the same line repair and sync, the cap trimmed within the day ...;
/// the soak keeps `--blackbox`, and its reader reads the hourly files."
final class BlackBoxFileTests: XCTestCase {
    var folder: URL!
    let disk = TestDisk()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-box-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func utc(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Double = 0) -> Date {
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                  year: 2026, month: 11, day: day, hour: hour, minute: minute).date!
        return base.addingTimeInterval(second)
    }

    func tick(_ frame: Int) -> TickRecord {
        var record = TickRecord()
        record.frame = Int64(frame)
        return record
    }

    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func text(_ name: String) -> String {
        (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Spec 9 §10 — "The black box lands in `machine/blackbox/`, a file an hour."
    func test_aFileAnHourByTheUTCHour() throws {
        let box = BlackBox(folder: folder, disk: disk.disk)
        try box.append(tick(1), at: utc(8, 13, 59, 59.9))
        try box.append(tick(2), at: utc(8, 14, 0, 0.1))
        try box.append(PresentRecord(output: 1, frame: 2, rePresented: false, latencyNs: 1, completion: nil, dropsSinceStart: 0), at: utc(8, 14, 30))
        try box.append(tick(3), at: utc(9, 0, 0, 1))
        XCTAssertEqual(files, ["blackbox-2026-11-08-13.jsonl", "blackbox-2026-11-08-14.jsonl", "blackbox-2026-11-09-00.jsonl"])
        XCTAssertEqual(text("blackbox-2026-11-08-13.jsonl").split(separator: "\n").count, 1)
        XCTAssertEqual(text("blackbox-2026-11-08-14.jsonl").split(separator: "\n").count, 2)
        XCTAssertTrue(text("blackbox-2026-11-08-14.jsonl").hasSuffix("\n"))
    }

    /// Spec 9 §7 — "512 MB in all, oldest first; only the current hour's file
    /// is spared, so the cap holds within a day".
    func test_theCapTrimsTheOldestHoursAndSparesOnlyTheCurrentOne() throws {
        let line = BlackBox.line(for: tick(1)).utf8.count
        // Room for about two and a half hours of ten lines each.
        let box = BlackBox(folder: folder, maximumBytes: line * 25, disk: disk.disk)
        for hour in 0..<6 {
            for k in 0..<10 { try box.append(tick(hour * 10 + k), at: utc(8, hour, k)) }
        }
        XCTAssertEqual(files, ["blackbox-2026-11-08-04.jsonl", "blackbox-2026-11-08-05.jsonl"], "within the day, the oldest hours went")
        let total = files.reduce(0) { $0 + text($1).utf8.count }
        XCTAssertLessThanOrEqual(total, line * 25)

        // One hour alone past the cap is still spared: it is the current one.
        let small = BlackBox(folder: folder.appendingPathComponent("small"), maximumBytes: line * 3, disk: disk.disk)
        for k in 0..<10 { try small.append(tick(k), at: utc(8, 7, k)) }
        let kept = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("small").path)
        XCTAssertEqual(kept, ["blackbox-2026-11-08-07.jsonl"])
    }

    /// Spec 9 §8 — "with the same line repair": a partial last line is ended first.
    func test_aPartialLastLineIsEndedOnOpening() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let whole = BlackBox.line(for: tick(1))
        try Data((whole + "{\"frame\":2,\"kind\":\"ti").utf8).write(to: folder.appendingPathComponent("blackbox-2026-11-08-13.jsonl"))
        let box = BlackBox(folder: folder, disk: disk.disk)
        try box.append(tick(3), at: utc(8, 13, 30))
        let written = text("blackbox-2026-11-08-13.jsonl")
        XCTAssertEqual(written, whole + "{\"frame\":2,\"kind\":\"ti\n" + BlackBox.line(for: tick(3)))
        var run = SoakRun(tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        for line in written.split(separator: "\n") { BlackBoxReader.add(line: String(line), to: &run) }
        XCTAssertEqual(run.ticks.map(\.frame), [1, 3], "the reader skips the fragment")
    }

    /// Spec 9 §8 — "and sync": the file is synced once a second while lines
    /// arrive, by the times the recorder gives.
    func test_theFileIsSyncedOnceASecond() throws {
        let box = BlackBox(folder: folder, disk: disk.disk)
        for k in 0..<25 { try box.append(tick(k), at: utc(8, 13, 0, Double(k) * 0.1)) }
        XCTAssertEqual(disk.syncs(of: "blackbox-2026-11-08-13.jsonl"), 2, "two and a half seconds of lines")
    }

    /// Spec 9 §8 — "its reader reads the hourly files", oldest first.
    func test_theReaderReadsTheHourlyFilesInOrder() throws {
        let box = BlackBox(folder: folder, disk: disk.disk)
        for hour in [22, 23] {
            for k in 0..<3 { try box.append(tick(hour * 100 + k), at: utc(8, hour, k)) }
        }
        for k in 0..<3 { try box.append(tick(10_000 + k), at: utc(9, 0, k)) }
        let run = try BlackBoxReader.load(folder: folder, tickNanoseconds: 16_666_667, sdiOutputs: [], displayOutputs: [1])
        XCTAssertEqual(run.ticks.map(\.frame), [2200, 2201, 2202, 2300, 2301, 2302, 10_000, 10_001, 10_002])
    }

    /// Spec 9 §8 — "The black box in `machine/blackbox/` in the engine's
    /// normal runs ...; the soak keeps `--blackbox`" and its own folder.
    func test_runWritesInTheMachineRootAndSoakKeepsItsFolder() {
        let machine = URL(fileURLWithPath: "/Users/Shared/Project O/machine")
        let named = URL(fileURLWithPath: "/tmp/soak-out")
        let work = URL(fileURLWithPath: "/Users/dev/project-o")
        XCTAssertEqual(OEngineCommandLine.blackBoxFolder(named: nil, machineRoot: machine, soak: false, stamp: "2026-11-08-085959", working: work).path,
                       "/Users/Shared/Project O/machine/blackbox")
        XCTAssertEqual(OEngineCommandLine.blackBoxFolder(named: named, machineRoot: machine, soak: false, stamp: "2026-11-08-085959", working: work).path,
                       "/tmp/soak-out", "a folder the command line names wins")
        XCTAssertEqual(OEngineCommandLine.blackBoxFolder(named: nil, machineRoot: machine, soak: true, stamp: "2026-11-08-085959", working: work).path,
                       "/Users/dev/project-o/tests/soak-output/2026-11-08-085959")
        XCTAssertEqual(OEngineCommandLine.blackBoxFolder(named: named, machineRoot: machine, soak: true, stamp: "2026-11-08-085959", working: work).path,
                       "/tmp/soak-out")
    }
}
