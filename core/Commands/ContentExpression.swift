// OCore — Spec 1 §6 and Spec 2 §2, content expressions and riders.

/// Spec 2 §2 — `scope := once | track`.
public enum Scope: String, Codable, Equatable, Sendable {
    case once
    case track
}

/// Spec 1 §6 — `media` content: "`ref` is a hash; optional `in`, `out` in ms,
/// `loop`, `gain` override, `syncOffsetMs` override".
public struct MediaContent: Codable, Equatable, Sendable {
    public var ref: String
    public var inMs: Int?
    public var outMs: Int?
    public var loop: Bool
    public var gain: Double?
    public var syncOffsetMs: Int?

    public init(ref: String, inMs: Int? = nil, outMs: Int? = nil, loop: Bool = false,
                gain: Double? = nil, syncOffsetMs: Int? = nil) {
        self.ref = ref
        self.inMs = inMs
        self.outMs = outMs
        self.loop = loop
        self.gain = gain
        self.syncOffsetMs = syncOffsetMs
    }

    private enum CodingKeys: String, CodingKey {
        case ref
        case inMs = "in"
        case outMs = "out"
        case loop, gain, syncOffsetMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        inMs = try c.decodeIfPresent(Int.self, forKey: .inMs)
        outMs = try c.decodeIfPresent(Int.self, forKey: .outMs)
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? false
        gain = try c.decodeIfPresent(Double.self, forKey: .gain)
        syncOffsetMs = try c.decodeIfPresent(Int.self, forKey: .syncOffsetMs)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encodeIfPresent(inMs, forKey: .inMs)
        try c.encodeIfPresent(outMs, forKey: .outMs)
        if loop { try c.encode(loop, forKey: .loop) }
        try c.encodeIfPresent(gain, forKey: .gain)
        try c.encodeIfPresent(syncOffsetMs, forKey: .syncOffsetMs)
    }
}

/// Spec 1 §6 — `content.kind`: `media`, `text` (`fields` map), `slide`
/// (`ref`, optional `build`), `input` (`input` number), and `empty`.
public enum ContentExpression: Codable, Equatable, Sendable {
    case media(MediaContent)
    case text(fields: [String: String])
    case slide(ref: String, build: Int?)
    case input(Int)
    case empty

    private enum CodingKeys: String, CodingKey { case kind, fields, ref, build, input }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "media":
            self = .media(try MediaContent(from: decoder))
        case "text":
            self = .text(fields: try c.decodeIfPresent([String: String].self, forKey: .fields) ?? [:])
        case "slide":
            self = .slide(ref: try c.decode(String.self, forKey: .ref),
                          build: try c.decodeIfPresent(Int.self, forKey: .build))
        case "input":
            self = .input(try c.decode(Int.self, forKey: .input))
        case "empty":
            self = .empty
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown content kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .media(let m):
            try c.encode("media", forKey: .kind)
            try m.encode(to: encoder)
        case .text(let fields):
            try c.encode("text", forKey: .kind)
            try c.encode(fields, forKey: .fields)
        case .slide(let ref, let build):
            try c.encode("slide", forKey: .kind)
            try c.encode(ref, forKey: .ref)
            try c.encodeIfPresent(build, forKey: .build)
        case .input(let n):
            try c.encode("input", forKey: .kind)
            try c.encode(n, forKey: .input)
        case .empty:
            try c.encode("empty", forKey: .kind)
        }
    }
}

/// Spec 2 §2 — `transition REF [DURATION] SCOPE` and
/// `audiotransition REF [DURATION] SCOPE`; stored as `{ref, ms, scope}`.
public struct TransitionRider: Codable, Equatable, Sendable {
    public var ref: Int
    public var ms: Int?
    public var scope: Scope
    public init(ref: Int, ms: Int? = nil, scope: Scope) {
        self.ref = ref
        self.ms = ms
        self.scope = scope
    }
}

/// Spec 2 §2 — `grade REF [DURATION] SCOPE`; "the grade rider also takes an
/// optional ms over which the change interpolates" (Spec 1 §6).
public struct GradeRider: Codable, Equatable, Sendable {
    public var ref: Int
    public var ms: Int?
    public var scope: Scope
    public init(ref: Int, ms: Int? = nil, scope: Scope) {
        self.ref = ref
        self.ms = ms
        self.scope = scope
    }
}

/// Spec 2 §2 — `gain DECIBELS SCOPE`; stored as `{db, scope}`.
public struct GainRider: Codable, Equatable, Sendable {
    public var db: Double
    public var scope: Scope
    public init(db: Double, scope: Scope) {
        self.db = db
        self.scope = scope
    }
}

/// Spec 2 §2 — `chase SCOPE` (reserved); stored as `{scope}`.
public struct ChaseRider: Codable, Equatable, Sendable {
    public var scope: Scope
    public init(scope: Scope) { self.scope = scope }
}

/// Spec 1 §6 — "Attribute riders on a write: `transition`, `audioTransition`,
/// `grade`, `gain`, `chase`, `build`." `build` has no scope (Spec 2 §2).
public struct Riders: Equatable, Sendable {
    public var transition: TransitionRider?
    public var audioTransition: TransitionRider?
    public var grade: GradeRider?
    public var gain: GainRider?
    public var chase: ChaseRider?
    public var build: Int?

    public init(transition: TransitionRider? = nil, audioTransition: TransitionRider? = nil,
                grade: GradeRider? = nil, gain: GainRider? = nil, chase: ChaseRider? = nil, build: Int? = nil) {
        self.transition = transition
        self.audioTransition = audioTransition
        self.grade = grade
        self.gain = gain
        self.chase = chase
        self.build = build
    }

    public static let none = Riders()
}
