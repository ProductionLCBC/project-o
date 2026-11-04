// OEngine — Spec 4 §11, one mix graph per audio output device, and Spec 4
// §12, the audio row: the audio system that owns the graphs (Area 16).

import Foundation
import OCore

/// Spec 4 §11 — one media instance's sound across the devices its channel's
/// outputs reach: one `AudioInstance` per graph, each on its own ring, in
/// output-number order. "When a channel is routed to more than one device,
/// the first-numbered device is the clock" (Area 16 reading, approved
/// 2026-11-03: the device of the lowest-numbered Audio Output the channel
/// names), so the first member is the clock.
public final class AudioAttachment: @unchecked Sendable {
    public struct Member: Sendable {
        public let graph: AudioGraph
        public let instance: AudioInstance
    }

    public let handle: InstanceHandle
    public let members: [Member]

    init(handle: InstanceHandle, members: [Member]) {
        self.handle = handle
        self.members = members
    }

    public var clock: Member? { members.first }

    func instance(on graph: AudioGraph) -> AudioInstance? {
        members.first { $0.graph === graph }?.instance
    }
}

/// Spec 4 §11 — "One Core Audio output unit (the HAL output AudioUnit) per
/// distinct device, each with its own render callback"; "SDI embedded audio
/// is an Audio Output whose device is a DeckLink output. Its mix is produced
/// by the same graph on a timer thread". The system builds one graph per
/// distinct device among the machine's Audio Outputs (Spec 1 §3) and one per
/// SDI-embedded output, and is the one face the control loop uses: attach an
/// instance to the outputs its channel names, gain, transport, transitions,
/// mute by output, and the media time from the clock device.
///
/// Spec 4 §12 — "Audio device vanishes: Switch to the Audio Output's
/// configured fallback device if one is set; otherwise drop that output's
/// audio (silence, with a badge) rather than guessing; return when the device
/// reappears." A graph whose device is absent swaps to the fallback of its
/// lowest-numbered output that has one, silencing the outputs on it whose
/// fallback differs; with no fallback present it runs on a silence stand-in
/// that keeps consuming, so the clock and the picture go on. A device absent
/// at launch gets the same rule. The badge is `deviceStates`, carried by the
/// metrics snapshot (Spec 4 §13).
public final class AudioSystem: @unchecked Sendable {
    /// One graph and its standing.
    final class Slot {
        enum Kind {
            case device
            case embedded(sdi: Int)
        }

        let key: String
        let kind: Kind
        let outputs: [AudioOutput]
        let channelCount: Int
        let graph: AudioGraph
        /// The paced feed of an embedded output: its primary device.
        let feed: PacedAudioDevice?
        var standing: AudioDeviceStanding = .silent
        var standIn: String?

        init(key: String, kind: Kind, outputs: [AudioOutput], channelCount: Int, graph: AudioGraph, feed: PacedAudioDevice?) {
            self.key = key
            self.kind = kind
            self.outputs = outputs
            self.channelCount = channelCount
            self.graph = graph
            self.feed = feed
        }

        /// Spec 4 §12 — the fallback the graph follows: the lowest-numbered output's.
        var fallbackKey: String? { outputs.first { $0.fallbackDevice != nil }?.fallbackDevice }
    }

    public let outputs: [AudioOutput]
    public let graphs: [AudioGraph]
    private let slots: [Slot]
    private let factory: any AudioDeviceFactory
    private let destinations: [Int: any StreamAudioDestination]
    private let log: EngineLog
    private let lock = NSLock()
    private var started = false
    private var notedChannels: Set<Int> = []
    /// Spec 4 §12 and §13 — a loss while running is a recovery the soak counts.
    public var onRecovery: (@Sendable (WatchdogRecovery) -> Void)?

    /// `destinations` are the DeckLink sinks by SDI output number, for the
    /// `sdiEmbedded` outputs (Spec 1 §3: `device` is "the SDI output number").
    public init(outputs: [AudioOutput], factory: any AudioDeviceFactory, destinations: [Int: any StreamAudioDestination] = [:], log: EngineLog) {
        self.outputs = outputs.sorted { $0.number < $1.number }
        self.factory = factory
        self.destinations = destinations
        self.log = log
        var slots: [Slot] = []
        var byKey: [String: [AudioOutput]] = [:]
        var order: [String] = []
        for output in self.outputs {
            if case .uid = output.device, output.kind == .sdiEmbedded {
                log.warning("audio output \(output.number) is sdiEmbedded but names a Core Audio device; treated as a device output")
            }
            if case .sdiOutput = output.device, output.kind == .device {
                log.warning("audio output \(output.number) is a device output but names an SDI output; treated as embedded")
            }
            let key = AudioDeviceKey.key(for: output)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(output)
        }
        for key in order {
            let group = byKey[key] ?? []
            let indices = group.flatMap(\.channels)
            if case .sdiOutput(let number)? = group.first?.device {
                // Spec 4 §10 — the card takes 2, 8 or 16 embedded channels.
                let channelCount = DeckLinkSink.embeddedChannelCount(for: indices)
                let destination = destinations[number]
                if destination == nil { log.warning("audio output \(group.map(\.number).map(String.init).joined(separator: ", ")): no SDI output \(number) on this machine; embedded audio goes nowhere") }
                let feed = PacedAudioDevice(name: key, channelCount: channelCount, destination: destination, threaded: true, log: log)
                let graph = AudioGraph(device: feed, outputs: group, key: key, log: log)
                slots.append(Slot(key: key, kind: .embedded(sdi: number), outputs: group, channelCount: channelCount, graph: graph, feed: feed))
            } else {
                let channelCount = max(2, (indices.max() ?? 1) + 1)
                let graph = AudioGraph(device: factory.makeSilenceDevice(name: key, channelCount: channelCount), outputs: group, key: key, log: log)
                slots.append(Slot(key: key, kind: .device, outputs: group, channelCount: channelCount, graph: graph, feed: nil))
            }
        }
        self.slots = slots
        graphs = slots.map(\.graph)
    }

    /// The first graph's device, for the harness and the process summary.
    public var device: (any AudioDevice)? { graphs.first?.device }

    public func graph(forOutput number: Int) -> AudioGraph? {
        slots.first { $0.outputs.contains { $0.number == number } }?.graph
    }

    // MARK: - Lifecycle

    /// Spec 4 §11 — open every device; Spec 4 §12 — a device absent at launch
    /// gets its fallback or silence, never a guess; then watch the device list.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true
        for slot in slots { settle(slot, atStartup: true) }
        factory.observeDeviceList { [weak self] in self?.recheckDevices() }
        for (_, destination) in destinations {
            destination.observeStream { [weak self] in self?.recheckDevices() }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        started = false
        factory.stopObserving()
        for slot in slots { slot.graph.stop() }
    }

    /// Spec 4 §12 — "Core Audio device notification": every graph checks its
    /// device and moves per the rule. Called by the factory's listener, by a
    /// card starting or stopping, and by the tests after they mark a device
    /// absent or back.
    public func recheckDevices() {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return }
        for slot in slots { settle(slot, atStartup: false) }
    }

    private func isPrimaryPresent(_ slot: Slot) -> Bool {
        switch slot.kind {
        case .device: return factory.isPresent(key: slot.key)
        case .embedded(let sdi): return destinations[sdi]?.streamTimeNowNs != nil
        }
    }

    private func primaryDevice(for slot: Slot) -> (any AudioDevice)? {
        switch slot.kind {
        case .device: return factory.makeDevice(key: slot.key, channelCount: slot.channelCount)
        case .embedded: return slot.feed
        }
    }

    /// Spec 4 §12 — the rule, in order: the primary when present, else the
    /// fallback when configured and present, else silence. Every change logs
    /// one line per output; a loss while running is a recovery.
    private func settle(_ slot: Slot, atStartup: Bool) {
        let previous = slot.standing
        let numbers = slot.outputs.map(\.number)
        if isPrimaryPresent(slot) {
            if previous == .primary, slot.graph.device.isRunning { return }
            if let device = primaryDevice(for: slot) {
                do {
                    try slot.graph.swapDevice(to: device)
                    slot.standing = .primary
                    slot.standIn = nil
                    for number in numbers {
                        slot.graph.setSilenced(false, output: number)
                        if !atStartup { log.info("audio output \(number): device \(slot.key) back") }
                    }
                    return
                } catch {
                    log.error("audio output \(numbers.map(String.init).joined(separator: ", ")): device \(slot.key) refused to start (\(error)); treating it as absent")
                }
            }
        }
        let wording = previous == .primary && !atStartup ? "lost" : "absent"
        if let fallback = slot.fallbackKey, factory.isPresent(key: fallback) {
            if previous == .fallback, slot.standIn == fallback, slot.graph.device.isRunning { return }
            if let device = factory.makeDevice(key: fallback, channelCount: slot.channelCount) {
                do {
                    try slot.graph.swapDevice(to: device)
                    for output in slot.outputs {
                        if output.fallbackDevice == fallback {
                            slot.graph.setSilenced(false, output: output.number)
                            log.warning("audio output \(output.number): device \(slot.key) \(wording); on fallback \(fallback)")
                        } else {
                            slot.graph.setSilenced(true, output: output.number)
                            log.warning("audio output \(output.number): device \(slot.key) \(wording); silent until it returns")
                        }
                    }
                    slot.standing = .fallback
                    slot.standIn = fallback
                    if previous == .primary, !atStartup { onRecovery?(.audioDeviceLost(slot.key)) }
                    return
                } catch {
                    log.error("audio output \(numbers.map(String.init).joined(separator: ", ")): fallback device \(fallback) refused to start (\(error))")
                }
            }
        }
        if previous == .silent, slot.graph.device.isRunning { return }
        for number in numbers {
            slot.graph.setSilenced(false, output: number)
            if previous == .fallback, let standIn = slot.standIn {
                log.warning("audio output \(number): fallback device \(standIn) lost; silent until a device returns")
            } else {
                log.warning("audio output \(number): device \(slot.key) \(wording); silent until it returns")
            }
        }
        let lostKey = previous == .fallback ? (slot.standIn ?? slot.key) : slot.key
        let standIn: any AudioDevice = slot.feed ?? factory.makeSilenceDevice(name: slot.key, channelCount: slot.channelCount)
        do {
            try slot.graph.swapDevice(to: standIn)
        } catch {
            log.error("audio output \(numbers.map(String.init).joined(separator: ", ")): the silence stand-in did not start (\(error))")
        }
        slot.standing = .silent
        slot.standIn = nil
        if previous != .silent, !atStartup { onRecovery?(.audioDeviceLost(lostKey)) }
    }

    // MARK: - Attachments (the control thread)

    /// The slots a channel's outputs reach, ordered by the lowest named output on each.
    private func slotsReached(by numbers: [Int]) -> [Slot] {
        var reached: [(slot: Slot, lowest: Int)] = []
        for slot in slots {
            let named = slot.outputs.map(\.number).filter { numbers.contains($0) }
            if let lowest = named.min() { reached.append((slot, lowest)) }
        }
        return reached.sorted { $0.lowest < $1.lowest }.map(\.slot)
    }

    /// How many rings an instance routed to `numbers` needs: one per device reached.
    public func ringCount(forOutputs numbers: [Int]) -> Int {
        slotsReached(by: numbers).count
    }

    /// Spec 4 §11 — "routes it to the numbered audio outputs the channel
    /// names": one instance per device reached, each on its own ring, the
    /// lowest-numbered output's device first as the clock. Nil when no named
    /// output exists on this machine or a graph is full.
    public func attach(handle: InstanceHandle, rings: [AudioRing], outputs numbers: [Int], inMs: Double, syncOffsetMs: Int, gainDb: Double,
                       playing: Bool, channel: Int) -> AudioAttachment? {
        let reached = slotsReached(by: numbers)
        guard !reached.isEmpty else { return nil }
        guard rings.count >= reached.count else {
            log.error("audio: channel \(channel) reaches \(reached.count) devices but has \(rings.count) rings")
            return nil
        }
        var members: [AudioAttachment.Member] = []
        for (i, slot) in reached.enumerated() {
            let ring = rings[i]
            let instance = AudioInstance(handle: handle, ring: ring, inMs: inMs, syncOffsetMs: syncOffsetMs,
                                         routing: slot.graph.routing(forAudioOutputs: numbers, instanceChannels: ring.channels))
            guard slot.graph.add(instance, gainDb: gainDb) else {
                for member in members { member.graph.remove(member.instance) }
                return nil
            }
            slot.graph.setPlaying(playing, for: instance)
            members.append(AudioAttachment.Member(graph: slot.graph, instance: instance))
        }
        if reached.count > 1 {
            lock.lock()
            let first = notedChannels.insert(channel).inserted
            lock.unlock()
            if first, let clock = reached.first {
                // Spec 4 §11 — "pre-flight notes multi-device routing for that reason": the note, until pre-flight exists.
                log.info("channel \(channel) routes to audio outputs on more than one device; device \(clock.key) (output \(clock.outputs.map(\.number).filter { numbers.contains($0) }.min() ?? 0)) is its clock and the others may drift")
            }
        }
        return AudioAttachment(handle: handle, members: members)
    }

    public func detach(_ attachment: AudioAttachment) {
        for member in attachment.members { member.graph.remove(member.instance) }
    }

    /// Spec 4 §11 — "per-instance gain ... with a 50 ms ramp on change", on every device.
    public func setGain(_ db: Double, for attachment: AudioAttachment) {
        for member in attachment.members { member.graph.setGain(db, for: member.instance) }
    }

    public func setPlaying(_ playing: Bool, for attachment: AudioAttachment) {
        for member in attachment.members { member.graph.setPlaying(playing, for: member.instance) }
    }

    /// Spec 4 §11 — the audio transition between a channel's outgoing and
    /// incoming instance, on every device either reaches.
    public func startTransition(outgoing: AudioAttachment?, incoming: AudioAttachment?, type: AudioTransitionType, ms: Int, offsetMs: Int) {
        var graphs: [AudioGraph] = []
        for member in (outgoing?.members ?? []) + (incoming?.members ?? []) where !graphs.contains(where: { $0 === member.graph }) {
            graphs.append(member.graph)
        }
        for graph in graphs {
            graph.startTransition(outgoing: outgoing?.instance(on: graph), incoming: incoming?.instance(on: graph), type: type, ms: ms, offsetMs: offsetMs)
        }
    }

    /// Spec 4 §11 — "Mute of an audio output zeroes that device's mix with a 20 ms ramp".
    public func setMuted(_ muted: Bool, output number: Int) {
        graph(forOutput: number)?.setMuted(muted, output: number)
    }

    /// Spec 4 §2 and §11 — the instance's media time on its clock device.
    public func mediaTimeMs(of attachment: AudioAttachment) -> Double {
        guard let clock = attachment.clock else { return 0 }
        return clock.graph.mediaTimeMs(of: clock.instance)
    }

    // MARK: - Measurement (Spec 4 §13)

    public var underruns: Int64 { graphs.reduce(0) { $0 + $1.underruns } }

    /// "audio underruns per device", keyed by the graph's primary device.
    public var underrunsByDevice: [String: Int64] {
        var out: [String: Int64] = [:]
        for graph in graphs { out[graph.key] = graph.underruns }
        return out
    }

    /// Spec 4 §12 — the badge: each device's standing, its outputs and its underruns.
    public var deviceStates: [AudioDeviceSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return slots.map {
            AudioDeviceSnapshot(device: $0.key, outputs: $0.outputs.map(\.number), standing: $0.standing, standIn: $0.standIn, underruns: Int($0.graph.underruns))
        }
    }
}
