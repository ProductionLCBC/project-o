// OCore — Spec 9 §4, `state/last.json`: the last state and the facts of the run that wrote it.

import Foundation

/// Spec 9 §4 — "`machine/state/last.json` holds ShowState (Spec 3 §2) as the
/// engine last projected it, and some facts about the run that wrote it":
///
/// ```json
/// { "schema": 1, "app": "0.1.0", "kind": "state", "writtenAt": "2026-11-08T09:41:07.002-05:00",
///   "run": "51e2…", "clean": false, "restored": false, "pendingClears": [3],
///   "state": { … } }
/// ```
///
/// "The new keys are optional, so the fixture's file reads as before": a fact
/// the file doesn't give, or gives in another shape, is nil here, and the
/// pending clears are then none. The engine writes every one of them.
public struct LastState: Equatable, Sendable {
    /// Spec 9 §4 — when the file was written, so it "says when the run was
    /// last alive, not when the last cue was fired".
    public var writtenAt: String?
    /// Spec 9 §4 — the uuid of the run that wrote it.
    public var run: UUID?
    /// Spec 9 §4 — `true` only when the engine stopped on request, after the
    /// shutdown macro; "A crash, a power cut or a force quit leaves `clean: false`."
    public var clean: Bool?
    /// Spec 9 §4 — "`restored` stays `true` for the first minute after a
    /// restore, whatever runs in it, and is `false` after that."
    public var restored: Bool?
    /// Spec 9 §4 — "`pendingClears` lists the popup slots with a clear-after
    /// still counting (Spec 6 §7)", in slot order.
    public var pendingClears: [Int]
    public var state: ShowState

    public init(writtenAt: String? = nil, run: UUID? = nil, clean: Bool? = nil, restored: Bool? = nil,
                pendingClears: [Int] = [], state: ShowState) {
        self.writtenAt = writtenAt
        self.run = run
        self.clean = clean
        self.restored = restored
        self.pendingClears = pendingClears.sorted()
        self.state = state
    }

    /// The file as the loader read it: its `state`, and the other members of
    /// the document (Spec 1 §8 keeps them beside it).
    public init(state: ShowState, members: [String: JSONValue]) {
        self.state = state
        writtenAt = members["writtenAt"]?.stringValue
        run = members["run"]?.stringValue.flatMap(UUID.init(uuidString:))
        clean = members["clean"]?.boolValue
        restored = members["restored"]?.boolValue
        pendingClears = (members["pendingClears"]?.arrayValue ?? []).compactMap(\.intValue).sorted()
    }

    /// The members the file carries beside its header and its `state`: every
    /// fact that is known, and the pending clears.
    public var members: [String: JSONValue] {
        var out: [String: JSONValue] = ["pendingClears": .array(pendingClears.sorted().map { .number(Double($0)) })]
        if let writtenAt { out["writtenAt"] = .string(writtenAt) }
        if let run { out["run"] = .string(run.uuidString.lowercased()) }
        if let clean { out["clean"] = .bool(clean) }
        if let restored { out["restored"] = .bool(restored) }
        return out
    }

    /// Spec 9 §4 — the file's bytes, as every document is written (Spec 1 §5:
    /// the header, sorted keys, two-space indent, LF). "Every write is atomic",
    /// which is the writer's part.
    public var data: Data {
        Writer.data(for: .state(state), extras: members)
    }
}

extension Machine {
    /// Spec 9 §4 — `state/last.json` as it was loaded, with the facts of the
    /// run that wrote it; nil when the machine root has no such file.
    public var last: LastState? {
        guard let state = lastState else { return nil }
        return LastState(state: state, members: documentExtras[.state] ?? [:])
    }
}
