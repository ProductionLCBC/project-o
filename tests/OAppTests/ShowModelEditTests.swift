import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §10 — the show model's edits: one edit sent, a refusal said in
/// plain words beside what was tried, and Undo and Redo named from the
/// `history` topic.
@MainActor
final class ShowModelEditTests: XCTestCase {
    typealias Rig = ShowModelTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try CatalogFile.install() }
    }

    private func history(_ rig: Rig, undo: String? = nil, redo: String? = nil, commands: Int = 1, source: String = "ui") {
        func step(_ text: String?) -> JSONValue {
            guard let text else { return .null }
            return .object(["group": .string("g-1"), "commands": .number(Double(commands)), "source": .object(["kind": .string(source)]), "text": .string(text)])
        }
        rig.store.apply(event: "history", ["topic": .string("history"), "undo": step(undo), "redo": step(redo)], now: rig.clock.now)
    }

    func test_anEditGoesAsOneCommandWithSourceUIAndItsResultComesBack() throws {
        let rig = try Rig()
        var applied: CommandOutcome?
        XCTAssertTrue(rig.model.edit(Edits.rename(list: 42, to: "Great Is Thy Faithfulness (Runyan)"), at: .left) { applied = $0 })
        XCTAssertEqual(rig.commands, [["edit list 42 title \"Great Is Thy Faithfulness (Runyan)\""]])
        XCTAssertEqual(rig.sent.first?.fields["source"], .string("ui"))
        rig.answers[0](.result(CommandOutcome(kind: .ok, group: "g-1")))
        XCTAssertEqual(applied?.group, "g-1", "the result names what the engine applied")
        XCTAssertEqual(rig.model.notices, [:])
    }

    /// "Rejections come back as a short message in plain words beside what was tried, from the code".
    func test_aRefusalIsSaidInPlainWordsBesideWhatWasTriedAndGoesAfterFiveSeconds() throws {
        let rig = try Rig()
        var applied = false
        rig.model.edit(Edits.rename(list: 42, to: "Doxology"), at: .left) { _ in applied = true }
        rig.changes = []
        rig.answers[0](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "duplicate", message: "list title \"Doxology\" is taken"))))
        XCTAssertFalse(applied)
        let notice = try XCTUnwrap(rig.model.notices[.left])
        XCTAssertEqual(EditWording.notice(notice), "That name is taken.", "the app's sentence for the code, not the engine's English")
        XCTAssertEqual(rig.changes, [[.left]], "the left column redraws, and nothing else")
        rig.clock.advance(by: 4.9)
        XCTAssertNotNil(rig.model.notices[.left])
        rig.clock.advance(by: 0.2)
        XCTAssertNil(rig.model.notices[.left])
        // A newer message at the same place takes the older one's, and each place has its own.
        rig.model.say(.rejected(EngineRejection(code: "onAir", message: "")), at: .pool)
        rig.model.say(.rejected(EngineRejection(code: "archived", message: "")), at: .left)
        rig.model.say(.notSent(.unavailable(.locked)), at: .left)
        XCTAssertEqual(rig.model.notices.count, 2)
        XCTAssertEqual(rig.model.notices[.left].map(EditWording.notice), "Not sent. The station is locked.")
        XCTAssertEqual(rig.model.notices[.pool].map(EditWording.notice), "It’s on air: clear it or switch away first.")
        rig.model.dismissNotice(at: .pool)
        XCTAssertNil(rig.model.notices[.pool])
    }

    func test_whileTheEngineIsAwayAnEditIsNotSentAndNotKept() throws {
        let rig = try Rig()
        rig.store.disconnected()
        XCTAssertFalse(rig.model.edit(Edits.delete(list: 42), at: .left))
        try rig.connect()
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// "Edit ▸ Undo and Redo send `undo` and `redo` (Spec 5 §8). Their names
    /// come from the `history` topic's top groups ... After an undo or a
    /// redo, the window says for three seconds what changed".
    func test_undoSendsUndoAndSaysForThreeSecondsWhatChanged() throws {
        let rig = try Rig()
        XCTAssertNil(rig.model.undoStep, "nothing to undo yet")
        XCTAssertFalse(rig.model.undo())
        XCTAssertEqual(rig.sent.count, 0)
        history(rig, undo: "edit list 42 title \"Great Is Thy Faithfulness (Runyan)\"")
        XCTAssertEqual(EditWording.menuTitle(undo: true, step: rig.model.undoStep), "Undo Rename")
        XCTAssertEqual(EditWording.menuTitle(undo: false, step: rig.model.redoStep), "Redo")
        XCTAssertTrue(rig.model.undo())
        XCTAssertEqual(rig.commands, [["undo"]])
        // The engine undoes it: the history's top moves to the redo side before the result arrives.
        history(rig, redo: "edit list 42 title \"Great Is Thy Faithfulness (Runyan)\"")
        rig.answers[0](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.model.notices[.top].map(EditWording.notice), "Undid the rename of the list Great Is Thy Faithfulness")
        rig.clock.advance(by: 2.9)
        XCTAssertNotNil(rig.model.notices[.top])
        rig.clock.advance(by: 0.2)
        XCTAssertNil(rig.model.notices[.top], "for three seconds")
        XCTAssertEqual(EditWording.menuTitle(undo: false, step: rig.model.redoStep), "Redo Rename")
        XCTAssertTrue(rig.model.redo())
        XCTAssertEqual(rig.commands.last, ["redo"])
        rig.answers[1](.result(CommandOutcome(kind: .ok)))
        XCTAssertEqual(rig.model.notices[.top].map(EditWording.notice), "Redid the rename of the list Great Is Thy Faithfulness")
    }

    func test_anUndoTheEngineRefusesSaysWhy() throws {
        let rig = try Rig()
        history(rig, undo: "edit list 42 delete")
        rig.model.undo()
        rig.answers[0](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "conflict", message: "list 42's number is taken"))))
        XCTAssertEqual(rig.model.notices[.top].map(EditWording.notice), "It has changed since, so that can’t be put back.")
    }

    /// "Both are disabled under the lock and while the engine is away."
    func test_undoAndRedoAreDisabledUnderTheLockAndWhileTheEngineIsAway() throws {
        let rig = try Rig()
        history(rig, undo: "edit list 42 title \"X\"", redo: "edit list 42 title \"Y\"")
        XCTAssertNotNil(rig.model.undoStep)
        var engine = try RecordedAPI.event("engine")
        engine["lock"] = .bool(true)
        rig.store.apply(event: "engine", engine, now: rig.clock.now)
        XCTAssertEqual(rig.model.cannotUndo, .locked)
        XCTAssertNil(rig.model.undoStep)
        XCTAssertNil(rig.model.redoStep)
        XCTAssertFalse(rig.model.undo())
        XCTAssertFalse(rig.model.redo())
        engine["lock"] = .bool(false)
        rig.store.apply(event: "engine", engine, now: rig.clock.now)
        XCTAssertNotNil(rig.model.undoStep)
        rig.store.disconnected()
        XCTAssertEqual(rig.model.cannotUndo, .engineAway)
        XCTAssertFalse(rig.model.undo())
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// Spec 10 §10 — "edits to masters on a `readOnlyMasters` machine (Spec 5 §7); the app disables them".
    func test_aReadOnlyMastersMachineMayNotEditMastersAndMayEditItsOwnPlaylists() throws {
        let rig = try Rig()
        XCTAssertNil(rig.model.cannotEditMasters, "the recorded machine's library is writable")
        var catalog = try RecordedAPI.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        var settings = try XCTUnwrap(machine["settings"]?.objectValue)
        settings["libraryMode"] = .string("readOnlyMasters")
        machine["settings"] = .object(settings)
        catalog["machine"] = .object(machine)
        rig.store.apply(catalog: catalog)
        XCTAssertEqual(rig.model.cannotEditMasters, .readOnlyMasters)
        XCTAssertNil(rig.model.cannotEditMachine)
    }
}
