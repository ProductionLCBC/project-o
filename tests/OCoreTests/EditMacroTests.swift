import Foundation
import XCTest
@testable import OCore

/// Spec 11 §13 — "Each edit of a ... macro ... applies with its inverse and
/// its checks (Spec 5 §6); ... a macro that comes to name a stack moves to
/// the machine root and back". Spec 11 §9 is the editor these edits serve.
final class EditMacroTests: XCTestCase {
    typealias F = FixtureLibrary

    private let address = EditAddress.numbered(.macro, 1)
    private let blackout = "{\"cmd\": \"stack.blackout\", \"stack\": 1, \"state\": \"on\"}"
    private let resetTimer = "{\"cmd\": \"timer.reset\", \"timer\": 1}"

    // MARK: - Fields and commands (Spec 11 §9)

    func test_theTilesColorAndLabel() {
        var edits = Edits()
        XCTAssertEqual(edits.apply("edit macro 1 label \"Hello\"").first?.inverse, EditCommand(address, .set(path: "label", value: .string("Welcome"))))
        XCTAssertEqual(edits.apply("edit macro 1 tileLabel \"HELLO\"").first?.inverse, EditCommand(address, .set(path: "tileLabel", value: .string("WELCOME"))))
        edits.apply("edit macro 1 color {\"a\": 1, \"b\": 0, \"g\": 0, \"r\": 1}")
        XCTAssertEqual(edits.library.macro(1)?.label, "Hello")
        XCTAssertEqual(edits.library.macro(1)?.tileLabel, "HELLO")
        XCTAssertEqual(edits.library.macro(1)?.color, Color(r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(edits.refuse("edit macro 1 color \"red\"")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit macro 1 scope machine")?.reason, .unknownPath, "the scope is computed, not stored")
        XCTAssertEqual(edits.refuse("edit macro 9 label \"x\"")?.reason, .unknownObject)
    }

    /// "Commands, in order, each a row with ... Edit, Move Up, Move Down and
    /// Remove"; Spec 5 §4 — inserted, removed and moved in the `commands`
    /// array by position, or set whole.
    func test_commandsGoInComeOutMoveAndAreSet() throws {
        var edits = Edits()
        let before = try XCTUnwrap(edits.library.macro(1)?.commands)
        let added = edits.apply("edit macro 1 insert commands 1 \(resetTimer)")
        XCTAssertEqual(edits.library.macro(1)?.commands.map(\.command.cmd), ["channel.write", "timer.reset", "timer.set", "timer.start", "popup.set"])
        XCTAssertEqual(added.first?.inverse, EditCommand(address, .remove(path: "commands", at: 1)))
        XCTAssertEqual(added.first?.changes, [Edits.changed(.macro, 1, ["commands"])])

        let moved = edits.apply("edit macro 1 move commands 1 3")
        XCTAssertEqual(edits.library.macro(1)?.commands.map(\.command.cmd), ["channel.write", "timer.set", "timer.start", "timer.reset", "popup.set"])
        XCTAssertEqual(moved.first?.inverse, EditCommand(address, .move(path: "commands", from: 3, at: 1)))

        let set = edits.apply("edit macro 1 commands.3 {\"cmd\": \"timer.pause\", \"timer\": 1}")
        XCTAssertEqual(edits.library.macro(1)?.commands[3].command, .timerPause(timer: 1))
        XCTAssertEqual(set.first?.inverse, EditCommand(address, .set(path: "commands.3", value: try JSONCoding.encode(GuardedCommand(.timerReset(timer: 1))))))

        let removed = edits.apply("edit macro 1 remove commands 3")
        XCTAssertEqual(edits.library.macro(1)?.commands, before, "its first command keeps the guard it was read with")
        XCTAssertEqual(removed.first?.inverse,
                       EditCommand(address, .insert(path: "commands", at: 3, value: try JSONCoding.encode(GuardedCommand(.timerPause(timer: 1))))))

        // Commands as Text sends the whole list (Spec 11 §4, §9).
        let whole = edits.apply("edit macro 1 commands [\(resetTimer), {\"cmd\": \"system.clearAll\"}]")
        XCTAssertEqual(edits.library.macro(1)?.commands.map(\.command), [.timerReset(timer: 1), .systemClearAll])
        XCTAssertEqual(whole.first?.inverse, EditCommand(address, .set(path: "commands", value: .array(try before.map { try JSONCoding.encode($0) }))))

        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 5 \(resetTimer)")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit macro 1 remove commands 2")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit macro 1 commands.7 \(resetTimer)")?.reason, .unknownPath)
        XCTAssertEqual(edits.refuse("edit macro 1 commands.0.timer 2")?.reason, .unknownPath, "a whole command is set, not a part of one")
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"timer.reset\"}")?.reason, .badValue)
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"lights.fade\"}")?.reason, .badValue, "not in the vocabulary")
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"channel\": 9, \"cmd\": \"channel.clear\"}")?.reason, .unknownReference)
        XCTAssertEqual(edits.refuse("edit macro 1 insert label 0 \(resetTimer)")?.reason, .badValue, "a label isn't an array")
        assertRoundTrip(["edit macro 1 insert commands 1 \(resetTimer)", "edit macro 1 move commands 1 3", "edit macro 1 remove commands 0",
                         "edit macro 1 commands [\(resetTimer)]", "edit macro 1 label \"Hello\""])
    }

    // MARK: - Scope (Spec 1 §2, Spec 5 §2)

    /// "a macro whose edit makes it name a stack or an output moves from the
    /// library root to the machine root (Spec 1 §2)", and back when it stops.
    func test_aMacroThatComesToNameAStackMovesToTheMachineRootAndBack() throws {
        var edits = Edits()
        XCTAssertEqual(edits.library.documentPaths["macro/1"], "macros/001-welcome.json")
        let named = edits.apply("edit macro 1 insert commands 0 \(blackout)")
        XCTAssertNil(edits.library.macro(1))
        XCTAssertEqual(edits.machine.macro(1)?.commands.first?.command, .stackBlackout(stack: .number(1), state: .on))
        XCTAssertEqual(edits.machine.macros.map(\.number), [1, 2], "in number order")
        XCTAssertEqual(named.first?.structure, [.removeDocument(.libraryMacro(1), path: "macros/001-welcome.json")],
                       "the file it leaves is removed in the same write")
        XCTAssertNil(edits.library.documentPaths["macro/1"])
        XCTAssertEqual(named.first?.inverse, EditCommand(address, .remove(path: "commands", at: 0)))

        // And back: it names no stack or output again.
        let back = edits.apply("edit macro 1 remove commands 0")
        XCTAssertNil(edits.machine.macro(1))
        XCTAssertEqual(edits.library.macro(1)?.commands.count, 4)
        XCTAssertEqual(back.first?.structure, [], "it had no file in the machine root yet")

        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"stack.blackout\", \"stack\": 9, \"state\": \"on\"}")?.reason,
                       .unknownReference, "a machine macro names a stack this machine has")
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"output.stack\", \"output\": 9, \"stack\": 1}")?.reason, .unknownReference)
        assertRoundTrip(["edit macro 1 insert commands 0 \(blackout)"])
        assertRoundTrip(["edit macro 1 insert commands 0 \(blackout)", "edit macro 1 label \"Blackout\"", "edit macro 1 renumber 7"])
    }

    func test_onAReadOnlyMastersMachineOnlyMachineMacrosAreEdited() {
        var edits = Edits(writable: false)
        XCTAssertEqual(edits.refuse("edit macro 1 label \"x\"")?.reason, .readOnlyLibrary, "macro 1 is portable")
        edits.apply("edit macro 2 label \"Pre-service\"")
        XCTAssertEqual(edits.machine.macro(2)?.label, "Pre-service")
        // A machine macro that would stop naming a stack or an output would move into the library.
        XCTAssertEqual(edits.refuse("edit macro 2 commands [\(resetTimer)]")?.reason, .readOnlyLibrary)
        // A new macro belongs to the root its commands give it.
        edits.apply("edit macro 7 create {\"commands\": [\(blackout)], \"label\": \"Blackout\"}")
        XCTAssertNotNil(edits.machine.macro(7))
        XCTAssertEqual(edits.refuse("edit macro 8 create {\"commands\": [\(resetTimer)]}")?.reason, .readOnlyLibrary)
        XCTAssertEqual(edits.refuse("edit macro create")?.reason, .readOnlyLibrary)
    }

    // MARK: - Structure (Spec 5 §6, check 8)

    /// "A cycle, or a macro nested past the depth cap, is refused (`cycle`, Spec 5 §6)."
    func test_aCycleOrANestPastTheCapIsRefused() {
        var edits = Edits()
        edits.apply("edit macro 2 insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 1}")
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 2}")?.reason, .cycle)
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 1}")?.reason, .cycle, "a macro that calls itself")
        XCTAssertEqual(edits.refuse("edit macro 1 insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 9}")?.reason, .unknownReference)

        // Spec 2 §5 — "A macro can call another macro up to 8 deep": a chain 3 → 4 → … → 10, eight macros.
        edits.apply("edit macro 10 create")
        for n in stride(from: 9, through: 3, by: -1) {
            edits.apply("edit macro \(n) create {\"commands\": [{\"cmd\": \"macro.run\", \"macro\": \(n + 1)}]}")
        }
        // One more level, at either end, is past the cap.
        XCTAssertEqual(edits.refuse("edit macro 11 create {\"commands\": [{\"cmd\": \"macro.run\", \"macro\": 3}]}")?.reason, .cycle)
        XCTAssertEqual(edits.refuse("edit macro 10 insert commands 0 {\"cmd\": \"macro.run\", \"macro\": 1}")?.reason, .cycle,
                       "a deeper callee pushes its callers past the cap")
        edits.apply("edit macro 10 insert commands 0 \(resetTimer)")
    }

    /// Spec 5 §6, check 8 — "An edit held by a cue, macro, key binding or
    /// scheduler entry is validated when its holder is saved, like any edit".
    func test_anEditAMacroHoldsIsCheckedWhenItIsSaved() {
        var edits = Edits()
        let held = "{\"channel\": 2, \"cmd\": \"edit.set\", \"object\": \"channel\", \"path\": \"label\", \"value\": \"Lyrics\"}"
        edits.apply("edit macro 1 insert commands 0 \(held)")
        let missing = edits.refuse("edit macro 1 insert commands 0 {\"channel\": 9, \"cmd\": \"edit.set\", \"object\": \"channel\", \"path\": \"label\", \"value\": \"x\"}")
        XCTAssertEqual(missing?.reason, .unknownObject)
        XCTAssertTrue(missing?.message.hasPrefix("the edit the macro holds") == true, missing?.message ?? "")
        // What is on air is asked when the held edit fires, not when it is saved.
        edits.play("channel 2 write text \"Great is Thy faithfulness\"")
        edits.apply("edit macro 1 insert commands 0 {\"channel\": 2, \"cmd\": \"edit.delete\", \"object\": \"channel\"}")
    }

    // MARK: - New, Duplicate, Delete, the number (Spec 11 §9)

    func test_createDuplicateAndDelete() throws {
        var edits = Edits()
        edits.apply("edit macro create")
        XCTAssertEqual(edits.library.macro(3), Macro(number: 3, commands: [], label: "", uuid: Edits.pick(1)))
        edits.apply("edit macro 5 create {\"commands\": [{\"cmd\": \"output.stack\", \"output\": 1, \"stack\": 2}], \"label\": \"Confidence on main\"}")
        XCTAssertEqual(edits.machine.macro(5)?.label, "Confidence on main")
        XCTAssertNil(edits.library.macro(5))
        XCTAssertEqual(edits.refuse("edit macro 5 create")?.reason, .duplicate, "one number names one macro, whichever root holds it")
        XCTAssertEqual(edits.refuse("edit macro 2 create")?.reason, .duplicate)

        let copied = edits.apply("edit macro 2 duplicate")
        XCTAssertEqual(edits.machine.macro(6)?.commands, edits.machine.macro(2)?.commands, "a copy is in the root its commands give it")
        XCTAssertEqual(copied.first?.logged, EditCommand(.numbered(.macro, 2), .duplicate(to: 6, title: nil, picks: EditPicks(uuid: Edits.pick(3)))))
        XCTAssertEqual(copied.first?.inverse, EditCommand(.numbered(.macro, 6), .delete))

        // Macro 2 is the startup macro and a scheduler entry's.
        let macro = try XCTUnwrap(edits.machine.macro(2))
        let deleted = edits.apply("edit macro 2 delete")
        XCTAssertNil(edits.machine.macro(2))
        XCTAssertEqual(deleted.first?.structure, [.removeDocument(.machineMacro(2), path: "macros/002-preshow.json")])
        XCTAssertEqual(deleted.first?.inverse, EditCommand(.numbered(.macro, 2), .create(body: try JSONCoding.encode(macro), folder: nil, title: nil)))
        XCTAssertTrue(deleted.first?.warnings.first?.hasPrefix("macro 2 is still named by 2 references") == true, deleted.first?.warnings.first ?? "")
        assertRoundTrip(["edit macro 2 delete"], writable: false)
        assertRoundTrip(["edit macro create", "edit macro 2 duplicate", "edit macro 1 delete"])
    }

    func test_renumberAndSwapCarryTheReferencesAndTheFiles() {
        var edits = Edits()
        let renumbered = edits.apply("edit macro 2 renumber 6")
        XCTAssertEqual(edits.machine.settings.startupMacro, 6)
        XCTAssertEqual(edits.machine.keys[5].command, .macro(6))
        XCTAssertEqual(edits.machine.documentPaths["macro/6"], "macros/002-preshow.json")
        XCTAssertNil(edits.machine.documentPaths["macro/2"])
        XCTAssertEqual(renumbered.first?.inverse, EditCommand(.numbered(.macro, 6), .renumber(to: 2)))
        XCTAssertEqual(edits.refuse("edit macro 6 renumber 1")?.reason, .duplicate, "the library's macro 1 has that number")

        // Macro 1 is run by list 7's third cue.
        edits.apply("edit macro 1 swap 6")
        XCTAssertEqual(edits.library.macro(6)?.label, "Welcome")
        XCTAssertEqual(edits.machine.macro(1)?.label, "Preshow")
        XCTAssertEqual(edits.library.list(number: 7)?.cues[2].commands[1].command, .macro(6))
        XCTAssertEqual(edits.machine.settings.startupMacro, 1)
        XCTAssertEqual(edits.library.documentPaths["macro/6"], "macros/001-welcome.json")
        XCTAssertEqual(edits.machine.documentPaths["macro/1"], "macros/002-preshow.json")
        assertRoundTrip(["edit macro 2 renumber 6", "edit macro 1 swap 6"])
    }
}
