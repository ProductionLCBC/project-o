import Foundation
import XCTest
@testable import OEngine

/// Spec 10 §2, "Starting" — "The app opens `machine/logs/engine-console.log`
/// for appending as the engine's standard output and error, so a failure
/// before the engine's own logger starts can still be read, and the engine
/// trims the file in place to its last 10 MB at launch."
final class ConsoleLogTests: XCTestCase {
    var folder: URL!
    var url: URL { folder.appendingPathComponent("logs/engine-console.log") }

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-console-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("logs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func inode() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    func lines(_ range: ClosedRange<Int>) -> String {
        range.map { "line \($0) of the engine's console\n" }.joined()
    }

    func test_theConsoleLogIsInTheMachineRootsLogs() {
        XCTAssertEqual(ConsoleLog.url(machineRoot: folder).path, url.path)
        XCTAssertEqual(ConsoleLog.limit, 10 * 1024 * 1024)
    }

    func test_aLogWithinTheLimitIsLeftAlone() throws {
        let text = lines(1...3)
        try Data(text.utf8).write(to: url)
        XCTAssertFalse(ConsoleLog.trim(url, to: text.utf8.count))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func test_aLongLogIsTrimmedInPlaceToItsLastLines() throws {
        try Data(lines(1...100).utf8).write(to: url)
        let before = try inode()
        let limit = lines(91...100).utf8.count + 5   // room for ten lines and a piece of the one before
        XCTAssertTrue(ConsoleLog.trim(url, to: limit))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), lines(91...100), "its last bytes, from the start of a line")
        XCTAssertEqual(try inode(), before, "in place: the same file, so the handle the app opened is still the log")
    }

    /// The app holds the file open for appending as the engine's standard
    /// output; what the engine prints after the trim must follow the kept lines.
    func test_whatIsPrintedAfterTheTrimFollowsTheKeptLines() throws {
        try Data(lines(1...100).utf8).write(to: url)
        let appending = open(url.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(appending, 0)
        defer { close(appending) }
        XCTAssertTrue(ConsoleLog.trim(url, to: lines(99...100).utf8.count))
        let next = Array("oengine: running\n".utf8)
        XCTAssertEqual(write(appending, next, next.count), next.count)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), lines(99...100) + "oengine: running\n")
    }

    func test_oneLineLongerThanTheLimitKeepsItsLastBytes() throws {
        let long = String(repeating: "x", count: 500)
        try Data(long.utf8).write(to: url)
        XCTAssertTrue(ConsoleLog.trim(url, to: 100))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), String(repeating: "x", count: 100))
    }

    func test_noLogIsNoError() {
        XCTAssertFalse(ConsoleLog.trim(url))
    }
}
