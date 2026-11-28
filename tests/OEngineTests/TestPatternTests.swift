import XCTest
import OCore
@testable import OEngine

/// Spec 11 §3 as corrected 2026-11-24 — the test pattern the engine draws for the preset editor's sample: "a grid at each
/// tenth of the frame, the center lines and a circle, the action-safe and title-safe areas (93% and 90%), and a row of
/// color bars". Its bitmap alone, on the CPU.
final class TestPatternTests: XCTestCase {
    /// A pixel of the BGRA bitmap, as red, green and blue.
    private func pixel(_ data: [UInt8], width: Int, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
    }

    func test_thePatternHasItsBarsCenterLinesAndSafeAreasWhereTheyBelong() throws {
        let width = 1920
        let height = 1080
        let data = [UInt8](TestPattern.bgra(width: width, height: height))
        XCTAssertEqual(data.count, width * height * 4)
        // The color bars across the middle third: 75% white, yellow, cyan, green, magenta, red, blue, left to right.
        let barY = height / 2 + height / 12
        let bar = width / 7
        let white = pixel(data, width: width, bar / 2, barY)
        XCTAssertTrue(white.r > 170 && white.g > 170 && white.b > 170, "\(white)")
        let yellow = pixel(data, width: width, bar + bar / 2, barY)
        XCTAssertTrue(yellow.r > 150 && yellow.g > 150 && yellow.b < 60, "\(yellow)")
        let blue = pixel(data, width: width, 6 * bar + bar / 2, barY)
        XCTAssertTrue(blue.r < 60 && blue.g < 60 && blue.b > 150, "\(blue)")
        // The center lines cross at the middle, bright over the dark ground.
        let center = pixel(data, width: width, width / 2, height / 6)
        XCTAssertGreaterThan(center.r + center.g + center.b, 500, "the vertical center line, above the bars")
        let ground = pixel(data, width: width, width / 2 + width / 20, height / 6 + 7)
        XCTAssertLessThan(ground.r + ground.g + ground.b, 150, "the dark ground between the lines")
        // The action-safe edge (93%) and the title-safe edge (90%), on the left, in the upper band.
        let actionX = Int((Double(width) * 0.035).rounded())
        let titleX = Int((Double(width) * 0.05).rounded())
        let action = pixel(data, width: width, actionX, height / 4 + 3)
        let title = pixel(data, width: width, titleX, height / 4 + 3)
        XCTAssertGreaterThan(action.r + action.g + action.b, 200, "\(action)")
        XCTAssertGreaterThan(title.r + title.g + title.b, 200, "\(title)")
        // Any size draws, and a nonsense size is a single black pixel rather than nothing.
        XCTAssertEqual(TestPattern.bgra(width: 640, height: 360).count, 640 * 360 * 4)
        XCTAssertEqual(TestPattern.bgra(width: 0, height: -4).count, 4)
    }
}
