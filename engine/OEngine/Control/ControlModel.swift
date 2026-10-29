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
/// poster, its clock and its colour description for stage 1.
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
    /// The transport and end behaviour last seen in ShowState.
    public var transport: Transport
    public var endBehavior: EndBehavior

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
/// an interrupted or restarted transition freezes the picture it interrupts).
public enum OutgoingRuntime: Sendable {
    case content(ContentRuntime)
    case snapshot
}

/// Spec 4 §4 — "the transition (type, progress 0–1 for this tick, easing,
/// colour)" tracked by frame on the control thread. `startFrame` is nil
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
public struct BoxKey: Hashable, Sendable {
    public var stack: Int
    public var slot: Int
    public var box: Int
}

public struct BoxRun: Sendable {
    public var previousContent: BoxContent?
    public var previousText: String?
    public var type: TransitionType = .cut
    public var easing: Easing = .linear
    public var startFrame: Int64 = 0
    public var durationFrames: Int64 = 0
    public var outgoing: BoxContent?

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
/// the channel"; Spec 4 §5 — stack textures are "The output size".
public struct MachineGeometry: Sendable {
    public let stackSizes: [Int: PixelSize]
    public let channelSizes: [Int: PixelSize]

    public init(library: Library, machine: Machine) {
        var stacks: [Int: PixelSize] = [:]
        for stack in machine.stacks {
            let showing = machine.outputs.filter { $0.defaultStack == stack.number }
            let largest = showing.map { PixelSize(width: $0.format.width, height: $0.format.height) }
                .max { $0.pixelCount < $1.pixelCount }
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

    public func stackSize(_ stack: Int) -> PixelSize { stackSizes[stack] ?? PixelSize(.hd) }
    public func channelSize(_ channel: Int) -> PixelSize { channelSizes[channel] ?? PixelSize(.hd) }
}
