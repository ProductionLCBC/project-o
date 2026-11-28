import AppKit
import XCTest
@testable import OAppUI

/// Spec 11 §8, "Fonts in the app" — "The app registers the bundled fonts for its own process too, from the engine's
/// resources in the same bundle", here the repository's own OFL DM Sans laid out as the app bundle holds it.
@MainActor
final class AppFontsTests: XCTestCase {
    func test_theEnginesBundledFontsAreFoundInTheAppAndRegisteredForItsProcess() throws {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine/OEngine/Resources/Fonts")
        let names = try FileManager.default.contentsOfDirectory(atPath: fonts.path).filter { $0.hasSuffix(".ttf") }.sorted()
        XCTAssertFalse(names.isEmpty)
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("app-fonts-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertEqual(AppFonts.files(in: app), [], "no engine bundle, nothing to register")
        let folder = app.appendingPathComponent("Contents/Resources/ProjectO_OEngine.bundle/Fonts")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try FileManager.default.copyItem(at: fonts.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
        try Data("not a font".utf8).write(to: folder.appendingPathComponent("README.txt"))
        XCTAssertEqual(AppFonts.files(in: app).map(\.lastPathComponent), names, "the font files only")
        XCTAssertEqual(AppFonts.register(in: app).map(\.lastPathComponent), names, "each usable, registered now or already")
        XCTAssertNotNil(NSFontManager.shared.availableMembers(ofFontFamily: "DM Sans"))
    }
}
