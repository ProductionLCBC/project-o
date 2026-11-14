import Foundation
import XCTest
@testable import OCore

/// Spec 9 §4 — "When it comes back (choice G-1). At launch, with
/// `restoreLastState` on, or at a relaunch whatever it says ..., the engine
/// restores the last state when all three hold: its run didn't end cleanly;
/// it was written less than two hours ago, so the run was alive then; and it
/// isn't `restored: true`, which would mean the engine stopped within a
/// minute of putting it back, as it would if the state itself crashed it.
/// Otherwise the launch starts empty, and a `lastStateSkipped` note says why."
/// Spec 9 §2 — `lastStateSkipped`: "`writtenAt`, `reason` (`clean`, `old` or
/// `restoredBefore`)". Spec 9 §10, The last state.
final class LastStateDecisionTests: XCTestCase {
    static let written = "2026-11-08T09:41:07.002-05:00"
    static let writtenMs: Int64 = CivilTime.milliseconds(written) ?? 0
    static let minute: Int64 = 60_000
    static let hour: Int64 = 60 * minute

    func last(clean: Bool? = false, restored: Bool? = false, writtenAt: String? = LastStateDecisionTests.written) -> LastState {
        LastState(writtenAt: writtenAt, run: UUID(), clean: clean, restored: restored, state: ShowState())
    }

    func decide(_ last: LastState?, setting: Bool = true, relaunch: Bool = false, after: Int64 = 20 * minute) -> LastState.Decision {
        LastState.decide(last, restoreLastState: setting, relaunch: relaunch, nowMs: Self.writtenMs + after)
    }

    /// "With the setting on, an unclean end and a state written under two
    /// hours ago, launch restores".
    func test_anUncleanRecentStateComesBackWithTheSettingOn() {
        XCTAssertEqual(decide(last()), .restore)
        XCTAssertEqual(decide(last(), after: 2 * Self.hour - 1), .restore, "less than two hours")
    }

    /// "At a launch that isn't a relaunch, a clean end, a state written over
    /// two hours ago and the setting off each start empty ..., the first two
    /// with `lastStateSkipped` and its reason."
    func test_aCleanEndAnOldStateAndTheSettingOffEachStartEmpty() {
        XCTAssertEqual(decide(last(clean: true)), .skip(.clean))
        XCTAssertEqual(decide(last(), after: 2 * Self.hour), .skip(.old), "two hours is not less than two hours")
        XCTAssertEqual(decide(last(), after: 26 * Self.hour), .skip(.old), "last night's final screen")
        // The setting off, and no relaunch: nothing is considered, and no note is owed.
        XCTAssertEqual(decide(last(), setting: false), .none)
        XCTAssertEqual(decide(last(clean: true), setting: false), .none)
    }

    /// "and it isn't `restored: true` ... A state that crashes the engine is
    /// so restored once at most".
    func test_aStateJustPutBackIsNotPutBackAgain() {
        XCTAssertEqual(decide(last(restored: true), after: 20_000), .skip(.restoredBefore))
        XCTAssertEqual(decide(last(restored: true), setting: false, relaunch: true, after: 20_000), .skip(.restoredBefore))
    }

    /// Spec 10 §2, choice U-14 — "A relaunch puts the last state back under
    /// Spec 9 §4's guards (less than two hours old, and not one just put
    /// back), whatever `restoreLastState` says".
    func test_aRelaunchRestoresWhateverTheSettingSaysUnderTheSameGuards() {
        XCTAssertEqual(decide(last(), setting: false, relaunch: true), .restore)
        XCTAssertEqual(decide(last(), setting: true, relaunch: true), .restore)
        XCTAssertEqual(decide(last(), setting: false, relaunch: true, after: 3 * Self.hour), .skip(.old))
        XCTAssertEqual(decide(last(clean: true), setting: false, relaunch: true), .skip(.clean))
    }

    /// The three conditions in the page's order: the first that fails is the reason.
    func test_theFirstConditionThatFailsIsTheReason() {
        XCTAssertEqual(decide(last(clean: true, restored: true), after: 5 * Self.hour), .skip(.clean))
        XCTAssertEqual(decide(last(restored: true), after: 5 * Self.hour), .skip(.old))
    }

    /// The plan's reading — a file from before Spec 9: "Without `writtenAt`
    /// it can't be shown recent: not restored, reason `old`. Without `clean`
    /// it counts as not clean. No file: an empty start, no `lastStateSkipped`".
    func test_aFileWithoutItsFactsAndNoFileAtAll() {
        XCTAssertEqual(decide(last(writtenAt: nil)), .skip(.old))
        XCTAssertEqual(decide(last(writtenAt: "last Sunday")), .skip(.old))
        XCTAssertEqual(decide(last(clean: nil, restored: nil)), .restore, "no word that it ended cleanly, or was put back")
        XCTAssertEqual(decide(nil), .none)
        XCTAssertEqual(decide(nil, setting: false, relaunch: true), .none)
    }

    /// A clock set back a little leaves the stamp ahead of now; it is still
    /// within two hours of it. One far ahead proves nothing.
    func test_aStampAheadOfTheClockCountsByItsDistance() {
        XCTAssertEqual(decide(last(), after: -10 * Self.minute), .restore)
        XCTAssertEqual(decide(last(), after: -3 * Self.hour), .skip(.old))
    }

    /// The reasons as the note writes them (Spec 9 §2).
    func test_theReasonsAreWrittenAsThePageNamesThem() {
        XCTAssertEqual(LastState.SkipReason.clean.rawValue, "clean")
        XCTAssertEqual(LastState.SkipReason.old.rawValue, "old")
        XCTAssertEqual(LastState.SkipReason.restoredBefore.rawValue, "restoredBefore")
        XCTAssertEqual(LastState.restoreLimitMs, 2 * 60 * 60 * 1000)
    }
}
