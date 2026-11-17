// OAppUI — Spec 10 §4, the palette as named colours, and the screens by the engine's names.

import AppKit
import OCore

/// Spec 10 §4, "Appearance" — "Dark only in v1 ... four colours carry
/// meaning everywhere: red for live and for errors, green for outputting and
/// for the selected preview, amber for browsing away from live (§6) and for
/// warnings, and blue for selection and focus."
///
/// The values are provisional: the clickable demo isn't in the repository,
/// so the look is proposed as a mockup at Area 13's first stop and these
/// take the values Adam approves there (his answer of 2026-11-17).
@MainActor
enum Palette {
    /// Red: live, and errors.
    static let live = NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
    /// Green: outputting, and the selected preview.
    static let outputting = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.47, alpha: 1)
    /// Amber: browsing away from live, and warnings.
    static let browsing = NSColor(srgbRed: 0.96, green: 0.68, blue: 0.20, alpha: 1)
    /// Blue: selection and focus.
    static let selection = NSColor(srgbRed: 0.31, green: 0.55, blue: 0.98, alpha: 1)
    /// The window behind everything.
    static let window = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.082, alpha: 1)
    /// A panel raised from the window.
    static let panel = NSColor(srgbRed: 0.106, green: 0.114, blue: 0.129, alpha: 1)
    static let text = NSColor(white: 0.93, alpha: 1)
    static let dimText = NSColor(white: 0.62, alpha: 1)
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
