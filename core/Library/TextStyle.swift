// OCore — Spec 1 §2, Text Style.

import Foundation

/// Spec 1 §2 — the Text Style value: "`font` (PostScript name), `size`,
/// `weight`, `color`, `alignment`, `lineSpacing`, `letterSpacing`, `outline`,
/// `shadow`, `allCaps`, variations (a map of OpenType axis tag to value...)".
/// "The same value type is embedded in boxes and in slide-designer text
/// layers." Encoded flat into whichever object carries it.
public struct TextStyleValues: Equatable, Sendable {
    public var font: String
    public var size: TextSize
    public var weight: Double
    public var color: Color
    public var alignment: TextAlignment
    public var lineSpacing: Double
    public var letterSpacing: Double
    public var outline: Outline
    public var shadow: Shadow
    public var allCaps: Bool
    public var variations: [String: Double]

    public init(font: String = "HelveticaNeue-Bold", size: TextSize = TextSize(value: 72), weight: Double = 700,
                color: Color = .white, alignment: TextAlignment = .center, lineSpacing: Double = 1.1,
                letterSpacing: Double = 0, outline: Outline = Outline(), shadow: Shadow = Shadow(),
                allCaps: Bool = false, variations: [String: Double] = [:]) {
        self.font = font
        self.size = size
        self.weight = weight
        self.color = color
        self.alignment = alignment
        self.lineSpacing = lineSpacing
        self.letterSpacing = letterSpacing
        self.outline = outline
        self.shadow = shadow
        self.allCaps = allCaps
        self.variations = variations
    }

    enum Keys: String, CodingKey, CaseIterable {
        case font, size, weight, color, alignment, lineSpacing, letterSpacing, outline, shadow, allCaps, variations
    }

    /// Read the values from the container of the object that embeds them.
    init(from c: KeyedDecodingContainer<Keys>) throws {
        font = try c.value(.font, default: "HelveticaNeue-Bold")
        size = try c.value(.size, default: TextSize(value: 72))
        weight = try c.value(.weight, default: 700)
        color = try c.value(.color, default: .white)
        alignment = try c.value(.alignment, default: .center)
        lineSpacing = try c.value(.lineSpacing, default: 1.1)
        letterSpacing = try c.value(.letterSpacing, default: 0)
        outline = try c.value(.outline, default: Outline())
        shadow = try c.value(.shadow, default: Shadow())
        allCaps = try c.value(.allCaps, default: false)
        variations = try c.value(.variations, default: [:])
    }

    func encode(into c: inout KeyedEncodingContainer<Keys>) throws {
        try c.encode(font, forKey: .font)
        try c.encode(size, forKey: .size)
        try c.encode(weight, forKey: .weight)
        try c.encode(color, forKey: .color)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(lineSpacing, forKey: .lineSpacing)
        try c.encode(letterSpacing, forKey: .letterSpacing)
        try c.encode(outline, forKey: .outline)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(allCaps, forKey: .allCaps)
        try c.encode(variations, forKey: .variations)
    }
}

/// Spec 1 §2 — Text Style (numbered, portable): "Text Styles are templates.
/// Applying one copies its values into a box or layer; the copy is then
/// independent."
public struct TextStyle: Codable, Equatable, Sendable {
    public var number: Int
    public var label: String
    public var uuid: UUID
    public var values: TextStyleValues
    public var extra: [String: JSONValue]

    public init(number: Int, label: String = "", uuid: UUID = UUID(), values: TextStyleValues = TextStyleValues(),
                extra: [String: JSONValue] = [:]) {
        self.number = number
        self.label = label
        self.uuid = uuid
        self.values = values
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case number, label, uuid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        label = try c.value(.label, default: "")
        uuid = try c.uuid(.uuid)
        values = try TextStyleValues(from: try decoder.container(keyedBy: TextStyleValues.Keys.self))
        extra = try decoder.unknownKeys(besides: CodingKeys.known.union(TextStyleValues.Keys.known))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(number, forKey: .number)
        try c.encode(label, forKey: .label)
        try c.encode(uuid: uuid, forKey: .uuid)
        var v = encoder.container(keyedBy: TextStyleValues.Keys.self)
        try values.encode(into: &v)
    }
}

/// Spec 1 §2 — Box `textStyle`: "an inline Text Style value, plus `fromStyle`
/// (style number or null). Copied on apply; `fromStyle` only records
/// provenance for re-apply."
public struct BoxTextStyle: Codable, Equatable, Sendable {
    public var values: TextStyleValues
    public var fromStyle: Int?
    public var extra: [String: JSONValue]

    public init(values: TextStyleValues = TextStyleValues(), fromStyle: Int? = nil, extra: [String: JSONValue] = [:]) {
        self.values = values
        self.fromStyle = fromStyle
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case fromStyle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromStyle = try c.decodeIfPresent(Int.self, forKey: .fromStyle)
        values = try TextStyleValues(from: try decoder.container(keyedBy: TextStyleValues.Keys.self))
        extra = try decoder.unknownKeys(besides: CodingKeys.known.union(TextStyleValues.Keys.known))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNullable(fromStyle, forKey: .fromStyle)
        var v = encoder.container(keyedBy: TextStyleValues.Keys.self)
        try values.encode(into: &v)
    }
}
