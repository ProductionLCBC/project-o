// OEngine — Spec 4 §15, the spike's fixtures: "ProRes and HEVC backgrounds
// with trims and one loop" and "a clapper fixture" for A/V sync, generated
// as synthetic media (tests/fixtures/README.md: "Keep media small; large soak
// media stays on the test bench").

import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// A synthetic clip: every frame carries its own index as twelve binary bars
/// across the top (white is one, most significant bar on the left), a luma
/// gradient below and a bright block that moves one column per frame, so a
/// capture can read which frame it is looking at and whether fields are in
/// order. An optional flash frame and audio click make the clapper.
public enum FixtureMedia {
    public enum Codec: String, Sendable, CaseIterable {
        case h264
        case hevc
        case hevc10
        case proRes422Proxy
        case proRes4444

        /// Spec 1 §7 — the index entry's `codec`.
        public var fourCC: String {
            switch self {
            case .h264: return "avc1"
            case .hevc, .hevc10: return "hvc1"
            case .proRes422Proxy: return "apco"
            case .proRes4444: return "ap4h"
            }
        }

        var avCodec: AVVideoCodecType {
            switch self {
            case .h264: return .h264
            case .hevc, .hevc10: return .hevc
            case .proRes422Proxy: return .proRes422Proxy
            case .proRes4444: return .proRes4444
            }
        }

        var inputPixelFormat: OSType {
            switch self {
            case .hevc10: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case .proRes4444: return kCVPixelFormatType_32BGRA
            default: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            }
        }
    }

    public enum Audio: Equatable, Sendable {
        case tone(hz: Double, gain: Float)
        case click(atMs: Double)
    }

    public struct Clip: Equatable, Sendable {
        public var name: String
        public var codec: Codec
        public var width: Int
        public var height: Int
        public var fps: Int
        public var seconds: Double
        public var audio: Audio?
        public var flashFrame: Int?
        public var keyframeInterval: Int

        public init(name: String, codec: Codec, width: Int = 320, height: Int = 180, fps: Int = 30, seconds: Double = 2,
                    audio: Audio? = nil, flashFrame: Int? = nil, keyframeInterval: Int = 60) {
            self.name = name
            self.codec = codec
            self.width = width
            self.height = height
            self.fps = fps
            self.seconds = seconds
            self.audio = audio
            self.flashFrame = flashFrame
            self.keyframeInterval = keyframeInterval
        }

        public var frameCount: Int { Int((seconds * Double(fps)).rounded()) }
        public var durationMs: Int { Int((seconds * 1000).rounded()) }
    }

    public enum WriteError: Error {
        case cannotStart(String)
        case cannotMakeBuffer
        case failed(String)
    }

    public static let barCount = 12
    /// What `frameIndex` reads from a flash frame: every bar lit.
    public static let flashIndex = (1 << barCount) - 1
    public static let sampleRate: Double = 48_000

    // MARK: - Writing

    /// Write the clip to `url` (a QuickTime file, so LPCM audio is allowed).
    public static func write(_ clip: Clip, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: clip.codec.avCodec,
            AVVideoWidthKey: clip.width,
            AVVideoHeightKey: clip.height,
        ]
        var compression: [String: Any] = [AVVideoMaxKeyFrameIntervalKey: clip.keyframeInterval, AVVideoAllowFrameReorderingKey: false]
        switch clip.codec {
        case .h264:
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAverageBitRateKey] = 2_000_000
        case .hevc:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            compression[AVVideoAverageBitRateKey] = 2_000_000
        case .hevc10:
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            compression[AVVideoAverageBitRateKey] = 3_000_000
        case .proRes422Proxy, .proRes4444:
            compression = [:]
        }
        if !compression.isEmpty { settings[AVVideoCompressionPropertiesKey] = compression }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: clip.codec.inputPixelFormat,
            kCVPixelBufferWidthKey as String: clip.width,
            kCVPixelBufferHeightKey as String: clip.height,
        ])
        guard writer.canAdd(videoInput) else { throw WriteError.cannotStart("video input") }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if clip.audio != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else { throw WriteError.cannotStart("audio input") }
            writer.add(input)
            audioInput = input
        }

        guard writer.startWriting() else { throw WriteError.cannotStart(writer.error.map { "\($0)" } ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        // The writer interleaves its tracks and decides which input it wants fed
        // next, so each input is driven by the writer's own pull callback; feeding
        // one input while waiting on the other deadlocks at the interleave boundary.
        let failure = WriteFailure()
        let group = DispatchGroup()
        let videoQueue = DispatchQueue(label: "o.fixture.video")
        let frames = Counter()
        group.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                let frameIndex = frames.value
                guard frameIndex < clip.frameCount else {
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                guard let pool = adaptor.pixelBufferPool else {
                    failure.set("no pixel buffer pool")
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else {
                    failure.set("no pixel buffer")
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                paint(frameIndex: frameIndex, flash: clip.flashFrame == frameIndex, into: buffer)
                let time = CMTime(value: Int64(frameIndex), timescale: Int32(clip.fps))
                if !adaptor.append(buffer, withPresentationTime: time) {
                    failure.set(writer.error.map { "\($0)" } ?? "video append failed at frame \(frameIndex)")
                    videoInput.markAsFinished()
                    group.leave()
                    return
                }
                frames.value = frameIndex + 1
            }
        }

        if let audioInput, let audio = clip.audio {
            let samples = audioSamples(audio, seconds: clip.seconds)
            let audioFrames = samples.count / 2
            let writtenFrames = Counter()
            let audioQueue = DispatchQueue(label: "o.fixture.audio")
            group.enter()
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    let written = writtenFrames.value
                    guard written < audioFrames else {
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    let count = min(2400, audioFrames - written)
                    let slice = Array(samples[(written * 2)..<((written + count) * 2)])
                    do {
                        guard audioInput.append(try audioSampleBuffer(slice, startFrame: Int64(written))) else {
                            failure.set(writer.error.map { "\($0)" } ?? "audio append failed")
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    } catch {
                        failure.set("\(error)")
                        audioInput.markAsFinished()
                        group.leave()
                        return
                    }
                    writtenFrames.value = written + count
                }
            }
        }

        guard group.wait(timeout: .now() + 120) == .success else {
            writer.cancelWriting()
            throw WriteError.failed("the writer did not finish in time")
        }
        if let message = failure.message {
            writer.cancelWriting()
            throw WriteError.failed(message)
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 120) == .success else {
            writer.cancelWriting()
            throw WriteError.failed("the writer did not finish in time")
        }
        if writer.status != .completed {
            throw WriteError.failed(writer.error.map { "\($0)" } ?? "status \(writer.status.rawValue)")
        }
    }

    /// A counter one serial callback queue owns.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    /// The first failure reported by either input's callback.
    private final class WriteFailure: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ message: String) {
            lock.lock()
            if stored == nil { stored = message }
            lock.unlock()
        }

        var message: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// The samples of the clip's audio: interleaved stereo float.
    public static func audioSamples(_ audio: Audio, seconds: Double) -> [Float] {
        let frames = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: frames * 2)
        switch audio {
        case .tone(let hz, let gain):
            for i in 0..<frames {
                let v = Float(sin(2 * Double.pi * hz * Double(i) / sampleRate)) * gain
                out[i * 2] = v
                out[i * 2 + 1] = v
            }
        case .click(let atMs):
            let start = Int(atMs / 1000 * sampleRate)
            for i in start..<min(frames, start + 48) {
                let v: Float = (i - start) % 2 == 0 ? 0.9 : -0.9
                out[i * 2] = v
                out[i * 2 + 1] = v
            }
        }
        return out
    }

    static func audioSampleBuffer(_ samples: [Float], startFrame: Int64) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                      mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                                      mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw WriteError.failed("audio format")
        }
        let frames = samples.count / 2
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: samples.count * 4, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: samples.count * 4, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { throw WriteError.failed("block buffer") }
        try samples.withUnsafeBytes { raw in
            guard CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: samples.count * 4) == noErr else {
                throw WriteError.failed("block bytes")
            }
        }
        var sample: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
                                        presentationTimeStamp: CMTime(value: startFrame, timescale: Int32(sampleRate)), decodeTimeStamp: .invalid)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: timing.presentationTimeStamp, packetDescriptions: nil,
                                                                   sampleBufferOut: &sample) == noErr, let sample else {
            throw WriteError.failed("audio sample buffer")
        }
        return sample
    }

    // MARK: - Painting

    /// Luma of a pixel of frame `index` at (x, y), 0...1, before any range coding.
    static func luma(frameIndex: Int, x: Int, y: Int, width: Int, height: Int, flash: Bool) -> Double {
        if flash { return 1 }
        let barHeight = max(1, height / 10)
        if y < barHeight {
            let bar = min(barCount - 1, x * barCount / max(1, width))
            let bit = (frameIndex >> (barCount - 1 - bar)) & 1
            return bit == 1 ? 1 : 0
        }
        let block = frameIndex % max(1, width)
        if abs(x - block) <= 2 && y > barHeight + 2 && y < height - 2 { return 1 }
        return 0.15 + 0.6 * Double(y - barHeight) / Double(max(1, height - barHeight))
    }

    static func paint(frameIndex: Int, flash: Bool, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let l = luma(frameIndex: frameIndex, x: x, y: y, width: width, height: height, flash: flash)
                    // The right third is half transparent, so ProRes 4444 carries alpha to test.
                    let alpha: Double = x > width * 2 / 3 && !flash ? 0.5 : 1
                    let code = UInt8((l * 255).rounded())
                    row[x * 4] = UInt8((Double(code) * alpha).rounded())
                    row[x * 4 + 1] = UInt8((Double(code) * alpha).rounded())
                    row[x * 4 + 2] = UInt8((Double(code) * alpha).rounded())
                    row[x * 4 + 3] = UInt8((alpha * 255).rounded())
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let c0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<height {
                let row = y0.advanced(by: y * yRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let l = luma(frameIndex: frameIndex, x: x, y: y, width: width, height: height, flash: flash)
                    row[x] = UInt8((16 + 219 * l).rounded())
                }
            }
            let tint = Double(frameIndex % 60) / 60   // a slow chroma drift, for visible motion
            for y in 0..<(height / 2) {
                let row = c0.advanced(by: y * cRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<(width / 2) {
                    row[x * 2] = UInt8((128 + 40 * (tint - 0.5)).rounded())
                    row[x * 2 + 1] = UInt8((128 - 40 * (tint - 0.5)).rounded())
                }
            }
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            guard let y0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 0), let c0 = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return }
            let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let cRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            for y in 0..<height {
                let row = y0.advanced(by: y * yRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width {
                    let l = luma(frameIndex: frameIndex, x: x, y: y, width: width, height: height, flash: flash)
                    row[x] = UInt16((64 + 876 * l).rounded()) << 6
                }
            }
            let tint = Double(frameIndex % 60) / 60
            for y in 0..<(height / 2) {
                let row = c0.advanced(by: y * cRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<(width / 2) {
                    row[x * 2] = UInt16((512 + 160 * (tint - 0.5)).rounded()) << 6
                    row[x * 2 + 1] = UInt16((512 - 160 * (tint - 0.5)).rounded()) << 6
                }
            }
        default:
            break
        }
    }

    // MARK: - Reading the bars back

    /// The frame index a decoded buffer shows, read from its bars; nil when
    /// the bars are not legible (a flash frame reads as all ones).
    public static func frameIndex(in buffer: CVPixelBuffer) -> Int? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let y = max(0, height / 20)
        func luma(_ x: Int) -> Double? {
            switch format {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
                return Double(row[x]) / 255
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                 kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
                return Double(row[x]) / 65535
            case kCVPixelFormatType_64RGBAHalf:
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: Float16.self)
                return Double(Float(row[x * 4]))
            case kCVPixelFormatType_32BGRA:
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
                return Double(row[x * 4 + 1]) / 255
            default:
                return nil
            }
        }
        var index = 0
        for bar in 0..<barCount {
            let x = (bar * width + width / (2 * barCount)) / barCount
            guard let l = luma(x) else { return nil }
            index = (index << 1) | (l > 0.5 ? 1 : 0)
        }
        return index
    }

    /// The frame index of a rendered frame (linear light), read from its bars.
    public static func frameIndex(in frame: CapturedFrame, contentRect: UVRect = .full) -> Int? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let contentHeight = Float(frame.height) * contentRect.height
        let y = Int(Float(frame.height) * contentRect.v + contentHeight / 20)
        guard y >= 0, y < frame.height else { return nil }
        var index = 0
        for bar in 0..<barCount {
            let fx = contentRect.u + contentRect.width * (Float(bar) + 0.5) / Float(barCount)
            let x = min(frame.width - 1, max(0, Int(fx * Float(frame.width))))
            let p = frame[x, y]
            let luma = 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b
            index = (index << 1) | (luma > 0.2 ? 1 : 0)
        }
        return index
    }
}
