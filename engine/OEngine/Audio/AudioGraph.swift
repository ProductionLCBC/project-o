// OEngine — Spec 4 §11, the mix graph for one device.

import Foundation
import OCore
import Synchronization

/// Spec 4 §11 — "writes to the device channels the Audio Output object maps":
/// which instance channel reaches which device channel, as pairs, so one
/// instance can feed every named output on the device at once (Area 16).
public struct AudioRouting: Equatable, Sendable {
    public struct Pair: Equatable, Sendable {
        public var source: Int
        public var target: Int

        public init(source: Int, target: Int) {
            self.source = source
            self.target = target
        }
    }

    public var pairs: [Pair]

    public init(pairs: [Pair]) {
        self.pairs = pairs
    }

    public static let none = AudioRouting(pairs: [])
}

/// Spec 4 §11 — one playing instance's sound: its ring, gain with the 50 ms
/// ramp, its envelope from the running audio transition, its routing to the
/// device's channels, and the clock reading it publishes.
public final class AudioInstance: @unchecked Sendable {
    public let handle: InstanceHandle
    public let ring: AudioRing
    public let inMs: Double
    /// Spec 4 §11 — "A pool item's syncOffsetMs ... delays audio when positive by holding samples in the ring".
    public let holdFrames: Int
    /// Spec 1 §3, Audio Output `channels`: the instance's channels onto the device's.
    public let routing: AudioRouting
    let gainTarget = Atomic<Float>(1)
    var gainCurrent: Float = 1
    var held = 0
    var envelope = Envelope.flat(1)
    let playing = Atomic<Bool>(true)
    /// Spec 4 §11 — set by the callback once the ring holds a preroll (or has
    /// ended); until then the instance is silent by design, counts no underrun
    /// and its clock holds at the in-point.
    let started = Atomic<Bool>(false)
    let delivered = Atomic<Int64>(0)
    let deliveredAtHostNs = Atomic<Int64>(0)
    let underrunCount = Atomic<Int64>(0)
    let active = Atomic<Bool>(false)

    public init(handle: InstanceHandle, ring: AudioRing, inMs: Double, syncOffsetMs: Int, routing: AudioRouting) {
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
        guard started.load(ordering: .acquiring) else { return inMs }
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
/// One graph per distinct device (Area 16): the graph's channel count is
/// fixed at construction, and its device can be swapped for a fallback or a
/// silence stand-in (Spec 4 §12) without touching the instances, their rings,
/// envelopes or the delay lines.
///
/// Real-time rules (Spec 4 §3): the callback walks a fixed table of instance
/// slots, reads rings and atomics, and allocates nothing. Instances are
/// installed into free slots on the control side before being marked active.
public final class AudioGraph: @unchecked Sendable {
    public static let maxInstances = 16
    /// Spec 4 §11 — the samples an instance's ring holds before it starts: 20 ms at 48 kHz.
    public static let prerollFrames = 960
    public static let gainRampFrames: Int64 = 2400     // 50 ms at 48 kHz
    public static let muteRampFrames: Int64 = 960      // 20 ms

    /// Spec 4 §13 — the device this graph stands for in the records: its UID,
    /// `default` for the system default, `sdi:N` for an embedded output.
    public let key: String
    /// Spec 1 §3 — the Audio Outputs on this device, in number order.
    public let outputs: [AudioOutput]
    /// The interleaved channel count of every device this graph runs on.
    public let channelCount: Int
    public let sampleRate: Double
    private let slots: UnsafeMutablePointer<AudioInstance?>
    private let lock = NSLock()
    private let log: EngineLog?
    private var activeDevice: any AudioDevice
    private var frameCounter: Int64 = 0
    private let framesRendered = Atomic<Int64>(0)
    private let totalUnderruns = Atomic<Int64>(0)
    private let scratch: UnsafeMutablePointer<Float>
    // Per output: delay line, mute and the hard silence of Spec 4 §12.
    private let delayLines: [DelayLine]
    private let muteTargets: [MuteTarget]
    private let silenceFlags: [SilenceFlag]
    private var muteCurrent: [Float]
    private let outputChannelMap: [[Int]]

    /// One output's mute target, written by the control side, read by the callback.
    final class MuteTarget: @unchecked Sendable {
        let value = Atomic<Float>(1)
    }

    /// Spec 4 §12 — an output silenced while its device is absent and the
    /// graph plays on another output's fallback: a hard zero, no ramp.
    final class SilenceFlag: @unchecked Sendable {
        let value = Atomic<Bool>(false)
    }

    public init(device: any AudioDevice, outputs: [AudioOutput], key: String = "", log: EngineLog? = nil) {
        activeDevice = device
        self.outputs = outputs.sorted { $0.number < $1.number }
        self.key = key
        self.log = log
        let channels = max(1, device.channelCount)
        let sorted = outputs.sorted { $0.number < $1.number }
        channelCount = channels
        sampleRate = device.sampleRate
        slots = UnsafeMutablePointer<AudioInstance?>.allocate(capacity: AudioGraph.maxInstances)
        slots.initialize(repeating: nil, count: AudioGraph.maxInstances)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: 8)
        scratch.initialize(repeating: 0, count: 8)
        delayLines = sorted.map { DelayLine(channels: channels, delayFrames: max(0, min(1000, $0.delayMs)) * 48) }
        muteTargets = sorted.map { _ in MuteTarget() }
        silenceFlags = sorted.map { _ in SilenceFlag() }
        muteCurrent = sorted.map { _ in 1 }
        outputChannelMap = sorted.map { output in output.channels.filter { $0 >= 0 && $0 < channels } }
    }

    deinit {
        slots.deinitialize(count: AudioGraph.maxInstances)
        slots.deallocate()
        scratch.deallocate()
    }

    /// The device the graph is running on now: its primary, a fallback or the
    /// silence stand-in (Spec 4 §12).
    public var device: any AudioDevice {
        lock.lock()
        defer { lock.unlock() }
        return activeDevice
    }

    public var outputNumbers: [Int] { outputs.map(\.number) }

    /// Start the current device with the graph's callback.
    public func start() throws {
        let device = self.device
        guard !device.isRunning else { return }
        try device.start { [self] output, frames, hostTime in render(output: output, frames: frames, hostTimeNs: hostTime) }
    }

    public func stop() {
        device.stop()
    }

    /// Spec 4 §12 — "Switch to the Audio Output's configured fallback device
    /// if one is set; otherwise drop that output's audio (silence ...); return
    /// when the device reappears": the graph moves to another device and
    /// keeps everything else. The old device is stopped before the new one
    /// starts, so the rings never have two consumers; every instance's clock
    /// stamp moves to the new device's time axis, so the clock continues from
    /// where it stood (the gap between the two is time the audience did not
    /// hear, and the picture held).
    public func swapDevice(to newDevice: any AudioDevice) throws {
        lock.lock()
        let old = activeDevice
        lock.unlock()
        if old === newDevice {
            if !newDevice.isRunning { try newDevice.start { [self] output, frames, hostTime in render(output: output, frames: frames, hostTimeNs: hostTime) } }
            return
        }
        old.stop()
        let now = newDevice.hostTimeNowNs
        lock.lock()
        for i in 0..<AudioGraph.maxInstances {
            slots[i]?.deliveredAtHostNs.store(now, ordering: .releasing)
        }
        lock.unlock()
        try newDevice.start { [self] output, frames, hostTime in render(output: output, frames: frames, hostTimeNs: hostTime) }
        lock.lock()
        activeDevice = newDevice
        lock.unlock()
    }

    // MARK: - Control side

    /// Spec 1 §2 — the channel's `audioOutputs` name the outputs an instance
    /// reaches; Spec 4 §11 — the mix is written "to the device channels the
    /// Audio Output object maps": every named output on this device, in
    /// output order, each instance channel onto the output's channel at the
    /// same index (a mono instance onto all of them). A channel index the
    /// device does not have is dropped, never folded onto another.
    public func routing(forAudioOutputs numbers: [Int], instanceChannels: Int) -> AudioRouting {
        var pairs: [AudioRouting.Pair] = []
        for output in outputs where numbers.contains(output.number) {
            let map = output.channels
            guard !map.isEmpty else { continue }
            let candidates: [AudioRouting.Pair]
            if instanceChannels <= 1 {
                candidates = map.map { AudioRouting.Pair(source: 0, target: $0) }
            } else {
                candidates = (0..<instanceChannels).map { AudioRouting.Pair(source: $0, target: map[$0 % map.count]) }
            }
            for pair in candidates where pair.target >= 0 && !pairs.contains(pair) {
                if pair.target >= channelCount {
                    log?.warning("audio output \(output.number): channel \(pair.target) is beyond the device's \(channelCount) channels; dropped")
                    continue
                }
                pairs.append(pair)
            }
        }
        return AudioRouting(pairs: pairs)
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

    /// Spec 4 §12 — an output whose device is absent and whose fallback is not
    /// the one this graph plays on is silent, at once and without a ramp.
    public func setSilenced(_ silenced: Bool, output number: Int) {
        for (i, output) in outputs.enumerated() where output.number == number {
            silenceFlags[i].value.store(silenced, ordering: .releasing)
        }
    }

    public var currentFrame: Int64 { framesRendered.load(ordering: .acquiring) }
    public var underruns: Int64 { totalUnderruns.load(ordering: .relaxed) }

    /// Spec 4 §2 — "A/V sync is anchored to the audio device clock": the
    /// instance's media time now, on the device's own clock.
    public func mediaTimeMs(of instance: AudioInstance) -> Double {
        instance.mediaTimeMs(nowNs: device.hostTimeNowNs)
    }

    // MARK: - The callback (Core Audio's real-time thread, or the paced device's)

    func render(output: UnsafeMutablePointer<Float>, frames: Int, hostTimeNs: Int64) {
        let channels = channelCount
        let frameNs = Int64(1_000_000_000 / sampleRate)
        for i in 0..<(frames * channels) { output[i] = 0 }
        // Mix every active instance into the device channels.
        for slot in 0..<AudioGraph.maxInstances {
            guard let instance = slots[slot], instance.active.load(ordering: .acquiring) else { continue }
            if !instance.started.load(ordering: .relaxed) {
                // Spec 4 §11 — "A/V sync is anchored to the audio device clock": the clock starts with the
                // first samples, and the first samples wait for a preroll so a decoder still filling the
                // ring is not an underrun. The spike's three-hour soak counted a device buffer or three
                // of silence at every instance start as underruns.
                guard instance.ring.framesAvailable >= AudioGraph.prerollFrames || instance.ring.isEnded else { continue }
                instance.deliveredAtHostNs.store(hostTimeNs, ordering: .releasing)
                instance.started.store(true, ordering: .releasing)
            }
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
                for pair in instance.routing.pairs {
                    guard pair.source < instance.ring.channels, pair.target < channels else { continue }
                    output[f * channels + pair.target] += scratch[pair.source] * level
                }
            }
            instance.gainCurrent = gain
            if deliveredNow > 0 {
                instance.delivered.add(deliveredNow, ordering: .relaxed)
                instance.deliveredAtHostNs.store(hostTimeNs + Int64(frames) * frameNs, ordering: .releasing)
            }
        }
        // Per output: delay, then mute, then the hard silence of a lost device.
        for (i, line) in delayLines.enumerated() {
            let channelsOfOutput = outputChannelMap[i]
            let target = muteTargets[i].value.load(ordering: .relaxed)
            let hard: Float = silenceFlags[i].value.load(ordering: .relaxed) ? 0 : 1
            var mute = muteCurrent[i]
            let step = (target - mute) / Float(AudioGraph.muteRampFrames)
            for f in 0..<frames {
                if mute != target {
                    mute += step
                    if (step > 0 && mute > target) || (step < 0 && mute < target) { mute = target }
                }
                for c in channelsOfOutput {
                    let index = f * channels + c
                    output[index] = line.process(output[index], channel: c) * mute * hard
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
