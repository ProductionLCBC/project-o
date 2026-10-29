// OEngine — Spec 4 §6, the video file content source.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Metal
import VideoToolbox
import Synchronization

/// Spec 4 §6 — "Video files ... decode with a VTDecompressionSession per
/// playing instance ... Request output in the source's native depth: NV12 or
/// P010 for 4:2:0, 4:2:2 10-bit for ProRes 422, 16-bit RGBA for ProRes 4444
/// and other alpha sources."
enum DecoderOutput {
    /// The pixel format to ask VideoToolbox for, and the layout it gives the shader.
    static func format(for formatDescription: CMFormatDescription) -> (OSType, SourceLayout) {
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        let extensions = CMFormatDescriptionGetExtensions(formatDescription) as? [CFString: Any] ?? [:]
        let depth = (extensions[kCMFormatDescriptionExtension_Depth] as? Int) ?? 24
        let bitsPerComponent = (extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? Int) ?? 8
        switch subtype {
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return (kCVPixelFormatType_64RGBAHalf, .rgba16)
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
             kCMVideoCodecType_AppleProRes422Proxy:
            return (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, .yuv422p10)
        default:
            if depth == 32 { return (kCVPixelFormatType_64RGBAHalf, .rgba16) }
            if bitsPerComponent > 8 { return (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .p010) }
            return (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .nv12)
        }
    }

    static func planeFormats(for layout: SourceLayout) -> (MTLPixelFormat, MTLPixelFormat?) {
        switch layout {
        case .nv12: return (.r8Unorm, .rg8Unorm)
        case .p010, .yuv422p10: return (.r16Unorm, .rg16Unorm)
        case .rgba16, .linearRGBA16, .finished: return (.rgba16Float, nil)
        case .bgra8sRGB: return (.bgra8Unorm_srgb, nil)
        }
    }
}

/// Spec 4 §6 — one playing instance: its decode thread, frame queue, loop
/// reader and session. Spec 4 §12 — "Decoder error on a frame: skip the
/// frame, repeat the previous, count it; after 10 consecutive errors, hold
/// the last frame, mark the instance missing, log once."
public final class VideoFileSource: ContentSource, @unchecked Sendable {
    public let url: URL
    public let inMs: Double
    public let outMs: Double?
    public let loop: Bool
    public let queue: FrameQueue
    private let device: MTLDevice?
    private let demuxer: any Demuxer
    private let log: EngineLog?
    private var thread: Thread?
    private let running = Atomic<Bool>(false)
    private let releasedFlag = Atomic<Bool>(false)
    private let layoutValue = Atomic<Int32>(0)
    private let widthValue = Atomic<Int32>(0)
    private let heightValue = Atomic<Int32>(0)
    private let failed = Atomic<Bool>(false)
    private let errorsTotal = Atomic<Int64>(0)
    private let framesDecoded = Atomic<Int64>(0)
    private let loopsCompleted = Atomic<Int64>(0)
    private var textureCache: CVMetalTextureCache?
    private var session: VTDecompressionSession?
    private var consecutiveErrors = 0

    public init(url: URL, inMs: Double, outMs: Double?, loop: Bool, device: MTLDevice?, demuxer: any Demuxer = AVAssetReaderDemuxer(),
                queueCapacity: Int = 6, log: EngineLog? = nil) {
        self.url = url
        self.inMs = max(0, inMs)
        self.outMs = outMs
        self.loop = loop
        self.device = device
        self.demuxer = demuxer
        self.log = log
        queue = FrameQueue(capacity: queueCapacity)
    }

    deinit {
        running.store(false, ordering: .releasing)
    }

    // MARK: - ContentSource

    public var layout: SourceLayout {
        switch layoutValue.load(ordering: .acquiring) {
        case 1: return .nv12
        case 2: return .p010
        case 3: return .yuv422p10
        case 4: return .rgba16
        default: return .nv12
        }
    }

    public var size: PixelSize {
        PixelSize(width: Int(widthValue.load(ordering: .acquiring)), height: Int(heightValue.load(ordering: .acquiring)))
    }

    public var isReady: Bool { queue.hasFrame }
    public var queueDepth: Int { queue.depth }
    public var isFailed: Bool { failed.load(ordering: .acquiring) }
    public var decodeErrors: Int64 { errorsTotal.load(ordering: .relaxed) }
    public var decodedFrames: Int64 { framesDecoded.load(ordering: .relaxed) }
    public var loops: Int64 { loopsCompleted.load(ordering: .relaxed) }
    public var isReleased: Bool { releasedFlag.load(ordering: .acquiring) }

    public func pick(mediaTimeMs: Double, into frame: inout PickedFrame) -> PickResult {
        queue.pick(mediaTimeMs: mediaTimeMs, into: &frame)
    }

    public func release() {
        releasedFlag.store(true, ordering: .releasing)
        running.store(false, ordering: .releasing)
    }

    // MARK: - The decode thread (Spec 4 §3: "Decode, one per playing instance ... user-initiated")

    /// Spec 4 §6 — start decoding: pre-roll to the in-point, then keep the
    /// queue full; at the out-point loop through a second reader or end.
    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in self.decodeLoop() }
        thread.name = "o.engine.decode"
        thread.qualityOfService = .userInitiated
        self.thread = thread
        thread.start()
    }

    private struct Reader {
        var session: any DemuxSession
        var offsetMs: Double
    }

    private func decodeLoop() {
        var reader: Reader
        do {
            reader = Reader(session: try demuxer.open(url, startMs: inMs), offsetMs: 0)
        } catch {
            log?.error("cannot open \(url.lastPathComponent): \(error)")
            failed.store(true, ordering: .releasing)
            queue.markEnded()
            return
        }
        var standby: Reader?
        let stream = reader.session.description
        widthValue.store(Int32(stream.size.width), ordering: .releasing)
        heightValue.store(Int32(stream.size.height), ordering: .releasing)
        let end = outMs ?? stream.durationMs
        let loopLength = max(0, end - inMs)
        var pending: [DecodedFrame] = []   // decoded, waiting for room (display order)
        var atEnd = false

        while running.load(ordering: .relaxed) {
            // Hand over what the queue has room for.
            while let next = pending.first, queue.hasRoom {
                queue.push(next)
                pending.removeFirst()
            }
            if !pending.isEmpty || atEnd {
                if atEnd && pending.isEmpty { queue.markEnded() }
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            // Pools around the AVFoundation and VideoToolbox calls: a decode thread lives for the whole instance.
            guard let sample = autoreleasepool(invoking: { reader.session.nextVideoSample() }) else {
                // End of the reader: loop or end.
                if loop, loopLength > 0 {
                    reader = switchReader(from: reader, standby: &standby, loopLength: loopLength)
                    continue
                }
                atEnd = true
                continue
            }
            if sample.presentationMs >= end, end.isFinite {
                if loop, loopLength > 0 {
                    reader = switchReader(from: reader, standby: &standby, loopLength: loopLength)
                    continue
                }
                atEnd = true
                continue
            }
            // Spec 4 §6 — "keeps a second reader pre-rolled at the in-point".
            if loop, standby == nil, loopLength > 0, sample.presentationMs >= inMs {
                if let second = try? demuxer.open(url, startMs: inMs) {
                    standby = Reader(session: second, offsetMs: reader.offsetMs + loopLength)
                }
            }
            let decoded = autoreleasepool { decode(sample, offsetMs: reader.offsetMs) }
            for frame in decoded where frame.presentationMs - reader.offsetMs >= inMs - 0.001 {
                pending.append(frame)
            }
        }
        reader.session.close()
        standby?.session.close()
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    /// Spec 4 §6 — "at the out-point the queue switches readers on the exact
    /// frame and the old reader is recycled into the next pre-roll."
    private func switchReader(from current: Reader, standby: inout Reader?, loopLength: Double) -> Reader {
        current.session.close()
        loopsCompleted.add(1, ordering: .relaxed)
        if let next = standby {
            standby = nil
            return next
        }
        if let fresh = try? demuxer.open(url, startMs: inMs) {
            return Reader(session: fresh, offsetMs: current.offsetMs + loopLength)
        }
        log?.error("cannot reopen \(url.lastPathComponent) for the loop")
        failed.store(true, ordering: .releasing)
        return current
    }

    /// Decode one compressed sample; frames come back in display order.
    private func decode(_ sample: CompressedSample, offsetMs: Double) -> [DecodedFrame] {
        // The demuxer's payload is a CMSampleBuffer; Core Foundation casts are checked by type id.
        guard CFGetTypeID(sample.payload as CFTypeRef) == CMSampleBufferGetTypeID() else { return [] }
        let sampleBuffer = sample.payload as! CMSampleBuffer
        if session == nil {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return [] }
            createSession(for: format)
        }
        guard let session else { return [] }
        let collected = DecodeCollector()
        let layout = self.layout
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { [self] status, _, imageBuffer, pts, duration in
            guard status == noErr, let imageBuffer else {
                collected.error = status
                return
            }
            if let frame = self.wrap(imageBuffer, pts: pts.seconds * 1000 + offsetMs, duration: duration.isNumeric ? duration.seconds * 1000 : 0, layout: layout) {
                collected.frames.append(frame)
            }
        }
        if status != noErr || collected.error != noErr {
            countError(status != noErr ? status : collected.error)
        } else {
            consecutiveErrors = 0
            framesDecoded.add(Int64(collected.frames.count), ordering: .relaxed)
        }
        return collected.frames.sorted { $0.presentationMs < $1.presentationMs }
    }

    /// What one synchronous decode call produced.
    private final class DecodeCollector: @unchecked Sendable {
        var frames: [DecodedFrame] = []
        var error: OSStatus = noErr
    }

    private func countError(_ status: OSStatus) {
        errorsTotal.add(1, ordering: .relaxed)
        consecutiveErrors += 1
        if consecutiveErrors == 10 {
            log?.error("decoder: 10 consecutive errors on \(url.lastPathComponent) (last \(status)); holding the last frame")
            failed.store(true, ordering: .releasing)
        }
        if status == kVTInvalidSessionErr {
            // Spec 4 §12 — "Decoder session dies: Recreate on the decode thread".
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
        }
    }

    private func createSession(for format: CMFormatDescription) {
        let (pixelFormat, layout) = DecoderOutput.format(for: format)
        layoutValue.store(layout.shaderCode, ordering: .releasing)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        widthValue.store(dimensions.width, ordering: .releasing)
        heightValue.store(dimensions.height, ordering: .releasing)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                  imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                  decompressionSessionOut: &created)
        guard status == noErr, let created else {
            log?.error("cannot create a decoder session for \(url.lastPathComponent): \(status)")
            failed.store(true, ordering: .releasing)
            return
        }
        session = created
        if let device, textureCache == nil {
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            textureCache = cache
        }
    }

    /// Spec 4 §1 guarantee 2 — "Frames go from the decoder's IOSurface to a
    /// Metal texture": wrap the planes through the texture cache, no copy.
    private func wrap(_ buffer: CVImageBuffer, pts: Double, duration: Double, layout: SourceLayout) -> DecodedFrame? {
        var frame = DecodedFrame(pixelBuffer: buffer, presentationMs: pts, durationMs: duration, layout: layout)
        guard let cache = textureCache else { return frame }
        let (format0, format1) = DecoderOutput.planeFormats(for: layout)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var view0: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format0, width, height, 0, &view0)
        guard let view0, let plane0 = CVMetalTextureGetTexture(view0) else { return nil }
        frame.view0 = view0
        frame.plane0 = plane0
        if let format1, CVPixelBufferGetPlaneCount(buffer) > 1 {
            let w1 = CVPixelBufferGetWidthOfPlane(buffer, 1)
            let h1 = CVPixelBufferGetHeightOfPlane(buffer, 1)
            var view1: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format1, w1, h1, 1, &view1)
            guard let view1, let plane1 = CVMetalTextureGetTexture(view1) else { return nil }
            frame.view1 = view1
            frame.plane1 = plane1
        }
        return frame
    }
}
