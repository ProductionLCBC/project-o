// OEngine — Spec 10 §3, the topics this spec defines: their events, and when they are sent.

import Foundation
import OCore

/// Spec 10 §3, "Topics" — the events of `channels`, `outputs`, `audio`,
/// `popups` and `commands`, each made from one snapshot of the engine's
/// values. The same functions make the events a build publishes and the
/// events the `state` query answers with, "as their topics would send them
/// now", so the two can't disagree.
enum ApiEvents {
    static func event(_ topic: String, _ fields: [String: JSONValue], seq: Int) -> JSONValue {
        var members = fields
        members["type"] = .string("event")
        members["topic"] = .string(topic)
        members["seq"] = .number(Double(seq))
        return .object(members)
    }

    // MARK: - channels

    /// What happened to a channel in one build and is said once: "once each,
    /// a transition that starts (picture and sound durations and the sound's
    /// offset), `steppedOn` and `blocked`".
    struct ChannelOnce: Equatable {
        var transition: TransitionEffect?
        var steppedOn = false
        var blocked = false

        var isEmpty: Bool { transition == nil && !steppedOn && !blocked }
    }

    /// Spec 10 §3 — "One event per channel: its content (kind, ref, label,
    /// missing, whether it has a picture and whether it has sound, and for
    /// timed media its duration, position, loop and end behavior; for text
    /// its fields), state as `/o/channel/N/state` reports it, provenance,
    /// lock, tracked attributes with their origins (Spec 3 §2)". "An empty
    /// channel has `content: null`."
    static func channel(_ number: Int, in snapshot: ApiSnapshot, seq: Int, once: ChannelOnce = ChannelOnce()) -> JSONValue {
        let channel = snapshot.state.channels[number]
        let content = channel?.content ?? .empty
        var fields: [String: JSONValue] = [
            "channel": .number(Double(number)),
            "state": .string(OSCFeedbackDeriver.feedbackState(of: content).rawValue),
            "lock": .bool(channel?.lock ?? false),
            "content": self.content(content, timing: snapshot.timings[number], in: snapshot),
            "provenance": channel.flatMap { try? JSONCoding.encode($0.provenance) } ?? .null,
            "attributes": attributes(channel),
        ]
        if let transition = once.transition {
            fields["transition"] = .object(["ms": .number(Double(transition.ms)), "audioMs": .number(Double(transition.audioMs)),
                                            "audioOffsetMs": .number(Double(transition.audioOffsetMs))])
        }
        if once.steppedOn { fields["steppedOn"] = .bool(true) }
        if once.blocked { fields["blocked"] = .bool(true) }
        return event("channels", fields, seq: seq)
    }

    static func content(_ content: ContentInstance, timing: MediaTiming?, in snapshot: ApiSnapshot) -> JSONValue {
        let label = JSONValue.string(OSCFeedbackDeriver.label(of: content, library: snapshot.library, machine: snapshot.machine))
        switch content {
        case .empty:
            return .null
        case .text(let text):
            return .object(["kind": .string("text"), "label": label, "fields": .object(text.fields.mapValues(JSONValue.string))])
        case .media(let media):
            let entry = MediaResolver.resolve(media.ref, library: snapshot.library, machine: snapshot.machine)?.entry
            var fields: [String: JSONValue] = [
                "kind": .string("media"), "ref": .string(media.ref), "label": label, "missing": .bool(media.missing),
                "hasPicture": .bool(entry.map { $0.kind == .video || $0.kind == .image } ?? false),
                "hasAudio": .bool(entry?.hasAudio ?? false),
                "loop": .bool(media.loop), "endBehavior": .string(media.endBehavior.rawValue),
            ]
            // "Timed media's duration and position count within its in and out points".
            if let timing {
                fields["durationMs"] = .number(Double(timing.durationMs))
                fields["positionMs"] = .number(Double(timing.positionMs))
            }
            return .object(fields)
        case .slide(let slide):
            return .object(["kind": .string("slide"), "ref": .string(slide.ref), "label": label, "hasPicture": .bool(true), "hasAudio": .bool(false)])
        case .input(let input):
            return .object(["kind": .string("input"), "input": .number(Double(input.input)), "label": label, "hasPicture": .bool(true), "hasAudio": .bool(false)])
        }
    }

    /// "tracked attributes with their origins": each attribute's value and
    /// where it came from, without the value it shadows.
    static func attributes(_ channel: ChannelState?) -> JSONValue {
        guard let channel, case .object(var members)? = try? JSONCoding.encode(channel.attributes) else { return .object([:]) }
        for (name, value) in members {
            guard case .object(var tracked) = value else { continue }
            tracked["shadow"] = nil
            members[name] = .object(tracked)
        }
        return .object(members)
    }

    // MARK: - outputs

    /// Spec 10 §3 — "Per output: its live stack, its state (`presenting`,
    /// `paused` while its screen or card is gone, `released`, or `absent`
    /// when its device isn't there) and, for SDI, its reference (`locked`,
    /// `freeRun` or `none`)."
    static func output(_ output: Output, in snapshot: ApiSnapshot, seq: Int) -> JSONValue {
        event("outputs", [
            "output": .number(Double(output.number)),
            "stack": .number(Double(snapshot.state.outputs[output.number] ?? output.defaultStack)),
            "state": .string((snapshot.standings[output.number] ?? .absent).rawValue),
            "reference": snapshot.references[output.number].map(JSONValue.string) ?? .null,
        ], seq: seq)
    }

    /// Spec 10 §3 — "Per stack: blackout and muted channels".
    static func stack(_ stack: Stack, in snapshot: ApiSnapshot, seq: Int) -> JSONValue {
        let state = snapshot.state.stacks[stack.number]
        return event("outputs", [
            "stack": .number(Double(stack.number)),
            "blackout": .bool(state?.blackout ?? false),
            "muted": .array((state?.muted ?? []).sorted().map { .number(Double($0)) }),
        ], seq: seq)
    }

    // MARK: - audio

    /// Spec 10 §3 — "Per audio output: `ok`, `fallback` or `silent` (Spec 4
    /// §12), and muted".
    static func audio(_ output: AudioOutput, in snapshot: ApiSnapshot, seq: Int) -> JSONValue {
        event("audio", [
            "audioOutput": .number(Double(output.number)),
            "state": .string(snapshot.audioStandings[output.number] ?? "silent"),
            "muted": .bool(snapshot.mutedAudio.contains(output.number)),
        ], seq: seq)
    }

    // MARK: - popups

    /// Spec 10 §3 — "Per slot: its text, and the milliseconds left on a
    /// pending clear-after"; `clearInMs` is null when nothing is counting,
    /// and, like a trigger's `inMs` (Spec 7 §6), is measured when the event
    /// is made.
    static func popup(_ slot: Int, in snapshot: ApiSnapshot, seq: Int) -> JSONValue {
        event("popups", [
            "popup": .number(Double(slot)),
            "text": .string(snapshot.state.popups[slot] ?? ""),
            "clearInMs": snapshot.pendingClears[slot].map { .number(Double(snapshot.milliseconds(until: $0))) } ?? .null,
        ], seq: seq)
    }

    // MARK: - Everything, now

    /// Spec 10 §3, the `state` query — "the `live`, `channels`, `popups`,
    /// `outputs` and `audio` events as their topics would send them now".
    static func all(in snapshot: ApiSnapshot) -> [JSONValue] {
        var events = [snapshot.liveEvent]
        let channels = Set(snapshot.library.channels.map(\.number)).union(snapshot.state.channels.keys)
        events += channels.sorted().map { channel($0, in: snapshot, seq: snapshot.seq) }
        events += (1...max(1, snapshot.popupSlots)).filter { $0 <= snapshot.popupSlots }.map { popup($0, in: snapshot, seq: snapshot.seq) }
        events += snapshot.machine.outputs.sorted { $0.number < $1.number }.map { output($0, in: snapshot, seq: snapshot.seq) }
        events += snapshot.machine.stacks.sorted { $0.number < $1.number }.map { stack($0, in: snapshot, seq: snapshot.seq) }
        events += snapshot.machine.audioOutputs.sorted { $0.number < $1.number }.map { audio($0, in: snapshot, seq: snapshot.seq) }
        return events
    }

    /// Spec 6 §8 — the `timers` events, one per slot, as their topic would send them now.
    static func timers(in snapshot: ApiSnapshot) -> [JSONValue] {
        (1...max(1, snapshot.timerSlots)).filter { $0 <= snapshot.timerSlots }.map { (snapshot.timers[$0] ?? .unset).event(timer: $0, seq: snapshot.seq) }
    }
}

/// Spec 10 §3 — when the topics' events are sent: `channels` "On every
/// change, and once a second while timed media plays"; `outputs`, `audio`
/// and `popups` "On change"; `commands` as each command runs (Spec 2 §9).
///
/// It belongs to the control side and is called once a build. It remembers
/// what each event last said and publishes the ones that would say something
/// else. The first build only remembers: a client that has just connected
/// asks `state` for where things stand.
final class ApiTopics {
    /// Everything a channel's event says, but for where its media stands.
    private struct ChannelKey: Equatable {
        var state: ChannelState?
        var label: String
        var picture: Bool
        var sound: Bool
        var durationMs: Int?
        var playing: Bool
    }

    private var primed = false
    private var channels: [Int: ChannelKey] = [:]
    private var channelSeconds: [Int: Int] = [:]
    private var outputs: [Int: [String]] = [:]
    private var stacks: [Int: StackState] = [:]
    private var audio: [Int: [String]] = [:]
    private var popups: [Int: String] = [:]

    /// One build's events, in a fixed order: `commands`, then `channels`,
    /// `popups`, `outputs` and `audio`.
    func publish(_ snapshot: ApiSnapshot, control: ControlLoop, to publisher: EnginePublisher) {
        // Spec 2 §9 — "The `commands` topic streams every executed command object with its sequence number".
        let stamp = control.variables.timestamp()
        for line in control.lastResults.flatMap(\.lines) {
            guard case .object(var members)? = try? JSONCoding.encode(LogEntry(line.executed, seq: line.seq, ts: stamp)) else { continue }
            members["type"] = .string("event")
            members["topic"] = .string("commands")
            publisher.publish(.object(members))
        }

        // What this build did to each channel, said once, and the line that did it.
        var once: [Int: ApiEvents.ChannelOnce] = [:]
        var seqs: [Int: Int] = [:]
        for line in control.lastResults.flatMap(\.lines) {
            for effect in line.executed.effects {
                switch effect {
                case .transition(var transition):
                    // Spec 10 §3 as corrected 2026-11-25 — "for content a box draws, as text is, the picture's duration
                    // is that of the longest box transition the change started".
                    if case .text = transition.to { transition.ms = control.boxTransitionsStarted[transition.channel] ?? 0 }
                    once[transition.channel, default: ApiEvents.ChannelOnce()].transition = transition
                    seqs[transition.channel] = line.seq
                case .steppedOn(let channel, _):
                    once[channel, default: ApiEvents.ChannelOnce()].steppedOn = true
                    seqs[channel] = line.seq
                case .blocked(let channel, _):
                    once[channel, default: ApiEvents.ChannelOnce()].blocked = true
                    seqs[channel] = line.seq
                case .attribute(let channel, _, _, _, _):
                    seqs[channel] = line.seq
                default:
                    break
                }
            }
        }

        let numbers = Set(snapshot.library.channels.map(\.number)).union(snapshot.state.channels.keys)
        for number in numbers.sorted() {
            let timing = snapshot.timings[number]
            let state = snapshot.state.channels[number]
            let content = state?.content ?? .empty
            // The label and what the media holds come from the library, which an edit can change under a channel on air.
            let entry = content.media.flatMap { MediaResolver.resolve($0.ref, library: snapshot.library, machine: snapshot.machine)?.entry }
            let key = ChannelKey(state: state, label: OSCFeedbackDeriver.label(of: content, library: snapshot.library, machine: snapshot.machine),
                                 picture: entry.map { $0.kind == .video || $0.kind == .image } ?? false, sound: entry?.hasAudio ?? false,
                                 durationMs: timing?.durationMs, playing: timing?.playing ?? false)
            // "once a second while timed media plays": when the whole second its position is in changes.
            let second = timing.flatMap { $0.playing ? $0.positionMs / 1000 : nil }
            let said = once[number] ?? ApiEvents.ChannelOnce()
            let changed = channels[number] != key || (second != nil && channelSeconds[number] != second) || !said.isEmpty
            channels[number] = key
            channelSeconds[number] = second
            if primed, changed { publisher.publish(ApiEvents.channel(number, in: snapshot, seq: seqs[number] ?? snapshot.seq, once: said)) }
        }
        channels = channels.filter { numbers.contains($0.key) }
        channelSeconds = channelSeconds.filter { numbers.contains($0.key) }

        for slot in 1...max(1, snapshot.popupSlots) where slot <= snapshot.popupSlots {
            let key = "\(snapshot.state.popups[slot] ?? "")\u{0}\(snapshot.pendingClears[slot].map(String.init) ?? "")"
            if popups[slot] != key {
                popups[slot] = key
                if primed { publisher.publish(ApiEvents.popup(slot, in: snapshot, seq: snapshot.seq)) }
            }
        }

        for output in snapshot.machine.outputs.sorted(by: { $0.number < $1.number }) {
            let key = ["\(snapshot.state.outputs[output.number] ?? output.defaultStack)", (snapshot.standings[output.number] ?? .absent).rawValue,
                       snapshot.references[output.number] ?? ""]
            if outputs[output.number] != key {
                outputs[output.number] = key
                if primed { publisher.publish(ApiEvents.output(output, in: snapshot, seq: snapshot.seq)) }
            }
        }
        for stack in snapshot.machine.stacks.sorted(by: { $0.number < $1.number }) {
            let key = snapshot.state.stacks[stack.number] ?? StackState()
            if stacks[stack.number] != key {
                stacks[stack.number] = key
                if primed { publisher.publish(ApiEvents.stack(stack, in: snapshot, seq: snapshot.seq)) }
            }
        }
        for output in snapshot.machine.audioOutputs.sorted(by: { $0.number < $1.number }) {
            let key = [snapshot.audioStandings[output.number] ?? "silent", snapshot.mutedAudio.contains(output.number) ? "muted" : ""]
            if audio[output.number] != key {
                audio[output.number] = key
                if primed { publisher.publish(ApiEvents.audio(output, in: snapshot, seq: snapshot.seq)) }
            }
        }
        primed = true
    }
}
