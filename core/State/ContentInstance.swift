// OCore — Spec 3 §2, content instances.

/// Spec 3 §2 — "`transport` (`playing`, `paused`, `stopped`)".
public enum Transport: String, Codable, Equatable, Sendable {
    case playing
    case paused
    case stopped
}

/// Spec 3 §2 — "`endBehavior` (`loop`, `hold`, `clear`)".
public enum EndBehavior: String, Codable, Equatable, Sendable {
    case loop
    case hold
    case clear
}

/// Spec 3 §2 — the `media` content instance. "`startedAtFrame` is the engine
/// frame on which playback began; the playhead is derived from it by the
/// engine, never stored."
public struct MediaInstance: Codable, Equatable, Sendable {
    /// Spec 1 §4 — `sha256:` followed by 64 lowercase hex characters.
    public var ref: String
    public var inMs: Int?
    public var outMs: Int?
    public var loop: Bool
    public var gainOverride: Double?
    public var syncOffsetMs: Int?
    public var startedAtFrame: Int
    public var transport: Transport
    public var endBehavior: EndBehavior
    public var missing: Bool

    public init(ref: String, inMs: Int? = nil, outMs: Int? = nil, loop: Bool = false,
                gainOverride: Double? = nil, syncOffsetMs: Int? = nil, startedAtFrame: Int,
                transport: Transport = .playing, endBehavior: EndBehavior = .hold, missing: Bool = false) {
        self.ref = ref
        self.inMs = inMs
        self.outMs = outMs
        self.loop = loop
        self.gainOverride = gainOverride
        self.syncOffsetMs = syncOffsetMs
        self.startedAtFrame = startedAtFrame
        self.transport = transport
        self.endBehavior = endBehavior
        self.missing = missing
    }
}

/// Spec 3 §2 — the `text` content instance: "`fields` (map). No look of its
/// own; presets render it."
public struct TextInstance: Codable, Equatable, Sendable {
    public var fields: [String: String]
    public init(fields: [String: String]) { self.fields = fields }
}

/// Spec 3 §2 — the `slide` content instance. "`build` defaults to the slide's
/// final state"; nil here means final.
public struct SlideInstance: Codable, Equatable, Sendable {
    /// Spec 1 §4 — `slide:` followed by the document's UUID.
    public var ref: String
    public var build: Int?
    public var missing: Bool
    public init(ref: String, build: Int? = nil, missing: Bool = false) {
        self.ref = ref
        self.build = build
        self.missing = missing
    }
}

/// Spec 3 §2 — the `input` content instance (live sources, v1.5).
public struct InputInstance: Codable, Equatable, Sendable {
    public var input: Int
    public var frozen: Bool
    public init(input: Int, frozen: Bool = false) {
        self.input = input
        self.frozen = frozen
    }
}

/// Spec 3 §2 and §10 — `ContentInstance`: "case empty, media(Media),
/// text(Fields), slide(Slide), input(Input)". Encoded with a `kind` key and
/// the instance's fields beside it, matching the content shape of Spec 1 §6.
public enum ContentInstance: Codable, Equatable, Sendable {
    case empty
    case media(MediaInstance)
    case text(TextInstance)
    case slide(SlideInstance)
    case input(InputInstance)

    /// The content kind as Spec 1 §6 names it.
    public var kind: String {
        switch self {
        case .empty: return "empty"
        case .media: return "media"
        case .text: return "text"
        case .slide: return "slide"
        case .input: return "input"
        }
    }

    public var isEmpty: Bool {
        if case .empty = self { return true }
        return false
    }

    public var media: MediaInstance? {
        if case .media(let m) = self { return m }
        return nil
    }

    public var slide: SlideInstance? {
        if case .slide(let s) = self { return s }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "empty": self = .empty
        case "media": self = .media(try MediaInstance(from: decoder))
        case "text": self = .text(try TextInstance(from: decoder))
        case "slide": self = .slide(try SlideInstance(from: decoder))
        case "input": self = .input(try InputInstance(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container,
                                                   debugDescription: "unknown content kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .empty: break
        case .media(let m): try m.encode(to: encoder)
        case .text(let t): try t.encode(to: encoder)
        case .slide(let s): try s.encode(to: encoder)
        case .input(let i): try i.encode(to: encoder)
        }
    }
}
