// OEngine — Spec 4 §11, the mix graph for one device.

import Foundation
import OCore
import Synchronization

/// Spec 4 §11 — one playing instance's sound: its ring, gain with the 50 ms
/// ramp, its envelope from the running audio transition, its routing to the
/// device's channels, and the clock reading it publishes.
public final class AudioInstance: @unchecked Sendable {
    public let handle: InstanceHandle
    public let ring: AudioRing
    public let inMs: Double
    /// Spec 4 §11 — "A pool item's syncOffsetMs ... delays audio when positive by holding samples in the ring".
    public let holdFrames: Int
    /// Device channel index per instance channel (Spec 1 §3, Audio Output `channels`).
    public let routing: [Int]
    let gainTarget = Atomic<Float>(1)
    var gainCurrent: Float = 1
    var held = 0
    var envelope = Envelope.flat(1)
    let playing = Atomic<Bool>(true)
    let delivered = Atomic<Int64>(0)
    let deliveredAtHostNs = Atomic<Int64>(0)
    let underrunCount = Atomic<Int64>(0)
    let active = Atomic<Bool>(false)

    public init(handle: InstanceHandle, ring: AudioRing, inMs: Double, syncOffsetMs: Int, routing: [Int]) {
        self.handle = handle
        self.ring = ring
        self.inMs = inMs
        holdFrames = max(0, syncOffsetMs) * 48
        self.routing = routing
    }

    /// Spec 4 §11 — "An instance's media time is derived from the samples of
    /// it that have reached the device": the ms of media delivered, plus the
    /// time since the device took them.
    public func mediaTimeMs(nowNs: Int64) -> Double {
        let frames = delivered.load(ordering: .acquiring)
        let since = playing.load(ordering: .relaxed) ? max(0, nowNs - deliveredAtHostNs.load(ordering: .relaxed)) : 0
        return inMs + Double(frames) / 48 + Double(since) / 1_000_000
    }

    public var underruns: Int64 { underrunCount.load(ordering: .relaxed) }
    public var framesDelivered: Int64 { delivered.load(ordering: .relaxed) }

    /// Spec 4 §11 — the per-instance gain envelope an audio transition imposes.
    struct Envelope {
        var from: Float
        var to: Float
        var startFrame: Int64
        var lengthFrames: Int64
        /// Silence until `startFrame` (a fade-through-silence incoming, a J cut).
        var silentBefore: Bool

        static func flat(_ value: Float) -> Envelope { Envelope(from: value, to: value, startFrame: 0, lengthFrames: 0, silentBefore: false) }

        func value(at frame: Int64) -> Float {
            if frame < startFrame { return silentBefore ? 0 : from }
            guard lengthFrames > 0 else { return to }
            let t = min(1, Float(frame - startFrame) / Float(lengthFrames))
            return from + (to - from) * t
        }

        func isDone(at frame: Int64) -> Bool { frame >= startFrame + lengthFrames }
    }
}

/// Spec 4 §11 — "The callback pulls from every instance routed to that
/// device, applies per-instance gain (the channel's tracked gain plus any
/// override) with a 50 ms ramp on change, applies the running audio
/// transition (crossfade or fade-through-silence between the outgoing and
/// incoming instance of a channel, with its offset), sums, and writes to the
/// device channels the Audio Output object maps." Then the per-output delay
/// line and mute (Spec 4 §11, "Output delay", "Mute").
///
/// Real-time rules (Spec 4 §3): the callback walks a fixed table of instance
/// slots, reads rings and atomics, and allocates nothing. Instances are
/// installed into free slots on the control side before being marked active.
public final class AudioGraph: @unchecked Sendable {
    public static let maxInstances = 16
    public static let gainRampFrames: Int64 = 2400     // 50 ms at 48 kHz
    public static let muteRampFrames: Int64 = 960      // 20 ms

    public let device: any AudioDevice
    public let outputs: [AudioOutput]
    private let slots: UnsafeMutablePointer<AudioInstance?>
    private let lock = NSLock()
    private let log: EngineLog?
    private var frameCounter: Int64 = 0
    private let framesRendered = Atomic<Int64>(0)
    private let totalUnderruns = Atomic<Int64>(0)
    private let scratch: UnsafeMutablePointer<Float>
    // Per output: delay line and mute.
    private let delayLines: [DelayLine]
    private let muteTargets: [MuteTarget]
    private var muteCurrent: [Float]
    private let outputChannelMap: [[Int]]

    /// One output's mute target, written by the control side, read by the callback.
    final class MuteTarget: @unchecked Sendable {
        let value = Atomic<Float>(1)
    }

    public init(device: any AudioDevice, outputs: [AudioOutput], log: EngineLog? = nil) {
        self.device = device
        self.outputs = outputs
        self.log = log
        slots = UnsafeMutablePointer<AudioInstance?>.allocate(capacity: AudioGraph.maxInstances)
        slots.initialize(repeating: nil, count: AudioGraph.maxInstances)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        scratch.initialize(repeating: 0, count: 8)
        delayLines = outputs.map { DelayLine(channels: device.channelCount, delayFrames: max(0, min(1000, $0.delayMs)) * 48) }
        muteTargets = outputs.map { _ in MuteTarget() }
        muteCurrent = outputs.map { _ in 1 }
        outputChannelMap = outputs.map { $0.channels.map { max(0, min(device.channelCount - 1, $0)) } }
    }

    deinit {
        slots.deinitialize(count: AudioGraph.maxInstances)
        slots.deallocate()
        scratch.deallocate()
    }

    public func start() throws {
        try device.start { [self] output, frames, hostTime in render(output: output, frames: frames, hostTimeNs: hostTime) }
    }

    public func stop() {
        device.stop()
    }

    // MARK: - Control side

    /// Spec 1 §2 — the channel's `audioOutputs` name the outputs an instance
    /// reaches; the device channel of each instance channel comes from the
    /// first of them (Spec 4 §11: "the first-numbered device is the clock").
    public func routing(forAudioOutputs numbers: [Int], instanceChannels: Int) -> [Int] {
        let outputs = numbers.compactMap { number in self.outputs.first { $0.number == number } }
        guard let first = outputs.first else { return instanceChannels == 1 ? [0, 1].prefix(device.channelCount).map { $0 } : Array(0..<min(instanceChannels, device.channelCount)) }
        let map = first.channels
        if instanceChannels == 1 { return map.isEmpty ? [0] : map }
        return (0..<instanceChannels).map { map.isEmpty ? $0 : map[$0 % map.count] }
    }

    /// Install an instance; false when every slot is taken.
    @discardableResult
    public func add(_ instance: AudioInstance, gainDb: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        instance.gainTarget.store(AudioGraph.linear(gainDb), ordering: .relaxed)
        instance.gainCurrent = AudioGraph.linear(gainDb)
        instance.held = instance.holdFrames
        for i in 0..<AudioGraph.maxInstances where slots[i] == nil {
            slots[i] = instance
            instance.active.store(true, ordering: .releasing)
            return true
        }
        log?.error("audio: no free instance slot")
        return false
    }

    public func remove(_ instance: AudioInstance) {
        instance.active.store(false, ordering: .releasing)
        lock.lock()
        for i in 0..<AudioGraph.maxInstances where slots[i] === instance { slots[i] = nil }
        lock.unlock()
    }

    public static func linear(_ db: Double) -> Float {
        db <= -120 ? 0 : Float(pow(10, db / 20))
    }

    /// Spec 4 §11 — "per-instance gain ... with a 50 ms ramp on change".
    public func setGain(_ db: Double, for instance: AudioInstance) {
        instance.gainTarget.store(AudioGraph.linear(db), ordering: .releasing)
    }

    public func setPlaying(_ playing: Bool, for instance: AudioInstance) {
        instance.playing.store(playing, ordering: .releasing)
    }

    /// Spec 4 §11 — the audio transition between a channel's outgoing and
    /// incoming instance: "crossfade or fade-through-silence ..., with its
    /// offset" (Spec 1 §2: `offsetMs` "signed; measured from the trigger").
    public func startTransition(outgoing: AudioInstance?, incoming: AudioInstance?, type: AudioTransitionType, ms: Int, offsetMs: Int) {
        let start = currentFrame + Int64(max(0, offsetMs)) * 48
        let length = Int64(max(0, ms)) * 48
        lock.lock()
        defer { lock.unlock() }
        switch type {
        case .cut:
            outgoing?.envelope = .init(from: 1, to: 0, startFrame: start, lengthFrames: 0, silentBefore: false)
            incoming?.envelope = .init(from: 0, to: 1, startFrame: start, lengthFrames: 0, silentBefore: true)
        case .crossfade:
            outgoing?.envelope = .init(from: 1, to: 0, startFrame: start, lengthFrames: length, silentBefore: false)
            incoming?.envelope = .init(from: 0, to: 1, startFrame: start, lengthFrames: length, silentBefore: true)
        case .fadeThroughSilence:
            let half = length / 2
            outgoing?.envelope = .init(from: 1, to: 0, startFrame: start, lengthFrames: half, silentBefore: false)
            incoming?.envelope = .init(from: 0, to: 1, startFrame: start + half, lengthFrames: half, silentBefore: true)
        }
    }

    /// Spec 4 §11 — "Mute of an audio output zeroes that device's mix with a 20 ms ramp".
    public func setMuted(_ muted: Bool, output number: Int) {
        for (i, output) in outputs.enumerated() where output.number == number {
            muteTargets[i].value.store(muted ? 0 : 1, ordering: .releasing)
        }
    }

    public var currentFrame: Int64 { framesRendered.load(ordering: .acquiring) }
    public var underruns: Int64 { totalUnderruns.load(ordering: .relaxed) }

    /// Spec 4 §2 — "A/V sync is anchored to the audio device clock": the
    /// instance's media time now, on the device's own clock.
    public func mediaTimeMs(of instance: AudioInstance) -> Double {
        instance.mediaTimeMs(nowNs: device.hostTimeNowNs)
    }

    // MARK: - The callback (Core Audio's real-time thread)

    func render(output: UnsafeMutablePointer<Float>, frames: Int, hostTimeNs: Int64) {
        let channels = device.channelCount
        let frameNs = Int64(1_000_000_000 / device.sampleRate)
        for i in 0..<(frames * channels) { output[i] = 0 }
        // Mix every active instance into the device channels.
        for slot in 0..<AudioGraph.maxInstances {
            guard let instance = slots[slot], instance.active.load(ordering: .acquiring) else { continue }
            let playing = instance.playing.load(ordering: .relaxed)
            let target = instance.gainTarget.load(ordering: .relaxed)
            var gain = instance.gainCurrent
            let step = (target - gain) / Float(AudioGraph.gainRampFrames)
            var deliveredNow: Int64 = 0
            for f in 0..<frames {
                if gain != target {
                    gain += step
                    if (step > 0 && gain > target) || (step < 0 && gain < target) { gain = target }
                }
                guard playing else { continue }
                let frame = frameCounter + Int64(f)
                let envelope = instance.envelope.value(at: frame)
                if instance.held > 0 {
                    // Spec 4 §11 — a positive sync offset holds the samples; the clock runs, so the picture leads by the offset.
                    instance.held -= 1
                    deliveredNow += 1
                    continue
                }
                let got = instance.ring.readFrame(into: scratch)
                if !got {
                    if !instance.ring.isEnded {
                        instance.underrunCount.add(1, ordering: .relaxed)
                        totalUnderruns.add(1, ordering: .relaxed)
                    }
                    continue
                }
                deliveredNow += 1
                let level = gain * envelope
                for c in 0..<instance.ring.channels {
                    let device = c < instance.routing.count ? instance.routing[c] : c
                    guard device < channels else { continue }
                    output[f * channels + device] += scratch[c] * level
                }
            }
            instance.gainCurrent = gain
            if deliveredNow > 0 {
                instance.delivered.add(deliveredNow, ordering: .relaxed)
                instance.deliveredAtHostNs.store(hostTimeNs + Int64(frames) * frameNs, ordering: .releasing)
            }
        }
        // Per output: delay, then mute.
        for (i, line) in delayLines.enumerated() {
            let channelsOfOutput = outputChannelMap[i]
            let target = muteTargets[i].value.load(ordering: .relaxed)
            var mute = muteCurrent[i]
            let step = (target - mute) / Float(AudioGraph.muteRampFrames)
            for f in 0..<frames {
                if mute != target {
                    mute += step
                    if (step > 0 && mute > target) || (step < 0 && mute < target) { mute = target }
                }
                for c in channelsOfOutput {
                    let index = f * channels + c
                    output[index] = line.process(output[index], channel: c) * mute
                }
            }
            muteCurrent[i] = mute
        }
        frameCounter += Int64(frames)
        framesRendered.store(frameCounter, ordering: .releasing)
    }
}

/// Spec 4 §11 — "An Audio Output's delayMs (up to 1000 ms ...) is a fixed
/// delay line at the end of that device's mix, applied after the clock
/// reading so sync is measured at the device, not after the delay."
final class DelayLine: @unchecked Sendable {
    let channels: Int
    let delayFrames: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var position = 0

    init(channels: Int, delayFrames: Int) {
        self.channels = max(1, channels)
        self.delayFrames = max(0, delayFrames)
        let count = max(1, self.delayFrames) * self.channels
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0, count: count)
    }

    deinit {
        buffer.deallocate()
    }

    /// One sample of one channel in, the sample from `delayFrames` ago out.
    /// Channels are processed in order within a frame; the position advances
    /// once per frame, on the last channel.
    @inline(__always)
    func process(_ sample: Float, channel: Int) -> Float {
        guard delayFrames > 0 else { return sample }
        let index = position * channels + channel
        let delayed = buffer[index]
        buffer[index] = sample
        if channel == channels - 1 { position = (position + 1) % delayFrames }
        return delayed
    }
}
