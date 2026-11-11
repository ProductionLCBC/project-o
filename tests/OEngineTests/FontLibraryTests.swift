import CoreText
import XCTest
import OCore
@testable import OEngine

/// Spec 6 §4 — "Fonts (P14). The engine registers a set of OFL-licensed fonts
/// bundled with it. It registers them for its own process, at launch and
/// before the first raster, so a font such as DM Sans resolves at every campus
/// with nothing installed. Installed fonts resolve as before. If a bundled
/// font's PostScript name is also installed, the engine uses the installed
/// copy and logs the clash once (choice T-7). A missing font falls back to the
/// machine's `fallbackFont` and is recorded for pre-flight (Spec 4 §8)." Choice
/// T-6, with Adam's answers of 2026-11-10: DM Sans roman and italic, which
/// also answer to the usual names of their weights. Spec 6 §11, Area 6: Fonts.
final class FontLibraryTests: XCTestCase {
    func folder() throws -> URL {
        try XCTUnwrap(FontLibrary.bundledFolder, "the engine's resources carry its fonts")
    }

    func url(of font: CTFont) -> URL? {
        CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
    }

    /// The font's `wght`, which Core Text leaves out at the axis default of 400.
    func weight(of font: CTFont) -> Double {
        (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[NSNumber(value: 0x7767_6874)]?.doubleValue ?? 400
    }

    func test_theEngineBundlesDMSansWithItsLicence() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: folder().path)
        XCTAssertTrue(files.contains("DMSans[opsz,wght].ttf"), "\(files)")
        XCTAssertTrue(files.contains("DMSans-Italic[opsz,wght].ttf"))
        XCTAssertTrue(files.contains("OFL.txt"))
        let licence = try String(contentsOf: folder().appendingPathComponent("OFL.txt"), encoding: .utf8)
        XCTAssertTrue(licence.contains("SIL OPEN FONT LICENSE Version 1.1"))
        let library = FontLibrary(folder: try folder(), installedNames: [])
        for name in ["DMSans-9ptRegular", "DMSans-9ptRegular_Bold", "DMSans-9ptItalic", "DMSans-Thin", "DMSans-Regular", "DMSans-Bold",
                     "DMSans-Black", "DMSans-Italic", "DMSans-BoldItalic", "DMSans-BlackItalic"] {
            XCTAssertTrue(library.bundledNames.contains(name), name)
        }
    }

    /// "a font such as DM Sans resolves at every campus with nothing installed",
    /// by the names Core Text gives it and by the usual ones.
    func test_aBundledFontResolvesWithNothingInstalled() throws {
        let library = FontLibrary(folder: try folder(), installedNames: [])
        let cases: [(String, Double, Bool)] = [("DMSans-Bold", 700, false), ("DMSans-9ptRegular_Bold", 700, false), ("DMSans-Thin", 100, false),
                                              ("DMSans-Regular", 400, false), ("DMSans-BoldItalic", 700, true), ("DMSans-Italic", 400, true)]
        for (name, wght, italic) in cases {
            let font = try XCTUnwrap(library.font(named: name, size: 40), name)
            XCTAssertEqual(library.origin(of: name), .bundled, name)
            XCTAssertTrue(url(of: font)?.path.hasPrefix(try folder().path) == true, "\(name) is drawn from the engine's own file")
            XCTAssertEqual(weight(of: font), wght, accuracy: 0.5, name)
            XCTAssertEqual(CTFontGetSymbolicTraits(font).contains(.traitItalic), italic, name)
        }
        let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue", fonts: library)
        var style = TextJobs.plain()
        style.font = "DMSans-Bold"
        let raster = try rasterizer.rasterize(TextJobs.job("Amen", style: style))
        XCTAssertNil(raster.substitutedFont, "nothing stood in")
        XCTAssertEqual(raster.layout.lines.first?.runs.first?.font, "DMSans-9ptRegular_Bold")
    }

    /// T-7 — "the engine uses the installed copy and logs the clash once": a
    /// copy of an installed system font stands in for a bundled one.
    func test_anInstalledFontOfTheSameNameWinsAndTheClashIsLoggedOnce() throws {
        let system = try XCTUnwrap(url(of: CTFontCreateWithName("Helvetica" as CFString, 12, nil)))
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("oengine-fonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try FileManager.default.copyItem(at: system, to: bundle.appendingPathComponent(system.lastPathComponent))
        let library = FontLibrary(folder: bundle)
        XCTAssertTrue(library.bundledNames.contains("Helvetica"))
        let log = EngineLog(category: "test-fonts")
        library.register(log: log)
        library.register(log: log)
        XCTAssertEqual(log.recent.filter { $0.message.contains("installed and bundled") }.count, 1, log.recent.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(library.origin(of: "Helvetica"), .installed)
        let font = try XCTUnwrap(library.font(named: "Helvetica", size: 40))
        XCTAssertEqual(url(of: font)?.resolvingSymlinksInPath().path, system.resolvingSymlinksInPath().path, "the installed copy")
    }

    func test_installedFontsResolveAsBeforeAndAMissingOneFallsBack() throws {
        let library = FontLibrary(folder: try folder())
        let neue = try XCTUnwrap(library.font(named: "HelveticaNeue-Bold", size: 40))
        XCTAssertEqual(CTFontCopyPostScriptName(neue) as String, "HelveticaNeue-Bold")
        XCTAssertEqual(library.origin(of: "HelveticaNeue-Bold"), .installed)
        XCTAssertNil(library.font(named: "NoSuchFont-Bold", size: 40))
        XCTAssertNil(library.origin(of: "NoSuchFont-Bold"), "neither installed nor bundled")
        let rasterizer = CoreTextLineRasterizer(fallbackFont: "HelveticaNeue", fonts: library)
        var style = TextJobs.plain()
        style.font = "NoSuchFont-Bold"
        XCTAssertEqual(try rasterizer.rasterize(TextJobs.job("Amen", style: style)).substitutedFont, "HelveticaNeue", "recorded for pre-flight")
    }

    /// "at launch and before the first raster": the harness registers the
    /// bundled fonts as the engine process does.
    func test_theEngineRegistersItsFontsAtLaunch() throws {
        let metal = try MetalHarness.backend()
        _ = try HeadlessEngine(library: EngineFixtures.library(), machine: EngineFixtures.spikeMachine(mainSize: Size(width: 480, height: 270)),
                               media: EngineFixtures.media, metal: metal)
        XCTAssertTrue(FontLibrary.shared.isRegistered)
    }
}
