// OCore — Spec 1 §2, Preset, Layout and Box.

import Foundation

/// Spec 1 §2 — a Preset's `layouts` key: "a map from stack number to a
/// layout, plus one entry under `\"*\"` that applies to any stack not named."
public enum LayoutKey: Hashable, Comparable, Sendable {
    case any
    case stack(Int)

    public var string: String {
        switch self {
        case .any: return "*"
        case .stack(let n): return String(n)
        }
    }

    public init?(string: String) {
        if string == "*" {
            self = .any
        } else if let n = Int(string), n > 0, String(n) == string {
            self = .stack(n)
        } else {
            return nil
        }
    }

    public static func < (lhs: LayoutKey, rhs: LayoutKey) -> Bool {
        switch (lhs, rhs) {
        case (.any, .any): return false
        case (.any, .stack): return true
        case (.stack, .any): return false
        case (.stack(let a), .stack(let b)): return a < b
        }
    }
}

/// Spec 1 §2 — Box `binding`: "`{kind: \"pixels\"}`, `{kind: \"field\",
/// name}`, or `{kind: \"static\", text}`. Field names: `body`, `title`,
/// `copyright`, `reference`, or a custom name; static text may contain
/// variables."
public struct Binding: Codable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case pixels
        case field(name: String)
        case `static`(text: String)
    }

    public var kind: Kind
    public var extra: [String: JSONValue]

    public init(kind: Kind, extra: [String: JSONValue] = [:]) {
        self.kind = kind
        self.extra = extra
    }

    public static let pixels = Binding(kind: .pixels)
    public static func field(name: String) -> Binding { Binding(kind: .field(name: name)) }
    public static func `static`(text: String) -> Binding { Binding(kind: .static(text: text)) }

    /// True for the field and static kinds: boxes that render text.
    public var isText: Bool {
        if case .pixels = kind { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case kind, name, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pixels": kind = .pixels
        case "field": kind = .field(name: try c.decode(String.self, forKey: .name))
        case "static": kind = .static(text: try c.decode(String.self, forKey: .text))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown binding kind \(other)")
        }
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .pixels:
            try c.encode("pixels", forKey: .kind)
        case .field(let name):
            try c.encode("field", forKey: .kind)
            try c.encode(name, forKey: .name)
        case .static(let text):
            try c.encode("static", forKey: .kind)
            try c.encode(text, forKey: .text)
        }
    }
}

/// Spec 1 §2 — Box `fit` for pixels: "`fill`, `fit`, `stretch`, `crop`".
public enum PixelFit: String, Codable, Equatable, Sendable {
    case fill, fit, stretch, crop
}

/// Spec 1 §2 — Box `fit` for text: "`{policy: \"shrinkToFit\" or
/// \"maxLines\", maxLines, minSize}`".
public struct TextFit: Codable, Equatable, Sendable {
    public enum Policy: String, Codable, Equatable, Sendable {
        case shrinkToFit, maxLines
    }

    public var policy: Policy
    public var maxLines: Int
    public var minSize: Double
    public var extra: [String: JSONValue]

    public init(policy: Policy = .shrinkToFit, maxLines: Int = 6, minSize: Double = 24, extra: [String: JSONValue] = [:]) {
        self.policy = policy
        self.maxLines = maxLines
        self.minSize = minSize
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case policy, maxLines, minSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.value(.policy, default: .shrinkToFit)
        maxLines = try c.value(.maxLines, default: 6)
        minSize = try c.value(.minSize, default: 24)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policy, forKey: .policy)
        try c.encode(maxLines, forKey: .maxLines)
        try c.encode(minSize, forKey: .minSize)
    }
}

/// Spec 1 §2 — Box `fit`: a word for pixels, an object for text.
public enum BoxFit: Codable, Equatable, Sendable {
    case pixels(PixelFit)
    case text(TextFit)

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let word = try? single.decode(String.self) {
            guard let fit = PixelFit(rawValue: word) else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "unknown fit \(word)")
            }
            self = .pixels(fit)
        } else {
            self = .text(try single.decode(TextFit.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .pixels(let fit): try single.encode(fit)
        case .text(let fit): try single.encode(fit)
        }
    }
}

/// Spec 1 §2 — Box `transition`: "`{ref: transition number, ms: override or
/// null}`. References the same Transition objects channels use."
public struct BoxTransition: Codable, Equatable, Sendable {
    public var ref: Int
    public var ms: Int?
    public var extra: [String: JSONValue]

    public init(ref: Int = 1, ms: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.ref = ref
        self.ms = ms
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case ref, ms }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.value(.ref, default: 1)
        ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encodeNullable(ms, forKey: .ms)
    }
}

/// Spec 1 §2 — Box (child of a Preset layout): `binding`, `frame`, `fit`,
/// `textStyle`, `transition`, `transitionOnVariableChange` ("Default false; a
/// popup box wants true"), `fallback` ("Renders only if no earlier box drew"),
/// `grade` ("Per-box output correction, separate from channel grades").
///
/// As in the §9 example, a pixels box carries no `textStyle` and no
/// `transitionOnVariableChange`; text and static boxes carry both.
public struct Box: Codable, Equatable, Sendable {
    public var binding: Binding
    public var frame: Frame
    public var fit: BoxFit
    public var textStyle: BoxTextStyle?
    public var transition: BoxTransition
    public var transitionOnVariableChange: Bool
    public var fallback: Bool
    public var grade: Int?
    public var extra: [String: JSONValue]

    public init(binding: Binding, frame: Frame = .full, fit: BoxFit, textStyle: BoxTextStyle? = nil,
                transition: BoxTransition = BoxTransition(), transitionOnVariableChange: Bool = false,
                fallback: Bool = false, grade: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.binding = binding
        self.frame = frame
        self.fit = fit
        self.textStyle = textStyle
        self.transition = transition
        self.transitionOnVariableChange = transitionOnVariableChange
        self.fallback = fallback
        self.grade = grade
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case binding, frame, fit, textStyle, transition, transitionOnVariableChange, fallback, grade
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binding = try c.decode(Binding.self, forKey: .binding)
        frame = try c.value(.frame, default: .full)
        fit = try c.value(.fit, default: binding.isText ? .text(TextFit()) : .pixels(.fit))
        textStyle = try c.decodeIfPresent(BoxTextStyle.self, forKey: .textStyle)
        transition = try c.value(.transition, default: BoxTransition())
        transitionOnVariableChange = try c.value(.transitionOnVariableChange, default: false)
        fallback = try c.value(.fallback, default: false)
        grade = try c.decodeIfPresent(Int.self, forKey: .grade)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(binding, forKey: .binding)
        try c.encode(frame, forKey: .frame)
        try c.encode(fit, forKey: .fit)
        if binding.isText {
            try c.encodeNullable(textStyle, forKey: .textStyle)
            try c.encode(transitionOnVariableChange, forKey: .transitionOnVariableChange)
        }
        try c.encode(transition, forKey: .transition)
        try c.encode(fallback, forKey: .fallback)
        try c.encodeNullable(grade, forKey: .grade)
    }
}

/// Spec 1 §2 — a Preset layout: "an ordered `boxes` array (bottom to top
/// within the channel's group) and a `mask` (reserved: alpha image reference
/// and crop)". The mask is kept as it was read.
public struct Layout: Codable, Equatable, Sendable {
    public var boxes: [Box]
    public var mask: JSONValue
    public var extra: [String: JSONValue]

    public init(boxes: [Box], mask: JSONValue = .null, extra: [String: JSONValue] = [:]) {
        self.boxes = boxes
        self.mask = mask
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case boxes, mask }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boxes = try c.value(.boxes, default: [])
        mask = try c.value(.mask, default: .null)
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(boxes, forKey: .boxes)
        try c.encode(mask, forKey: .mask)
    }
}

/// Spec 1 §2 — Preset: `number`, `label`, `uuid`, `builtIn`, `layouts`.
/// "Preset 1 is built in with a single `\"*\"` layout: one pixel box filling
/// the frame, then a fallback body box." Spec 1 §9: "built in, copyable, not
/// deletable."
public struct Preset: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var builtIn: Bool
    public var layouts: [LayoutKey: Layout]
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", uuid: UUID = UUID(), builtIn: Bool = false,
                layouts: [LayoutKey: Layout], extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.builtIn = builtIn
        self.layouts = layouts
        self.extra = extra
    }

    /// Spec 1 §2 — "The `\"*\"` layout covers the rest."
    public func layout(for stack: Int) -> Layout? {
        layouts[.stack(stack)] ?? layouts[.any]
    }

    /// Spec 1 §2 and §9 — the built-in Preset 1 as the app writes it on a
    /// fresh install, used when a library has no preset 1 on disk (§8).
    public static let builtInDefault = Preset(
        number: 1, label: "Default", uuid: UUID(uuidString: "c0de0000-0000-4000-8000-000000000001") ?? UUID(), builtIn: true,
        layouts: [.any: Layout(boxes: [
            Box(binding: .pixels, frame: .full, fit: .pixels(.fit), transition: BoxTransition(ref: 1)),
            Box(binding: .field(name: "body"), frame: Frame(x: 0.05, y: 0.1, w: 0.9, h: 0.8),
                fit: .text(TextFit(policy: .shrinkToFit, maxLines: 6, minSize: 24)),
                textStyle: BoxTextStyle(values: TextStyleValues(shadow: Shadow(x: 0, y: 2, blur: 8, color: Color(r: 0, g: 0, b: 0, a: 0.6))), fromStyle: 1),
                transition: BoxTransition(ref: 2, ms: 250), fallback: true),
        ])])

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid, builtIn, layouts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        builtIn = try c.value(.builtIn, default: false)
        var layouts: [LayoutKey: Layout] = [:]
        for (key, layout) in try c.value(.layouts, default: [String: Layout]()) {
            guard let layoutKey = LayoutKey(string: key) else {
                throw DecodingError.dataCorruptedError(forKey: .layouts, in: c, debugDescription: "layout key must be \"*\" or a stack number, not \(key)")
            }
            layouts[layoutKey] = layout
        }
        self.layouts = layouts
        extra = try decoder.unknownKeys(besides: CodingKeys.known)
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        try c.encode(builtIn, forKey: .builtIn)
        try c.encode(Dictionary(uniqueKeysWithValues: layouts.map { ($0.key.string, $0.value) }), forKey: .layouts)
    }
}
