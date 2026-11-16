import Foundation
import XCTest
@testable import OEngine

/// Spec 10 §2, "Starting" — "When the app starts an engine after the last
/// one ended, it adds `--relaunch` (below), and `--released display:<uuid>`
/// for each screen it has released while it runs (§9)." The command line's
/// own reading of those words, and the boot time the relaunch rule compares
/// `last.json` with.
final class CommandLineArgumentTests: XCTestCase {
    func test_anOptionGivenOnceAScreenKeepsEveryValueInOrder() {
        let args = Arguments(["--library", "/a/library", "--released", "display:AA", "--relaunch", "--released", "display:BB", "--no-lan",
                              "--campus", "West Shore"])
        XCTAssertEqual(args.all("--released"), ["display:AA", "display:BB"], "one for each screen")
        XCTAssertTrue(args.flag("--relaunch"))
        XCTAssertTrue(args.flag("--no-lan"))
        XCTAssertFalse(args.flag("--no-audio"))
        XCTAssertEqual(args.options["--library"], "/a/library")
        XCTAssertEqual(args.options["--campus"], "West Shore", "a name with a space is one value")
        XCTAssertEqual(args.all("--operator-screen"), [], "an option that wasn't given has no values")
    }

    /// Spec 10 §2 — "was written after the Mac started": the kernel says when that was.
    func test_theMacStartedInThePast() throws {
        let booted = try XCTUnwrap(BootTime.wallMilliseconds(), "the kernel gives its boot time")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(booted, now)
        XCTAssertGreaterThan(booted, now - 2 * 365 * 24 * 3600 * 1000, "within the last two years")
    }
}
