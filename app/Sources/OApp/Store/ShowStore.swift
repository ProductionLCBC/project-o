// OApp — Spec 10 §1 and §3, what the app shows: the engine's reports, kept in one place on the main thread.

import Foundation
import OCore

/// What part of the store a change touched, so a view redraws only for its own.
public enum StoreChange: Hashable, Sendable {
    case connection
    case live
    case channels
    case outputs
    case stacks
    case audio
    case popups
    case timers
    case history
    case saving
    case engine
    case devices
    case metrics
    case catalog
    case lists
    case media
    case thumbnails
}

/// Something that happened once and is no state: the store hands it on and keeps none of it.
public enum StoreMoment: Equatable, Sendable {
    /// Spec 10 §7 — a fire entered another list; the strip shows "reset" where attributes went back to their defaults.
    case boundary(reset: Bool)
    /// Spec 10 §7 — a transition starting, a channel stepped on, a write a lock blocked.
    case channel(ChannelMoment)
    /// Spec 10 §8 — the remote dot: commands arrived from outside the app.
    case remote([String])
    /// Spec 8 §7 — a job's progress, an outcome, an item's missing state changing.
    case media(MediaEvent)
    /// Spec 5 §2 — the library changed; the connection asks again for what it holds (Spec 10 §3).
    case library(LibraryChangeEvent)
    /// Spec 2 §9, the `commands` topic — an executed command, which gives a live change its source (Spec 10 §15).
    case command([String: JSONValue])
}

/// Spec 10 §1 — "What the app shows comes from the engine's events and
/// queries (§3). It keeps no state of its own apart from its view settings
/// (§4) and the operator's selection." This is where what the engine
/// reported is kept, on the main thread, for every view to read.
///
/// Spec 10 §3, "Connecting" — "an answer reflects every event sent before
/// it: the app applies the events that arrive after an answer and drops
/// those that came before it." The store holds that rule: an event of a
/// topic the `state` query answers for is dropped until that answer has been
/// applied on this connection, and a `library` event is dropped unless its
/// revision is past the catalog's.
@MainActor
public final class ShowStore {
    /// The topics whose standing the `state` query answers with (Spec 10 §3).
    static let stateTopics: Set<String> = ["live", "channels", "outputs", "audio", "popups", "timers"]

    // MARK: What the engine reported

    /// The engine this was read from; nil until a `hello`, and kept while the engine is away.
    public private(set) var hello: Hello?
    /// Spec 10 §2 — "While it's away, the library stays browsable as the app
    /// last read it, every control that sends something is disabled".
    public private(set) var isConnected = false
    public private(set) var live = LiveStatus()
    public private(set) var channels: [Int: ChannelStatus] = [:]
    public private(set) var outputs: [Int: OutputStatus] = [:]
    public private(set) var stacks: [Int: StackStatus] = [:]
    public private(set) var audio: [Int: AudioStatus] = [:]
    public private(set) var popups: [Int: PopupStatus] = [:]
    public private(set) var timers: [Int: TimerStatus] = [:]
    public private(set) var history = HistoryStatus()
    public private(set) var saving = SavingStatus()
    public private(set) var engine = EngineStatus()
    public private(set) var devices: DetectedDevices?
    /// Spec 4 §13 — the last `MetricsSnapshot`, as it came; the output details read their counts from it (Spec 10 §8).
    public private(set) var metrics: [String: JSONValue]?
    public private(set) var catalog: Catalog?
    /// The lists the app holds whole, by uuid: those of the browsed and the live contexts (Area 13 reading of §3).
    public private(set) var lists: [String: ListDocument] = [:]
    /// Both indexes' entries, in the engine's order.
    public private(set) var media: [MediaItem] = []
    /// Cue thumbnails' files, relative to the machine root, by list uuid and cue uuid.
    public private(set) var thumbnails: [String: [String: String]] = [:]
    /// What couldn't be read, newest last, for the log; never shown as a failure of the show.
    public private(set) var issues: [String] = []

    // MARK: When it arrived

    /// When the live status arrived, on the app's clock: the armed countdown counts from here (Spec 7 §6).
    public private(set) var liveAt: TimeInterval = 0
    /// When each channel's status arrived: remaining time counts from here between the once-a-second events (Spec 10 §3).
    public private(set) var channelAt: [Int: TimeInterval] = [:]
    public private(set) var popupAt: [Int: TimeInterval] = [:]
    public private(set) var timerAt: [Int: TimeInterval] = [:]

    // MARK: In step with the connection

    /// Whether the `state` answer of this connection has been applied.
    public private(set) var hasState = false
    public private(set) var hasMedia = false

    private var observers: [Int: (Set<StoreChange>) -> Void] = [:]
    private var momentObservers: [Int: (StoreMoment) -> Void] = [:]
    private var nextObserver = 0

    public init() {}

    // MARK: - Observing

    /// Calls `handler` after every change, with what changed. The returned number ends it.
    @discardableResult
    public func observe(_ handler: @escaping (Set<StoreChange>) -> Void) -> Int {
        nextObserver += 1
        observers[nextObserver] = handler
        return nextObserver
    }

    /// Calls `handler` with each moment as it happens.
    @discardableResult
    public func observeMoments(_ handler: @escaping (StoreMoment) -> Void) -> Int {
        nextObserver += 1
        momentObservers[nextObserver] = handler
        return nextObserver
    }

    public func stopObserving(_ token: Int) {
        observers[token] = nil
        momentObservers[token] = nil
    }

    private func changed(_ changes: Set<StoreChange>) {
        guard !changes.isEmpty else { return }
        for key in observers.keys.sorted() { observers[key]?(changes) }
    }

    private func happened(_ moment: StoreMoment) {
        for key in momentObservers.keys.sorted() { momentObservers[key]?(moment) }
    }

    private func note(_ issue: String) {
        issues.append(issue)
        if issues.count > 200 { issues.removeFirst(issues.count - 200) }
    }

    // MARK: - The connection

    /// A connection to an engine opened with this `hello`. Nothing it sent
    /// before its `state` answer counts, so the store is out of step until
    /// that answer; what the last engine reported stays on show meanwhile.
    public func connected(_ hello: Hello) {
        self.hello = hello
        isConnected = true
        hasState = false
        hasMedia = false
        changed([.connection])
    }

    /// The engine has gone. What it last reported stays, so "the library
    /// stays browsable as the app last read it" (Spec 10 §2).
    public func disconnected() {
        guard isConnected else { return }
        isConnected = false
        hasState = false
        hasMedia = false
        changed([.connection])
    }

    // MARK: - Events (Spec 10 §3, "Topics")

    /// Applies one event that arrived at `now` on the app's clock.
    public func apply(event topic: String, _ fields: [String: JSONValue], now: TimeInterval) {
        if Self.stateTopics.contains(topic), !hasState { return }
        switch topic {
        case "live":
            guard let status = LiveStatus(event: fields) else { return note("a live event couldn't be read") }
            applyLive(status, now: now)
            if let reset = LiveStatus.boundaryReset(in: fields) { happened(.boundary(reset: reset)) }
        case "channels":
            guard let status = ChannelStatus(event: fields) else { return note("a channels event couldn't be read") }
            channels[status.number] = status
            channelAt[status.number] = now
            changed([.channels])
            if let moment = ChannelMoment(event: fields) { happened(.channel(moment)) }
        case "outputs":
            if let output = OutputStatus(event: fields) {
                outputs[output.number] = output
                changed([.outputs])
            } else if let stack = StackStatus(event: fields) {
                stacks[stack.number] = stack
                changed([.stacks])
            } else {
                note("an outputs event couldn't be read")
            }
        case "audio":
            guard let status = AudioStatus(event: fields) else { return note("an audio event couldn't be read") }
            audio[status.number] = status
            changed([.audio])
        case "popups":
            guard let status = PopupStatus(event: fields) else { return note("a popups event couldn't be read") }
            popups[status.slot] = status
            popupAt[status.slot] = now
            changed([.popups])
        case "timers":
            guard let status = TimerStatus(event: fields) else { return note("a timers event couldn't be read") }
            timers[status.slot] = status
            timerAt[status.slot] = now
            changed([.timers])
        case "history":
            guard let status = HistoryStatus(event: fields) else { return note("a history event couldn't be read") }
            history = status
            changed([.history])
        case "saving":
            guard let status = SavingStatus(event: fields) else { return note("a saving event couldn't be read") }
            saving = status
            changed([.saving])
        case "engine":
            if let remote = EngineStatus.remoteSources(in: fields) {
                happened(.remote(remote))
            } else if let status = EngineStatus(event: fields) {
                engine = status
                changed([.engine])
            } else {
                note("an engine event couldn't be read")
            }
        case "devices":
            guard let found = try? JSONCoding.decode(DetectedDevices.self, from: .object(fields)) else { return note("a devices event couldn't be read") }
            devices = found
            changed([.devices])
        case "metrics":
            metrics = fields
            changed([.metrics])
        case "library":
            guard let event = LibraryChangeEvent(event: fields) else { return note("a library event couldn't be read") }
            // The catalog the app holds already reflects every revision up to its own.
            if let catalog, event.rev <= catalog.rev { return }
            happened(.library(event))
        case "media":
            guard let event = MediaEvent(event: fields) else { return note("a media event couldn't be read") }
            if event.op == "missing", hasMedia, let id = event.id, let missing = event.missing, let index = media.firstIndex(where: { $0.id == id }) {
                // A deleted item stays deleted; its file coming or going is what this says.
                if !media[index].isDeleted {
                    media[index].presence = missing ? "missing" : "ok"
                    changed([.media])
                }
            }
            happened(.media(event))
        case "thumbnails":
            guard let event = ThumbnailEvent(event: fields) else { return note("a thumbnails event couldn't be read") }
            switch event {
            case .cue(_, let list, let cue, let file):
                thumbnails[list, default: [:]][cue] = file
                changed([.thumbnails])
            case .tile(let id, let file):
                if let index = media.firstIndex(where: { $0.id == id }) {
                    media[index].tile = file
                    changed([.media])
                }
            }
        case "commands":
            happened(.command(fields))
        default:
            note("an event of the unknown topic \(topic)")
        }
    }

    private func applyLive(_ status: LiveStatus, now: TimeInterval) {
        live = status
        liveAt = now
        changed([.live])
    }

    // MARK: - Answers (Spec 10 §3, "Queries")

    /// Spec 10 §3, `state` — "the timers, and the `live`, `channels`,
    /// `popups`, `outputs` and `audio` events as their topics would send them
    /// now". From here on this connection's events of those topics count.
    public func apply(state answer: [String: JSONValue], now: TimeInterval) {
        hasState = true
        channels = [:]
        outputs = [:]
        stacks = [:]
        audio = [:]
        popups = [:]
        timers = [:]
        live = LiveStatus()
        channelAt = [:]
        popupAt = [:]
        timerAt = [:]
        for value in (answer.items("events") ?? []) + (answer.items("timers") ?? []) {
            guard let fields = value.objectValue, let topic = fields.text("topic") else { continue }
            // The standing alone: nothing in an answer is a moment.
            switch topic {
            case "live": if let status = LiveStatus(event: fields) { live = status; liveAt = now }
            case "channels": if let status = ChannelStatus(event: fields) { channels[status.number] = status; channelAt[status.number] = now }
            case "outputs":
                if let output = OutputStatus(event: fields) { outputs[output.number] = output }
                else if let stack = StackStatus(event: fields) { stacks[stack.number] = stack }
            case "audio": if let status = AudioStatus(event: fields) { audio[status.number] = status }
            case "popups": if let status = PopupStatus(event: fields) { popups[status.slot] = status; popupAt[status.slot] = now }
            case "timers": if let status = TimerStatus(event: fields) { timers[status.slot] = status; timerAt[status.slot] = now }
            default: break
            }
        }
        changed([.live, .channels, .outputs, .stacks, .audio, .popups, .timers])
    }

    /// Spec 10 §3, `catalog`.
    public func apply(catalog answer: [String: JSONValue]) {
        guard let read = Catalog(answer: answer) else { return note("the catalog couldn't be read") }
        for issue in read.issues { note(issue) }
        catalog = read
        // A list the library no longer has isn't held any more.
        let known = Set(read.lists.map(\.uuid))
        lists = lists.filter { known.contains($0.key) }
        thumbnails = thumbnails.filter { known.contains($0.key) }
        changed([.catalog, .lists])
    }

    /// Spec 10 §3, `list` — one list whole, held from here on.
    public func apply(list answer: [String: JSONValue]) {
        guard let document = ListDocument(answer: answer) else { return note("a list couldn't be read") }
        lists[document.uuid] = document
        changed([.lists])
    }

    /// The app no longer shows this list, so it needn't be held.
    public func drop(list uuid: String) {
        guard lists.removeValue(forKey: uuid) != nil else { return }
        thumbnails[uuid] = nil
        changed([.lists])
    }

    /// Spec 10 §3, `media`.
    public func apply(media answer: [String: JSONValue]) {
        let read = MediaItem.items(answer: answer)
        for issue in read.issues { note(issue) }
        media = read.items
        hasMedia = true
        changed([.media])
    }

    /// Spec 10 §3, `thumbnails` — a list's cue thumbnails as they stand; a
    /// `thumbnails` event follows each one the engine still has to draw.
    public func apply(thumbnails answer: [String: JSONValue], list uuid: String) {
        thumbnails[uuid] = CueThumbnails(answer: answer).files
        changed([.thumbnails])
    }

    // MARK: - What a view asks

    /// Spec 10 §1 — "An action the app can't take now, because the engine is
    /// away, the lock is on or the library is read-only, shows disabled with
    /// the reason." Why nothing can be sent, or nil when it can.
    public var cannotSend: Unavailable? {
        isConnected && hasState ? nil : .engineAway
    }

    /// Why the library can't be edited, or nil when it can (Spec 10 §10):
    /// "All of them are refused under the lock (§12), and edits to masters on
    /// a `readOnlyMasters` machine (Spec 5 §7); the app disables them in both
    /// cases with the reason."
    public func cannotEdit(master: Bool) -> Unavailable? {
        if let away = cannotSend { return away }
        if engine.lock { return .locked }
        if master, catalog?.mastersAreReadOnly == true { return .readOnlyMasters }
        return nil
    }
}

/// Spec 10 §1 — why a control is disabled; each has one sentence in the string catalog.
public enum Unavailable: String, Equatable, Sendable {
    case engineAway
    case locked
    case readOnlyMasters
}
