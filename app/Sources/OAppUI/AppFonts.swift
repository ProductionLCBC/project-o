// OAppUI — Spec 11 §8, "Fonts in the app": the engine's bundled fonts, registered for the app's own process.

import AppKit
import CoreText

/// Spec 11 §8 — "The app registers the bundled fonts for its own process too, from the engine's resources in the same
/// bundle, so the font picker and the style form draw each face in itself. What goes on air is still the engine's
/// drawing."
@MainActor
enum AppFonts {
    /// Where the engine's resource bundle keeps its fonts inside the app: in Resources, and beside the engine in Helpers.
    static func folders(in app: URL) -> [URL] {
        ["Contents/Resources/ProjectO_OEngine.bundle/Fonts", "Contents/Helpers/ProjectO_OEngine.bundle/Fonts"].map {
            app.appendingPathComponent($0, isDirectory: true)
        }
    }

    /// The font files of the first folder that has any.
    static func files(in app: URL) -> [URL] {
        let manager = FileManager.default
        for folder in folders(in: app) {
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            let fonts = names.filter { ["ttf", "otf", "ttc"].contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            if !fonts.isEmpty { return fonts.map { folder.appendingPathComponent($0) } }
        }
        return []
    }

    /// Registers them for this process; a face already there (installed on the Mac too) counts as registered.
    /// Returns the files that are now usable.
    @discardableResult
    static func register(in app: URL = Bundle.main.bundleURL) -> [URL] {
        files(in: app).filter { url in
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            return code == CTFontManagerError.alreadyRegistered.rawValue
        }
    }
}
