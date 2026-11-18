// OApp — Spec 10 §14: the saving tag, the last state's banner and what it offers.

import Foundation
import OCore

/// Spec 10 §14, "The saving tag" — "amber "Unsaved (3)" when documents have
/// waited more than five seconds to be written, amber "Disk low", and red
/// "Disk full: changes not saved" with the log in memory."
public enum SavingTag: Equatable, Sendable {
    case unsaved(Int)
    case diskLow
    case diskFull

    /// "more than five seconds".
    public static let wait: TimeInterval = 5

    /// The tag that shows, or nil. `unsavedFor` is how long the engine's
    /// count has stood above zero on the app's clock. One tag shows, the
    /// worst first: a full disk, then documents waiting, then a low disk
    /// (Area 13 reading); a click lists all that stands.
    public static func make(_ saving: SavingStatus, unsavedFor seconds: TimeInterval?) -> SavingTag? {
        if saving.disk == "full" { return .diskFull }
        if saving.unsaved > 0, let seconds, seconds > wait { return .unsaved(saving.unsaved) }
        if saving.disk == "low" { return .diskLow }
        return nil
    }

    public var isRed: Bool { self == .diskFull }
}

/// Spec 10 §14 — "A click lists what is waiting": the engine's `saving`
/// topic counts the documents and doesn't name them (Spec 9 §7), so the list
/// says how many wait, how the disk stands and where the log goes.
public struct SavingDetails: Equatable, Sendable {
    public var waiting: Int
    public var disk: String
    public var logInMemory: Bool

    public init(_ saving: SavingStatus) {
        waiting = saving.unsaved
        disk = saving.disk
        logInMemory = saving.log == "memory"
    }
}

/// Spec 10 §14, "The last state" — the banner over the grid when the engine
/// put the last state back this run, or didn't and says why.
public struct RestoreBanner: Equatable, Sendable {
    /// One thing that didn't come back (Spec 9 §4).
    public struct Left: Equatable, Sendable {
        /// `channel`, `output`, `stack` or `popup`.
        public var kind: String
        public var number: Int
        /// `gone`, `clearing` or `missing`.
        public var why: String

        public init(kind: String, number: Int, why: String) {
            self.kind = kind
            self.number = number
            self.why = why
        }

        init?(_ value: JSONValue) {
            guard let members = value.objectValue, let kind = members.text("kind"), let number = members.integer("number") else { return nil }
            self.init(kind: kind, number: number, why: members.text("why") ?? "gone")
        }
    }

    public enum Kind: Equatable, Sendable {
        /// "Picked up where the engine stopped, at 09:41. Video started again from the top." With what didn't come back.
        case restored(writtenAt: String?, left: [Left])
        /// It wasn't put back, with Spec 9 §2's reason: `clean`, `old` or `restoredBefore`.
        case skipped(reason: String)
    }

    /// What the banner says of the timers, which "came back unset (Spec 6 §6)".
    public enum Timers: Equatable, Sendable {
        /// The app saw the engine end with no timer set: there is nothing to say.
        case none
        /// The app didn't see the engine end, so it can only say they came back unset.
        case unset
        /// "with Set Timers Again, which sets each timer to its last value
        /// from the `timers` topic and starts those that were running".
        case setAgain([TimerStatus])
    }

    /// "offers "Fire 3 Verse 2 again", built from the last `live` event the app saw as an ordinary fire."
    public struct FireAgain: Equatable, Sendable {
        public var number: Int
        public var label: String
        /// The fire, or why it can't be sent: "its Make Live and the restore
        /// banner's Fire Again (§14) are disabled with "Rename to fire"" (§6).
        public var sending: Sending?
        public var refusal: FireRefusal?
    }

    public var kind: Kind
    public var timers = Timers.none
    public var fireAgain: FireAgain?

    /// What the app saw of the engine that ended, if it saw one end this run.
    public struct LastSeen: Equatable, Sendable {
        public var live: LiveStatus
        public var timers: [TimerStatus]

        public init(live: LiveStatus, timers: [TimerStatus]) {
            self.live = live
            self.timers = timers
        }
    }

    /// The banner for this run's last state, or nil when the engine reports
    /// none or the banner was dismissed for this run: "Dismissed, it stays
    /// away for that run (§4)."
    public static func make(engine: EngineStatus, dismissedRun: String?, lastSeen: LastSeen?, catalog: Catalog?, live: LiveStatus) -> RestoreBanner? {
        guard let state = engine.lastState, !engine.run.isEmpty, engine.run != dismissedRun else { return nil }
        switch state {
        case .restored(let writtenAt, let left):
            var banner = RestoreBanner(kind: .restored(writtenAt: writtenAt, left: left.compactMap(Left.init)))
            if let lastSeen {
                let set = lastSeen.timers.filter { $0.state != "unset" && ($0.valueMs ?? $0.setMs) != nil }.sorted { $0.slot < $1.slot }
                banner.timers = set.isEmpty ? .none : .setAgain(set)
            } else {
                banner.timers = .unset
            }
            return banner
        case .skipped(let reason, _):
            var banner = RestoreBanner(kind: .skipped(reason: reason))
            if let seen = lastSeen?.live, let catalog { banner.fireAgain = fireAgain(seen, catalog: catalog, live: live) }
            return banner
        }
    }

    /// "built from the last `live` event the app saw as an ordinary fire":
    /// the cue it named, in its playlist or its library list, as a press on
    /// its cell would fire it now. Nil when no cue had fired, or what it
    /// named is gone.
    static func fireAgain(_ seen: LiveStatus, catalog: Catalog, live: LiveStatus) -> FireAgain? {
        guard seen.cue != nil, seen.cuePosition > 0 else { return nil }
        let fire: Result<Sending, FireRefusal>
        if let uuid = seen.playlist {
            guard let playlist = catalog.playlist(uuid: uuid), seen.itemPosition > 0 else { return nil }
            fire = GridFire.playlistCue(playlist, item: seen.itemPosition, cue: seen.cuePosition, live: live)
        } else if let uuid = seen.listUuid {
            guard let list = catalog.list(uuid: uuid) else { return nil }
            fire = GridFire.libraryCue(list, cue: seen.cuePosition)
        } else {
            return nil
        }
        switch fire {
        case .success(let sending): return FireAgain(number: seen.cuePosition, label: seen.label, sending: sending, refusal: nil)
        case .failure(let refusal): return FireAgain(number: seen.cuePosition, label: seen.label, sending: nil, refusal: refusal)
        }
    }
}

extension WindowPlacement {
    /// A rectangle on the Mac's screens.
    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        func contains(x px: Double, y py: Double) -> Bool {
            px >= x && px <= x + width && py >= y && py <= y + height
        }
    }

    /// Spec 10 §4, "View settings" — "the window's frame": where the window
    /// opens, from the frame `view.json` holds, or nil for where it would
    /// open anyway. The saved frame is taken when the middle of its title
    /// bar lies on a screen this Mac has now, so the window can always be
    /// reached, and it is never smaller than the window may be (Area 13
    /// reading). Whether that screen is an output's is §4's other rule,
    /// which moves the window afterwards.
    public static func restored(_ saved: [Double]?, screens: [Rect], minimum: (width: Double, height: Double)) -> Rect? {
        guard let saved, saved.count == 4 else { return nil }
        let frame = Rect(x: saved[0], y: saved[1], width: max(saved[2], minimum.width), height: max(saved[3], minimum.height))
        // AppKit's y grows upward: the title bar is at the frame's top.
        let titleX = frame.x + frame.width / 2
        let titleY = frame.y + frame.height - 10
        return screens.contains { $0.contains(x: titleX, y: titleY) } ? frame : nil
    }
}
