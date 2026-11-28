import Foundation
import XCTest
import OCore
@testable import OApp

/// A keys model over the show model's rig: the recorded catalog binds the
/// defaults (Space and → `next`, ← `previous`, ⇧⎋ `system clearall`).
@MainActor
final class KeysRig {
    let show: ShowModelTests.Rig
    let keys: KeysModel
    var changes = 0

    init(connected: Bool = true) throws {
        show = try ShowModelTests.Rig(connected: connected)
        keys = KeysModel(model: show.model, clock: show.clock)
        keys.onChange = { [unowned self] in self.changes += 1 }
    }

    @discardableResult
    func press(_ key: String, _ context: KeyContext = KeyContext(), isRepeat: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> KeyRoute {
        guard let stroke = KeyStroke(key, isRepeat: isRepeat) else {
            XCTFail("\(key) is not a key name", file: file, line: line)
            return .nothing
        }
        return keys.press(stroke, context: context)
    }

    /// The source each request carried.
    var sources: [String] { show.sent.map { $0.fields["source"]?.stringValue ?? "" } }

    /// The catalog again, with more keyboard rows after the recorded ones.
    func bind(_ rows: [(key: String, command: [String: JSONValue])]) throws {
        var catalog = try RecordedAPI.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        var keys = try XCTUnwrap(machine["keys"]?.arrayValue)
        for row in rows {
            keys.append(.object(["device": .string("keyboard"), "key": .string(row.key), "command": .object(row.command)]))
        }
        machine["keys"] = .array(keys)
        catalog["machine"] = .object(machine)
        show.store.apply(catalog: catalog)
    }
}

/// Spec 10 §9 — "The app reads the table and sends a binding's command with
/// source `key` when its key is pressed. Bindings ... fire on a key's first
/// press only: the repeats of a held key never fire it again, so holding
/// Space sends one `next`."
@MainActor
final class KeysModelTests: XCTestCase {
    func test_theTableIsTheCatalogsAndFollowsIt() throws {
        let rig = try KeysRig(connected: false)
        XCTAssertEqual(rig.keys.table.rows, [], "no catalog, no bindings")
        try rig.show.connect()
        XCTAssertEqual(rig.keys.table.rows.map(\.key.text), ["space", "right", "left", "shift+escape"])
        XCTAssertGreaterThan(rig.changes, 0)
        try rig.bind([("f5", ["cmd": .string("macro.run"), "macro": .number(2)])])
        XCTAssertEqual(rig.keys.table.rows.map(\.key.text), ["space", "right", "left", "shift+escape", "f5"])
    }

    func test_holdingSpaceSendsOneNextWithSourceKey() throws {
        let rig = try KeysRig()
        rig.press("space")
        for _ in 0..<20 { rig.press("space", isRepeat: true) }
        XCTAssertEqual(rig.show.commands, [["next"]])
        XCTAssertEqual(rig.sources, ["key"])
    }

    func test_theDefaultsSendWhatTheSpecSays() throws {
        let rig = try KeysRig()
        for key in ["space", "right", "left", "shift+escape"] { rig.press(key) }
        XCTAssertEqual(rig.show.commands, [["next"], ["next"], ["previous"], ["system clearall"]])
        XCTAssertEqual(Set(rig.sources), ["key"])
        XCTAssertEqual(rig.press("escape"), .nothing)
        XCTAssertEqual(rig.press("b"), .nothing)
        XCTAssertEqual(rig.show.sent.count, 4, "plain Escape and an unbound key send nothing")
    }

    /// Spec 10 §18, "Area 13, the engine" — "a key pressed while the engine is away sends nothing later".
    func test_aKeyPressedWhileTheEngineIsAwaySendsNothingThenOrLater() throws {
        let rig = try KeysRig()
        rig.show.store.disconnected()
        rig.press("space")
        rig.press("shift+escape")
        XCTAssertEqual(rig.show.sent.count, 0)
        try rig.show.connect()
        rig.show.clock.advance(by: 10)
        XCTAssertEqual(rig.show.sent.count, 0, "nothing was kept to send")
        rig.press("space")
        XCTAssertEqual(rig.show.commands, [["next"]])
    }

    /// Spec 10 §18 — "⇧⎋ fires with a sheet, a popover or a field open"; "in
    /// a field, a `ctrl` or function-key binding fires and a `shift+`
    /// character binding types".
    func test_whatIsOpenDecidesWhetherAKeyReachesTheBindings() throws {
        let rig = try KeysRig()
        try rig.bind([("ctrl+g", ["cmd": .string("macro.run"), "macro": .number(1)]), ("f5", ["cmd": .string("macro.run"), "macro": .number(2)]),
                      ("shift+a", ["cmd": .string("macro.run"), "macro": .number(3)])])
        for context in [KeyContext(sheet: true), KeyContext(field: .row), KeyContext(dialog: true, sheet: true), KeyContext(overlay: true)] {
            rig.press("shift+escape", context)
        }
        XCTAssertEqual(rig.show.commands, Array(repeating: ["system clearall"], count: 4))
        XCTAssertEqual(rig.press("space", KeyContext(field: .search)), .passed)
        XCTAssertEqual(rig.press("shift+a", KeyContext(field: .search)), .passed)
        XCTAssertEqual(rig.press("right", KeyContext(dialog: true, sheet: true)), .passed)
        XCTAssertEqual(rig.press("shift+escape", KeyContext(menu: true)), .passed)
        XCTAssertEqual(rig.press("shift+escape", KeyContext(recorder: true)), .passed)
        XCTAssertEqual(rig.show.sent.count, 4, "none of those reached the table")
        rig.press("ctrl+g", KeyContext(field: .search))
        rig.press("f5", KeyContext(field: .search))
        XCTAssertEqual(rig.show.commands.suffix(2), [["macro 1"], ["macro 2"]])
    }
}

/// Spec 10 §9, "Digit entry" — "with no field focused, an unbound digit key,
/// on the top row or the keypad, goes into the go-to field, and Return fires
/// `cue N` in the live list. Escape, or three seconds without a key, clears
/// the digits, and a held digit counts once. While digits are waiting,
/// Return completes them whatever Return is bound to. Digit entry is off
/// while a sheet or popover is open."
@MainActor
final class DigitEntryTests: XCTestCase {
    func test_digitsWaitInTheGoToFieldAndReturnFiresThatCue() throws {
        let rig = try KeysRig()
        XCTAssertEqual(rig.press("1"), .digit(1))
        XCTAssertEqual(rig.press("pad4"), .digit(4))
        XCTAssertEqual(rig.keys.digits.digits, "14")
        XCTAssertEqual(rig.show.sent.count, 0, "nothing goes until Return")
        XCTAssertEqual(rig.press("return"), .completeDigits)
        XCTAssertEqual(rig.show.commands, [["cue 14"]])
        XCTAssertEqual(rig.sources, ["key"], "a key fired it (Area 13 reading)")
        XCTAssertFalse(rig.keys.digits.isWaiting)
        XCTAssertEqual(rig.press("return"), .nothing, "Return, unbound and with nothing waiting")
        XCTAssertEqual(rig.show.sent.count, 1)
    }

    func test_theKeypadsEnterCompletesThemToo() throws {
        let rig = try KeysRig()
        rig.press("pad3")
        XCTAssertEqual(rig.press("padenter"), .completeDigits)
        XCTAssertEqual(rig.show.commands, [["cue 3"]])
    }

    func test_aHeldDigitCountsOnce() throws {
        let rig = try KeysRig()
        rig.press("2")
        for _ in 0..<10 { rig.press("2", isRepeat: true) }
        XCTAssertEqual(rig.keys.digits.digits, "2")
    }

    func test_threeSecondsAfterTheLastDigitTheyClear() throws {
        let rig = try KeysRig()
        rig.press("1")
        rig.show.clock.advance(by: 2.9)
        XCTAssertEqual(rig.keys.digits.digits, "1")
        rig.press("2")
        rig.show.clock.advance(by: 2.9)
        XCTAssertEqual(rig.keys.digits.digits, "12", "each digit starts the three seconds again")
        rig.show.clock.advance(by: 0.2)
        XCTAssertFalse(rig.keys.digits.isWaiting)
        XCTAssertEqual(rig.press("return"), .nothing)
        XCTAssertEqual(rig.show.sent.count, 0, "cleared digits fire nothing")
    }

    /// Area 13 reading — "three seconds without a key" is without a digit:
    /// another key fires its binding and leaves the digits their time, so
    /// they never wait longer than three seconds after the last one.
    func test_anotherKeyInBetweenFiresAndDoesNotKeepTheDigitsWaiting() throws {
        let rig = try KeysRig()
        rig.press("1")
        rig.show.clock.advance(by: 2)
        rig.press("space")
        XCTAssertEqual(rig.show.commands, [["next"]])
        XCTAssertEqual(rig.keys.digits.digits, "1")
        rig.show.clock.advance(by: 1.1)
        XCTAssertFalse(rig.keys.digits.isWaiting)
    }

    func test_escapeClearsTheDigitsAndSendsNothing() throws {
        let rig = try KeysRig()
        rig.press("4")
        rig.press("2")
        XCTAssertEqual(rig.press("escape"), .escape(.digits))
        XCTAssertFalse(rig.keys.digits.isWaiting)
        XCTAssertEqual(rig.show.sent.count, 0)
        rig.show.clock.advance(by: 5)
        XCTAssertEqual(rig.press("return"), .nothing)
    }

    /// Spec 10 §18 — "digit entry with Return bound and unbound".
    func test_returnCompletesTheDigitsEvenWhenItIsBound() throws {
        let rig = try KeysRig()
        try rig.bind([("return", ["cmd": .string("macro.run"), "macro": .number(2)])])
        rig.press("return")
        XCTAssertEqual(rig.show.commands, [["macro 2"]], "with nothing waiting, Return is its binding")
        rig.press("3")
        rig.press("return")
        XCTAssertEqual(rig.show.commands, [["macro 2"], ["cue 3"]], "with digits waiting, it completes them and its binding doesn't fire")
        rig.press("return")
        XCTAssertEqual(rig.show.commands.last, ["macro 2"])
    }

    func test_aBoundDigitFiresItsBindingAndNeverWaits() throws {
        let rig = try KeysRig()
        try rig.bind([("7", ["cmd": .string("macro.run"), "macro": .number(7)])])
        XCTAssertEqual(rig.press("1"), .digit(1))
        rig.press("7")
        XCTAssertEqual(rig.keys.digits.digits, "1")
        XCTAssertEqual(rig.show.commands, [["macro 7"]])
    }

    /// Spec 10 §18 — "digit entry is off with a sheet open".
    func test_digitEntryIsOffWithASheetAPopoverOrTheOverlayOpen() throws {
        let rig = try KeysRig()
        for context in [KeyContext(sheet: true), KeyContext(overlay: true)] {
            XCTAssertEqual(rig.press("4", context), .nothing)
        }
        XCTAssertFalse(rig.keys.digits.isWaiting)
    }

    func test_withNothingLiveThereIsNoListToGoTo() throws {
        let rig = try KeysRig(connected: false)
        XCTAssertFalse(rig.show.model.nextRow.goToEnabled)
        XCTAssertEqual(rig.press("4"), .nothing)
        XCTAssertFalse(rig.keys.digits.isWaiting)
    }

    func test_zeroAloneFiresNothingAndAFieldTakingTheFocusClearsWhatWaited() throws {
        let rig = try KeysRig()
        rig.press("0")
        XCTAssertEqual(rig.press("return"), .completeDigits)
        XCTAssertEqual(rig.show.sent.count, 0, "cue numbers start at 1")
        XCTAssertFalse(rig.keys.digits.isWaiting)
        rig.press("0")
        rig.press("5")
        XCTAssertEqual(rig.keys.digits.number, 5)
        XCTAssertEqual(rig.press("b", KeyContext(field: .search)), .passed)
        XCTAssertFalse(rig.keys.digits.isWaiting, "the cursor went into a field")
    }

    func test_theDigitsAsAValue() {
        var entry = DigitEntry()
        XCTAssertNil(entry.number)
        entry.type(4, at: 100)
        entry.type(2, at: 101)
        XCTAssertEqual(entry.digits, "42")
        XCTAssertEqual(entry.number, 42)
        XCTAssertEqual(entry.clearsAt, 104)
        XCTAssertFalse(entry.expire(at: 103.9))
        XCTAssertTrue(entry.expire(at: 104))
        XCTAssertFalse(entry.isWaiting)
        entry.type(12, at: 0)
        XCTAssertFalse(entry.isWaiting, "only a digit is a digit")
        for _ in 0..<30 { entry.type(9, at: 0) }
        XCTAssertNil(entry.number, "more digits than a number holds fire nothing")
    }
}

/// Spec 10 §9, "Fixed keys" — ⌃⌥⌘⎋, and Spec 10 §18 — "⌃⌥⌘⎋ raises the
/// window at once and sends `releaseScreen`, and the window stays raised
/// when the engine doesn't answer."
@MainActor
final class ReleaseScreenTests: XCTestCase {
    @MainActor
    final class Rig {
        let clock = ManualClock()
        let releaser: ScreenReleaser
        var events: [String] = []
        var answers: [(Reply?) -> Void] = []

        init(connected: Bool = true) {
            releaser = ScreenReleaser(clock: clock)
            releaser.onRaised = { [unowned self] in self.events.append($0 ? "raised" : "dropped") }
            releaser.onSilent = { [unowned self] in self.events.append("silent") }
            if connected { connect() }
        }

        func connect() {
            releaser.transmit = { [unowned self] request, answer in
                self.events.append("\(request.type) \(request.fields["screen"]?.stringValue ?? "")")
                self.answers.append(answer)
            }
        }

        func ok(_ index: Int, outputs: [Int] = [1]) {
            answers[index](.result(CommandOutcome(kind: .ok, outputs: outputs)))
        }
    }

    private let main = "display:FA21CBA0-626C-4AE4-A16C-7D56EC3C1175"
    private let side = "display:37D8832A-2D66-02CA-B9F7-8F30A301B230"

    func test_theWindowIsRaisedAtOnceThenTheEngineIsAskedAndItsAnswerDropsTheWindowBack() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        XCTAssertEqual(rig.events, ["raised", "releaseScreen \(main)"], "raised before the engine is asked, not when it answers")
        XCTAssertTrue(rig.releaser.isRaised)
        rig.ok(0)
        XCTAssertEqual(rig.events.last, "dropped")
        XCTAssertFalse(rig.releaser.isRaised)
        XCTAssertEqual(rig.releaser.released, [main], "remembered for `--released` and for the next engine")
        rig.clock.advance(by: 10)
        XCTAssertFalse(rig.events.contains("silent"), "an engine that answered isn't silent")
    }

    /// Spec 10 §9 as corrected 2026-11-24 — "Put Back on This Screen sends `retakeScreen` with it ... and the app
    /// forgets the screen", so neither the next engine nor `--released` takes it off again.
    func test_aScreenPutBackIsAskedOfTheEngineAndForgotten() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.ok(0)
        rig.releaser.release(screen: side)
        rig.releaser.putBack(screen: side.lowercased())
        XCTAssertEqual(Array(rig.events.suffix(2)), ["dropped", "retakeScreen \(side.lowercased())"],
                       "the window drops back from a release still unanswered, and the engine is asked")
        XCTAssertEqual(rig.releaser.released, [main], "the screen named either way is forgotten")
        XCTAssertFalse(rig.releaser.isRaised)
        rig.releaser.connected()
        XCTAssertEqual(rig.events.last, "releaseScreen \(main)", "the next engine is asked for the other screen alone")
    }

    func test_whenTheEngineDoesNotAnswerInTwoSecondsTheWindowStaysRaised() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.clock.advance(by: 1.9)
        XCTAssertEqual(rig.events, ["raised", "releaseScreen \(main)"])
        rig.clock.advance(by: 0.2)
        XCTAssertEqual(rig.events.last, "silent", "the not-responding banner (§2)")
        XCTAssertTrue(rig.releaser.isRaised, "so the way back holds even with the engine stuck")
        rig.clock.advance(by: 60)
        XCTAssertTrue(rig.releaser.isRaised)
        // An answer, however late, is still the engine saying the outputs are off the screen.
        rig.ok(0)
        XCTAssertFalse(rig.releaser.isRaised)
    }

    func test_aRefusalLeavesTheWindowRaisedAndIsNotSilence() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.answers[0](.result(CommandOutcome(kind: .rejected, rejection: EngineRejection(code: "badValue", message: "no such screen"))))
        rig.clock.advance(by: 5)
        XCTAssertTrue(rig.releaser.isRaised, "nothing says the outputs left the screen")
        XCTAssertFalse(rig.events.contains("silent"))
    }

    func test_withNoEngineTheScreenIsRememberedAndTheNextEngineIsAsked() {
        let rig = Rig(connected: false)
        rig.releaser.release(screen: main)
        XCTAssertEqual(rig.events, ["raised"], "nothing to ask")
        XCTAssertEqual(rig.releaser.released, [main])
        rig.clock.advance(by: 30)
        XCTAssertEqual(rig.events, ["raised"], "no engine isn't a silent engine: the banner already says where it stands")
        XCTAssertTrue(rig.releaser.isRaised)
        // "sends `releaseScreen` again to any engine it connects to".
        rig.connect()
        rig.releaser.connected()
        XCTAssertEqual(rig.events.last, "releaseScreen \(main)")
        rig.ok(0)
        XCTAssertFalse(rig.releaser.isRaised)
    }

    func test_everyEngineConnectedToIsAskedAgainForEveryScreenReleased() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.ok(0)
        rig.releaser.release(screen: side)
        rig.ok(1)
        rig.releaser.release(screen: main)
        rig.ok(2)
        XCTAssertEqual(rig.releaser.released, [main, side], "each screen once, in the order released")
        rig.events = []
        rig.releaser.connected()
        XCTAssertEqual(rig.events, ["releaseScreen \(main)", "releaseScreen \(side)"])
        XCTAssertFalse(rig.releaser.isRaised, "asking a new engine again doesn't raise a window that had dropped back")
        rig.ok(3)
        rig.ok(4)
        XCTAssertFalse(rig.events.contains("dropped"))
    }

    func test_theWindowStaysRaisedUntilEveryReleaseIsAnswered() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.releaser.release(screen: side)
        XCTAssertEqual(rig.events.filter { $0 == "raised" }.count, 1)
        rig.ok(0)
        XCTAssertTrue(rig.releaser.isRaised)
        rig.ok(1)
        XCTAssertFalse(rig.releaser.isRaised)
        XCTAssertEqual(rig.events.filter { $0 == "dropped" }.count, 1)
    }

    func test_aConnectionThatClosesBeforeAnsweringLeavesTheWindowRaised() {
        let rig = Rig()
        rig.releaser.release(screen: main)
        rig.answers[0](nil)
        XCTAssertTrue(rig.releaser.isRaised)
    }
}
