// OApp — Spec 10 §15, what VoiceOver is told as the show moves: the live cue with its source, a trigger arming, an output that stops, a write blocked or stepped on.

import Foundation
import OCore

/// Something to say aloud (Spec 10 §15, "VoiceOver").
public enum Announcement: Equatable, Sendable {
    /// "Every change of the live cue is announced, with its source when it
    /// wasn't the app ("Auto: Chorus b", "From OSC: Verse 2")". `source` is
    /// the engine's word for where the fire came from, nil when it isn't known.
    case live(number: Int, label: String, source: String?)
    /// "a trigger arming ("Auto in 8 seconds")".
    case armed(seconds: Int)
    /// "an output that stops presenting".
    case outputStopped(OutputDot)
    /// "a write a lock blocked".
    case blocked(channel: Int)
    /// "or that stepped on a transition".
    case steppedOn(channel: Int)
}

/// Spec 10 §15 — works out what to announce from what the engine reports.
/// The `live` event carries no source, so the source is the one of the
/// command that moved the pointer, which the `commands` topic sends ahead of
/// the `live` event of the same tick (Area 13 reading, with the engine's
/// fixed order of events).
public struct LiveAnnouncer: Equatable, Sendable {
    /// The commands that move the pointer (Spec 2 §3).
    static let pointerCommands: Set<String> = ["playlist.next", "playlist.previous", "playlist.goto", "playlist.cue", "playlist.section", "playlist.load", "list.goto"]

    private var seeded = false
    private var cue: String?
    private var armed: String?
    private var source: String?
    private var presenting: Set<Int> = []
    private var outputsSeeded = false

    public init() {}

    /// A connection began or ended: what is live then is where things
    /// stand, not a change, so the next `live` and outputs say nothing.
    public mutating func reset() {
        self = LiveAnnouncer()
    }

    /// An executed command, from the `commands` topic.
    public mutating func command(_ event: [String: JSONValue]) {
        guard let cmd = event.members("command")?.text("cmd"), Self.pointerCommands.contains(cmd) else { return }
        source = event.members("source")?.text("kind")
    }

    /// A `live` event arrived.
    public mutating func live(_ live: LiveStatus) -> [Announcement] {
        defer {
            seeded = true
            cue = live.cue
            armed = live.armed?.cue
            source = nil
        }
        guard seeded else { return [] }
        var out: [Announcement] = []
        if let now = live.cue, now != cue || source != nil {
            // A refire of the same cue is a fire too, when a command made it.
            out.append(.live(number: live.cuePosition, label: live.label, source: source))
        }
        if let trigger = live.armed, trigger.cue != armed {
            out.append(.armed(seconds: Int((Double(trigger.inMs) / 1000).rounded())))
        }
        return out
    }

    /// The outputs as the top bar shows them.
    public mutating func outputs(_ dots: [OutputDot]) -> [Announcement] {
        let now = Set(dots.filter { $0.state == .presenting }.map(\.number))
        defer {
            presenting = now
            outputsSeeded = true
        }
        guard outputsSeeded else { return [] }
        return dots.filter { presenting.contains($0.number) && !now.contains($0.number) }.map(Announcement.outputStopped)
    }

    /// Something a channel reports once.
    public func channel(_ moment: ChannelMoment) -> [Announcement] {
        var out: [Announcement] = []
        if moment.blocked { out.append(.blocked(channel: moment.channel)) }
        if moment.steppedOn { out.append(.steppedOn(channel: moment.channel)) }
        return out
    }
}

/// The announcements' words, from the catalog.
@MainActor
public enum AnnounceWording {
    public static func text(_ announcement: Announcement) -> String {
        switch announcement {
        case .live(let number, let label, let source):
            let cue = label.isEmpty ? Strings.text(.gridCueUnlabelled, number) : label
            switch source {
            // The app's own: the cue, and no more.
            case nil, "ui"?, "key"?, "commandbar"?: return cue
            // An armed trigger fires as the engine's own `next` (Spec 7 §6); a cue or the timeline holding one is automatic too.
            case "scheduler"?, "cue"?, "timeline"?, "engine"?: return Strings.text(.announceAuto, cue)
            case "osc"?: return Strings.text(.announceOsc, cue)
            case "api"?: return Strings.text(.announceApi, cue)
            case "midi"?: return Strings.text(.announceMidi, cue)
            case "streamdeck"?: return Strings.text(.announceStreamDeck, cue)
            case "macro"?, "startup"?, "shutdown"?: return Strings.text(.announceMacro, cue)
            case "restore"?: return Strings.text(.announceRestore, cue)
            default: return Strings.text(.announceElsewhere, cue)
            }
        case .armed(let seconds): return Strings.counted(.announceArmed, seconds)
        case .outputStopped(let dot): return Strings.text(.announceOutput, ShowWording.output(dot))
        case .blocked(let channel): return Strings.text(.announceBlocked, channel)
        case .steppedOn(let channel): return Strings.text(.announceSteppedOn, channel)
        }
    }
}
