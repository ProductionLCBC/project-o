import Foundation
import OCore
import XCTest
@testable import OEngine

/// Spec 8 §6 — `media delete` "moves the item's file ... to the Trash", and
/// `media undelete` "moves the files back to where they came from". Adam's
/// answer of 2026-11-11 (8): before delete is built, an opt-in check on this
/// Mac moves a few-byte temporary file into the real Trash and back, so we
/// know macOS lets an engine with no Full Disk Access do both. It runs only
/// with `O_REAL_TRASH=1`, never on the hosted runner or in an ordinary run.
final class MediaTrashTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func test_aFileGoesToTheRealTrashAndComesBack() throws {
        guard ProcessInfo.processInfo.environment["O_REAL_TRASH"] == "1" else {
            throw XCTSkip("the real Trash is touched only with O_REAL_TRASH=1 (Spec 8 §6, Adam's answer 8)")
        }
        let bytes = Data("Project O Trash check \(UUID().uuidString)\n".utf8)
        let file = folder.appendingPathComponent("Trash check.txt")
        try bytes.write(to: file)
        let trash = SystemTrash()

        let trashed: URL
        switch trash.trash(file) {
        case .success(let url): trashed = url
        case .failure(let why): return XCTFail("macOS refused the move to the Trash: \(why)")
        }
        print("Trash check: the Trash put the file at \(trashed.path)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the file left its folder")
        XCTAssertTrue(trashed.path.contains("/.Trash/"), "it went to the user's Trash: \(trashed.path)")

        switch trash.putBack(trashed, to: file) {
        case .success: break
        case .failure(let why):
            return XCTFail("macOS refused the move back from the Trash: \(why); the file is still at \(trashed.path)")
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes, "the same bytes came back")
        var info = stat()
        XCTAssertNotEqual(lstat(trashed.path, &info), 0, "nothing is left in the Trash")

        // Spec 8 §6 — "if the Trash has been emptied, the undo fails with
        // `conflict`": a file no longer where the Trash put it is `gone`.
        XCTAssertEqual(trash.putBack(trashed, to: folder.appendingPathComponent("again.txt")).failure, .gone)
    }

    /// The seam's own refusals, without the real Trash: a file the Trash no
    /// longer holds is `gone`, and putting back never writes over a file.
    func test_puttingBackNeverWritesOverAFile() throws {
        let away = folder.appendingPathComponent("away.txt")
        let here = folder.appendingPathComponent("here.txt")
        try Data("away".utf8).write(to: away)
        try Data("here".utf8).write(to: here)
        XCTAssertEqual(SystemTrash().putBack(away, to: here).failure, .taken)
        XCTAssertEqual(try String(contentsOf: here, encoding: .utf8), "here")
        XCTAssertEqual(try String(contentsOf: away, encoding: .utf8), "away")
        XCTAssertEqual(SystemTrash().putBack(folder.appendingPathComponent("never.txt"), to: here).failure, .gone)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
