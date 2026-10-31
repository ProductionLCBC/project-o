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

/// Spec 4 §13 — "Per minute: memory in use (heaps, decoder pools, caches),
/// decoder sessions alive, cache hit rates, audio underruns per device,
/// watchdog events."
public struct MinuteRecord: Equatable, Sendable {
    public var minute: Int
    public var memoryBytes: Int64
    public var decoderSessions: Int
    public var textCacheHitRate: Double
    public var audioUnderruns: Int
    public var watchdogEvents: Int
    public var watchdogRecoveries: Int

    public init(minute: Int, memoryBytes: Int64, decoderSessions: Int, textCacheHitRate: Double, audioUnderruns: Int,
                watchdogEvents: Int, watchdogRecoveries: Int) {
        self.minute = minute
        self.memoryBytes = memoryBytes
        self.decoderSessions = decoderSessions
        self.textCacheHitRate = textCacheHitRate
        self.audioUnderruns = audioUnderruns
        self.watchdogEvents = watchdogEvents
        self.watchdogRecoveries = watchdogRecoveries
    }
}
