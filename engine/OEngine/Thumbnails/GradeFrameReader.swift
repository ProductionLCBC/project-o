// OEngine — Spec 11 §3 as corrected 2026-11-26 (G-43): a grade's video frames, for the `render` query's `atMs`.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OCore

/// Spec 11 §3 as corrected 2026-11-26 (G-43) — "A grade's video frames come
/// from one reader the job keeps open, reading forward: pictures of the same
/// time share its frame, a time before the last one read, more than two
/// seconds after it, or another item starts it again, and it closes after ten
/// seconds unused." The frame at a time is "its frame at that time from the
/// item's start, its last frame past its end": the frame showing then, the
/// last to start at or before it.
///
/// Used on the thumbnail job's queue only (and by the tests on theirs): never
/// on the render thread, which this reader neither waits on nor touches.
final class GradeFrameReader: @unchecked Sendable {
    /// "more than two seconds after it ... starts it again".
    static let jumpMs = 2000.0
    /// "it closes after ten seconds unused".
    static let idleNs: Int64 = 10_000_000_000

    private struct Frame {
        var buffer: CVPixelBuffer
        var ms: Double
    }

    /// How many readers have been opened, for the tests.
    private(set) var opened = 0
    /// When a frame was last asked for, on the engine's monotonic clock.
    private(set) var lastUsedNs: Int64 = 0
    private var url: URL?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var durationMs = 0.0
    /// The frame showing at the last time asked for, and the next one read past it.
    private var held: Frame?
    private var pending: Frame?
    private var ended = false

    var isOpen: Bool { reader != nil }

    /// The frame of the video at `url` showing at `atMs`, as 32-bit BGRA;
    /// nil when it can't be decoded.
    func frame(of url: URL, atMs: Int, nowNs: Int64 = MonotonicClock.now().nanoseconds) -> CVPixelBuffer? {
        lastUsedNs = nowNs
        let time = Double(max(0, atMs))
        if reader == nil || url != self.url || startsAgain(at: time) {
            guard open(url, at: time) else { return nil }
        }
        while true {
            if let next = pending {
                guard next.ms <= time + 0.001 else { break }
                held = next
                heldIsFirst = false
                pending = nil
            }
            guard !ended, let output, let sample = output.copyNextSampleBuffer() else {
                ended = true
                break
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ms = pts.isNumeric ? pts.seconds * 1000 : (held?.ms ?? 0)
            if held == nil || ms <= time + 0.001 {
                // The first frame read stands for any time before it.
                heldIsFirst = held == nil
                held = Frame(buffer: buffer, ms: ms)
            } else {
                pending = Frame(buffer: buffer, ms: ms)
            }
        }
        return held?.buffer
    }

    /// "a time before the last one read, more than two seconds after it". A
    /// time before the video's first frame, read from its start, is that frame.
    private func startsAgain(at time: Double) -> Bool {
        guard let held else { return true }
        if time + 0.001 < held.ms { return !(readFromStart && heldIsFirst) }
        return time > held.ms + GradeFrameReader.jumpMs
    }

    /// Whether the reader read from the item's start, and the frame held is the first it read.
    private var readFromStart = false
    private var heldIsFirst = false

    /// "it closes after ten seconds unused": called on the job's queue after a while.
    func closeIfIdle(nowNs: Int64 = MonotonicClock.now().nanoseconds) {
        guard reader != nil, nowNs - lastUsedNs >= GradeFrameReader.idleNs else { return }
        close()
    }

    func close() {
        if let reader, reader.status == .reading { reader.cancelReading() }
        reader = nil
        output = nil
        url = nil
        held = nil
        pending = nil
        ended = false
    }

    /// A reader from playback's pre-roll before `time` (`AVAssetReaderDemuxer`),
    /// so every frame near it keeps its own time; a time past the end reads
    /// the end.
    private func open(_ url: URL, at time: Double) -> Bool {
        close()
        guard let asset = try? AssetLoading.loaded(url),
              let track = asset.tracks(withMediaType: .video).first,
              let made = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard made.canAdd(output) else { return false }
        made.add(output)
        durationMs = asset.duration.isNumeric ? asset.duration.seconds * 1000 : 0
        let within = durationMs > 0 ? min(time, durationMs) : time
        let start = max(0, within - AVAssetReaderDemuxer.prerollMs)
        made.timeRange = CMTimeRange(start: CMTime(value: CMTimeValue(start), timescale: 1000), duration: .positiveInfinity)
        guard made.startReading() else { return false }
        reader = made
        self.output = output
        self.url = url
        opened += 1
        readFromStart = start == 0
        heldIsFirst = false
        return true
    }
}
