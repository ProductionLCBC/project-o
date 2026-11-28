// OApp — Spec 11 §5, the text editor's state: the caret's chunk, what it has sent, and what others changed.

import Foundation
import OCore

/// Spec 11 §5, "Other clients" — the caret's cue, removed elsewhere: "its
/// text stays, marked "Cue removed", with Add as New Cue and Copy, and
/// nothing is sent until one is chosen."
public struct RemovedChunk: Equatable, Sendable {
    /// The removed cue's uuid, which the chunk keeps as its name.
    public var cue: String
    /// Where it stood, from 0, among the chunks as they are now.
    public var index: Int
    public var text: String
    /// The cue as it was, for Add as New Cue.
    public var was: Cue
}

/// The list's fields the column beside the document edits (Spec 11 §5, "The
/// fields column", G-46): "title, author, copyright, CCLI number, track through".
public enum TextListField: String, CaseIterable, Sendable {
    case title, author, copyright, ccli, trackThrough
}

/// Spec 11 §5 — edit mode's Text page: one list's text on one channel. It
/// keeps the caret's chunk's text as typed until it is sent, sends it as
/// `TypingCadence` paces it, and takes the store's answers for every other
/// chunk. Every edit goes through `EditModel.send`, so a read-only list, the
/// lock and an engine that is away stop it as they stop the Cues page's.
@MainActor
public final class TextEditor {
    unowned let editing: EditModel

    /// The empty list's one chunk, which has no cue yet: "An empty list shows
    /// one empty chunk saying "Type or paste the song's text"."
    public static let emptyChunk = ""

    public private(set) var document = TextDocument(channel: 0)
    /// The chunk with the caret, by its cue's uuid (`emptyChunk` in an empty
    /// list); nil while the editor doesn't have the focus.
    public private(set) var caret: String?
    /// The caret's chunk as typed, kept against every answer until it is sent.
    public private(set) var caretText = ""
    /// Spec 11 §5, "Other clients" — the caret's chunk "says "Changed elsewhere" until it next sends".
    public private(set) var changedElsewhere = false
    public private(set) var removed: RemovedChunk?
    /// Called when an undo or a redo replaced the caret's chunk: "keeping the caret's place in its text where it can".
    public var onReplaced: ((String) -> Void)?
    /// What the page says for a moment in its header, as "Select within one cue." (Spec 11 §5, "Selection").
    public private(set) var notice: String?
    private var noticeTask: (any ClockTask)?
    /// Called with what VoiceOver should hear as the page changes (Spec 11 §10).
    public var onSay: ((String) -> Void)?

    /// Typed since the caret entered: "A chunk the caret passes through without typing sends nothing."
    private var dirty = false
    private lazy var cadence = TypingCadence(clock: editing.model.appClock) { [weak self] text in self?.sendTyping(text) ?? false }
    /// Spec 10 §3 — "An applied edit's result also carries its `group`": the editor's own, which it knows from them.
    public private(set) var ownGroups: Set<String> = []
    /// The cues this editor inserted that the store doesn't hold yet, so the caret can move into one before the
    /// engine answers; each at its place in the list.
    private var inserted: [(cue: Cue, at: Int)] = []
    /// What the caret's cue said about the channel when the editor last sent or entered it.
    private var known: CueSays?
    /// A `library` event from elsewhere named the caret's cue, or an undo or redo did; acted on when the list arrives.
    private var elsewhere = false
    private var replacing = false
    private var lastList: List?

    init(editing: EditModel) {
        self.editing = editing
    }

    private var store: ShowStore { editing.model.store }

    // MARK: - Which text (Spec 11 §5)

    /// Spec 11 §5, "Which text" — "The page opens on the lowest-numbered text
    /// channel (channel 2 on first run), or on the channel whose cell was
    /// double-clicked in the Cues page." The picker's choice stands while the
    /// page is used, and `view.json` keeps it (Spec 11 §2).
    public var channel: Int {
        let channels = store.catalog?.channels.map(\.number) ?? []
        if let chosen = editing.model.settings.editTextChannel, channels.contains(chosen) { return chosen }
        return store.catalog?.textChannel ?? channels.min() ?? 2
    }

    /// The picker's channels: "those whose `usualContent` is text first".
    public var channels: [Channel] {
        store.catalog.map(TextDocument.pickerChannels) ?? []
    }

    /// The header's channel picker.
    public func choose(channel: Int) {
        guard channel != self.channel else { return }
        leave()
        editing.model.settings.editTextChannel = channel
        refresh()
        editing.model.changed([.edit])
    }

    /// The list the page edits, with the cues this editor inserted that the store doesn't hold yet.
    public var list: List? {
        guard var list = editing.list else { return nil }
        for (cue, at) in inserted where !list.cues.contains(where: { $0.uuid == cue.uuid }) {
            list.cues.insert(cue, at: min(max(0, at), list.cues.count))
        }
        return list
    }

    /// Why the list can't be edited, or nil: Spec 11 §5 — "A local copy, or a
    /// list on a `readOnlyMasters` machine, opens read-only (§1)".
    public var cannotEdit: CannotEdit? { editing.cannotEdit }

    /// "An empty list shows one empty chunk".
    public var isEmptyList: Bool { editing.list != nil && document.chunks.isEmpty && removed == nil }

    // MARK: - The document (Spec 11 §5)

    /// The page opened, or its list or channel changed.
    func opened() {
        lastList = nil
        refresh()
    }

    /// Brings the document up to date with the store, keeping the caret's
    /// chunk as typed: "A `library` event patches the chunks it names, never
    /// moving the caret or the scroll."
    func refresh() {
        guard let catalog = store.catalog, let source = editing.list else {
            document = TextDocument(channel: channel)
            return
        }
        // A cue this editor inserted leaves the overlay once the store holds it.
        inserted.removeAll { entry in source.cues.contains { $0.uuid == entry.cue.uuid } }
        guard let list else { return }
        let uuid = list.uuid.uuidString.lowercased()
        document = TextDocument.make(list: list, channel: channel, catalog: catalog, media: store.media,
                                     thumbnails: store.thumbnails[uuid] ?? [:], live: editing.textLive(list: list))
        let changed = source != lastList
        lastList = source
        // Cues arrived under an empty list's caret, from elsewhere: its one chunk is gone, and so is the caret.
        if caret == Self.emptyChunk, !document.chunks.isEmpty { caret = nil }
        guard let caret, caret != Self.emptyChunk, changed || removed == nil else { return }
        guard let chunk = document.chunk(caret), let cue = cue(caret) else {
            // "If its cue is removed elsewhere, its text stays, marked "Cue removed"".
            if removed == nil, let was = lastCue {
                removed = RemovedChunk(cue: caret, index: min(lastIndex, document.chunks.count), text: caretText, was: was)
                cadence.start(caretText, holdsBack: true)
            }
            return
        }
        lastCue = cue
        lastIndex = document.index(of: caret) ?? lastIndex
        cadence.holdsBack = chunk.holdsBack
        guard changed else { return }
        let says = CueSays.about(channel, in: cue)
        if replacing {
            // "An undo or a redo replaces every chunk it names, the caret's included".
            replacing = false
            elsewhere = false
            caretText = Self.editable(chunk)
            dirty = false
            known = says
            changedElsewhere = false
            cadence.start(caretText, holdsBack: chunk.holdsBack)
            onReplaced?(caretText)
        } else if elsewhere {
            // "The chunk with the caret keeps its text, takes the rest of its cue from the event".
            elsewhere = false
            if says != known { changedElsewhere = true }
            known = says
        }
    }

    private var lastCue: Cue?
    private var lastIndex = 0

    /// A cue of the list by its uuid, as the store holds it or as this editor inserted it.
    private func cue(_ uuid: String) -> Cue? {
        list?.cues.first { $0.uuid.uuidString.lowercased() == uuid }
    }

    /// What a chunk's text view holds when the caret enters it: its body, or
    /// the held line, grayed, that typing turns into a write.
    nonisolated static func editable(_ chunk: TextChunk) -> String {
        switch chunk.kind {
        case .write(let body): return body
        case .heldText(let body, _, _, _): return body
        default: return ""
        }
    }

    /// What a chunk shows: the caret's as typed, the others as the store has them.
    public func text(of cue: String) -> String {
        if cue == caret { return caretText }
        if let removed, removed.cue == cue { return removed.text }
        return document.chunk(cue).map(Self.editable) ?? ""
    }

    /// Whether the caret's chunk holds text typed in this visit, which is the chunk's own and not grayed.
    public func isTyped(_ cue: String) -> Bool {
        cue == caret && dirty
    }

    // MARK: - The caret (Spec 11 §5, "Typing")

    /// The caret entered a chunk.
    public func enter(_ uuid: String) {
        guard uuid != caret else { return }
        leave()
        if uuid == Self.emptyChunk {
            guard isEmptyList else { return }
            caret = uuid
            caretText = ""
            dirty = false
            known = nil
            cadence.start("", holdsBack: false)
            return
        }
        guard let chunk = document.chunk(uuid), chunk.isEditable else { return }
        caret = uuid
        caretText = Self.editable(chunk)
        dirty = false
        changedElsewhere = false
        known = cue(uuid).map { CueSays.about(channel, in: $0) }
        lastCue = cue(uuid)
        lastIndex = document.index(of: uuid) ?? 0
        cadence.start(caretText, holdsBack: chunk.holdsBack)
        editing.selectFromText(cue: uuid)
    }

    /// The caret's chunk changed as typed: its whole text, and whether the input method is still composing it.
    public func typed(_ text: String, composing: Bool) {
        guard let caret, removed?.cue != caret else {
            if var ghost = removed, ghost.cue == caret {
                ghost.text = text
                removed = ghost
                caretText = text
            }
            return
        }
        guard text != caretText || composing else { return }
        caretText = text
        dirty = true
        if caret == Self.emptyChunk {
            guard !composing else { return }
            firstCharacter(text)
            return
        }
        cadence.changed(text, composing: composing)
    }

    /// The caret leaves its chunk: "once when the chunk loses the caret"; "A
    /// chunk left empty is a clear (R5)".
    public func leave() {
        guard let caret else { return }
        defer {
            self.caret = nil
            dirty = false
            known = nil
        }
        guard caret != Self.emptyChunk, removed?.cue != caret, dirty else { return }
        if caretText.isEmpty {
            cadence.start("", holdsBack: false)
            guard let cue = cue(caret), let number = list?.number else { return }
            send(TextEdits.emptied(cue: cue, list: number, channel: channel))
        } else {
            cadence.left()
        }
    }

    /// What is typed and not sent yet in the caret's chunk.
    public var unsent: String? { cadence.unsent }

    /// One send of the caret's chunk, as the cadence paces it.
    private func sendTyping(_ text: String) -> Bool {
        guard let caret, let cue = cue(caret), let chunk = document.chunk(caret), let number = list?.number,
              let sending = TextEdits.typing(text, chunk: chunk, cue: cue, list: number, channel: channel) else { return false }
        return send(sending)
    }

    /// The first character in an empty list: one insert of a cue with its write, and the caret goes on in it.
    private func firstCharacter(_ text: String) {
        guard let list = editing.list, !text.isEmpty else { return }
        let uuid = editing.makeUuid()
        guard let sending = TextEdits.firstCue(uuid: uuid, body: text, list: list.number, channel: channel),
              case .edit(let edit)? = sending.commands.first, case .insert(_, _, let value) = edit.action,
              let cue = try? JSONCoding.decode(Cue.self, from: value) else { return }
        inserted.append((cue, 0))
        guard send(sending, inserting: uuid.uuidString.lowercased()) else {
            inserted.removeAll { $0.cue.uuid == uuid }
            return
        }
        refresh()
        let name = uuid.uuidString.lowercased()
        caret = name
        dirty = true
        known = CueSays.about(channel, in: cue)
        lastCue = cue
        lastIndex = 0
        // What was typed has gone with the insert; what follows is typing on the new cue.
        cadence.start(text, holdsBack: false)
        editing.selectFromText(cue: name)
    }

    /// Sends one of the editor's edits, keeping the group its result names.
    /// `inserting` names a cue the edit inserts, which leaves the overlay if the engine refuses it.
    @discardableResult
    private func send(_ sending: Sending?, inserting: String? = nil) -> Bool {
        guard let sending else { return false }
        var applied = false
        let cannot = editing.send(sending, then: { [weak self] outcome in
            applied = true
            guard let self, let group = outcome.group else { return }
            self.ownGroups.insert(group)
        }, answered: { [weak self] in
            guard let self, !applied, let inserting else { return }
            // Refused: the cue it would have made goes, and the page shows the list as the engine has it. A caret in
            // that cue goes back to where its text came from, the text kept: "a rejection puts the control back".
            self.inserted.removeAll { $0.cue.uuid.uuidString.lowercased() == inserting }
            if self.caret == inserting { self.caretReturns() }
            self.refresh()
            self.editing.model.changed([.edit])
        })
        guard cannot == nil else { return false }
        changedElsewhere = false
        // What the cue says now, so an answer from elsewhere can be told from this one's.
        for command in sending.commands {
            if case .edit(let edit) = command, case .cue(_, let uuid) = edit.address, uuid.uuidString.lowercased() == caret,
               case .cueChannel(let change) = edit.action, change.channel == channel {
                known = CueSays(state: change.state, attributes: change.attributes)
            }
        }
        return true
    }

    /// A refused insert took the caret's chunk away: an empty list's caret
    /// goes back to its one chunk, with what was typed.
    private func caretReturns() {
        if editing.list?.cues.isEmpty ?? false {
            caret = Self.emptyChunk
            dirty = false
            known = nil
            cadence.start(caretText, holdsBack: false)
        } else {
            caret = nil
        }
    }

    // MARK: - Other clients (Spec 11 §5)

    /// Spec 11 §5, "Other clients" — a `library` event. The editor's own
    /// echoes change nothing; an undo or a redo replaces the caret's chunk; any
    /// other change that names the caret's cue makes it say "Changed elsewhere"
    /// once the list has come.
    func event(_ event: LibraryChangeEvent) {
        if let group = event.group, ownGroups.contains(group), event.cause != "undo", event.cause != "redo" { return }
        guard let caret, caret != Self.emptyChunk, let listUuid = editing.listUuid else { return }
        let names = event.changed.contains { change in
            switch change.object {
            case "cue": return change.address.text("cue") == caret
            case "list": return change.address.text("listUuid") == listUuid || change.address.integer("list") == list?.number
            default: return false
            }
        }
        guard names else { return }
        if event.cause == "undo" || event.cause == "redo" {
            replacing = true
        } else {
            elsewhere = true
        }
    }

    /// "Add as New Cue": the text in a new cue where the removed one stood,
    /// with its label and section and the other fields of its write, and every
    /// other channel held.
    public func addRemovedAsNewCue() {
        guard let ghost = removed, let list = editing.list else { return }
        var fields: [String: String] = [:]
        if case .write(.text(let had), _) = CueSays.about(channel, in: ghost.was).state { fields = had }
        fields["body"] = ghost.text
        let uuid = editing.makeUuid()
        let write = ghost.text.isEmpty ? nil : ChannelWrite(channel: .number(channel), content: .text(fields: fields))
        let cue = TextEdits.newCue(uuid: uuid, label: ghost.was.label, section: ghost.was.section, write: write)
        let at = min(ghost.index, list.cues.count)
        removed = nil
        caret = nil
        inserted.append((cue, at))
        if !send(Sending([TextEdits.insert(cue, at: at, list: list.number)]), inserting: uuid.uuidString.lowercased()) {
            inserted.removeAll { $0.cue.uuid == uuid }
            removed = ghost
        }
        refresh()
        editing.model.changed([.edit])
    }

    /// "Copy": the removed chunk's text, for the pasteboard; the chunk goes.
    public func copyRemoved() -> String? {
        guard let ghost = removed else { return nil }
        removed = nil
        if caret == ghost.cue { caret = nil }
        refresh()
        editing.model.changed([.edit])
        return ghost.text
    }

    // MARK: - Selection (Spec 11 §5)

    /// Says something in the page's header for three seconds, and to VoiceOver.
    public func say(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = editing.model.later(3) { [weak self] in
            self?.notice = nil
            self?.editing.model.changed([.edit])
        }
        onSay?(text)
        editing.model.changed([.edit])
    }

    /// Spec 11 §5, "Selection" — "Typing, Delete, Cut or Paste over a
    /// selection that crosses a break does nothing and says "Select within one cue.""
    public func refuseAcrossBreaks() {
        say(Strings.text(.textSelectWithinOneCue))
    }

    /// "A second ⌘A selects the whole document, for Copy only": each run's
    /// section on a line of its own, then its chunks' own text, the chunks
    /// apart by a blank line, so the copy pastes back as the same cues (Area 10
    /// reading). Holds, clears and rows of other content copy nothing.
    public func documentText() -> String {
        var paragraphs: [String] = []
        var section: String?
        for chunk in document.chunks {
            if chunk.startsRun { section = chunk.section }
            var own = chunk.text
            if chunk.cue == caret, dirty || chunk.kind == .write(body: chunk.text) { own = caretText }
            guard !own.isEmpty else { continue }
            paragraphs.append(([section].compactMap { $0 } + [own]).joined(separator: "\n"))
            section = nil
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// The section combo's choices: "a combo box with the list's sections and E3's names".
    public var sectionChoices: [String] {
        editing.list.map(CueInspector.sections) ?? CueInspector.sectionNames
    }

    // MARK: - The fields column (Spec 11 §5, G-46)

    /// "the list's metadata (title, author, copyright, CCLI number, track
    /// through), each an `edit.set` on the list on commit".
    public func set(_ field: TextListField, _ value: JSONValue) {
        guard let list = editing.list else { return }
        let current: JSONValue
        switch field {
        case .title: current = .string(list.title)
        case .author: current = .string(list.author)
        case .copyright: current = .string(list.copyright)
        case .ccli: current = .string(list.ccli)
        case .trackThrough: current = .bool(list.trackThrough)
        }
        guard value != current else { return }
        send(Sending([.edit(EditCommand(.list(list.number), .set(path: field.rawValue, value: value)))]))
    }

    /// The cue whose label and section the column shows: the caret's, else the one last edited.
    public var columnCue: Cue? {
        if let caret, let cue = cue(caret) { return cue }
        return editing.selectedCues.first
    }

    /// "for the chunk with the caret, its cue's label".
    public func setLabel(_ label: String) {
        guard let cue = columnCue, let list = editing.list else { return }
        send(CueEdits.label(label, cue: cue, list: list.number))
    }

    /// "and section (a combo box with the list's sections and E3's names)",
    /// carried forward as the Cues page carries it (Spec 11 §4).
    public func setSection(_ section: String) {
        guard let cue = columnCue, let list = editing.list else { return }
        send(CueEdits.sectionRun(section, from: cue, in: list))
    }

    /// "and Hold, which returns the channel to hold on that cue, keeping `track` riders as §4 says".
    public func hold() {
        guard let cue = columnCue, let list = editing.list else { return }
        let uuid = cue.uuid.uuidString.lowercased()
        if caret == uuid {
            dirty = false
            cadence.start(caretText, holdsBack: false)
        }
        guard send(TextEdits.hold(cue: cue, list: list.number, channel: channel)) else { return }
        if caret == uuid { replacing = true }
    }
}
