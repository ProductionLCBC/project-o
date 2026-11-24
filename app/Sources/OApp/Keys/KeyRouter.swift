// OApp — Spec 10 §9, where a key goes: what is open or focused first, the bindings only when none of it takes the key.

import Foundation
import OCore

/// Spec 10 §9, "A text field" — the kinds of field, by what Return and
/// Escape do in each and what the top bar says over it (§8).
public enum FieldKind: Equatable, Sendable, CaseIterable {
    /// The go-to field (§7).
    case goTo
    /// A popup or timer row's field (§7).
    case row
    /// A search field.
    case search
    /// The command bar.
    case commandBar
    /// In-place text over a cue (§10).
    case inPlaceText
    /// A field that edits and saves on Return: a rename, a new title, a note, a Settings field.
    case edit
    /// Edit mode's text popover and its commands as text (Spec 11 §4).
    case editPopover
    /// Edit mode's text editor (Spec 11 §5).
    case textEditor
    /// Any other control that takes typing.
    case other

    /// What plain Escape does in the field.
    public enum Escape: Equatable, Sendable {
        /// "In a field that edits ..., plain Escape discards what was typed and leaves the field".
        case discardAndLeave
        /// "apart from the go-to field, which it clears".
        case clearAndLeave
        /// "in any other field it leaves the field and keeps the text".
        case leave
    }

    /// Spec 10 §8 — "while a text field has the focus, what its keys do".
    public enum Hint: Equatable, Sendable {
        /// "Editing: ⌘Return saves · Esc discards" over in-place text and edit mode's text popover and commands as text.
        case commandReturnSaves
        /// "Editing text: ⌥Return splits · Esc leaves" over edit mode's text editor.
        case textEditor
        /// "Editing: Return saves · Esc discards" over any other field that edits.
        case returnSaves
        /// "Typing: Esc for show keys" over the rest.
        case typing
    }

    public var escape: Escape {
        switch self {
        case .inPlaceText, .edit, .editPopover: return .discardAndLeave
        case .goTo: return .clearAndLeave
        case .row, .search, .commandBar, .textEditor, .other: return .leave
        }
    }

    public var hint: Hint {
        switch self {
        case .inPlaceText, .editPopover: return .commandReturnSaves
        case .textEditor: return .textEditor
        case .edit: return .returnSaves
        case .goTo, .row, .search, .commandBar, .other: return .typing
        }
    }

    /// "A single-line field that acts on Return (the go-to field, a popup or
    /// timer row, a rename, a new title, a note) hands the focus back to the
    /// window when it acts, so the next Space sends `next`. Search fields
    /// and the command bar keep the focus until Escape or a click elsewhere."
    public var handsFocusBackOnReturn: Bool {
        switch self {
        case .goTo, .row, .edit: return true
        case .search, .commandBar, .inPlaceText, .editPopover, .textEditor, .other: return false
        }
    }
}

/// What is open or has the focus when a key is pressed, for §9's order.
public struct KeyContext: Equatable, Sendable {
    /// 1. The key recorder is recording (§11; Area 17 builds it).
    public var recorder = false
    /// 2. A menu is open.
    public var menu = false
    /// 3. A file dialog is up, or a list has the focus in a sheet or popover.
    public var dialog = false
    /// 4. The kind of text field that has the focus, or nil with none.
    public var field: FieldKind?
    /// 5. In edit mode, a cue grid, canvas or list in the workspace or the inspector has the focus (Spec 11 §2).
    public var editFocus = false
    /// Edit mode is open: plain Escape, with nothing else to close, leaves it (Spec 11 §2).
    public var editMode = false
    /// 6. A sheet or popover is open.
    public var sheet = false
    /// The keys overlay is up.
    public var overlay = false
    /// Digits are waiting in the go-to field.
    public var digitsWaiting = false
    /// The go-to field can take a number: something is live with a list to go to (§7).
    public var goToEnabled = true

    public init(recorder: Bool = false, menu: Bool = false, dialog: Bool = false, field: FieldKind? = nil, editFocus: Bool = false,
                sheet: Bool = false, overlay: Bool = false, digitsWaiting: Bool = false, goToEnabled: Bool = true, editMode: Bool = false) {
        self.editMode = editMode
        self.recorder = recorder
        self.menu = menu
        self.dialog = dialog
        self.field = field
        self.editFocus = editFocus
        self.sheet = sheet
        self.overlay = overlay
        self.digitsWaiting = digitsWaiting
        self.goToEnabled = goToEnabled
    }
}

/// Where a key goes.
public enum KeyRoute: Equatable, Sendable {
    /// Not the bindings': what is open or has the focus takes it, or the menus or the keyboard's navigation do.
    case passed
    /// Its binding fires: the command goes with source `key`.
    case fire(KeyBinding)
    /// A digit goes into the go-to field.
    case digit(Int)
    /// Return, with digits waiting: `cue N` in the live list.
    case completeDigits
    /// Plain Escape, which "never sends a command": what it leaves or closes.
    case escape(Escaped)
    /// Nothing happens and nothing else gets the key: a held key's repeat, or a key with nothing bound.
    case nothing

    public enum Escaped: Equatable, Sendable {
        /// It leaves the field, by the field's rule.
        case field(FieldKind)
        /// It clears the digits waiting in the go-to field.
        case digits
        /// It closes the keys overlay.
        case overlay
        /// Spec 11 §2 — with nothing else to close, it leaves edit mode.
        case editMode
    }
}

/// Spec 10 §9, "When bindings fire" — "Whenever a Project O window is the
/// key window, a key goes to the first of these that is open or has the
/// focus, and to the bindings only when none of them takes it".
public enum KeyRouter {
    private static let shiftEscape = KeyName(key: "escape", shift: true)

    /// Return, on the main keys or the keypad, with nothing held (Area 13
    /// reading: the keypad's Enter is Return for a sheet's default button
    /// and for the digits a keypad typed).
    static func isReturn(_ name: KeyName) -> Bool {
        name.isPlain && (name.key == "return" || name.key == "padenter")
    }

    static func isEscape(_ name: KeyName) -> Bool {
        name.isPlain && name.key == "escape"
    }

    public static func route(_ stroke: KeyStroke, table: BindingTable, context: KeyContext) -> KeyRoute {
        // "⌘-combinations belong to the menus", so they never reach the table.
        if stroke.command { return .passed }
        // 1. "The key recorder takes every key ... Plain Escape cancels it".
        if context.recorder { return .passed }
        // 2. "An open menu takes every key until it closes, ⇧⎋ included, as macOS has it".
        if context.menu { return .passed }
        // A key §9 has no name for can't be bound: whatever takes typing has it, and otherwise nothing does.
        guard let name = stroke.name else { return context.dialog || context.field != nil ? .passed : .nothing }

        let isShiftEscape = name == shiftEscape
        let bound = table.binding(for: name)

        // 3. "A file dialog, or a list that has the focus in a sheet or popover, takes every key but ⇧⎋."
        if context.dialog {
            if !isShiftEscape { return .passed }
        } else if let field = context.field {
            // 4. "A text field takes every key but ⇧⎋, a binding that includes `ctrl`, and the function keys `f1` to `f20`".
            let reachesBindings = isShiftEscape || (bound != nil && (name.ctrl || name.isFunctionKey))
            if !reachesBindings {
                // Escape in a field the app made follows that field's rule; in any other it is the field's own.
                if isEscape(name), field != .other { return .escape(.field(field)) }
                return .passed
            }
        } else {
            // 5. "In edit mode, a focused cue grid, canvas, or list in the workspace or the inspector takes the
            //    arrows, with ⇧ or ⌥, and Delete and Forward Delete (Spec 11 §2)."
            if context.editFocus {
                if name.isArrow && !name.ctrl { return .passed }
                if name.isPlain && (name.key == "delete" || name.key == "forwarddelete") { return .passed }
            }
            // 6. "A sheet or popover takes Return and plain Escape."
            if context.sheet, isReturn(name) || isEscape(name) { return .passed }
        }

        // None of them took it. Escape first: it "never sends a command".
        if isEscape(name) {
            if context.digitsWaiting { return .escape(.digits) }
            if context.overlay { return .escape(.overlay) }
            // Spec 11 §2 — "Escape leaves a field first, then closes a popover, a sheet or the keys overlay, then
            // clears waiting digits, then leaves edit mode."
            if context.editMode { return .escape(.editMode) }
            return .nothing
        }
        // "While digits are waiting, Return completes them whatever Return is bound to."
        if context.digitsWaiting, isReturn(name) { return stroke.isRepeat ? .nothing : .completeDigits }
        // The bindings, "on a key's first press only".
        if let bound { return stroke.isRepeat ? .nothing : .fire(bound) }
        // "Digit entry is built in: with no field focused, an unbound digit key, on the top row or the keypad, goes
        // into the go-to field ... a held digit counts once ... Digit entry is off while a sheet or popover is open."
        if let digit = name.digit, context.field == nil, !context.dialog, !context.sheet, !context.overlay {
            return stroke.isRepeat || !context.goToEnabled ? .nothing : .digit(digit)
        }
        // The keyboard's navigation (§15) is reserved, so it is never in the table: the focused control has it.
        if name.isReserved { return .passed }
        return .nothing
    }
}

/// Spec 10 §9, "Digit entry" — the digits waiting in the go-to field.
public struct DigitEntry: Equatable, Sendable {
    /// "Escape, or three seconds without a key, clears the digits".
    public static let seconds: TimeInterval = 3

    public private(set) var digits = ""
    /// When the digits clear by themselves, on the app's clock.
    public private(set) var clearsAt: TimeInterval?

    public init() {}

    public var isWaiting: Bool { !digits.isEmpty }

    /// The cue number typed so far: nil with no digits, with zero, or with more digits than a number holds.
    public var number: Int? {
        guard let number = Int(digits), number > 0 else { return nil }
        return number
    }

    /// A digit key was pressed. The three seconds run from the last digit
    /// (Area 13 reading: another key in between fires its binding and
    /// leaves the digits and their three seconds as they were, so digits
    /// never wait longer than three seconds after the last one).
    public mutating func type(_ digit: Int, at now: TimeInterval) {
        guard (0...9).contains(digit) else { return }
        digits += String(digit)
        clearsAt = now + Self.seconds
    }

    public mutating func clear() {
        digits = ""
        clearsAt = nil
    }

    /// Clears the digits when their three seconds have run; says whether it did.
    public mutating func expire(at now: TimeInterval) -> Bool {
        guard let clearsAt, now >= clearsAt else { return false }
        clear()
        return true
    }
}
