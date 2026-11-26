import Foundation
import XCTest
import OCore
@testable import OApp

/// Spec 11 §8 — the preset editor as values: the layout tabs with the stacks
/// each draws and the live dot, the boxes top first, a stack's tab that uses
/// the `*` layout, layouts for stacks this Mac doesn't have, the sample, and
/// every edit its controls send, against the recorded fixture (preset 1
/// Default has a `*` layout of a pixel box then a fallback body box, and a
/// layout for stack 2; output 1 shows stack 1).
final class PresetPageTests: XCTestCase {
    private func text(_ sending: Sending?, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let sending else {
            XCTFail("nothing to send", file: file, line: line)
            return []
        }
        for command in sending.commands {
            guard let printed = CommandText.print(command) else {
                XCTFail("\(command.cmd) doesn't print", file: file, line: line)
                continue
            }
            XCTAssertEqual(try? CommandText.parse(printed).get().command, command, printed, file: file, line: line)
        }
        return sending.text
    }

    /// The value an edit sets.
    private func value(_ sending: Sending?) -> JSONValue? {
        guard case .edit(let edit)? = sending?.commands.first, case .set(_, let value) = edit.action else { return nil }
        return value
    }

    private let dots = [OutputDot(number: 1, label: "Main", stack: 1, state: .presenting, isBlackedOut: false)]

    func test_theTabsNameTheStacksEachLayoutDrawsWithTheLiveDot() throws {
        let page = PresetPage.make(catalog: try Recorded.catalog(), preset: 1, tab: .any, dots: dots)
        XCTAssertEqual(page.tabs.map(\.key), [.any, .stack(1), .stack(2)])
        // "Any stack: 1 Main": stack 2 has a layout of its own.
        XCTAssertEqual(page.tabs[0].stacks.map(\.number), [1])
        XCTAssertEqual(page.tabs.map(\.hasOwn), [true, false, true])
        XCTAssertEqual(page.tabs.map(\.isLive), [true, true, false], "output 1 shows stack 1")
        XCTAssertTrue(page.ownsLayout)
        XCTAssertEqual(page.shownOn, [1])
        // "in z-order with the top box first (the layout's `boxes` run bottom to top)".
        XCTAssertEqual(page.boxes.map(\.index), [1, 0])
        XCTAssertEqual(page.boxes.map(\.binding), [.field(name: "body"), .pixels])
        // "A stack's tab without a layout of its own says "Uses the * layout"".
        let one = PresetPage.make(catalog: try Recorded.catalog(), preset: 1, tab: .stack(1), dots: dots)
        XCTAssertFalse(one.ownsLayout)
        XCTAssertEqual(one.layout, page.layout)
        XCTAssertEqual(one.path, "1")
        let two = PresetPage.make(catalog: try Recorded.catalog(), preset: 1, tab: .stack(2), dots: dots)
        XCTAssertTrue(two.ownsLayout)
        XCTAssertEqual(two.boxes.map(\.offset), [1, 0])
        XCTAssertEqual(two.shownOn, [], "stack 2 is on no output")
    }

    /// "A layout for a stack this machine doesn't have stays in the preset, listed under "Other stacks"".
    func test_aLayoutForAStackThisMacDoesntHaveIsListedUnderOtherStacks() throws {
        var catalog = try Recorded.catalog()
        let at = try XCTUnwrap(catalog.presets.firstIndex { $0.number == 3 })
        catalog.presets[at].layouts[.stack(7)] = Layout(boxes: [])
        let page = PresetPage.make(catalog: catalog, preset: 3, tab: .stack(7), dots: dots)
        XCTAssertEqual(page.otherStacks, [7])
        XCTAssertEqual(page.tab, .stack(7))
        XCTAssertTrue(page.ownsLayout)
        XCTAssertEqual(PresetPage.make(catalog: catalog, preset: 3, tab: .stack(9), dots: dots).tab, .any, "a tab not there falls back to *")
        XCTAssertNil(PresetPage.make(catalog: catalog, preset: 99, tab: .any, dots: dots).preset)
    }

    func test_theSampleIsTheCuesTextOrTheBuiltInLoremIpsum() {
        var sample = LayoutSample()
        guard case .object(let builtIn) = sample.value else { return XCTFail("an object") }
        XCTAssertEqual(builtIn["content"]?.objectValue?["fields"]?.objectValue?["title"], .string("Lorem Ipsum"))
        XCTAssertEqual(builtIn["next"]?.arrayValue?.count, 3, "the built-in sample's next verses, for boxes at an offset")
        XCTAssertNil(builtIn["cue"])
        sample.fields = ["body": "Praise God"]
        sample.listUuid = "a9f00000-0000-4000-8000-000000000007"
        sample.cue = "11aa0000-0000-4000-8000-000000000001"
        guard case .object(let fromCue) = sample.value else { return XCTFail("an object") }
        XCTAssertEqual(fromCue["listUuid"], .string("a9f00000-0000-4000-8000-000000000007"))
        XCTAssertEqual(fromCue["cue"], .string("11aa0000-0000-4000-8000-000000000001"))
        XCTAssertNil(fromCue["next"], "the next cues write no text")
        sample.kind = .empty
        XCTAssertEqual(sample.value, .object(["content": .object(["kind": .string("empty")])]))
        sample.kind = .media
        XCTAssertEqual(sample.value, .object(["content": .object(["kind": .string("pattern")])]), "the engine's test pattern at first")
        sample.media = "sha256:55"
        XCTAssertEqual(sample.value, .object(["content": .object(["kind": .string("media"), "ref": .string("sha256:55")])]))
    }

    func test_eachControlSendsItsEdit() throws {
        let catalog = try Recorded.catalog()
        let preset = try XCTUnwrap(catalog.presets.first { $0.number == 1 })
        let style1 = catalog.textStyles.first { $0.number == 1 }
        XCTAssertEqual(text(PresetEdits.setBox(preset: 1, layout: "*", index: 1, "offset", .number(1))), ["edit preset 1 layouts.*.boxes.1.offset 1"])
        XCTAssertEqual(text(PresetEdits.frame(preset: 1, layout: "2", index: 0, Frame(x: 0.1, y: 0.123456, w: 0.8, h: 1.2))),
                       ["edit preset 1 layouts.2.boxes.0.frame { \"h\": 1, \"w\": 0.8, \"x\": 0.1, \"y\": 0.1235 }"], "normalized, to a ten-thousandth")
        // "Changing between pixels and text sets the whole box in one edit".
        let pixels = try XCTUnwrap(preset.layouts[.any]?.boxes.first)
        let toText = PresetEdits.binding(preset: 1, layout: "*", index: 0, box: pixels, to: .field(name: "title"), style1: style1)
        XCTAssertEqual(text(toText).first?.hasPrefix("edit preset 1 layouts.*.boxes.0 {"), true)
        let made = try JSONCoding.decode(type(of: pixels), from: try XCTUnwrap(value(toText)))
        XCTAssertEqual(made.binding.kind, .field(name: "title"))
        XCTAssertEqual(made.fit, .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24)))
        XCTAssertEqual(made.textStyle?.fromStyle, 1)
        XCTAssertEqual(made.textStyle?.values, style1?.values, "text style 1's value")
        XCTAssertEqual(made.frame, pixels.frame)
        let body = try XCTUnwrap(preset.layouts[.any]?.boxes.last)
        let toPixels = try JSONCoding.decode(type(of: body), from: try XCTUnwrap(value(PresetEdits.binding(preset: 1, layout: "*", index: 1, box: body, to: .pixels, style1: style1))))
        XCTAssertEqual(toPixels.fit, .pixels(.fit))
        XCTAssertNil(toPixels.textStyle, "no style")
        // A field's name alone.
        XCTAssertEqual(text(PresetEdits.binding(preset: 1, layout: "*", index: 1, box: body, to: .field(name: "title"), style1: style1)),
                       ["edit preset 1 layouts.*.boxes.1.binding { \"kind\": \"field\", \"name\": \"title\" }"])
        // Layouts.
        XCTAssertEqual(text(PresetEdits.copyFromAny(preset: preset, stack: 1)).first?.hasPrefix("edit preset 1 layouts.1 { \"boxes\": ["), true)
        XCTAssertEqual(text(PresetEdits.removeLayout(preset: 1, stack: 2)), ["edit preset 1 unset layouts.2"])
        // Boxes.
        XCTAssertEqual(text(PresetEdits.moveBox(preset: 1, layout: "*", from: 0, to: 1)), ["edit preset 1 move layouts.*.boxes 0 1"])
        XCTAssertEqual(text(PresetEdits.removeBox(preset: 1, layout: "*", index: 1)), ["edit preset 1 remove layouts.*.boxes 1"])
        let added = PresetEdits.insertBox(preset: 1, layout: "*", at: 2, PresetEdits.newBox(.static(text: "[Time]"), style1: style1))
        XCTAssertEqual(text(added).first?.hasPrefix("edit preset 1 insert layouts.*.boxes 2 {"), true)
        // The text style.
        XCTAssertEqual(text(PresetEdits.style(preset: 1, layout: "*", index: 1, "size.value", .number(60))), ["edit preset 1 layouts.*.boxes.1.textStyle.size.value 60"])
        let applied = try JSONCoding.decode(BoxTextStyle.self, from: try XCTUnwrap(value(PresetEdits.apply(preset: 1, layout: "*", index: 1, style: try XCTUnwrap(catalog.textStyles.last)))))
        XCTAssertEqual(applied.fromStyle, 2)
        // "Save as Style… ... sends one group: `edit textstyle N create` with the box's style, then the box's `fromStyle` set to N."
        let saved = PresetEdits.saveAsStyle(preset: 1, layout: "*", index: 1, values: TextStyleValues(), number: 3, label: "Lyrics")
        XCTAssertEqual(saved?.group, true)
        XCTAssertEqual(text(saved).count, 2)
        XCTAssertEqual(text(saved).first?.hasPrefix("edit textstyle 3 create {"), true)
        XCTAssertEqual(text(saved).last, "edit preset 1 layouts.*.boxes.1.textStyle.fromStyle 3")
        // "N is one more than the highest style number in the catalog or named by any box's `fromStyle`".
        XCTAssertEqual(PresetEdits.nextStyleNumber(catalog: catalog), 3)
        var named = catalog
        named.presets[0].layouts[.any]?.boxes[1].textStyle?.fromStyle = 7
        XCTAssertEqual(PresetEdits.nextStyleNumber(catalog: named), 8, "a deleted style's boxes are never adopted")
        // The preset.
        XCTAssertEqual(text(PresetEdits.create()), ["edit preset create { \"layouts\": { \"*\": { \"boxes\": [], \"mask\": null } } }"])
        XCTAssertEqual(text(PresetEdits.duplicate(preset: 3)), ["edit preset 3 duplicate"])
        XCTAssertEqual(text(PresetEdits.renumber(preset: 3, to: 4, swap: true)), ["edit preset 3 swap 4"])
        XCTAssertEqual(text(PresetEdits.delete(preset: 3)), ["edit preset 3 delete"])
    }

    func test_aBoxStyleSaysWhenItDiffersFromItsStyle() throws {
        let catalog = try Recorded.catalog()
        let style1 = try XCTUnwrap(catalog.textStyles.first { $0.number == 1 })
        var style = BoxTextStyle(values: style1.values, fromStyle: 1)
        XCTAssertFalse(PresetEdits.isChanged(style, catalog: catalog))
        style.values.size = TextSize(value: 40)
        XCTAssertTrue(PresetEdits.isChanged(style, catalog: catalog))
        XCTAssertFalse(PresetEdits.isChanged(BoxTextStyle(values: TextStyleValues(), fromStyle: nil), catalog: catalog))
    }
}
