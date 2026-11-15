import Foundation
import XCTest
import OCore
import OFormats
@testable import OEngine

/// Spec 9 §5 and Spec 5 §8 — edit undo and redo in the engine. Spec 9 §10,
/// Undo and redo: "The stack holds 500 groups, is empty at launch and runs
/// `undoes` and `redoes` groups with source `restore`; a reload or the media
/// walk drops the steps it should with a `stepsDropped` note; operator lock
/// refuses both; `history jump` is refused with `notInV1`; the `history`
/// topic is sent on subscribe and follows every change to either stack."
/// Spec 5 §11 — "Typing ... one log entry and one undo step"; "Disk. A reload
/// drops the undo steps that touch its document"; "Events. Each applied group
/// or reload sends exactly one `library` event, and the revision goes up by
/// one." On temporary copies of the fixture.
final class UndoEngineTests: XCTestCase {
    typealias E = EngineFixtures
    static let doxology = "lists/007-doxology.json"

    var disk: DiskFixture!
    let history = EventRecorder()
    var library: Library { disk.engine.engine.library }

    override func setUpWithError() throws {
        disk = try DiskFixture(launch: true)
        disk.settleSaving()
    }

    override func tearDown() {
        disk = nil
    }

    func entries() -> [LogEntry] { disk.commandLog().compactMap(\.entry) }

    func rejected(_ text: String, source: SourceKind = .ui) -> RejectionReason? {
        let before = disk.control.rejections.count
        disk.send(text, source: source)
        disk.settle()
        return disk.control.rejections.count > before ? disk.control.rejections.last?.reason : nil
    }

    func subscribe() {
        let history = self.history
        disk.engine.engine.publisher.subscribe(["history"]) { history.record($0) }
    }

    // MARK: - The stack

    /// "The stack ... is empty at launch": an undo changes nothing and is logged `noop`.
    func test_theStackIsEmptyAtLaunch() throws {
        XCTAssertNil(disk.control.history.undoTop)
        XCTAssertNil(disk.control.history.redoTop)
        disk.send("undo")
        disk.send("redo")
        disk.settle()
        XCTAssertEqual(entries().map(\.text), ["undo", "redo"])
        XCTAssertEqual(entries().map(\.result), [.noop, .noop])
        XCTAssertEqual(disk.control.revision, 1)
    }

    /// "`undo` runs the top group's logged inverses, last first, as one group with source `restore` and an
    /// `undoes` field; `redo` runs an undone group's commands again with `redoes`"; the event's cause is
    /// `undo` or `redo` (Spec 5 §8), the revision goes up by one each time, and the file follows.
    func test_undoAndRedoRunAsRestoreGroupsWithUndoesAndRedoesInTheLog() throws {
        disk.send("edit list 7 title \"Praise God\"")
        disk.settle()
        let made = try XCTUnwrap(entries().last?.group)
        XCTAssertEqual(disk.control.revision, 2)

        disk.send("undo", source: .commandbar)
        disk.nextSecond()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology")
        XCTAssertEqual(disk.list(at: Self.doxology)?.title, "Doxology", "the file follows")
        var lines = entries()
        XCTAssertEqual(lines.suffix(2).map(\.text), ["undo", "edit list 7 title \"Doxology\""])
        let own = lines[lines.count - 2]
        XCTAssertEqual(own.source.kind, .commandbar)
        XCTAssertEqual(own.undo, .none, "its own line is not undoable")
        XCTAssertEqual(own.result, .ok)
        let undone = try XCTUnwrap(lines.last)
        XCTAssertEqual(undone.source.kind, .restore)
        XCTAssertEqual(undone.kind, .edit)
        XCTAssertEqual(undone.undoes, made)
        XCTAssertNotEqual(undone.group, own.group)
        XCTAssertTrue(disk.commandLogText().contains("\"undoes\": \"\(made.rawValue)\""))
        XCTAssertEqual(disk.control.revision, 3)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("undo"))
        XCTAssertEqual(disk.events.all.last?["group"], .string(undone.group.rawValue))

        disk.send("redo")
        disk.nextSecond()
        XCTAssertEqual(library.list(number: 7)?.title, "Praise God")
        lines = entries()
        XCTAssertEqual(lines.suffix(2).map(\.text), ["redo", "edit list 7 title \"Praise God\""])
        XCTAssertEqual(lines.last?.redoes, made)
        XCTAssertNil(lines.last?.undoes)
        XCTAssertEqual(lines.last?.source.kind, .restore)
        XCTAssertEqual(disk.control.revision, 4)
        XCTAssertEqual(disk.events.all.last?["cause"], .string("redo"))
        XCTAssertEqual(disk.events.all.count, 3, "one `library` event each: the edit, the undo, the redo")
    }

    /// "The stack of this run's applied edit groups, 500 deep".
    func test_theStackHolds500Groups() throws {
        for n in 1...503 {
            disk.send("edit list 7 ccli \"\(n)\"")
            disk.engine.tick()
        }
        XCTAssertEqual(disk.control.history.undo.count, 500)
        XCTAssertEqual(disk.control.history.undoTop?.commands.first, .edit(EditCommand(.list(7), .set(path: "ccli", value: .string("503")))))
    }

    /// Spec 5 §8 — "The stack starts empty at launch and is cleared at quit": the next run can't undo this one's edits.
    func test_theNextRunStartsWithAnEmptyStack() throws {
        disk.send("edit list 7 title \"Praise God\"")
        disk.nextSecond()
        disk.engine.stop()
        let next = try DiskFixture(continuing: disk)
        XCTAssertNil(next.control.history.undoTop)
        next.send("undo")
        next.settle()
        XCTAssertEqual(next.engine.engine.library.list(number: 7)?.title, "Praise God")
    }

    // MARK: - Typing (Spec 5 §5)

    /// "A second of text edits to one field folds into one log entry and one undo step ... whose inverse
    /// is the value from before the run." An undo sent while the run is open closes it first, so the step
    /// it reverses is the one just typed.
    func test_aTypingRunIsOneUndoStepAndAnUndoClosesItFirst() throws {
        for text in ["P", "Pr", "Praise"] {
            disk.send("edit list 7 title \"\(text)\"", client: "app")
            disk.engine.tick()
        }
        XCTAssertEqual(disk.control.history.undo.count, 1)
        XCTAssertTrue(entries().isEmpty, "the run is still open: its one line isn't written")
        disk.send("undo", client: "app")
        disk.settle()
        XCTAssertEqual(library.list(number: 7)?.title, "Doxology", "back to the value from before the run")
        let lines = entries()
        XCTAssertEqual(lines.map(\.text), ["edit list 7 title \"Praise\"", "undo", "edit list 7 title \"Doxology\""])
        XCTAssertEqual(lines[2].undoes, lines[0].group, "the run's group")
        XCTAssertEqual(lines[0].inverse, .edit(EditCommand(.list(7), .set(path: "title", value: .string("Doxology")))))
        disk.send("redo")
        disk.settle()
        XCTAssertEqual(library.list(number: 7)?.title, "Praise")
    }

    // MARK: - Dropped steps

    /// "Steps are dropped, with a `stepsDropped` note, when a document they touch reloads from disk (Spec 5 §10)".
    func test_aReloadDropsTheStepsThatTouchItsDocumentWithANote() throws {
        disk.send("edit list 7 title \"Praise God\"")
        disk.send("edit list 42 ccli \"1\"")
        disk.nextSecond()
        let groups = entries().map(\.group)
        XCTAssertEqual(disk.control.history.undo.count, 2)

        // A sync brings list 7 back changed.
        let path = "lists/007-praise-god.json"
        try disk.write(.library, path, try disk.edited(.library, path, "author", .string("Arrived By Sync")))
        disk.engine.scanDisk()
        XCTAssertEqual(library.list(number: 7)?.author, "Arrived By Sync")

        XCTAssertEqual(disk.control.history.undo.map(\.group), [groups[1]], "the step that touched another list stays")
        let note = try XCTUnwrap(disk.notes("stepsDropped").first)
        XCTAssertEqual(note.note["groups"], .array([.string(groups[0].rawValue)]))
        XCTAssertEqual(note.note["cause"], .string("file"))
        XCTAssertEqual(disk.notes("stepsDropped").count, 1, "one log line")

        // "An undo therefore never overwrites a change that arrived by sync."
        disk.send("undo")
        disk.send("undo")
        disk.settle()
        XCTAssertEqual(library.list(number: 7)?.title, "Praise God")
        XCTAssertEqual(library.list(number: 7)?.author, "Arrived By Sync")
        XCTAssertEqual(library.list(number: 42)?.ccli, "18723", "the other step undid")
    }

    /// "or the media walk maps an entry they name to another file or brings it back (Spec 8 §4)".
    func test_theWalkDropsTheStepsThatNameAnEntryItBringsBack() throws {
        let media = try MediaFixture(launching: true)
        defer { media.trash.release() }
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: media.url(.mediaRoot, "backgrounds/cross.png").path))
        XCTAssertNil(media.run("media delete \(E.cross)"))
        XCTAssertEqual(media.control.history.undo.count, 1)
        let group = try XCTUnwrap(media.control.history.undoTop?.group)

        // The file comes back by hand: the walk brings the deleted item back at that path.
        try bytes.write(to: media.url(.mediaRoot, "backgrounds/cross.png"))
        media.walk()
        XCTAssertNil(media.control.history.undoTop, "the delete's step names that entry")
        media.engine.settleLogs()
        let notes = LogLine.reading(try String(contentsOf: media.machineRoot.appendingPathComponent("logs/commands-\(media.engine.variables.today()).jsonl"),
                                               encoding: .utf8)).compactMap(\.note).filter { $0.event == "stepsDropped" }
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.note["groups"], .array([.string(group.rawValue)]))
        XCTAssertEqual(notes.first?.note["cause"], .string("media"))
    }

    // MARK: - Lock and history jump

    /// "Operator lock refuses undo and redo of edits (Spec 5 §7), and `history jump N` is refused with `notInV1`."
    func test_operatorLockRefusesBothAndHistoryJumpIsNotInV1() throws {
        disk = try DiskFixture(configure: { $0.settings.operatorLock.enabled = true }, launch: true)
        disk.settleSaving()
        for source: SourceKind in [.ui, .api, .osc] {
            XCTAssertEqual(rejected("undo", source: source), .operatorLock, "\(source)")
            XCTAssertEqual(rejected("redo", source: source), .operatorLock, "\(source)")
        }
        XCTAssertNil(rejected("channel 1 clear"), "runtime commands pass")
        // Held, it is `blocked` and logged, and the rest of the group runs.
        disk.engine.send(group: ["undo", "channel 1 lock"], source: .key)
        disk.settle()
        XCTAssertEqual(entries().suffix(2).map(\.result), [.blocked, .ok])
        XCTAssertTrue(disk.log.contains("blocked key edit undo: operatorLock"))

        XCTAssertEqual(rejected("history jump 3"), .notInV1)
    }

    // MARK: - The history topic (Spec 9 §5)

    /// "the engine sends an event when a client subscribes and whenever either stack changes".
    func test_theHistoryTopicIsSentOnSubscribeAndFollowsEveryChange() throws {
        subscribe()
        XCTAssertEqual(history.all.count, 1, "on subscribe")
        XCTAssertEqual(history.all[0]["undo"], .null)
        XCTAssertEqual(history.all[0]["redo"], .null)
        XCTAssertEqual(history.all[0]["topic"], .string("history"))

        disk.send("edit list 7 title \"Praise God\"", source: .ui)
        disk.settle()
        XCTAssertEqual(history.all.count, 2)
        let group = try XCTUnwrap(entries().last?.group)
        XCTAssertEqual(history.all[1]["undo"], .object(["group": .string(group.rawValue), "commands": .number(1),
                                                         "source": .object(["kind": .string("ui")]),
                                                         "text": .string("edit list 7 title \"Praise God\"")]))
        XCTAssertEqual(history.all[1]["redo"], .null)
        XCTAssertEqual(history.all[1]["seq"]?.intValue, entries().last?.seq)

        disk.send("channel 1 clear")
        disk.settle()
        XCTAssertEqual(history.all.count, 2, "a runtime command changes neither stack")

        disk.send("undo")
        disk.settle()
        XCTAssertEqual(history.all.count, 3)
        XCTAssertEqual(history.all[2]["undo"], .null)
        XCTAssertEqual(history.all[2]["redo"]?["text"], .string("edit list 7 title \"Praise God\""))

        disk.send("redo")
        disk.settle()
        XCTAssertEqual(history.all.count, 4)
        XCTAssertEqual(history.all[3]["redo"], .null)
        XCTAssertEqual(history.all[3]["undo"]?["text"], .string("edit list 7 title \"Praise God\""))

        disk.send("undo")
        disk.send("edit list 42 ccli \"2\"")
        disk.settle()
        XCTAssertEqual(history.all.last?["redo"], .null, "a new edit clears the redo stack")
        XCTAssertEqual(history.all.last?["undo"]?["text"], .string("edit list 42 ccli \"2\""))

        // A later subscriber gets the stacks as they are now.
        let late = EventRecorder()
        disk.engine.engine.publisher.subscribe(["history"]) { late.record($0) }
        XCTAssertEqual(late.all.count, 1)
        XCTAssertEqual(late.all[0]["undo"]?["text"], .string("edit list 42 ccli \"2\""))
    }

    /// A reload that drops steps changes the stacks, so the topic follows it.
    func test_theHistoryTopicFollowsDroppedSteps() throws {
        disk.send("edit list 7 title \"Praise God\"")
        disk.nextSecond()
        subscribe()
        XCTAssertNotEqual(history.all.last?["undo"], .null)
        let path = "lists/007-praise-god.json"
        try disk.write(.library, path, try disk.edited(.library, path, "author", .string("Arrived By Sync")))
        disk.engine.scanDisk()
        XCTAssertEqual(history.all.last?["undo"], .null)
    }

    // MARK: - Through the gate (Spec 9 §5, Spec 8 §6)

    /// "an undo whose step holds ... a `media undelete` goes through it too" (the plan): undoing a delete
    /// brings its files back from the Trash before the entry comes back, and redo trashes them again.
    func test_undoingAMediaDeleteBringsItsFilesBackThroughTheGate() throws {
        let media = try MediaFixture()
        defer { media.trash.release() }
        XCTAssertNil(media.run("media delete \(E.cross)"))
        XCTAssertFalse(media.exists(.mediaRoot, "backgrounds/cross.png"))
        XCTAssertEqual(media.control.history.undo.count, 1)

        XCTAssertNil(media.run("undo"))
        XCTAssertTrue(media.exists(.mediaRoot, "backgrounds/cross.png"), "back from the Trash")
        XCTAssertTrue(media.exists(.machineMedia, "cross-fast.png"))
        let entry = MediaResolver.entry(for: E.cross, library: media.control.library.mediaIndex, machine: media.control.machine.mediaLocal)?.entry
        XCTAssertNil(entry?.deletedAt, "and the entry is as it was")
        XCTAssertNil(media.control.history.undoTop)
        XCTAssertNotNil(media.control.history.redoTop)
        XCTAssertEqual(media.mediaLibraryEvents.count, 0)
        XCTAssertEqual(media.library.all.last?["cause"], .string("undo"))

        XCTAssertNil(media.run("redo"))
        XCTAssertFalse(media.exists(.mediaRoot, "backgrounds/cross.png"), "trashed again")
        XCTAssertEqual(media.library.all.last?["cause"], .string("redo"))
        XCTAssertNotNil(media.control.history.undoTop)
    }
}
