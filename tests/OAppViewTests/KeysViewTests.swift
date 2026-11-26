import AppKit
import Carbon.HIToolbox
import XCTest
import OCore
@testable import OApp
@testable import OAppUI

/// Spec 10 §9, "Key names" — "A key is matched by its position": the app's
/// table of positions against the Mac's own constants for them.
final class KeyCodeTests: XCTestCase {
    func test_everyPositionInTheTableIsTheSystemsConstantForThatKey() {
        let system: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10,
            "f11": kVK_F11, "f12": kVK_F12, "f13": kVK_F13, "f14": kVK_F14, "f15": kVK_F15, "f16": kVK_F16, "f17": kVK_F17, "f18": kVK_F18,
            "f19": kVK_F19, "f20": kVK_F20,
            "space": kVK_Space, "return": kVK_Return, "escape": kVK_Escape, "tab": kVK_Tab, "delete": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
            "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "pad0": kVK_ANSI_Keypad0, "pad1": kVK_ANSI_Keypad1, "pad2": kVK_ANSI_Keypad2, "pad3": kVK_ANSI_Keypad3, "pad4": kVK_ANSI_Keypad4,
            "pad5": kVK_ANSI_Keypad5, "pad6": kVK_ANSI_Keypad6, "pad7": kVK_ANSI_Keypad7, "pad8": kVK_ANSI_Keypad8, "pad9": kVK_ANSI_Keypad9,
            "padenter": kVK_ANSI_KeypadEnter, "padplus": kVK_ANSI_KeypadPlus, "padminus": kVK_ANSI_KeypadMinus, "padstar": kVK_ANSI_KeypadMultiply,
            "padslash": kVK_ANSI_KeypadDivide, "paddot": kVK_ANSI_KeypadDecimal, "padequals": kVK_ANSI_KeypadEquals,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "`": kVK_ANSI_Grave,
        ]
        XCTAssertEqual(Set(system.keys), Set(KeyName.keys), "every key name of Spec 10 §9")
        for (key, code) in system {
            XCTAssertEqual(KeyPositions.code(of: key), UInt16(code), key)
        }
        // The keys the spec has no name for: the ISO keyboard's extra key, the keypad's Clear, a JIS keyboard's own.
        for code in [kVK_ISO_Section, kVK_ANSI_KeypadClear, kVK_JIS_Yen, kVK_JIS_Underscore, kVK_JIS_KeypadComma, kVK_JIS_Eisu, kVK_JIS_Kana, kVK_Help] {
            XCTAssertNil(KeyPositions.name(code: UInt16(code)), "\(code)")
        }
    }
}

/// A fake for ⌃⌥⌘⎋'s registration: no test takes a key from the whole Mac.
@MainActor
final class FakeReleaseKey: ReleaseKey {
    var gives = true
    private(set) var pressed: (@MainActor () -> Void)?
    private(set) var registrations = 0

    func register(_ pressed: @escaping @MainActor () -> Void) -> Bool {
        registrations += 1
        self.pressed = gives ? pressed : nil
        return gives
    }

    func unregister() { pressed = nil }

    /// The operator presses ⌃⌥⌘⎋, wherever the keys are.
    func press() { pressed?() }
}

/// Spec 10 §9 and §18, "Area 13, the keys" — the keys read as the window
/// reads them: a key-down event handed to the app's key tap, with what is
/// focused in a window laid out on no screen.
@MainActor
final class KeysViewTests: XCTestCase {
    typealias Rig = ShowWindowTests.Rig

    override func setUp() async throws {
        try await MainActor.run { try ViewStrings.install() }
    }

    /// A key-down as the system would hand it over.
    private func event(_ key: String, command: Bool = false, isRepeat: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        let stroke = try XCTUnwrap(KeyStroke(key, command: command, isRepeat: isRepeat), "\(key) is not a key name", file: file, line: line)
        var flags: NSEvent.ModifierFlags = []
        if stroke.ctrl { flags.insert(.control) }
        if stroke.alt { flags.insert(.option) }
        if stroke.shift { flags.insert(.shift) }
        if stroke.command { flags.insert(.command) }
        return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                              characters: "", charactersIgnoringModifiers: "", isARepeat: isRepeat, keyCode: stroke.code),
                             file: file, line: line)
    }

    /// Presses a key; says whether the app took it.
    @discardableResult
    private func press(_ key: String, in rig: Rig, command: Bool = false, isRepeat: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws -> Bool {
        rig.window.keyTap.take(try event(key, command: command, isRepeat: isRepeat, file: file, line: line))
    }

    /// Types into the field that has the cursor, as the keyboard would.
    private func type(_ text: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        let editor = try XCTUnwrap(rig.window.window.firstResponder as? NSTextView, "no field has the cursor", file: file, line: line)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func sources(_ rig: Rig) -> [String] { rig.sent.map { $0.fields["source"]?.stringValue ?? "" } }

    /// Whether the show has the keys: the window or its regions, which take no typing, and no field.
    private func hasKeys(_ rig: Rig) -> Bool {
        let responder = rig.window.window.firstResponder
        return responder === rig.view || responder === rig.window.window
    }

    // MARK: - The event

    func test_aKeyDownIsReadAsItsPositionWhatWasHeldAndWhetherItRepeats() throws {
        let plain = KeyTap.stroke(try event("space"))
        XCTAssertEqual(plain, KeyStroke(code: 49))
        XCTAssertEqual(KeyTap.stroke(try event("ctrl+alt+shift+f5")), KeyStroke(code: 96, ctrl: true, alt: true, shift: true))
        XCTAssertEqual(KeyTap.stroke(try event("q", command: true)).command, true)
        XCTAssertEqual(KeyTap.stroke(try event("space", isRepeat: true)).isRepeat, true)
        // Caps Lock, Fn and the keypad's own flag aren't part of a key name (Area 13 reading).
        let noisy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.capsLock, .function, .numericPad, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 123))
        XCTAssertEqual(KeyTap.stroke(noisy).name?.text, "shift+left")
    }

    // MARK: - Bindings

    /// "Holding Space sends one `next`".
    func test_holdingSpaceSendsOneNext() throws {
        let rig = try Rig()
        XCTAssertTrue(try press("space", in: rig))
        for _ in 0..<15 { XCTAssertTrue(try press("space", in: rig, isRepeat: true), "the repeat is the app's too, and does nothing") }
        XCTAssertEqual(rig.commands, [["next"]])
        XCTAssertEqual(sources(rig), ["key"])
    }

    func test_theDefaultKeysAndWhatTheAppLeavesAlone() throws {
        let rig = try Rig()
        for key in ["right", "left", "shift+escape"] { XCTAssertTrue(try press(key, in: rig)) }
        XCTAssertEqual(rig.commands, [["next"], ["previous"], ["system clearall"]])
        // "⌘-combinations never reach the table": they go on to the menus.
        XCTAssertFalse(try press("q", in: rig, command: true))
        XCTAssertFalse(try press("space", in: rig, command: true))
        // The keyboard's navigation goes on to the window (§15).
        XCTAssertFalse(try press("tab", in: rig))
        XCTAssertFalse(try press("alt+space", in: rig))
        // "plain Escape never sends a command"; an unbound key is taken, so the Mac doesn't sound its alert.
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertTrue(try press("b", in: rig))
        XCTAssertEqual(rig.sent.count, 3)
    }

    // MARK: - Text fields (Spec 10 §9, "A text field")

    /// "in a field, a `ctrl` or function-key binding fires and a `shift+`
    /// character binding types"; "⇧⎋ fires with ... a field open".
    func test_inASearchFieldTypingIsTheFieldsAndShiftEscapeStillFires() throws {
        let rig = try Rig()
        let window = rig.window.window
        XCTAssertTrue(window.makeFirstResponder(rig.view.left.search))
        XCTAssertEqual(rig.window.keyTap.context().field, .search)
        for key in ["space", "right", "left", "b", "4", "return", "shift+a"] {
            XCTAssertFalse(try press(key, in: rig), "\(key) is the field's")
        }
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertTrue(try press("shift+escape", in: rig))
        XCTAssertEqual(rig.commands, [["system clearall"]])
        XCTAssertFalse(hasKeys(rig), "and the cursor stays where it was")
    }

    /// Spec 10 §8 — "while a text field has the focus, what its keys do".
    func test_theTopBarSaysWhatAFocusedFieldsKeysDo() throws {
        for transform in [{ $0 }, Pseudolanguage.accented, Pseudolanguage.longer] as [(String) -> String] {
            try ViewStrings.install(transform: transform)
            let rig = try Rig()
            let window = rig.window.window
            let hint = rig.view.topBar.hint
            XCTAssertTrue(hint.isHidden, "no field has the focus")
            XCTAssertTrue(window.makeFirstResponder(rig.view.grid.search))
            rig.view.layoutSubtreeIfNeeded()
            XCTAssertFalse(hint.isHidden)
            XCTAssertEqual(hint.stringValue, transform("Typing: Esc for show keys"))
            XCTAssertFalse(Audit.isCutOff(hint), "\"\(hint.stringValue)\" is clipped")
            XCTAssertTrue(window.makeFirstResponder(rig.view.nextRow.goTo))
            XCTAssertEqual(hint.stringValue, transform("Typing: Esc for show keys"), "the go-to field sends a command, and edits nothing")
            window.handKeysBack()
            XCTAssertTrue(hint.isHidden)
        }
        try ViewStrings.install()
    }

    /// "in any other field it leaves the field and keeps the text".
    func test_escapeLeavesASearchFieldAndKeepsItsText() throws {
        let rig = try Rig()
        let search = rig.view.grid.search
        XCTAssertTrue(rig.window.window.makeFirstResponder(search))
        try type("verse", in: rig)
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertTrue(hasKeys(rig), "the keys are the show's again")
        XCTAssertEqual(search.stringValue, "verse")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertTrue(try press("space", in: rig))
        XCTAssertEqual(rig.commands, [["next"]])
    }

    /// "apart from the go-to field, which it clears".
    func test_escapeClearsTheGoToFieldAndFiresNothing() throws {
        let rig = try Rig()
        let goTo = rig.view.nextRow.goTo
        XCTAssertTrue(rig.window.window.makeFirstResponder(goTo))
        try type("14", in: rig)
        XCTAssertEqual(goTo.stringValue, "14")
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertEqual(goTo.stringValue, "")
        XCTAssertTrue(hasKeys(rig))
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// Spec 10 §18 — "Escape ... keeps a popup draft".
    func test_escapeKeepsAPopupDraftAndSendsNothing() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        rig.view.tabs.show(.popups)
        let draft = try XCTUnwrap(Audit.all(DraftField.self, in: rig.view.tabs).first)
        XCTAssertTrue(rig.window.window.makeFirstResponder(draft))
        XCTAssertEqual(rig.window.keyTap.context().field, .row)
        try type("Nursery: 14", in: rig)
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertTrue(hasKeys(rig))
        XCTAssertEqual(draft.stringValue, "Nursery: 14", "the draft is kept")
        XCTAssertEqual(rig.sent.count, 0, "leaving a row's field sends nothing")
    }

    /// A click elsewhere leaves a row's field too, and no more sends its draft than Escape does.
    func test_leavingARowsFieldByAClickElsewhereSendsNothing() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        rig.view.tabs.show(.popups)
        let draft = try XCTUnwrap(Audit.all(DraftField.self, in: rig.view.tabs).first)
        XCTAssertTrue(rig.window.window.makeFirstResponder(draft))
        try type("Car lights on", in: rig)
        let elsewhere = rig.view.grid.convert(NSPoint(x: rig.view.grid.bounds.midX, y: rig.view.grid.bounds.midY), to: nil)
        rig.window.window.handKeysBack(ifClickedOutsideAFieldAt: elsewhere)
        XCTAssertTrue(hasKeys(rig))
        XCTAssertEqual(draft.stringValue, "Car lights on")
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// Spec 10 §18 — "after Send in a popup row, Space sends `next`".
    func test_afterSendInAPopupRowSpaceSendsNext() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        rig.view.tabs.show(.popups)
        let draft = try XCTUnwrap(Audit.all(DraftField.self, in: rig.view.tabs).first)
        XCTAssertTrue(rig.window.window.makeFirstResponder(draft))
        try type("Nursery: 14", in: rig)
        XCTAssertFalse(try press("space", in: rig), "while it is typed in, Space is a space")
        // Return in the row's field is Send.
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(draft.action), to: draft.target, from: draft))
        XCTAssertEqual(rig.commands, [["popup 1 set \"Nursery: 14\""]])
        XCTAssertTrue(hasKeys(rig), "the field handed the focus back when it acted")
        XCTAssertTrue(try press("space", in: rig))
        XCTAssertEqual(rig.commands.last, ["next"])
    }

    func test_returnInATimersFieldSetsItAndHandsTheFocusBack() throws {
        let rig = try Rig(size: NSSize(width: 1440, height: 1100))
        rig.view.tabs.show(.popups)
        let duration = try XCTUnwrap(Audit.all(DraftField.self, in: rig.view.tabs).dropFirst(4).first)
        XCTAssertTrue(rig.window.window.makeFirstResponder(duration))
        try type("5:00", in: rig)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(duration.action), to: duration.target, from: duration))
        XCTAssertEqual(rig.commands, [["timer 1 set 5:00"]])
        XCTAssertTrue(hasKeys(rig))
    }

    // MARK: - Digit entry

    func test_digitsTypedWithNoFieldFocusedShowInTheGoToFieldAndReturnFiresThatCue() throws {
        let rig = try Rig()
        let row = rig.view.nextRow
        XCTAssertTrue(try press("1", in: rig))
        XCTAssertTrue(try press("pad4", in: rig))
        XCTAssertEqual(row.goTo.stringValue, "14", "the digits go into the go-to field")
        XCTAssertEqual(row.line.stringValue, "Great Is Thy Faithfulness", "while digits wait, the row shows the live list's title (§7)")
        XCTAssertTrue(hasKeys(rig), "and the cursor doesn't: Space is still Next")
        XCTAssertEqual(rig.sent.count, 0)
        XCTAssertTrue(try press("return", in: rig))
        XCTAssertEqual(rig.commands, [["cue 14"]])
        XCTAssertEqual(sources(rig), ["key"])
        XCTAssertEqual(row.goTo.stringValue, "")
    }

    func test_escapeClearsDigitsThatWait() throws {
        let rig = try Rig()
        try press("3", in: rig)
        XCTAssertEqual(rig.view.nextRow.goTo.stringValue, "3")
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertEqual(rig.view.nextRow.goTo.stringValue, "")
        XCTAssertTrue(try press("return", in: rig))
        XCTAssertEqual(rig.sent.count, 0)
    }

    /// Typed into the field itself, a number goes as the window's (`ui`), and Return hands the focus back.
    func test_aNumberTypedInTheGoToFieldFiresOnReturnAndHandsTheFocusBack() throws {
        let rig = try Rig()
        let goTo = rig.view.nextRow.goTo
        XCTAssertTrue(rig.window.window.makeFirstResponder(goTo))
        try type("3", in: rig)
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(goTo.action), to: goTo.target, from: goTo))
        XCTAssertEqual(rig.commands, [["cue 3"]])
        XCTAssertEqual(sources(rig), ["ui"])
        XCTAssertTrue(hasKeys(rig))
    }

    // MARK: - The overlay

    func test_theKeysOverlayListsTheBindingsThenTheFixedKeysAndEscapeOrAClickClosesIt() throws {
        let rig = try Rig()
        rig.view.layoutLabel = { _ in nil }
        XCTAssertFalse(rig.view.isShowingKeys)
        // "? in the top bar".
        XCTAssertTrue(rig.view.topBar.keys.isEnabled)
        rig.view.topBar.keys.press()
        let overlay = try XCTUnwrap(rig.view.keysOverlay)
        rig.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.frame, rig.view.bounds, "over the whole window")
        let rows = overlay.shownRows.map { "\($0.key): \($0.what)" }
        XCTAssertEqual(Array(rows.prefix(4)), ["Space: Next cue", "→: Next cue", "←: Previous cue", "⇧⎋: Clear all channels (popups stay)"])
        XCTAssertEqual(rows[4], "⌃⌥⌘⎋: Take every output off the screen this window is on")
        XCTAssertEqual(rows.count, 12, "four bindings, then the fixed keys, the view's shortcuts, digit entry and ⌥-double-click")
        XCTAssertEqual(overlay.shownLines, ["Undo changes the library, never what is on the screens.", "While a menu is open it takes every key, ⇧⎋ included."])
        // The show goes on under it: a binding fires, and a digit doesn't wait where it can't be seen.
        XCTAssertTrue(try press("space", in: rig))
        XCTAssertEqual(rig.commands, [["next"]])
        XCTAssertTrue(try press("4", in: rig))
        XCTAssertEqual(rig.view.nextRow.goTo.stringValue, "")
        // "Escape or a click closes it."
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertFalse(rig.view.isShowingKeys)
        XCTAssertEqual(rig.sent.count, 1, "Escape sent nothing")
        rig.view.toggleKeys()
        let again = try XCTUnwrap(rig.view.keysOverlay)
        again.mouseDown(with: try event("space"))
        XCTAssertFalse(rig.view.isShowingKeys)
    }

    func test_theOverlayDrawsAKeyAsTheLayoutPrintsItAndFollowsTheTable() throws {
        let rig = try Rig()
        // A French keyboard: the key at Q's place prints A.
        rig.view.layoutLabel = { code in code == 12 ? "a" : nil }
        var catalog = try Rig.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        machine["keys"] = .array([
            .object(["device": .string("keyboard"), "key": .string("q"), "command": .object(["cmd": .string("macro.run"), "macro": .number(2)])]),
            .object(["device": .string("keyboard"), "key": .string("escape"), "command": .object(["cmd": .string("system.clearAll")])]),
        ])
        catalog["machine"] = .object(machine)
        rig.view.showKeys()
        let overlay = try XCTUnwrap(rig.view.keysOverlay)
        rig.store.apply(catalog: catalog)
        XCTAssertEqual(overlay.shownRows.first.map { "\($0.key): \($0.what)" }, "A: Run macro 2", "the open overlay follows the table")
        // "warn when nothing is bound to `next` or to `system clearall`", and a row the app leaves out is listed.
        XCTAssertEqual(Array(overlay.shownLines.prefix(3)), ["No key is bound to Next cue.", "No key is bound to Clear all channels.",
                                                             "“escape” is reserved, so its binding is ignored."])
        rig.view.releaseKeyRegistered = false
        rig.view.hideKeys()
        rig.view.showKeys()
        XCTAssertEqual(rig.view.keysOverlay?.shownLines.last, "macOS didn’t give Project O the key ⌃⌥⌘⎋, so it works only while Project O is the active app. "
                       + "Help ▸ Release Output from This Screen does the same.")
    }

    /// Spec 10 §15 and §18 — every control has a label, and "under the accented pseudolanguage and one 40% longer, nothing is clipped".
    func test_theOverlayIsLabeledAndShowsEveryLineWholeUnderEitherPseudolanguage() throws {
        for transform in [{ $0 }, Pseudolanguage.accented, Pseudolanguage.longer] as [(String) -> String] {
            try ViewStrings.install(transform: transform)
            let rig = try Rig()
            rig.view.layoutLabel = { _ in nil }
            rig.view.releaseKeyRegistered = false
            rig.view.showKeys()
            rig.view.layoutSubtreeIfNeeded()
            let overlay = try XCTUnwrap(rig.view.keysOverlay)
            XCTAssertEqual(Audit.unlabeled(in: overlay), [])
            XCTAssertEqual(overlay.accessibilityLabel(), transform("Keys"))
            let labels = Audit.all(NSTextField.self, in: overlay)
            XCTAssertGreaterThan(labels.count, 20)
            for label in labels {
                XCTAssertGreaterThan(label.frame.width, 0, "\"\(label.stringValue)\" has no room")
                if label.maximumNumberOfLines == 1 {
                    XCTAssertFalse(Audit.isCutOff(label), "\"\(label.stringValue)\" is clipped")
                } else {
                    // A line that wraps has the height its words need at the width it was given.
                    let needed = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.frame.width, height: 10_000)).height ?? 0
                    XCTAssertGreaterThanOrEqual(label.frame.height, needed - 0.5, "\"\(label.stringValue)\" is cut short")
                }
            }
        }
        try ViewStrings.install()
    }

    // MARK: - The command bar

    private func turnOnTheCommandBar(_ rig: Rig) throws {
        var catalog = try Rig.load("catalog")
        var machine = try XCTUnwrap(catalog["machine"]?.objectValue)
        var settings = try XCTUnwrap(machine["settings"]?.objectValue)
        settings["commandBar"] = .bool(true)
        machine["settings"] = .object(settings)
        catalog["machine"] = .object(machine)
        rig.store.apply(catalog: catalog)
        rig.view.layoutSubtreeIfNeeded()
    }

    /// "The command bar, off by default (`commandBar`), is a field across the top of the center when on. ⌘K focuses it."
    func test_theCommandBarIsOffByDefaultAndAcrossTheTopOfTheCenterWhenOn() throws {
        let rig = try Rig()
        let bar = rig.view.commandBar
        XCTAssertTrue(bar.isHidden)
        let gridTop = rig.view.grid.frame.minY
        rig.view.focusCommandBar()
        XCTAssertTrue(hasKeys(rig) || !(rig.window.window.firstResponder is NSText), "off, ⌘K has nothing to focus")
        try turnOnTheCommandBar(rig)
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.frame.minY, gridTop)
        XCTAssertEqual(bar.frame.minX, rig.view.grid.frame.minX)
        XCTAssertEqual(bar.frame.width, rig.view.grid.frame.width)
        XCTAssertEqual(rig.view.grid.frame.minY, gridTop + CommandBarView.height + 4, "the grid starts under it, a gap apart (Spec 10 §4)")
        XCTAssertEqual(Audit.unlabeled(in: bar), [])
        rig.view.focusCommandBar()
        XCTAssertEqual(rig.window.keyTap.context().field, .commandBar)
    }

    /// "As the operator types, it shows the canonical form, or the error ...;
    /// Return sends the command with source `commandbar` and shows the
    /// result or the rejection beside it; ↑ and ↓ recall the last fifty".
    func test_theCommandBarShowsTheCanonicalFormSendsOnReturnAndKeepsTheFocus() throws {
        let rig = try Rig()
        try turnOnTheCommandBar(rig)
        let bar = rig.view.commandBar
        rig.view.focusCommandBar()
        try type("Stack 1 Blackout TOGGLE", in: rig)
        XCTAssertEqual(bar.preview.stringValue, "stack 1 blackout toggle")
        XCTAssertFalse(try press("space", in: rig), "typing is the bar's")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(bar.field.action), to: bar.field.target, from: bar.field))
        XCTAssertEqual(rig.commands, [["stack 1 blackout toggle"]])
        XCTAssertEqual(sources(rig), ["commandbar"])
        XCTAssertEqual(bar.field.stringValue, "")
        XCTAssertEqual(bar.outcome.stringValue, "stack 1 blackout toggle: sent")
        XCTAssertEqual(rig.window.keyTap.context().field, .commandBar, "the command bar keeps the focus until Escape or a click elsewhere")
        try type("nonsense", in: rig)
        XCTAssertFalse(bar.preview.stringValue.isEmpty, "the parser's error")
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(bar.field.action), to: bar.field.target, from: bar.field))
        XCTAssertEqual(rig.sent.count, 1, "text that isn't a command goes nowhere")
        bar.recall(earlier: true)
        XCTAssertEqual(bar.field.stringValue, "stack 1 blackout toggle")
        // Escape leaves it and keeps the text.
        XCTAssertTrue(try press("escape", in: rig))
        XCTAssertTrue(hasKeys(rig))
        XCTAssertEqual(bar.field.stringValue, "stack 1 blackout toggle")
        XCTAssertEqual(rig.sent.count, 1)
    }

    // MARK: - What is open (Spec 10 §9, "When bindings fire")

    func test_whatIsOpenAndFocusedIsReadFromTheWindows() throws {
        let rig = try Rig()
        let tap = rig.window.keyTap
        XCTAssertEqual(tap.context(), KeyContext(), "nothing open, no field focused")
        // Another window of the app's has the keys: a sheet, a popover or a panel.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        tap.keyWindow = { sheet }
        XCTAssertEqual(tap.context(), KeyContext(sheet: true))
        XCTAssertFalse(try press("return", in: rig), "Return is the sheet's")
        XCTAssertFalse(try press("escape", in: rig), "and plain Escape")
        XCTAssertTrue(try press("4", in: rig))
        XCTAssertEqual(rig.view.nextRow.goTo.stringValue, "", "digit entry is off with a sheet open")
        XCTAssertTrue(try press("shift+escape", in: rig))
        XCTAssertTrue(try press("space", in: rig))
        XCTAssertEqual(rig.commands, [["system clearall"], ["next"]], "⇧⎋ fires with a sheet open, and so does every other binding")
        // A field in it has the cursor: the field's rule, and its own Escape.
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 100, height: 22))
        sheet.contentView?.addSubview(field)
        XCTAssertTrue(sheet.makeFirstResponder(field))
        XCTAssertEqual(tap.context(), KeyContext(field: .other, sheet: true))
        XCTAssertFalse(try press("space", in: rig))
        XCTAssertFalse(try press("escape", in: rig), "a field the app didn't make keeps its own Escape")
        XCTAssertTrue(try press("shift+escape", in: rig))
        // A list in it has the focus: every key but ⇧⎋ is the list's.
        final class List: NSTableView {
            override var acceptsFirstResponder: Bool { true }
        }
        let list = List(frame: NSRect(x: 10, y: 40, width: 100, height: 50))
        sheet.contentView?.addSubview(list)
        XCTAssertTrue(sheet.makeFirstResponder(list))
        XCTAssertTrue(sheet.firstResponder === list, "\(String(describing: sheet.firstResponder))")
        XCTAssertEqual(tap.context(), KeyContext(dialog: true, sheet: true))
        XCTAssertFalse(try press("right", in: rig))
        XCTAssertFalse(try press("space", in: rig))
        XCTAssertTrue(try press("shift+escape", in: rig))
        XCTAssertEqual(rig.commands.count, 4)
        tap.keyWindow = { nil }
        rig.view.showKeys()
        XCTAssertEqual(tap.context(), KeyContext(overlay: true))
    }

    // MARK: - ⌃⌥⌘⎋ (Spec 10 §9, "Fixed keys")

    private func controller(_ key: FakeReleaseKey) -> (AppController, NoLauncher) {
        let roots = MemoryRootsStore()
        let launcher = NoLauncher()
        let controller = AppController(rootsStore: roots, launcher: launcher, connector: NoConnector(), executable: URL(fileURLWithPath: "/nowhere/oengine"),
                                       releaseKey: key)
        controller.windowScreenName = { "display:FA21CBA0-626C-4AE4-A16C-7D56EC3C1175" }
        return (controller, launcher)
    }

    /// "⌃⌥⌘⎋ raises the window at once ...": pressed wherever the keys are, since the system has the key.
    func test_theReleaseKeyRaisesTheWindowAtOnceAndRemembersTheScreen() throws {
        let key = FakeReleaseKey()
        let (controller, _) = controller(key)
        var forward = 0
        controller.bringForward = { _ in forward += 1 }
        controller.startKeys()
        defer { controller.windowController.keyTap.remove() }
        XCTAssertEqual(key.registrations, 1)
        XCTAssertTrue(controller.windowController.regions.releaseKeyRegistered)
        XCTAssertEqual(controller.windowController.window.level, .normal)
        key.press()
        XCTAssertEqual(controller.windowController.window.level, OutputLevels.aboveOutputs, "one level above the outputs, before any engine answers")
        XCTAssertEqual(forward, 1, "in front, with another app active or not")
        XCTAssertTrue(controller.isRaised)
        XCTAssertTrue(controller.windowController.window.takesClicks, "raised, it takes clicks")
        XCTAssertEqual(controller.releasedScreens, ["display:FA21CBA0-626C-4AE4-A16C-7D56EC3C1175"])
        // No engine has answered: it stays raised.
        XCTAssertEqual(controller.windowController.window.level, OutputLevels.aboveOutputs)
    }

    /// The menu's entry does the same, and is how the key works when the system didn't give it.
    func test_whenTheSystemDoesNotGiveTheKeyTheOverlaySaysSoAndHelpsEntryStillWorks() throws {
        let key = FakeReleaseKey()
        key.gives = false
        let (controller, _) = controller(key)
        controller.bringForward = { _ in }
        let delegate = AppDelegate()
        delegate.openMainWindow(show: false, controller: controller)
        controller.startKeys()
        defer { controller.windowController.keyTap.remove() }
        XCTAssertFalse(controller.windowController.regions.releaseKeyRegistered)
        key.press()
        XCTAssertFalse(controller.isRaised, "the system never calls a key it didn't give")
        let bar = try XCTUnwrap(delegate.menuBar)
        let help = bar.entries(of: "Help")
        let release = try XCTUnwrap(help.first { $0.title == "Release Output from This Screen" } as? ClosureMenuItem)
        XCTAssertTrue(release.isEnabled)
        XCTAssertEqual(release.keyEquivalentModifierMask, [.control, .option, .command])
        release.choose()
        XCTAssertTrue(controller.isRaised)
        // Help ▸ Keys opens the overlay, which says the key is the app's only while it is active.
        let keys = try XCTUnwrap(help.first { $0.title == "Keys" } as? ClosureMenuItem)
        XCTAssertTrue(keys.isEnabled)
        XCTAssertEqual(keys.keyEquivalent, "/")
        keys.choose()
        let overlay = try XCTUnwrap(controller.windowController.regions.keysOverlay)
        XCTAssertTrue(overlay.shownLines.contains { $0.hasPrefix("macOS didn’t give Project O the key ⌃⌥⌘⎋") })
        keys.choose()
        XCTAssertFalse(controller.windowController.regions.isShowingKeys, "chosen again, it closes")
    }

    /// The Mac's own keyboard layout, read without a window: whatever it is, a letter key prints one character.
    func test_theCurrentKeyboardLayoutLabelsItsKeys() throws {
        let label = KeyboardLayout.label(code: 0)
        if let identifier = KeyboardLayout.identifier, identifier == "com.apple.keylayout.US" || identifier == "com.apple.keylayout.ABC" {
            XCTAssertEqual(label, "a")
            XCTAssertEqual(KeyboardLayout.label(code: 12), "q")
            XCTAssertEqual(KeyboardLayout.label(code: 41), ";")
        } else if let label {
            XCTAssertFalse(label.isEmpty)
        }
    }
}
