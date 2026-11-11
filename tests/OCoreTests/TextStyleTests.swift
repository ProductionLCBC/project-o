import Foundation
import XCTest
@testable import OCore

/// Spec 6 §4 — "The Text Style gains `verticalAlignment`, beside `alignment`:
/// `top`, `center` or `bottom`, defaulting to `center` and written on every
/// style, inline ones included." Spec 1 §2 — the Text Style's fields.
final class TextStyleTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_theVerticalAlignmentDefaultsToCentreAndIsWrittenOnEveryStyle() throws {
        XCTAssertEqual(TextStyleValues().verticalAlignment, .center)
        // A style written before Spec 6 has no key: it reads as centre.
        let older = JSONValue.object(["fromStyle": .null, "font": .string("HelveticaNeue-Bold")])
        let inline = try JSONCoding.decode(BoxTextStyle.self, from: older)
        XCTAssertEqual(inline.values.verticalAlignment, .center)
        XCTAssertEqual(try JSONCoding.encode(inline)["verticalAlignment"], .string("center"), "written even at the default")

        var top = TextStyle(number: 3, label: "Top", uuid: F.uuid("7e57", 3))
        top.values.verticalAlignment = .top
        let written = try JSONCoding.encode(top)
        XCTAssertEqual(written["verticalAlignment"], .string("top"))
        XCTAssertEqual(try JSONCoding.decode(TextStyle.self, from: written).values.verticalAlignment, .top)
        XCTAssertEqual(try JSONCoding.decode(TextStyle.self, from: written.setting("verticalAlignment", to: .string("bottom"))).values.verticalAlignment, .bottom)
        XCTAssertThrowsError(try JSONCoding.decode(TextStyle.self, from: written.setting("verticalAlignment", to: .string("middle"))),
                             "only top, center and bottom")
    }

    /// Every style in the fixture library, catalog and inline, carries the key.
    func test_everyFixtureStyleCarriesItsVerticalAlignment() throws {
        let (library, _, _) = F.load()
        for style in library.textStyles {
            XCTAssertEqual(try JSONCoding.encode(style)["verticalAlignment"], .string(style.values.verticalAlignment.rawValue))
        }
        let text = F.documents(under: F.libraryRoot).filter { $0.path.hasPrefix("presets/") || $0.path == "text-styles.json" }
        for document in text {
            let tree = try JSONValue.parse(document.data)
            var styles: [JSONValue] = tree["textStyles"]?.arrayValue ?? []
            for layout in tree["layouts"]?.objectValue?.values.map({ $0 }) ?? [] {
                for box in layout["boxes"]?.arrayValue ?? [] where box["textStyle"]?.objectValue != nil {
                    styles.append(box["textStyle"] ?? .null)
                }
            }
            for style in styles {
                XCTAssertNotNil(style["verticalAlignment"]?.stringValue, "\(document.path): every style is written with its anchor")
            }
        }
    }
}
