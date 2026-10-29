// OEngine — Spec 4 §14, the `ContentSource` seam; Spec 4 §6, content sources.

import Foundation
import OCore

/// Spec 4 §6 — "Every content kind is a `ContentSource`: something that, asked
/// for tick N, returns the texture (or textures) to sample, or reports that it
/// has nothing yet. The channel pass does not know whether it is drawing a
/// video, a still, a camera or a designed slide."
///
/// Spec 4 §14 — v1: "Video file, still, empty"; later "Live inputs, Hap,
/// designed slides, audio sets".
public protocol ContentSource: AnyObject, Sendable {
    /// Spec 4 §7 — the plane layout the channel shader is specialised for.
    var layout: SourceLayout { get }
    var size: PixelSize { get }
    /// Spec 4 §6 — true once the first frame is available, which is when a
    /// cold write's transition starts.
    var isReady: Bool { get }

    /// Spec 4 §4 step 2, on the render thread — "pick the decoded frame for
    /// this tick from the instance's queue and record whether a frame was
    /// missing". Spec 4 §6 — "takes the newest frame at or before the
    /// instance's media time, releases older ones, and repeats the previous
    /// frame if none qualifies, counting the repeat." Must not allocate, lock
    /// or wait.
    func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult

    /// Spec 4 §3 — the depth of the instance's decoded-frame queue, for the
    /// metrics and the watchdog.
    var queueDepth: Int { get }

    /// Control side — the source will not be sampled again; its decoder and
    /// pool go back on the decode thread. Never on the render thread.
    func release()
}

/// Spec 4 §6 — what a pick found.
public enum PickResult: Equatable, Sendable {
    /// A frame at or before the media time was taken.
    case frame
    /// No new frame qualified; the previous one is repeated (`videoRepeat`).
    case repeated
    /// The source has nothing yet (a cold write, a missing file): the
    /// channel renders transparent.
    case nothing
}

/// Spec 4 §6 — the frame a source hands the channel pass: up to three planes
/// as GPU texture objects the backend understands, and the presentation time
/// that was picked. The objects are retained, never copied or allocated here.
public struct PickedFrame: @unchecked Sendable {
    public var plane0: AnyObject?
    public var plane1: AnyObject?
    public var plane2: AnyObject?
    public var presentationMs: Double
    public var layout: SourceLayout

    public init() {
        plane0 = nil
        plane1 = nil
        plane2 = nil
        presentationMs = 0
        layout = .linearRGBA16
    }

    public mutating func clear() {
        plane0 = nil
        plane1 = nil
        plane2 = nil
        presentationMs = 0
    }
}

/// Spec 4 §4 step 2 — the picks of one tick, one slot per channel pass, in a
/// buffer allocated once so the render thread fills it without allocating.
public final class PickedFrames: @unchecked Sendable {
    public let capacity: Int
    let frames: UnsafeMutablePointer<PickedFrame>
    let results: UnsafeMutablePointer<PickResult>

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        frames = UnsafeMutablePointer<PickedFrame>.allocate(capacity: self.capacity)
        frames.initialize(repeating: PickedFrame(), count: self.capacity)
        results = UnsafeMutablePointer<PickResult>.allocate(capacity: self.capacity)
        results.initialize(repeating: .nothing, count: self.capacity)
    }

    deinit {
        frames.deinitialize(count: capacity)
        frames.deallocate()
        results.deinitialize(count: capacity)
        results.deallocate()
    }

    public subscript(index: Int) -> PickedFrame {
        get { frames[index] }
        set { frames[index] = newValue }
    }

    public func result(at index: Int) -> PickResult { results[index] }
    public func setResult(_ result: PickResult, at index: Int) { results[index] = result }

    /// Drop every retained plane, so sources can be released.
    public func clearAll() {
        for i in 0..<capacity {
            frames[i].clear()
            results[i] = .nothing
        }
    }
}

/// Spec 4 §6 — the table of live sources the render thread picks from, by
/// instance handle. Installed and removed on the control side before the plan
/// that names them is published or after the last plan that named them was
/// consumed; read on the render thread.
public final class SourceTable: @unchecked Sendable {
    public let capacity: Int
    private let slots: UnsafeMutablePointer<(any ContentSource)?>

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        slots = UnsafeMutablePointer<(any ContentSource)?>.allocate(capacity: self.capacity)
        slots.initialize(repeating: nil, count: self.capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    public func install(_ source: any ContentSource, at handle: InstanceHandle) {
        guard handle.rawValue >= 0, Int(handle.rawValue) < capacity else { return }
        slots[Int(handle.rawValue)] = source
    }

    public func remove(_ handle: InstanceHandle) {
        guard handle.rawValue >= 0, Int(handle.rawValue) < capacity else { return }
        slots[Int(handle.rawValue)] = nil
    }

    /// Render thread: an array read, no allocation.
    public func source(_ handle: InstanceHandle) -> (any ContentSource)? {
        guard handle.rawValue >= 0, Int(handle.rawValue) < capacity else { return nil }
        return slots[Int(handle.rawValue)]
    }
}
