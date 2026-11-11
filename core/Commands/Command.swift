// OCore — Spec 2 §3, the v1 vocabulary as command objects (Spec 1 §6).

/// Spec 2 §3 — "`N` is the target's number; every channel command, `stack N
/// blackout` and `audio N mute` also take the word `all`, for every channel,
/// stack or audio output." Encoded as the number or the string `"all"`.
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

    /// Spec 2 §3 — `on`, `off` or `toggle` on one target: the value it ends at.
    public func resolve(current: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }

    /// Spec 2 §3 — "With `all`, `toggle` turns every one on unless every one
    /// is already on, when it turns them all off." The one value every target
    /// of an `all` command ends at, given their current values.
    public func resolve(all currents: [Bool]) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !currents.allSatisfy { $0 }
        }
    }
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

/// Spec 2 §3 and Spec 3 §10 — `Command`: the Spec 2 objects. One case per
/// row of the vocabulary table, encoded in the Spec 1 §6 object form with
/// `cmd` as `target.verb`.
///
/// Spec 1 §6 — "The loader checks each command against the vocabulary in
/// Spec 2 and flags unknown commands or bad parameters on the cue rather than
/// dropping them; ... the command is kept verbatim so a newer version can
/// still read it." An unknown `cmd` decodes to `.unknown` with every
/// parameter; a known `cmd` whose parameters do not decode becomes `.invalid`
/// with every parameter. Both re-encode as they were read and the projection
/// answers `noop` (Spec 3 §6).
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
    case stackBlackout(stack: Target, state: SwitchState)
    case stackMute(stack: Int, channel: Int, state: SwitchState)
    // Playlist and library navigation
    case next
    case previous
    case cue(Int)
    case itemCue(item: Int, cue: Int)
    case itemSection(item: Int, section: String)
    case listCue(list: Int, cue: Int)
    /// Spec 2 §3 as Spec 7 §3 corrected it — `playlist "TITLE"`, by title alone.
    case playlistLoad(title: String)
    /// Spec 2 §3, Spec 7 §4 — "Clears the armed trigger, so nothing fires on its own".
    case disarm
    // Timers, popups and audio
    /// Spec 2 §3 as Spec 6 §10 corrected it — "`timer N set DURATION [up]`
    /// sets a countdown, or with `up` a count-up, and stops it" (Spec 6 §6).
    /// Spec 1 §5 — the object form writes `"up": true` only when true.
    case timerSet(timer: Int, ms: Int, up: Bool = false)
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
    /// Spec 5 §4 — the edit family, `edit.` plus the verb.
    case edit(EditCommand)
    /// Spec 8 §2 — the media family, `media.` plus the verb.
    case media(MediaCommand)
    /// Spec 1 §6 — an unknown `cmd`, kept verbatim with its parameters.
    case unknown(cmd: String, fields: [String: JSONValue] = [:])
    /// Spec 1 §6 — a known `cmd` whose parameters did not decode, kept verbatim.
    case invalid(cmd: String, fields: [String: JSONValue])

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
        case .disarm: return "playlist.disarm"
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
        case .edit(let e): return e.cmd
        case .media(let m): return m.cmd
        case .unknown(let cmd, _): return cmd
        case .invalid(let cmd, _): return cmd
        }
    }

    /// Spec 2 §3 — every `cmd` the vocabulary knows, plus the bare names
    /// Spec 1 §6 used before its correction for the verbs whose text form is
    /// bare (`next`, `previous`, `cue`, `undo`, `redo`, `macro`): accepted on
    /// input, never printed (Area 1 brief, deviation 2).
    public static let knownNames: Set<String> = Set<String>([
        "channel.write", "channel.clear", "channel.reset", "channel.transition", "channel.audioTransition", "channel.grade",
        "channel.gain", "channel.transport", "channel.endBehavior", "channel.lock", "channel.freeze", "channel.track",
        "channel.build", "output.stack", "stack.blackout", "stack.mute", "playlist.next", "playlist.previous",
        "playlist.cue", "playlist.goto", "playlist.section", "list.goto", "playlist.load", "playlist.disarm", "timer.set", "timer.start",
        "timer.pause", "timer.reset", "popup.set", "popup.clear", "audio.mute", "macro.run", "history.undo",
        "history.redo", "history.jump", "system.clearAll", "system.preflight", "system.snapshot",
        "next", "previous", "cue", "undo", "redo", "macro",
    ]).union(EditAction.commandNames).union(MediaCommand.commandNames)

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Spec 2 §3 — the navigation that fires a cue: `next`, `previous`, `cue
    /// N`, `item N cue M`, `item N section`, `list N cue M`. Spec 2 §9 logs it
    /// as the navigation's line, then the cue's commands as their own group.
    public var isNavigation: Bool {
        switch self {
        case .next, .previous, .cue, .itemCue, .itemSection, .listCue: return true
        default: return false
        }
    }

    public var isInvalid: Bool {
        if case .invalid = self { return true }
        return false
    }

    /// Spec 1 §6 — why an `.invalid` command's parameters did not decode;
    /// nil for every other case.
    public var invalidReason: String? {
        guard case .invalid(let cmd, let fields) = self else { return nil }
        var object = fields
        object["cmd"] = .string(cmd)
        do {
            _ = try JSONCoding.decode(StrictCommand.self, from: .object(object))
            return "parameters did not decode"
        } catch {
            return JSONCoding.describe(error)
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Spec 1 §6 — the parameters of a command object: everything but `cmd`
    /// and the `when` guard that belongs to the entry around it.
    static func parameters(from decoder: Decoder) throws -> [String: JSONValue] {
        try decoder.unknownKeys(besides: ["cmd", "when"])
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let cmd = try c.decode(String.self, forKey: Key("cmd"))
        guard Command.knownNames.contains(cmd) else {
            self = .unknown(cmd: cmd, fields: try Command.parameters(from: decoder))
            return
        }
        do {
            self = try Command(strict: cmd, from: decoder)
        } catch is DecodingError {
            self = .invalid(cmd: cmd, fields: try Command.parameters(from: decoder))
        }
    }

    /// The strict decoder: a known `cmd` with its parameters, or a `DecodingError`.
    init(strict cmd: String, from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func target(_ name: String) throws -> Target { try c.decode(Target.self, forKey: Key(name)) }
        func int(_ name: String) throws -> Int { try c.decode(Int.self, forKey: Key(name)) }
        func intIf(_ name: String) throws -> Int? { try c.decodeIfPresent(Int.self, forKey: Key(name)) }
        func string(_ name: String) throws -> String { try c.decode(String.self, forKey: Key(name)) }
        switch cmd {
        case "channel.write":
            var riders = Riders(
                transition: try c.decodeIfPresent(TransitionRider.self, forKey: Key("transition")),
                audioTransition: try c.decodeIfPresent(TransitionRider.self, forKey: Key("audioTransition")),
                grade: try c.decodeIfPresent(GradeRider.self, forKey: Key("grade")),
                gain: try c.decodeIfPresent(GainRider.self, forKey: Key("gain")),
                chase: try c.decodeIfPresent(ChaseRider.self, forKey: Key("chase")),
                build: try intIf("build"))
            var content = try c.decode(ContentExpression.self, forKey: Key("content"))
            // Spec 3 §3 rule 8 — "Build is an attribute of slide content": a
            // `build` rider on a slide write with no build of its own is the
            // content's build (Area 3 plan, decision 4).
            if case .slide(let ref, nil) = content, let build = riders.build {
                content = .slide(ref: ref, build: build)
                riders.build = nil
            }
            self = .channelWrite(ChannelWrite(channel: try target("channel"), content: content, riders: riders))
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
            self = .stackBlackout(stack: try target("stack"), state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "stack.mute":
            self = .stackMute(stack: try int("stack"), channel: try int("channel"),
                              state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "playlist.next", "next": self = .next
        case "playlist.previous", "previous": self = .previous
        case "playlist.cue", "cue": self = .cue(try int("cue"))
        case "playlist.goto": self = .itemCue(item: try int("item"), cue: try int("cue"))
        case "playlist.section": self = .itemSection(item: try int("item"), section: try string("section"))
        case "list.goto": self = .listCue(list: try int("list"), cue: try int("cue"))
        case "playlist.load":
            // Spec 7 §3 — "A `playlist.load` stored with a `date`, from before
            // this spec, loads by its title and ignores the date": the date
            // stays as an unknown key of the stored command (Spec 1 §8).
            self = .playlistLoad(title: try string("title"))
        case "playlist.disarm": self = .disarm
        case "timer.set":
            // Spec 6 §6 — `up` "written only when true, like `loop`": absent is a countdown.
            self = .timerSet(timer: try int("timer"), ms: try int("ms"),
                             up: try c.decodeIfPresent(Bool.self, forKey: Key("up")) ?? false)
        case "timer.start": self = .timerStart(timer: try int("timer"))
        case "timer.pause": self = .timerPause(timer: try int("timer"))
        case "timer.reset": self = .timerReset(timer: try int("timer"))
        case "popup.set":
            self = .popupSet(popup: try int("popup"), text: try string("text"), clearAfterMs: try intIf("clearAfterMs"))
        case "popup.clear": self = .popupClear(popup: try int("popup"))
        case "audio.mute":
            self = .audioMute(audio: try target("audio"), state: try c.decode(SwitchState.self, forKey: Key("state")))
        case "macro.run", "macro": self = .macro(try int("macro"))
        case "history.undo", "undo": self = .undo
        case "history.redo", "redo": self = .redo
        case "history.jump": self = .historyJump(try int("position"))
        case "system.clearAll": self = .systemClearAll
        case "system.preflight": self = .systemPreflight
        case "system.snapshot": self = .systemSnapshot
        case let edit where edit.hasPrefix("edit."):
            self = .edit(try EditCommand(cmd: edit, fields: try Command.parameters(from: decoder)))
        case let media where media.hasPrefix("media."):
            self = .media(try MediaCommand(cmd: media, fields: try Command.parameters(from: decoder)))
        default:
            throw DecodingError.dataCorruptedError(forKey: Key("cmd"), in: c, debugDescription: "unknown command \(cmd)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(_, let fields) = self {
            try encoder.encode(unknownKeys: fields)
        }
        if case .invalid(_, let fields) = self {
            try encoder.encode(unknownKeys: fields)
        }
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
        case .next, .previous, .disarm, .undo, .redo, .systemClearAll, .systemPreflight, .systemSnapshot, .unknown, .invalid:
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
        case .playlistLoad(let title):
            try c.encode(title, forKey: Key("title"))
        case .timerSet(let timer, let ms, let up):
            try c.encode(timer, forKey: Key("timer"))
            try c.encode(ms, forKey: Key("ms"))
            if up { try c.encode(true, forKey: Key("up")) }
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
            for (key, value) in e.fields { try c.encode(value, forKey: Key(key)) }
        case .media(let m):
            for (key, value) in m.fields { try c.encode(value, forKey: Key(key)) }
        }
    }

    // MARK: - Reading a command's parts

    /// The channel target of a channel command, if it has one.
    public var channelTarget: Target? {
        switch self {
        case .channelWrite(let w): return w.channel
        case .channelClear(let ch), .channelReset(let ch), .channelTransition(let ch, _, _), .channelAudioTransition(let ch, _, _),
             .channelGrade(let ch, _, _), .channelGain(let ch, _), .channelTransport(let ch, _), .channelEndBehavior(let ch, _),
             .channelLock(let ch, _), .channelFreeze(let ch, _), .channelTrack(let ch, _), .channelBuild(let ch, _):
            return ch
        default: return nil
        }
    }

    /// A write's riders, if this is a write.
    public var riders: Riders? {
        if case .channelWrite(let w) = self { return w.riders }
        return nil
    }

    /// Replace a write's riders; anything else is unchanged.
    public mutating func setRiders(_ riders: Riders) {
        guard case .channelWrite(var w) = self else { return }
        w.riders = riders
        self = .channelWrite(w)
    }

    /// The media or slide id a write names, if any.
    public var mediaRef: String? {
        if case .channelWrite(let w) = self { return w.content.mediaRef }
        return nil
    }

    // MARK: - Spec 1 §4, references by number

    /// Spec 1 §4 — "When an object's number changes, every internal
    /// reference in the library and the machine root is rewritten". Returns
    /// this command with every numbered reference passed through `transform`.
    /// Unknown and invalid commands are left as they were read.
    public func mapReferences(_ transform: (NumberedType, Int) -> Int) -> Command {
        func target(_ type: NumberedType, _ t: Target) -> Target {
            if case .number(let n) = t { return .number(transform(type, n)) }
            return t
        }
        switch self {
        case .channelWrite(var w):
            w.channel = target(.channel, w.channel)
            if case .input(let n) = w.content { w.content = .input(transform(.input, n)) }
            if var r = w.riders.transition { r.ref = transform(.transition, r.ref); w.riders.transition = r }
            if var r = w.riders.audioTransition { r.ref = transform(.audioTransition, r.ref); w.riders.audioTransition = r }
            if var r = w.riders.grade { r.ref = transform(.grade, r.ref); w.riders.grade = r }
            return .channelWrite(w)
        case .channelClear(let ch): return .channelClear(channel: target(.channel, ch))
        case .channelReset(let ch): return .channelReset(channel: target(.channel, ch))
        case .channelTransition(let ch, let ref, let ms):
            return .channelTransition(channel: target(.channel, ch), ref: transform(.transition, ref), ms: ms)
        case .channelAudioTransition(let ch, let ref, let ms):
            return .channelAudioTransition(channel: target(.channel, ch), ref: transform(.audioTransition, ref), ms: ms)
        case .channelGrade(let ch, let ref, let ms):
            return .channelGrade(channel: target(.channel, ch), ref: transform(.grade, ref), ms: ms)
        case .channelGain(let ch, let db): return .channelGain(channel: target(.channel, ch), db: db)
        case .channelTransport(let ch, let mode): return .channelTransport(channel: target(.channel, ch), mode: mode)
        case .channelEndBehavior(let ch, let mode): return .channelEndBehavior(channel: target(.channel, ch), mode: mode)
        case .channelLock(let ch, let locked): return .channelLock(channel: target(.channel, ch), locked: locked)
        case .channelFreeze(let ch, let state): return .channelFreeze(channel: target(.channel, ch), state: state)
        case .channelTrack(let ch, let direction): return .channelTrack(channel: target(.channel, ch), direction: direction)
        case .channelBuild(let ch, let build): return .channelBuild(channel: target(.channel, ch), build: build)
        case .outputStack(let output, let stack):
            return .outputStack(output: transform(.output, output), stack: transform(.stack, stack))
        // Spec 1 §2 — `stack all` names no stack, so it is never a reference.
        case .stackBlackout(let stack, let state): return .stackBlackout(stack: target(.stack, stack), state: state)
        case .stackMute(let stack, let channel, let state):
            return .stackMute(stack: transform(.stack, stack), channel: transform(.channel, channel), state: state)
        case .listCue(let list, let cue): return .listCue(list: transform(.list, list), cue: cue)
        case .audioMute(let audio, let state): return .audioMute(audio: target(.audioOutput, audio), state: state)
        case .macro(let n): return .macro(transform(.macro, n))
        case .edit(let e):
            return .edit(e.mapReferences(transform))
        case .next, .previous, .cue, .itemCue, .itemSection, .playlistLoad, .disarm, .timerSet, .timerStart, .timerPause, .timerReset,
             .popupSet, .popupClear, .undo, .redo, .historyJump, .systemClearAll, .systemPreflight, .systemSnapshot,
             .media, .unknown, .invalid:
            return self
        }
    }

    /// Every number this command uses to name an object of `type`.
    public func forEachReference(of type: NumberedType, _ body: (Int) -> Void) {
        _ = mapReferences { found, number in
            if found == type { body(number) }
            return number
        }
    }

    /// Spec 1 §7 — `replace media`: this command with every media or slide id
    /// passed through `transform`.
    public func mapMediaRefs(_ transform: (String) -> String) -> Command {
        guard case .channelWrite(var w) = self else { return self }
        switch w.content {
        case .media(var m):
            m.ref = transform(m.ref)
            w.content = .media(m)
        case .slide(let ref, let build):
            w.content = .slide(ref: transform(ref), build: build)
        default:
            break
        }
        return .channelWrite(w)
    }
}

/// The strict decoding of a command object, for diagnosing an `.invalid` one.
private struct StrictCommand: Decodable {
    let command: Command

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard let key = Key(stringValue: "cmd") else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "cmd")) }
        command = try Command(strict: try c.decode(String.self, forKey: key), from: decoder)
    }
}

/// Spec 2 §7 — "Any command in a macro can carry one guard." Spec 1 §6 — the
/// guard is "reserved on cues". Encoded flat: the command's own keys plus an
/// optional `when`, plus any keys the vocabulary does not know (Spec 1 §8).
public struct GuardedCommand: Codable, Equatable, Sendable {
    public var command: Command
    public var when: Guard?
    public var extra: [String: JSONValue]

    public init(_ command: Command, when: Guard? = nil, extra: [String: JSONValue] = [:]) {
        self.command = command
        self.when = when
        self.extra = extra
    }

    private enum CodingKeys: String, CodingKey { case when }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        when = try c.decodeIfPresent(Guard.self, forKey: .when)
        command = try Command(from: decoder)
        // The keys the command itself writes back are not unknown.
        let written = (try? JSONCoding.encode(command).objectValue?.keys).map { Set($0) } ?? []
        extra = try decoder.unknownKeys(besides: written.union(["cmd", "when"]))
    }

    public func encode(to encoder: Encoder) throws {
        try encoder.encode(unknownKeys: extra)
        try command.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(when, forKey: .when)
    }

    /// Spec 1 §6 — a cue's or macro's commands decode one at a time, so one
    /// command with bad parameters never takes the document down.
    static func decodeList<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> [GuardedCommand] {
        let raw = try container.decodeIfPresent([JSONValue].self, forKey: key) ?? []
        return try raw.map { try JSONCoding.decode(GuardedCommand.self, from: $0) }
    }
}
