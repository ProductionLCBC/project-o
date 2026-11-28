// OApp — Spec 11 §8, the preset editor: the preset, its layout tabs and boxes as values, the sample, and the edits its
// controls send.

import Foundation
import OCore

/// Spec 11 §8, "Layouts" — a tab across the top of the canvas: "a tab for the `*` layout and one per stack this
/// machine has, each naming the stacks it draws on this machine ..., with the live dot on those an output shows".
public struct LayoutTab: Equatable, Sendable {
    public var key: LayoutKey
    /// The stacks this machine has that the tab's layout draws: for `*`, those with no layout of their own.
    public var stacks: [Stack]
    /// A stack's tab with a layout of its own; the `*` tab always has one.
    public var hasOwn: Bool
    /// "the live dot on those an output shows".
    public var isLive: Bool
}

/// Spec 11 §8, "Boxes" — a row of the box list, "in z-order with the top box first (the layout's `boxes` run bottom
/// to top), each with its binding and its offset".
public struct PresetBoxRow: Equatable, Sendable {
    /// Its place in the layout's `boxes`, from 0 at the bottom.
    public var index: Int
    public var binding: Binding.Kind
    public var offset: Int
    public var frame: Frame
}

/// One text box whose sample overflowed, from the render's `overflow`.
public struct LayoutOverflow: Equatable, Sendable {
    public var box: Int
    public var offset: Int
    public var linesCut: Int
}

/// Spec 11 §8 — the preset editor, worked out from the catalog and the outputs' dots.
public struct PresetPage: Equatable, Sendable {
    public var presets: [Preset] = []
    public var preset: Preset?
    public var tabs: [LayoutTab] = []
    /// "A layout for a stack this machine doesn't have stays in the preset, listed under "Other stacks"".
    public var otherStacks: [Int] = []
    /// The tab shown.
    public var tab: LayoutKey = .any
    /// What the tab draws: its own layout, or the `*` layout for a stack's tab without one.
    public var layout: Layout?
    /// Whether the tab's layout is its own, and so edited here; a stack's tab without one "says "Uses the * layout"".
    public var ownsLayout = true
    /// Top first.
    public var boxes: [PresetBoxRow] = []
    /// The outputs that show a stack the tab's layout draws: an edit to it shows there at once.
    public var shownOn: [Int] = []

    public init() {}

    public static func make(catalog: Catalog, preset number: Int?, tab: LayoutKey, dots: [OutputDot]) -> PresetPage {
        var page = PresetPage()
        page.presets = catalog.presets.sorted { $0.number < $1.number }
        guard let number, let preset = page.presets.first(where: { $0.number == number }) else { return page }
        page.preset = preset
        let stacks = catalog.stacks.sorted { $0.number < $1.number }
        let shown = Set(dots.filter { $0.state != .absent }.map(\.stack))
        let own = Set(preset.layouts.keys.compactMap { key -> Int? in if case .stack(let n) = key { n } else { nil } })
        let drawnByAny = stacks.filter { !own.contains($0.number) }
        page.tabs = [LayoutTab(key: .any, stacks: drawnByAny, hasOwn: true, isLive: drawnByAny.contains { shown.contains($0.number) })]
        page.tabs += stacks.map { stack in
            LayoutTab(key: .stack(stack.number), stacks: [stack], hasOwn: own.contains(stack.number), isLive: shown.contains(stack.number))
        }
        page.otherStacks = own.subtracting(stacks.map(\.number)).sorted()
        // A tab that isn't here (a stack gone) falls back to `*`.
        page.tab = page.tabs.contains { $0.key == tab } || page.otherStacks.contains(where: { .stack($0) == tab }) ? tab : .any
        page.ownsLayout = preset.layouts[page.tab] != nil
        page.layout = preset.layouts[page.tab] ?? preset.layouts[.any]
        page.boxes = (page.layout?.boxes ?? []).enumerated().reversed().map { index, box in
            PresetBoxRow(index: index, binding: box.binding.kind, offset: box.offset, frame: box.frame)
        }
        let drawn = page.tabs.first { $0.key == page.tab }?.stacks.map(\.number) ?? []
        page.shownOn = dots.filter { $0.state != .absent && drawn.contains($0.stack) }.map(\.number).sorted()
        return page
    }

    /// The layout's key in an edit's path: `*` or the stack's number.
    public var path: String { tab.string }
}

/// Spec 11 §8, "The sample" — "what a channel could hold", the app's alone, never saved in the preset.
public struct LayoutSample: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable { case text, media, empty }

    public var kind = Kind.text
    /// The text sample's fields and where they came from; nil until the page works them out.
    public var fields: [String: String]?
    public var next: [[String: String]] = []
    public var listUuid: String?
    public var isLocal = false
    public var cue: String?
    /// The media sample's item; nil is the engine's test pattern, which the media sample starts on (G-35).
    public var media: String?

    public init() {}

    /// Spec 11 §8 as corrected 2026-11-26 (G-41) — "a built-in sample of placeholder Latin, lorem ipsum, with a title and
    /// a copyright line ... For boxes at an offset, ... the built-in sample's next paragraphs."
    public static let builtInVerses: [String] = [
        "Lorem ipsum dolor sit amet,\nconsectetur adipiscing elit.",
        "Sed do eiusmod tempor incididunt\nut labore et dolore magna aliqua.",
        "Ut enim ad minim veniam,\nquis nostrud exercitation.",
        "Duis aute irure dolor\nin reprehenderit in voluptate.",
    ]
    public static let builtInTitle = "Lorem Ipsum"
    public static let builtInCopyright = "Sample text"

    public static func builtIn(verse: Int) -> [String: String] {
        ["body": builtInVerses[min(verse, builtInVerses.count - 1)], "title": builtInTitle, "copyright": builtInCopyright]
    }

    /// The render query's `sample` (Spec 11 §3).
    public var value: JSONValue {
        var sample: [String: JSONValue] = [:]
        func content(_ fields: [String: String]) -> JSONValue {
            .object(["kind": .string("text"), "fields": .object(fields.mapValues { .string($0) })])
        }
        switch kind {
        case .empty:
            sample["content"] = .object(["kind": .string("empty")])
        case .media:
            // "the engine's test pattern at first (§3), or a pool item chosen after it".
            if let media {
                sample["content"] = .object(["kind": .string("media"), "ref": .string(media)])
            } else {
                sample["content"] = .object(["kind": .string("pattern")])
            }
        case .text:
            sample["content"] = content(fields ?? Self.builtIn(verse: 0))
            let later = fields == nil ? (1...3).map { Self.builtIn(verse: $0) } : next
            if !later.isEmpty { sample["next"] = .array(later.prefix(3).map(content)) }
            if fields != nil, let listUuid, let cue {
                sample[isLocal ? "local" : "listUuid"] = .string(listUuid)
                sample["cue"] = .string(cue)
            }
        }
        return .object(sample)
    }
}

/// Spec 11 §8 — the edits the preset editor sends, each one Spec 5 edit.
public enum PresetEdits {
    private static func edit(_ address: EditAddress, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(address, action))])
    }

    private static func boxPath(_ layout: String, _ index: Int) -> String { "layouts.\(layout).boxes.\(index)" }

    /// "each an `edit.set` of `layouts.L.boxes.I.FIELD` on commit".
    public static func setBox(preset: Int, layout: String, index: Int, _ field: String, _ value: JSONValue) -> Sending {
        edit(.numbered(.preset, preset), .set(path: "\(boxPath(layout, index)).\(field)", value: value))
    }

    /// "one `edit.set` of the box's `frame`, normalized to the stack's size", to a ten-thousandth.
    public static func frame(preset: Int, layout: String, index: Int, _ frame: Frame) -> Sending {
        func n(_ value: Double) -> JSONValue { .number((min(1, max(0, value)) * 10000).rounded() / 10000) }
        return setBox(preset: preset, layout: layout, index: index, "frame",
                      .object(["x": n(frame.x), "y": n(frame.y), "w": n(frame.w), "h": n(frame.h)]))
    }

    /// "Changing between pixels and text sets the whole box in one edit, so it never holds half of each: a box that
    /// becomes text gets `shrinkToFit` and text style 1's value (the type's defaults when there is no style 1), and
    /// one that becomes pixels gets `fit` and no style." A field's name or a static text changes alone.
    public static func binding(preset: Int, layout: String, index: Int, box: Box, to kind: Binding.Kind, style1: TextStyle?) -> Sending? {
        var changed = box
        changed.binding = Binding(kind: kind)
        if changed.binding.isText == box.binding.isText {
            guard let value = try? JSONCoding.encode(changed.binding) else { return nil }
            return setBox(preset: preset, layout: layout, index: index, "binding", value)
        }
        if changed.binding.isText {
            changed.fit = .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24))
            changed.textStyle = BoxTextStyle(values: style1?.values ?? TextStyleValues(), fromStyle: style1?.number)
        } else {
            changed.fit = .pixels(.fit)
            changed.textStyle = nil
            changed.transitionOnVariableChange = false
            // Spec 1 §2 as corrected 2026-11-25 — "a pixel box always takes the channel's".
            changed.transition = nil
        }
        guard let value = try? JSONCoding.encode(changed) else { return nil }
        return edit(.numbered(.preset, preset), .set(path: boxPath(layout, index), value: value))
    }

    /// "Copy from \*, which sets `layouts.S` to a copy of the `*` layout (`edit.set`)".
    public static func copyFromAny(preset: Preset, stack: Int) -> Sending? {
        guard let any = preset.layouts[.any], let value = try? JSONCoding.encode(any) else { return nil }
        return edit(.numbered(.preset, preset.number), .set(path: "layouts.\(stack)", value: value))
    }

    /// "Remove This Stack's Layout (`edit preset P unset layouts.S`)".
    public static func removeLayout(preset: Int, stack: Int) -> Sending {
        edit(.numbered(.preset, preset), .unset(path: "layouts.\(stack)"))
    }

    /// "Rows drag to reorder (`edit.move` on `layouts.L.boxes`, by position)", places counted from 0 at the bottom.
    public static func moveBox(preset: Int, layout: String, from: Int, to: Int) -> Sending {
        edit(.numbered(.preset, preset), .move(path: "layouts.\(layout).boxes", from: from, at: to))
    }

    /// "Add Box ▸ ... inserts a box at the top with a frame in the canvas's middle (`edit.insert`)"; Duplicate "inserts
    /// a copy above it".
    public static func insertBox(preset: Int, layout: String, at index: Int, _ box: Box) -> Sending? {
        guard let value = try? JSONCoding.encode(box) else { return nil }
        return edit(.numbered(.preset, preset), .insert(path: "layouts.\(layout).boxes", at: index, value: value))
    }

    /// "Remove (`edit.remove`)".
    public static func removeBox(preset: Int, layout: String, index: Int) -> Sending {
        edit(.numbered(.preset, preset), .remove(path: "layouts.\(layout).boxes", at: index))
    }

    /// A new box of a kind, "with a frame in the canvas's middle": text boxes carry style 1's value.
    public static func newBox(_ kind: Binding.Kind, style1: TextStyle?) -> Box {
        let frame = Frame(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        let binding = Binding(kind: kind)
        guard binding.isText else { return Box(binding: binding, frame: frame, fit: .pixels(.fit)) }
        return Box(binding: binding, frame: frame, fit: .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24)),
                   textStyle: BoxTextStyle(values: style1?.values ?? TextStyleValues(), fromStyle: style1?.number))
    }

    /// "Each change sets one field of `textStyle`."
    public static func style(preset: Int, layout: String, index: Int, _ field: String, _ value: JSONValue) -> Sending {
        setBox(preset: preset, layout: layout, index: index, "textStyle.\(field)", value)
    }

    /// "Apply Style ▸ copies a numbered style's value into the box and sets `fromStyle` (one `edit.set` of
    /// `textStyle`). Re-apply copies the style's current value again."
    public static func apply(preset: Int, layout: String, index: Int, style: TextStyle) -> Sending? {
        guard let value = try? JSONCoding.encode(BoxTextStyle(values: style.values, fromStyle: style.number)) else { return nil }
        return setBox(preset: preset, layout: layout, index: index, "textStyle", value)
    }

    /// "Save as Style… asks for a name and sends one group: `edit textstyle N create` with the box's style, then the
    /// box's `fromStyle` set to N."
    public static func saveAsStyle(preset: Int, layout: String, index: Int, values: TextStyleValues, number: Int, label: String) -> Sending? {
        guard case .object(var body)? = try? JSONCoding.encode(TextStyle(number: number, label: label, values: values)) else { return nil }
        body["number"] = nil
        body["uuid"] = nil
        let create = Command.edit(EditCommand(.numbered(.textStyle, number), .create(body: .object(body), folder: nil, title: nil)))
        let from = Command.edit(EditCommand(.numbered(.preset, preset), .set(path: "\(boxPath(layout, index)).textStyle.fromStyle", value: .number(Double(number)))))
        return Sending([create, from])
    }

    /// "N is one more than the highest style number in the catalog or named by any box's `fromStyle`".
    public static func nextStyleNumber(catalog: Catalog) -> Int {
        let named = catalog.presets.flatMap { $0.layouts.values.flatMap { $0.boxes.compactMap { $0.textStyle?.fromStyle } } }
        return (catalog.textStyles.map(\.number) + named).max().map { $0 + 1 } ?? 1
    }

    /// Whether a box's style differs from the numbered style it came from: the form says "changed".
    public static func isChanged(_ style: BoxTextStyle, catalog: Catalog) -> Bool {
        guard let from = style.fromStyle, let numbered = catalog.textStyles.first(where: { $0.number == from }) else { return false }
        return numbered.values != style.values
    }

    // MARK: - The preset itself

    public static func set(preset: Int, _ path: String, _ value: JSONValue) -> Sending {
        edit(.numbered(.preset, preset), .set(path: path, value: value))
    }

    /// "New Preset (`edit preset create`, with an empty `*` layout)".
    public static func create() -> Sending {
        edit(.numbered(.preset, nil), .create(body: .object(["layouts": .object(["*": .object(["boxes": .array([]), "mask": .null])])]),
                                              folder: nil, title: nil))
    }

    public static func duplicate(preset: Int) -> Sending { edit(.numbered(.preset, preset), .duplicate(to: nil, title: nil, picks: EditPicks())) }

    public static func renumber(preset: Int, to number: Int, swap: Bool) -> Sending {
        edit(.numbered(.preset, preset), swap ? .swap(with: number) : .renumber(to: number))
    }

    public static func delete(preset: Int) -> Sending { edit(.numbered(.preset, preset), .delete) }
}
