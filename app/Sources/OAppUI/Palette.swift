// OAppUI — Spec 10 §4, the palette as named colors, and the screens by the engine's names.

import AppKit
import OCore

/// Spec 10 §4, "Appearance" — "Dark only in v1 ... four colors carry
/// meaning everywhere: red for live and for errors, green for outputting and
/// for the selected preview, amber for browsing away from live (§6) and for
/// warnings, and blue for selection and focus."
///
/// The look is the one Adam approved in layout at Area 13's first stop
/// (2026-11-17), drawn cleaner as he asked: surfaces told apart by their
/// fill and not by borders, one hairline where two meet, and color kept for
/// the four meanings and the section hues. The clickable demo isn't in the
/// repository, so these are the app's own.
@MainActor
enum Palette {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// Red: live, and errors.
    static let live = rgb(0xF2453D)
    /// Green: outputting, and the selected preview.
    static let outputting = rgb(0x30C36B)
    /// Amber: browsing away from live, and warnings.
    static let browsing = rgb(0xF5A623)
    /// Blue: selection and focus.
    static let selection = rgb(0x4C8DFF)

    /// The window behind everything, a column's panel on it, and what is raised from a panel: a cell, a field, a button.
    static let window = rgb(0x0E0F12)
    static let panel = rgb(0x15171B)
    static let raised = rgb(0x1E2127)
    /// A raised thing under the pointer or pressed.
    static let raisedHigh = rgb(0x282C34)
    /// Where a picture goes before it is there.
    static let well = rgb(0x08090B)
    /// The one line between two surfaces.
    static let hairline = NSColor(white: 1, alpha: 0.07)

    static let text = rgb(0xECEEF2)
    static let dimText = rgb(0x9AA0AB)
    static let faintText = rgb(0x626975)

    /// Spec 10 §6 — "a fixed palette of eight hues that are neither the live
    /// red nor the browse amber", in `SectionHue`'s order: verse, chorus,
    /// bridge, pre-chorus, tag, intro, outro, and one more for other names.
    static let sections: [NSColor] = [rgb(0x2CB5A9), rgb(0x8B6CF6), rgb(0xD45DB5), rgb(0x5B74E8), rgb(0x9BC53D), rgb(0x3BB6DE), rgb(0x7A8BA8), rgb(0xB07CC6)]

    static func section(_ hue: Int?) -> NSColor? {
        hue.flatMap { sections.indices.contains($0) ? sections[$0] : nil }
    }
}

extension NSScreen {
    /// Spec 10 §2 — the screen as the engine names it, `display:<uuid>`,
    /// with the uuid "as macOS prints it, in capitals".
    var deviceName: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else { return nil }
        return DetectedScreen.devicePrefix + (CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String).uppercased()
    }

    /// The screen with this name, among those the Mac has now.
    static func named(_ device: String) -> NSScreen? {
        screens.first { $0.deviceName == device }
    }
}

/// Spec 10 §2 — the window levels around the engine's outputs, which "sit at
/// the screen-saver window level": a curtain "one level below the outputs",
/// and the main window, raised, "one level above the outputs" (§9).
@MainActor
enum OutputLevels {
    static let output = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    static let curtain = NSWindow.Level(rawValue: output.rawValue - 1)
    static let aboveOutputs = NSWindow.Level(rawValue: output.rawValue + 1)
}
