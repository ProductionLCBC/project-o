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
/// and the timing are as the spec says. Spec 4 §11, "Transport" — "Looping
/// audio uses the same two-reader hand-off as video so loops are gapless":
/// the next pass's reader is opened on a queue of its own while the current
/// one still decodes, so the swap at the out-point waits on nothing. (Until
/// the soak of 2026-11-27 it was opened only once the current one ran out,
/// and a reopen slower than the ring's 250 ms left the device short.)
///
/// One ring per device the instance reaches (Area 16): each device's
/// callback consumes its own ring, every ring gets every sample, and the
/// decoder is paced by the slowest of them. Devices on different clocks
/// drift apart by their clock error, as Spec 4 §11 accepts.
public final class AudioFileDecoder: @unchecked Sendable {
    public let url: URL
    public let inMs: Double
    public let outMs: Double?
    public let loop: Bool
    /// One ring per device, in the order the audio system asked for them.
    public let rings: [AudioRing]
    public let channels: Int
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let failed = Atomic<Bool>(false)
    private let framesDecoded = Atomic<Int64>(0)
    private let log: EngineLog?
    /// How long each reopen for a loop is made to take, for the tests: a busy disk's.
    private let reopenDelay: Double

    public init(url: URL, inMs: Double, outMs: Double?, loop: Bool, channels: Int = 2, ringCount: Int = 1, log: EngineLog? = nil,
                reopenDelay: Double = 0) {
        self.reopenDelay = max(0, reopenDelay)
        self.url = url
        self.inMs = max(0, inMs)
        self.outMs = outMs
        self.loop = loop
        let channels = max(1, min(2, channels))
        self.channels = channels
        self.log = log
        rings = (0..<max(1, ringCount)).map { _ in AudioRing(channels: channels) }
    }

    /// The first ring: the clock device's.
    public var ring: AudioRing { rings[0] }

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

    /// A reader opened for the next pass of a loop, on a queue of its own.
    private final class Standby: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: Result<(AVAssetReader, AVAssetReaderTrackOutput, Double), Error>?

        func set(_ result: Result<(AVAssetReader, AVAssetReaderTrackOutput, Double), Error>) {
            lock.lock()
            opened = result
            lock.unlock()
        }

        var result: Result<(AVAssetReader, AVAssetReaderTrackOutput, Double), Error>? {
            lock.lock()
            defer { lock.unlock() }
            return opened
        }
    }

    /// Opens the next pass's reader while this one decodes.
    private func prepareNext() -> Standby {
        let standby = Standby()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if reopenDelay > 0 { Thread.sleep(forTimeInterval: reopenDelay) }
            standby.set(Result { try openReader() })
        }
        return standby
    }

    private func decodeLoop() {
        var current: (AVAssetReader, AVAssetReaderTrackOutput, Double)
        do {
            current = try openReader()
        } catch {
            log?.error("audio: cannot open \(url.lastPathComponent): \(error)")
            failed.store(true, ordering: .releasing)
            for ring in rings { ring.markEnded() }
            return
        }
        var next = loop ? prepareNext() : nil
        defer {
            // A reader opened for a pass that won't come is let go.
            if case .success(let unused)? = next?.result { unused.0.cancelReading() }
        }
        var pending: [Float] = []
        // Frames of `pending` each ring has taken.
        var cursors = [Int](repeating: 0, count: rings.count)
        while running.load(ordering: .relaxed) {
            if !pending.isEmpty {
                let total = pending.count / channels
                var allDone = true
                for (i, ring) in rings.enumerated() where cursors[i] < total {
                    let written = pending.withUnsafeBufferPointer { buffer in
                        ring.write(UnsafeBufferPointer(rebasing: buffer[(cursors[i] * channels)...]))
                    }
                    cursors[i] += written
                    if cursors[i] < total { allDone = false }
                }
                if !allDone {
                    Thread.sleep(forTimeInterval: 0.005)
                    continue
                }
                pending = []
                for i in cursors.indices { cursors[i] = 0 }
            }
            guard let sample = autoreleasepool(invoking: { current.1.copyNextSampleBuffer() }) else {
                if loop, let standby = next {
                    current.0.cancelReading()
                    // Ready already, unless the pass was shorter than an open takes.
                    while running.load(ordering: .relaxed), standby.result == nil { Thread.sleep(forTimeInterval: 0.002) }
                    switch standby.result {
                    case .success(let reader)?:
                        current = reader
                        next = prepareNext()
                        continue
                    case .failure(let error)?:
                        next = nil
                        log?.error("audio: cannot reopen \(url.lastPathComponent) for the loop: \(error)")
                        failed.store(true, ordering: .releasing)
                    case nil:
                        break
                    }
                }
                for ring in rings { ring.markEnded() }
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
