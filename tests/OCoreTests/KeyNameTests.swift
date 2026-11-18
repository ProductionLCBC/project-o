import XCTest
@testable import OCore

/// Spec 10 §9, "Key names" — "A binding's `key` is a key name, after any
/// modifiers, joined by `+` in the order `ctrl`, `alt`, `shift`: `space`,
/// `right`, `shift+escape`, `ctrl+alt+f`. ... Some keys are reserved and
/// can't be bound ... The engine refuses a binding of a reserved key, or a
/// key name outside this grammar, with `badValue` (Spec 5 §6), so an import
/// can't bring one in."
final class KeyNameTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_theSpecsExamplesRead() throws {
        XCTAssertEqual(KeyName("space"), KeyName(key: "space"))
        XCTAssertEqual(KeyName("right"), KeyName(key: "right"))
        XCTAssertEqual(KeyName("shift+escape"), KeyName(key: "escape", shift: true))
        XCTAssertEqual(KeyName("ctrl+alt+f"), KeyName(key: "f", ctrl: true, alt: true))
        XCTAssertEqual(try XCTUnwrap(KeyName("ctrl+alt+shift+f12")).text, "ctrl+alt+shift+f12")
    }

    /// "The names are `a` to `z`, `0` to `9`, `f1` to `f20`, `space`,
    /// `return`, `escape`, `tab`, `delete`, `forwarddelete`, `left`,
    /// `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, the
    /// keypad's `pad0` to `pad9`, `padenter`, `padplus`, `padminus`,
    /// `padstar`, `padslash`, `paddot` and `padequals`, and the punctuation
    /// keys by their unshifted US character".
    func test_theNamesAreTheSpecsAndNoOthers() {
        var names: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        names += (0...9).map { "\($0)" }
        names += (1...20).map { "f\($0)" }
        names += ["space", "return", "escape", "tab", "delete", "forwarddelete", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
        names += (0...9).map { "pad\($0)" }
        names += ["padenter", "padplus", "padminus", "padstar", "padslash", "paddot", "padequals"]
        names += ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        XCTAssertEqual(KeyName.keys, names)
        XCTAssertEqual(KeyName.keys.count, 98)
        XCTAssertEqual(Set(KeyName.keys).count, 98, "no name twice")
    }

    /// `parse(print(x)) == x`, for every key under every set of modifiers.
    func test_everyKeyNameUnderEveryModifierPrintsAndReadsBack() throws {
        var count = 0
        for key in KeyName.keys {
            for bits in 0..<8 {
                let name = try XCTUnwrap(KeyName(key: key, ctrl: bits & 1 != 0, alt: bits & 2 != 0, shift: bits & 4 != 0))
                XCTAssertEqual(KeyName(name.text), name, name.text)
                count += 1
            }
        }
        XCTAssertEqual(count, 98 * 8)
        XCTAssertNil(KeyName(key: "enter"), "a name the grammar doesn't have makes no key name")
    }

    /// Area 13 reading — the grammar is exact: lower case, the modifiers in
    /// the spec's order, each once, nothing around the `+`. A file's key
    /// that reads another way is outside it, so no two spellings name one key.
    func test_whatIsOutsideTheGrammarIsNotAKeyName() {
        let outside = ["", "+", "shift+", "+a", "a+b", "shift+ctrl+f", "alt+ctrl+f", "shift+alt+f", "shift+shift+a", "cmd+q", "command+q", "meta+a",
                       "Space", "SHIFT+escape", "Shift+Escape", "A", "f0", "f21", "pad10", "enter", "esc", "backspace", "del", " space", "space ",
                       "shift + a", "shift++a", "plus", "~", "!", "é", "numpad1", "capslock", "fn+f1", "ctrl"]
        for text in outside {
            XCTAssertNil(KeyName(text), "\"\(text)\"")
            XCTAssertEqual(KeyName.bindable(text), .failure(.notAKeyName), "\"\(text)\"")
        }
    }

    /// "Some keys are reserved and can't be bound: ⌘-combinations belong to
    /// the menus; Tab, ⇧Tab, ⌥ with the arrows, ⌥Return, ⌥Space and ⌃Return
    /// are the keyboard's navigation (§15); plain `escape` leaves fields and
    /// closes things; and ⌃⌥⌘⎋ is fixed".
    func test_theReservedKeysCannotBeBound() {
        let reserved = ["escape", "tab", "shift+tab", "alt+left", "alt+right", "alt+up", "alt+down", "alt+return", "alt+space", "ctrl+return"]
        for text in reserved {
            XCTAssertEqual(KeyName(text)?.isReserved, true, text)
            XCTAssertEqual(KeyName.bindable(text), .failure(.reserved), text)
        }
        // ⌘ has no word in the grammar, so a ⌘-combination, ⌃⌥⌘⎋ among them, can't be written at all.
        XCTAssertEqual(KeyName.bindable("ctrl+alt+cmd+escape"), .failure(.notAKeyName))
    }

    /// Area 13 reading — reserved is the chords the spec names and no
    /// others: the same key under another modifier is a different chord.
    func test_everyOtherChordCanBeBound() throws {
        let free = ["space", "return", "left", "right", "up", "down", "shift+escape", "ctrl+escape", "shift+space", "shift+return", "shift+left",
                    "ctrl+left", "alt+shift+left", "ctrl+alt+left", "ctrl+tab", "alt+tab", "alt+f", "ctrl+space", "ctrl+alt+return", "padenter", "f1", "`"]
        for text in free {
            let name = try XCTUnwrap(KeyName(text), text)
            XCTAssertFalse(name.isReserved, text)
            XCTAssertEqual(KeyName.bindable(text), .success(name), text)
        }
        var reserved: [String] = []
        for key in KeyName.keys {
            for bits in 0..<8 {
                let name = try XCTUnwrap(KeyName(key: key, ctrl: bits & 1 != 0, alt: bits & 2 != 0, shift: bits & 4 != 0))
                if name.isReserved { reserved.append(name.text) }
            }
        }
        XCTAssertEqual(reserved.count, 10, "ten chords in all: \(reserved)")
    }

    /// Spec 10 §9, "Digit entry" — "an unbound digit key, on the top row or
    /// the keypad"; "When bindings fire", 4 — "the function keys `f1` to `f20`".
    func test_aKeySaysWhetherItIsADigitAFunctionKeyOrReturn() {
        XCTAssertEqual((0...9).map { KeyName("\($0)")?.digit }, (0...9).map { Optional($0) })
        XCTAssertEqual((0...9).map { KeyName("pad\($0)")?.digit }, (0...9).map { Optional($0) })
        XCTAssertNil(KeyName("shift+1")?.digit, "a digit under a modifier is another chord")
        XCTAssertNil(KeyName("a")?.digit)
        XCTAssertNil(KeyName("f1")?.digit)
        XCTAssertEqual(KeyName("f1")?.isFunctionKey, true)
        XCTAssertEqual(KeyName("shift+f20")?.isFunctionKey, true)
        XCTAssertEqual(KeyName("f")?.isFunctionKey, false)
        XCTAssertEqual(KeyName("pad1")?.isFunctionKey, false)
        XCTAssertEqual(KeyName("return")?.isPlain, true)
        XCTAssertEqual(KeyName("shift+return")?.isPlain, false)
    }

    /// Spec 10 §9, "Defaults" (R1) — and Spec 10 §16, "Fixtures": the
    /// fixture's clear-all sits on `shift+escape`, which can be bound.
    func test_theDefaultsAndTheFixturesKeyboardRowsAreKeyNamesThatCanBeBound() throws {
        XCTAssertEqual(FirstRun.keys.map { $0.key ?? "" }, ["space", "right", "left", "shift+escape"])
        for binding in FirstRun.keys + F.load().machine.keys where binding.device == "keyboard" {
            let key = try XCTUnwrap(binding.key)
            let name = try XCTUnwrap(KeyName(key), key)
            XCTAssertEqual(KeyName.bindable(key), .success(name), key)
        }
    }
}
