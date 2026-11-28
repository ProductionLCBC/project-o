// OApp — Spec 11 §2 and §4, edit mode's model: the ways in and out, the page, the Cues page's list, selection and edits.

import Foundation
import OCore

/// Spec 11 §2, the top bar — "what the page edits. For the Cues and Text
/// pages that is where the list came from and its title, "Sunday 9:00 ›
/// Amazing Grace", or "Library › Amazing Grace"". `source` is the
/// playlist's title, or nil for the Library window.
public struct EditCrumb: Equatable, Sendable {
    public var source: String?
    public var title: String

    public init(source: String?, title: String) {
        self.source = source
        self.title = title
    }
}

/// Spec 11 §4, "Fire" — "The inspector's header says which ("Fires in
/// Sunday"). As in show mode, it is disabled for a playlist its title
/// doesn't load ("Rename to fire") and a list its number doesn't reach
/// ("Renumber to fire")."
public enum FireNote: Equatable, Sendable {
    /// In the playlist named, or from the Library window for nil.
    case fires(in: String?)
    case refused(FireRefusal)
    /// The engine is away, or there is no cue to fire.
    case unavailable
}

/// Spec 11 §2, "Rejections and warnings" — what the inspector's notice line says.
public enum EditNotice: Equatable, Sendable {
    /// "A rejected edit puts its control back, outlined in red, and the line says why in plain words".
    case rejected(EngineRejection)
    /// Something that couldn't be sent, with why: a read-only list, the lock, the engine away.
    case notSent(CannotEdit)
    /// "An applied edit's `warnings` (Spec 5 §6) show there in yellow until the object is next edited."
    case warnings([String])
    /// Spec 11 §4, "Multi-cue editing" — ""This cue only" ... skips the rest, saying how many it skipped".
    case skipped(Int)
    /// Spec 11 §2 — "The first edit in a run to something on air says so in
    /// the inspector's notice line (below), naming where it shows: "On air
    /// on outputs 1 and 2: this shows at once."" The outputs, by number.
    case onAir(outputs: [Int])
}

/// Spec 11 §4, "The Preview monitor" — the engine's picture of the selected
/// cue, as the last answer of `render` gave it.
public struct PreviewPicture: Equatable, Sendable {
    /// The file, relative to the machine root; nil until a picture has been drawn.
    public var file: String?
    public var width: Int?
    public var height: Int?
    /// "a media item whose file is missing draws nothing for the pixel boxes, and the answer says `missing: true`".
    public var isMissing = false
}

/// Spec 11 §2 and §4 — edit mode, beside the show window's model: which
/// page shows, which list the Cues page edits and where it came from, what
/// is selected in its grid, and each control's edit. It sends through the
/// window's model, so the lock, the engine's absence and a read-only library
/// stop an edit here exactly as they do in show mode.
@MainActor
public final class EditModel {
    unowned let model: ShowModel

    /// The uuid of a cue the app inserts: "with a uuid the app makes, so a group can name the cue it inserts".
    public var makeUuid: () -> UUID = { UUID() }
    /// The lock came on while edit mode was open: the window offers an open field's unsent text before the page goes.
    public var onLocked: (() -> Void)?

    /// "The pages keep where a list came from, which Fire (§4) and leaving use."
    public private(set) var source: GridContext?
    public private(set) var itemUuid: String?
    public private(set) var listUuid: String?
    public private(set) var selection = CueGridSelection()
    public private(set) var grid = CueGridModel()
    /// The page's list as the show grid has it where it came from: its item's number and whether its cues may be fired.
    public private(set) var section: GridSection?
    public private(set) var preview = PreviewPicture()
    /// Spec 11 §8 — the Presets page's own state: the selected box, the canvas's stack, the sample, the engine's
    /// picture of the layout, what uses the preset and the fonts the engine draws.
    public internal(set) var presetState = PresetEditorState()
    /// Spec 11 §9 — the Objects page's own state: Used by, the grade's two pictures and the item they show.
    public internal(set) var objectState = ObjectEditorState()
    /// Spec 11 §5 — the Text page: the list's text on one channel, the caret's chunk and what it has sent.
    public private(set) lazy var text = TextEditor(editing: self)

    private var standing: EditNotice?
    private var triedLeaving = false
    /// The edits sent that the engine hasn't answered, and whether edit mode leaves once it has applied them.
    private var pending = 0
    private var leavesWhenAnswered = false
    /// The selection the on-air note was last said for.
    private var saidOnAir: Set<String> = []
    private var pendingSelect: String?
    private var previewPixels = 0
    private var previewAsked = 0
    private var previewSubject: [String: JSONValue]?

    init(model: ShowModel) {
        self.model = model
    }

    private var store: ShowStore { model.store }

    public var page: EditPage { model.settings.editPage }

    // MARK: - Opening it (Spec 11 §2)

    /// "While operator lock is on, Mode ▸ Edit, Edit in the top bar and every entry above are disabled with the reason".
    public var cannotOpen: Unavailable? {
        store.cannotEdit(master: false) == .locked ? .locked : nil
    }

    /// "Mode ▸ Edit (⌘2) or Edit in the top bar opens the last page on what
    /// show mode had in hand: the list the grid browses, from its playlist or
    /// the Library window, and the selected cue, else the live cue if it is
    /// in that list, else the first." With nothing in hand, the page opens
    /// on what `view.json` remembers.
    @discardableResult
    public func open() -> Bool {
        guard cannotOpen == nil else { return false }
        if model.mode == .edit { return true }
        let shown = model.grid
        let sections = shown.sections.filter { $0.kind == .list && $0.listUuid != nil && !$0.isMissing }
        if let context = shown.context, let section = sections.first(where: \.isLive) ?? sections.first, let list = section.listUuid {
            let live = section.cells.first(where: \.isLive)?.uuid
            let remembered = model.settings.editList == list ? model.settings.editCue : nil
            enter(source: context, item: section.itemUuid, list: list, cue: live ?? remembered)
        } else if let list = model.settings.editList, store.catalog?.list(uuid: list) != nil {
            let playlist = model.settings.editPlaylist.flatMap { store.catalog?.playlist(uuid: $0) == nil ? nil : $0 }
            enter(source: playlist.map(GridContext.playlist) ?? .list(list), item: playlist == nil ? nil : model.settings.editItem,
                  list: list, cue: model.settings.editCue)
        } else {
            enter(source: nil, item: nil, list: nil, cue: nil)
        }
        return true
    }

    /// "a double-click on a cue that isn't a text cue, or Edit Cue in a cue's menu, opens the Cues page on that cue (Spec 10 §6)".
    @discardableResult
    public func open(cue cell: CueCell, in section: GridSection) -> Bool {
        guard cannotOpen == nil, let context = model.grid.context, let list = section.listUuid else { return false }
        model.settings.editPage = .cues
        enter(source: context, item: section.itemUuid, list: list, cue: cell.uuid)
        return true
    }

    /// A page opened from show mode: Edit on a macro tile opens Objects, and
    /// Edit in Stack Editor opens Stacks (Spec 11 §2). Edit mode opens as
    /// Mode ▸ Edit does, on that page.
    @discardableResult
    public func open(page: EditPage) -> Bool {
        guard cannotOpen == nil, page.isBuilt else { return false }
        model.settings.editPage = page
        return open()
    }

    private func enter(source: GridContext?, item: String?, list: String?, cue: String?) {
        let wasShow = model.mode == .show
        model.mode = .edit
        if wasShow { isLive = false }
        triedLeaving = false
        standing = nil
        set(source: source, item: item, list: list, cue: cue)
        if wasShow { model.note?(["event": .string("editMode"), "on": .bool(true)], "Edit mode opened") }
        // The Text page's document is made before the window draws it.
        if page == .text { text.opened() }
        model.changed([.layout, .edit, .top])
        if page == .presets { presetsOpened() }
        if page == .objects { objectsOpened() }
    }

    /// Makes a list the Cues page's, on a cue of it: the one named, else its first.
    private func set(source: GridContext?, item: String?, list: String?, cue: String?) {
        if list != listUuid { text.leave() }
        self.source = source
        itemUuid = item
        listUuid = list
        selection = CueGridSelection(cue: nil, channel: nil)
        preview = PreviewPicture()
        previewSubject = nil
        if case .playlist(let playlist)? = source { model.showItems(ofPlaylist: playlist) }
        model.holdEditLists()
        rebuild()
        let order = grid.headers.map(\.uuid)
        let channels = grid.rows.map(\.channel)
        let wanted = cue.flatMap { order.contains($0) ? $0 : nil } ?? order.first
        // The row: the one `view.json` remembers, else the text channel's, where a song is mostly edited.
        let channel = model.settings.editChannel.flatMap { channels.contains($0) ? $0 : nil } ?? store.catalog?.textChannel ?? channels.first
        selection = CueGridSelection(cue: wanted, channel: channel)
        // A list that hasn't arrived yet is selected when it does.
        if wanted == nil { pendingSelect = cue }
        remember()
        askPreview()
    }

    // MARK: - Leaving it (Spec 11 §2)

    /// "Show in the top bar, Escape with nothing else to close (below), or
    /// Mode ▸ Show (⌘1) returns to show mode on the cue the Cues or Text page
    /// has selected: the grid browses where its list came from ... and
    /// scrolls to it, firing nothing ... An open field commits first (Spec
    /// 10 §10). If the engine refuses that commit, edit mode stays on the
    /// field with the reason, and a second try leaves without it."
    /// `commit` commits the open field and says whether it may close.
    @discardableResult
    public func leave(committing commit: () -> Bool = { true }) -> Bool {
        guard model.mode == .edit else { return true }
        if !commit(), !triedLeaving {
            triedLeaving = true
            return false
        }
        // The field's edit is with the engine and not answered yet: edit mode waits for the answer, leaves when
        // it is applied and stays, with the reason, when it is refused.
        if pending > 0, !triedLeaving {
            triedLeaving = true
            leavesWhenAnswered = true
            return false
        }
        close()
        return true
    }

    private func close() {
        triedLeaving = false
        leavesWhenAnswered = false
        model.mode = .show
        let cue = selection.first(in: grid.headers.map(\.uuid))
        if let source { model.browse(source) }
        model.note?(["event": .string("editMode"), "on": .bool(false)], "Edit mode closed")
        model.changed([.layout, .grid, .left, .right, .strip, .top, .pool])
        if let listUuid, let cue { model.onRevealCue?(itemUuid, listUuid, cue) }
    }

    /// "The lock closes edit mode (UX spec, S13) ... When it comes on from
    /// elsewhere, edit mode closes to show mode on the same cue, and an open
    /// field's unsent text is offered in a sheet with Copy".
    func lockCameOn() {
        guard model.mode == .edit else { return }
        onLocked?()
        close()
    }

    // MARK: - The pages and the Browser (Spec 11 §2)

    /// The page picker, and ⌥⌘1 to ⌥⌘6.
    public func show(page: EditPage) {
        guard page.isBuilt, page != self.page else { return }
        acted()
        if self.page == .text { text.leave() }
        model.settings.editPage = page
        if page == .text { text.opened() }
        model.changed([.edit, .top])
        askPreview()
        if page == .presets { presetsOpened() }
        if page == .objects { objectsOpened() }
    }

    public func show(tab: BrowserTab) {
        guard tab != model.settings.browserTab else { return }
        model.settings.browserTab = tab
        model.changed([.edit])
    }

    public func show(mediaView: MediaListView) {
        guard mediaView != model.settings.mediaView else { return }
        model.settings.mediaView = mediaView
        model.changed([.edit])
    }

    /// "A click on a linked item or on a library list makes it the list the
    /// Cues and Text pages edit, which the Cues page shows at once when it
    /// is the page in view; a double-click opens the Cues page on it from
    /// any page." `item` names the playlist's item; nil takes the first
    /// that shows the list.
    public func choose(list uuid: String, from context: GridContext, item: String?, opening: Bool = false) {
        acted()
        standing = nil
        var item = item
        if item == nil, case .playlist(let playlist) = context, let catalog = store.catalog {
            item = catalog.playlist(uuid: playlist)?.playlist.items.first { GridModel.listUuid(of: $0, catalog: catalog) == uuid }?.uuid.uuidString.lowercased()
        }
        if opening { model.settings.editPage = .cues }
        let remembered = model.settings.editList == uuid ? model.settings.editCue : nil
        set(source: context, item: item, list: uuid, cue: uuid == listUuid ? selection.first(in: grid.headers.map(\.uuid)) : remembered)
        model.changed([.edit, .top])
    }

    /// The top bar's crumb for the Cues page.
    public var crumb: EditCrumb? {
        guard listUuid != nil else { return nil }
        var from: String?
        if case .playlist(let uuid)? = source { from = store.catalog?.playlist(uuid: uuid)?.playlist.title }
        return EditCrumb(source: from, title: grid.title)
    }

    // MARK: - The grid (Spec 11 §4)

    /// The list the page edits, as the app holds it.
    public var list: List? { listUuid.flatMap { store.lists[$0]?.list } }

    /// The selected cues, in the list's order.
    public var selectedCues: [Cue] {
        guard let list else { return [] }
        return list.cues.filter { selection.cues.contains($0.uuid.uuidString.lowercased()) }
    }

    /// The channel the inspector's Channel column shows.
    public var channel: Int? { selection.channel }

    /// Why the page's list can't be edited, or nil when it can: a local
    /// copy, a number another list shares, a read-only library, the lock,
    /// or an engine that is away.
    public var cannotEdit: CannotEdit? {
        guard listUuid != nil else { return .missing }
        return model.cannotEdit(listUuid: listUuid)
    }

    /// Spec 11 §2, "Other clients" — "A page whose object is deleted under it
    /// says "Deleted", with Undo while that delete is the history's top group."
    public var isListDeleted: Bool {
        guard let listUuid, let catalog = store.catalog else { return false }
        return catalog.list(uuid: listUuid) == nil
    }

    /// Whether the history's top group is a delete, which Undo would take back.
    public var canUndoDelete: Bool {
        guard isListDeleted, let step = model.undoStep else { return false }
        return HistoryKind.of(text: step.text) == .remove
    }

    /// Brings the grid up to date with the store. The selection follows the
    /// list: cues deleted elsewhere leave it, and a cue this page inserted
    /// is selected when it arrives.
    func rebuild() {
        let was = grid.headers.map(\.uuid)
        section = nil
        guard let catalog = store.catalog else {
            grid = CueGridModel()
            return
        }
        let shown = model.gridModel(for: source)
        section = shown.sections.first { $0.kind == .list && $0.listUuid == listUuid && (itemUuid == nil || $0.itemUuid == itemUuid) }
            ?? shown.sections.first { $0.kind == .list && $0.listUuid == listUuid }
        grid = CueGridModel.make(document: listUuid.flatMap { store.lists[$0] }, section: section, catalog: catalog, media: store.media,
                                 folds: model.settings.foldedRows)
        let hidden = Set(model.settings.hiddenRows)
        for index in grid.rows.indices { grid.rows[index].isHidden = hidden.contains(grid.rows[index].channel) }
        let order = grid.headers.map(\.uuid)
        let channels = grid.rows.map(\.channel)
        if let pending = pendingSelect, order.contains(pending) {
            selection.click(cue: pending, row: selection.row)
            pendingSelect = nil
        }
        selection.reconcile(order: order, channels: channels, was: was)
        if page == .text { text.refresh() }
    }

    /// What the store changed, while edit mode is open.
    func storeChanged(_ changes: Set<StoreChange>) {
        if changes.contains(.engine), cannotOpen != nil {
            lockCameOn()
            return
        }
        // Spec 11 §5, "Near the live cue" — the Text page's chunks hold back while an output shows a box ahead.
        if page == .text, changes.isDisjoint(with: [.connection, .catalog, .lists, .live, .thumbnails, .media]),
           !changes.isDisjoint(with: [.outputs, .stacks]) {
            text.refresh()
            return
        }
        guard !changes.isDisjoint(with: [.connection, .catalog, .lists, .live, .thumbnails, .media]) else { return }
        let before = selection
        rebuild()
        if selection != before { remember() }
        // "It is asked for again after each `library` event that names the list or anything it draws."
        if !changes.isDisjoint(with: [.connection, .catalog, .lists, .media]) { askPreview(again: true) }
        // Spec 11 §8 — the layout's picture is "asked for again after each edit", and Used by with it.
        if page == .presets, !changes.isDisjoint(with: [.connection, .catalog, .media]) {
            askLayout(again: true)
            askPresetUses(again: true)
            if changes.contains(.connection) { askFonts(again: true) }
        }
        // Spec 11 §9 — "A grade on air changes from the next frame": its picture is asked for again after each edit.
        if page == .objects, !changes.isDisjoint(with: [.connection, .catalog, .media]) {
            askObjectUses(again: true)
            askGrade(again: true)
        }
    }

    /// Spec 5 §2 — a `library` event, which the Text page reads for its
    /// caret's chunk (Spec 11 §5, "Other clients" and "Undo"); the documents
    /// it names come after it, asked for again by the session.
    func libraryChanged(_ event: LibraryChangeEvent) {
        text.event(event)
    }

    /// The preview stack or another setting changed.
    func settingsChanged() {
        rebuild()
        askPreview()
        if page == .presets { askLayout() }
        if page == .objects { askGrade() }
    }

    private func acted() {
        triedLeaving = false
    }

    private func remember() {
        var settings = model.settings
        if case .playlist(let uuid)? = source { settings.editPlaylist = uuid } else { settings.editPlaylist = nil }
        settings.editItem = itemUuid
        settings.editList = listUuid
        settings.editCue = selection.lead ?? selection.first(in: grid.headers.map(\.uuid))
        settings.editChannel = selection.channel
        if settings != model.settings { model.settings = settings }
    }

    private func selectionChanged() {
        acted()
        remember()
        model.changed([.edit])
        askPreview()
    }

    /// A click on a cell or a header, by the cue's place in the list:
    /// "⇧-click selects a range of cues and ⌘-click adds or removes one".
    public func click(cue index: Int, row: CueGridSelection.Row, shift: Bool = false, command: Bool = false) {
        guard grid.headers.indices.contains(index) else { return }
        let order = grid.headers.map(\.uuid)
        let was = selection.lead
        if shift {
            selection.extend(to: order[index], in: order)
            selection.set(row)
        } else if command {
            selection.toggle(cue: order[index], in: order)
            selection.set(row)
        } else {
            selection.click(cue: order[index], row: row)
        }
        selectionChanged()
        // Spec 11 §2 — Live: "each cue the selection moves onto, by the arrow keys or a click, is fired with
        // `state` ... ⇧ and ⌘ with a click or an arrow only select".
        if isLive, !shift, !command, selection.lead != was { _ = fire(withState: true) }
    }

    /// Spec 11 §4 — "A click on a band selects its run's cues, ⇧ and ⌘
    /// extending the selection as on a header", by the place of a cue under it.
    public func clickBand(cue index: Int, shift: Bool = false, command: Bool = false) {
        guard let run = grid.runs.first(where: { index >= $0.first && index < $0.first + $0.count }) else { return }
        let order = grid.headers.map(\.uuid)
        let cues = (run.first..<min(order.count, run.first + run.count)).map { order[$0] }
        selection.select(run: cues, in: order, extend: shift, add: command)
        selectionChanged()
    }

    /// A click on a row's name: the row is selected, and the cues stay.
    public func select(row: CueGridSelection.Row) {
        selection.set(row)
        selectionChanged()
    }

    /// Spec 11 §5 — the caret entered a cue's chunk: the cue is the page's
    /// selection, which the Preview monitor shows and leaving edit mode
    /// returns to (Spec 11 §2). Typing never fires, Live or not: Live is the
    /// cue grid's (Area 10 reading).
    func selectFromText(cue: String) {
        let order = grid.headers.map(\.uuid)
        guard selection.lead != cue || selection.isMulti else { return }
        if order.contains(cue) {
            selection.click(cue: cue, row: .channel(text.channel))
        } else {
            pendingSelect = cue
        }
        remember()
        model.changed([.edit])
        askPreview()
    }

    /// The arrows, with the grid focused.
    public func move(_ direction: CueGridSelection.Direction, extend: Bool) {
        let was = selection.lead
        selection.move(direction, extend: extend, order: grid.headers.map(\.uuid), channels: grid.rows.map(\.channel))
        selectionChanged()
        // Spec 11 §2 — Live: "each cue the selection moves onto, by the arrow keys or a click, is fired with `state`".
        if isLive, !extend, !selection.isMulti, selection.lead != was { _ = fire(withState: true) }
    }

    /// Spec 11 §2 — "Live ... one toggle beside the page picker, says what
    /// moving the cue grid's selection does. Off, which edit mode always opens
    /// with, it only selects: nothing goes to air." (Adam, 2026-11-24.)
    public private(set) var isLive = false

    public func setLive(_ on: Bool) {
        guard on != isLive else { return }
        isLive = on
        model.changed([.top, .edit])
    }

    /// ‹ and › in the inspector's header: "which move the selection, never the pointer".
    public func step(_ forward: Bool) {
        move(forward ? .right : .left, extend: false)
    }

    /// Spec 11 §4 — a row's eye "hides the channel from the Preview monitor's
    /// picture alone ... Hidden rows are kept by channel number for every
    /// list" (corrected 2026-11-24). A row for a channel number no channel
    /// has has nothing to hide.
    public func toggleHidden(row: Int) {
        guard grid.rows.indices.contains(row), grid.rows[row].exists else { return }
        let channel = grid.rows[row].channel
        var hidden = Set(model.settings.hiddenRows)
        if hidden.contains(channel) { hidden.remove(channel) } else { hidden.insert(channel) }
        model.settings.hiddenRows = hidden.sorted()
        rebuild()
        askPreview()
        model.changed([.edit])
    }

    /// The channels the Preview leaves out, in number order: "the monitor's header says how many are hidden".
    public var hiddenChannels: [Int] {
        grid.rows.filter { $0.isHidden && $0.exists }.map(\.channel)
    }

    /// A row's fold control.
    public func toggleFold(row: Int) {
        guard grid.rows.indices.contains(row) else { return }
        model.settings.foldedRows[grid.rows[row].channel] = !grid.rows[row].isFolded
        rebuild()
        model.changed([.edit])
    }

    /// Spec 11 §4, "Tracking" (G-45) — the switch beside the zoom.
    public var isTracking: Bool { model.settings.gridTracking }

    public func setTracking(_ on: Bool) {
        guard on != model.settings.gridTracking else { return }
        model.settings.gridTracking = on
        model.changed([.edit])
    }

    /// "A click on a block or a line selects the cue that set it, on that channel's row"; elsewhere in a lane, the
    /// cue's cell.
    public func clickLane(cue: Int, row: Int, lane: Int) {
        guard grid.rows.indices.contains(row) else { return }
        let channel = grid.rows[row].channel
        let lanes = grid.rows[row].lanes
        let mark = lanes.indices.contains(lane) && lanes[lane].marks.indices.contains(cue) ? lanes[lane].marks[cue] : .none
        click(cue: mark.settingCue(at: cue) ?? cue, row: .channel(channel))
    }

    /// The header's slider.
    public func zoom(to column: Double) {
        let column = CueGridZoom.clamped(column)
        guard column != model.settings.gridZoom else { return }
        model.settings.gridZoom = column
        model.changed([.edit])
    }

    /// "a pinch on the grid does the same".
    public func pinch(by magnification: Double) {
        zoom(to: CueGridZoom.pinched(model.settings.gridZoom, by: magnification))
    }

    // MARK: - Fire (Spec 11 §4)

    /// The one cue Fire fires: the first selected.
    private var fireCell: CueCell? {
        selection.first(in: grid.headers.map(\.uuid)).flatMap { uuid in grid.headers.first { $0.uuid == uuid } }
    }

    public var fireNote: FireNote {
        guard let section, fireCell != nil, store.cannotSend == nil else { return .unavailable }
        if let refusal = section.refusal { return .refused(refusal) }
        return .fires(in: crumb?.source)
    }

    /// "sends what a click on that cue sends where the page's list came from
    /// (Spec 10 §6) ... Fire is the one control that fires a cue of any list".
    /// `withState`: Live's fire, "fired with `state` where Fire would fire it" (Spec 11 §2).
    @discardableResult
    public func fire(withState: Bool = false) -> Bool {
        guard case .fires = fireNote, let section, let cell = fireCell,
              let sending = model.fire(cell, in: section, context: source, withState: withState) else { return false }
        return model.send(sending)
    }

    // MARK: - The Preview monitor (Spec 11 §4)

    /// The monitor's width in pixels, when it is laid out or its screen changes.
    public func previewWidth(_ pixels: Int) {
        let pixels = min(1920, max(160, pixels))
        guard pixels != previewPixels else { return }
        previewPixels = pixels
        askPreview()
    }

    /// "from `render` with `subject.kind` `cue` at the monitor's width in
    /// pixels (§3), on the stack its picker names". Asked when what it would
    /// draw changes; `again` asks even for the same subject, since the list
    /// itself changed.
    private func askPreview(again: Bool = false) {
        guard model.mode == .edit, page == .cues || page == .text, previewPixels > 0, let listUuid,
              let cue = selection.first(in: grid.headers.map(\.uuid)) else { return }
        let isLocal = store.lists[listUuid]?.local ?? store.catalog?.list(uuid: listUuid)?.local ?? false
        var subject: [String: JSONValue] = ["kind": .string("cue"), "cue": .string(cue), "stack": .number(Double(model.previewStack)),
                                            "width": .number(Double(previewPixels))]
        subject[isLocal ? "local" : "listUuid"] = .string(listUuid)
        // Spec 11 §3 — "optionally `hide`": the hidden rows' channels (§4).
        let hidden = hiddenChannels
        if !hidden.isEmpty { subject["hide"] = .array(hidden.map { .number(Double($0)) }) }
        guard again || subject != previewSubject else { return }
        previewSubject = subject
        subject["width"] = nil
        previewAsked += 1
        let asked = previewAsked
        model.ask(.query("render", ["canvas": .string("preview"), "subject": .object(subject), "width": .number(Double(previewPixels))])) { [weak self] answer in
            // "a newer request for the same canvas replaces one still waiting, which is answered `{"superseded": true}`".
            guard let self, asked == self.previewAsked, let answer, answer["superseded"] != .bool(true), let file = answer["file"]?.stringValue else { return }
            self.preview = PreviewPicture(file: file, width: answer["width"]?.intValue, height: answer["height"]?.intValue,
                                          isMissing: answer["missing"] == .bool(true))
            self.model.changed([.edit])
        }
    }

    // MARK: - Sending an edit (Spec 11 §2, "Rejections and warnings")

    /// What the inspector's notice line says now.
    public var notice: EditNotice? {
        switch model.notices[.inspector] {
        case .rejected(let rejection)?: return .rejected(rejection)
        case .notSent(let cannot)?: return .notSent(cannot)
        default: return standing
        }
    }

    /// Sends one of the page's edits. A list that can't be edited sends
    /// nothing and says why; a refusal is said in the notice line; an
    /// applied edit's warnings stand there until the next edit. `done` hears
    /// an edit that was applied; `answered`, whatever the answer was.
    @discardableResult
    func send(_ sending: Sending?, then done: (@MainActor (CommandOutcome) -> Void)? = nil,
              answered: (@MainActor () -> Void)? = nil) -> CannotEdit? {
        acted()
        guard let sending, sending.request != nil else { return nil }
        standing = nil
        model.dismissNotice(at: .inspector)
        // A list that can't be edited holds back the Cues page's edits alone: a stack, a channel or a preset is the
        // library's, whichever list the Cues page last showed.
        if page == .cues || page == .text, let cannot = cannotEdit {
            model.say(.notSent(cannot), at: .inspector)
            return cannot
        }
        // The lock, a read-only library or an engine that is away: nothing is sent, and the line says why.
        let unavailable = store.cannotEdit(master: true) ?? store.cannotSend
        guard unavailable == nil, let transmit = model.transmit, let request = sending.request else {
            let cannot = CannotEdit.unavailable(unavailable ?? .engineAway)
            model.say(.notSent(cannot), at: .inspector)
            return cannot
        }
        noteOnAir()
        pending += 1
        transmit(request) { [weak self] reply in
            defer { answered?() }
            guard let self else { return }
            self.pending = max(0, self.pending - 1)
            guard let outcome = reply?.outcome else {
                self.leavesWhenAnswered = false
                return
            }
            if outcome.kind == .rejected {
                // "If the engine refuses that commit, edit mode stays on the field with the reason".
                self.leavesWhenAnswered = false
                self.model.say(.rejected(outcome.rejection ?? EngineRejection(code: "", message: "")), at: .inspector)
                return
            }
            if !outcome.warnings.isEmpty {
                self.standing = .warnings(outcome.warnings)
                self.model.changed([.edit])
            }
            done?(outcome)
            if self.leavesWhenAnswered, self.pending == 0, self.model.mode == .edit { self.close() }
        }
        model.changed([.edit])
        return nil
    }

    /// "The first edit in a run to something on air says so": an edit to a
    /// cue the confidence screen shows ahead of time is on air at once, on
    /// the outputs that look ahead. Said once for a selection, until another is made.
    private func noteOnAir() {
        guard page == .cues, let catalog = store.catalog, let listUuid, let list else { return }
        let live = store.live
        let liveList = live.listUuid.flatMap { store.lists[$0]?.list }
        let liveIndex = live.cue.flatMap { cue in liveList?.cues.firstIndex { $0.uuid.uuidString.lowercased() == cue } }
        // The list where it is live: the live item of the live playlist, or the list fired from the library.
        var isLive = live.listUuid == listUuid
        var isNext = false
        if case .playlist(let playlist)? = source, let entry = catalog.playlist(uuid: playlist)?.playlist {
            isLive = isLive && live.playlist == playlist && live.item == itemUuid
            if live.playlist == playlist, let at = entry.items.firstIndex(where: { $0.uuid.uuidString.lowercased() == live.item }) {
                let after = entry.items[(at + 1)...].first { GridModel.listUuid(of: $0, catalog: catalog) != nil }
                isNext = after.map { $0.uuid.uuidString.lowercased() == itemUuid } ?? false
            }
        } else {
            isLive = isLive && live.isLibraryList
        }
        let ahead = EditOnAir.lookahead(isLive: isLive, isNext: isNext, liveIndex: liveIndex, liveCount: liveList?.cues.count ?? 0)
        let edited = list.cues.indices.filter { ahead.contains($0) && selection.cues.contains(list.cues[$0].uuid.uuidString.lowercased()) }
        guard !edited.isEmpty, saidOnAir != selection.cues else { return }
        let outputs = EditOnAir.lookaheadOutputs(catalog: catalog, dots: model.outputDots)
        guard !outputs.isEmpty else { return }
        saidOnAir = selection.cues
        standing = .onAir(outputs: outputs)
    }

    /// The cell the Channel column edits: the first selected cue, on the inspector's channel.
    private var target: (cue: Cue, channel: Int, list: Int)? {
        guard let list, let channel, let cue = selectedCues.first else { return nil }
        return (cue, channel, list.number)
    }

    // MARK: - The Channel column (Spec 11 §4)

    /// Clear and Hold on the selected cell; Write goes through the content popover (`write`).
    public func set(_ state: CueGridCell.State) {
        guard let target, !selection.isMulti else { return }
        switch state {
        case .clear: send(CueEdits.clear(channel: target.channel, cue: target.cue, list: target.list))
        case .hold:
            // "On a "No channel" row the only action is Hold".
            if grid.row(of: target.channel).map({ !grid.rows[$0].exists }) ?? false {
                send(CueEdits.holdMissing(channel: target.channel, cue: target.cue, list: target.list))
            } else {
                send(CueEdits.hold(channel: target.channel, cue: target.cue, list: target.list))
            }
        case .write: break
        }
    }

    /// The content popover commits: "the cell writes nothing until something is chosen".
    public func write(_ content: ContentExpression) {
        guard let target, !selection.isMulti else { return }
        if case .media(let item) = content { model.settings.used(media: item.ref) }
        send(CueEdits.write(content, channel: target.channel, cue: target.cue, list: target.list))
    }

    /// A media item picked in the popover or dropped on a cell, by the cue's
    /// place and the channel: "with the item's default grade as a `grade G once` rider".
    public func pick(media id: String, cue index: Int, channel: Int) {
        guard let list, list.cues.indices.contains(index) else { return }
        let grade = store.media.first { $0.id == id }?.entry.defaults.grade
        model.settings.used(media: id)
        send(CueEdits.pick(media: id, defaultGrade: grade, channel: channel, cue: list.cues[index], list: list.number))
    }

    /// The content popover commits a media item, with its trim and loop.
    /// The item the cell writes already is that write edited, and keeps
    /// every rider; another item is a new pick, as a drop is.
    public func pick(_ content: MediaContent) {
        guard let target, !selection.isMulti else { return }
        if case .write(.media(let before), _) = CueSays.about(target.channel, in: target.cue).state, before.ref == content.ref {
            return write(.media(content))
        }
        let grade = store.media.first { $0.id == content.ref }?.entry.defaults.grade
        model.settings.used(media: content.ref)
        send(CueEdits.pick(content, defaultGrade: grade, channel: target.channel, cue: target.cue, list: target.list))
    }

    /// A chip's popover commits, over the selected cues.
    public func setChip(_ attribute: CueAttribute) {
        guard let list, let channel else { return }
        let change = CueEdits.set(attribute, channel: channel, cues: selectedCues, list: list.number)
        send(change.sending)
        if change.skipped > 0 {
            standing = .skipped(change.skipped)
            model.changed([.edit])
        }
    }

    /// A chip's Remove, over the selected cues.
    public func removeChip(_ kind: CueAttribute.Kind) {
        guard let list, let channel else { return }
        send(CueEdits.remove(kind, channel: channel, cues: selectedCues, list: list.number))
    }

    // MARK: - The Cue and Trigger columns (Spec 11 §4)

    private func each(_ make: (Cue, Int) -> Sending?) {
        guard let list else { return }
        send(CueEdits.group(selectedCues.map { make($0, list.number) }))
    }

    public func setLabel(_ label: String) {
        guard !selection.isMulti else { return }
        each { CueEdits.label(label, cue: $0, list: $1) }
    }

    /// The section, over the selected cues: "`edit.set` for the section and the trigger". One cue carries it on
    /// to the cues after it that shared its old one (Spec 11 §4, "A section carries forward in the editor alone");
    /// "With several cues selected it is set on those alone."
    public func setSection(_ section: String) {
        guard let list else { return }
        if !selection.isMulti, let cue = selectedCues.first {
            send(CueEdits.sectionRun(section, from: cue, in: list))
        } else {
            each { CueEdits.section(section, cue: $0, list: $1) }
        }
    }

    public func setNote(_ note: String) {
        guard !selection.isMulti else { return }
        each { note == $0.note ? nil : Edits.note(note, list: $1, cue: $0.uuid) }
    }

    public func setTrigger(_ kind: CueTrigger.Kind) {
        each { cue, list in
            guard cue.trigger.kind != kind else { return nil }
            var trigger = cue.trigger
            trigger.kind = kind
            return Edits.trigger(trigger, list: list, cue: cue.uuid)
        }
    }

    public func setAdvanceAfter(ms: Int?) {
        each { $0.advanceAfterMs == ms ? nil : Edits.advanceAfter(ms: ms, list: $1, cue: $0.uuid) }
    }

    // MARK: - Cues (Spec 11 §4, "Selecting")

    /// New Cue After the selected cue, or at the end for the + header: "and the page selects it".
    public func newCue(atEnd: Bool) {
        guard let list else { return }
        let uuid = makeUuid()
        let sending = CueEdits.newCue(uuid: uuid, after: atEnd ? nil : selectedCues.last, in: list)
        if send(sending) == nil { pendingSelect = uuid.uuidString.lowercased() }
    }

    public func duplicate() {
        each { cue, list in CueEdits.duplicate(cue: cue, list: list) }
    }

    public func duplicateSection() {
        guard let list, let cue = selectedCues.first else { return }
        send(Edits.duplicateSection(list: list.number, cue: cue.uuid))
    }

    /// Move Earlier and Move Later: the selected cues, one place.
    public func moveSelected(earlier: Bool) {
        guard let list, let first = selectedCues.first, let last = selectedCues.last,
              let from = list.position(of: first.uuid), let to = list.position(of: last.uuid) else { return }
        // Positions count from 1: ahead of the cue before the first, or past the cue after the last.
        let before = earlier ? from - 2 : to + 1
        guard before >= 0, before <= list.cues.count else { return }
        send(CueEdits.move(cues: selectedCues, before: before, in: list))
    }

    /// A header dropped at a new place: the selected cues when the dragged one is among them, else that one.
    public func drop(cue index: Int, before: Int) {
        guard let list, list.cues.indices.contains(index) else { return }
        let dragged = list.cues[index]
        let cues = selection.cues.contains(dragged.uuid.uuidString.lowercased()) ? selectedCues : [dragged]
        send(CueEdits.move(cues: cues, before: before, in: list))
    }

    /// Delete and Forward Delete with the grid focused, and the menu's
    /// Delete: "With a channel's row selected ... returns the selected cells
    /// to Hold ... With the header row selected it deletes the selected cues".
    public func delete() {
        guard let list else { return }
        if case .channel(let channel) = selection.row {
            let missing = grid.row(of: channel).map { !grid.rows[$0].exists } ?? false
            send(CueEdits.group(selectedCues.map { cue in
                missing ? CueEdits.holdMissing(channel: channel, cue: cue, list: list.number) : CueEdits.hold(channel: channel, cue: cue, list: list.number)
            }))
        } else {
            deleteCues()
        }
    }

    /// The menu's Delete: "Deleting cues asks first only when the cues hold
    /// edits, or include the live cue or the armed one (choice A-11)".
    public func deleteCues() {
        guard let list else { return }
        let cues = selectedCues
        guard !cues.isEmpty else { return }
        let sending = CueEdits.remove(cues: cues, list: list.number)
        let live = grid.headers.first(where: \.isLive)?.uuid
        let armed = grid.headers.first(where: \.isArmed)?.uuid
        guard CueEdits.deleteAsks(cues: cues, live: live, armed: armed) else {
            send(sending)
            return
        }
        let uuids = Set(cues.map { $0.uuid.uuidString.lowercased() })
        let question = Confirmation.deleteCues(count: cues.count, live: live.map(uuids.contains) ?? false, armed: armed.map(uuids.contains) ?? false,
                                               edits: CueEdits.deleteAsks(cues: cues, live: nil, armed: nil))
        model.ask(question) { [weak self] in self?.send(sending) }
    }

    // MARK: - The Commands column (Spec 11 §4)

    private var onlyCue: (cue: Cue, list: Int)? {
        guard let list, !selection.isMulti, let cue = selectedCues.first else { return nil }
        return (cue, list.number)
    }

    /// The palette's Add: "inserts the command after the selected one, or at the end".
    public func insertCommand(_ command: Command, after position: Int?) {
        guard let found = onlyCue else { return }
        send(CueEdits.insert(command, after: position, cue: found.cue, list: found.list))
    }

    public func setCommand(_ command: Command, at position: Int) {
        guard let found = onlyCue else { return }
        send(CueEdits.setCommand(command, at: position, cue: found.cue, list: found.list))
    }

    public func removeCommand(at position: Int) {
        guard let found = onlyCue else { return }
        send(CueEdits.removeCommand(at: position, cue: found.cue, list: found.list))
    }

    public func moveCommand(at position: Int, up: Bool) {
        guard let found = onlyCue else { return }
        send(CueEdits.moveCommand(at: position, up: up, cue: found.cue, list: found.list))
    }

    /// Commands as text commits. Returns false while a line has an error:
    /// "with one, nothing is sent, and leaving asks Keep Editing or Discard Changes".
    @discardableResult
    public func setCommands(text: String) -> Bool {
        guard let found = onlyCue else { return true }
        if CommandsText.hasErrors(text, cue: found.cue, options: parseOptions) { return false }
        send(CommandsText.edit(text, cue: found.cue, list: found.list, options: parseOptions))
        return true
    }

    /// What OCore's parser needs to read a media name or a number as this machine has them.
    public var parseOptions: ParseOptions {
        ParseOptions(mediaIDs: Set(store.media.map(\.id)))
    }

    // MARK: - The list (Spec 11 §4, "The list")

    /// Spec 11 §4 — "the other's opens read-only, offering to renumber the
    /// first, after which each has a number of its own." An edit by the
    /// shared number reaches the list that comes first (Spec 7 §2), which is
    /// the one this renumbers.
    public func renumberOther(to number: Int) {
        guard let list, cannotEdit == .renumberToEdit, number != list.number else { return }
        acted()
        if let cannot = model.commit(CueEdits.renumber(list: list.number, to: number), master: true, at: .inspector) {
            model.say(.notSent(cannot), at: .inspector)
        }
    }

    /// "Renumber… (`edit list N renumber M`, or Swap for a taken number)".
    public func renumber(to number: Int) {
        guard let list, number != list.number, let catalog = store.catalog else { return }
        let taken = catalog.lists.contains { $0.number == number && !$0.local }
        send(taken ? CueEdits.swap(list: list.number, with: number) : CueEdits.renumber(list: list.number, to: number))
    }
}
