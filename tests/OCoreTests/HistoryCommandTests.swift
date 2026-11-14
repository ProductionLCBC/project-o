import Foundation
import XCTest
@testable import OCore

/// Spec 5 §8 — "Runtime undo and the history view are v1.5, so in v1 `undo`
/// and `redo` (Spec 2 §3) always mean edit undo, and `history jump N` is
/// rejected with `notInV1`." Spec 9 §5 — "`history jump N` is refused with
/// `notInV1`."
final class HistoryCommandTests: XCTestCase {
    typealias X = Fixtures

    func run(_ commands: [Command], source: SourceKind) -> Result<RunOutcome, Rejection> {
        CommandRunner.run(CommandGroup(id: GroupID("g-1"), source: CommandSource(kind: source), commands: commands),
                          state: X.fresh(), context: X.context(frame: 10, source: source))
    }

    /// Sent directly, the group is rejected and nothing in it runs.
    func test_historyJumpSentDirectlyIsRejectedWithNotInV1() {
        for source: SourceKind in [.ui, .api, .osc, .commandbar] {
            switch run([.channelLock(channel: .number(1), locked: true), .historyJump(3)], source: source) {
            case .success(let outcome):
                XCTFail("\(source): ran \(outcome.executed.map(\.command))")
            case .failure(let rejection):
                XCTAssertEqual(rejection.reason, .notInV1, "\(source)")
                XCTAssertEqual(rejection.index, 1, "\(source)")
            }
        }
    }

    /// The plan's reading of Spec 2 §3 and Spec 5 §2 — held by a cue, macro,
    /// key binding or scheduler entry it is `blocked` with the reason, "and
    /// the rest of the group runs".
    func test_historyJumpHeldIsBlockedAndTheRestRuns() throws {
        for source: SourceKind in [.key, .scheduler, .startup] {
            let outcome = try run([.historyJump(3), .channelLock(channel: .number(1), locked: true)], source: source).get()
            XCTAssertEqual(outcome.executed.map(\.result), [.blocked, .ok], "\(source)")
            XCTAssertEqual(outcome.executed.first?.refusal?.reason, .notInV1, "\(source)")
            XCTAssertEqual(outcome.state.channels[1]?.lock, true, "\(source)")
        }
    }
}
