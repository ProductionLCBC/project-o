import AppKit
import XCTest
@testable import OAppUI

/// Adam, 2026-11-25: a grade's tint and a transition's color "snap back". An NSColorWell that isn't continuous sends
/// nothing when the color panel changes its color, so no color edit was ever sent. Here the real color panel picks
/// for a FormColorWell.
@MainActor
final class ColorWellTests: XCTestCase {
    func test_whatThePanelChoosesIsSaidOnceWhenThePanelLetsGoOrTheColorRests() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let well = FormColorWell(label: "Tint")
        well.frame = NSRect(x: 10, y: 10, width: 44, height: 24)
        window.contentView?.addSubview(well)
        var chosen: [NSColor] = []
        well.onChoose = { chosen.append($0) }
        defer { NSColorPanel.shared.orderOut(nil) }
        // A drag across the wheel: three colors, one edit, said when the panel lets the well go.
        well.activate(true)
        XCTAssertTrue(well.isChoosing)
        for green in [0.2, 0.4, 0.6] { NSColorPanel.shared.color = NSColor(srgbRed: 1, green: green, blue: 0, alpha: 1) }
        XCTAssertEqual(chosen.count, 0, "not a step at a time")
        // While it chooses, the page's redraws leave it alone.
        well.show(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertEqual(well.color.usingColorSpace(.sRGB)?.greenComponent ?? 0, 0.6, accuracy: 0.01)
        well.deactivate()
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.usingColorSpace(.sRGB)?.greenComponent ?? 0, 0.6, accuracy: 0.01, "the last one")
        // Left open, the color is said once it has rested.
        well.activate(true)
        NSColorPanel.shared.color = NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        let rested = expectation(description: "rested")
        DispatchQueue.main.asyncAfter(deadline: .now() + FormColorWell.restSeconds + 0.2) { rested.fulfill() }
        wait(for: [rested], timeout: 2)
        XCTAssertEqual(chosen.count, 2)
        well.deactivate()
        XCTAssertEqual(chosen.count, 2, "said once")
    }

    /// Adam, 2026-11-26: a grade's sliders "snap back" when dragged. Let go, a slider keeps the value it sent until the
    /// engine's copy shows it, whatever the page's redraws bring meanwhile.
    func test_aSliderKeepsTheValueItSentUntilItComesBack() {
        let slider = GradeSlider(.brightness)
        slider.release(at: 140)
        XCTAssertFalse(slider.show(100), "the old value, from a redraw before the engine applied the edit")
        XCTAssertEqual(slider.doubleValue, 140)
        XCTAssertTrue(slider.show(140), "the engine's copy has it")
        XCTAssertTrue(slider.show(90), "then another client's edit shows")
        XCTAssertEqual(slider.doubleValue, 90)
    }

    /// Spec 11 §9 as corrected 2026-11-26 (G-43) — the panel's every color as it moves, for the stage that draws the
    /// tint while the panel is open; the edit still once.
    func test_theWellSaysEachColorAsThePanelMoves() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let well = FormColorWell(label: "Tint")
        well.frame = NSRect(x: 10, y: 10, width: 44, height: 24)
        window.contentView?.addSubview(well)
        var changing: [NSColor] = []
        var chosen: [NSColor] = []
        well.onChanging = { changing.append($0) }
        well.onChoose = { chosen.append($0) }
        defer { NSColorPanel.shared.orderOut(nil) }
        well.activate(true)
        for green in [0.2, 0.4, 0.6] { NSColorPanel.shared.color = NSColor(srgbRed: 1, green: green, blue: 0, alpha: 1) }
        XCTAssertEqual(changing.count, 3)
        XCTAssertEqual(chosen.count, 0)
        well.deactivate()
        XCTAssertEqual(chosen.count, 1)
    }

    /// G-43 — a grade's slider says each step of a drag, and its value to send once let go.
    func test_aSliderSaysEachStepOfADragAndItsValueOnceLetGo() {
        let slider = GradeSlider(.saturation)
        var slid: [Double] = []
        var released: [Double] = []
        slider.onSlide = { slid.append($0) }
        slider.onRelease = { released.append($0) }
        slider.slide(to: 120)
        slider.slide(to: 140)
        XCTAssertEqual(slid, [120, 140])
        XCTAssertEqual(released, [])
        slider.dragEnded()
        XCTAssertEqual(released, [140])
    }

    /// Spec 11 §9 (G-40) — "a double-click putting it back to its identity", sent as one edit.
    func test_aDoubleClickPutsASliderBack() {
        let slider = GradeSlider(.contrast)
        var sent: [Double] = []
        slider.onRelease = { sent.append($0) }
        slider.release(at: 150)
        slider.reset()
        XCTAssertEqual(sent, [150, 100], "contrast's identity is 100%")
        XCTAssertEqual(slider.doubleValue, 100)
    }
}
