// OEngine — Spec 10 §3, the `engine`, `thumbnails` and `metrics` topics.

import Foundation
import OCore

/// Spec 10 §3, the `engine` topic — "The run; the lock and whether a
/// passcode is set (§12); the LAN listener's state (`open`, `closed` or
/// `waiting`) and client count; the last state this run, put back with what
/// didn't come back, or skipped with Spec 9 §2's reason; and badges. Also
/// remote activity", sent "On subscribe and on change; remote activity at
/// most ten times a second".
///
/// Control side, once a build. The standing event is kept as the topic's
/// current value, so a new subscriber gets it at once; `remote` is an event
/// of its own and is never kept.
final class ApiStatus {
    /// Spec 10 §3 — a `watchdog` or `gpu` badge stands for "a recovery or a
    /// device reset within the last five minutes".
    static let recentNanoseconds: Int64 = 300 * 1_000_000_000
    /// "remote activity at most ten times a second".
    static let remoteIntervalNanoseconds: Int64 = 100_000_000
    /// Spec 10 §3 — `remote` "lists the sources of the commands that arrived
    /// from outside the app ...: `osc`, `api`, `midi`, `streamdeck`".
    static let remoteSources: Set<SourceKind> = [.osc, .api, .midi, .streamdeck]

    private var standing: JSONValue?
    private var watchdogRecoveries = 0
    private var watchdogAt: Int64?
    private var gpuFailures: Int64 = 0
    private var gpuAt: Int64?
    private var remote: Set<String> = []
    private var remoteAt: Int64 = .min
    private var tiles: Set<String>?
    private var metricsSecond: Int64 = -1

    func publish(engine: Engine, snapshot: ApiSnapshot, now: MonotonicTime) {
        let control = engine.control
        let publisher = engine.publisher

        // Badges that stand for something recent: remember when it happened.
        let recoveries = engine.watchdog.recoveries
        if recoveries > watchdogRecoveries { watchdogAt = now.nanoseconds }
        watchdogRecoveries = recoveries
        let failures = engine.render.gpuFailures
        if failures > gpuFailures { gpuAt = now.nanoseconds }
        gpuFailures = failures

        var badges: [JSONValue] = []
        func badge(_ kind: String, level: String? = nil) {
            var members: [String: JSONValue] = ["kind": .string(kind)]
            if let level { members["level"] = .string(level) }
            badges.append(.object(members))
        }
        // "`thermal` (serious or critical), `memory` (warning or critical pressure), `watchdog` or `gpu` ..., `clock`
        // (running on a fallback clock, Spec 4 §2) or `keychain` (an item can't be read, §12)".
        let thermal = engine.thermal.level
        if thermal == .serious || thermal == .critical { badge("thermal", level: thermal.rawValue) }
        let memory = engine.pressure.level
        if memory == .warning || memory == .critical { badge("memory", level: memory.rawValue) }
        if let at = watchdogAt, now.nanoseconds - at <= Self.recentNanoseconds { badge("watchdog") }
        if let at = gpuAt, now.nanoseconds - at <= Self.recentNanoseconds { badge("gpu") }
        if let scheduler = engine.scheduler, scheduler.activeClock !== engine.clock { badge("clock") }
        var lan = engine.api.lan
        if lan.keychainUnreadable { badge("keychain") }
        // Spec 10 §2 — "the engine retries a refused registration or send every few seconds, and the `engine` topic
        // shows the LAN as waiting meanwhile": a listener that is open while OSC sends are held back is waiting too.
        if lan.state == .open, engine.oscRefused?() == true { lan.state = .waiting }

        let lastState: JSONValue
        switch engine.launchReport?.lastState {
        case .restored(let writtenAt, let left):
            lastState = .object(["restored": .bool(true), "writtenAt": writtenAt.map(JSONValue.string) ?? .null, "left": .array(left.map(\.json))])
        case .skipped(let reason, let writtenAt):
            lastState = .object(["restored": .bool(false), "reason": .string(reason.rawValue), "writtenAt": writtenAt.map(JSONValue.string) ?? .null])
        case .some(.none), nil:
            lastState = .null
        }

        let fields: [String: JSONValue] = [
            "run": .string(engine.run.uuidString.lowercased()),
            "lock": .bool(snapshot.machine.settings.operatorLock.enabled),
            // Spec 10 §12 — the passcode's Keychain item is Area 18's; until then none is set.
            "passcode": .bool(false),
            "lan": .object(["state": .string(lan.state.rawValue), "clients": .number(Double(lan.clients))]),
            "lastState": lastState,
            "badges": .array(badges),
        ]
        let facts = JSONValue.object(fields)
        if standing != facts {
            standing = facts
            publisher.publish(current: ApiEvents.event("engine", fields, seq: snapshot.seq))
        }

        // "remote activity": the sources of what arrived from outside the app, coalesced.
        for result in control.lastResults {
            if let kind = result.lines.first?.executed.source.kind, Self.remoteSources.contains(kind) { remote.insert(kind.rawValue) }
        }
        for rejected in control.lastRejected where Self.remoteSources.contains(rejected.source.kind) { remote.insert(rejected.source.kind.rawValue) }
        if !remote.isEmpty, remoteAt == .min || now.nanoseconds - remoteAt >= Self.remoteIntervalNanoseconds {
            publisher.publish(ApiEvents.event("engine", ["remote": .array(remote.sorted().map(JSONValue.string))], seq: snapshot.seq))
            remote = []
            remoteAt = now.nanoseconds
        }

        // Spec 10 §3, `thumbnails` — "a pool tile written, with its id and file".
        if let known = tiles {
            let written = snapshot.mediaTiles.subtracting(known)
            if !written.isEmpty, let folder = snapshot.tilesFolder {
                let entries = snapshot.library.mediaIndex.entries + snapshot.machine.mediaLocal.entries
                for entry in entries {
                    guard let name = MediaPosters.tileName(of: entry), written.contains(name) else { continue }
                    publisher.publish(ApiEvents.event("thumbnails", ["id": .string(entry.id),
                                                                     "file": .string(ApiQueries.relative(folder.appendingPathComponent(name), to: engine.machineRoot))],
                                                      seq: snapshot.seq))
                }
            }
        }
        tiles = snapshot.mediaTiles

        // Spec 4 §13 — the `metrics` topic, "Once a second", while someone listens; worked out off the control thread.
        let second = snapshot.rate.num > 0 ? snapshot.frame * Int64(snapshot.rate.den) / Int64(snapshot.rate.num) : 0
        if second != metricsSecond {
            metricsSecond = second
            if let source = engine.metricsSource, !engine.api.subscribers(of: "metrics").isEmpty {
                let seq = snapshot.seq
                engine.api.workers.async {
                    guard case .object(let members)? = try? JSONCoding.encode(source()) else { return }
                    publisher.publish(ApiEvents.event("metrics", members, seq: seq))
                }
            }
        }
    }
}

/// Spec 10 §2 — the LAN listener as the `engine` topic reports it: "Until it
/// has the token, the LAN listener stays closed and the `engine` topic says
/// so"; "the `engine` topic shows the LAN as waiting meanwhile".
public struct LanStanding: Equatable, Sendable {
    public enum State: String, Sendable {
        case open
        case closed
        case waiting
    }

    public var state: State = .closed
    public var clients = 0
    /// Spec 10 §3 — the `keychain` badge: "an item can't be read".
    public var keychainUnreadable = false

    public init() {}
}
