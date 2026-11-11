import Foundation
import XCTest
@testable import OCore

/// Spec 6 §3 — "Preset 1 is built in and editable ... Its definition lives in
/// code on `main` and changes with this spec. It holds two layouts: `"*"`, as
/// before: a pixel box filling the frame, then a fallback body box. `"2"`, the
/// confidence layout (P13): a body box at 0 for the current cue and a body box
/// at +1 for the next." Spec 6 §9 — the first-run library and stacks, which
/// the fixtures match. Spec 6 §11, Area 6: "Fixtures. The rewritten fixtures
/// load and write back byte for byte (Spec 1 §10), and Preset 1's built-in
/// definition matches `001-default.json`."
final class FirstRunTests: XCTestCase {
    typealias F = FixtureLibrary

    func test_presetOnesBuiltInDefinitionMatchesTheFixture() throws {
        let (library, _, _) = F.load()
        XCTAssertEqual(library.preset(1), Preset.builtInDefault)
        let written = Writer.data(for: .preset(Preset.builtInDefault))
        XCTAssertEqual(written, F.librarySnapshot.files["presets/001-default.json"], "the built-in definition writes the fixture's bytes")
    }

    func test_presetOneHoldsTheConfidenceLayoutForStackTwo() throws {
        let preset = Preset.builtInDefault
        XCTAssertEqual(preset.layouts.keys.sorted(), [.any, .stack(2)])
        let any = try XCTUnwrap(preset.layouts[.any])
        XCTAssertEqual(any.boxes.map(\.binding.kind), [.pixels, .field(name: "body")])
        XCTAssertEqual(any.boxes.map(\.fallback), [false, true])
        XCTAssertEqual(any.boxes.map(\.offset), [0, 0])

        let two = try XCTUnwrap(preset.layouts[.stack(2)])
        XCTAssertEqual(two.boxes.map(\.binding.kind), [.field(name: "body"), .field(name: "body")], "no pixel box")
        XCTAssertEqual(two.boxes.map(\.offset), [0, 1], "the current cue, then the next")
        let current = two.boxes[0], next = two.boxes[1]
        XCTAssertEqual(current.frame, Frame(x: 0.03, y: 0.11, w: 0.94, h: 0.56))
        XCTAssertEqual(current.fit, .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24)))
        XCTAssertEqual(current.textStyle?.values.verticalAlignment, .top)
        XCTAssertEqual(current.textStyle?.values.alignment, .left)
        XCTAssertEqual(current.textStyle?.values.size, TextSize(value: 64, unit: .pt))
        // "The +1 box matches the first apart from offset 1, its frame (y 0.7, h 0.27), the maxLines policy
        // with 3 lines, a grey colour (0.7) and a size of 40 points."
        XCTAssertEqual(next.frame, Frame(x: 0.03, y: 0.7, w: 0.94, h: 0.27))
        XCTAssertEqual(next.fit, .text(TextFit(policy: .maxLines, maxLines: 3, minSize: 24)))
        XCTAssertEqual(next.textStyle?.values.color, Color(r: 0.7, g: 0.7, b: 0.7, a: 1))
        XCTAssertEqual(next.textStyle?.values.size, TextSize(value: 40, unit: .pt))
        var same = next
        same.offset = 0
        same.frame = current.frame
        same.fit = current.fit
        same.textStyle?.values.color = .white
        same.textStyle?.values.size = TextSize(value: 64, unit: .pt)
        XCTAssertEqual(same, current, "nothing else differs")
    }

    /// Spec 6 §9 — the first-run library and stacks, as the fixture holds them.
    func test_theFixtureHoldsTheFirstRunLibraryAndStacks() throws {
        let (library, machine, report) = F.load()
        XCTAssertEqual(report.issues, [])
        XCTAssertEqual(library.channels.map(\.label), ["Background", "Foreground", "Clock"])
        let clock = try XCTUnwrap(library.channel(3))
        XCTAssertEqual(clock.usualContent, .any, "channel 2 stays the only text channel")
        XCTAssertEqual(clock.defaultPreset, 2)
        XCTAssertEqual(clock.audioOutputs, [1])
        XCTAssertEqual(clock.renderSize, .largest)
        XCTAssertEqual(clock.uuid, F.uuid("3c3c", 3))

        XCTAssertEqual(library.presets.map(\.label), ["Default", "Clock", "Lower third", "Credits"])
        let clockPreset = try XCTUnwrap(library.preset(2))
        XCTAssertEqual(clockPreset.layouts.keys.sorted(), [.any])
        XCTAssertEqual(clockPreset.layouts[.any]?.boxes.map(\.binding.kind), [.static(text: "[Time]")])
        XCTAssertEqual(clockPreset.layouts[.any]?.boxes.first?.frame, Frame(x: 0.69, y: 0.01, w: 0.28, h: 0.09), "the top right corner")
        let credits = try XCTUnwrap(library.preset(4))
        XCTAssertEqual(credits.layouts[.any]?.boxes.map(\.binding.kind),
                       ["title", "author", "copyright", "ccli"].map { Binding.Kind.field(name: $0) })
        XCTAssertEqual(credits.uuid, F.uuid("c0de", 4))
        XCTAssertEqual(library.preset(3)?.layouts[.any]?.boxes.first?.binding.kind, .field(name: "title"), "the lower third's title box")
        XCTAssertEqual(library.textStyles.map(\.values.verticalAlignment), [.center, .center])

        let main = try XCTUnwrap(machine.stack(1)), confidence = try XCTUnwrap(machine.stack(2))
        XCTAssertEqual(main.slots.map(\.channel), [1, 2])
        XCTAssertNil(main.defaultPreset)
        XCTAssertEqual(confidence.label, "Confidence")
        XCTAssertEqual(confidence.slots.map(\.channel), [2, 3])
        XCTAssertNil(confidence.defaultPreset, "stack 2 needs no default preset")

        // "On stack 2, channel 2 resolves to Preset 1's "2" layout and channel 3 to the Clock preset."
        func layout(_ slot: StackSlot, on stack: Stack) -> Layout? {
            library.resolvedPreset(slot.preset ?? stack.defaultPreset ?? library.channel(slot.channel)?.defaultPreset).layout(for: stack.number)
        }
        XCTAssertEqual(layout(confidence.slots[0], on: confidence), Preset.builtInDefault.layouts[.stack(2)])
        XCTAssertEqual(layout(confidence.slots[1], on: confidence), clockPreset.layouts[.any])
        XCTAssertEqual(layout(main.slots[1], on: main), Preset.builtInDefault.layouts[.any])
    }
}
