import CoreText
import XCTest
import OCore
@testable import OEngine

/// Spec 1 §2 — the Text Style's "variations (a map of OpenType axis tag to
/// value, such as wght, wdth, opsz, for variable fonts; weight is the wght
/// axis when the font is variable and the nearest instance when it is not)".
/// Area 11's block: "a text style's weight sets a variable font's wght axis
/// when its variations name none, and picks the family's nearest face for a
/// static font, with tests of its own". Helvetica Neue, on every Mac, is the
/// static family: UltraLight 100 to Bold 700 in regular width and in italic,
/// and a condensed Bold and Black. The bundled DM Sans, with nothing counted
/// as installed, is the variable one: `wght` 100 to 1000.
final class FontWeightTests: XCTestCase {
    static let wght = NSNumber(value: 0x7767_6874)

    func resolved(_ font: String, weight: Double, variations: [String: Double] = [:], fonts: FontLibrary = .shared,
                  fallback: String = "HelveticaNeue") -> CTFont {
        var values = TextStyleValues()
        values.font = font
        values.weight = weight
        values.variations = variations
        return CoreTextLineRasterizer(fallbackFont: fallback, fonts: fonts).resolveFont(values, pixelSize: 40).font
    }

    func name(_ font: CTFont) -> String { CTFontCopyPostScriptName(font) as String }

    /// The font's `wght`, Core Text leaving it out at the axis default of 400.
    func wght(_ font: CTFont) -> Double {
        (CTFontCopyVariation(font) as? [NSNumber: NSNumber])?[Self.wght]?.doubleValue ?? 400
    }

    func bundledOnly() throws -> FontLibrary {
        FontLibrary(folder: try XCTUnwrap(FontLibrary.bundledFolder), installedNames: [])
    }

    /// "the nearest instance when it is not": among the family's static faces
    /// with the named face's slant and width, the nearest weight; a tie keeps
    /// the named face, then the lighter.
    func test_aStaticFontTakesItsFamilysNearestFace() {
        XCTAssertEqual(name(resolved("HelveticaNeue", weight: 700)), "HelveticaNeue-Bold")
        XCTAssertEqual(name(resolved("HelveticaNeue-Bold", weight: 300)), "HelveticaNeue-Light")
        XCTAssertEqual(name(resolved("HelveticaNeue-Bold", weight: 500)), "HelveticaNeue-Medium")
        XCTAssertEqual(name(resolved("HelveticaNeue-Bold", weight: 100)), "HelveticaNeue-UltraLight")
        XCTAssertEqual(name(resolved("HelveticaNeue-Italic", weight: 700)), "HelveticaNeue-BoldItalic", "the slant is kept")
        XCTAssertEqual(name(resolved("HelveticaNeue-CondensedBold", weight: 900)), "HelveticaNeue-CondensedBlack", "the width is kept")
        XCTAssertEqual(name(resolved("HelveticaNeue-Bold", weight: 900)), "HelveticaNeue-Bold",
                       "no face of regular width is heavier; the condensed black is another width")
        XCTAssertEqual(name(resolved("HelveticaNeue-Medium", weight: 600)), "HelveticaNeue-Medium", "a tie keeps the named face")
        XCTAssertEqual(name(resolved("HelveticaNeue", weight: 600)), "HelveticaNeue-Medium", "a tie between two others takes the lighter")
        XCTAssertEqual(name(resolved("HelveticaNeue-Bold", weight: 700)), "HelveticaNeue-Bold", "its own weight: itself")
    }

    /// "weight is the wght axis when the font is variable", unless the style's
    /// variations name it; clamped to the axis.
    func test_aVariableFontsWghtFollowsTheWeightUnlessItsVariationsNameIt() throws {
        let fonts = try bundledOnly()
        XCTAssertEqual(wght(resolved("DMSans-Regular", weight: 700, fonts: fonts)), 700, accuracy: 0.5)
        XCTAssertEqual(wght(resolved("DMSans-Regular", weight: 250, fonts: fonts)), 250, accuracy: 0.5)
        XCTAssertEqual(wght(resolved("DMSans-Bold", weight: 400, fonts: fonts)), 400, accuracy: 0.5, "the weight, not the instance's name")
        XCTAssertEqual(wght(resolved("DMSans-Regular", weight: 700, variations: ["wght": 300], fonts: fonts)), 300, accuracy: 0.5,
                       "the variations name the axis: they win")
        XCTAssertEqual(wght(resolved("DMSans-Regular", weight: 1200, fonts: fonts)), 1000, accuracy: 0.5, "clamped to the axis")
        XCTAssertEqual(wght(resolved("DMSans-Regular", weight: 20, fonts: fonts)), 100, accuracy: 0.5)
        XCTAssertEqual(wght(resolved("DMSans-Bold", weight: 700, fonts: fonts)), 700, accuracy: 0.5)
        XCTAssertTrue(CTFontGetSymbolicTraits(resolved("DMSans-Italic", weight: 800, fonts: fonts)).contains(.traitItalic))
        XCTAssertEqual(wght(resolved("DMSans-Italic", weight: 800, fonts: fonts)), 800, accuracy: 0.5)
    }

    /// Spec 6 §4 — "A missing font falls back to the machine's `fallbackFont`
    /// and is recorded for pre-flight": the fallback draws at the style's
    /// weight too, and the record names the machine's fallback font.
    func test_theFallbackFontTakesTheWeightToo() throws {
        var style = TextJobs.plain()
        style.font = "NoSuchFont-Bold"
        style.weight = 700
        let raster = try CoreTextLineRasterizer(fallbackFont: "HelveticaNeue").rasterize(TextJobs.job("Amen", style: style))
        XCTAssertEqual(raster.substitutedFont, "HelveticaNeue", "recorded for pre-flight as the machine's fallback font")
        XCTAssertEqual(raster.layout.lines.first?.runs.first?.font, "HelveticaNeue-Bold", "drawn at the style's weight")
        style.weight = 300
        XCTAssertEqual(try CoreTextLineRasterizer(fallbackFont: "HelveticaNeue").rasterize(TextJobs.job("Amen", style: style))
                        .layout.lines.first?.runs.first?.font, "HelveticaNeue-Light")
    }

    /// Every style in the fixtures, and the default, names the face of its own
    /// weight, so nothing they draw moves and the goldens hold.
    func test_theFixtureStylesKeepTheirOwnFaces() throws {
        let library = try EngineFixtures.library()
        var styles = library.textStyles.map(\.values)
        for preset in library.presets {
            for layout in preset.layouts.values {
                styles += layout.boxes.compactMap { $0.textStyle?.values }
            }
        }
        styles.append(TextStyleValues())
        XCTAssertGreaterThan(styles.count, 5)
        for style in styles {
            XCTAssertEqual(name(resolved(style.font, weight: style.weight, variations: style.variations)), style.font,
                           "\(style.font) at \(style.weight)")
        }
    }
}
