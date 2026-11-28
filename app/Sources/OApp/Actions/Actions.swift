// OApp — Spec 10 §5–§8, what each button, menu item, key and drag sends.

import Foundation
import OCore

/// Spec 10 §18, "Area 13, commands" — what one action sends: its commands,
/// whether they go as one group, and the source. Spec 10 §1 — the app "never
/// does anything the command vocabulary cannot", so every action is commands.
public struct Sending: Equatable, Sendable {
    public var commands: [Command]
    /// Spec 2 §8 — a group "validates as a whole" and lands on one frame.
    public var group: Bool
    public var source: AppSource

    /// One command goes alone; several go as one group (Spec 2 §5: an action
    /// on a selection "submits them as a group").
    public init(_ commands: [Command], source: AppSource = .ui) {
        self.commands = commands
        self.group = commands.count > 1
        self.source = source
    }

    /// The request that carries it, or nil when there is nothing to send.
    public var request: EngineRequest? {
        guard let first = commands.first else { return nil }
        return group ? .group(commands, source: source) : .command(first, source: source)
    }

    /// The commands in canonical text (Spec 2 §4), one each.
    public var text: [String] {
        commands.map { CommandText.print($0) ?? $0.cmd }
    }
}

/// Spec 10 §5–§8 — the one place an action becomes commands. Each function
/// is one row of §18's table; the views call these and compose nothing
/// themselves.
public enum Actions {
    // MARK: The pointer (Spec 10 §5, §6, §7)

    /// Spec 10 §7 — "a large Next (`next`)".
    public static func next(source: AppSource = .ui) -> Sending { Sending([.next], source: source) }

    /// Spec 10 §7 — "Last (`previous`)".
    public static func previous(source: AppSource = .ui) -> Sending { Sending([.previous], source: source) }

    /// Spec 10 §7 — the go-to field "takes a number and fires `cue N` in the live list on Return".
    public static func goTo(cue: Int, source: AppSource = .ui) -> Sending { Sending([.cue(cue)], source: source) }

    /// Spec 10 §7 — "Hold appears beside Next and sends `disarm`".
    public static func hold(source: AppSource = .ui) -> Sending { Sending([.disarm], source: source) }

    /// Spec 10 §5 — "Make Live (`playlist "TITLE"`, Spec 2 §3: live with no cue fired".
    public static func makeLive(title: String) -> Sending { Sending([.playlistLoad(title: title)]) }

    /// Spec 10 §6 — "in the live playlist, `item N cue M`". `state`: Spec 2 §3's `[state]`, which edit mode's Live
    /// sends (Spec 11 §2).
    public static func fire(item: Int, cue: Int, state: Bool = false) -> Sending { Sending([.itemCue(item: item, cue: cue, state: state)]) }

    /// Spec 10 §6 — "in a playlist that isn't loaded, `playlist "TITLE"` then
    /// `item N cue M`, one group that lands on one frame (Spec 2 §8)".
    public static func fire(loading title: String, item: Int, cue: Int, state: Bool = false) -> Sending {
        Sending([.playlistLoad(title: title), .itemCue(item: item, cue: cue, state: state)])
    }

    /// Spec 10 §6 — "in a list from the library, `list N cue M`".
    public static func fire(list: Int, cue: Int, state: Bool = false) -> Sending { Sending([.listCue(list: list, cue: cue, state: state)]) }

    // MARK: Transport (Spec 10 §7)

    /// "Play, Pause and Stop (`channel N play`, `pause`, `stop`) ... Several
    /// channels show Play, Pause and Stop for all of them, as one group."
    public static func transport(_ mode: TransportMode, channels: some Sequence<Int>) -> Sending {
        Sending(Selection.expand(channels) { .channelTransport(channel: .number($0), mode: mode) })
    }

    /// "its end behavior as Loop, Hold and Clear (`channel N end loop | hold | clear`)".
    public static func end(_ behavior: EndBehavior, channel: Int) -> Sending {
        Sending([.channelEndBehavior(channel: .number(channel), mode: behavior)])
    }

    // MARK: Clears (Spec 10 §7, choice U-4)

    /// "Clear All (`system clearall`)": the tile, and the strip's panic button.
    public static func clearAll() -> Sending { Sending([.systemClearAll]) }

    /// "Blackout Stack S, for the selected preview stack (`stack S blackout toggle`)".
    public static func blackout(stack: Int) -> Sending { Sending([.stackBlackout(stack: .number(stack), state: .toggle)]) }

    /// "Blackout All (`stack all blackout toggle`, which Area 15 adds)".
    public static func blackoutAll() -> Sending { Sending([.stackBlackout(stack: .all, state: .toggle)]) }

    /// "Mute All Audio (`audio all mute toggle`)".
    public static func muteAllAudio() -> Sending { Sending([.audioMute(audio: .all, state: .toggle)]) }

    /// "Reset Channels (`channel all reset`)".
    public static func resetChannels() -> Sending { Sending([.channelReset(channel: .all)]) }

    /// "Clear Popups (`popup N clear` for every slot, as one group, Spec 6 §7)".
    public static func clearPopups(slots: Int) -> Sending {
        Sending(slots > 0 ? (1...slots).map { .popupClear(popup: $0) } : [])
    }

    // MARK: Macros, popups and timers (Spec 10 §7)

    /// "running `macro N` on a click".
    public static func macro(_ number: Int, source: AppSource = .ui) -> Sending { Sending([.macro(number)], source: source) }

    /// "`popup N set "TEXT" [clearafter S]`".
    public static func popupSend(slot: Int, text: String, clearAfterSeconds: Int?) -> Sending {
        Sending([.popupSet(popup: slot, text: text, clearAfterMs: clearAfterSeconds.map { $0 * 1000 })])
    }

    /// "`popup N clear`".
    public static func popupClear(slot: Int) -> Sending { Sending([.popupClear(popup: slot)]) }

    /// "Set (`timer N set DURATION [up]`)".
    public static func timerSet(slot: Int, ms: Int, up: Bool) -> Sending { Sending([.timerSet(timer: slot, ms: ms, up: up)]) }

    /// "Start or Pause (`timer N start`, `pause`)".
    public static func timerStart(slot: Int) -> Sending { Sending([.timerStart(timer: slot)]) }
    public static func timerPause(slot: Int) -> Sending { Sending([.timerPause(timer: slot)]) }

    /// "Reset (`timer N reset`)".
    public static func timerReset(slot: Int) -> Sending { Sending([.timerReset(timer: slot)]) }

    // MARK: The strip (Spec 10 §7)

    /// "Selection belongs to the window and is never sent: an action on it
    /// sends one command per selected channel, in number order, as one group
    /// (Spec 2 §5)."
    public static func clearSelected(_ channels: some Sequence<Int>) -> Sending {
        Sending(Selection.expand(channels) { .channelClear(channel: .number($0)) })
    }

    /// A cell's Clear: "Each sends the command its name says".
    public static func clear(channel: Int) -> Sending { Sending([.channelClear(channel: .number(channel))]) }

    /// "a click toggles the mute (`stack S mute N toggle`)".
    public static func stackMute(stack: Int, channel: Int) -> Sending { Sending([.stackMute(stack: stack, channel: channel, state: .toggle)]) }

    /// "Lock or Unlock (`channel N lock`, `unlock`)".
    public static func lock(channel: Int, _ locked: Bool) -> Sending { Sending([.channelLock(channel: .number(channel), locked: locked)]) }

    /// "Reset Attributes (`channel N reset`)".
    public static func resetAttributes(channel: Int) -> Sending { Sending([.channelReset(channel: .number(channel))]) }

    /// "Grade ▸ (None and each grade; `channel N grade G`, which tracks, Spec 2 §3)"; None is grade 0.
    public static func grade(channel: Int, grade: Int) -> Sending { Sending([.channelGrade(channel: .number(channel), ref: grade, ms: nil)]) }

    /// "Transition ▸ (each transition; `channel N transition R`)".
    public static func transition(channel: Int, transition: Int) -> Sending {
        Sending([.channelTransition(channel: .number(channel), ref: transition, ms: nil)])
    }

    // MARK: The pool (Spec 10 §6)

    /// "Live writes from the pool ... send `channel N write media sha256:…`
    /// with source `ui`, with the item's default grade as a `grade G once`
    /// rider when it has one, and no other rider: its trim, loop, gain and
    /// sync offset fall back to its defaults when the write lands (Spec 3 §4)."
    public static func liveWrite(media id: String, channel: Int, defaultGrade: Int?) -> Sending {
        let riders = Riders(grade: defaultGrade.map { GradeRider(ref: $0, scope: .once) })
        return Sending([.channelWrite(ChannelWrite(channel: .number(channel), content: .media(MediaContent(ref: id)), riders: riders))])
    }

    // MARK: Outputs (Spec 10 §8)

    /// "a Stack ▸ menu that switches its live stack (`output N stack M`)".
    public static func outputStack(output: Int, stack: Int) -> Sending { Sending([.outputStack(output: output, stack: stack)]) }
}

/// Spec 10 §6 — why a cue or a playlist can't be fired; each is the reason
/// the disabled control shows.
public enum FireRefusal: Error, Equatable, Sendable {
    /// "the other's cells, its Make Live and the restore banner's Fire Again (§14) are disabled with "Rename to fire"."
    case renameToFire
    /// "A library list whose number another list shares is disabled the same way, with "Renumber to fire" (Spec 7 §2)."
    case renumberToFire
}

/// Spec 10 §6, "Clicking" — which commands a press on a cue sends, from what
/// the catalog says of the playlist or the list it is in.
public enum GridFire {
    /// A cue of a playlist: "in the live playlist, `item N cue M`; in a
    /// playlist that isn't loaded, `playlist "TITLE"` then `item N cue M`".
    /// "A playlist whose title another shares can be fired or made live only
    /// if its title loads it, which the `catalog` says (Spec 7 §3)".
    public static func playlistCue(_ playlist: CatalogPlaylist, item: Int, cue: Int, live: LiveStatus, state: Bool = false) -> Result<Sending, FireRefusal> {
        if live.playlist == playlist.playlist.uuid.uuidString.lowercased() { return .success(Actions.fire(item: item, cue: cue, state: state)) }
        guard playlist.named else { return .failure(.renameToFire) }
        return .success(Actions.fire(loading: playlist.playlist.title, item: item, cue: cue, state: state))
    }

    /// Make Live, on the same condition.
    public static func makeLive(_ playlist: CatalogPlaylist) -> Result<Sending, FireRefusal> {
        playlist.named ? .success(Actions.makeLive(title: playlist.playlist.title)) : .failure(.renameToFire)
    }

    /// A cue of a list opened from the library: "`list N cue M`".
    public static func libraryCue(_ list: ListSummary, cue: Int, state: Bool = false) -> Result<Sending, FireRefusal> {
        list.named ? .success(Actions.fire(list: list.number, cue: cue, state: state)) : .failure(.renumberToFire)
    }
}
