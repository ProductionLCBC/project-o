// OEngine — Spec 4 §4, the frame plan.

import Foundation
import OCore

/// Spec 4 §7 stage 1 — the source layouts the channel shader is specialised
/// for: "NV12, P010, 4:2:2 10-bit, RGBA16, still". `linearRGBA16` is a still
/// already converted to premultiplied linear light (stage 2 still applies);
/// `bgra8sRGB` is a poster or text texture the GPU linearizes on sample;
/// `finished` is channel pixels as rendered (a snapshot): no stage 1, no
/// stage 2.
public enum SourceLayout: String, Codable, Sendable {
    case nv12
    case p010
    case yuv422p10
    case rgba16
    case linearRGBA16
    case bgra8sRGB
    case finished

    /// Spec 4 §7 — "For YCbCr sources: matrix ... range expansion ... then the
    /// transfer function."
    public var isYCbCr: Bool {
        switch self {
        case .nv12, .p010, .yuv422p10: return true
        case .rgba16, .linearRGBA16, .bgra8sRGB, .finished: return false
        }
    }
}

/// Spec 4 §7 — "BT.709 by default, BT.601 for SD-sized sources, BT.2020
/// sources converted to 709 primaries".
public enum ColorMatrix: String, Codable, Sendable {
    case bt709
    case bt601
    case bt2020
}

/// Spec 4 §4 — what a channel pass samples: nothing, a decoded instance picked
/// at step 2 for a media time, or a texture by handle (a still, a poster, a
/// snapshot).
public enum SourceRef: Equatable, Sendable {
    case none
    case instance(InstanceHandle, mediaTimeMs: Double)
    case texture(TextureHandle)
}

extension SourceRef: Codable {
    private enum Key: String, CodingKey { case kind, handle, mediaTimeMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "instance":
            self = .instance(InstanceHandle(rawValue: try c.decode(Int32.self, forKey: .handle)),
                             mediaTimeMs: try c.decode(Double.self, forKey: .mediaTimeMs))
        case "texture": self = .texture(TextureHandle(rawValue: try c.decode(Int32.self, forKey: .handle)))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown source \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .none: try c.encode("none", forKey: .kind)
        case .instance(let handle, let ms):
            try c.encode("instance", forKey: .kind)
            try c.encode(handle.rawValue, forKey: .handle)
            try c.encode(ms, forKey: .mediaTimeMs)
        case .texture(let handle):
            try c.encode("texture", forKey: .kind)
            try c.encode(handle.rawValue, forKey: .handle)
        }
    }
}

/// Spec 4 §4 — a source bound for one pass: the reference, its plane layout,
/// colour matrix and range for stage 1, and its pixel size for the
/// letterboxed fit of Spec 4 §7.
public struct SourceBinding: Equatable, Codable, Sendable {
    public var source: SourceRef
    public var layout: SourceLayout
    public var matrix: ColorMatrix
    public var range: ColorRange
    public var size: PixelSize

    public init(source: SourceRef, layout: SourceLayout, matrix: ColorMatrix, range: ColorRange, size: PixelSize) {
        self.source = source
        self.layout = layout
        self.matrix = matrix
        self.range = range
        self.size = size
    }
}

/// Spec 4 §4 — "the transition (type, progress 0–1 for this tick, easing,
/// colour)". Progress is already eased on the control thread.
public struct TransitionState: Equatable, Codable, Sendable {
    public var type: TransitionType
    public var progress: Float
    public var color: ColorValue?

    public init(type: TransitionType, progress: Float, color: ColorValue?) {
        self.type = type
        self.progress = progress
        self.color = color
    }
}

/// Spec 4 §4 — "ChannelPass names the channel, its target texture, the
/// incoming source ..., the outgoing source if a transition is running, the
/// transition ..., the grade parameters for this tick ... and the channel's
/// render size."
public struct ChannelPass: Equatable, Codable, Sendable {
    public var channel: Int
    public var target: TextureHandle
    public var size: PixelSize
    public var incoming: SourceBinding
    public var outgoing: SourceBinding?
    public var transition: TransitionState?
    public var grade: GradeParameters
    /// Spec 4 §5 — "Mipmaps are generated for a channel texture only on ticks
    /// where a due stack samples it below half scale".
    public var generateMips: Bool
    /// Spec 4 §7 — the outgoing of an interrupted or restarted transition is
    /// the channel texture as it was: on this tick the render thread copies it
    /// into the channel's snapshot texture before rendering (Area 4 reading).
    public var snapshotOutgoing: Bool

    public init(channel: Int, target: TextureHandle, size: PixelSize, incoming: SourceBinding, outgoing: SourceBinding? = nil,
                transition: TransitionState? = nil, grade: GradeParameters = .identity, generateMips: Bool = false,
                snapshotOutgoing: Bool = false) {
        self.channel = channel
        self.target = target
        self.size = size
        self.incoming = incoming
        self.outgoing = outgoing
        self.transition = transition
        self.grade = grade
        self.generateMips = generateMips
        self.snapshotOutgoing = snapshotOutgoing
    }
}

/// Spec 4 §9 — "field: One quad per line, laid out by the cached layout".
public struct TextLine: Equatable, Codable, Sendable {
    public var texture: TextureHandle
    /// The line's frame in stack pixels.
    public var frame: PixelRect

    public init(texture: TextureHandle, frame: PixelRect) {
        self.texture = texture
        self.frame = frame
    }
}

/// Spec 4 §9 — "pixels: A quad placing the channel texture in the box frame
/// by fit mode": the texture, where the quad lands in stack pixels, and which
/// part of the texture it shows.
public struct PixelQuad: Equatable, Codable, Sendable {
    public var texture: TextureHandle
    public var frame: PixelRect
    public var uv: UVRect
    /// Spec 4 §5 — the texture's mip chain was generated this tick, so the
    /// box may sample it; otherwise only level zero holds the picture.
    public var mips: Bool

    public init(texture: TextureHandle, frame: PixelRect, uv: UVRect, mips: Bool = false) {
        self.texture = texture
        self.frame = frame
        self.uv = uv
        self.mips = mips
    }
}

/// Spec 4 §9 — what a resolved box draws.
public enum BoxContent: Equatable, Sendable {
    case pixels(PixelQuad)
    case lines([TextLine])

    public var isEmpty: Bool {
        switch self {
        case .pixels: return false
        case .lines(let lines): return lines.isEmpty
        }
    }
}

extension BoxContent: Codable {
    private enum Key: String, CodingKey { case kind, quad, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "pixels": self = .pixels(try c.decode(PixelQuad.self, forKey: .quad))
        case "lines": self = .lines(try c.decode([TextLine].self, forKey: .lines))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown box content \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .pixels(let quad):
            try c.encode("pixels", forKey: .kind)
            try c.encode(quad, forKey: .quad)
        case .lines(let lines):
            try c.encode("lines", forKey: .kind)
            try c.encode(lines, forKey: .lines)
        }
    }
}

/// Spec 4 §9 — "Box transitions. When a box's content changes, the stack pass
/// draws both the old and new textures mixed by the box's Transition object
/// (cut or dissolve in v1), with the same mixer as the channel pass."
public struct BoxTransitionState: Equatable, Codable, Sendable {
    public var type: TransitionType
    public var progress: Float
    public var outgoing: BoxContent

    public init(type: TransitionType, progress: Float, outgoing: BoxContent) {
        self.type = type
        self.progress = progress
        self.outgoing = outgoing
    }
}

/// Spec 4 §4 — "an ordered list of resolved boxes: for each slot, the preset
/// layout chosen by the Spec 1 resolution order, with every box already bound
/// to a concrete source ..., its frame in pixels, its opacity (slot opacity
/// times mute), its transition state, and its per-box grade." The slot
/// offset, the binding and the resolved text ride along for the harness,
/// which checks the +1 slot against the projected state (Spec 4 §15).
public struct ResolvedBox: Equatable, Codable, Sendable {
    public var channel: Int
    public var offset: Int
    public var binding: Binding
    public var text: String?
    public var frame: PixelRect
    public var content: BoxContent
    public var opacity: Float
    public var transition: BoxTransitionState?
    public var grade: GradeParameters?

    public init(channel: Int, frame: PixelRect, content: BoxContent, opacity: Float, transition: BoxTransitionState? = nil,
                grade: GradeParameters? = nil, offset: Int = 0, binding: Binding = .pixels, text: String? = nil) {
        self.channel = channel
        self.offset = offset
        self.binding = binding
        self.text = text
        self.frame = frame
        self.content = content
        self.opacity = opacity
        self.transition = transition
        self.grade = grade
    }

    /// Spec 4 §9 — "draws with alpha zero, which the pass skips".
    public var isDrawn: Bool { opacity > 0 && (!content.isEmpty || transition != nil) }
}

/// Spec 4 §4 — "StackPass names the stack, the output size, the base, and an
/// ordered list of resolved boxes". Spec 4 §9 — the gamma-blend switch is a
/// per-stack shader variant.
public struct StackPass: Equatable, Codable, Sendable {
    public var stack: Int
    public var target: TextureHandle
    public var size: PixelSize
    public var base: StackBase
    public var gammaBlend: Bool
    public var boxes: [ResolvedBox]

    public init(stack: Int, target: TextureHandle, size: PixelSize, base: StackBase, gammaBlend: Bool, boxes: [ResolvedBox]) {
        self.stack = stack
        self.target = target
        self.size = size
        self.base = base
        self.gammaBlend = gammaBlend
        self.boxes = boxes
    }

    /// The boxes the pass draws: alpha above zero with something to show.
    public var drawnBoxes: [ResolvedBox] { boxes.filter(\.isDrawn) }
}

/// Spec 4 §4 — "Output transitions (stack switch, blackout) are expressed as a
/// second stack texture and a mix factor." Spec 4 §10 — "the previous stack
/// for a switch, black for blackout, nothing for per-slot mute".
public enum SecondTexture: Equatable, Sendable {
    case none
    case black
    case stack(TextureHandle)
}

extension SecondTexture: Codable {
    private enum Key: String, CodingKey { case kind, handle }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": self = .none
        case "black": self = .black
        case "stack": self = .stack(TextureHandle(rawValue: try c.decode(Int32.self, forKey: .handle)))
        case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown second texture \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .none: try c.encode("none", forKey: .kind)
        case .black: try c.encode("black", forKey: .kind)
        case .stack(let handle):
            try c.encode("stack", forKey: .kind)
            try c.encode(handle.rawValue, forKey: .handle)
        }
    }
}

/// Spec 4 §4 — "SinkPass names the output, the stack texture to take, the
/// encode (display 10-bit, DeckLink v210 with or without weave, NDI BGRA) and
/// the destination (a drawable, a shared buffer slot)."
public struct SinkPass: Equatable, Codable, Sendable {
    public var output: Int
    public var stack: TextureHandle
    public var second: SecondTexture
    public var mix: Float
    public var encode: EncodeKind
    /// The slot in the output's ring of three (Spec 4 §2).
    public var destination: Int

    public init(output: Int, stack: TextureHandle, second: SecondTexture, mix: Float, encode: EncodeKind, destination: Int) {
        self.output = output
        self.stack = stack
        self.second = second
        self.mix = mix
        self.encode = encode
        self.destination = destination
    }
}

/// Spec 4 §8 — the cache key: "a hash of (field text, text style value, box
/// pixel width, box pixel height, fit policy, output scale)".
public struct TextKey: Hashable, Codable, Sendable {
    public var hash: UInt64

    public init(hash: UInt64) {
        self.hash = hash
    }
}

/// Spec 4 §4 — "textJobs: rasterizations to request (not to wait for)": one
/// box's text with everything the rasterizer needs (Spec 4 §8).
public struct TextJob: Equatable, Codable, Sendable {
    public var key: TextKey
    public var text: String
    public var style: BoxTextStyle
    public var box: PixelSize
    public var fit: TextFit
    /// Spec 1 §2 — sizes in pt are "points on a 1080-line canvas scaled with
    /// output height; percent is a percentage of output height".
    public var outputHeight: Int

    public init(key: TextKey, text: String, style: BoxTextStyle, box: PixelSize, fit: TextFit, outputHeight: Int) {
        self.key = key
        self.text = text
        self.style = style
        self.box = box
        self.fit = fit
        self.outputHeight = outputHeight
    }
}

/// Spec 4 §4 — "auxPasses: multiviewer, preview, thumbnails; skipped first
/// under pressure".
public enum AuxKind: String, Codable, Sendable {
    case preview
    case multiviewer
    case thumbnail
}

public struct AuxPass: Equatable, Codable, Sendable {
    public var kind: AuxKind
    public var stack: Int
    public var target: TextureHandle

    public init(kind: AuxKind, stack: Int, target: TextureHandle) {
        self.kind = kind
        self.stack = stack
        self.target = target
    }
}

/// Spec 4 §4 — "A frame plan is a plain value describing everything the
/// render thread must do for one tick, built on the control thread from the
/// ShowState, the library and the machine configuration."
public struct FramePlan: Equatable, Codable, Sendable {
    public var frame: Int64
    public var channelPasses: [ChannelPass]
    public var textJobs: [TextJob]
    public var stackPasses: [StackPass]
    public var sinkPasses: [SinkPass]
    public var auxPasses: [AuxPass]

    public init(frame: Int64, channelPasses: [ChannelPass] = [], textJobs: [TextJob] = [], stackPasses: [StackPass] = [],
                sinkPasses: [SinkPass] = [], auxPasses: [AuxPass] = []) {
        self.frame = frame
        self.channelPasses = channelPasses
        self.textJobs = textJobs
        self.stackPasses = stackPasses
        self.sinkPasses = sinkPasses
        self.auxPasses = auxPasses
    }

    public static let empty = FramePlan(frame: 0)
}

/// Spec 4 §15 — "The headless harness reproduces a tick from a saved frame
/// plan": the plan as canonical JSON (CLAUDE.md: sorted keys, two-space
/// indent, LF).
public enum SavedPlan {
    public static func encode(_ plan: FramePlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(plan)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> FramePlan {
        try JSONDecoder().decode(FramePlan.self, from: data)
    }
}
