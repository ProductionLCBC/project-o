// OCore — Spec 7 §6, the live position and the countdown as feedback.

import Foundation

/// Spec 7 §6 — one reading of where the show is, for consoles and clients:
/// "the live item's or cue's number, the playlist's title or the cue's
/// label, a removal of what the pointer names, or a countdown". Positions
/// are "as they are now, not as they were when the cue fired". It drives
/// `/o/live/playlist`, `/o/live/item`, `/o/live/cue`, `/o/live/label`,
/// `/o/live/armed`, `/o/query` at those addresses, and the `live` event.
public struct LiveSnapshot: Equatable, Sendable {
    /// The pointer's handles: "a list by number, everything else by uuid".
    public var playlist: UUID?
    public var item: UUID?
    public var list: Int?
    public var listUuid: UUID?
    public var cue: UUID?
    /// "`/o/live/playlist` sends the playlist's title, or an empty string when
    /// none is loaded"; the kept copy's once it is gone.
    public var playlistTitle: String
    /// Spec 10 §3 — the list's title, from the kept copy once it is gone.
    public var listTitle: String
    /// "While the live item is gone and its song finishes, `/o/live/item`
    /// sends 0, as for a library list"; 0 before a cue fires.
    public var itemPosition: Int
    /// "When the live cue is gone, `/o/live/cue` sends the number of the cue
    /// just before its place, or 0 at the top"; 0 before a cue fires.
    public var cuePosition: Int
    /// The live cue's label, or that cue's label once it is gone; empty
    /// before a cue fires.
    public var label: String
    /// "`gone` lists what has been removed, of `cue`, `item`, `list` and `playlist`."
    public var gone: [String]
    /// Spec 6 §5 — `[Next Title]`, the read Area 11 puts in box text.
    public var nextTitle: String?
    /// "`armed` is `null` while no trigger is live".
    public var armed: Armed?

    /// The countdown: "the positions of the cue that will fire". "`item` is 0
    /// with a library list live, and for a cue in a gone item."
    public struct Armed: Equatable, Sendable {
        public var item: UUID?
        public var cue: UUID
        public var itemPosition: Int
        public var cuePosition: Int
        public var atFrame: Int
    }

    /// Spec 7 §4 and §6 — the reading of the pointer's place, over the roots
    /// and the kept copies.
    public static func reading(state: ShowState, library: Library, machine: Machine, kept: KeptCopies) -> LiveSnapshot {
        let placer = Placer(library: library, machine: machine, kept: kept)
        var out = LiveSnapshot(playlist: state.pointer?.playlist, item: state.pointer?.itemUuid, list: nil, listUuid: state.pointer?.listUuid,
                               cue: state.pointer?.cueUuid, playlistTitle: "", listTitle: "", itemPosition: 0, cuePosition: 0, label: "",
                               gone: [], nextTitle: placer.nextTitle(from: state.pointer), armed: nil)
        let placement = placer.placement(of: state.pointer)
        switch placement {
        case .nothing:
            break
        case .loaded(let playlist):
            out.playlistTitle = playlist?.title ?? ""
        case .placed(let place):
            out.playlistTitle = place.playlist?.title ?? ""
            out.list = place.list.number
            out.listTitle = place.list.title
            out.itemPosition = place.itemPosition ?? 0
            switch place.cue {
            case .at(let index), .after(let index):
                out.cuePosition = index + 1
                out.label = index >= 0 ? place.list.cues[index].label : ""
            }
            out.gone = place.gone.names
        case .unplaceable(let list, let playlist):
            out.playlistTitle = playlist?.title ?? ""
            if let list {
                out.list = list.number
                out.listTitle = list.title
                if let index = list.cues.firstIndex(where: { $0.uuid == state.pointer?.cueUuid }) {
                    out.cuePosition = index + 1
                    out.label = list.cues[index].label
                }
            }
            if let playlist, let index = playlist.items.firstIndex(where: { $0.uuid == state.pointer?.itemUuid }) {
                out.itemPosition = index + 1
            }
        }
        if let armed = state.armed, let next = placer.next(from: state.pointer),
           next.cue.uuid == armed.cueUuid, next.itemUuid == armed.itemUuid {
            out.armed = Armed(item: armed.itemUuid, cue: armed.cueUuid, itemPosition: next.item ?? 0,
                              cuePosition: next.cueIndex + 1, atFrame: armed.atFrame)
        }
        return out
    }

    /// The milliseconds left to `armed` at `frame`, never below 0 (Spec 7 §6,
    /// "the milliseconds left when the message is sent").
    public static func inMs(_ armed: Armed, frame: Int, rate: FrameRate) -> Int {
        guard rate.num > 0 else { return 0 }
        let frames = max(0, armed.atFrame - frame)
        return (frames * 1000 * rate.den + rate.num / 2) / rate.num
    }

    // MARK: - OSC (Spec 2 §6, Spec 7 §6)

    /// `/o/live/playlist`, `/o/live/item`, `/o/live/cue`, `/o/live/label`.
    public var positionMessages: [OSCMessage] {
        [OSCFeedback.livePlaylist(playlistTitle), OSCFeedback.liveItem(itemPosition), OSCFeedback.liveCue(cuePosition),
         OSCFeedback.liveLabel(label)]
    }

    /// `/o/live/armed` "carries `i:item` `i:cue` `i:ms` ... and with no
    /// arguments when the trigger disarms, lapses or fires".
    public func armedMessage(frame: Int, rate: FrameRate) -> OSCMessage {
        guard let armed else { return OSCFeedback.liveArmed(nil) }
        return OSCFeedback.liveArmed((armed.itemPosition, armed.cuePosition, Self.inMs(armed, frame: frame, rate: rate)))
    }

    /// Spec 2 §6 — "Any client may ask for a current value with `/o/query`
    /// ... and receives the feedback message once": the live addresses, nil
    /// for any other.
    public func answer(query address: String, frame: Int, rate: FrameRate) -> OSCMessage? {
        switch address {
        case "/o/live/playlist": return OSCFeedback.livePlaylist(playlistTitle)
        case "/o/live/item": return OSCFeedback.liveItem(itemPosition)
        case "/o/live/cue": return OSCFeedback.liveCue(cuePosition)
        case "/o/live/label": return OSCFeedback.liveLabel(label)
        case "/o/live/armed": return armedMessage(frame: frame, rate: rate)
        default: return nil
        }
    }

    /// What to send after a build, given the reading last sent: Spec 7 §6 —
    /// "The engine sends them on a fire, a load, an arm and a disarm, and
    /// after any applied edit group or reload that changes what they carry:
    /// the live item's or cue's number, the playlist's title or the cue's
    /// label, a removal of what the pointer names, or a countdown that lapses
    /// or comes back." On a fire, a load or a disarm (`moved`) the four
    /// position messages go out, and `/o/live/armed` goes "empty first on a
    /// fire that used up a trigger, then for the new arming"; otherwise each
    /// goes out when what it carries changed. The `live` event goes "at the
    /// same moments", and when anything else it carries changed: a handle or
    /// the list's title (Spec 10 §3). `[Next Title]` is a box's read, not
    /// feedback.
    public static func feedback(from old: LiveSnapshot?, to new: LiveSnapshot, moved: Bool, frame: Int, rate: FrameRate)
        -> (messages: [OSCMessage], event: Bool) {
        var messages: [OSCMessage] = []
        let positionsChanged = old.map { ($0.playlistTitle, $0.itemPosition, $0.cuePosition, $0.label, $0.gone) }
            .map { $0 != (new.playlistTitle, new.itemPosition, new.cuePosition, new.label, new.gone) } ?? true
        if moved || positionsChanged { messages += new.positionMessages }
        if moved {
            if old?.armed != nil { messages.append(OSCFeedback.liveArmed(nil)) }
            if new.armed != nil { messages.append(new.armedMessage(frame: frame, rate: rate)) }
        } else if old?.armed != new.armed {
            messages.append(new.armedMessage(frame: frame, rate: rate))
        }
        var oldCarried = old
        oldCarried?.nextTitle = nil
        var newCarried = new
        newCarried.nextTitle = nil
        return (messages, !messages.isEmpty || oldCarried != newCarried)
    }

    // MARK: - The `live` event (Spec 7 §6, Spec 10 §3)

    /// "It names the pointer by both handles, in Spec 5's style (a list by
    /// number, everything else by uuid), with the positions the OSC messages
    /// send, what is gone and the armed trigger. Spec 10 §3 adds the
    /// playlist's and list's titles, the cue's label and the list boundary";
    /// `boundary` is given on a fire that entered another list, with
    /// `reset` false when that list tracks through.
    public func event(frame: Int, rate: FrameRate, seq: Int, boundary: Bool? = nil) -> JSONValue {
        func uuid(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
        var members: [String: JSONValue] = [
            "type": .string("event"), "topic": .string("live"),
            "playlist": uuid(playlist), "item": uuid(item), "list": list.map { .number(Double($0)) } ?? .null,
            "listUuid": uuid(listUuid), "cue": uuid(cue),
            "position": .object(["item": .number(Double(itemPosition)), "cue": .number(Double(cuePosition))]),
            "gone": .array(gone.map { .string($0) }),
            "playlistTitle": .string(playlistTitle), "listTitle": .string(listTitle), "label": .string(label),
            "seq": .number(Double(seq)),
        ]
        if let armed {
            members["armed"] = .object([
                "item": uuid(armed.item), "cue": uuid(armed.cue),
                "position": .object(["item": .number(Double(armed.itemPosition)), "cue": .number(Double(armed.cuePosition))]),
                "inMs": .number(Double(Self.inMs(armed, frame: frame, rate: rate))),
            ])
        } else {
            members["armed"] = .null
        }
        if let boundary { members["boundary"] = .object(["reset": .bool(boundary)]) }
        return .object(members)
    }
}
