// OEngine — Spec 4 §14, the `Demuxer` seam.

import Foundation

/// Spec 4 §14 — `Demuxer`: "AVAssetReader passthrough" in v1; "FFmpeg's
/// libavformat for exotic containers" later. Spec 4 §6 — "Demux with
/// AVFoundation's `AVAssetReader` in passthrough mode (compressed samples
/// out), decode with a `VTDecompressionSession` per playing instance."
///
/// A demuxer opens a file and hands back a session that yields compressed
/// samples in decode order from a start time, on the decode thread.
public protocol Demuxer: AnyObject, Sendable {
    var name: String { get }
    /// Open `url` and position the reader so that decoding forward reaches
    /// `startMs` (the preceding keyframe for long-GOP sources, Spec 4 §6).
    func open(_ url: URL, startMs: Double) throws -> any DemuxSession
}

/// One reader over one file, consumed by one decode thread.
public protocol DemuxSession: AnyObject, Sendable {
    /// The stream's properties, read from the container.
    var description: DemuxedStream { get }
    /// The next compressed video sample, or nil at the end of the stream.
    func nextVideoSample() -> CompressedSample?
    func close()
}

/// Spec 1 §7 — what the index already knows, confirmed from the container.
public struct DemuxedStream: Equatable, Sendable {
    public var size: PixelSize
    public var durationMs: Double
    public var rate: Double
    public var hasAudio: Bool
    public var codec: String

    public init(size: PixelSize, durationMs: Double, rate: Double, hasAudio: Bool, codec: String) {
        self.size = size
        self.durationMs = durationMs
        self.rate = rate
        self.hasAudio = hasAudio
        self.codec = codec
    }
}

/// A compressed sample with its presentation time; the payload is the
/// demuxer's own object (a CMSampleBuffer for AVFoundation).
public struct CompressedSample: @unchecked Sendable {
    public var presentationMs: Double
    public var durationMs: Double
    public var isKeyframe: Bool
    public var payload: Any

    public init(presentationMs: Double, durationMs: Double, isKeyframe: Bool, payload: Any) {
        self.presentationMs = presentationMs
        self.durationMs = durationMs
        self.isKeyframe = isKeyframe
        self.payload = payload
    }
}
