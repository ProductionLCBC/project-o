import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 10 §9, "Key names" — "A key is matched by its position, named as on
/// a US keyboard, so a binding stays on its key whatever the input source."
final class KeyPositionTableTests: XCTestCase {
    func test_everyKeyNameHasOnePositionAndNoTwoShareOne() {
        XCTAssertEqual(Set(KeyPositions.codes.keys), Set(KeyName.keys), "the table names §9's keys and no others")
        XCTAssertEqual(Set(KeyPositions.codes.values).count, KeyName.keys.count, "no position has two names")
        for key in KeyName.keys {
            let code = KeyPositions.code(of: key)
            XCTAssertNotNil(code, key)
            XCTAssertEqual(code.flatMap(KeyPositions.name), key, key)
        }
    }

    /// The positions macOS gives the keys of a US keyboard (its virtual key
    /// codes); `KeyCodeTests`, among the view tests, checks every one of the
    /// table's against the system's own constants.
    func test_thePositionsAreTheMacsOwn() {
        let known: [String: UInt16] = ["a": 0, "s": 1, "q": 12, "1": 18, "0": 29, "return": 36, "tab": 48, "space": 49, "`": 50, "delete": 51, "escape": 53,
                                       "pad0": 82, "pad9": 92, "padenter": 76, "f1": 122, "f12": 111, "f20": 90, "left": 123, "right": 124, "down": 125,
                                       "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117, "\\": 42, "/": 44]
        for (key, code) in known { XCTAssertEqual(KeyPositions.code(of: key), code, key) }
    }

    /// Area 13 reading — a key §9 has no name for can't be bound: the ISO
    /// keyboard's key beside the left Shift, the keypad's Clear, a JIS
    /// keyboard's own keys, Help.
    func test_aKeyTheSpecHasNoNameForHasNone() {
        for code: UInt16 in [0x0A, 0x47, 0x5D, 0x5E, 0x5F, 0x66, 0x68, 0x72, 0x34, 0x7F, 200] {
            XCTAssertNil(KeyPositions.name(code: code), "\(code)")
            XCTAssertNil(KeyStroke(code: code).name, "\(code)")
        }
    }

    func test_aPressNamesItsKeyWithWhatWasHeld() {
        XCTAssertEqual(KeyStroke(code: 49).name?.text, "space")
        XCTAssertEqual(KeyStroke(code: 53, shift: true).name?.text, "shift+escape")
        XCTAssertEqual(KeyStroke(code: 3, ctrl: true, alt: true).name?.text, "ctrl+alt+f")
        // ⌘ isn't part of a key name: the press says it was held, and the router keeps it from the table.
        XCTAssertEqual(KeyStroke(code: 12, command: true).name?.text, "q")
        XCTAssertEqual(KeyStroke("shift+escape"), KeyStroke(code: 53, shift: true))
        XCTAssertNil(KeyStroke("cmd+q"))
    }
}

/// Spec 10 §9 — "The app reads the table and sends a binding's command with
/// source `key` when its key is pressed"; "Safeguards".
final class BindingTableTests: XCTestCase {
    private func key(_ text: String) throws -> KeyName { try XCTUnwrap(KeyName(text)) }

    func test_theRecordedCatalogsKeyboardRowsAreTheDefaults() throws {
        let table = BindingTable(try Recorded.catalog().keys)
        XCTAssertEqual(table.rows.map(\.key.text), ["space", "right", "left", "shift+escape"])
        XCTAssertEqual(table.rows.map(\.binding.command), [.next, .next, .previous, .systemClearAll])
        XCTAssertEqual(table.ignored, [], "a Stream Deck's row and the scheduler's aren't the keyboard's, and aren't mistakes")
        XCTAssertEqual(table.missing, [])
        XCTAssertEqual(table.binding(for: try key("space"))?.command, .next)
        XCTAssertNil(table.binding(for: try key("shift+space")), "another chord is another key")
        XCTAssertNil(table.binding(for: try key("b")))
    }

    /// "In v1 the device is the keyboard; MIDI and Stream Deck devices and the scheduler's rows are v1.5."
    func test_onlyTheKeyboardsRowsAreRead() {
        let table = BindingTable([
            KeyBinding(device: "streamdeck:AL12K3", key: "button 1", command: .next),
            KeyBinding(device: "midi:1", key: "space", command: .next),
            KeyBinding(device: "scheduler", when: Schedule(days: ["sunday"], time: "09:55"), command: .macro(2)),
            KeyBinding(device: "keyboard", key: "f5", command: .macro(1)),
        ])
        XCTAssertEqual(table.rows.map(\.key.text), ["f5"])
        XCTAssertEqual(table.ignored, [])
    }

    /// Area 13 reading — a row the engine would have refused is left out and
    /// kept to be listed, and of two rows on one key the first is the binding.
    func test_aRowThatCannotBeABindingIsLeftOutAndListed() throws {
        let table = BindingTable([
            KeyBinding(device: "keyboard", key: "space", command: .next),
            KeyBinding(device: "keyboard", key: "escape", command: .systemClearAll),
            KeyBinding(device: "keyboard", key: "Shift+Escape", command: .systemClearAll),
            KeyBinding(device: "keyboard", key: "space", command: .previous),
            KeyBinding(device: "keyboard", key: nil, command: .previous),
            KeyBinding(device: "keyboard", key: "alt+left", command: .previous),
        ])
        XCTAssertEqual(table.rows.map(\.key.text), ["space"])
        XCTAssertEqual(table.binding(for: try key("space"))?.command, .next, "the first row on a key")
        XCTAssertEqual(table.ignored, [.init(key: "escape", reason: .reserved), .init(key: "Shift+Escape", reason: .notAKeyName),
                                       .init(key: "space", reason: .repeated), .init(key: "", reason: .notAKeyName),
                                       .init(key: "alt+left", reason: .reserved)])
    }

    /// "Settings ▸ Key bindings and the keys overlay warn when nothing is bound to `next` or to `system clearall`".
    func test_theSafeguardsSayWhatNothingIsBoundTo() {
        XCTAssertEqual(BindingTable().missing, [.next, .clearAll])
        XCTAssertEqual(BindingTable([KeyBinding(device: "keyboard", key: "space", command: .next)]).missing, [.clearAll])
        XCTAssertEqual(BindingTable([KeyBinding(device: "keyboard", key: "shift+escape", command: .systemClearAll)]).missing, [.next])
        // A binding the app leaves out guards nothing.
        XCTAssertEqual(BindingTable([KeyBinding(device: "keyboard", key: "escape", command: .systemClearAll),
                                     KeyBinding(device: "streamdeck:1", key: "button 1", command: .next)]).missing, [.next, .clearAll])
        XCTAssertEqual(BindingTable(FirstRun.keys).missing, [], "first run's defaults (R1) bind both")
    }
}

/// Spec 10 §9, "When bindings fire" — "a key goes to the first of these that
/// is open or has the focus, and to the bindings only when none of them
/// takes it", and Spec 10 §18, "Area 13, the keys".
final class KeyRouterTests: XCTestCase {
    /// The defaults, with Return, ⌃G, F5, ⇧A, ⌥B and a digit bound beside them.
    private let table = BindingTable(FirstRun.keys + [
        KeyBinding(device: "keyboard", key: "ctrl+g", command: .macro(1)),
        KeyBinding(device: "keyboard", key: "f5", command: .macro(2)),
        KeyBinding(device: "keyboard", key: "shift+a", command: .macro(3)),
        KeyBinding(device: "keyboard", key: "alt+b", command: .macro(4)),
        KeyBinding(device: "keyboard", key: "7", command: .macro(7)),
        KeyBinding(device: "keyboard", key: "delete", command: .macro(8)),
        KeyBinding(device: "keyboard", key: "up", command: .macro(9)),
    ])

    private func route(_ key: String, _ context: KeyContext = KeyContext(), command: Bool = false, isRepeat: Bool = false,
                       table: BindingTable? = nil, file: StaticString = #filePath, line: UInt = #line) -> KeyRoute {
        guard let stroke = KeyStroke(key, command: command, isRepeat: isRepeat) else {
            XCTFail("\(key) is not a key name", file: file, line: line)
            return .nothing
        }
        return KeyRouter.route(stroke, table: table ?? self.table, context: context)
    }

    private func fires(_ route: KeyRoute) -> Command? {
        if case .fire(let binding) = route { return binding.command }
        return nil
    }

    // MARK: With nothing open

    func test_aBoundKeyFiresItsBindingOnItsFirstPressOnly() {
        XCTAssertEqual(fires(route("space")), .next)
        XCTAssertEqual(fires(route("right")), .next)
        XCTAssertEqual(fires(route("left")), .previous)
        XCTAssertEqual(fires(route("shift+escape")), .systemClearAll)
        // "the repeats of a held key never fire it again, so holding Space sends one `next`": the repeat goes nowhere else either.
        XCTAssertEqual(route("space", isRepeat: true), .nothing)
        XCTAssertEqual(route("shift+escape", isRepeat: true), .nothing)
    }

    func test_commandCombinationsNeverReachTheTable() {
        let all = BindingTable(KeyName.keys.map { KeyBinding(device: "keyboard", key: $0, command: .next) })
        for key in ["q", "l", "1", "k", "/", "space", "z"] {
            XCTAssertEqual(route(key, command: true, table: all), .passed, "⌘\(key) is the menus'")
        }
        XCTAssertEqual(route("shift+z", command: true, table: all), .passed)
    }

    func test_plainEscapeNeverSendsACommand() {
        // Even from a table that binds it, which the engine refuses and a file edited by hand might hold.
        XCTAssertEqual(BindingTable([KeyBinding(device: "keyboard", key: "escape", command: .systemClearAll)]).rows, [])
        XCTAssertEqual(route("escape"), .nothing)
        XCTAssertEqual(route("escape", KeyContext(overlay: true)), .escape(.overlay), "it closes the keys overlay")
        XCTAssertEqual(route("escape", KeyContext(digitsWaiting: true)), .escape(.digits), "it clears the digits")
        for context in [KeyContext(), KeyContext(sheet: true), KeyContext(field: .goTo), KeyContext(field: .other), KeyContext(dialog: true),
                        KeyContext(recorder: true), KeyContext(menu: true), KeyContext(overlay: true), KeyContext(editFocus: true)] {
            XCTAssertNil(fires(route("escape", context)), "\(context)")
        }
    }

    func test_aKeyWithNothingBoundDoesNothingAndTheKeyboardsNavigationIsPassedOn() {
        XCTAssertEqual(route("b"), .nothing)
        XCTAssertEqual(route("return"), .nothing, "Return, unbound and with no digits waiting")
        XCTAssertEqual(route("shift+space"), .nothing)
        // §15's navigation is reserved, so it is never bound: the focused control has it.
        for key in ["tab", "shift+tab", "alt+left", "alt+right", "alt+up", "alt+down", "alt+return", "alt+space", "ctrl+return"] {
            XCTAssertEqual(route(key), .passed, key)
        }
        XCTAssertEqual(KeyRouter.route(KeyStroke(code: 0x0A), table: table, context: KeyContext()), .nothing, "a key with no name")
        XCTAssertEqual(KeyRouter.route(KeyStroke(code: 0x0A), table: table, context: KeyContext(field: .search)), .passed, "typed, in a field")
    }

    // MARK: 1 and 2, the recorder and an open menu

    func test_theKeyRecorderTakesEveryKeyAndFiresNothing() {
        for key in ["space", "shift+escape", "escape", "f5", "ctrl+g", "7", "return"] {
            XCTAssertEqual(route(key, KeyContext(recorder: true)), .passed, key)
        }
    }

    func test_anOpenMenuTakesEveryKeyShiftEscapeIncluded() {
        for key in ["space", "shift+escape", "escape", "f5", "ctrl+g", "7"] {
            XCTAssertEqual(route(key, KeyContext(menu: true)), .passed, key)
        }
    }

    // MARK: 3, a file dialog

    /// "→ and Space in the Import… dialog send nothing while ⇧⎋ still fires".
    func test_aFileDialogTakesEveryKeyButShiftEscape() {
        let dialog = KeyContext(dialog: true, sheet: true)
        for key in ["right", "space", "left", "f5", "ctrl+g", "7", "return", "escape", "b"] {
            XCTAssertEqual(route(key, dialog), .passed, key)
        }
        XCTAssertEqual(fires(route("shift+escape", dialog)), .systemClearAll)
        // The dialog's own field has the cursor: the dialog's rule holds, not a field's.
        XCTAssertEqual(route("ctrl+g", KeyContext(dialog: true, field: .other, sheet: true)), .passed)
        XCTAssertEqual(fires(route("shift+escape", KeyContext(dialog: true, field: .other, sheet: true))), .systemClearAll)
    }

    // MARK: 4, a text field

    /// "in a field, a `ctrl` or function-key binding fires and a `shift+` character binding types".
    func test_aTextFieldTakesEveryKeyButShiftEscapeAControlBindingAndTheFunctionKeys() {
        for kind in FieldKind.allCases {
            let field = KeyContext(field: kind)
            XCTAssertEqual(fires(route("shift+escape", field)), .systemClearAll, "\(kind)")
            XCTAssertEqual(fires(route("ctrl+g", field)), .macro(1), "\(kind)")
            XCTAssertEqual(fires(route("f5", field)), .macro(2), "\(kind)")
            XCTAssertEqual(route("shift+a", field), .passed, "a `shift+` binding on a character key types: \(kind)")
            XCTAssertEqual(route("alt+b", field), .passed, "and an `alt+` one: \(kind)")
            for key in ["space", "right", "left", "7", "delete", "up", "return", "b", "tab"] {
                XCTAssertEqual(route(key, field), .passed, "\(key) in \(kind)")
            }
            // What isn't bound is the field's, a function key or a ⌃ chord like any other.
            XCTAssertEqual(route("f6", field), .passed, "\(kind)")
            XCTAssertEqual(route("ctrl+a", field), .passed, "\(kind)")
            XCTAssertEqual(route("ctrl+g", field, isRepeat: true), .nothing, "a held binding fires once: \(kind)")
        }
    }

    func test_escapeInAFieldFollowsTheFieldsRule() {
        for kind in FieldKind.allCases where kind != .other {
            XCTAssertEqual(route("escape", KeyContext(field: kind)), .escape(.field(kind)), "\(kind)")
            XCTAssertEqual(route("escape", KeyContext(field: kind, sheet: true)), .escape(.field(kind)), "the field comes before the sheet: \(kind)")
        }
        XCTAssertEqual(route("escape", KeyContext(field: .other)), .passed, "a field the app didn't make keeps its own Escape")
    }

    // MARK: 5, edit mode's focused editors

    func test_inEditModeAFocusedEditorTakesTheArrowsAndTheDeleteKeys() {
        let editing = KeyContext(editFocus: true)
        for key in ["left", "right", "up", "down", "shift+left", "alt+shift+up", "delete", "forwarddelete"] {
            XCTAssertEqual(route(key, editing), .passed, key)
        }
        XCTAssertEqual(fires(route("space", editing)), .next, "every other key is the show's")
        XCTAssertEqual(fires(route("shift+escape", editing)), .systemClearAll)
        XCTAssertEqual(fires(route("left")), .previous, "and outside edit mode the arrows are the show's too")
    }

    // MARK: 6, a sheet or popover

    /// "⇧⎋ fires with a sheet, a popover or a field open"; "A sheet or popover takes Return and plain Escape."
    func test_aSheetOrPopoverTakesReturnAndPlainEscapeAndNothingElse() {
        let sheet = KeyContext(sheet: true)
        let bound = BindingTable(FirstRun.keys + [KeyBinding(device: "keyboard", key: "return", command: .macro(5)),
                                                  KeyBinding(device: "keyboard", key: "padenter", command: .macro(6))])
        XCTAssertEqual(route("return", sheet, table: bound), .passed, "Return is the sheet's, whatever it is bound to")
        XCTAssertEqual(route("padenter", sheet, table: bound), .passed)
        XCTAssertEqual(route("escape", sheet), .passed)
        XCTAssertEqual(fires(route("shift+escape", sheet)), .systemClearAll)
        XCTAssertEqual(fires(route("space", sheet)), .next)
        XCTAssertEqual(fires(route("shift+return", sheet, table: BindingTable([KeyBinding(device: "keyboard", key: "shift+return", command: .next)]))), .next,
                       "⇧Return is another chord")
        XCTAssertEqual(fires(route("return", table: bound)), .macro(5), "with no sheet, Return fires its binding")
    }

    // MARK: Digit entry

    func test_anUnboundDigitGoesToTheGoToFieldAndABoundOneFiresItsBinding() {
        XCTAssertEqual(route("4"), .digit(4))
        XCTAssertEqual(route("pad4"), .digit(4), "on the top row or the keypad")
        XCTAssertEqual(route("0"), .digit(0))
        XCTAssertEqual(fires(route("7")), .macro(7), "a bound digit is a binding (Area 13 reading)")
        XCTAssertEqual(route("pad7"), .digit(7), "the keypad's 7 is another key")
        XCTAssertEqual(route("4", isRepeat: true), .nothing, "a held digit counts once")
        XCTAssertEqual(route("shift+4"), .nothing, "a digit under a modifier isn't a digit")
        XCTAssertEqual(route("4", KeyContext(goToEnabled: false)), .nothing, "with nothing live there is no list to go to")
    }

    /// "digit entry is off with a sheet open".
    func test_digitEntryIsOffWithASheetAPopoverOrTheOverlayOpenAndInAField() {
        XCTAssertEqual(route("4", KeyContext(sheet: true)), .nothing)
        XCTAssertEqual(route("4", KeyContext(overlay: true)), .nothing)
        XCTAssertEqual(route("4", KeyContext(field: .search)), .passed, "typed into the field")
        XCTAssertEqual(route("4", KeyContext(dialog: true, sheet: true)), .passed)
    }

    /// "digit entry with Return bound and unbound": "While digits are waiting, Return completes them whatever Return is bound to."
    func test_returnCompletesWaitingDigitsWhateverItIsBoundTo() {
        let bound = BindingTable(FirstRun.keys + [KeyBinding(device: "keyboard", key: "return", command: .macro(5))])
        let waiting = KeyContext(digitsWaiting: true)
        XCTAssertEqual(route("return", waiting), .completeDigits, "unbound")
        XCTAssertEqual(route("return", waiting, table: bound), .completeDigits, "bound")
        XCTAssertEqual(route("padenter", waiting, table: bound), .completeDigits, "the keypad's Enter, after the keypad's digits")
        XCTAssertEqual(route("return", waiting, isRepeat: true), .nothing)
        XCTAssertEqual(fires(route("return", table: bound)), .macro(5), "with none waiting, Return is its binding")
        XCTAssertEqual(route("return"), .nothing)
        XCTAssertEqual(fires(route("space", waiting)), .next, "another key is still its binding while digits wait")
        XCTAssertEqual(route("shift+return", waiting), .nothing, "⇧Return isn't Return")
    }
}

/// Spec 10 §9, "A text field", and §8's line over a focused field.
final class FieldRuleTests: XCTestCase {
    /// "In a field that edits (in-place text, a rename, a new title, a note,
    /// a Settings field), plain Escape discards what was typed and leaves
    /// the field; in any other field it leaves the field and keeps the text,
    /// apart from the go-to field, which it clears." Spec 10 §18 — "Escape
    /// discards an in-place edit and keeps a popup draft".
    func test_whatEscapeDoesInEachKindOfField() {
        XCTAssertEqual(FieldKind.inPlaceText.escape, .discardAndLeave)
        XCTAssertEqual(FieldKind.edit.escape, .discardAndLeave)
        XCTAssertEqual(FieldKind.editPopover.escape, .discardAndLeave)
        XCTAssertEqual(FieldKind.goTo.escape, .clearAndLeave)
        XCTAssertEqual(FieldKind.row.escape, .leave, "a popup draft is kept")
        XCTAssertEqual(FieldKind.search.escape, .leave)
        XCTAssertEqual(FieldKind.commandBar.escape, .leave)
        XCTAssertEqual(FieldKind.textEditor.escape, .leave)
        XCTAssertEqual(FieldKind.other.escape, .leave)
    }

    /// "A single-line field that acts on Return (the go-to field, a popup or
    /// timer row, a rename, a new title, a note) hands the focus back to the
    /// window when it acts ... Search fields and the command bar keep the
    /// focus until Escape or a click elsewhere."
    func test_whichFieldsHandTheFocusBackWhenReturnActs() {
        XCTAssertEqual(FieldKind.allCases.filter(\.handsFocusBackOnReturn), [.goTo, .row, .edit])
    }

    /// Spec 10 §8 — the four lines the top bar shows over a focused field.
    func test_whatTheTopBarSaysOverEachKindOfField() {
        XCTAssertEqual(FieldKind.inPlaceText.hint, .commandReturnSaves)
        XCTAssertEqual(FieldKind.editPopover.hint, .commandReturnSaves)
        XCTAssertEqual(FieldKind.textEditor.hint, .textEditor)
        XCTAssertEqual(FieldKind.edit.hint, .returnSaves)
        XCTAssertEqual([FieldKind.goTo, .row, .search, .commandBar, .other].map(\.hint), Array(repeating: .typing, count: 5))
    }
}
