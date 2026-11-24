// OApp — Spec 10 §5 and §6, the edits that take more than one step: a question first, a query first, or something to show after.

import Foundation
import OCore

extension ShowModel {
    /// Asks, and runs `work` on a yes. With no window to ask, nothing is done.
    func ask(_ confirmation: Confirmation, then work: @escaping @MainActor () -> Void) {
        guard let confirm else { return }
        confirm(confirmation) { yes in
            if yes { work() }
        }
    }

    /// Asks the engine something and hands back its answer's fields, or nil when it is away or refuses.
    func ask(_ query: EngineRequest, then work: @escaping @MainActor ([String: JSONValue]?) -> Void) {
        guard store.cannotSend == nil, let transmit else { return work(nil) }
        transmit(query) { reply in
            if case .answer(let fields)? = reply { work(fields) } else { work(nil) }
        }
    }

    // MARK: - Playlists (Spec 10 §5)

    /// "Make Live (`playlist "TITLE"`, Spec 2 §3: live with no cue fired, so the next `next` fires its first cue ...)".
    @discardableResult
    public func makeLive(playlist uuid: String) -> Bool {
        guard let playlist = store.catalog?.playlist(uuid: uuid), let sending = try? GridFire.makeLive(playlist).get() else { return false }
        return send(sending)
    }

    /// "Delete… (`… delete`, after a confirmation, which says the service
    /// keeps running from the engine's copy when it is live, Spec 7 §4)."
    public func deletePlaylist(_ uuid: String) {
        guard let playlist = store.catalog?.playlist(uuid: uuid)?.playlist else { return }
        ask(.deletePlaylist(title: playlist.title, isLive: store.live.playlist == uuid)) { [weak self] in
            self?.edit(Edits.delete(playlist: playlist.uuid), at: .left)
        }
    }

    /// "Remove from Playlist (`… item I remove`; on the live item it says
    /// the song finishes first, Spec 7 §4)": asked only there, since undo is
    /// the way back from any other.
    public func removeItem(_ item: String, from uuid: String, at place: NoticePlace = .left) {
        guard let playlist = store.catalog?.playlist(uuid: uuid)?.playlist,
              let entry = playlist.items.first(where: { $0.uuid.uuidString.lowercased() == item }) else { return }
        let remove: @MainActor () -> Void = { [weak self] in _ = self?.edit(Edits.remove(item: entry.uuid, from: playlist.uuid), at: place) }
        guard store.live.playlist == uuid, store.live.item == item else { return remove() }
        ask(.removeLiveItem(title: store.live.listTitle), then: remove)
    }

    /// "Add to Playlist ▸ (the playlists, appending a linked item)".
    public func add(list uuid: String, toPlaylist playlistUuid: String, at position: Int? = nil, place: NoticePlace = .left) {
        guard let catalog = store.catalog, let list = catalog.list(uuid: uuid), let playlist = catalog.playlist(uuid: playlistUuid)?.playlist else { return }
        edit(Edits.insert(list: list, in: playlist.uuid, at: position ?? playlist.items.count), at: place)
    }

    // MARK: - The library (Spec 10 §5)

    /// "Delete… (`edit list N delete`, after a confirmation naming the playlists that link it, from `listUse`)".
    public func deleteList(_ uuid: String) {
        guard let list = store.catalog?.list(uuid: uuid) else { return }
        ask(.query("listUse", ["listUuid": .string(uuid)])) { [weak self] answer in
            let linking = answer.map { ListUse(answer: $0).playlists.map(\.title) } ?? []
            self?.ask(.deleteList(title: list.title, playlists: linking)) {
                self?.edit(Edits.delete(list: list.number), at: .left)
            }
        }
    }

    /// "New List ... sends `edit list create folder "PATH"` for the selected
    /// folder, or `edit list create` at the top, and browses the new, empty
    /// list, which its result names (§3)".
    @discardableResult
    public func newList(in folder: String?) -> CannotEdit? {
        commit(Edits.newList(in: folder), master: true, at: .left) { [weak self] outcome in
            // "`create` keeps its picks where they live: a list's number in its address and its uuid in its body" (Spec 5 §4).
            guard let created = outcome.applied.first?.command.objectValue, let uuid = created["value"]?.objectValue?["uuid"]?.stringValue else { return }
            self?.browse(.list(uuid.lowercased()))
        }
    }

    // MARK: - Fields that commit (Spec 10 §5, §10)
    //
    // Each answers why it couldn't be sent, or nil when it went or there was
    // nothing to send (an empty or unchanged name), so the field may close.

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func playlist(_ uuid: String) -> Playlist? {
        store.catalog?.playlist(uuid: uuid)?.playlist
    }

    /// "the window's + button or ⌘N opens a title field in the tree; Return sends `edit playlist create "TITLE"`."
    public func newPlaylist(title: String) -> CannotEdit? {
        let title = trimmed(title)
        return commit(title.isEmpty ? nil : Edits.newPlaylist(title: title), master: false, at: .left)
    }

    public func rename(playlist uuid: String, to title: String) -> CannotEdit? {
        let title = trimmed(title)
        guard let playlist = playlist(uuid), !title.isEmpty, title != playlist.title else { return nil }
        return commit(Edits.rename(playlist: playlist.uuid, to: title), master: false, at: .left)
    }

    /// "Duplicate… (asks for the new title; `… duplicate`)".
    public func duplicate(playlist uuid: String, as title: String) -> CannotEdit? {
        let title = trimmed(title)
        guard let playlist = playlist(uuid), !title.isEmpty else { return nil }
        return commit(Edits.duplicate(playlist: playlist.uuid, title: title), master: false, at: .left)
    }

    /// "Date and Time… (a popover setting `serviceDate` and `serviceTime`, each with "None")".
    public func schedule(playlist uuid: String, date: String?, time: String?) -> CannotEdit? {
        guard let playlist = playlist(uuid) else { return nil }
        return commit(Edits.schedule(playlist: playlist, date: date, time: time), master: false, at: .left)
    }

    /// "Add Header Above, which opens a label field, Return inserting the header there".
    public func addHeader(_ label: String, above item: String, in uuid: String) -> CannotEdit? {
        let label = trimmed(label)
        guard let playlist = playlist(uuid), !label.isEmpty,
              let position = playlist.items.firstIndex(where: { $0.uuid.uuidString.lowercased() == item }) else { return nil }
        return commit(Edits.insertHeader(label, in: playlist.uuid, at: position), master: false, at: .left)
    }

    /// "Rename, for a header (`… item I label`)".
    public func rename(header item: String, in uuid: String, to label: String) -> CannotEdit? {
        let label = trimmed(label)
        guard let playlist = playlist(uuid), !label.isEmpty,
              let entry = playlist.items.first(where: { $0.uuid.uuidString.lowercased() == item }), case .header(let old) = entry.kind, old != label else { return nil }
        return commit(Edits.rename(header: entry.uuid, in: playlist.uuid, to: label), master: false, at: .left)
    }

    /// "Rename (in place; the list's `title`)".
    public func rename(list uuid: String, to title: String) -> CannotEdit? {
        let title = trimmed(title)
        guard let list = store.catalog?.list(uuid: uuid), !title.isEmpty, title != list.title else { return nil }
        if let cannot = Menus.cannotEdit(list: list, cannotEditMasters: cannotEditMasters) { return cannot }
        return commit(Edits.rename(list: list.number, to: title), master: true, at: .left)
    }

    /// "Double-click or the menu renames one in place (`edit folder "A" rename "B"`)."
    public func rename(folder path: String, to name: String) -> CannotEdit? {
        let name = trimmed(name)
        guard !name.isEmpty, name != LibraryTree.name(of: path) else { return nil }
        return commit(Edits.rename(folder: path, to: name), master: true, at: .left)
    }

    /// "New Folder opens a name field and sends `edit folder "PATH" create` with the name typed."
    public func newFolder(_ name: String, in parent: String) -> CannotEdit? {
        let name = trimmed(name)
        guard !name.isEmpty else { return nil }
        let cannot = commit(Edits.newFolder(name, in: parent), master: true, at: .left)
        // The folder it was made in is opened, so the new one shows.
        if cannot == nil, !parent.isEmpty, !settings.openFolders.contains(parent) { toggle(folder: parent) }
        return cannot
    }

    // MARK: - A cue's edits (Spec 10 §6, §10)

    /// Why a list's cues, and the list itself, can't be edited: the machine,
    /// a local copy, a number another list shares, or a list that is gone.
    public func cannotEdit(listUuid uuid: String?) -> CannotEdit? {
        guard let uuid, let list = store.catalog?.list(uuid: uuid) else { return .missing }
        return Menus.cannotEdit(list: list, cannotEditMasters: cannotEditMasters)
    }

    /// The cue a cell shows, with its list's number, from the list the app holds.
    public func cue(_ cell: CueCell, in section: GridSection) -> (cue: Cue, list: Int)? {
        guard let uuid = section.listUuid, let list = store.lists[uuid]?.list,
              let cue = list.cues.first(where: { $0.uuid.uuidString.lowercased() == cell.uuid }) else { return nil }
        return (cue, list.number)
    }

    /// "a cue with a text write on the text channel ... edits that text in
    /// place (§10)": the body it would open on, or nil for any other cue.
    public func textBody(of cell: CueCell, in section: GridSection) -> String? {
        guard let channel = store.catalog?.textChannel, let found = cue(cell, in: section) else { return nil }
        return CueSays.about(channel, in: found.cue).textBody
    }

    public func cueContext(_ cell: CueCell, in section: GridSection) -> Menus.CueContext {
        let cannotFire: CannotEdit? = store.cannotSend.map(CannotEdit.unavailable) ?? section.refusal.map(CannotEdit.fire) ?? (section.isRemoved ? .removed : nil)
        return Menus.CueContext(fire: cannotFire, edit: section.isRemoved ? .removed : cannotEdit(listUuid: section.listUuid),
                                hasText: textBody(of: cell, in: section) != nil, trigger: cell.trigger, advanceAfterMs: cell.advanceAfterMs,
                                isArmed: cell.isArmed, cannotSend: store.cannotSend, editCue: editing.cannotOpen.map(CannotEdit.unavailable))
    }

    private func cueEdit(_ cell: CueCell, _ section: GridSection, _ make: (Cue, Int) -> Sending?) -> CannotEdit? {
        if let cannot = section.isRemoved ? CannotEdit.removed : cannotEdit(listUuid: section.listUuid) { return cannot }
        guard let found = cue(cell, in: section) else { return nil }
        return commit(make(found.cue, found.list), master: true, at: .grid)
    }

    /// "Note… (a popover; `edit list L cue C note "…"`)". An unchanged note sends nothing.
    public func note(_ text: String, cell: CueCell, in section: GridSection) -> CannotEdit? {
        cueEdit(cell, section) { cue, list in text == cue.note ? nil : Edits.note(text, list: list, cue: cue.uuid) }
    }

    /// "Trigger ▸ Go, Time after Previous… (seconds)".
    public func trigger(_ trigger: CueTrigger, cell: CueCell, in section: GridSection) -> CannotEdit? {
        cueEdit(cell, section) { cue, list in trigger.kind == cue.trigger.kind ? nil : Edits.trigger(trigger, list: list, cue: cue.uuid) }
    }

    /// "Advance After… (seconds or none)".
    public func advanceAfter(ms: Int?, cell: CueCell, in section: GridSection) -> CannotEdit? {
        cueEdit(cell, section) { cue, list in ms == cue.advanceAfterMs ? nil : Edits.advanceAfter(ms: ms, list: list, cue: cue.uuid) }
    }

    /// "Duplicate Section (`… section duplicate`)".
    @discardableResult
    public func duplicateSection(cell: CueCell, in section: GridSection) -> CannotEdit? {
        cueEdit(cell, section) { cue, list in Edits.duplicateSection(list: list, cue: cue.uuid) }
    }

    /// In-place text commits: "one `edit.cueChannel` for that cue and
    /// channel with the new body ... The field sends nothing until it
    /// commits (choice U-12)."
    public func commitText(_ body: String, cell: CueCell, in section: GridSection) -> CannotEdit? {
        guard let channel = store.catalog?.textChannel else { return nil }
        return cueEdit(cell, section) { cue, list in Edits.text(body: body, cue: cue, list: list, channel: channel) }
    }

    // MARK: - A list header (Spec 10 §6, §10)

    /// A list header's menu, from the list the app holds: the channels it
    /// writes content to, each with the grade its first write tracks.
    public func headerMenu(for section: GridSection) -> [MenuEntry] {
        let catalog = store.catalog
        let list = section.listUuid.flatMap { store.lists[$0]?.list }
        let channels = (list.map(Edits.gradeChannels) ?? []).map { channel in
            Menus.GradeChoice(channel: channel, label: channelLabel(channel), tracked: list.flatMap { Edits.trackedGrade(channel: channel, in: $0) })
        }
        let inPlaylist = section.itemUuid != nil && !section.isRemoved
        var remove: CannotEdit? = cannotEditMachine.map(CannotEdit.unavailable)
        if case .playlist(let uuid)? = grid.context, catalog?.playlist(uuid: uuid)?.playlist.archived == true { remove = remove ?? .archived }
        return Menus.listHeader(inPlaylist: inPlaylist, isLinked: !section.isLocal && !section.isMissing && section.listUuid != nil, removeItem: remove,
                                edit: section.isRemoved ? .removed : cannotEdit(listUuid: section.listUuid), channels: channels, grades: catalog?.grades ?? [])
    }

    /// "The grade picker ... sets the grade of the first cue in that list that writes content to channel N".
    @discardableResult
    public func grade(_ grade: Int?, channel: Int, in section: GridSection) -> CannotEdit? {
        if let cannot = cannotEdit(listUuid: section.listUuid) { return cannot }
        guard let uuid = section.listUuid, let list = store.lists[uuid]?.list, Edits.trackedGrade(channel: channel, in: list) != grade else { return nil }
        return commit(Edits.grade(grade, channel: channel, in: list), master: true, at: .grid)
    }

    /// Whether a library folder holds nothing: no list in it or under it, and no folder under it.
    public func isEmpty(folder path: String) -> Bool {
        guard let catalog = store.catalog else { return false }
        let under = path + "/"
        return !catalog.lists.contains { !$0.local && ($0.folder == path || $0.folder.hasPrefix(under)) } && !catalog.folders.contains { $0.hasPrefix(under) }
    }

    // MARK: - Drags (Spec 10 §5, §6)

    /// What landing a drag there would do, as the machine stands now.
    public func plan(_ payload: DragPayload, onto target: DropTarget) -> DropPlan {
        Drops.plan(payload, onto: target, catalog: store.catalog, cannotEditMachine: cannotEditMachine, cannotEditMasters: cannotEditMasters)
    }

    /// Does what a drop came to: sends its edit, or says beside the target why nothing happened.
    public func perform(_ plan: DropPlan, at place: NoticePlace) {
        switch plan {
        case .refused(let reason): say(.notSent(reason), at: place)
        case .edit(let sending, _): edit(sending, at: place)
        // A cue's, a strip cell's and the pool's drops land through their own functions (ShowModel+Pool).
        default: break
        }
    }

    // MARK: - Restores (Spec 10 §14)

    /// "Restore a Version… on a list opens a sheet of its kept versions from
    /// the `versions` query, newest first". Hands back the list's title, its
    /// versions, and whether it is on air, which the sheet says.
    public func versions(ofList uuid: String, then show: @escaping @MainActor (_ title: String, _ versions: [KeptVersion], _ onAir: Bool) -> Void) {
        guard let list = store.catalog?.list(uuid: uuid) else { return }
        let onAir = store.live.listUuid == uuid
        ask(.query("versions", ["list": .number(Double(list.number))])) { answer in
            show(list.title, answer.map(KeptVersion.all) ?? [], onAir)
        }
    }

    /// "Restore asks: "Restore version 16 of "Great Is Thy Faithfulness",
    /// kept Nov 1 at 09:12, with 14 cues? ..." Then `system restore list N
    /// version V`. A list on air takes it at each cue's next fire, and the
    /// sheet says so."
    public func restore(_ version: KeptVersion, ofList uuid: String) {
        guard let list = store.catalog?.list(uuid: uuid) else { return }
        if let cannot = Menus.cannotEdit(list: list, cannotEditMasters: cannotEditMasters) { return say(.notSent(cannot), at: .top) }
        let question = Confirmation.restoreVersion(version: version.version, title: list.title, keptAt: EditWording.when(version.keptAt), cues: version.cues,
                                                   onAir: store.live.listUuid == uuid)
        ask(question) { [weak self] in
            self?.edit(Edits.restore(list: list.number, version: version.version), at: .top)
        }
    }
}
