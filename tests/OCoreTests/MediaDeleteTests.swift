import Foundation
import XCTest
@testable import OCore

/// Spec 8 §6 — `media delete` and `media undelete`, pure: their checks, what
/// they do to the entry, and how the runner parks a held delete and applies a
/// direct one with the files the worker moved. (Moving the files, the second
/// check and the gate are the engine's tests, MediaDeleteEngineTests.)
final class MediaDeleteTests: XCTestCase {
    typealias F = FixtureLibrary

    func roots(writable: Bool = true) -> (library: Library, machine: Machine) {
        var (library, machine, _) = F.load()
        machine.settings.libraryMode = writable ? .writable : .readOnlyMasters
        return (library, machine)
    }

    let files = [MediaTrashedFile(location: MediaLocation(.machineMedia, "cross-fast.png")!, trash: "/Users/x/.Trash/cross-fast.png"),
                 MediaTrashedFile(location: MediaLocation(.mediaRoot, "backgrounds/cross.png")!, trash: "/Users/x/.Trash/cross.png")]

    func reason<T>(_ result: Result<T, Rejection>) -> RejectionReason? {
        if case .failure(let r) = result { return r.reason }
        return nil
    }

    /// "Checks ... Library mode and operator lock apply (§2)"; an item already
    /// deleted changes nothing; an undelete of an item not deleted is a `conflict`.
    func test_theChecks() {
        let (library, machine) = roots()
        XCTAssertEqual(reason(MediaEdits.check(.delete(id: "sha256:" + String(repeating: "0", count: 64), files: nil), library: library, machine: machine)),
                       .unknownObject)
        XCTAssertEqual(try MediaEdits.check(.delete(id: F.cross, files: nil), library: library, machine: machine).get(), true)
        XCTAssertEqual(reason(MediaEdits.check(.undelete(id: F.cross, files: files), library: library, machine: machine)), .conflict)
        let (readOnlyLibrary, readOnlyMachine) = roots(writable: false)
        XCTAssertEqual(reason(MediaEdits.check(.delete(id: F.cross, files: nil), library: readOnlyLibrary, machine: readOnlyMachine)), .readOnlyLibrary)
        XCTAssertEqual(try MediaEdits.check(.delete(id: F.announcement, files: nil), library: readOnlyLibrary, machine: readOnlyMachine).get(), true,
                       "the machine's own media")
    }

    /// "the entry stays, with `deletedAt` set and its `path` empty, and the
    /// command is logged with where each file came from and where the Trash
    /// put it"; its inverse undelete brings the path back from the files.
    func test_deleteAndUndeleteChangeTheEntryAndInvertEachOther() throws {
        let (library, machine) = roots()
        let deleted = try MediaEdits.delete(id: F.cross, files: files, at: "2026-11-14T10:00:00Z", library: library, machine: machine).get()
        let entry = try XCTUnwrap(deleted.library.mediaIndex.entry(F.cross))
        XCTAssertEqual(entry.deletedAt, "2026-11-14T10:00:00Z")
        XCTAssertEqual(entry.path, "")
        XCTAssertEqual(deleted.logged, .delete(id: F.cross, files: files))
        XCTAssertEqual(deleted.inverse, .undelete(id: F.cross, files: files))
        XCTAssertEqual(deleted.changes, [LibraryChange(object: "media", address: ["media": .string(F.cross)], paths: ["path", "deletedAt"])])
        // Deleting it again changes nothing.
        let again = try MediaEdits.delete(id: F.cross, files: [], at: "2026-11-14T11:00:00Z", library: deleted.library, machine: deleted.machine).get()
        XCTAssertTrue(again.isNoop)
        // Undelete: "the entry takes the restored path of its first file in its own folder".
        let restored = try MediaEdits.undelete(id: F.cross, files: files, restored: files, library: deleted.library, machine: deleted.machine).get()
        XCTAssertEqual(restored.library, library, "the entry as it was")
        XCTAssertEqual(restored.inverse, .delete(id: F.cross, files: nil))
        // "giving the restored one a numbered name instead".
        let numbered = [files[0], MediaTrashedFile(location: MediaLocation(.mediaRoot, "backgrounds/cross 2.png")!, trash: files[1].trash)]
        let renamed = try MediaEdits.undelete(id: F.cross, files: files, restored: numbered, library: deleted.library, machine: deleted.machine).get()
        XCTAssertEqual(renamed.library.mediaIndex.entry(F.cross)?.path, "backgrounds/cross 2.png")
        XCTAssertEqual(renamed.logged, .undelete(id: F.cross, files: files), "logged as sent")
    }

    /// Spec 8 §2 — "a held `media delete` applies once its files have moved
    /// (§6), after the rest of its group", and Adam's answer of 2026-11-11 (7):
    /// the held edits after it wait with it. A delete sent directly is applied
    /// without files on the first check, and with the worker's on the second.
    func test_theRunnerParksAHeldDeleteAndAppliesADirectOneWithItsFiles() throws {
        let (library, machine) = roots()
        let state = ShowState.fresh(library: library, machine: machine)
        let context = ProjectionContext(frame: 0, library: library, machine: machine, source: CommandSource(kind: .engine))
        let write = Command.channelWrite(ChannelWrite(channel: .number(2), content: .media(MediaContent(ref: F.cross))))
        let rename = Command.edit(EditCommand(.list(42), .set(path: "title", value: .string("Renamed"))))
        let held = CommandGroup(id: GroupID.random(), source: CommandSource(kind: .scheduler),
                                commands: [.media(.delete(id: F.announcement, files: nil)), write, rename])
        let parked = try CommandRunner.run(held, state: state, context: context).get()
        XCTAssertEqual(parked.executed.map(\.command), [write], "the rest of the group ran at once")
        XCTAssertEqual(parked.parked.map(\.command), [.media(.delete(id: F.announcement, files: nil)), rename], "the delete and the edit after it wait")
        XCTAssertEqual(parked.library, library)
        let moved = [MediaTrashedFile(location: MediaLocation(.machineMedia, "announcement.png")!, trash: "/Users/x/.Trash/announcement.png")]
        let after = CommandRunner.runHeld(parked.parked, state: parked.state, context: context, moved: [F.announcement: .success(moved)])
        XCTAssertEqual(after.executed.map(\.result), [.ok, .ok])
        XCTAssertEqual(after.executed.first?.command, .media(.delete(id: F.announcement, files: moved)))
        XCTAssertNotNil(after.machine.mediaLocal.entry(F.announcement)?.deletedAt)
        XCTAssertEqual(after.library.list(number: 42)?.title, "Renamed")
        let refused = CommandRunner.runHeld(parked.parked, state: parked.state, context: context,
                                            moved: [F.announcement: .failure(Rejection(reason: .noTrash, message: "no Trash"))])
        XCTAssertEqual(refused.executed.map(\.result), [.blocked, .ok], "a delete whose files couldn't move is blocked; the rest runs")

        let direct = CommandGroup(id: GroupID.random(), source: CommandSource(kind: .ui), commands: [.media(.delete(id: F.announcement, files: nil))])
        let first = try CommandRunner.run(direct, state: state, context: context).get()
        XCTAssertNotNil(first.machine.mediaLocal.entry(F.announcement)?.deletedAt, "the first check applies it without files")
        let second = try CommandRunner.run(direct, state: state, context: context, moved: [F.announcement: .success(moved)]).get()
        XCTAssertEqual(second.executed.first?.command, .media(.delete(id: F.announcement, files: moved)))
        XCTAssertEqual(reason(CommandRunner.run(direct, state: state, context: context,
                                                moved: [F.announcement: .failure(Rejection(reason: .noTrash, message: "no Trash"))])), .noTrash)
    }
}
