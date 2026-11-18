// OApp — Spec 10 §9, which key was pressed: a position on the keyboard, named as on a US keyboard.

import Foundation
import OCore

/// Spec 10 §9, "Key names" — "A key is matched by its position, named as on
/// a US keyboard, so a binding stays on its key whatever the input source."
///
/// macOS numbers each key by where it sits (its virtual key code), whatever
/// the keyboard layout prints on it: code 12 is the key at the top left of
/// the letters, Q on a US keyboard and A on a French one. This is the table
/// from those codes to §9's names. A key with no name here, the ISO
/// keyboard's extra key beside the left Shift, a JIS keyboard's own keys or
/// the keypad's Clear, can't be bound (Area 13 reading).
public enum KeyPositions {
    /// Each key name's code.
    public static let codes: [String: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
        "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "return": 0x24, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28,
        ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "tab": 0x30, "space": 0x31, "`": 0x32,
        "delete": 0x33, "escape": 0x35,
        "f17": 0x40, "paddot": 0x41, "padstar": 0x43, "padplus": 0x45, "padslash": 0x4B, "padenter": 0x4C, "padminus": 0x4E,
        "f18": 0x4F, "f19": 0x50, "padequals": 0x51,
        "pad0": 0x52, "pad1": 0x53, "pad2": 0x54, "pad3": 0x55, "pad4": 0x56, "pad5": 0x57, "pad6": 0x58, "pad7": 0x59, "f20": 0x5A,
        "pad8": 0x5B, "pad9": 0x5C,
        "f5": 0x60, "f6": 0x61, "f7": 0x62, "f3": 0x63, "f8": 0x64, "f9": 0x65, "f11": 0x67, "f13": 0x69, "f16": 0x6A, "f14": 0x6B,
        "f10": 0x6D, "f12": 0x6F, "f15": 0x71, "home": 0x73, "pageup": 0x74, "forwarddelete": 0x75, "f4": 0x76, "end": 0x77,
        "f2": 0x78, "pagedown": 0x79, "f1": 0x7A, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    ]

    private static let names: [UInt16: String] = {
        var names: [UInt16: String] = [:]
        for (name, code) in codes { names[code] = name }
        return names
    }()

    /// The name of the key at a position, or nil for a key §9 has no name for.
    public static func name(code: UInt16) -> String? { names[code] }

    /// The position a key name stands for.
    public static func code(of key: String) -> UInt16? { codes[key] }
}

/// One press of a key, as the system reports it: where the key sits, what
/// was held with it, and whether this is a held key repeating.
///
/// Spec 10 §9 — bindings "fire on a key's first press only: the repeats of
/// a held key never fire it again". The first press is the one the system
/// doesn't mark as a repeat; Caps Lock and Fn aren't part of a key name, so
/// they aren't carried here (Area 13 readings).
public struct KeyStroke: Equatable, Sendable {
    public var code: UInt16
    public var ctrl: Bool
    public var alt: Bool
    public var shift: Bool
    /// ⌘ was held: "⌘-combinations belong to the menus".
    public var command: Bool
    public var isRepeat: Bool

    public init(code: UInt16, ctrl: Bool = false, alt: Bool = false, shift: Bool = false, command: Bool = false, isRepeat: Bool = false) {
        self.code = code
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.command = command
        self.isRepeat = isRepeat
    }

    /// A press of a key by its name, as a test or the keys overlay makes one; nil for a text that isn't a key name.
    public init?(_ text: String, command: Bool = false, isRepeat: Bool = false) {
        guard let name = KeyName(text), let code = KeyPositions.code(of: name.key) else { return nil }
        self.init(code: code, ctrl: name.ctrl, alt: name.alt, shift: name.shift, command: command, isRepeat: isRepeat)
    }

    /// The key name of this press, without ⌘; nil for a key with no name.
    public var name: KeyName? {
        KeyPositions.name(code: code).flatMap { KeyName(key: $0, ctrl: ctrl, alt: alt, shift: shift) }
    }
}
