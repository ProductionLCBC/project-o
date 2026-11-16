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

// MARK: - When it comes back (Spec 9 §4, choice G-1)

extension LastState {
    /// Spec 9 §2 — `lastStateSkipped`'s `reason`: "`clean`, `old` or `restoredBefore`".
    public enum SkipReason: String, Equatable, Sendable {
        /// The run that wrote it ended cleanly.
        case clean
        /// It wasn't written within the last two hours.
        case old
        /// The engine stopped within a minute of putting it back.
        case restoredBefore
    }

    /// What a launch does with the last state.
    public enum Decision: Equatable, Sendable {
        /// Put it back.
        case restore
        /// Start empty, and say why in a `lastStateSkipped` note.
        case skip(SkipReason)
        /// Start empty with nothing to say: the setting is off and the launch
        /// isn't a relaunch, or there is no file.
        case none
    }

    /// Spec 9 §4 — "it was written less than two hours ago, so the run was alive then".
    public static let restoreLimitMs: Int64 = 2 * 60 * 60 * 1000

    /// Spec 9 §4 — "At launch, with `restoreLastState` on, or at a relaunch
    /// whatever it says (...Spec 10 §2), the engine restores the last state
    /// when all three hold: its run didn't end cleanly; it was written less
    /// than two hours ago, so the run was alive then; and it isn't `restored:
    /// true` ... Otherwise the launch starts empty, and a `lastStateSkipped`
    /// note says why." The first of the three that fails is the reason.
    /// `nowMs` is the wall clock, in milliseconds since 1970, from the caller:
    /// nothing here reads a clock.
    ///
    /// A file that doesn't say when it was written can't be shown to be
    /// recent (`old`); one that doesn't say it ended cleanly, or that it was
    /// put back, is taken at its word.
    public static func decide(_ last: LastState?, restoreLastState: Bool, relaunch: Bool, nowMs: Int64) -> Decision {
        guard restoreLastState || relaunch, let last else { return .none }
        if last.clean == true { return .skip(.clean) }
        guard let written = last.writtenAt.flatMap(CivilTime.milliseconds), abs(nowMs - written) < restoreLimitMs else {
            return .skip(.old)
        }
        if last.restored == true { return .skip(.restoredBefore) }
        return .restore
    }
}

// MARK: - Which launch is a relaunch (Spec 10 §2, choice U-14)

extension LastState {
    /// Spec 10 §2, "What a relaunch brings back" — "A launch is a relaunch
    /// when the app says so with `--relaunch`, having seen the engine end or
    /// ended it itself, or when the run before it ended without a stop in
    /// this boot of the Mac: `state/last.json` says `clean: false` and was
    /// written after the Mac started. The flag covers a full disk, which
    /// removes that file (Spec 9 §7)."
    ///
    /// `bootedAtMs` is when the Mac started, in milliseconds since 1970, from
    /// the caller; nil when it isn't known, and then only the flag makes a
    /// relaunch. A file that doesn't say it ended cleanly counts as not clean,
    /// as it does for the restore (Spec 9 §4, Area 12's reading); one that
    /// doesn't say when it was written can't be shown to be of this boot.
    public static func isRelaunch(flagged: Bool, last: LastState?, bootedAtMs: Int64?) -> Bool {
        if flagged { return true }
        guard let last, last.clean != true, let bootedAtMs, let written = last.writtenAt.flatMap(CivilTime.milliseconds) else { return false }
        return written > bootedAtMs
    }
}

// MARK: - What comes back (Spec 9 §4)

extension LastState {
    /// Spec 9 §2 — one entry of `lastStateRestored`'s `left`, "what didn't
    /// come back": a channel, an output, a stack or a popup slot by its
    /// number, and why. A channel whose media came back missing names the
    /// media too.
    public struct Left: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case channel, output, stack, popup
        }

        public enum Why: String, Equatable, Sendable {
            /// The library or the machine no longer has it.
            case gone
            /// A popup with a clear-after still counting: "they were on their way off".
            case clearing
            /// The content came back, as missing: no index knows its media, or its file isn't there.
            case missing
        }

        public var kind: Kind
        public var number: Int
        public var why: Why
        public var media: String?

        public init(kind: Kind, number: Int, why: Why, media: String? = nil) {
            self.kind = kind
            self.number = number
            self.why = why
            self.media = media
        }

        /// The entry as the note writes it: `{ "channel": 9, "why": "gone" }`.
        public var json: JSONValue {
            var members: [String: JSONValue] = [kind.rawValue: .number(Double(number)), "why": .string(why.rawValue)]
            if let media { members["media"] = .string(media) }
            return .object(members)
        }
    }

    /// The state a restore puts back, and what it left out.
    public struct Restored: Equatable, Sendable {
        public var state: ShowState
        public var left: [Left]
    }

    /// Spec 9 §4 — "What comes back, the way Spec 3 §8 replaces ShowState":
    /// the saved state against the library and the machine as they are now,
    /// for the engine frame of the restore.
    ///
    /// - "Content and tracked attributes with their origins, outputs on their
    ///   stacks, stacks with their blackout and muted channels, and locks
    ///   (choice G-3)."
    /// - "Popups with their text, apart from those with a pending clear-after".
    /// - "The pointer, as it was saved, whatever its shape".
    /// - "Video and audio start again from their in-points: `startedAtFrame`
    ///   is the frame of the restore, and the transport is as it was."
    /// - "every restored channel's provenance is `restored` keeping its cue
    ///   and list, and outgoing instances are dropped." (A channel that is
    ///   empty and that nothing wrote has none to keep.)
    /// - "`armed` is cleared."
    /// - "A channel the library no longer has is left out, and content whose
    ///   media no index knows, or whose file isn't there, comes back missing."
    ///   An output, a stack or a popup slot the machine no longer has is left
    ///   out the same way.
    ///
    /// `missing` is the engine's set of ids whose files aren't there (Spec 8
    /// §2), where a file at its location counts as present "without waiting
    /// for the walk to hash it". What the saved state doesn't mention starts
    /// as a fresh launch has it (Spec 3 §2).
    public func restored(library: Library, machine: Machine, frame: Int, missing: Set<String>) -> Restored {
        var out = ShowState.fresh(library: library, machine: machine)
        var left: [Left] = []

        /// Spec 3 §4's flag, with Spec 9 §4's "no index knows".
        func isMissing(_ ref: String) -> Bool {
            let chain = MediaResolver.chain(from: ref, library: library.mediaIndex, machine: machine.mediaLocal)
            guard let entry = MediaResolver.entry(for: chain.reached, library: library.mediaIndex, machine: machine.mediaLocal)?.entry else {
                return true
            }
            return entry.isDeleted || missing.contains(chain.reached)
        }

        for number in state.channels.keys.sorted() {
            guard var channel = state.channels[number] else { continue }
            guard out.channels[number] != nil else {
                left.append(Left(kind: .channel, number: number, why: .gone))
                continue
            }
            let written = channel.provenance != nil || !channel.content.isEmpty
            switch channel.content {
            case .media(var media):
                media.startedAtFrame = frame
                media.missing = isMissing(media.ref)
                if media.missing { left.append(Left(kind: .channel, number: number, why: .missing, media: media.ref)) }
                channel.content = .media(media)
            case .slide(var slide):
                slide.missing = isMissing(slide.ref)
                if slide.missing { left.append(Left(kind: .channel, number: number, why: .missing, media: slide.ref)) }
                channel.content = .slide(slide)
            case .empty, .text, .input:
                break
            }
            channel.outgoing = []
            if written { channel.provenance = .restored(from: channel.provenance) }
            out.channels[number] = channel
        }

        var goneStacks: Set<Int> = []
        for output in state.outputs.keys.sorted() {
            guard let stack = state.outputs[output] else { continue }
            guard out.outputs[output] != nil else {
                left.append(Left(kind: .output, number: output, why: .gone))
                continue
            }
            // An output whose stack is gone stays on its default.
            if out.stacks[stack] != nil { out.outputs[output] = stack } else { goneStacks.insert(stack) }
        }
        for stack in state.stacks.keys.sorted() {
            guard let saved = state.stacks[stack] else { continue }
            if out.stacks[stack] != nil { out.stacks[stack] = saved } else { goneStacks.insert(stack) }
        }
        for stack in goneStacks.sorted() { left.append(Left(kind: .stack, number: stack, why: .gone)) }

        let clearing = Set(pendingClears)
        for slot in state.popups.keys.sorted() {
            guard let text = state.popups[slot] else { continue }
            if clearing.contains(slot) {
                left.append(Left(kind: .popup, number: slot, why: .clearing))
            } else if slot < 1 || slot > machine.settings.popups {
                left.append(Left(kind: .popup, number: slot, why: .gone))
            } else {
                out.popups[slot] = text
            }
        }

        out.pointer = state.pointer
        out.armed = nil
        return Restored(state: out, left: left)
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
