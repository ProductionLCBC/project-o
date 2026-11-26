// OApp — Spec 11 §9, the small editors: the Objects page's groups, the selected object, a grade's parameters as the
// sliders show them, what refers to an object, and the edits the page sends.

import Foundation
import OCore

/// Spec 11 §9 — "a list in groups (Grades, Transitions, Audio transitions, Text styles, Macros)", in that order.
public enum ObjectKind: String, Codable, CaseIterable, Sendable {
    case grade, transition, audioTransition, textStyle, macro

    public var type: NumberedType {
        switch self {
        case .grade: .grade
        case .transition: .transition
        case .audioTransition: .audioTransition
        case .textStyle: .textStyle
        case .macro: .macro
        }
    }

}

/// One object on the page: its kind and its number.
public struct ObjectKey: Hashable, Sendable {
    public var kind: ObjectKind
    public var number: Int

    public init(_ kind: ObjectKind, _ number: Int) {
        self.kind = kind
        self.number = number
    }

    /// Spec 5 §6 — "Transitions 1–3 can't be deleted, renumbered or swapped"; Spec 11 §9 as corrected 2026-11-25 —
    /// "1–3 keep their [type]".
    public var isProtected: Bool { kind == .transition && (1...3).contains(number) }
}

/// Spec 11 §9 — one row of a group, "by number and label".
public struct ObjectRow: Equatable, Sendable {
    public var key: ObjectKey
    public var label: String
}

/// One group of the list.
public struct ObjectGroup: Equatable, Sendable {
    public var kind: ObjectKind
    public var rows: [ObjectRow]
}

/// Spec 11 §9 — the Objects page: its groups and the object the center edits.
public struct ObjectsPage: Equatable, Sendable {
    public var groups: [ObjectGroup] = []
    /// The chosen object while it exists, else the first object of the first group that has one.
    public var selected: ObjectKey?

    public init() {}

    public static func make(catalog: Catalog, chosen: ObjectKey?) -> ObjectsPage {
        var page = ObjectsPage()
        func group(_ kind: ObjectKind, _ rows: [(Int, String)]) -> ObjectGroup {
            ObjectGroup(kind: kind, rows: rows.sorted { $0.0 < $1.0 }.map { ObjectRow(key: ObjectKey(kind, $0.0), label: $0.1) })
        }
        page.groups = [
            group(.grade, catalog.grades.map { ($0.number, $0.label) }),
            group(.transition, catalog.transitions.map { ($0.number, $0.label) }),
            group(.audioTransition, catalog.audioTransitions.map { ($0.number, $0.label) }),
            group(.textStyle, catalog.textStyles.map { ($0.number, $0.label) }),
            group(.macro, catalog.macros.map { ($0.number, $0.label) }),
        ]
        if let chosen, page.contains(chosen) {
            page.selected = chosen
        } else {
            page.selected = page.groups.lazy.compactMap(\.rows.first).first?.key
        }
        return page
    }

    public func contains(_ key: ObjectKey) -> Bool {
        groups.contains { $0.kind == key.kind && $0.rows.contains { $0.key == key } }
    }
}

/// Spec 11 §9, "Grades" — "Each parameter is a slider with a number field and its identity marked (Spec 1 §2):
/// brightness, contrast and saturation from 0 to 200% (100% is identity), hue from −180° to 180° (0°), opacity from 0
/// to 100% (100%), blur from 0 to the largest radius the grade pass takes (0)", hue from 0° to 360° since Adam's word of
/// 2026-11-26 (G-39). A grade holds brightness as the
/// change from identity (Spec 4 §7 multiplies by 1 + brightness), contrast and saturation as factors, hue in degrees,
/// opacity from 0 to 1 and blur in pixels.
public enum GradeParameter: String, CaseIterable, Sendable {
    case brightness, contrast, saturation, hue, opacity, blur

    /// The blur pass samples up to 32 texels a side at half resolution (Spec 4 §7), so 64 pixels.
    public static let largestBlur = 64.0

    /// The slider's range, as shown.
    public var range: ClosedRange<Double> {
        switch self {
        case .brightness, .contrast, .saturation: 0...200
        case .hue: 0...360
        case .opacity: 0...100
        case .blur: 0...Self.largestBlur
        }
    }

    /// The identity, as shown: where the slider's mark sits.
    public var identity: Double {
        switch self {
        case .brightness, .contrast, .saturation, .opacity: 100
        case .hue, .blur: 0
        }
    }

    /// The value the slider shows for a grade.
    public func shown(_ grade: Grade) -> Double {
        switch self {
        case .brightness: (1 + grade.brightness) * 100
        case .contrast: grade.contrast * 100
        case .saturation: grade.saturation * 100
        // A stored hue outside 0° to 360° (the engine turns by any angle) shows turned into it.
        case .hue: (grade.hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        case .opacity: grade.opacity * 100
        case .blur: grade.blur
        }
    }

    /// The value the grade stores for one shown, held to the slider's range.
    public func stored(_ shown: Double) -> Double {
        let held = min(range.upperBound, max(range.lowerBound, shown))
        let value: Double
        switch self {
        case .brightness: value = held / 100 - 1
        case .contrast, .saturation, .opacity: value = held / 100
        case .hue, .blur: value = held
        }
        return (value * 10000).rounded() / 10000
    }
}

/// Spec 11 §9, "Used by" and §3's `uses` — one thing that refers to an object, as the answer's entries say it.
public enum ObjectUse: Equatable, Sendable {
    case channel(Int, field: String)
    case stack(Int, field: String)
    case slot(stack: Int, channel: Int, fallback: Bool)
    case layout(preset: Int, layout: String)
    case box(preset: Int, layout: String, box: Int, field: String)
    case output(Int, field: String)
    case audioOutput(Int, field: String)
    case cue(list: Int, number: Int?, label: String, isLocal: Bool)
    case macro(Int, command: Int)
    case key(device: String, key: String)
    /// A scheduler entry, by its place.
    case schedule(Int)
    case media(String, field: String)
    case machine(field: String)

    /// Reads a `uses` answer's entries, kind by kind in the answer's order of kinds, and whether there are more.
    public static func read(_ answer: [String: JSONValue]) -> (uses: [ObjectUse], more: Bool) {
        let entries = answer["uses"]?.objectValue ?? [:]
        var found: [ObjectUse] = []
        func each(_ kind: String, _ read: ([String: JSONValue]) -> ObjectUse?) {
            for value in entries[kind]?.arrayValue ?? [] {
                if let entry = value.objectValue, let use = read(entry) { found.append(use) }
            }
        }
        func layout(_ value: JSONValue?) -> String? {
            if let text = value?.stringValue { return text }
            return value?.intValue.map(String.init)
        }
        each("channels") { e in e["channel"]?.intValue.map { .channel($0, field: e["field"]?.stringValue ?? "") } }
        each("stacks") { e in
            guard let stack = e["stack"]?.intValue else { return nil }
            if let slot = e["slot"]?.intValue { return .slot(stack: stack, channel: slot, fallback: e["fallback"] == .bool(true)) }
            return .stack(stack, field: e["field"]?.stringValue ?? "")
        }
        each("presets") { e in
            guard let preset = e["preset"]?.intValue, let key = layout(e["layout"]) else { return nil }
            return .layout(preset: preset, layout: key)
        }
        each("boxes") { e in
            guard let preset = e["preset"]?.intValue, let key = layout(e["layout"]), let box = e["box"]?.intValue else { return nil }
            return .box(preset: preset, layout: key, box: box, field: e["field"]?.stringValue ?? "")
        }
        each("outputs") { e in e["output"]?.intValue.map { .output($0, field: e["field"]?.stringValue ?? "") } }
        each("audiooutputs") { e in e["audiooutput"]?.intValue.map { .audioOutput($0, field: e["field"]?.stringValue ?? "") } }
        each("cues") { e in
            guard let list = e["list"]?.intValue else { return nil }
            return .cue(list: list, number: e["number"]?.intValue, label: e["label"]?.stringValue ?? "", isLocal: e["local"] != nil)
        }
        each("macros") { e in e["macro"]?.intValue.map { .macro($0, command: e["command"]?.intValue ?? 0) } }
        each("keys") { e in
            if let device = e["device"]?.stringValue, let key = e["key"]?.stringValue { return .key(device: device, key: key) }
            return e["at"]?.intValue.map { .schedule($0) }
        }
        each("media") { e in e["media"]?.stringValue.map { .media($0, field: e["field"]?.stringValue ?? "") } }
        each("machine") { e in e["field"]?.stringValue.map { .machine(field: $0) } }
        return (found, answer["more"] == .bool(true))
    }
}

/// Spec 11 §9 — the edits the Objects page sends, each one Spec 5 edit.
public enum ObjectEdits {
    private static func edit(_ type: NumberedType, _ number: Int?, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(.numbered(type, number), action))])
    }

    /// Each field's edit: one `edit.set` (`edit grade 3 set brightness 0.2`, `edit textstyle N FIELD VALUE`).
    public static func set(_ key: ObjectKey, _ path: String, _ value: JSONValue) -> Sending {
        edit(key.kind.type, key.number, .set(path: path, value: value))
    }

    /// "a + row that creates one", at a free number with the type's defaults (a transition's, "a 500 ms dissolve").
    public static func create(_ kind: ObjectKind) -> Sending? {
        edit(kind.type, nil, .create(body: nil, folder: nil, title: nil))
    }

    /// "Duplicate (the UX spec's duplicate-from)".
    public static func duplicate(_ key: ObjectKey) -> Sending? {
        edit(key.kind.type, key.number, .duplicate(to: nil, title: nil, picks: EditPicks()))
    }

    /// "its number, with renumber, or swap for a taken one (Spec 5 §4)".
    public static func renumber(_ key: ObjectKey, to number: Int, swap: Bool) -> Sending? {
        guard !key.isProtected, number >= 1, number != key.number else { return nil }
        return edit(key.kind.type, key.number, swap ? .swap(with: number) : .renumber(to: number))
    }

    public static func delete(_ key: ObjectKey) -> Sending? {
        guard !key.isProtected else { return nil }
        return edit(key.kind.type, key.number, .delete)
    }

    // MARK: - Text styles (Spec 11 §9, "Text styles")

    /// One box that names a style in `fromStyle`: its preset, its layout's key and its place.
    public struct StyledBox: Equatable, Sendable {
        public var preset: Int
        public var layout: String
        public var index: Int
    }

    /// "the boxes that name the style in `fromStyle`", preset by preset, `*` first.
    public static func boxes(naming style: Int, catalog: Catalog) -> [StyledBox] {
        var found: [StyledBox] = []
        for preset in catalog.presets.sorted(by: { $0.number < $1.number }) {
            for key in preset.layouts.keys.sorted() {
                for (index, box) in (preset.layouts[key]?.boxes ?? []).enumerated() where box.textStyle?.fromStyle == style {
                    found.append(StyledBox(preset: preset.number, layout: key.string, index: index))
                }
            }
        }
        return found
    }

    /// "Re-apply to Boxes copies the style's value into every one of them, as one group of `edit.set`s of each box's
    /// `textStyle`"; nil when no box names it.
    public static func reapply(_ style: TextStyle, catalog: Catalog) -> Sending? {
        let boxes = boxes(naming: style.number, catalog: catalog)
        guard !boxes.isEmpty, let value = try? JSONCoding.encode(BoxTextStyle(values: style.values, fromStyle: style.number)) else { return nil }
        return Sending(boxes.map { box in
            .edit(EditCommand(.numbered(.preset, box.preset), .set(path: "layouts.\(box.layout).boxes.\(box.index).textStyle", value: value)))
        })
    }

    // MARK: - Macros (Spec 11 §9, "Macros")

    private static func value(_ entry: GuardedCommand) -> JSONValue {
        (try? JSONCoding.encode(entry)) ?? .null
    }

    /// The palette's Add: "inserts the command after the selected one, or at the end" (§4).
    public static func insert(_ command: Command, after position: Int?, macro: Macro) -> Sending {
        let at = position.map { min($0 + 1, macro.commands.count) } ?? macro.commands.count
        return edit(.macro, macro.number, .insert(path: "commands", at: at, value: value(GuardedCommand(command))))
    }

    /// A row's Edit: one `edit.set` of the command at its place.
    public static func setCommand(_ command: Command, at position: Int, macro: Macro) -> Sending? {
        guard macro.commands.indices.contains(position), macro.commands[position].command != command else { return nil }
        var entry = macro.commands[position]
        entry.command = command
        return edit(.macro, macro.number, .set(path: "commands.\(position)", value: value(entry)))
    }

    /// A row's Remove, by place.
    public static func removeCommand(at position: Int, macro: Macro) -> Sending? {
        guard macro.commands.indices.contains(position) else { return nil }
        return edit(.macro, macro.number, .remove(path: "commands", at: position))
    }

    /// Move Up and Move Down, one place.
    public static func moveCommand(at position: Int, up: Bool, macro: Macro) -> Sending? {
        let target = up ? position - 1 : position + 1
        guard macro.commands.indices.contains(position), macro.commands.indices.contains(target) else { return nil }
        return edit(.macro, macro.number, .move(path: "commands", from: position, at: target))
    }

    /// "Commands as Text works as in §4": one `edit.set` of `commands`, only while no line has an error, and nil when
    /// nothing changed.
    public static func commands(_ text: String, macro: Macro, options: ParseOptions = ParseOptions()) -> Sending? {
        let parsed = CommandsText.parse(text, commands: macro.commands, options: options)
        guard parsed.errors.isEmpty, parsed.commands != macro.commands else { return nil }
        let values = parsed.commands.compactMap { try? JSONCoding.encode($0) }
        guard values.count == parsed.commands.count else { return nil }
        return edit(.macro, macro.number, .set(path: "commands", value: .array(values)))
    }

    /// "A macro that holds an edit says first "This also changes the library.""
    public static func holdsEdit(_ macro: Macro) -> Bool {
        macro.commands.contains { if case .edit = $0.command { return true } else { return false } }
    }
}
