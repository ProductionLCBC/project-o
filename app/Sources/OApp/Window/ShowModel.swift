// OApp — Spec 10 §4–§8, the show-mode window's model: what the operator chose, what each region shows, what each action sends.

import Foundation
import OCore

/// Spec 10 §1 — "What the app shows comes from the engine's events and
/// queries (§3). It keeps no state of its own apart from its view settings
/// (§4) and the operator's selection." This holds that state — what the grid
/// browses, the strip's selection, the view settings, the search fields —
/// builds each region's model from the store, and sends each action through
/// the session. The views draw what it holds and call its functions; no view
/// composes a command.
@MainActor
public final class ShowModel {
    /// What changed, so a region redraws only for its own.
    public enum Change: Hashable, Sendable {
        case grid, left, right, strip, top, pool
        /// Only where the regions sit: a divider moved.
        case layout
        /// Only what a cue's cell or a strip's cell says about a drop: an import's progress, or why nothing was sent.
        case dropNotes
        /// Edit mode's regions: its Browser, workspace, monitors and inspector (Spec 11 §2).
        case edit
    }

    /// Spec 10 §4, the Mode menu — "Show ⌘1; Edit ⌘2". Edit mode's own model
    /// opens and closes it (Spec 11 §2).
    public internal(set) var mode = WindowMode.show
    /// Spec 11 — edit mode, beside this model.
    public private(set) lazy var editing = EditModel(model: self)
    /// Leaving edit mode: "the grid browses where its list came from ... and
    /// scrolls to it, firing nothing" (Spec 11 §2). The playlist's item, or
    /// nil from the Library window; the list; the cue.
    public var onRevealCue: ((_ item: String?, _ list: String, _ cue: String) -> Void)?

    public let store: ShowStore
    private let clock: any AppClock

    /// How a request reaches the engine: the session's `send`. Nil while no engine is connected.
    public var transmit: ((EngineRequest, @escaping (Reply?) -> Void) -> Void)?
    /// Which lists the session should hold whole (Spec 10 §3).
    public var hold: ((Set<String>) -> Void)?
    /// The system's double-click interval (Spec 10 §6).
    public var doubleClickInterval: () -> TimeInterval = { 0.5 }
    /// Called after a change, with the regions it touches.
    public var onChange: ((Set<Change>) -> Void)?
    /// Called when the grid should bring the live cue into view (Spec 10 §6, "Following the live cue").
    public var onFollowLive: (() -> Void)?
    /// How the window asks before a delete or a restore: a sheet with
    /// Cancel and the button that does it (Spec 10 §4, §9). With no window
    /// to ask, nothing that needs asking is done.
    public var confirm: ((Confirmation, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// How a note reaches the engine's command log (Spec 10 §3, "Notes"):
    /// the session's `note` request. Nil while no engine is connected, and
    /// then nothing is noted and nothing kept to note later.
    public var note: ((_ fields: [String: JSONValue], _ text: String) -> Void)?
    /// Called when a view setting changed, with the settings as they stand: what writes `view.json` (Spec 10 §4).
    public var onSettings: ((ViewSettings) -> Void)?
    /// Called with what VoiceOver should be told as the show moves (Spec 10 §15).
    public var onAnnounce: ((Announcement) -> Void)?
    /// Spec 10 §15, "Reduce Motion" — the system's setting, which the window keeps this at.
    public var reducesMotion = false

    // MARK: What the operator chose

    public private(set) var browse = BrowseState()
    public private(set) var selection = StripSelection()
    public internal(set) var settings = ViewSettings() {
        didSet { if settings != oldValue, !isLoadingSettings { onSettings?(settings) } }
    }
    private var isLoadingSettings = false
    public private(set) var expandedPlaylists: Set<String> = []
    public private(set) var gridSearch = ""
    public private(set) var librarySearch = ""
    public private(set) var poolFilter = MediaPool.Filter()
    public private(set) var selectedMedia: String?
    /// Spec 10 §13 — whether this run made the machine's outputs, and whether the first window's line was dismissed.
    public var isFirstRun = false
    public private(set) var firstLineDismissed = false

    // MARK: What happened lately

    /// Spec 10 §7 — "the row says why for three seconds".
    public private(set) var why: WhyNothing?
    private var whyTask: (any ClockTask)?
    public private(set) var remote = RemoteDot()
    /// Spec 10 §6 — lists whose master reloaded from disk and haven't been fired since.
    public private(set) var updated: Set<String> = []
    /// Spec 10 §7 — a transition under way on a channel: when it started, on the app's clock, and its length.
    public private(set) var transitions: [Int: (startedAt: TimeInterval, ms: Int)] = [:]
    /// Spec 10 §7 — "Stepped on, it flashes red; a write blocked by the channel's lock makes the lock tag flash": until when.
    public private(set) var steppedOnUntil: [Int: TimeInterval] = [:]
    public private(set) var blockedUntil: [Int: TimeInterval] = [:]
    /// Spec 10 §7 — "For three seconds after a fire enters another list, a "reset" mark shows".
    public private(set) var resetUntil: TimeInterval?
    public var follow = FollowLive()
    private var gate = CuePressGate()
    private var removed: (index: Int, section: GridSection)?
    /// Spec 10 §10 — the short messages standing now, each beside what was tried, and when each goes.
    public internal(set) var notices: [NoticePlace: Notice] = [:]
    var noticeTasks: [NoticePlace: any ClockTask] = [:]
    /// Spec 10 §6, "Importing" — the files on their way in, and what waits on each.
    public private(set) lazy var imports = MediaImports(model: self)
    /// Spec 10 §14 — what the app saw of the engine that ended: its last `live` event and its timers.
    public internal(set) var lastSeen: RestoreBanner.LastSeen?
    /// Spec 10 §14 — since when, on the app's clock, the engine has counted documents waiting to be written.
    private var unsavedSince: TimeInterval?
    private var unsavedTask: (any ClockTask)?
    private var announcer = LiveAnnouncer()

    /// The grid as it stands; rebuilt when what it shows changes.
    public private(set) var grid = GridModel()

    public init(store: ShowStore, clock: any AppClock) {
        self.store = store
        self.clock = clock
        store.observe { [weak self] changes in self?.storeChanged(changes) }
        store.observeMoments { [weak self] moment in self?.happened(moment) }
    }

    func changed(_ changes: Set<Change>) {
        onChange?(changes)
    }

    /// The app's clock, for a view that times something of its own.
    public var now: TimeInterval { clock.now }

    /// Runs `work` on the app's clock, `seconds` from now.
    @discardableResult
    func later(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask {
        clock.after(seconds, work)
    }

    /// A channel's label, for a chip's words.
    public func channelLabel(_ number: Int) -> String {
        store.catalog?.channels.first { $0.number == number }?.label ?? ""
    }

    // MARK: - The store

    private func storeChanged(_ changes: Set<StoreChange>) {
        var out: Set<Change> = []
        if changes.contains(.connection) {
            // What is live at a connection is where things stand, not a change to announce (Spec 10 §15).
            announcer.reset()
            out.formUnion([.grid, .left, .right, .strip, .top, .pool])
            // "the engine ending drops it too and may lose the import" (Spec 10 §6).
            if !store.isConnected {
                imports.engineEnded()
                // What the next engine's banner may offer again (Spec 10 §14): the store still holds what it last heard.
                if store.catalog != nil { lastSeen = RestoreBanner.LastSeen(live: store.live, timers: Array(store.timers.values)) }
                unsavedSince = nil
            }
        }
        if changes.contains(.saving) { savingChanged() }
        if changes.contains(.live) {
            if store.hasState { announcer.live(store.live).forEach { onAnnounce?($0) } }
            if store.hasState { browse.connected(live: store.live, lastBrowsed: knownLastBrowsed) }
            // "until the list is next fired": the list the pointer is in has been fired.
            if let list = store.live.listUuid, store.live.cue != nil { updated.remove(list) }
            if !store.live.gone.contains("item") { removed = nil }
            holdLists()
            out.formUnion([.grid, .left, .right, .top])
        }
        if !changes.isDisjoint(with: [.catalog, .lists]) {
            // With nothing live, the grid opens on "the last thing browsed" once the catalog says it is still there.
            if store.hasState { browse.connected(live: store.live, lastBrowsed: knownLastBrowsed) }
            selection.keep(only: stripChannels)
            holdLists()
            out.formUnion([.grid, .left, .right, .strip, .top, .pool])
        }
        if changes.contains(.thumbnails) { out.insert(.grid) }
        if changes.contains(.media) { out.formUnion([.grid, .pool, .strip]) }
        if !changes.isDisjoint(with: [.channels, .stacks]) { out.formUnion([.strip, .right, .top]) }
        // "an output that stops presenting" is announced (Spec 10 §15).
        if !changes.isDisjoint(with: [.outputs, .stacks, .catalog]), store.hasState, store.catalog != nil {
            announcer.outputs(outputDots).forEach { onAnnounce?($0) }
        }
        if !changes.isDisjoint(with: [.outputs, .audio, .popups, .timers, .engine, .saving, .history, .devices]) { out.formUnion([.right, .top]) }
        // The lock comes on or off: the buttons that edit show enabled or disabled with the reason (Spec 10 §10); and
        // the engine says what became of the last state, which the banner over the grid shows (§14).
        if changes.contains(.engine) { out.formUnion([.left, .pool, .grid]) }
        if out.contains(.grid) { rebuildGrid() }
        if changes.contains(.live), grid.liveCell != nil { followLiveSoon() }
        // Spec 11 §2 — edit mode follows the store too, and the lock closes it.
        if mode == .edit {
            editing.storeChanged(changes)
            out.insert(.edit)
        }
        changed(out)
    }

    private func happened(_ moment: StoreMoment) {
        let now = clock.now
        switch moment {
        case .boundary(let reset):
            guard reset else { return }
            resetUntil = now + 3
            after(3) { [weak self] in self?.changed([.strip]) }
            changed([.strip])
        case .channel(let moment):
            if let transition = moment.transition, transition.ms > 0 {
                transitions[moment.channel] = (now, transition.ms)
                after(Double(transition.ms) / 1000) { [weak self] in
                    self?.transitions[moment.channel] = nil
                    self?.changed([.strip])
                }
            }
            if moment.steppedOn { steppedOnUntil[moment.channel] = now + 1 }
            if moment.blocked { blockedUntil[moment.channel] = now + 1 }
            if moment.steppedOn || moment.blocked { after(1) { [weak self] in self?.changed([.strip]) } }
            // "a write a lock blocked or that stepped on a transition" (Spec 10 §15).
            announcer.channel(moment).forEach { onAnnounce?($0) }
            changed([.strip])
        case .remote(let sources):
            remote.arrived(from: sources, at: now)
            after(RemoteDot.glow) { [weak self] in self?.changed([.top]) }
            changed([.top])
        case .library(let event):
            // Spec 5 §2 — cause `file`: a master reloaded from disk (Spec 1 §8).
            guard event.cause == "file" else { return }
            for change in event.changed where change.object == "list" || change.object == "cue" {
                if let uuid = change.address.text("listUuid") { updated.insert(uuid) }
            }
        case .media(let event):
            // Spec 8 §7 — an import's progress and its outcome, by its job.
            imports.event(event)
        case .command(let event):
            // Spec 10 §15 — the command that moves the pointer gives the next `live` change its source.
            announcer.command(event)
        }
    }

    @discardableResult
    private func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any ClockTask {
        clock.after(seconds, work)
    }

    private func holdLists() {
        var needed = GridModel.listsNeeded(shown: browse.shown, live: store.live, catalog: store.catalog)
        // Spec 11 §4 — the list the Cues page edits, and its playlist's, are held while edit mode is open.
        if mode == .edit {
            needed.formUnion(GridModel.listsNeeded(shown: editing.source, live: store.live, catalog: store.catalog))
            if let list = editing.listUuid { needed.insert(list) }
        }
        hold?(needed)
    }

    /// Edit mode chose another list: the app holds it.
    func holdEditLists() {
        holdLists()
    }

    /// The grid's model for a context other than the one the show grid
    /// browses: edit mode's list, where it came from (Spec 11 §4).
    func gridModel(for context: GridContext?) -> GridModel {
        var inputs = GridInputs(context: context, catalog: store.catalog)
        inputs.lists = store.lists
        inputs.thumbnails = store.thumbnails
        inputs.media = store.media
        inputs.live = store.live
        inputs.updated = updated
        return GridModel.make(inputs)
    }

    private func rebuildGrid() {
        var inputs = GridInputs(context: browse.shown, catalog: store.catalog)
        inputs.lists = store.lists
        inputs.thumbnails = store.thumbnails
        inputs.media = store.media
        inputs.live = store.live
        inputs.search = gridSearch
        inputs.updated = updated
        inputs.removed = removed
        let before = grid
        grid = GridModel.make(inputs)
        // Spec 7 §4 — remember the live item's section, so it can stay at its place if the item is removed.
        if !store.live.gone.contains("item"), let index = grid.sections.firstIndex(where: { $0.isLive && $0.kind == .list }) {
            removed = (index, grid.sections[index])
        } else if removed == nil, let index = before.sections.firstIndex(where: { $0.isLive && $0.kind == .list }) {
            removed = (index, before.sections[index])
        }
    }

    // MARK: - Following the live cue (Spec 10 §6)

    private var followTask: (any ClockTask)?

    private func followLiveSoon() {
        let now = clock.now
        if follow.mayScroll(at: now) {
            onFollowLive?()
        } else if let at = follow.catchUpAt(now: now) {
            followTask?.cancel()
            followTask = after(max(0, at - now)) { [weak self] in self?.followLiveSoon() }
        }
        // Held back by a button or a drag: `pointerRested` asks again when it ends.
    }

    /// The pointer left the grid, a button came up or a drag ended: "it catches up".
    public func pointerRested() {
        if grid.liveCell != nil { followLiveSoon() }
    }

    // MARK: - Browsing (Spec 10 §5, §6)

    public var isBrowsing: Bool { browse.isBrowsing(live: store.live) }

    /// "Click a playlist to browse it"; "Click a list to browse it in the grid".
    public func browse(_ context: GridContext) {
        let before = browse.shown
        browse.browse(context)
        if case .list = context { revealedList = nil }
        settings.lastBrowsed = context
        holdLists()
        rebuildGrid()
        changed([.grid, .left, .top])
        if context != before { noteBrowse(context) }
    }

    /// "the last thing browsed", when the catalog still has it.
    private var knownLastBrowsed: GridContext? {
        guard let catalog = store.catalog else { return nil }
        switch settings.lastBrowsed {
        case .playlist(let uuid)?: return catalog.playlist(uuid: uuid) == nil ? nil : .playlist(uuid)
        case .list(let uuid)?: return catalog.list(uuid: uuid) == nil ? nil : .list(uuid)
        case nil: return nil
        }
    }

    /// Spec 10 §3, "Notes" — `browse`: "The grid shows another playlist or
    /// list", with "`playlist` (uuid) or `list` (number)".
    private func noteBrowse(_ context: GridContext) {
        guard let catalog = store.catalog else { return }
        switch context {
        case .playlist(let uuid):
            guard let playlist = catalog.playlist(uuid: uuid)?.playlist else { return }
            note?(["event": .string("browse"), "playlist": .string(uuid)], "The grid shows the playlist \"" + playlist.title + "\"")
        case .list(let uuid):
            guard let list = catalog.list(uuid: uuid) else { return }
            note?(["event": .string("browse"), "list": .number(Double(list.number))], "The grid shows list \(list.number), \"" + list.title + "\"")
        }
    }

    /// "Back to Live (⌘L, or the button) returns the grid to the live
    /// context and scrolls to the live cue; ⌘L also scrolls to the live cue
    /// when it is out of view without browsing."
    public func backToLive() {
        let wasBrowsing = isBrowsing
        browse.backToLive(live: store.live)
        holdLists()
        rebuildGrid()
        changed([.grid, .left, .top])
        onFollowLive?()
        // Spec 10 §3, "Notes" — `backToLive`: noted when it brought the grid back, not when ⌘L only scrolled.
        if wasBrowsing { note?(["event": .string("backToLive")], "Back to live") }
    }

    /// A click on a playlist in the tree: it is browsed, and expanded by §5's rule.
    public func choose(playlist uuid: String, option: Bool) {
        expandedPlaylists = PlaylistTree.expanding(uuid, in: expandedPlaylists, option: option)
        browse(.playlist(uuid))
    }

    public func toggle(folder path: String) {
        var open = Set(settings.openFolders)
        if open.contains(path) { open.remove(path) } else { open.insert(path) }
        settings.openFolders = open.sorted()
        changed([.left])
    }

    public func search(grid text: String) {
        gridSearch = text
        rebuildGrid()
        changed([.grid])
    }

    public func search(library text: String) {
        librarySearch = text
        if !text.isEmpty { revealedList = nil }
        changed([.left])
    }

    // MARK: - Regions' models

    public var playlistRows: [PlaylistRow] {
        guard let catalog = store.catalog else { return [] }
        return PlaylistTree.rows(catalog: catalog, live: store.live, expanded: expandedPlaylists, shown: browse.shown,
                                 showArchived: settings.showsArchivedPlaylists)
    }

    public var libraryRows: [LibraryRow] {
        guard let catalog = store.catalog else { return [] }
        return LibraryTree.rows(catalog: catalog, open: Set(settings.openFolders), search: librarySearch)
    }

    public var nextRow: NextRow { NextRow.make(live: store.live, cannotSend: store.cannotSend) }

    public var livePosition: LivePosition { LivePosition.make(live: store.live, shown: browse.shown) }

    /// The armed countdown's milliseconds left, now.
    public var countdownMs: Int? {
        Countdown.remainingMs(store.live.armed, elapsedMs: Int((clock.now - store.liveAt) * 1000))
    }

    public var outputDots: [OutputDot] {
        OutputDot.all(outputs: store.catalog?.outputs ?? [], status: store.outputs, stackStatus: store.stacks)
    }

    public var tags: [TopBarTag] {
        TopBarTag.all(channels: store.catalog?.channels ?? [], audio: store.audio, popups: store.popups, engine: store.engine, saving: savingTag)
    }

    /// Spec 10 §14, "The saving tag".
    public var savingTag: SavingTag? {
        SavingTag.make(store.saving, unsavedFor: unsavedSince.map { clock.now - $0 })
    }

    /// The engine's count of documents waiting changed: the tag shows once
    /// they "have waited more than five seconds", so the top bar is asked
    /// again then.
    private func savingChanged() {
        if store.saving.unsaved > 0 {
            guard unsavedSince == nil else { return }
            unsavedSince = clock.now
            unsavedTask?.cancel()
            unsavedTask = after(SavingTag.wait + 0.05) { [weak self] in self?.changed([.top]) }
        } else {
            unsavedSince = nil
            unsavedTask?.cancel()
            unsavedTask = nil
        }
    }

    public var isRemoteLit: Bool { remote.isLit(at: clock.now) }

    /// Spec 10 §7 — "The preview shows the selected stack's surface (§2), starting from the thumbnail stack".
    public var previewStack: Int {
        settings.previewStack ?? store.catalog?.settings?.thumbnailStack ?? store.catalog?.stacks.map(\.number).min() ?? 1
    }

    private var stripView: StripView { settings.stripStack.map(StripView.stack) ?? .all }

    private var stripChannels: [Int] {
        stripView.channels(store.catalog?.channels ?? [], stacks: store.catalog?.stacks ?? [])
    }

    private func elapsedMs(channel: Int) -> Int {
        store.channelAt[channel].map { Int((clock.now - $0) * 1000) } ?? 0
    }

    public var stripCells: [StripCell] {
        guard let catalog = store.catalog else { return [] }
        return StripCell.cells(view: stripView, selection: selection, catalog: catalog, channels: store.channels, stackStatus: store.stacks,
                               media: store.media, lists: store.lists, elapsedMs: elapsedMs)
    }

    public var transport: TransportPanel {
        TransportPanel.make(selection: selection.channels, channels: store.channels, elapsedMs: elapsedMs)
    }

    public var clearsTiles: [ClearsTile] {
        let catalog = store.catalog
        return ClearsTile.all(previewStack: previewStack, stacks: catalog?.stacks ?? [], stackStatus: store.stacks, audioOutputs: catalog?.audioOutputs ?? [],
                              audio: store.audio, channels: catalog?.channels.count ?? 0, popupSlots: catalog?.settings?.popups ?? 0,
                              cannotSend: store.cannotSend)
    }

    public var poolTiles: [PoolTile] { MediaPool.tiles(store.media, filter: poolFilter) }

    public var recentTiles: [PoolTile] { MediaPool.recents(store.media, recent: settings.recentMedia) }

    public var firstWindowLine: FirstWindowLine? {
        FirstWindowLine.make(firstRun: isFirstRun, dismissed: firstLineDismissed, outputs: store.catalog?.outputs ?? [])
    }

    /// Whether the "reset" mark shows on the strip now (Spec 10 §7).
    public var showsReset: Bool { resetUntil.map { clock.now < $0 } ?? false }

    /// How far a channel's transition bar has run, 0 to 1, or nil with none under way.
    public func transitionProgress(channel: Int) -> Double? {
        guard let running = transitions[channel], running.ms > 0 else { return nil }
        // Spec 10 §15 — Reduce Motion "shows the transition bar's end state instead of running it".
        if reducesMotion { return 1 }
        return min(1, max(0, (clock.now - running.startedAt) * 1000 / Double(running.ms)))
    }

    public func isSteppedOn(_ channel: Int) -> Bool { steppedOnUntil[channel].map { clock.now < $0 } ?? false }
    public func isBlocked(_ channel: Int) -> Bool { blockedUntil[channel].map { clock.now < $0 } ?? false }

    // MARK: - Sending (Spec 10 §1, §2)

    /// Sends an action's commands. Spec 10 §2 — while the engine is away
    /// "every control that sends something is disabled, and a key that would
    /// send a command is dropped, never queued": with no engine to take it,
    /// nothing is sent and nothing is kept. Returns whether it went.
    @discardableResult
    public func send(_ sending: Sending) -> Bool {
        guard store.cannotSend == nil, let transmit, let request = sending.request else { return false }
        let commands = sending.commands
        transmit(request) { [weak self] reply in
            guard let self, case .result(let outcome)? = reply, commands.count == 1, let command = commands.first else { return }
            self.explain(command, outcome.kind)
        }
        return true
    }

    /// Spec 10 §7, "Why nothing happened".
    private func explain(_ command: Command, _ result: ResultKind) {
        guard let reason = WhyLine.reason(for: command, result: result, live: store.live) else { return }
        why = reason
        whyTask?.cancel()
        whyTask = after(WhyLine.seconds) { [weak self] in
            self?.why = nil
            self?.changed([.right])
        }
        changed([.right])
    }

    // MARK: - The grid's presses (Spec 10 §6)

    /// A press on a cue's cell. Fires on the press, by §6's rules; the result says what the press was.
    @discardableResult
    public func press(cue cell: CueCell, in section: GridSection, option: Bool = false, secondary: Bool = false) -> CuePress {
        let key = (section.itemUuid ?? section.listUuid ?? "") + "/" + cell.uuid
        let press = gate.press(cue: key, at: clock.now, interval: doubleClickInterval(), option: option, secondary: secondary)
        if press == .fire, let sending = fire(cell, in: section) { send(sending) }
        return press
    }

    /// What firing this cue sends, or nil when it can't be fired (Spec 10 §6, "Clicking").
    public func fire(_ cell: CueCell, in section: GridSection) -> Sending? {
        fire(cell, in: section, context: grid.context)
    }

    /// The same for a list shown from `context`, which edit mode's Fire
    /// uses: "sends what a click on that cue sends where the page's list
    /// came from" (Spec 11 §4).
    func fire(_ cell: CueCell, in section: GridSection, context: GridContext?) -> Sending? {
        guard section.refusal == nil, !section.isRemoved, let catalog = store.catalog else { return nil }
        switch context {
        case .playlist(let uuid):
            guard let playlist = catalog.playlist(uuid: uuid), let item = section.item else { return nil }
            return try? GridFire.playlistCue(playlist, item: item, cue: cell.number, live: store.live).get()
        case .list(let uuid):
            guard let list = catalog.list(uuid: uuid) else { return nil }
            return try? GridFire.libraryCue(list, cue: cell.number).get()
        case nil:
            return nil
        }
    }

    // MARK: - The strip (Spec 10 §7)

    public func toggleSelection(_ channel: Int) {
        selection.toggle(channel)
        changed([.strip, .right])
    }

    public func selectOnly(_ channel: Int) {
        selection.selectOnly(channel)
        changed([.strip, .right])
    }

    public func selectAll() {
        selection.selectAll(stripChannels)
        changed([.strip, .right])
    }

    public func selectNone() {
        selection.selectNone()
        changed([.strip, .right])
    }

    /// The strip's view: all channels, or one stack's. A channel the view hides drops out of the selection.
    public func show(stripStack: Int?) {
        settings.stripStack = stripStack
        selection.keep(only: stripChannels)
        changed([.strip, .right])
    }

    // MARK: - The pool (Spec 10 §6)

    public func select(media id: String?) {
        selectedMedia = id
        changed([.pool])
    }

    public func setPool(_ change: (inout MediaPool.Filter) -> Void) {
        change(&poolFilter)
        settings.poolSort = poolFilter.sort
        settings.poolKind = poolFilter.kind
        settings.poolFolder = poolFilter.folder
        changed([.pool])
    }

    /// "Double-click writes it live to its drop channel ... asking for a
    /// channel when that is "Ask"." Sends the live write to `channel`, or to
    /// the item's drop channel; returns false when a channel must be asked for.
    @discardableResult
    public func goLive(media id: String, on channel: Int? = nil) -> Bool {
        guard let item = store.media.first(where: { $0.id == id }),
              let target = channel ?? MediaPool.dropChannel(for: item.entry, settings: store.catalog?.settings) else { return false }
        if send(Actions.liveWrite(media: id, channel: target, defaultGrade: item.entry.defaults.grade)) {
            settings.used(media: id)
            changed([.pool])
        }
        return true
    }

    /// A file dropped on a strip cell has come in: "sends the live write when the job's `done` names the item" (Spec 10 §7).
    func goLive(imported id: String, on channel: Int, defaultGrade: Int?) {
        if send(Actions.liveWrite(media: id, channel: channel, defaultGrade: defaultGrade)) { used(media: id) }
    }

    /// The item was used: it leads the collapsed pool's "twenty most recently used items" (Spec 10 §6, "The divider").
    func used(media id: String) {
        settings.used(media: id)
        changed([.pool])
    }

    // MARK: - The view (Spec 10 §4, §7)

    public func change(_ edit: (inout ViewSettings) -> Void) {
        edit(&settings)
        rebuildGrid()
        // Spec 11 §2 — the monitors show show mode's preview stack, "one choice for both modes".
        if mode == .edit { self.editing.settingsChanged() }
        changed([.grid, .left, .right, .strip, .top, .pool, .edit])
    }

    /// A divider moved: the settings change and the regions are placed again, with nothing redrawn.
    public func resize(_ edit: (inout ViewSettings) -> Void) {
        edit(&settings)
        settings.leftColumnWidth = ViewSettings.clampedLeft(settings.leftColumnWidth)
        settings.rightColumnWidth = ViewSettings.clampedRight(settings.rightColumnWidth)
        settings.leftSplit = min(0.8, max(0.2, settings.leftSplit))
        changed([.layout])
    }

    /// Spec 10 §5 and §6, "Show in Library" — the list is shown in the
    /// Library tree: every folder on its way is opened and its row marked,
    /// until the operator next chooses something there. The grid stays on
    /// what it shows (Area 13 reading: showing where a list lives isn't
    /// browsing it).
    public func showInLibrary(list uuid: String) {
        guard let summary = store.catalog?.list(uuid: uuid), !summary.local else { return }
        var open = Set(settings.openFolders)
        var parts: [String] = []
        for part in summary.folder.split(separator: "/") {
            parts.append(String(part))
            open.insert(parts.joined(separator: "/"))
        }
        settings.openFolders = open.sorted()
        librarySearch = ""
        revealedList = uuid
        changed([.left])
    }

    /// The list "Show in Library" last pointed at, marked in the tree.
    public private(set) var revealedList: String?

    /// "View ▸ Reset Layout puts the defaults back; it's a UI action, not a command."
    public func resetLayout() {
        // What the operator did, and where the window stands, isn't layout: it stays.
        var fresh = ViewSettings()
        fresh.recentMedia = settings.recentMedia
        fresh.windowFrame = settings.windowFrame
        fresh.lastBrowsedPlaylist = settings.lastBrowsedPlaylist
        fresh.lastBrowsedList = settings.lastBrowsedList
        fresh.dismissedRestoreRun = settings.dismissedRestoreRun
        settings = fresh
        poolFilter.sort = settings.poolSort
        poolFilter.kind = settings.poolKind
        poolFilter.folder = settings.poolFolder
        selection.keep(only: stripChannels)
        rebuildGrid()
        changed([.grid, .left, .right, .strip, .top, .pool])
    }

    /// Spec 10 §4 — the settings `view.json` held at launch take the place
    /// of the defaults. Reading them isn't a change, so nothing is written.
    public func load(settings loaded: ViewSettings) {
        isLoadingSettings = true
        settings = loaded
        isLoadingSettings = false
        poolFilter.sort = loaded.poolSort
        poolFilter.kind = loaded.poolKind
        poolFilter.folder = loaded.poolFolder
        selection.keep(only: stripChannels)
        if store.hasState { browse.connected(live: store.live, lastBrowsed: knownLastBrowsed) }
        holdLists()
        rebuildGrid()
        changed([.grid, .left, .right, .strip, .top, .pool, .layout])
    }

    /// "the window's frame": the window was moved or sized. Nothing is drawn again for it.
    public func windowMoved(to frame: [Double]) {
        guard frame.count == 4, settings.windowFrame != frame else { return }
        settings.windowFrame = frame
    }

    public func dismissFirstLine() {
        firstLineDismissed = true
        changed([.grid])
    }
}
