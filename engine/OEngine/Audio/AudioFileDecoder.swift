// OEngine — Spec 4 §11, "Decode": the audio track of a media file into an
// instance's ring.

import Foundation
import AVFoundation
import CoreMedia
import Synchronization

/// Spec 4 §11 — "The same AVAssetReader that demuxes video supplies the audio
/// track as 48 kHz 32-bit float PCM (converted by AVFoundation if the file
/// differs), decoded on the instance's decode thread into a lock-free ring of
/// about 200 ms per instance." The spike opens a reader of its own for the
/// audio track beside the video demuxer's reader (Area 4 reading); the ring
/// and the timing are as the spec says. Loops reopen at the in-point before
/// the ring runs dry, so they are gapless (Spec 4 §11, "Transport").
public final class AudioFileDecoder: @unchecked Sendable {
    public let url: URL
    public let inMs: Double
    public let outMs: Double?
    public let loop: Bool
    public let ring: AudioRing
    public let channels: Int
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let failed = Atomic<Bool>(false)
    private let framesDecoded = Atomic<Int64>(0)
    private let log: EngineLog?

    public init(url: URL, inMs: Double, outMs: Double?, loop: Bool, channels: Int = 2, log: EngineLog? = nil) {
        self.url = url
        self.inMs = max(0, inMs)
        self.outMs = outMs
        self.loop = loop
        self.channels = max(1, min(2, channels))
        self.log = log
        ring = AudioRing(channels: self.channels)
    }

    public var isFailed: Bool { failed.load(ordering: .acquiring) }
    public var decoded: Int64 { framesDecoded.load(ordering: .relaxed) }

    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in decodeLoop() }
        thread.name = "o.engine.audio.decode"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    public func stop() {
        running.store(false, ordering: .releasing)
    }

    private func openReader() throws -> (AVAssetReader, AVAssetReaderTrackOutput, Double) {
        let asset = try AssetLoading.loaded(url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw DemuxError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let end = outMs ?? asset.duration.seconds * 1000
        reader.timeRange = CMTimeRange(start: CMTime(value: Int64(inMs), timescale: 1000), end: CMTime(value: Int64(end), timescale: 1000))
        guard reader.startReading() else { throw DemuxError.cannotStart(reader.error.map { "\($0)" } ?? "unknown") }
        return (reader, output, end)
    }

    private func decodeLoop() {
        var current: (AVAssetReader, AVAssetReaderTrackOutput, Double)
        do {
            current = try openReader()
        } catch {
            log?.error("audio: cannot open \(url.lastPathComponent): \(error)")
            failed.store(true, ordering: .releasing)
            ring.markEnded()
            return
        }
        var pending: [Float] = []
        while running.load(ordering: .relaxed) {
            if !pending.isEmpty {
                let written = ring.write(pending)
                pending.removeFirst(written * channels)
                if !pending.isEmpty {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
            }
            guard let sample = autoreleasepool(invoking: { current.1.copyNextSampleBuffer() }) else {
                if loop {
                    current.0.cancelReading()
                    do {
                        current = try openReader()
                        continue
                    } catch {
                        log?.error("audio: cannot reopen \(url.lastPathComponent) for the loop: \(error)")
                        failed.store(true, ordering: .releasing)
                    }
                }
                ring.markEnded()
                break
            }
            pending = autoreleasepool { AudioFileDecoder.samples(of: sample) }
            framesDecoded.add(Int64(pending.count / channels), ordering: .relaxed)
        }
        current.0.cancelReading()
    }

    /// The interleaved float samples of a PCM sample buffer.
    static func samples(of sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let copied = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == noErr else { return [] }
        return bytes.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }
}
