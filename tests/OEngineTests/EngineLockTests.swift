import Foundation
import XCTest
@testable import OEngine

/// Spec 10 §2, "One engine per machine root" — "The engine holds an exclusive
/// lock on `machine/.engine.lock` while it runs, with its process id in the
/// file. A second engine on the same root exits at once with status 3 and a
/// line saying which engine holds it." Spec 10 §18, Area 19 — "a second
/// engine on the same root exits with status 3; the lock file holds the
/// engine's process id".
final class EngineLockTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_theLockFileHoldsTheEnginesProcessID() throws {
        let lock = try EngineLock.acquire(machineRoot: root).get()
        defer { lock.release() }
        XCTAssertEqual(lock.url.lastPathComponent, ".engine.lock")
        let text = try String(contentsOf: root.appendingPathComponent(".engine.lock"), encoding: .utf8)
        XCTAssertEqual(text, "\(getpid())\n")
        XCTAssertEqual(EngineLock.holder(machineRoot: root), getpid(), "what the app reads to find an engine that doesn't answer")
    }

    func test_aSecondEngineOnTheSameRootIsRefusedAndToldWhoHoldsIt() throws {
        let first = try EngineLock.acquire(machineRoot: root).get()
        defer { first.release() }
        switch EngineLock.acquire(machineRoot: root) {
        case .success(let second):
            second.release()
            XCTFail("two engines hold one root")
        case .failure(let failure):
            XCTAssertEqual(failure, .held(by: getpid()))
            XCTAssertEqual(failure.description, "engine \(getpid()) holds this machine root")
        }
        XCTAssertEqual(EngineLock.holder(machineRoot: root), getpid(), "the refused engine leaves the holder's id in the file")
    }

    func test_theRootIsFreeAgainOnceItsEngineLetsGo() throws {
        let first = try EngineLock.acquire(machineRoot: root).get()
        first.release()
        first.release()
        let second = try EngineLock.acquire(machineRoot: root).get()
        second.release()
    }

    func test_theLockMakesAMachineRootThatIsNotThereYet() throws {
        // Spec 10 §13 — the engine writes a new install's machine root, so the lock comes before the folder exists.
        let fresh = root.appendingPathComponent("Project O/machine")
        let lock = try EngineLock.acquire(machineRoot: fresh).get()
        defer { lock.release() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.appendingPathComponent(".engine.lock").path))
    }

    func test_aRootWhoseLockFileNamesNobodyHasNoHolder() throws {
        XCTAssertNil(EngineLock.holder(machineRoot: root), "no file")
        try Data("not a number\n".utf8).write(to: root.appendingPathComponent(".engine.lock"))
        XCTAssertNil(EngineLock.holder(machineRoot: root))
    }

    /// "A second engine on the same root exits at once with status 3": before
    /// the roots are read, a first-run document is written or a screen opens.
    func test_runOnAHeldRootExitsWithStatusThreeBeforeAnythingIsBuilt() throws {
        let held = try EngineLock.acquire(machineRoot: root).get()
        defer { held.release() }
        let library = root.appendingPathComponent("library")
        let status = OEngineCommandLine.run(arguments: ["run", "--library", library.path, "--machine", root.path])
        XCTAssertEqual(status, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".engine.lock"], "nothing was written beside the lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    /// Spec 10 §13 (Adam's answer of 2026-11-15) — a launch that is refused
    /// "writes nothing": what taking the lock made goes again, and nothing
    /// that was there before does.
    func test_withdrawingTakesAwayWhatTakingTheLockMadeAndNothingElse() throws {
        // A machine root two folders deep that isn't there yet.
        let fresh = root.appendingPathComponent("Project O/machine")
        try EngineLock.acquire(machineRoot: fresh).get().withdraw()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Project O").path), "the folders it made are gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the folder that was there stays")

        // A folder that was there, with something in it: only the lock file goes.
        let used = root.appendingPathComponent("used")
        try FileManager.default.createDirectory(at: used, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: used.appendingPathComponent("note.txt"))
        try EngineLock.acquire(machineRoot: used).get().withdraw()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: used.path), ["note.txt"])

        // A lock file an earlier engine left stays, and the root can be taken again.
        let before = root.appendingPathComponent("before")
        try EngineLock.acquire(machineRoot: before).get().release()
        try EngineLock.acquire(machineRoot: before).get().withdraw()
        XCTAssertTrue(FileManager.default.fileExists(atPath: before.appendingPathComponent(".engine.lock").path))
        try EngineLock.acquire(machineRoot: before).get().release()

        // Something written into a fresh root while it was held keeps the folder.
        let filled = root.appendingPathComponent("filled")
        let lock = try EngineLock.acquire(machineRoot: filled).get()
        try Data("{}".utf8).write(to: filled.appendingPathComponent("machine.json"))
        lock.withdraw()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: filled.path), ["machine.json"])
    }

    /// Status 3 is the app's sign that another engine holds the root, which
    /// it doesn't count as an end; roots that don't load are an end, with a
    /// status of their own, and they let the root go.
    func test_rootsThatDoNotLoadExitWithStatusFourAndLetTheRootGo() throws {
        // A short folder: the machine root's socket path has to fit (Spec 10 §2), and the temporary folder's doesn't.
        let short = try ShortFolder.make()
        defer { try? FileManager.default.removeItem(at: short) }
        let library = short.appendingPathComponent("library"), machine = short.appendingPathComponent("machine")
        try FileManager.default.copyItem(at: EngineFixtures.libraryRoot, to: library)
        try FileManager.default.copyItem(at: EngineFixtures.machineRoot, to: machine)
        try Data("{ not json".utf8).write(to: library.appendingPathComponent("library.json"))
        let status = OEngineCommandLine.run(arguments: ["run", "--library", library.path, "--machine", machine.path])
        XCTAssertEqual(status, 4)
        let again = try EngineLock.acquire(machineRoot: machine).get()
        again.release()
    }
}
