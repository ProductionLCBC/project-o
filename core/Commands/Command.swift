// OCore — Spec 2 §3, the v1 vocabulary as command objects (Spec 1 §6).

/// Spec 2 §3 — "`N` is a channel number or the word `all`." Also used for
/// `audio N mute` / `audio all`. Encoded as the number or the string `"all"`.
public enum Target: Codable, Equatable, Sendable {
    case number(Int)
    case all

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n); return }
        let s = try c.decode(String.self)
        guard s.lowercased() == "all" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "target must be a number or \"all\"")
        }
        self = .all
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .all: try c.encode("all")
        }
    }
}

/// Spec 2 §3 — `on`, `off`, `toggle` for blackout, mute and freeze.
public enum SwitchState: String, Codable, Equatable, Sendable {
    case on, off, toggle
}

/// Spec 2 §3 — `channel N play`, `pause`, `stop` (`channel.transport`).
public enum TransportMode: String, Codable, Equatable, Sendable {
    case play, pause, stop
}

/// Spec 2 §3 — `channel N skip`, `back` (`channel.track`, audio sets, v1.5).
public enum TrackDirection: String, Codable, Equatable, Sendable {
    case skip, back
}

/// Spec 2 §3 — `channel N write CONTENT [riders]` (`channel.write`).
public struct ChannelWrite: Equatable, Sendable {
    public var channel: Target
    public var content: ContentExpression
    public var riders: Riders

    public init(channel: Target, content: ContentExpression, riders: Riders = .none) {
        self.channel = channel
        self.content = content
        self.riders = riders
    }
}

/// Spec 2 §3 — "Edit commands share the shape `edit TARGET N FIELD VALUE`";
/// reserved here so the object form already accommodates them.
public struct EditCommand: Codable, Equatable, Sendable {
    public var target: String
    public var number: Int
    public var field: String
    public var value: JSONValue?

    public init(target: String, number: Int, field: String, value: JSONValue? = nil) {
        self.target = target
        self.number = number
        self.field = field
        self.value = value
    }
}

/// Spec 2 §3 and Spec 3 §10 — `Command`: the Spec 2 objects. One case per
/// row of the vocabulary table, encoded in the Spec 1 §6 object form with
/// `cmd` as `target.verb`. An unknown `cmd` decodes to `.unknown` rather than
/// failing, so a loader keeps it and the projection answers `noop`.
public enum Command: Codable, Equatable, Sendable {
    // Channels
    case channelWrite(ChannelWrite)
    case channelClear(channel: Target)
    case channelReset(channel: Target)
    case channelTransition(channel: Target, ref: Int, ms: Int?)
    case channelAudioTransition(channel: Target, ref: Int, ms: Int?)
    case channelGrade(channel: Target, ref: Int, ms: Int?)
    case channelGain(channel: Target, db: Double)
    case channelTransport(channel: Target, mode: TransportMode)
    case channelEndBehavior(channel: Target, mode: EndBehavior)
    case channelLock(channel: Target, locked: Bool)
    case channelFreeze(channel: Target, state: SwitchState)
    case channelTrack(channel: Target, direction: TrackDirection)
    case channelBuild(channel: Target, build: Int)
    // Stacks and outputs
    case outputStack(output: Int, stack: Int)
    case stackBlackout(stack: Int, state: SwitchState)
    case stackMute(stack: Int, channel: Int, state: SwitchState)
    // Playlist and library navigation
    case next
    case previous
    case cue(Int)
    case itemCue(item: Int, cue: Int)
    case itemSection(item: Int, section: String)
    case listCue(list: Int, cue: Int)
    case playlistLoad(title: String, date: String?)
    // Timers, popups and audio
    case timerSet(timer: Int, ms: Int)
    case timerStart(timer: Int)
    case timerPause(timer: Int)
    case timerReset(timer: Int)
    case popupSet(popup: Int, text: String, clearAfterMs: Int?)
    case popupClear(popup: Int)
    case audioMute(audio: Target, state: SwitchState)
    // Macros, history and system
    case macro(Int)
    case undo
    case redo
    case historyJump(Int)
    case systemClearAll
    case systemPreflight
    case systemSnapshot
    case edit(EditCommand)
    /// Spec 1 §6 — unknown commands are kept verbatim; Spec 3 §6 answers `noop`.
    case unknown(cmd: String)

    // MARK: - Spec 2 §4 mapping rules: `cmd` is `target.verb` in camelCase.

    /// The `cmd` name of this command.
    public var cmd: String {
        switch self {
        case .channelWrite: return "channel.write"
        case .channelClear: return "channel.clear"
        case .channelReset: return "channel.reset"
        case .channelTransition: return "channel.transition"
        case .channelAudioTransition: return "channel.audioTransition"
        case .channelGrade: return "channel.grade"
        case .channelGain: return "channel.gain"
        case .channelTransport: return "channel.transport"
        case .channelEndBehavior: return "channel.endBehavior"
        case .channelLock: return "channel.lock"
        case .channelFreeze: return "channel.freeze"
        case .channelTrack: return "channel.track"
        case .channelBuild: return "channel.build"
        case .outputStack: return "output.stack"
        case .stackBlackout: return "stack.blackout"
        case .stackMute: return "stack.mute"
        case .next: return "playlist.next"
        case .previous: return "playlist.previous"
        case .cue: return "playlist.cue"
        case .itemCue: return "playlist.goto"
        case .itemSection: return "playlist.section"
        case .listCue: return "list.goto"
        case .playlistLoad: return "playlist.load"
        case .timerSet: return "timer.set"
        case .timerStart: return "timer.start"
        case .timerPause: return "timer.pause"
        case .timerReset: return "timer.reset"
        case .popupSet: return "popup.set"
        case .popupClear: return "popup.clear"
        case .audioMute: return "audio.mute"
        case .macro: return "macro.run"
        case .undo: return "history.undo"
        case .redo: return "history.redo"
        case .historyJump: return "history.jump"
        case .systemClearAll: return "system.clearAll"
        case .systemPreflight: return "system.preflight"
        case .systemSnapshot: return "system.snapshot"
        case .edit: return "edit"
        case .unknown(let cmd): return cmd
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let cmd = try c.decode(String.self, forKey: Key("cmd"))
        func target(_ name: String) throws -> Target { try c.decode(Target.self, forKey: Key(name)) }
        func int(_ name: String) throws -> Int { try c.decode(Int.self, forKey: Key(name)) }
        func intIf(_ name: String) throws -> Int? { try c.decodeIfPresent(Int.self, forKey: Key(name)) }
        func string(_ name: String) throws -> String { try c.decode(String.self, forKey: Key(name)) }
        switch cmd {
        case "channel.write":
            let riders = Riders(
                transition: try c.decodeIfPresent(TransitionRider.self, forKey: Key("transition")),
                audioTransition: try c.decodeIfPresent(TransitionRider.self, forKey: Key("audioTransition")),
                grade: try c.decodeIfPresent(GradeRider.self, forKey: Key("grade")),
                gain: try c.decodeIfPresent(GainRider.self, forKey: Key("gain")),
                chase: try c.decodeIfPresent(ChaseRider.self, forKey: Key("chase")),
                build: try intIf("build"))
            self = .channelWrite(ChannelWrite(
                channel: try target("channel"),
                content: try c.decode(ContentExpression.self, forKey: Key("content")),
                riders: riders))
        case "channel.clear": self = .channelClear(channel: try target("channel"))
        case "channel.reset": self = .channelReset(channel: try target("channel"))
        case "channel.transition":
            self = .channelTransition(channel: try target("channel"), ref: try int("ref"), ms: try intIf("ms"))
        case "channel.audioTransition":
            self = .channelAudioTransition(channel: try target("channel"), ref: try int("ref"), ms: try intIf("ms"))
        case "channel.grade":
            self = .channelGrade(channel: try target("channel"), ref: try int("ref"), ms: try intIf("ms"))
        case "channel.gain":
            self = .channelGain(channel: try target("channel"), db: try c.decode(Double.self, forKey: Key("db")))
        case "channel.transport":
            self = .channelTransport(channel: try target("channel"),
                                     mode: try c.decode(TransportMode.self, forKey: Key("mode")))
        case "channel.endBehavior":
            self = .channelEndBehavior(channel: try target("channel"),
                                       mode: try c.decode(EndBehavior.self, forKey: Key("mode")))
        case "channel.lock":
            self = .channelLock(channel: try target("channel"), locked: try c.decode(Bool.self, forKey: Key("locked")))
        case "channel.freeze":
            self = .channelFreeze(channel: try target("channel"), state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "channel.track":
            self = .channelTrack(channel: try target("channel"),
                                 direction: try c.decode(TrackDirection.self, forKey: Key("direction")))
        case "channel.build": self = .channelBuild(channel: try target("channel"), build: try int("build"))
        case "output.stack": self = .outputStack(output: try int("output"), stack: try int("stack"))
        case "stack.blackout":
            self = .stackBlackout(stack: try int("stack"), state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "stack.mute":
            self = .stackMute(stack: try int("stack"), channel: try int("channel"),
                              state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "playlist.next": self = .next
        case "playlist.previous": self = .previous
        case "playlist.cue": self = .cue(try int("cue"))
        case "playlist.goto": self = .itemCue(item: try int("item"), cue: try int("cue"))
        case "playlist.section": self = .itemSection(item: try int("item"), section: try string("section"))
        case "list.goto": self = .listCue(list: try int("list"), cue: try int("cue"))
        case "playlist.load":
            self = .playlistLoad(title: try string("title"), date: try c.decodeIfPresent(String.self, forKey: Key("date")))
        case "timer.set": self = .timerSet(timer: try int("timer"), ms: try int("ms"))
        case "timer.start": self = .timerStart(timer: try int("timer"))
        case "timer.pause": self = .timerPause(timer: try int("timer"))
        case "timer.reset": self = .timerReset(timer: try int("timer"))
        case "popup.set":
            self = .popupSet(popup: try int("popup"), text: try string("text"), clearAfterMs: try intIf("clearAfterMs"))
        case "popup.clear": self = .popupClear(popup: try int("popup"))
        case "audio.mute":
            self = .audioMute(audio: try target("audio"), state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "macro.run", "macro": self = .macro(try int("macro"))
        case "history.undo": self = .undo
        case "history.redo": self = .redo
        case "history.jump": self = .historyJump(try int("position"))
        case "system.clearAll": self = .systemClearAll
        case "system.preflight": self = .systemPreflight
        case "system.snapshot": self = .systemSnapshot
        case "edit": self = .edit(try EditCommand(from: decoder))
        default: self = .unknown(cmd: cmd)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(cmd, forKey: Key("cmd"))
        switch self {
        case .channelWrite(let w):
            try c.encode(w.channel, forKey: Key("channel"))
            try c.encode(w.content, forKey: Key("content"))
            try c.encodeIfPresent(w.riders.transition, forKey: Key("transition"))
            try c.encodeIfPresent(w.riders.audioTransition, forKey: Key("audioTransition"))
            try c.encodeIfPresent(w.riders.grade, forKey: Key("grade"))
            try c.encodeIfPresent(w.riders.gain, forKey: Key("gain"))
            try c.encodeIfPresent(w.riders.chase, forKey: Key("chase"))
            try c.encodeIfPresent(w.riders.build, forKey: Key("build"))
        case .channelClear(let ch), .channelReset(let ch):
            try c.encode(ch, forKey: Key("channel"))
        case .channelTransition(let ch, let ref, let ms), .channelAudioTransition(let ch, let ref, let ms),
             .channelGrade(let ch, let ref, let ms):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(ref, forKey: Key("ref"))
            try c.encodeIfPresent(ms, forKey: Key("ms"))
        case .channelGain(let ch, let db):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(db, forKey: Key("db"))
        case .channelTransport(let ch, let mode):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(mode, forKey: Key("mode"))
        case .channelEndBehavior(let ch, let mode):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(mode, forKey: Key("mode"))
        case .channelLock(let ch, let locked):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(locked, forKey: Key("locked"))
        case .channelFreeze(let ch, let state):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(state, forKey: Key("state"))
        case .channelTrack(let ch, let direction):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(direction, forKey: Key("direction"))
        case .channelBuild(let ch, let build):
            try c.encode(ch, forKey: Key("channel"))
            try c.encode(build, forKey: Key("build"))
        case .outputStack(let output, let stack):
            try c.encode(output, forKey: Key("output"))
            try c.encode(stack, forKey: Key("stack"))
        case .stackBlackout(let stack, let state):
            try c.encode(stack, forKey: Key("stack"))
            try c.encode(state, forKey: Key("state"))
        case .stackMute(let stack, let channel, let state):
            try c.encode(stack, forKey: Key("stack"))
            try c.encode(channel, forKey: Key("channel"))
            try c.encode(state, forKey: Key("state"))
        case .next, .previous, .undo, .redo, .systemClearAll, .systemPreflight, .systemSnapshot, .unknown:
            break
        case .cue(let n):
            try c.encode(n, forKey: Key("cue"))
        case .itemCue(let item, let cue):
            try c.encode(item, forKey: Key("item"))
            try c.encode(cue, forKey: Key("cue"))
        case .itemSection(let item, let section):
            try c.encode(item, forKey: Key("item"))
            try c.encode(section, forKey: Key("section"))
        case .listCue(let list, let cue):
            try c.encode(list, forKey: Key("list"))
            try c.encode(cue, forKey: Key("cue"))
        case .playlistLoad(let title, let date):
            try c.encode(title, forKey: Key("title"))
            try c.encodeIfPresent(date, forKey: Key("date"))
        case .timerSet(let timer, let ms):
            try c.encode(timer, forKey: Key("timer"))
            try c.encode(ms, forKey: Key("ms"))
        case .timerStart(let timer), .timerPause(let timer), .timerReset(let timer):
            try c.encode(timer, forKey: Key("timer"))
        case .popupSet(let popup, let text, let clearAfterMs):
            try c.encode(popup, forKey: Key("popup"))
            try c.encode(text, forKey: Key("text"))
            try c.encodeIfPresent(clearAfterMs, forKey: Key("clearAfterMs"))
        case .popupClear(let popup):
            try c.encode(popup, forKey: Key("popup"))
        case .audioMute(let audio, let state):
            try c.encode(audio, forKey: Key("audio"))
            try c.encode(state, forKey: Key("state"))
        case .macro(let n):
            try c.encode(n, forKey: Key("macro"))
        case .historyJump(let position):
            try c.encode(position, forKey: Key("position"))
        case .edit(let e):
            try e.encode(to: encoder)
        }
    }
}

/// Spec 2 §7 — "Any command in a macro can carry one guard." Encoded flat:
/// the command's own keys plus an optional `when`.
public struct GuardedCommand: Codable, Equatable, Sendable {
    public var command: Command
    public var when: Guard?

    public init(_ command: Command, when: Guard? = nil) {
        self.command = command
        self.when = when
    }

    private enum CodingKeys: String, CodingKey { case when }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = try c.decodeIfPresent(Guard.self, forKey: .when)
        command = try Command(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try command.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(when, forKey: .when)
    }
}
