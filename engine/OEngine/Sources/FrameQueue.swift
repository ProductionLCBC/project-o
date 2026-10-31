// OEngine — Spec 4 §6, "The frame queue".

import Foundation
import CoreVideo
import Synchronization

/// One decoded frame: the pixel buffer and its Metal views, kept together so
/// the IOSurface lives as long as any texture does. The objects are the
/// decoder's; the queue only holds them.
public struct DecodedFrame: @unchecked Sendable {
    public var pixelBuffer: CVPixelBuffer?
    public var view0: CVMetalTexture?
    public var view1: CVMetalTexture?
    public var plane0: AnyObject?
    public var plane1: AnyObject?
    public var presentationMs: Double
    public var durationMs: Double
    public var layout: SourceLayout

    public init(pixelBuffer: CVPixelBuffer? = nil, view0: CVMetalTexture? = nil, view1: CVMetalTexture? = nil, plane0: AnyObject? = nil,
                plane1: AnyObject? = nil, presentationMs: Double, durationMs: Double, layout: SourceLayout) {
        self.pixelBuffer = pixelBuffer
        self.view0 = view0
        self.view1 = view1
        self.plane0 = plane0
        self.plane1 = plane1
        self.presentationMs = presentationMs
        self.durationMs = durationMs
        self.layout = layout
    }
}

/// Spec 4 §6 — "Each instance decodes ahead into a lock-free queue of 3–4
/// frames, each tagged with its presentation time and duration. On a tick the
/// channel pass takes the newest frame at or before the instance's media time,
/// releases older ones, and repeats the previous frame if none qualifies,
/// counting the repeat." Spec 4 §3 — "Decoded frames travel in
/// single-producer, single-consumer ring queues."
///
/// The producer (decode thread) owns the slots from the consumer's displayed
/// frame onward and releases the objects it overwrites, so the consumer
/// (render thread) never performs the last release of a frame.
public final class FrameQueue: @unchecked Sendable {
    public let capacity: Int
    private let slots: UnsafeMutablePointer<DecodedFrame?>
    private let head = Atomic<Int64>(0)          // next index the producer writes
    private let displayed = Atomic<Int64>(-1)    // the index the consumer shows
    private let ended = Atomic<Bool>(false)
    private let repeatCount = Atomic<Int64>(0)
    private let frameCount = Atomic<Int64>(0)

    public init(capacity: Int = 6) {
        self.capacity = max(2, capacity)
        slots = UnsafeMutablePointer<DecodedFrame?>.allocate(capacity: self.capacity)
        slots.initialize(repeating: nil, count: self.capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    // MARK: - Producer

    /// Room for another frame without overwriting one the consumer may show.
    public var hasRoom: Bool {
        let h = head.load(ordering: .relaxed)
        let d = displayed.load(ordering: .acquiring)
        return h - max(0, d) < Int64(capacity)
    }

    /// Frames ahead of the displayed one.
    public var depth: Int {
        let h = head.load(ordering: .relaxed)
        let d = displayed.load(ordering: .relaxed)
        return Int(max(0, h - max(0, d) - (d >= 0 ? 1 : 0)))
    }

    /// Push one frame in presentation order. False, and nothing stored, when full.
    @discardableResult
    public func push(_ frame: DecodedFrame) -> Bool {
        guard hasRoom else { return false }
        let h = head.load(ordering: .relaxed)
        slots[Int(h % Int64(capacity))] = frame
        head.store(h + 1, ordering: .releasing)
        frameCount.add(1, ordering: .relaxed)
        return true
    }

    /// Spec 4 §6 — end of media reached: nothing more will be pushed.
    public func markEnded() { ended.store(true, ordering: .releasing) }
    public var isEnded: Bool { ended.load(ordering: .acquiring) }

    /// Producer side: drop everything (Spec 4 §11, "stop flushes the ring").
    public func flush() {
        let h = head.load(ordering: .relaxed)
        for i in 0..<capacity { slots[i] = nil }
        displayed.store(h - 1, ordering: .releasing)
        ended.store(false, ordering: .relaxed)
    }

    // MARK: - Consumer (render thread)

    /// True once a frame has been pushed.
    public var hasFrame: Bool { head.load(ordering: .acquiring) > 0 }

    /// Spec 4 §6 — the newest frame at or before `mediaTimeMs`, else the
    /// displayed one repeated, else nothing. Allocation-free.
    public func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult {
        let h = head.load(ordering: .acquiring)
        let d = displayed.load(ordering: .relaxed)
        var best: Int64 = -1
        var index = max(0, d)
        while index < h {
            if let candidate = slots[Int(index % Int64(capacity))], candidate.presentationMs <= mediaTimeMs {
                best = index
            } else if index > d, slots[Int(index % Int64(capacity))].map({ $0.presentationMs > mediaTimeMs }) ?? false {
                break
            }
            index += 1
        }
        if best < 0 {
            guard d >= 0, let shown = slots[Int(d % Int64(capacity))] else { return .nothing }
            fill(&frame, from: shown)
            repeatCount.add(1, ordering: .relaxed)
            return .repeated
        }
        guard let chosen = slots[Int(best % Int64(capacity))] else { return .nothing }
        fill(&frame, from: chosen)
        if best == d {
            repeatCount.add(1, ordering: .relaxed)
            return .repeated
        }
        displayed.store(best, ordering: .releasing)
        return .frame
    }

    private func fill(_ frame: inout PickedFrame, from decoded: DecodedFrame) {
        frame.plane0 = decoded.plane0
        frame.plane1 = decoded.plane1
        frame.plane2 = nil
        frame.presentationMs = decoded.presentationMs
        frame.layout = decoded.layout
    }

    /// The frame currently shown, for tests and the last-good-frame copies.
    public var displayedFrame: DecodedFrame? {
        let d = displayed.load(ordering: .acquiring)
        guard d >= 0 else { return nil }
        return slots[Int(d % Int64(capacity))]
    }

    public var repeats: Int64 { repeatCount.load(ordering: .relaxed) }
    public var pushed: Int64 { frameCount.load(ordering: .relaxed) }
}
