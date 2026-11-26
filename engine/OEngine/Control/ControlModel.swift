// OEngine — Spec 4 §3 and §4, the control thread's picture of the engine: the
// live ShowState and what the engine is doing about it.

import Foundation
import OCore

/// Spec 4 §2 — "Media time is not the tick ... Instances without audio run a
/// media clock derived from the tick so they stay deterministic." Spec 3 §4 —
/// pause holds, play resumes from the engine's playhead.
public struct MediaClock: Equatable, Sendable {
    public var anchorFrame: Int64
    public var anchorMs: Double
    public var playing: Bool

    public init(anchorFrame: Int64, anchorMs: Double, playing: Bool) {
        self.anchorFrame = anchorFrame
        self.anchorMs = anchorMs
        self.playing = playing
    }

    public func mediaTime(at frame: Int64, millisecondsPerTick: Double) -> Double {
        playing ? anchorMs + Double(frame - anchorFrame) * millisecondsPerTick : anchorMs
    }

    public mutating func pause(at frame: Int64, millisecondsPerTick: Double) {
        anchorMs = mediaTime(at: frame, millisecondsPerTick: millisecondsPerTick)
        anchorFrame = frame
        playing = false
    }

    public mutating func resume(at frame: Int64) {
        anchorFrame = frame
        playing = true
    }
}

/// Spec 4 §6 — a media instance as the engine runs it: its source, its
/// poster, its clock and its color description for stage 1.
public struct MediaRuntime: Sendable {
    public var ref: String
    public var handle: InstanceHandle
    public var source: (any ContentSource)?
    public var poster: TextureHandle
    public var entry: MediaEntry?
    public var layout: SourceLayout
    public var size: PixelSize
    public var matrix: ColorMatrix
    public var range: ColorRange
    public var inMs: Double
    public var outMs: Double
    public var clock: MediaClock
    /// Spec 4 §6 — true once the first frame is available.
    public var ready: Bool
    /// Spec 3 §4 — the instance has `missing: true`: "The engine renders nothing for the pixel path".
    public var missing: Bool
    /// Spec 4 §6 — the end-of-media `clear` was issued.
    public var clearIssued: Bool
    /// The transport and end behavior last seen in ShowState.
    public var transport: Transport
    public var endBehavior: EndBehavior
    /// Spec 4 §11 — the instance's sound on every device its channel's
    /// outputs reach, when the file has a track and a graph exists.
    public var audio: AudioAttachment?
    public var audioDecoder: AudioFileDecoder?
    public var syncOffsetMs: Int = 0
    public var gainOverride: Double?
    /// Spec 8 §9 — the poster this instance shows while it isn't playing, which
    /// it takes once it loads when the write landed before it had (Spec 4 §6).
    public var posterKey: PosterKey?
    /// Spec 8 §6 (plan) — the write landed while its item's files were moving
    /// for a delete: "its file opens only when the park ends".
    public var parkedOpen = false

    public var isStill: Bool { entry?.kind == .image }
    public var loops: Bool { endBehavior == .loop && outMs.isFinite }
}

/// Spec 3 §2 — the content on a channel, as runtime.
public enum ContentRuntime: Sendable {
    case empty
    case text([String: String])
    case media(MediaRuntime)
    case slide(String)
    case input(Int)

    public var media: MediaRuntime? {
        if case .media(let m) = self { return m }
        return nil
    }

    /// Spec 4 §7 — "One pass per channel with pixel content": media that is
    /// not missing. Text has no channel pass; slides are v2, inputs v1.5.
    public var hasPixels: Bool {
        guard let m = media else { return false }
        return !m.missing
    }
}

/// Spec 4 §7 — the outgoing of a transition: the previous content, still
/// playing, or a snapshot of the channel texture as it was (Area 4 reading:
/// an interrupted or restarted transition freezes the picture it interrupts),
/// or nothing: "On a channel that held no picture the outgoing is
/// transparent, so a dissolve fades the new content in" (as corrected
/// 2026-11-25).
public enum OutgoingRuntime: Sendable {
    case content(ContentRuntime)
    case snapshot
    case nothing
}

/// Spec 4 §4 — "the transition (type, progress 0–1 for this tick, easing,
/// color)" tracked by frame on the control thread. `startFrame` is nil
/// while a cold write waits for its first decoded frame (Spec 4 §6).
public struct TransitionRun: Equatable, Sendable {
    public var type: TransitionType
    public var easing: Easing
    public var color: ColorValue?
    public var durationFrames: Int64
    public var startFrame: Int64?

    public func state(at frame: Int64) -> TransitionState? {
        guard let start = startFrame, frame >= start else { return nil }
        if durationFrames <= 0 {
            return frame == start ? TransitionState(type: type, progress: 1, color: color) : nil
        }
        let t = min(1, Float(frame - start) / Float(durationFrames))
        return TransitionState(type: type, progress: easing.apply(t), color: color)
    }

    public func isComplete(at frame: Int64) -> Bool {
        guard let start = startFrame else { return false }
        return frame > start && frame - start >= durationFrames
    }

    public func isRunning(at frame: Int64) -> Bool {
        guard let start = startFrame else { return true }
        return frame >= start && !isComplete(at: frame)
    }
}

/// Spec 3 §4 — "the engine interpolates each grade parameter from the old
/// values (none counts as identity) to the new over that time".
public struct GradeRun: Equatable, Sendable {
    public var targetRef: Int
    public var from: GradeParameters
    public var to: GradeParameters
    public var startFrame: Int64
    public var durationFrames: Int64

    public static let none = GradeRun(targetRef: 0, from: .identity, to: .identity, startFrame: 0, durationFrames: 0)

    public func current(at frame: Int64) -> GradeParameters {
        guard durationFrames > 0, frame < startFrame + durationFrames else { return to }
        let t = max(0, Float(frame - startFrame) / Float(durationFrames))
        return GradeParameters.lerp(from, to, t)
    }

    public func isComplete(at frame: Int64) -> Bool { frame >= startFrame + durationFrames }
}

/// One channel's runtime.
public struct ChannelRuntime: Sendable {
    public var live: ContentRuntime = .empty
    public var outgoing: OutgoingRuntime?
    public var transition: TransitionRun?
    /// The snapshot copy is taken on the next tick the render thread runs.
    public var snapshotPending = false
    public var grade: GradeRun = .none
    public var gainDb: Double = 0

    public init() {}
}

/// Spec 4 §10 — "A stack switch mixes old and new stack textures over the
/// output's switch transition".
public struct SwitchRun: Equatable, Sendable {
    public var oldStack: Int
    public var newStack: Int
    public var easing: Easing
    public var startFrame: Int64
    public var durationFrames: Int64

    /// The amount of the old stack still showing.
    public func oldMix(at frame: Int64) -> Float {
        guard durationFrames > 0 else { return 0 }
        let t = min(1, max(0, Float(frame - startFrame) / Float(durationFrames)))
        return 1 - easing.apply(t)
    }

    public func isComplete(at frame: Int64) -> Bool { frame - startFrame >= durationFrames }
}

/// Spec 4 §10 — "blackout mixes to black over the blackout transition".
public struct BlackoutRun: Equatable, Sendable {
    public var toBlack: Bool
    public var easing: Easing
    public var startFrame: Int64
    public var durationFrames: Int64
    public var fromMix: Float

    public func mix(at frame: Int64) -> Float {
        let target: Float = toBlack ? 1 : 0
        guard durationFrames > 0 else { return target }
        let t = min(1, max(0, Float(frame - startFrame) / Float(durationFrames)))
        return fromMix + (target - fromMix) * easing.apply(t)
    }

    public func isComplete(at frame: Int64) -> Bool { frame - startFrame >= durationFrames }
}

public struct OutputRuntime: Sendable {
    public var switchRun: SwitchRun?
    public var blackout: BlackoutRun?
    /// The blackout mix where the last run ended: 1 while blacked out.
    public var blackoutMix: Float = 0

    public init() {}
}

/// Spec 4 §9 — box transitions are tracked per box of a slot of a stack.
/// The slot is named by its channel, which a stack holds once (Spec 6 §2):
/// the number stays the slot's when slots are added, removed or moved (Spec
/// 11 §6), where its place in the stack would not.
public struct BoxKey: Hashable, Sendable {
    public var stack: Int
    /// The slot's channel number.
    public var slot: Int
    public var box: Int
}

/// Spec 4 §9 — which box a run remembers. Runs are kept by a box's place (its
/// stack, its slot's channel, its index in the layout), and an edit can put
/// another box in that place: a slot given another preset, a preset given a
/// layout of its own for the stack, a box inserted or removed before this
/// one. What the place held before is then not this box's to dissolve from
/// or to keep drawing. How the box looks (its frame, fit, style, transition)
/// and a static box's own text are not part of this: an edit of those is an
/// edit of the same box.
public struct BoxIdentity: Equatable, Sendable {
    public enum Bound: Equatable, Sendable {
        case pixels
        case field(String)
        case text

        public init(_ kind: Binding.Kind) {
            switch kind {
            case .pixels: self = .pixels
            case .field(let name): self = .field(name)
            case .static: self = .text
            }
        }
    }

    public var preset: UUID
    public var layout: LayoutKey
    public var bound: Bound
    public var offset: Int

    public init(preset: UUID, layout: LayoutKey, bound: Bound, offset: Int) {
        self.preset = preset
        self.layout = layout
        self.bound = bound
        self.offset = offset
    }
}

public struct BoxRun: Sendable {
    /// The box this run is of; a run under the same key for another box starts afresh.
    public var identity: BoxIdentity?
    /// Spec 4 §9 as corrected 2026-11-25 — whether the box has drawn nothing since it was claimed: its next text
    /// "appears from nothing", mixing from transparent, where a box just claimed shows its first text at once.
    public var wasEmpty = false
    public var previousContent: BoxContent?
    public var previousText: String?
    /// Spec 4 §9 — whether the text the box took in this build is the text
    /// it was drawing, before its variables resolve: "When the box has been
    /// drawing this text and only its raster is missing, the box keeps
    /// drawing its previous lines". False for a box's first text and for
    /// "Text a cue has just written", which "still waits for its own raster".
    public var sameTextAsBefore = false
    /// Spec 4 §8 and Spec 6 §5 — what a text box last adopted: "A box whose
    /// text names variables is laid out again only when its resolved text
    /// changes ... How soon depends on what changed". The text before its
    /// variables resolved (a field's text, or a static box's own), the text
    /// drawn, and each value it was resolved with.
    public var adoptedTemplate: String?
    public var adoptedText: String?
    /// Spec 6 §4 — whether the adopted text was laid out with tabular digits.
    public var adoptedTabular = false
    public var adoptedValues: [ResolvedValue] = []
    /// Spec 6 §5 — the frame of the box's last adoption: a popup's new value
    /// "is adopted on the first frame at least 100 ms after the box's
    /// previous adoption".
    public var adoptedFrame: Int64?
    /// Spec 6 §5 — the wall-clock second of the box's last adoption that took
    /// the clock, a timer or `[Service In]`: they change the box "at most once
    /// per wall-clock second".
    public var clockedSecond: Int64 = .min
    /// Spec 6 §5 — whether the last change adopted was a value's, which runs
    /// the box transition only with `transitionOnVariableChange`, rather than
    /// new text.
    public var valueChange = false
    public var type: TransitionType = .cut
    public var easing: Easing = .linear
    public var startFrame: Int64 = 0
    public var durationFrames: Int64 = 0
    public var outgoing: BoxContent?
    /// Spec 4 §8 — "the result replaces the cache entry": the rasters this
    /// box's value changes replaced, still in the cache while the box may be
    /// drawing them (Spec 4 §9, a box "keeps drawing its previous lines until
    /// the new raster is ready"), released once the new value's raster drew.
    public var replaced: [TextKey] = []

    public func state(at frame: Int64) -> BoxTransitionState? {
        guard let outgoing, durationFrames > 0, frame < startFrame + durationFrames, type != .cut else { return nil }
        let t = max(0, Float(frame - startFrame) / Float(durationFrames))
        return BoxTransitionState(type: type, progress: easing.apply(t), outgoing: outgoing)
    }
}

/// Spec 4 §3 — "The live ShowState" plus the runtimes the control thread
/// keeps beside it. A value; the control loop owns the only copy.
public struct ControlModel: Sendable {
    public var state: ShowState
    public var channels: [Int: ChannelRuntime] = [:]
    public var outputs: [Int: OutputRuntime] = [:]
    public var boxRuns: [BoxKey: BoxRun] = [:]
    public var frame: Int64 = 0

    public init(state: ShowState) {
        self.state = state
    }
}

/// Spec 1 §2 — "renderSize: the largest output size among stacks that include
/// the channel"; Spec 4 §5 — a stack texture is "The size of the output
/// showing it". The sizes the engine's textures have, worked out again
/// whenever a channel, a stack, an output or what an output shows changes.
public struct MachineGeometry: Equatable, Sendable {
    public let stackSizes: [Int: PixelSize]
    public let channelSizes: [Int: PixelSize]

    /// Spec 4 §5 — a stack texture is "The size of the output showing it,
    /// the largest when several do; for a stack no output shows, that of the
    /// largest output whose default stack it is, else 1920 by 1080 (Spec 11
    /// §3). The old stack of a running switch keeps its size until the switch
    /// ends". `state` says which stack each output shows, an output without
    /// an entry being on its default stack; `switching` names, by output, the
    /// old stack of a switch still running.
    public init(library: Library, machine: Machine, state: ShowState? = nil, switching: [Int: Int] = [:]) {
        func size(_ output: Output) -> PixelSize { PixelSize(width: output.format.width, height: output.format.height) }
        var stacks: [Int: PixelSize] = [:]
        for stack in machine.stacks {
            let showing = machine.outputs.filter {
                (state?.outputs[$0.number] ?? $0.defaultStack) == stack.number || switching[$0.number] == stack.number
            }
            let defaulting = machine.outputs.filter { $0.defaultStack == stack.number }
            let largest = (showing.isEmpty ? defaulting : showing).map(size).max { $0.pixelCount < $1.pixelCount }
            stacks[stack.number] = largest ?? PixelSize(.hd)
        }
        var channels: [Int: PixelSize] = [:]
        for channel in library.channels {
            switch channel.renderSize {
            case .size(let w, let h):
                channels[channel.number] = PixelSize(width: w, height: h)
            case .largest:
                let including = machine.stacks.filter { $0.slots.contains { $0.channel == channel.number } }
                let largest = including.compactMap { stacks[$0.number] }.max { $0.pixelCount < $1.pixelCount }
                channels[channel.number] = largest ?? PixelSize(.hd)
            }
        }
        stackSizes = stacks
        channelSizes = channels
    }

    /// The sizes the textures were made at, when one couldn't be made at the size the rule gives (Spec 4 §12).
    init(stackSizes: [Int: PixelSize], channelSizes: [Int: PixelSize]) {
        self.stackSizes = stackSizes
        self.channelSizes = channelSizes
    }

    public func stackSize(_ stack: Int) -> PixelSize { stackSizes[stack] ?? PixelSize(.hd) }
    public func channelSize(_ channel: Int) -> PixelSize { channelSizes[channel] ?? PixelSize(.hd) }
}
