import XCTest
import OCore
@testable import OEngine

/// Spec 9 §2 as corrected 2026-11-27 — "Beside the file, the engine keeps the run's last 500 lines in memory ..., so a
/// soak's memory is flat within its first minutes". Every line still reaches the sink, which writes the file.
final class CommandLogMemoryTests: XCTestCase {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func test_theEngineKeepsTheRunsLast500LinesAndHandsEveryOneOn() {
        XCTAssertEqual(CommandLog.defaultCapacity, 500)
        let log = CommandLog()
        let handed = Count()
        log.attach { lines in handed.add(lines.count) }
        for n in 1...1200 {
            _ = log.note(["n": .number(Double(n))], text: "line \(n)", source: CommandSource(kind: .ui), ts: "2026-11-27T12:00:00.000Z")
        }
        XCTAssertEqual(log.lines.count, 500)
        XCTAssertEqual(log.lines.first?.seq, 701, "the oldest kept is the 700th line on")
        XCTAssertEqual(log.lines.last?.seq, 1200)
        XCTAssertEqual(handed.value, 1200, "every line goes to the file")
    }
}
