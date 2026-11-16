import Foundation
import XCTest
@testable import OCore

/// Spec 10 §2, "What a relaunch brings back" (choice U-14) — "A launch is a
/// relaunch when the app says so with `--relaunch`, having seen the engine
/// end or ended it itself, or when the run before it ended without a stop in
/// this boot of the Mac: `state/last.json` says `clean: false` and was
/// written after the Mac started. The flag covers a full disk, which removes
/// that file (Spec 9 §7)." Spec 10 §18, Area 19, stopping and relaunching.
final class RelaunchRuleTests: XCTestCase {
    /// 2026-11-08T09:41:07.002-05:00, as the fixture's file is stamped.
    let written = "2026-11-08T09:41:07.002-05:00"
    var writtenMs: Int64 { CivilTime.milliseconds(written) ?? 0 }

    func last(clean: Bool? = false, writtenAt: String? = "2026-11-08T09:41:07.002-05:00") -> LastState {
        LastState(writtenAt: writtenAt, run: UUID(), clean: clean, restored: false, state: ShowState())
    }

    func test_theFlagMakesARelaunchWhateverTheFileSays() {
        XCTAssertTrue(LastState.isRelaunch(flagged: true, last: nil, bootedAtMs: nil), "with no last.json, as after a full disk")
        XCTAssertTrue(LastState.isRelaunch(flagged: true, last: last(clean: true), bootedAtMs: writtenMs + 1), "the app saw the engine end")
    }

    func test_aRunThatEndedWithoutAStopInThisBootMakesARelaunch() {
        let booted = writtenMs - 3_600_000   // the Mac started an hour before the file was written
        XCTAssertGreaterThan(writtenMs, 0, "the stamp reads")
        XCTAssertTrue(LastState.isRelaunch(flagged: false, last: last(), bootedAtMs: booted), "clean false, written after the Mac started")
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(clean: true), bootedAtMs: booted), "a stop on request is no crash")
    }

    func test_aFileFromBeforeTheMacStartedIsNotThisBoots() {
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(), bootedAtMs: writtenMs + 60_000), "the Mac itself went down since: the setting decides")
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(), bootedAtMs: writtenMs), "written as the Mac started is not after it")
        XCTAssertTrue(LastState.isRelaunch(flagged: false, last: last(), bootedAtMs: writtenMs - 1))
    }

    func test_whatIsNotKnownMakesNoRelaunch() {
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: nil, bootedAtMs: 0), "no file")
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(), bootedAtMs: nil), "the boot time isn't known")
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(writtenAt: nil), bootedAtMs: 0), "a file that doesn't say when it was written")
        XCTAssertFalse(LastState.isRelaunch(flagged: false, last: last(writtenAt: "yesterday"), bootedAtMs: 0), "or says it in no form that reads")
        // A file that doesn't say it ended cleanly counts as not clean, as it does for the restore (Spec 9 §4).
        XCTAssertTrue(LastState.isRelaunch(flagged: false, last: last(clean: nil), bootedAtMs: writtenMs - 1))
    }
}
