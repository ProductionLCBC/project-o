// OApp — Spec 10 §3, what the topics carry, read into values.

import Foundation
import OCore

extension [String: JSONValue] {
    func text(_ key: String) -> String? { self[key]?.stringValue }
    func integer(_ key: String) -> Int? { self[key]?.intValue }
    func flag(_ key: String) -> Bool? { self[key]?.boolValue }
    func members(_ key: String) -> [String: JSONValue]? { self[key]?.objectValue }
    func items(_ key: String) -> [JSONValue]? { self[key]?.arrayValue }
}

// MARK: - live (Spec 7 §6, Spec 10 §3)

/// Spec 7 §6, the `live` event — "It names the pointer by both handles ...
/// with the positions the OSC messages send, what is gone and the armed
/// trigger. Spec 10 §3 adds the playlist's and list's titles, the cue's
/// label and the list boundary".
public struct LiveStatus: Equatable, Sendable {
    /// Spec 7 §6 — the armed trigger: the cue that will fire and "the
    /// milliseconds left when the message is sent", which the app counts
    /// down "on its own clock from when it receives them".
    public struct Armed: Equatable, Sendable {
        public var item: String?
        public var cue: String
        public var itemPosition: Int
        public var cuePosition: Int
        public var inMs: Int

        public init(item: String?, cue: String, itemPosition: Int, cuePosition: Int, inMs: Int) {
            self.item = item
            self.cue = cue
            self.itemPosition = itemPosition
            self.cuePosition = cuePosition
            self.inMs = inMs
        }
    }

    /// The live playlist's uuid; nil with no playlist loaded, and for a list fired from the library.
    public var playlist: String?
    public var item: String?
    public var list: Int?
    public var listUuid: String?
    /// The last cue fired; nil with a playlist loaded and no cue fired yet.
    public var cue: String?
    /// The live item's and cue's numbers "as they are now"; 0 where there is none.
    public var itemPosition = 0
    public var cuePosition = 0
    /// "what has been removed, of `cue`, `item`, `list` and `playlist`".
    public var gone: Set<String> = []
    public var playlistTitle = ""
    public var listTitle = ""
    public var label = ""
    public var armed: Armed?

    public init() {}

    /// Reads a `live` event; nil when it isn't one.
    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "live" else { return nil }
        playlist = event.text("playlist")
        item = event.text("item")
        list = event.integer("list")
        listUuid = event.text("listUuid")
        cue = event.text("cue")
        let position = event.members("position")
        itemPosition = position?.integer("item") ?? 0
        cuePosition = position?.integer("cue") ?? 0
        gone = Set((event.items("gone") ?? []).compactMap(\.stringValue))
        playlistTitle = event.text("playlistTitle") ?? ""
        listTitle = event.text("listTitle") ?? ""
        label = event.text("label") ?? ""
        if let armed = event.members("armed"), let cue = armed.text("cue") {
            let place = armed.members("position")
            self.armed = Armed(item: armed.text("item"), cue: cue, itemPosition: place?.integer("item") ?? 0,
                               cuePosition: place?.integer("cue") ?? 0, inMs: armed.integer("inMs") ?? 0)
        }
    }

    /// Spec 10 §3 — "on a fire that enters another list, `boundary`, whose
    /// `reset` is false when that list tracks through". Nil on any other event.
    public static func boundaryReset(in event: [String: JSONValue]) -> Bool? {
        event.members("boundary")?.flag("reset")
    }

    /// Spec 10 §7 — "While nothing is live, with no playlist loaded and no
    /// list fired from the library (Spec 7 §4), Next is disabled".
    public var isSomethingLive: Bool { playlist != nil || listUuid != nil }

    /// A cue has been fired, so `previous` and `cue N` have somewhere to stand.
    public var hasFired: Bool { cue != nil }

    /// Spec 10 §6 — "the list fired from the library when that is live": a live list with no playlist.
    public var isLibraryList: Bool { playlist == nil && listUuid != nil }
}

// MARK: - channels (Spec 10 §3)

/// Spec 10 §3, the `channels` topic — a channel's content: "kind, ref,
/// label, missing, whether it has a picture and whether it has sound, and
/// for timed media its duration, position, loop and end behaviour; for text
/// its fields".
public struct ChannelContent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text(fields: [String: String])
        case media(ref: String, missing: Bool, loop: Bool, endBehavior: String)
        case slide(ref: String)
        case input(Int)
        /// A kind this build doesn't know: shown by its label, never guessed at.
        case other(String)
    }

    public var kind: Kind
    public var label: String
    public var hasPicture: Bool
    public var hasAudio: Bool
    /// "Timed media's duration and position count within its in and out
    /// points, so its remaining time is the duration less the position".
    public var durationMs: Int?
    public var positionMs: Int?

    public init(kind: Kind, label: String, hasPicture: Bool = false, hasAudio: Bool = false, durationMs: Int? = nil, positionMs: Int? = nil) {
        self.kind = kind
        self.label = label
        self.hasPicture = hasPicture
        self.hasAudio = hasAudio
        self.durationMs = durationMs
        self.positionMs = positionMs
    }

    public init?(_ content: [String: JSONValue]) {
        guard let kind = content.text("kind") else { return nil }
        switch kind {
        case "text":
            var fields: [String: String] = [:]
            for (name, value) in content.members("fields") ?? [:] { fields[name] = value.stringValue }
            self.kind = .text(fields: fields)
        case "media":
            self.kind = .media(ref: content.text("ref") ?? "", missing: content.flag("missing") ?? false, loop: content.flag("loop") ?? false,
                               endBehavior: content.text("endBehavior") ?? "")
        case "slide":
            self.kind = .slide(ref: content.text("ref") ?? "")
        case "input":
            self.kind = .input(content.integer("input") ?? 0)
        default:
            self.kind = .other(kind)
        }
        label = content.text("label") ?? ""
        hasPicture = content.flag("hasPicture") ?? false
        hasAudio = content.flag("hasAudio") ?? false
        durationMs = content.integer("durationMs")
        positionMs = content.integer("positionMs")
    }

    /// Whether this is media with a length: what the Transport tab and a cell's remaining time are about.
    public var isTimed: Bool {
        if case .media = kind { return durationMs != nil }
        return false
    }
}

/// Spec 10 §3 — one channel as its event reports it: "its content ...,
/// state as `/o/channel/N/state` reports it, provenance, lock, tracked
/// attributes with their origins (Spec 3 §2)".
public struct ChannelStatus: Equatable, Sendable {
    /// Spec 3 §2 — one tracked attribute: its value and where it came from (`default`, `tracked` or `once`).
    public struct Attribute: Equatable, Sendable {
        public var value: JSONValue
        public var origin: String

        public init(value: JSONValue, origin: String) {
            self.value = value
            self.origin = origin
        }
    }

    public var number: Int
    /// Spec 2 §6 — `empty`, `playing`, `paused`, `held` or `missing`.
    public var state: String
    public var lock: Bool
    /// "An empty channel has `content: null`."
    public var content: ChannelContent?
    /// Spec 3 §2 — what put the content there: a cue, a restore, or a source.
    public var provenance: Provenance?
    public var attributes: [String: Attribute]

    public init(number: Int, state: String = "empty", lock: Bool = false, content: ChannelContent? = nil, provenance: Provenance? = nil,
                attributes: [String: Attribute] = [:]) {
        self.number = number
        self.state = state
        self.lock = lock
        self.content = content
        self.provenance = provenance
        self.attributes = attributes
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "channels", let number = event.integer("channel") else { return nil }
        self.number = number
        state = event.text("state") ?? "empty"
        lock = event.flag("lock") ?? false
        content = event.members("content").flatMap(ChannelContent.init)
        provenance = event["provenance"].flatMap { $0 == .null ? nil : try? JSONCoding.decode(Provenance.self, from: $0) }
        attributes = [:]
        for (name, value) in event.members("attributes") ?? [:] {
            guard let reading = value.objectValue, let origin = reading.text("origin") else { continue }
            attributes[name] = Attribute(value: reading["value"] ?? .null, origin: origin)
        }
    }
}

/// Spec 10 §3 — what a `channels` event says "once each": "a transition that
/// starts (picture and sound durations and the sound's offset), `steppedOn`
/// and `blocked`". The strip's transition bar and its flashes start from
/// these (Spec 10 §7); they are moments, not state, and the store keeps none.
public struct ChannelMoment: Equatable, Sendable {
    public struct Transition: Equatable, Sendable {
        public var ms: Int
        public var audioMs: Int
        public var audioOffsetMs: Int
    }

    public var channel: Int
    public var transition: Transition?
    public var steppedOn: Bool
    public var blocked: Bool

    /// Nil when the event says nothing once-only.
    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "channels", let channel = event.integer("channel") else { return nil }
        self.channel = channel
        transition = event.members("transition").map {
            Transition(ms: $0.integer("ms") ?? 0, audioMs: $0.integer("audioMs") ?? 0, audioOffsetMs: $0.integer("audioOffsetMs") ?? 0)
        }
        steppedOn = event.flag("steppedOn") ?? false
        blocked = event.flag("blocked") ?? false
        if transition == nil, !steppedOn, !blocked { return nil }
    }
}

// MARK: - outputs, audio, popups (Spec 10 §3)

/// Spec 10 §3, the `outputs` topic — "Per output: its live stack, its state
/// (`presenting`, `paused` while its screen or card is gone, `released`, or
/// `absent` when its device isn't there) and, for SDI, its reference
/// (`locked`, `freeRun` or `none`)."
public struct OutputStatus: Equatable, Sendable {
    public var number: Int
    public var stack: Int
    public var state: String
    public var reference: String?

    public init(number: Int, stack: Int, state: String, reference: String? = nil) {
        self.number = number
        self.stack = stack
        self.state = state
        self.reference = reference
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "outputs", let number = event.integer("output") else { return nil }
        self.init(number: number, stack: event.integer("stack") ?? 0, state: event.text("state") ?? "absent", reference: event.text("reference"))
    }

    public var isPresenting: Bool { state == "presenting" }
}

/// Spec 10 §3, the `outputs` topic — "Per stack: blackout and muted channels".
public struct StackStatus: Equatable, Sendable {
    public var number: Int
    public var blackout: Bool
    public var muted: [Int]

    public init(number: Int, blackout: Bool = false, muted: [Int] = []) {
        self.number = number
        self.blackout = blackout
        self.muted = muted
    }

    /// A stack's event names its stack and no output; an output's event names both.
    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "outputs", event["output"] == nil, let number = event.integer("stack") else { return nil }
        self.init(number: number, blackout: event.flag("blackout") ?? false, muted: (event.items("muted") ?? []).compactMap(\.intValue))
    }
}

/// Spec 10 §3, the `audio` topic — "Per audio output: `ok`, `fallback` or
/// `silent` (Spec 4 §12), and muted".
public struct AudioStatus: Equatable, Sendable {
    public var number: Int
    public var state: String
    public var muted: Bool

    public init(number: Int, state: String, muted: Bool) {
        self.number = number
        self.state = state
        self.muted = muted
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "audio", let number = event.integer("audioOutput") else { return nil }
        self.init(number: number, state: event.text("state") ?? "silent", muted: event.flag("muted") ?? false)
    }
}

/// Spec 10 §3, the `popups` topic — "Per slot: its text, and the
/// milliseconds left on a pending clear-after", measured when the event was
/// made.
public struct PopupStatus: Equatable, Sendable {
    public var slot: Int
    public var text: String
    public var clearInMs: Int?

    public init(slot: Int, text: String = "", clearInMs: Int? = nil) {
        self.slot = slot
        self.text = text
        self.clearInMs = clearInMs
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "popups", let slot = event.integer("popup") else { return nil }
        self.init(slot: slot, text: event.text("text") ?? "", clearInMs: event.integer("clearInMs"))
    }

    public var isSet: Bool { !text.isEmpty }
}

// MARK: - timers (Spec 6 §8)

/// Spec 6 §8, the `timers` topic — "`state` is `unset`, `stopped`,
/// `running` or `paused`, and `direction` is `down` or `up`. An unset timer
/// has `null` for `direction`, `setMs` and `valueMs`, and `""` for `text`."
public struct TimerStatus: Equatable, Sendable {
    public var slot: Int
    public var state: String
    public var direction: String?
    public var setMs: Int?
    public var valueMs: Int?
    public var text: String

    public init(slot: Int, state: String = "unset", direction: String? = nil, setMs: Int? = nil, valueMs: Int? = nil, text: String = "") {
        self.slot = slot
        self.state = state
        self.direction = direction
        self.setMs = setMs
        self.valueMs = valueMs
        self.text = text
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "timers", let slot = event.integer("timer") else { return nil }
        self.init(slot: slot, state: event.text("state") ?? "unset", direction: event.text("direction"), setMs: event.integer("setMs"),
                  valueMs: event.integer("valueMs"), text: event.text("text") ?? "")
    }

    public var isRunning: Bool { state == "running" }
}

// MARK: - history, saving (Spec 9 §5, §7)

/// Spec 9 §5, the `history` topic — the top of each stack: "`text` is the
/// group's first command in its canonical form, `commands` how many it has,
/// and `source` where it came from (Spec 10 §10)".
public struct HistoryStatus: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var group: String
        public var commands: Int
        public var source: String
        public var text: String

        public init(group: String, commands: Int, source: String, text: String) {
            self.group = group
            self.commands = commands
            self.source = source
            self.text = text
        }

        init?(_ value: JSONValue?) {
            guard let members = value?.objectValue else { return nil }
            self.init(group: members.text("group") ?? "", commands: members.integer("commands") ?? 1,
                      source: members.members("source")?.text("kind") ?? "", text: members.text("text") ?? "")
        }
    }

    public var undo: Step?
    public var redo: Step?

    public init(undo: Step? = nil, redo: Step? = nil) {
        self.undo = undo
        self.redo = redo
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "history" else { return nil }
        self.init(undo: Step(event["undo"]), redo: Step(event["redo"]))
    }
}

/// Spec 9 §7, the `saving` topic — "`unsaved` counts the documents waiting
/// to be written past their second; `disk` is `ok`, `low` or `full`; `log`
/// is `file` or `memory`."
public struct SavingStatus: Equatable, Sendable {
    public var unsaved: Int
    public var disk: String
    public var log: String
    public var lastSnapshot: String?

    public init(unsaved: Int = 0, disk: String = "ok", log: String = "file", lastSnapshot: String? = nil) {
        self.unsaved = unsaved
        self.disk = disk
        self.log = log
        self.lastSnapshot = lastSnapshot
    }

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "saving" else { return nil }
        self.init(unsaved: event.integer("unsaved") ?? 0, disk: event.text("disk") ?? "ok", log: event.text("log") ?? "file",
                  lastSnapshot: event.text("lastSnapshot"))
    }
}

// MARK: - engine (Spec 10 §3)

/// Spec 10 §3, the `engine` topic — "The run; the lock and whether a
/// passcode is set (§12); the LAN listener's state (`open`, `closed` or
/// `waiting`) and client count; the last state this run, put back with what
/// didn't come back, or skipped with Spec 9 §2's reason; and badges."
public struct EngineStatus: Equatable, Sendable {
    /// Spec 10 §14 — what became of the last state at this run's launch.
    public enum LastState: Equatable, Sendable {
        case restored(writtenAt: String?, left: [JSONValue])
        /// `clean`, `old` or `restoredBefore` (Spec 9 §2).
        case skipped(reason: String, writtenAt: String?)
    }

    /// Spec 10 §3 — "A badge's `kind` is `thermal` (serious or critical),
    /// `memory` (warning or critical pressure), `watchdog` or `gpu` ...,
    /// `clock` ... or `keychain`".
    public struct Badge: Equatable, Sendable {
        public var kind: String
        public var level: String?

        public init(kind: String, level: String? = nil) {
            self.kind = kind
            self.level = level
        }
    }

    public var run: String
    public var lock: Bool
    public var passcode: Bool
    public var lanState: String
    public var lanClients: Int
    public var lastState: LastState?
    public var badges: [Badge]

    public init(run: String = "", lock: Bool = false, passcode: Bool = false, lanState: String = "closed", lanClients: Int = 0,
                lastState: LastState? = nil, badges: [Badge] = []) {
        self.run = run
        self.lock = lock
        self.passcode = passcode
        self.lanState = lanState
        self.lanClients = lanClients
        self.lastState = lastState
        self.badges = badges
    }

    /// Reads the standing `engine` event; nil for the `remote` event, which is one of its own.
    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "engine", let run = event.text("run") else { return nil }
        let lan = event.members("lan")
        var lastState: LastState?
        if let last = event.members("lastState") {
            if last.flag("restored") == true {
                lastState = .restored(writtenAt: last.text("writtenAt"), left: last.items("left") ?? [])
            } else {
                lastState = .skipped(reason: last.text("reason") ?? "", writtenAt: last.text("writtenAt"))
            }
        }
        self.init(run: run, lock: event.flag("lock") ?? false, passcode: event.flag("passcode") ?? false,
                  lanState: lan?.text("state") ?? "closed", lanClients: lan?.integer("clients") ?? 0, lastState: lastState,
                  badges: (event.items("badges") ?? []).compactMap { badge in
                      guard let members = badge.objectValue, let kind = members.text("kind") else { return nil }
                      return Badge(kind: kind, level: members.text("level"))
                  })
    }

    /// Spec 10 §3 — "`remote` lists the sources of the commands that arrived
    /// from outside the app since the last such event: `osc`, `api`, `midi`,
    /// `streamdeck`". Nil for the standing event.
    public static func remoteSources(in event: [String: JSONValue]) -> [String]? {
        guard event.text("topic") == "engine" else { return nil }
        return event.items("remote")?.compactMap(\.stringValue)
    }
}

// MARK: - library, media, thumbnails

/// Spec 5 §2, the `library` event — the revision it makes, its cause
/// ("`edit`, `undo`, `redo`, `file`, `media`, `restore` or `lock`") and what
/// changed: each object once, by its address, with the paths that changed or
/// none when the whole object did.
public struct LibraryChangeEvent: Equatable, Sendable {
    public struct Changed: Equatable, Sendable {
        /// `list`, `cue`, `playlist`, `item`, `folder`, `media`, `channel` and so on.
        public var object: String
        /// The object's address as the event gives it: `list`, `listUuid`, `cue`, `playlist`, `item`, `folder`, `media`.
        public var address: [String: JSONValue]
        public var paths: [String]
    }

    public var rev: Int
    public var cause: String
    public var changed: [Changed]
    public var group: String?
    public var source: String?

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "library", let rev = event.integer("rev") else { return nil }
        self.rev = rev
        cause = event.text("cause") ?? ""
        group = event.text("group")
        source = event.members("source")?.text("kind")
        changed = (event.items("changed") ?? []).compactMap { entry in
            guard var members = entry.objectValue, let object = members.text("object") else { return nil }
            let paths = (members.items("paths") ?? []).compactMap(\.stringValue)
            members["object"] = nil
            members["paths"] = nil
            return Changed(object: object, address: members, paths: paths)
        }
    }
}

/// Spec 8 §7, the `media` topic — "one event per file as a job moves
/// through hashing, copying, reading and the poster, a final outcome per
/// file, and the walk's progress. It also carries changes in an item's
/// missing state".
public struct MediaEvent: Equatable, Sendable {
    public var job: String?
    /// `import`, `missing`, or the walk's own word.
    public var op: String
    public var file: String?
    public var state: String?
    public var progress: Double?
    /// `imported`, `known` or `refused`, on a job's `done`.
    public var outcome: String?
    public var id: String?
    /// A refusal's reason: `unsupported`, `changed`, `diskFull`, `notListed` or `readOnlyLibrary`.
    public var reason: String?
    public var missing: Bool?

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "media", let op = event.text("op") else { return nil }
        self.op = op
        job = event.text("job")
        file = event.text("file")
        state = event.text("state")
        progress = event["progress"]?.doubleValue
        outcome = event.text("outcome")
        id = event.text("id")
        reason = event.text("reason")
        missing = event.flag("missing")
    }

    /// The job's last word on a file.
    public var isDone: Bool { state == "done" }
}

/// Spec 10 §3, the `thumbnails` topic — "A cue thumbnail written, with its
/// stack, list, cue and file; or a pool tile written, with its id and file",
/// the file "relative to the machine root".
public enum ThumbnailEvent: Equatable, Sendable {
    case cue(stack: Int, listUuid: String, cue: String, file: String)
    case tile(id: String, file: String)

    public init?(event: [String: JSONValue]) {
        guard event.text("topic") == "thumbnails", let file = event.text("file") else { return nil }
        if let id = event.text("id") {
            self = .tile(id: id, file: file)
        } else if let cue = event.text("cue"), let list = event.text("listUuid") {
            self = .cue(stack: event.integer("stack") ?? 0, listUuid: list, cue: cue, file: file)
        } else {
            return nil
        }
    }
}
