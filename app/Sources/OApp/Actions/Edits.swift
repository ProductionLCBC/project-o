// OApp — Spec 10 §5, §6, §10 and §14, what each edit of the library sends.

import Foundation
import OCore

/// What a cue says about one channel, as `edit.cueChannel` takes it (Spec 5
/// §4): "its content state (write with content and riders, clear, or hold
/// ...) plus its standalone attribute writes".
public struct CueSays: Equatable, Sendable {
    public var state: CueChannelState
    public var attributes: [Command]

    /// Reads a cue's commands for one channel. Where a hand-made cue has two
    /// content commands on the channel, the last is the one that lands, so
    /// it is the one read (Area 13 reading).
    public static func about(_ channel: Int, in cue: Cue) -> CueSays {
        var state = CueChannelState.hold
        var attributes: [Command] = []
        for entry in cue.commands {
            switch entry.command {
            case .channelWrite(let write) where write.channel == .number(channel):
                state = .write(write.content, write.riders)
            case .channelClear(.number(let number)) where number == channel:
                state = .clear
            case let command where command.isStandaloneAttribute(channel: channel):
                attributes.append(command)
            default:
                break
            }
        }
        return CueSays(state: state, attributes: attributes)
    }

    /// The body of the cue's text write on the channel, or nil when it writes no text there.
    public var textBody: String? {
        guard case .write(.text(let fields), _) = state else { return nil }
        return fields["body"] ?? ""
    }

    /// Whether the cue writes content on the channel.
    public var writesContent: Bool {
        if case .write = state { return true }
        return false
    }
}

/// Spec 10 §5, §6, §10 and §14 — the edits, each a row of §18's table like
/// the runtime actions: one function, one command (or one group), source
/// `ui`. "Show mode edits the library in a few places, each through Spec 5's
/// edit path, so the engine runs them, logs them with their inverses, and
/// undo reverses them."
public enum Edits {
    private static func edit(_ address: EditAddress, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(address, action))])
    }

    private static func value<T: Encodable>(_ encodable: T) -> JSONValue {
        (try? JSONCoding.encode(encodable)) ?? .null
    }

    // MARK: Playlists (Spec 10 §5)

    /// "Return sends `edit playlist create "TITLE"`."
    public static func newPlaylist(title: String) -> Sending {
        edit(.playlist(nil), .create(body: nil, folder: nil, title: title))
    }

    /// "Rename (in place; `… title`)".
    public static func rename(playlist: UUID, to title: String) -> Sending {
        edit(.playlist(playlist), .set(path: "title", value: .string(title)))
    }

    /// "Date and Time… (a popover setting `serviceDate` and `serviceTime`,
    /// each with "None")". Only what changed is sent, both as one group.
    public static func schedule(playlist: Playlist, date: String?, time: String?) -> Sending {
        var commands: [Command] = []
        if date != playlist.serviceDate {
            commands.append(.edit(EditCommand(.playlist(playlist.uuid), .set(path: "serviceDate", value: date.map(JSONValue.string) ?? .null))))
        }
        if time != playlist.serviceTime {
            commands.append(.edit(EditCommand(.playlist(playlist.uuid), .set(path: "serviceTime", value: time.map(JSONValue.string) ?? .null))))
        }
        return Sending(commands)
    }

    /// "Duplicate… (asks for the new title; `… duplicate`)".
    public static func duplicate(playlist: UUID, title: String) -> Sending {
        edit(.playlist(playlist), .duplicate(to: nil, title: title, picks: .none))
    }

    /// "Archive a Copy (`… archive`, Spec 7 §5, which works while it is live)".
    public static func archiveCopy(playlist: UUID) -> Sending {
        edit(.playlist(playlist), .archive(title: nil, picks: .none))
    }

    /// "Archive (`… archived true`, disabled while it is live) or, for an archived one, Restore from Archive (`… archived false`)".
    public static func archive(playlist: UUID, _ archived: Bool) -> Sending {
        edit(.playlist(playlist), .set(path: "archived", value: .bool(archived)))
    }

    /// "Delete… (`… delete`, after a confirmation ...)".
    public static func delete(playlist: UUID) -> Sending {
        edit(.playlist(playlist), .delete)
    }

    // MARK: A playlist's items (Spec 10 §5)

    /// "Remove from Playlist (`… item I remove` ...)".
    public static func remove(item: UUID, from playlist: UUID) -> Sending {
        edit(.item(playlist: playlist, item: item), .remove(path: nil, at: nil))
    }

    /// "Add Header Above, which opens a label field, Return inserting the header there".
    public static func insertHeader(_ label: String, in playlist: UUID, at position: Int) -> Sending {
        edit(.playlist(playlist), .insert(path: "items", at: position, value: value(PlaylistItem.Draft(kind: .header(label: label)))))
    }

    /// "Rename, for a header (`… item I label`)".
    public static func rename(header item: UUID, in playlist: UUID, to label: String) -> Sending {
        edit(.item(playlist: playlist, item: item), .set(path: "label", value: .string(label)))
    }

    /// "Items drag to reorder (`… item I move K`)."
    public static func move(item: UUID, in playlist: UUID, to position: Int) -> Sending {
        edit(.item(playlist: playlist, item: item), .move(path: nil, from: nil, at: position))
    }

    /// "A list ... is inserted where it lands (`edit playlist P insert items
    /// K {"kind": "linked", "list": N, "listUuid": "…"}`, naming the list by
    /// its uuid, since two lists can share a number, Spec 7 §2)."
    public static func insert(list: ListSummary, in playlist: UUID, at position: Int) -> Sending {
        let item = PlaylistItem.Draft(kind: .linked(list: list.number, listUuid: UUID(uuidString: list.uuid)))
        return edit(.playlist(playlist), .insert(path: "items", at: position, value: value(item)))
    }

    // MARK: The library's folders and lists (Spec 10 §5)

    private static func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    /// "Double-click or the menu renames one in place (`edit folder "A" rename "B"`)": the same parent, another name.
    public static func rename(folder path: String, to name: String) -> Sending {
        edit(.folder(path), .rename(to: join(parent(of: path), name)))
    }

    /// "A folder dragged onto another moves into it (a rename with the new parent)"; onto the top, `into` is empty.
    public static func move(folder path: String, into parent: String) -> Sending {
        let name = path.split(separator: "/").last.map { String($0) } ?? path
        return edit(.folder(path), .rename(to: join(parent, name)))
    }

    /// "New Folder opens a name field and sends `edit folder "PATH" create` with the name typed."
    public static func newFolder(_ name: String, in parent: String) -> Sending {
        edit(.folder(join(parent, name)), .create(body: nil, folder: nil, title: nil))
    }

    /// "Delete Folder is enabled only for an empty folder (`… delete`)."
    public static func delete(folder path: String) -> Sending {
        edit(.folder(path), .delete)
    }

    /// "Dragging a list onto a folder moves it (`edit list N folder "PATH"`), onto the tree's empty space moves it to the top (`""`)".
    public static func move(list: Int, toFolder path: String) -> Sending {
        edit(.list(list), .folder(path))
    }

    /// "Rename (in place; the list's `title`)".
    public static func rename(list: Int, to title: String) -> Sending {
        edit(.list(list), .set(path: "title", value: .string(title)))
    }

    /// "Duplicate (`edit list N duplicate`)".
    public static func duplicate(list: Int) -> Sending {
        edit(.list(list), .duplicate(to: nil, title: nil, picks: .none))
    }

    /// "Delete… (`edit list N delete`, after a confirmation naming the playlists that link it, from `listUse`)".
    public static func delete(list: Int) -> Sending {
        edit(.list(list), .delete)
    }

    /// Spec 10 §5 — "Return sends `edit list create folder "PATH" {"title": "TITLE"}`, or
    /// `edit list create {"title": "TITLE"}` at the top" (corrected 2026-11-24).
    public static func newList(in folder: String?, title: String) -> Sending {
        edit(.list(nil), .create(body: .object(["title": .string(title)]), folder: (folder ?? "").isEmpty ? nil : folder, title: nil))
    }

    // MARK: A cue's menu (Spec 10 §6)

    /// "Note… (a popover; `edit list L cue C note "…"`)".
    public static func note(_ text: String, list: Int, cue: UUID) -> Sending {
        edit(.cue(list: list, cue: cue), .set(path: "note", value: .string(text)))
    }

    /// "Trigger ▸ Go, Time after Previous… (seconds)".
    public static func trigger(_ trigger: CueTrigger, list: Int, cue: UUID) -> Sending {
        edit(.cue(list: list, cue: cue), .set(path: "trigger", value: value(trigger)))
    }

    /// "Advance After… (seconds or none)".
    public static func advanceAfter(ms: Int?, list: Int, cue: UUID) -> Sending {
        edit(.cue(list: list, cue: cue), .set(path: "advanceAfterMs", value: ms.map { .number(Double($0)) } ?? .null))
    }

    /// "Duplicate Section (`… section duplicate`)".
    public static func duplicateSection(list: Int, cue: UUID) -> Sending {
        edit(.cue(list: list, cue: cue), .section(.duplicate))
    }

    // MARK: Edits from show mode (Spec 10 §10)

    /// "In-place text ... A commit sends one `edit.cueChannel` for that cue
    /// and channel with the new body, keeping the write's other fields, its
    /// riders and the channel's attribute writes (Spec 5 §4)." Nil when the
    /// cue writes no text there, or the body is as it was (nothing is sent
    /// for no change; an emptied body is a write with an empty body).
    public static func text(body: String, cue: Cue, list: Int, channel: Int) -> Sending? {
        let says = CueSays.about(channel, in: cue)
        guard case .write(.text(var fields), let riders) = says.state, (fields["body"] ?? "") != body else { return nil }
        fields["body"] = body
        return edit(.cue(list: list, cue: cue.uuid),
                    .cueChannel(CueChannelEdit(channel: channel, state: .write(.text(fields: fields), riders), attributes: says.attributes)))
    }

    /// "A pool tile dropped on a cue ... sends one `edit.cueChannel` writing
    /// the item on that channel: `write media sha256:…`, keeping the
    /// transition and audio-transition riders of what the cue wrote there
    /// before and the channel's attribute writes, with the item's default
    /// grade as a `grade G once` rider, or none ... The item's trim, loop,
    /// gain and sync offset aren't written".
    public static func write(media id: String, defaultGrade: Int?, on channel: Int, cue: Cue, list: Int) -> Sending {
        let says = CueSays.about(channel, in: cue)
        var riders = Riders()
        if case .write(_, let before) = says.state {
            riders.transition = before.transition
            riders.audioTransition = before.audioTransition
        }
        riders.grade = defaultGrade.map { GradeRider(ref: $0, scope: .once) }
        return edit(.cue(list: list, cue: cue.uuid),
                    .cueChannel(CueChannelEdit(channel: channel, state: .write(.media(MediaContent(ref: id)), riders), attributes: says.attributes)))
    }

    /// The cue "Grade for Channel N ▸" acts on: "the first cue in that list that writes content to channel N".
    public static func gradeCue(channel: Int, in list: List) -> Cue? {
        list.cues.first { CueSays.about(channel, in: $0).writesContent }
    }

    /// The channels a list header offers a grade for: "one submenu per channel the list writes content to".
    public static func gradeChannels(in list: List) -> [Int] {
        var channels: Set<Int> = []
        for cue in list.cues {
            for entry in cue.commands {
                if case .channelWrite(let write) = entry.command, case .number(let channel) = write.channel { channels.insert(channel) }
            }
        }
        return channels.sorted()
    }

    /// The grade that write tracks now, or nil for none.
    public static func trackedGrade(channel: Int, in list: List) -> Int? {
        guard let cue = gradeCue(channel: channel, in: list), case .write(_, let riders) = CueSays.about(channel, in: cue).state,
              let grade = riders.grade, grade.scope == .track else { return nil }
        return grade.ref
    }

    /// "The grade picker ... one `edit.cueChannel` giving that write a
    /// `grade G track` rider, or removing its grade rider for None (Spec 5
    /// §5)." Nil when no cue of the list writes content there.
    public static func grade(_ grade: Int?, channel: Int, in list: List) -> Sending? {
        guard let cue = gradeCue(channel: channel, in: list) else { return nil }
        let says = CueSays.about(channel, in: cue)
        guard case .write(let content, var riders) = says.state else { return nil }
        riders.grade = grade.map { GradeRider(ref: $0, scope: .track) }
        return edit(.cue(list: list.number, cue: cue.uuid),
                    .cueChannel(CueChannelEdit(channel: channel, state: .write(content, riders), attributes: says.attributes)))
    }

    // MARK: Media (Spec 10 §6, §10)

    /// "Defaults… (a popover editing its trim in and out, loop, gain, grade,
    /// sync offset and default channel, each an `edit media sha256:…
    /// defaults.FIELD` edit, Spec 8 §5)".
    public static func mediaDefault(_ id: String, field: String, value: JSONValue) -> Sending {
        edit(.media(id), .set(path: "defaults." + field, value: value))
    }

    /// "Then `media delete HASH` (Spec 8 §6)."
    public static func deleteMedia(_ id: String) -> Sending {
        Sending([.media(.delete(id: id, files: nil))])
    }

    /// "sends `media replace OLD NEW` when the import's `done` names the new id".
    public static func replaceMedia(old: String, new: String) -> Sending {
        Sending([.media(.replace(old: old, new: new, record: nil))])
    }

    /// "imported with `media import "PATH"` (Spec 8 §3)".
    public static func importMedia(path: String) -> Sending {
        Sending([.media(.importFile(path: path))])
    }

    // MARK: Undo, redo and restores (Spec 10 §10, §14)

    /// "Edit ▸ Undo and Redo send `undo` and `redo` (Spec 5 §8)."
    public static func undo() -> Sending { Sending([.undo]) }
    public static func redo() -> Sending { Sending([.redo]) }

    /// "Then `system restore list N version V`."
    public static func restore(list: Int, version: Int) -> Sending {
        Sending([.systemRestoreList(list: list, version: version)])
    }

    /// "Then `system restore snapshot "ID"`".
    public static func restore(snapshot id: String) -> Sending {
        Sending([.systemRestoreSnapshot(id: id)])
    }

    /// File ▸ Take Snapshot: `system snapshot` (Spec 9 §3).
    public static func takeSnapshot() -> Sending { Sending([.systemSnapshot]) }

    /// Spec 10 §14 — "Set Timers Again, which sets each timer to its last
    /// value from the `timers` topic and starts those that were running":
    /// one group, each timer's `set` then its `start`, in slot order. The
    /// value is the last one received, not carried forward by the time
    /// since (Area 13 reading).
    public static func setTimersAgain(_ timers: [TimerStatus]) -> Sending {
        var commands: [Command] = []
        for timer in timers.sorted(by: { $0.slot < $1.slot }) {
            guard let ms = timer.valueMs ?? timer.setMs else { continue }
            commands.append(.timerSet(timer: timer.slot, ms: ms, up: timer.direction == "up"))
            if timer.isRunning { commands.append(.timerStart(timer: timer.slot)) }
        }
        return Sending(commands)
    }
}

extension Catalog {
    /// Spec 10 §6 — "the text channel (the lowest-numbered channel whose
    /// `usualContent` is text, channel 2 on first run, as the scope doc's E1 picks)".
    public var textChannel: Int? {
        channels.filter { $0.usualContent == .text }.map(\.number).min()
    }
}
