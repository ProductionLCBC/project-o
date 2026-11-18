// OApp — Spec 10 §3, "Connecting": one connection's conversation with the engine.

import Foundation
import OCore

/// Spec 10 §3, "Connecting" — "The app subscribes to every topic below that
/// it uses, then asks for `state`, `catalog` and `media` (queries, below).
/// ... After each `library` event (Spec 5 §2), the app asks again for the
/// documents the event names that it holds."
///
/// One session is one connection that has said `hello`. It gives each
/// request's reply back to whoever asked, feeds the store, and asks again
/// when the library changes. It lives on the main thread; the connection's
/// own thread hands it each message in order (`receive`).
@MainActor
public final class EngineSession {
    /// Spec 10 §3 — the topics the app uses, and `commands`, which gives a
    /// live change its source for the announcements of §15 (Area 13 reading:
    /// the `live` event carries none).
    public static let topics = ["live", "channels", "outputs", "audio", "popups", "timers", "library", "media", "history", "saving",
                                "thumbnails", "engine", "devices", "metrics", "commands"]

    public let hello: Hello
    private let link: EngineLink
    private let store: ShowStore
    private let clock: any AppClock
    private var waiting: [Int: (Reply?) -> Void] = [:]
    private var open = true
    /// The queries in flight that a library change wants asked again once they answer, so a burst of edits costs
    /// one more query and not one each.
    private var asking: Set<String> = []
    private var askAgain: Set<String> = []
    /// The lists the app wants held whole, by uuid.
    private var held: Set<String> = []
    private var momentToken: Int?

    /// Called once, when the connection has gone.
    public var onClosed: (() -> Void)?
    /// Called with each line that couldn't be read, for the log.
    public var onUnknown: ((String) -> Void)?

    public init(link: EngineLink, hello: Hello, store: ShowStore, clock: any AppClock) {
        self.link = link
        self.hello = hello
        self.store = store
        self.clock = clock
    }

    /// Whether requests still go anywhere.
    public var isOpen: Bool { open }

    // MARK: - Starting

    /// Spec 10 §3 — subscribes, then asks for `state`, `catalog` and `media`.
    public func start() {
        store.connected(hello)
        momentToken = store.observeMoments { [weak self] moment in
            if case .library(let event) = moment { self?.libraryChanged(event) }
        }
        send(.subscribe(Self.topics))
        ask("state")
        ask("catalog")
        ask("media")
    }

    // MARK: - Sending

    /// Sends a request. `completion` is called on the main thread with its
    /// reply, or with nil when the connection closed first. Spec 10 §1 —
    /// "Nothing is queued to send later": once the connection has gone, the
    /// request goes nowhere and `completion` is called with nil at once.
    @discardableResult
    public func send(_ request: EngineRequest, completion: ((Reply?) -> Void)? = nil) -> Int? {
        guard open else {
            completion?(nil)
            return nil
        }
        let id = link.send(request)
        if let completion { waiting[id] = completion }
        return id
    }

    /// Closes the connection from this side.
    public func close() {
        link.close()
    }

    // MARK: - Receiving

    /// One message from the engine, in the order it arrived.
    public func receive(_ incoming: Incoming) {
        switch incoming {
        case .hello:
            // A second hello means nothing new: the session was made from the first.
            break
        case .reply(let id, let reply):
            waiting.removeValue(forKey: id)?(reply)
        case .event(let topic, let fields):
            store.apply(event: topic, fields, now: clock.now)
        case .unknown(let what):
            onUnknown?(what)
        case .closed:
            guard open else { return }
            open = false
            if let momentToken { store.stopObserving(momentToken) }
            let unanswered = waiting
            waiting = [:]
            for key in unanswered.keys.sorted() { unanswered[key]?(nil) }
            store.disconnected()
            onClosed?()
        }
    }

    // MARK: - Queries the store is fed from

    /// Asks one of the queries whose answer the store keeps: `state`,
    /// `catalog`, `media`, or `list` and `thumbnails` for a list by its
    /// uuid. While the same question is in flight, a second asking waits and
    /// is asked once when the first answers.
    private func ask(_ what: String, list uuid: String? = nil, local: Bool = false) {
        let key = uuid.map { "\(what) \($0)" } ?? what
        guard !asking.contains(key) else {
            askAgain.insert(key)
            return
        }
        asking.insert(key)
        var fields: [String: JSONValue] = [:]
        if let uuid { fields[local ? "local" : "listUuid"] = .string(uuid) }
        send(.query(what, fields)) { [weak self] reply in
            guard let self else { return }
            self.asking.remove(key)
            if let answer = reply?.answer {
                switch what {
                case "state": self.store.apply(state: answer, now: self.clock.now)
                case "catalog": self.store.apply(catalog: answer)
                case "media": self.store.apply(media: answer)
                case "list": self.store.apply(list: answer)
                case "thumbnails": if let uuid { self.store.apply(thumbnails: answer, list: uuid) }
                default: break
                }
            } else if what == "list", let uuid, reply != nil {
                // The list has gone from the library: the app holds it no longer.
                self.store.drop(list: uuid)
            }
            if self.askAgain.remove(key) != nil, self.open { self.ask(what, list: uuid, local: local) }
        }
    }

    /// Spec 10 §3 (Area 13 reading) — the lists the app holds whole are
    /// those of what the grid browses and of what is live. Asks for the ones
    /// newly wanted, with their thumbnails (Spec 10 §6: "The grid asks
    /// `thumbnails` for each list it shows"), and lets the others go.
    public func hold(lists wanted: Set<String>) {
        let dropped = held.subtracting(wanted)
        let added = wanted.subtracting(held)
        held = wanted
        for uuid in dropped.sorted() { store.drop(list: uuid) }
        for uuid in added.sorted() { askList(uuid) }
    }

    private func askList(_ uuid: String) {
        let local = store.catalog?.list(uuid: uuid)?.local ?? false
        ask("list", list: uuid, local: local)
        ask("thumbnails", list: uuid, local: local)
    }

    /// Spec 10 §3 — "After each `library` event (Spec 5 §2), the app asks
    /// again for the documents the event names that it holds." The catalog
    /// holds every summary and title, so it is asked again each time; a held
    /// list is asked again when the event names it or one of its cues; the
    /// media when the event names media. Spec 10 §6 — thumbnails "again for
    /// the cues a `library` event names": a preset, a grade or a channel
    /// redraws them without naming a cue, so every held list's are asked
    /// again unless the event names only playlists, items and folders (Area
    /// 13 reading).
    private func libraryChanged(_ event: LibraryChangeEvent) {
        ask("catalog")
        var lists: Set<String> = []
        var media = event.cause == "media"
        var looks = false
        for change in event.changed {
            switch change.object {
            case "list", "cue":
                if let uuid = change.address.text("listUuid"), held.contains(uuid) { lists.insert(uuid) }
                looks = true
            case "media":
                media = true
                looks = true
            case "playlist", "item", "folder":
                break
            default:
                looks = true
            }
        }
        // A restore or a file arriving can change anything it doesn't name one by one.
        if event.cause == "restore" || event.cause == "file" {
            lists = held
            media = true
        }
        for uuid in lists.sorted() { ask("list", list: uuid, local: store.catalog?.list(uuid: uuid)?.local ?? false) }
        if media { ask("media") }
        if looks {
            for uuid in held.sorted() { ask("thumbnails", list: uuid, local: store.catalog?.list(uuid: uuid)?.local ?? false) }
        }
    }
}
