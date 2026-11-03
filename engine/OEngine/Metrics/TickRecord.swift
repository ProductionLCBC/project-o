// OEngine — Spec 4 §13, the records.

import Foundation

/// Spec 4 §13 — "Per tick: frame number, master clock time, CPU encode time,
/// GPU time from command-buffer timestamps (channel, stack and sink buffers
/// separately), number of channel and stack passes, aux passes skipped,
/// decoder queue depth per instance, `videoRepeat` per channel, `textLate`
/// count, plan reused flag." A fixed-size value the render thread writes into
/// the ring without allocating: channels that repeated are a bitmask (bit 0
/// is channel 1) and queue depths are packed four bits per instance.
public struct TickRecord: Equatable, Sendable {
    public var frame: Int64 = 0
    public var masterTimeNs: Int64 = 0
    public var cpuEncodeNs: Int64 = 0
    public var gpuChannelNs: Int64 = 0
    public var gpuStackNs: Int64 = 0
    public var gpuSinkNs: Int64 = 0
    public var channelPasses: Int32 = 0
    public var stackPasses: Int32 = 0
    public var auxPasses: Int32 = 0
    public var auxSkipped: Int32 = 0
    public var planReused: Bool = false
    public var gpuFailed: Bool = false
    public var textLate: Int32 = 0
    public var videoRepeatChannels: UInt64 = 0
    public var queueDepths: UInt64 = 0
    public var instanceCount: UInt8 = 0

    public init() {}

    public var gpuTotalNs: Int64 { gpuChannelNs + gpuStackNs + gpuSinkNs }

    /// The channel numbers whose frame was repeated this tick.
    public var videoRepeat: [Int] {
        (0..<64).filter { videoRepeatChannels & (1 << UInt64($0)) != 0 }.map { $0 + 1 }
    }

    public mutating func markRepeat(channel: Int) {
        guard channel >= 1 else { return }
        videoRepeatChannels |= 1 << UInt64(min(63, channel - 1))
    }

    /// The decoder queue depth of each live instance, in handle order.
    public var instanceQueueDepths: [Int] {
        var count = Int(instanceCount)
        if count == 0 {
            for i in (0..<16).reversed() where (queueDepths >> UInt64(i * 4)) & 0xF != 0 {
                count = i + 1
                break
            }
        }
        return (0..<min(16, count)).map { Int((queueDepths >> UInt64($0 * 4)) & 0xF) }
    }

    public mutating func setQueueDepth(_ depth: Int, instance: Int) {
        guard instance >= 0, instance < 16 else { return }
        let shift = UInt64(instance * 4)
        queueDepths &= ~(UInt64(0xF) << shift)
        queueDepths |= UInt64(min(15, max(0, depth))) << shift
        instanceCount = max(instanceCount, UInt8(instance + 1))
    }
}

/// Spec 4 §10 — "the completion callback reports `completed`, `displayedLate`,
/// `dropped` or `flushed` per frame".
public enum SinkCompletion: String, Codable, Sendable {
    case completed
    case displayedLate
    case dropped
    case flushed
}

/// Spec 4 §13 — "Per output, per presented frame: presented or re-presented,
/// present latency (tick to vsync or to scheduled slot), DeckLink completion
/// result, drop count since start."
public struct PresentRecord: Equatable, Sendable {
    public var output: Int
    public var frame: Int64
    public var rePresented: Bool
    public var latencyNs: Int64
    public var completion: SinkCompletion?
    public var dropsSinceStart: Int64

    public init(output: Int, frame: Int64, rePresented: Bool, latencyNs: Int64, completion: SinkCompletion?, dropsSinceStart: Int64) {
        self.output = output
        self.frame = frame
        self.rePresented = rePresented
        self.latencyNs = latencyNs
        self.completion = completion
        self.dropsSinceStart = dropsSinceStart
    }
}

/// Spec 4 §13 — "Per minute: memory in use, as the process footprint (the
/// kernel's `phys_footprint`, which counts the GPU-owned textures and heaps
/// and leaves out purgeable cache memory) beside the resident size, and its
/// parts: the malloc zones' live and allocated bytes with the purgeable zone
/// on its own, the resource table's texture bytes, the decoder pools' bytes,
/// the text cache's bytes and the readback buffers' bytes; decoder sessions
/// alive, cache hit rates, audio underruns per device, watchdog events." The
/// breakdown fields read as zero in records written before 2026-11-03.
public struct MinuteRecord: Equatable, Sendable {
    public var minute: Int
    /// The resident size: what the record carried first, kept for older
    /// readers; §13 judges it only when the footprint is missing.
    public var memoryBytes: Int64
    public var decoderSessions: Int
    public var textCacheHitRate: Double
    public var audioUnderruns: Int
    public var watchdogEvents: Int
    public var watchdogRecoveries: Int
    public var footprintBytes: Int64
    /// The graphics-tagged part of the footprint (`ProcessMemory`).
    public var graphicsFootprintBytes: Int64
    public var heapLiveBytes: Int64
    public var heapAllocatedBytes: Int64
    public var purgeableLiveBytes: Int64
    public var textureBytes: Int64
    public var decoderPoolBytes: Int64
    public var textCacheBytes: Int64
    public var readbackBytes: Int64
    /// Spec 4 §12 and §13 (Area 5 reading, approved 2026-11-03) — the
    /// thermal state and the memory-pressure state in that minute, so "a
    /// rising GPU time has an explanation", and the thumbnail cache's hit
    /// rate beside the text cache's ("cache hit rates"). Records written
    /// before 2026-11-03 read as unknown and as a cache nothing asked of.
    public var thermalState: ThermalLevel = .unknown
    public var memoryPressure: MemoryPressureLevel = .unknown
    public var thumbnailCacheHitRate: Double = 1
    /// Spec 4 §13 — "audio underruns per device" in that minute, keyed by the
    /// graph's primary device (Area 16); records written before read as empty.
    public var audioUnderrunsByDevice: [String: Int] = [:]

    public init(minute: Int, memoryBytes: Int64, decoderSessions: Int, textCacheHitRate: Double, audioUnderruns: Int,
                watchdogEvents: Int, watchdogRecoveries: Int,
                footprintBytes: Int64 = 0, graphicsFootprintBytes: Int64 = 0, heapLiveBytes: Int64 = 0, heapAllocatedBytes: Int64 = 0,
                purgeableLiveBytes: Int64 = 0, textureBytes: Int64 = 0, decoderPoolBytes: Int64 = 0, textCacheBytes: Int64 = 0,
                readbackBytes: Int64 = 0, thermalState: ThermalLevel = .unknown, memoryPressure: MemoryPressureLevel = .unknown,
                thumbnailCacheHitRate: Double = 1) {
        self.minute = minute
        self.memoryBytes = memoryBytes
        self.decoderSessions = decoderSessions
        self.textCacheHitRate = textCacheHitRate
        self.audioUnderruns = audioUnderruns
        self.watchdogEvents = watchdogEvents
        self.watchdogRecoveries = watchdogRecoveries
        self.footprintBytes = footprintBytes
        self.graphicsFootprintBytes = graphicsFootprintBytes
        self.heapLiveBytes = heapLiveBytes
        self.heapAllocatedBytes = heapAllocatedBytes
        self.purgeableLiveBytes = purgeableLiveBytes
        self.textureBytes = textureBytes
        self.decoderPoolBytes = decoderPoolBytes
        self.textCacheBytes = textCacheBytes
        self.readbackBytes = readbackBytes
        self.thermalState = thermalState
        self.memoryPressure = memoryPressure
        self.thumbnailCacheHitRate = thumbnailCacheHitRate
    }

    /// Spec 4 §13 — the figure the memory threshold judges: the footprint less
    /// its graphics-tagged part.
    public var judgedFootprintBytes: Int64 { max(0, footprintBytes - graphicsFootprintBytes) }
}
