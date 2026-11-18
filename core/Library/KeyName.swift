// OCore — Spec 10 §9, key names: how a keyboard binding names its key.

/// Spec 10 §9, "Key names" — why a binding's `key` can't be bound: "The
/// engine refuses a binding of a reserved key, or a key name outside this
/// grammar, with `badValue` (Spec 5 §6)".
public enum KeyNameRefusal: Error, Equatable, Sendable {
    /// The text is outside the grammar.
    case notAKeyName
    /// "Some keys are reserved and can't be bound".
    case reserved
}

/// Spec 10 §9, "Key names" — "A binding's `key` is a key name, after any
/// modifiers, joined by `+` in the order `ctrl`, `alt`, `shift`: `space`,
/// `right`, `shift+escape`, `ctrl+alt+f`. ... A key is matched by its
/// position, named as on a US keyboard, so a binding stays on its key
/// whatever the input source."
///
/// One key name has one spelling (Area 13 reading): lower case, the
/// modifiers in the spec's order, each at most once, nothing around the
/// `+`. So the text of a key name is its identity, as a command's canonical
/// text is, and `KeyName(name.text) == name`.
public struct KeyName: Hashable, Sendable {
    /// The key, by its name: one of `KeyName.keys`.
    public let key: String
    public let ctrl: Bool
    public let alt: Bool
    public let shift: Bool

    /// "The names are `a` to `z`, `0` to `9`, `f1` to `f20`, `space`,
    /// `return`, `escape`, `tab`, `delete`, `forwarddelete`, `left`,
    /// `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, the
    /// keypad's `pad0` to `pad9`, `padenter`, `padplus`, `padminus`,
    /// `padstar`, `padslash`, `paddot` and `padequals`, and the punctuation
    /// keys by their unshifted US character (`-`, `=`, `[`, `]`, `\`, `;`,
    /// `'`, `,`, `.`, `/`, and the grave accent)." In the spec's order.
    public static let keys: [String] = {
        var names: [String] = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        names += (0...9).map { String($0) }
        names += (1...20).map { "f" + String($0) }
        names += ["space", "return", "escape", "tab", "delete", "forwarddelete", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
        names += (0...9).map { "pad" + String($0) }
        names += ["padenter", "padplus", "padminus", "padstar", "padslash", "paddot", "padequals"]
        names += ["-", "=", "[", "]", "\\", ";", "'", ",", ".", "/", "`"]
        return names
    }()

    private static let known = Set(keys)
    private static let functionKeys = Set((1...20).map { "f" + String($0) })
    private static let arrows: Set<String> = ["left", "right", "up", "down"]

    /// A key under modifiers; nil when the grammar has no key of that name.
    public init?(key: String, ctrl: Bool = false, alt: Bool = false, shift: Bool = false) {
        guard Self.known.contains(key) else { return nil }
        self.key = key
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
    }

    /// Reads a key name; nil when the text is outside the grammar. No key's
    /// name holds a `+`, so the last part is the key and the parts before it
    /// the modifiers, which come "in the order `ctrl`, `alt`, `shift`".
    public init?(_ text: String) {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { String($0) }
        guard let key = parts.popLast() else { return nil }
        var held = [false, false, false]
        var next = 0
        let order = ["ctrl", "alt", "shift"]
        for part in parts {
            // Each modifier is looked for only after the one before it, so one out of order or twice isn't found.
            guard let index = order[next...].firstIndex(of: part) else { return nil }
            held[index] = true
            next = index + 1
        }
        self.init(key: key, ctrl: held[0], alt: held[1], shift: held[2])
    }

    /// The key name as a binding stores it.
    public var text: String {
        (ctrl ? "ctrl+" : "") + (alt ? "alt+" : "") + (shift ? "shift+" : "") + key
    }

    /// Whether no modifier is held.
    public var isPlain: Bool { !ctrl && !alt && !shift }

    /// "Some keys are reserved and can't be bound: ⌘-combinations belong to
    /// the menus; Tab, ⇧Tab, ⌥ with the arrows, ⌥Return, ⌥Space and ⌃Return
    /// are the keyboard's navigation (§15); plain `escape` leaves fields and
    /// closes things; and ⌃⌥⌘⎋ is fixed".
    ///
    /// ⌘ has no word in the grammar, so a ⌘-combination can't be written.
    /// The rest are these chords and no others (Area 13 reading): the same
    /// key under another modifier, `alt+shift+left` or `ctrl+tab`, is a
    /// different chord and can be bound.
    public var isReserved: Bool {
        switch key {
        case "escape": return isPlain
        case "tab": return !ctrl && !alt
        case "left", "right", "up", "down", "space": return alt && !ctrl && !shift
        case "return": return (alt && !ctrl && !shift) || (ctrl && !alt && !shift)
        default: return false
        }
    }

    /// Spec 10 §9, "When bindings fire", 4 — "the function keys `f1` to `f20`".
    public var isFunctionKey: Bool { Self.functionKeys.contains(key) }

    /// One of the four arrows, under any modifiers.
    public var isArrow: Bool { Self.arrows.contains(key) }

    /// Spec 10 §9, "Digit entry" — "a digit key, on the top row or the
    /// keypad": the digit, for a key pressed with no modifier.
    public var digit: Int? {
        guard isPlain else { return nil }
        let text = key.hasPrefix("pad") ? String(key.dropFirst(3)) : key
        guard text.count == 1, let digit = Int(text) else { return nil }
        return digit
    }

    /// The key name a binding may hold, or why it may not.
    public static func bindable(_ text: String) -> Result<KeyName, KeyNameRefusal> {
        guard let name = KeyName(text) else { return .failure(.notAKeyName) }
        return name.isReserved ? .failure(.reserved) : .success(name)
    }
}
