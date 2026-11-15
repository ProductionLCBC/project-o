import Foundation
import XCTest
@testable import OCore

/// Spec 5 §8 — "One linear stack per run ... up to the last 500 (choice
/// E-4)"; "Any new edit clears the redo stack"; "A reload drops steps";
/// "The media walk drops the steps that name an entry it maps to another
/// file or brings back". Spec 9 §5 — the `history` topic's event. The stack
/// as a value, before the runner and the engine use it.
final class UndoHistoryTests: XCTestCase {
    let ui = CommandSource(kind: .ui)
    let listA = UUID(uuidString: "a9f00000-0000-4000-8000-00000000002a") ?? UUID()
    let listB = UUID(uuidString: "a9f00000-0000-4000-8000-000000000007") ?? UUID()

    func title(_ list: Int, _ text: String) -> Command {
        .edit(EditCommand(.list(list), .set(path: "title", value: .string(text))))
    }

    func record(_ history: inout UndoHistory, _ group: String, list: Int = 42, to: String, from: String, document: UUID? = nil) {
        history.record(group: GroupID(group), source: ui, command: title(list, to), inverse: title(list, from),
                       documents: [.list(document ?? listA)])
    }

    // MARK: - Steps

    func test_itStartsEmpty() {
        let history = UndoHistory()
        XCTAssertNil(history.undoTop)
        XCTAssertNil(history.redoTop)
    }

    /// "The edits in a group share one log group id, one `library` event and one undo step."
    func test_theEditsOfOneGroupAreOneStepAndTheNextGroupIsAnother() {
        var history = UndoHistory()
        record(&history, "g-1", to: "B", from: "A")
        record(&history, "g-1", list: 7, to: "Y", from: "X", document: listB)
        record(&history, "g-2", to: "C", from: "B")
        XCTAssertEqual(history.undo.map(\.group), [GroupID("g-1"), GroupID("g-2")])
        XCTAssertEqual(history.undo[0].commands, [title(42, "B"), title(7, "Y")])
        XCTAssertEqual(history.undo[0].inverses, [title(42, "A"), title(7, "X")])
        XCTAssertEqual(history.undo[0].documents, [.list(listA), .list(listB)])
        XCTAssertEqual(history.undoTop?.group, GroupID("g-2"))
    }

    /// "up to the last 500": the oldest goes.
    func test_itKeepsTheLast500Groups() {
        var history = UndoHistory()
        for n in 1...503 { record(&history, "g-\(n)", to: "t\(n)", from: "t\(n - 1)") }
        XCTAssertEqual(history.undo.count, 500)
        XCTAssertEqual(history.undo.first?.group, GroupID("g-4"))
        XCTAssertEqual(history.undoTop?.group, GroupID("g-503"))
    }

    // MARK: - Undo and redo

    func test_anUndoneGroupMovesToTheRedoStackAndARedoneOneComesBack() {
        var history = UndoHistory()
        record(&history, "g-1", to: "B", from: "A")
        record(&history, "g-2", to: "C", from: "B")
        history.undone()
        XCTAssertEqual(history.undoTop?.group, GroupID("g-1"))
        XCTAssertEqual(history.redoTop?.group, GroupID("g-2"))
        history.undone()
        XCTAssertNil(history.undoTop)
        XCTAssertEqual(history.redo.map(\.group), [GroupID("g-2"), GroupID("g-1")], "the one undone last is redone first")

        // The redo ran g-1's commands again as its own group, with the inverses that run made.
        var again = history.redo[1]
        again.group = GroupID("g-9")
        history.redone(as: again)
        XCTAssertEqual(history.undoTop?.group, GroupID("g-9"))
        XCTAssertEqual(history.undoTop?.source, ui, "where the edits first came from")
        XCTAssertEqual(history.redoTop?.group, GroupID("g-2"))
    }

    /// "Any new edit clears the redo stack, so history stays linear".
    func test_aNewEditClearsTheRedoStack() {
        var history = UndoHistory()
        record(&history, "g-1", to: "B", from: "A")
        history.undone()
        XCTAssertNotNil(history.redoTop)
        record(&history, "g-2", to: "Z", from: "A")
        XCTAssertNil(history.redoTop)
        XCTAssertEqual(history.undo.map(\.group), [GroupID("g-2")])
    }

    func test_undoneAndRedoneOnAnEmptyStackChangeNothing() {
        var history = UndoHistory()
        history.undone()
        history.redone(as: UndoStep(group: GroupID("g-1"), source: ui))
        XCTAssertEqual(history, UndoHistory())
    }

    // MARK: - Typing (Spec 5 §5)

    /// "pushes one undo step, whose inverse is the value from before the run".
    func test_aTypingRunIsOneStepWithTheValueFromBeforeIt() {
        var history = UndoHistory()
        record(&history, "g-1", to: "G", from: "")
        record(&history, "g-2", to: "Gr", from: "G")
        history.foldTop(intoRun: GroupID("g-1"))
        record(&history, "g-3", to: "Gre", from: "Gr")
        history.foldTop(intoRun: GroupID("g-1"))
        XCTAssertEqual(history.undo.count, 1)
        XCTAssertEqual(history.undoTop?.group, GroupID("g-1"))
        XCTAssertEqual(history.undoTop?.commands, [title(42, "Gre")])
        XCTAssertEqual(history.undoTop?.inverses, [title(42, "")])
    }

    /// Another client's edit between two edits of a run: the later edit stays a step, under the run's group.
    func test_aRunWithAnotherStepInTheMiddleKeepsItsLaterEditAsAStep() {
        var history = UndoHistory()
        record(&history, "g-1", to: "G", from: "")
        record(&history, "g-other", list: 7, to: "Y", from: "X", document: listB)
        record(&history, "g-2", to: "Gr", from: "G")
        history.foldTop(intoRun: GroupID("g-1"))
        XCTAssertEqual(history.undo.map(\.group), [GroupID("g-1"), GroupID("g-other"), GroupID("g-1")])
        XCTAssertEqual(history.undoTop?.inverses, [title(42, "G")])
    }

    // MARK: - Dropping steps

    /// "every undo and redo step that touches it is dropped".
    func test_aReloadDropsTheStepsOfBothStacksThatTouchTheDocument() {
        var history = UndoHistory()
        record(&history, "g-1", to: "B", from: "A")
        record(&history, "g-2", list: 7, to: "Y", from: "X", document: listB)
        record(&history, "g-3", to: "C", from: "B")
        record(&history, "g-4", list: 7, to: "Z", from: "Y", document: listB)
        history.undone()    // g-4 to redo
        XCTAssertEqual(history.drop(touching: [.list(listB)]), [GroupID("g-2"), GroupID("g-4")])
        XCTAssertEqual(history.undo.map(\.group), [GroupID("g-1"), GroupID("g-3")])
        XCTAssertNil(history.redoTop)
        XCTAssertEqual(history.drop(touching: [.keys]), [])
        XCTAssertEqual(history.drop(touching: []), [])
    }

    /// "The media walk drops the steps that name an entry it maps to another file or brings back".
    func test_theWalkDropsTheStepsThatNameAnEntry() {
        var history = UndoHistory()
        let old = "sha256:" + String(repeating: "a", count: 64)
        let new = "sha256:" + String(repeating: "b", count: 64)
        let other = "sha256:" + String(repeating: "c", count: 64)
        let record = MediaReplaceRecord()
        history.record(group: GroupID("g-1"), source: ui, command: .media(.replace(old: old, new: new, record: record)),
                       inverse: .media(.unreplace(old: old, new: new, record: record)), documents: [.mediaIndex])
        history.record(group: GroupID("g-2"), source: ui,
                       command: .edit(EditCommand(.media(other), .set(path: "defaults.loop", value: .bool(true)))),
                       inverse: .edit(EditCommand(.media(other), .unset(path: "defaults.loop"))), documents: [.mediaIndex])
        self.record(&history, "g-3", to: "B", from: "A")
        XCTAssertEqual(history.undo[0].mediaIDs, [old, new])
        XCTAssertEqual(history.drop(naming: [other]), [GroupID("g-2")])
        XCTAssertEqual(history.drop(naming: [new]), [GroupID("g-1")])
        XCTAssertEqual(history.undo.map(\.group), [GroupID("g-3")])
    }

    // MARK: - Snapshots named (Spec 9 §7)

    func test_itNamesTheSnapshotsItsStepsWouldRestore() {
        var history = UndoHistory()
        history.record(group: GroupID("g-1"), source: ui, command: .systemRestoreSnapshot(id: "2026-11-08-085959"),
                       inverse: .systemRestoreSnapshot(id: "2026-11-08-091500"), documents: [])
        record(&history, "g-2", to: "B", from: "A")
        history.undone()
        XCTAssertEqual(history.snapshotIDs, ["2026-11-08-085959", "2026-11-08-091500"])
    }

    // MARK: - The history topic (Spec 9 §5)

    func test_theEventNamesTheTopOfEachStack() throws {
        var history = UndoHistory()
        XCTAssertEqual(history.event(seq: 7), .object(["type": .string("event"), "topic": .string("history"), "undo": .null, "redo": .null,
                                                        "seq": .number(7)]))
        record(&history, "g-7f1a2b3c", to: "Great Is Thy Faithfulness", from: "Great")
        record(&history, "g-2", to: "C", from: "B")
        record(&history, "g-2", list: 7, to: "Y", from: "X", document: listB)
        history.undone()
        let event = try XCTUnwrap(history.event(seq: 5230).objectValue)
        XCTAssertEqual(event["seq"], .number(5230))
        XCTAssertEqual(event["undo"], .object(["group": .string("g-7f1a2b3c"), "commands": .number(1), "source": .object(["kind": .string("ui")]),
                                               "text": .string("edit list 42 title \"Great Is Thy Faithfulness\"")]))
        let redo = try XCTUnwrap(event["redo"]?.objectValue)
        XCTAssertEqual(redo["group"], .string("g-2"))
        XCTAssertEqual(redo["commands"], .number(2))
        XCTAssertEqual(redo["text"], .string("edit list 42 title \"C\""), "the group's first command")
    }
}
