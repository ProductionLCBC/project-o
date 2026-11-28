// OCore — Spec 5 §3 and §6: the parts of an object an edit can name by a
// path, and what each part takes.
//
// "Parts of an object are named by a path: field names as they appear on
// disk, joined by dots, with array positions as numbers from 0 and map keys
// as written" (Spec 5 §3). Check 3 asks that the path "exists in the object's
// JSON Schema ... and is editable", check 4 that the value "has the field's
// type and enum, and it is in range" (Spec 5 §6). The tables here say both
// for the objects Area 14 edits; a test holds each to its schema in
// `formats/schemas`.

import Foundation

/// Spec 5 §6, checks 3 and 4 — one part of an object: what a value there
/// must be, and what lies under it.
indirect enum EditField: Sendable {
    case text
    case flag
    case whole(min: Int? = nil, max: Int? = nil)
    case number(min: Double? = nil, max: Double? = nil)
    /// One of a set of words (`alignment`, `base`).
    case choice([String])
    /// One of a set of whole numbers (a decoder cap of 2 or 3).
    case wholeChoice([Int])
    /// A number that names an object (Spec 1 §4).
    case reference(NumberedType)
    /// The part may be `null` (Spec 5 §3: "`null` is a value, which clears a nullable field").
    case optional(EditField)
    /// Named fields. `optional` are the keys a document may leave out, which
    /// `unset` can remove (Spec 5 §4).
    case record([String: EditField], optional: Set<String> = [])
    /// Entries under keys as written: a preset's `layouts`, a style's `variations`.
    case map(EditField, keys: MapKeys)
    /// An array, its items named by position.
    case list(EditField)
    /// One of several shapes (`binding`, `fit`, `renderSize`).
    case either([EditField])
    /// Exactly this word (`"largest"`, a binding's `kind`).
    case literal(String)
    /// A macro's commands: command objects, checked as a cue's are.
    case commands
    /// Reserved and kept as read (a layout's `mask`).
    case anything
    /// There, and never edited (Spec 5 §6: "`uuid`, `schema`, `app`, `kind`,
    /// `version`, `builtIn` and `number` never are").
    case readOnly(EditField)

    enum MapKeys: Sendable {
        /// Spec 1 §2 — "a map from stack number to a layout, plus one entry under `"*"`".
        case layout
        /// An OpenType axis tag (`wght`, `wdth`, `opsz`).
        case axis

        func accepts(_ key: String) -> Bool {
            switch self {
            case .layout: return LayoutKey(string: key) != nil
            case .axis: return !key.isEmpty
            }
        }
    }
}

// MARK: - Values (Spec 5 §6, check 4)

extension EditField {
    /// Why `value` can't go here, or nil when it can.
    func problem(with value: JSONValue) -> String? {
        switch self {
        case .text:
            return value.stringValue == nil ? "is a string" : nil
        case .flag:
            return value.boolValue == nil ? "is true or false" : nil
        case .whole(let min, let max):
            guard let n = value.intValue else { return "is a whole number" }
            if let min, n < min { return max.map { "is \(min) to \($0)" } ?? "is \(min) or more" }
            if let max, n > max { return min.map { "is \($0) to \(max)" } ?? "is \(max) or less" }
            return nil
        case .number(let min, let max):
            guard let n = value.doubleValue else { return "is a number" }
            if let min, n < min { return max.map { "is \(EditField.plain(min)) to \(EditField.plain($0))" } ?? "is \(EditField.plain(min)) or more" }
            if let max, n > max { return min.map { "is \(EditField.plain($0)) to \(EditField.plain(max))" } ?? "is \(EditField.plain(max)) or less" }
            return nil
        case .choice(let words):
            guard let s = value.stringValue, words.contains(s) else { return "is one of " + words.joined(separator: ", ") }
            return nil
        case .wholeChoice(let numbers):
            guard let n = value.intValue, numbers.contains(n) else { return "is " + numbers.map(String.init).joined(separator: " or ") }
            return nil
        case .reference(let type):
            guard let n = value.intValue, n >= 1 else { return "is a \(type.displayName) number, 1 or more" }
            return nil
        case .optional(let field):
            return value.isNull ? nil : field.problem(with: value)
        case .record(let fields, let optional):
            guard let members = value.objectValue else { return "is an object" }
            for key in fields.keys.sorted() {
                guard let field = fields[key] else { continue }
                if let member = members[key] {
                    if let problem = field.problem(with: member) { return "has a \(key) that \(problem)" }
                } else if !optional.contains(key) {
                    return "needs \(key)"
                }
            }
            return nil
        case .map(let field, let keys):
            guard let members = value.objectValue else { return "is an object" }
            for key in members.keys.sorted() {
                guard keys.accepts(key) else { return "has a key, \(key), it can't have" }
                if let member = members[key], let problem = field.problem(with: member) { return "has a \(key) that \(problem)" }
            }
            return nil
        case .list(let field):
            guard let items = value.arrayValue else { return "is an array" }
            for (index, item) in items.enumerated() {
                if let problem = field.problem(with: item) { return "has an item, \(index), that \(problem)" }
            }
            return nil
        case .either(let fields):
            if fields.contains(where: { $0.problem(with: value) == nil }) { return nil }
            return fields.first?.problem(with: value) ?? "is none of its shapes"
        case .literal(let word):
            return value.stringValue == word ? nil : "is \"\(word)\""
        case .commands:
            return value.arrayValue == nil ? "is an array of commands" : nil
        case .anything:
            return nil
        case .readOnly(let field):
            return field.problem(with: value)
        }
    }

    private static func plain(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(n)
    }

    /// The shape of `either` that `value` has, or the field itself.
    func shape(of value: JSONValue?) -> EditField {
        switch self {
        case .either(let fields):
            guard let value else { return self }
            return fields.first { $0.problem(with: value) == nil } ?? self
        case .optional(let field):
            if let value, !value.isNull { return field.shape(of: value) }
            return self
        case .readOnly(let field):
            return field.shape(of: value)
        default:
            return self
        }
    }
}

// MARK: - References in a value (Spec 5 §6, check 5; Spec 1 §4)

extension EditField {
    /// `value` with every number that names an object passed through
    /// `transform`: what an edit's check 5 reads, and what a renumber rewrites
    /// in the value of an edit a cue or macro holds (Spec 1 §4, "every
    /// internal reference"). A layout's key names a stack, so it follows too.
    func mappingReferences(in value: JSONValue, _ transform: (NumberedType, Int) -> Int) -> JSONValue {
        switch self {
        case .reference(let type):
            guard let n = value.intValue else { return value }
            return .number(Double(transform(type, n)))
        case .optional(let field), .readOnly(let field):
            return value.isNull ? value : field.mappingReferences(in: value, transform)
        case .record(let fields, _):
            guard var members = value.objectValue else { return value }
            for (key, field) in fields {
                if let member = members[key] { members[key] = field.mappingReferences(in: member, transform) }
            }
            return .object(members)
        case .map(let field, let keys):
            guard let members = value.objectValue else { return value }
            var out: [String: JSONValue] = [:]
            for (key, member) in members {
                var name = key
                if case .layout = keys, case .stack(let stack)? = LayoutKey(string: key) { name = String(transform(.stack, stack)) }
                out[name] = field.mappingReferences(in: member, transform)
            }
            return .object(out)
        case .list(let field):
            guard let items = value.arrayValue else { return value }
            return .array(items.map { field.mappingReferences(in: $0, transform) })
        case .either:
            let shape = shape(of: value)
            if case .either = shape { return value }
            return shape.mappingReferences(in: value, transform)
        case .commands:
            guard let items = value.arrayValue else { return value }
            return .array(items.map { item in
                guard let entry = try? JSONCoding.decode(GuardedCommand.self, from: item) else { return item }
                var mapped = entry
                mapped.command = entry.command.mapReferences(transform)
                mapped.when = entry.when?.mapReferences(transform)
                // A command no number of which moved stays as it was written.
                guard mapped != entry else { return item }
                return (try? JSONCoding.encode(mapped)) ?? item
            })
        case .text, .flag, .whole, .number, .choice, .wholeChoice, .literal, .anything:
            return value
        }
    }

    /// Every number in `value` that names an object.
    func references(in value: JSONValue) -> [(type: NumberedType, number: Int)] {
        var out: [(type: NumberedType, number: Int)] = []
        _ = mappingReferences(in: value) { type, number in
            out.append((type, number))
            return number
        }
        return out
    }
}

// MARK: - A field from the table alone

extension EditField {
    /// The concrete shapes this field can take, with what wraps them taken off.
    var shapes: [EditField] {
        switch self {
        case .readOnly(let field), .optional(let field): return field.shapes
        case .either(let fields): return fields.flatMap(\.shapes)
        default: return [self]
        }
    }

    /// The field a path names, read from the table without an object: what
    /// the value of an edit that isn't being applied, one a cue or a macro
    /// holds, is. Where a part has several shapes the path may fit more than
    /// one, and the value picks.
    func field(at path: EditPath) -> EditField? {
        var candidates: [EditField] = [self]
        for component in path.components {
            var next: [EditField] = []
            for shape in candidates.flatMap(\.shapes) {
                switch shape {
                case .record(let fields, _):
                    if let field = fields[component] { next.append(field) }
                case .map(let element, let keys):
                    if keys.accepts(component) { next.append(element) }
                case .list(let element):
                    if Int(component) != nil { next.append(element) }
                default:
                    break
                }
            }
            if next.isEmpty { return nil }
            candidates = next
        }
        return candidates.count == 1 ? candidates[0] : .either(candidates)
    }
}

// MARK: - Paths (Spec 5 §3; §6, check 3)

/// Spec 5 §3 — "field names as they appear on disk, joined by dots, with
/// array positions as numbers from 0 and map keys as written".
struct EditPath: Equatable, Sendable {
    var components: [String]

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { return nil }
        components = parts
    }

    init(components: [String]) {
        self.components = components
    }

    var text: String { components.joined(separator: ".") }
    var parent: EditPath { EditPath(components: Array(components.dropLast())) }
    var last: String { components.last ?? "" }
}

/// What a path names in one object: the part's field, the value there now,
/// and how it sits in its parent.
struct EditPlace {
    enum Parent { case root, record(optionalKey: Bool), map, list }
    var field: EditField
    /// The value at the path, or nil when a map has no such entry or a
    /// record's optional key is left out.
    var value: JSONValue?
    var parent: Parent
    /// The part, or something above it, is never edited.
    var readOnly: Bool
}

enum EditPathError: Error, Equatable {
    /// Spec 5 §6 — `unknownPath`, with the first component that names nothing.
    case unknown(String)
}

extension EditField {
    /// Spec 5 §6, check 3 — "The path. It exists in the object's JSON
    /// Schema": the part `path` names in `object`, an object's JSON form.
    func place(_ path: EditPath, in object: JSONValue) throws -> EditPlace {
        var field = self
        var value: JSONValue? = object
        var parent = EditPlace.Parent.root
        var readOnly = false
        for (index, component) in path.components.enumerated() {
            var shape = field
            // Step through what wraps the part: read-only, nullable, one of several shapes.
            unwrapping: while true {
                switch shape {
                case .readOnly(let inner):
                    readOnly = true
                    shape = inner
                case .optional(let inner):
                    guard let present = value, !present.isNull else { throw EditPathError.unknown(component) }
                    shape = inner
                case .either:
                    let chosen = shape.shape(of: value)
                    if case .either = chosen { throw EditPathError.unknown(component) }
                    shape = chosen
                default:
                    break unwrapping
                }
            }
            switch shape {
            case .record(let fields, let optional):
                guard let next = fields[component] else { throw EditPathError.unknown(component) }
                field = next
                value = value?[component]
                parent = .record(optionalKey: optional.contains(component))
            case .map(let element, let keys):
                guard keys.accepts(component) else { throw EditPathError.unknown(component) }
                field = element
                value = value?[component]
                parent = .map
            case .list(let element):
                guard let position = Int(component), position >= 0, let items = value?.arrayValue, position < items.count else {
                    throw EditPathError.unknown(component)
                }
                field = element
                value = items[position]
                parent = .list
            default:
                throw EditPathError.unknown(component)
            }
            // A part that isn't there has nothing under it.
            if value == nil, index < path.components.count - 1 { throw EditPathError.unknown(path.components[index + 1]) }
        }
        if case .readOnly = field { readOnly = true }
        return EditPlace(field: field, value: value, parent: parent, readOnly: readOnly)
    }
}

extension JSONValue {
    /// This tree with the value at `path` replaced, or the entry made in a map
    /// or record. Nothing changes when the path's parent isn't there.
    func replacing(_ path: ArraySlice<String>, with value: JSONValue) -> JSONValue {
        guard let first = path.first else { return value }
        let rest = path.dropFirst()
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[first] = value
            } else if let member = members[first] {
                members[first] = member.replacing(rest, with: value)
            }
            return .object(members)
        case .array(var items):
            guard let position = Int(first), position >= 0, position < items.count else { return self }
            items[position] = items[position].replacing(rest, with: value)
            return .array(items)
        default:
            return self
        }
    }

    /// This tree without the member `path` names.
    func removing(_ path: ArraySlice<String>) -> JSONValue {
        guard let first = path.first else { return self }
        let rest = path.dropFirst()
        switch self {
        case .object(var members):
            if rest.isEmpty {
                members[first] = nil
            } else if let member = members[first] {
                members[first] = member.removing(rest)
            }
            return .object(members)
        case .array(var items):
            guard let position = Int(first), position >= 0, position < items.count else { return self }
            if rest.isEmpty {
                items.remove(at: position)
            } else {
                items[position] = items[position].removing(rest)
            }
            return .array(items)
        default:
            return self
        }
    }

    /// The value `path` names, if it is there.
    func value(at path: ArraySlice<String>) -> JSONValue? {
        guard let first = path.first else { return self }
        if let position = Int(first), case .array = self { return self[position]?.value(at: path.dropFirst()) }
        return self[first]?.value(at: path.dropFirst())
    }
}

// MARK: - The objects (Spec 1 §2 and §3)

enum EditFields {
    /// Spec 5 §6, check 3 — "`uuid`, `schema`, `app`, `kind`, `version`,
    /// `builtIn` and `number` never are" editable.
    static let neverEdited: Set<String> = ["uuid", "schema", "app", "kind", "version", "builtIn", "number"]

    private static let identity: [String: EditField] = [
        "number": .readOnly(.whole(min: 1)), "label": .text, "uuid": .readOnly(.text),
    ]

    private static func object(_ fields: [String: EditField], optional: Set<String> = []) -> EditField {
        .record(identity.merging(fields) { _, new in new }, optional: optional)
    }

    static let color: EditField = .record([
        "r": .number(min: 0, max: 1), "g": .number(min: 0, max: 1), "b": .number(min: 0, max: 1), "a": .number(min: 0, max: 1),
    ])

    /// Spec 1 §2 — Channel. Spec 5 §6 — "a decoder cap of 2 or 3", "gain within ±60 dB".
    static let channel: EditField = object([
        "defaultPreset": .reference(.preset),
        "defaults": .record([
            "transition": .reference(.transition), "audioTransition": .reference(.audioTransition), "gain": .number(min: -60, max: 60),
        ]),
        "decoderCap": .optional(.wholeChoice([2, 3])),
        "audioOutputs": .list(.reference(.audioOutput)),
        "renderSize": .either([.literal("largest"), .record(["width": .whole(min: 1), "height": .whole(min: 1)])]),
        "textThumbnail": .choice(["body", "firstLine"]),
        "usualContent": .choice(["media", "text", "slide", "live", "any"]),
    ])

    /// Spec 1 §3 — a slot: "`{channel, preset (number or null), opacity (0–1), mute (bool)}`".
    static let slot: EditField = .record([
        "channel": .reference(.channel), "preset": .optional(.reference(.preset)), "opacity": .number(min: 0, max: 1), "mute": .flag,
    ])

    /// Spec 1 §3 — Stack.
    static let stack: EditField = object([
        "slots": .list(slot),
        "base": .choice(["black", "transparent"]),
        "defaultPreset": .optional(.reference(.preset)),
        "gammaBlend": .flag,
    ])

    /// Spec 1 §2 — Text Style, "The same value type is embedded in boxes".
    private static let textStyleValues: [String: EditField] = [
        "font": .text,
        "size": .record(["value": .number(min: 0), "unit": .choice(["pt", "percent"])]),
        "weight": .number(),
        "color": color,
        "alignment": .choice(["left", "center", "right"]),
        "verticalAlignment": .choice(["top", "center", "bottom"]),
        "lineSpacing": .number(),
        "letterSpacing": .number(),
        "outline": .record(["width": .number(min: 0), "color": color]),
        "shadow": .record(["x": .number(), "y": .number(), "blur": .number(min: 0), "color": color]),
        "allCaps": .flag,
        "variations": .map(.number(), keys: .axis),
    ]

    static let textStyle: EditField = object(textStyleValues)

    /// Spec 1 §2 — a box's `textStyle`: "an inline Text Style value, plus `fromStyle`".
    static let boxTextStyle: EditField = .record(textStyleValues.merging(["fromStyle": .optional(.reference(.textStyle))]) { _, new in new })

    /// Spec 1 §2 — Box. Spec 5 §6 — "box frames 0–1".
    static let box: EditField = .record([
        "binding": .either([
            .record(["kind": .literal("pixels")]),
            .record(["kind": .literal("field"), "name": .text]),
            .record(["kind": .literal("static"), "text": .text]),
        ]),
        "frame": .record([
            "x": .number(min: 0, max: 1), "y": .number(min: 0, max: 1), "w": .number(min: 0, max: 1), "h": .number(min: 0, max: 1),
        ]),
        "fit": .either([
            .choice(["fill", "fit", "stretch", "crop"]),
            .record(["policy": .choice(["shrinkToFit", "maxLines"]), "maxLines": .whole(min: 1), "minSize": .number(min: 0)]),
        ]),
        "textStyle": .optional(boxTextStyle),
        // Spec 1 §2 as corrected 2026-11-25 — "or null": null takes the channel's transition.
        "transition": .optional(.record(["ref": .reference(.transition), "ms": .optional(.whole())])),
        "transitionOnVariableChange": .flag,
        "fallback": .flag,
        "offset": .whole(min: Box.offsetRange.lowerBound, max: Box.offsetRange.upperBound),
        "grade": .optional(.reference(.grade)),
    ], optional: ["textStyle", "transitionOnVariableChange"])

    /// Spec 1 §2 — a layout: "an ordered `boxes` array ... and a `mask` (*reserved*)".
    static let layout: EditField = .record(["boxes": .list(box), "mask": .optional(.anything)])

    /// Spec 1 §2 — Preset.
    static let preset: EditField = object([
        "builtIn": .readOnly(.flag),
        "layouts": .map(layout, keys: .layout),
    ])

    /// Spec 1 §2 — Grade.
    static let grade: EditField = object([
        "hue": .number(), "saturation": .number(min: 0), "brightness": .number(), "contrast": .number(min: 0),
        "blur": .number(min: 0), "tint": color, "opacity": .number(min: 0, max: 1),
    ])

    /// Spec 1 §2 — Transition. Spec 11 §9 as corrected 2026-11-25 — "Every
    /// transition's duration (`ms`), easing and, for a fade, color can be
    /// edited; the type of a new one is picked from the three, and 1–3 keep
    /// theirs (`protected`)", which the shelf's rules check.
    static let transition: EditField = object([
        "type": .choice(["cut", "dissolve", "fadeThroughColor"]),
        "ms": .whole(min: 0),
        "easing": .choice(["linear", "easeIn", "easeOut", "easeInOut"]),
        "color": .optional(color),
        "builtIn": .readOnly(.flag),
    ])

    /// Spec 1 §2 — Audio Transition. Spec 5 §6 — "offsets within ±1000 ms".
    static let audioTransition: EditField = object([
        "type": .choice(["cut", "crossfade", "fadeThroughSilence"]),
        "ms": .whole(min: 0),
        "easing": .choice(["linear", "easeIn", "easeOut", "easeInOut"]),
        "offsetMs": .whole(min: -1000, max: 1000),
    ])

    /// Spec 1 §2 — Macro.
    static let macro: EditField = object(["commands": .commands, "color": color, "tileLabel": .text])

    /// Spec 11 §6 and §11 — what Area 14 edits of an output: "its default
    /// stack ..., and its switch and blackout transitions". The rest of an
    /// output is Area 17's.
    static let output: EditField = .record([
        "defaultStack": .reference(.stack),
        "transitions": .record(["switch": .reference(.transition), "blackout": .reference(.transition)]),
    ])

    /// The fields of an output that wait for Area 17 (Spec 10 §16).
    static let outputLater: Set<String> = ["label", "kind", "device", "format", "colorRange", "genlock", "keyFillPartner", "keyMode"]

    /// The table for a numbered type Area 14 edits; nil for lists, audio
    /// outputs and inputs.
    static func table(for type: NumberedType) -> EditField? {
        switch type {
        case .channel: return channel
        case .stack: return stack
        case .preset: return preset
        case .textStyle: return textStyle
        case .grade: return grade
        case .transition: return transition
        case .audioTransition: return audioTransition
        case .macro: return macro
        case .output: return output
        case .list, .audioOutput, .input: return nil
        }
    }
}
