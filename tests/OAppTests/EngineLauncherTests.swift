import Foundation
import XCTest
@testable import OApp

/// Spec 10 §2, "Starting" — "the app starts `oengine run ...` in a session of
/// its own, so the engine outlives the app. ... The app opens
/// `machine/logs/engine-console.log` for appending as the engine's standard
/// output and error ... An engine that exits with status 3 found another
/// engine holding the root". "When it doesn't answer" — "It ends the engine
/// by its `pid` with a kill, never a terminate signal".
///
/// The live launcher against the system's own small programs, so no test
/// starts an engine (Spec 10 §16).
final class EngineLauncherTests: XCTestCase {
    private var folder: URL!
    private var log: URL!
    private let launcher = PosixEngineLauncher()
    private var started: [Int32] = []

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("o-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log = folder.appendingPathComponent("engine-console.log")
    }

    override func tearDown() {
        for pid in started where launcher.isRunning(pid: pid) { launcher.kill(pid: pid) }
        try? FileManager.default.removeItem(at: folder)
    }

    private func start(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let pid = try launcher.start(EngineLaunch(executable: URL(fileURLWithPath: executable), arguments: arguments, consoleLog: log))
        started.append(pid)
        return pid
    }

    /// Waits for the process's end as the launcher reports it, not for time to pass.
    private func exit(of pid: Int32, timeout: TimeInterval = 10) -> EngineExit? {
        let reported = expectation(description: "the process's end is reported")
        let box = Box<EngineExit?>(nil)
        let watch = launcher.watch(pid: pid) { exit in
            box.set(exit)
            reported.fulfill()
        }
        wait(for: [reported], timeout: timeout)
        watch.cancel()
        return box.value
    }

    private func logText() -> String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(5_000)
        }
        return condition()
    }

    func test_theEngineStartsInASessionOfItsOwn() throws {
        let pid = try start("/bin/sleep", ["30"])
        XCTAssertEqual(getsid(pid), pid, "the process leads its own session, so it outlives the app")
        XCTAssertNotEqual(getsid(pid), getsid(0), "and that session isn't the one this test runs in")
        XCTAssertTrue(launcher.kill(pid: pid))
        XCTAssertEqual(exit(of: pid), .signaled(SIGKILL), "a kill, never a terminate signal")
    }

    func test_itsOutputAndErrorAreAppendedToTheConsoleLog() throws {
        try Data("before\n".utf8).write(to: log)
        let pid = try start("/bin/sh", ["-c", "echo out; echo err >&2"])
        XCTAssertEqual(exit(of: pid), .exited(status: 0))
        XCTAssertEqual(logText(), "before\nout\nerr\n", "appended, in order, after what the file already held")
    }

    func test_anExitStatusIsRead() throws {
        let pid = try start("/bin/sh", ["-c", "exit 3"])
        XCTAssertEqual(exit(of: pid), .exited(status: 3), "status 3 is how an engine says another holds the root")
    }

    func test_aProcessThatEndedBeforeTheWatchIsStillReportedWithItsStatus() throws {
        let pid = try start("/bin/sh", ["-c", "exit 4"])
        // An ended process that nobody has read yet has no executable path any more.
        XCTAssertTrue(waitUntil { launcher.executablePath(pid: pid) == nil })
        XCTAssertEqual(exit(of: pid), .exited(status: 4))
    }

    func test_aProcessItDidNotStartIsWatchedAndReportedGone() throws {
        // The shell starts a sleep of its own and prints its process id: a process this launcher didn't start.
        let shell = try start("/bin/sh", ["-c", "/bin/sleep 30 & echo $!; wait"])
        XCTAssertTrue(waitUntil { self.logText().contains("\n") })
        let other = try XCTUnwrap(Int32(logText().trimmingCharacters(in: .whitespacesAndNewlines)))
        started.append(other)
        XCTAssertTrue(launcher.isRunning(pid: other))
        XCTAssertEqual(launcher.executablePath(pid: other), "/bin/sleep", "the id names the program it runs")

        let reported = expectation(description: "the other process's end is reported")
        let box = Box<EngineExit?>(nil)
        let watch = launcher.watch(pid: other) { exit in
            box.set(exit)
            reported.fulfill()
        }
        XCTAssertTrue(launcher.kill(pid: other))
        wait(for: [reported], timeout: 10)
        watch.cancel()
        XCTAssertEqual(box.value, .gone, "its status is its own parent's to read")
        XCTAssertEqual(exit(of: shell), .exited(status: 0))
    }

    func test_aProcessThatIsNotThereIsReportedGoneAtOnce() throws {
        let pid = try start("/bin/sh", ["-c", "exit 0"])
        XCTAssertEqual(exit(of: pid), .exited(status: 0))
        XCTAssertFalse(launcher.isRunning(pid: pid))
        XCTAssertEqual(exit(of: pid), .gone, "once read, the id names nothing")
        XCTAssertNil(launcher.executablePath(pid: pid))
    }

    func test_anExecutableThatIsNotThereIsRefused() {
        XCTAssertThrowsError(try start(folder.appendingPathComponent("no-such-engine").path, [])) { error in
            guard case EngineLaunchError.spawn(_, let code)? = error as? EngineLaunchError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, ENOENT)
        }
    }

    func test_aConsoleLogThatCannotBeOpenedIsRefused() {
        log = folder.appendingPathComponent("no-such-folder/engine-console.log")
        XCTAssertThrowsError(try start("/bin/sh", ["-c", "exit 0"])) { error in
            guard case EngineLaunchError.consoleLog? = error as? EngineLaunchError else { return XCTFail("\(error)") }
        }
    }

    func test_theEngineIsGivenTheUsersEnvironmentAndNothingOfATestRunners() {
        let kept = PosixEngineLauncher.environment(from: [
            "HOME": "/Users/someone", "PATH": "/usr/bin", "TMPDIR": "/tmp/x", "LC_ALL": "en_US.UTF-8",
            "DYLD_INSERT_LIBRARIES": "/x.dylib", "XCTestConfigurationFilePath": "/y", "OS_ACTIVITY_DT_MODE": "YES",
        ])
        XCTAssertEqual(kept, ["HOME": "/Users/someone", "PATH": "/usr/bin", "TMPDIR": "/tmp/x", "LC_ALL": "en_US.UTF-8"])
    }

    func test_onlyTheConsoleLogIsInherited() throws {
        // A descriptor this process holds open must not reach the engine: the shell lists what it was given. The
        // descriptor is given a high number, so it can't be mistaken for one the listing opens for itself.
        let file = open(folder.appendingPathComponent("extra").path, O_WRONLY | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(file, 0)
        let extra = fcntl(file, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(extra, 200)
        defer {
            close(file)
            close(extra)
        }
        let pid = try start("/bin/sh", ["-c", "ls /dev/fd | tr '\\n' ' '"])
        XCTAssertEqual(exit(of: pid), .exited(status: 0))
        let listed = logText().split(separator: " ").compactMap { Int32($0) }
        XCTAssertFalse(listed.contains { $0 >= 200 }, "descriptor \(extra) is open here and must not be in the started process: \(listed)")
        XCTAssertTrue(listed.contains(0) && listed.contains(1) && listed.contains(2))
    }
}

/// A value shared with a callback on another thread.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Value

    init(_ value: Value) { held = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func set(_ value: Value) {
        lock.lock()
        held = value
        lock.unlock()
    }
}
