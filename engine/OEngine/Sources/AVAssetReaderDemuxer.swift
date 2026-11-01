// OEngine — Spec 4 §14, the `Demuxer` seam's v1 implementation: AVAssetReader
// in passthrough mode.

import Foundation
import AVFoundation
import CoreMedia

public enum DemuxError: Error {
    case noVideoTrack
    case cannotStart(String)
}

/// Spec 4 §12 — a media open that never answers is a failure, not a wait:
/// AVFoundation's synchronous property loads (`tracks`, `duration`) block
/// until the media server answers, and on a machine whose media services are
/// stalled that is forever. The asset is loaded asynchronously and waited on
/// with a bound before any property is read.
public enum AssetLoading {
    public static func loaded(_ url: URL, timeout seconds: Double = 20) throws -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        let keys = ["tracks", "duration"]
        let done = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: keys) { done.signal() }
        guard done.wait(timeout: .now() + seconds) == .success else {
            throw DemuxError.cannotStart("\(url.lastPathComponent) did not load within \(Int(seconds)) s")
        }
        for key in keys {
            var error: NSError?
            if asset.statusOfValue(forKey: key, error: &error) != .loaded {
                throw DemuxError.cannotStart("\(url.lastPathComponent): \(key) \(error?.localizedDescription ?? "not loaded")")
            }
        }
        return asset
    }
}

/// Spec 4 §6 — "Demux with AVFoundation's AVAssetReader in passthrough mode
/// (compressed samples out) ... Using Apple's demuxer with a direct decoder
/// session keeps the frame queue, the output pixel format and the seek
/// behaviour under the engine's control".
public final class AVAssetReaderDemuxer: Demuxer, @unchecked Sendable {
    public let name = "avassetreader"

    public init() {}

    /// Spec 4 §6 — "A write with an in-point seeks the reader to the preceding
    /// keyframe": the reader starts a GOP's worth before the in-point and the
    /// decode thread drops frames until the in-point.
    public static let prerollMs: Double = 3000

    /// Spec 4 §12 — opening runs on a worker the caller waits on with a
    /// bound: the reader's own calls are synchronous and a stalled media
    /// service must fail the open, never hang the decode thread or a test.
    public func open(_ url: URL, startMs: Double) throws -> any DemuxSession {
        let outcome = OpenOutcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                outcome.session = try AVAssetReaderSession(url: url, startMs: startMs)
            } catch {
                outcome.error = error
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            throw DemuxError.cannotStart("\(url.lastPathComponent) did not open within 30 s")
        }
        if let error = outcome.error { throw error }
        guard let session = outcome.session else { throw DemuxError.cannotStart("no session") }
        return session
    }

    private final class OpenOutcome: @unchecked Sendable {
        var session: AVAssetReaderSession?
        var error: Error?
    }
}

final class AVAssetReaderSession: DemuxSession, @unchecked Sendable {
    let description: DemuxedStream
    let formatDescription: CMFormatDescription?
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var finished = false

    init(url: URL, startMs: Double) throws {
        let asset = try AssetLoading.loaded(url)
        let tracks = asset.tracks(withMediaType: .video)
        guard let track = tracks.first else { throw DemuxError.noVideoTrack }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let start = max(0, startMs - AVAssetReaderDemuxer.prerollMs)
        reader.timeRange = CMTimeRange(start: CMTime(value: Int64(start), timescale: 1000), duration: .positiveInfinity)
        let size = track.naturalSize
        let codec = (track.formatDescriptions.first.map { $0 as! CMFormatDescription }).map { CMFormatDescriptionGetMediaSubType($0) }
        formatDescription = track.formatDescriptions.first.map { $0 as! CMFormatDescription }
        description = DemuxedStream(size: PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded())),
                                    durationMs: asset.duration.seconds * 1000, rate: Double(track.nominalFrameRate),
                                    hasAudio: !asset.tracks(withMediaType: .audio).isEmpty,
                                    codec: codec.map(AVAssetReaderSession.fourCC) ?? "")
        guard reader.startReading() else { throw DemuxError.cannotStart(reader.error.map { "\($0)" } ?? "unknown") }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    func nextVideoSample() -> CompressedSample? {
        guard !finished, let sample = output.copyNextSampleBuffer() else {
            finished = true
            return nil
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let duration = CMSampleBufferGetDuration(sample)
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            keyframe = !notSync
        }
        return CompressedSample(presentationMs: pts.seconds * 1000, durationMs: duration.isNumeric ? duration.seconds * 1000 : 0,
                                isKeyframe: keyframe, payload: sample)
    }

    func close() {
        if reader.status == .reading { reader.cancelReading() }
        finished = true
    }
}
