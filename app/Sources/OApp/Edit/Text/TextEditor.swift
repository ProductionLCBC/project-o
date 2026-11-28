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
    /// Called when a break moves the caret to another chunk, with the chunk and the caret's place in its text.
    public var onCaret: ((String, Int) -> Void)?
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

    /// One of the editor's edits that inserts, removes or rewrites cues, shown
    /// on the list until the list comes back from the engine with it, or the
    /// engine refuses it (`LocalEdits`).
    private struct Pending {
        var id: Int
        var commands: [Command]
        /// The list as the store held it when the engine applied the edit; the edit stops showing once the store
        /// holds another.
        var answered: List?
        /// Where the caret was before the edit, which a refusal puts it back to.
        var caretBefore: String?
    }
    private var pending: [Pending] = []
    private var pendingCount = 0

    /// What the caret's cue said about the channel when the editor last sent or entered it.
    private var known: CueSays?
    /// A `library` event from elsewhere named the caret's cue, or an undo or redo did; acted on when the list arrives.
    private var elsewhere = false
    private var replacing = false
    private var lastList: List?
    private var lastCue: Cue?
    private var lastIndex = 0

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

    /// The list the page edits, as the editor's own edits will leave it: the
    /// store's list with what the editor sent and the store doesn't show yet.
    public var list: List? {
        guard var list = editing.list else { return nil }
        for entry in pending {
            for command in entry.commands { LocalEdits.apply(command, to: &list) }
        }
        return list
    }

    /// Why the list can't be edited, or nil: Spec 11 §5 — "A local copy, or a
    /// list on a `readOnlyMasters` machine, opens read-only (§1)".
    public var cannotEdit: CannotEdit? { editing.cannotEdit }

    /// "An empty list shows one empty chunk".
    public var isEmptyList: Bool { list != nil && document.chunks.isEmpty && removed == nil }

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
        // An edit of the editor's own stops showing once the store holds it, or holds a list newer than its answer.
        pending.removeAll { entry in
            entry.commands.allSatisfy { LocalEdits.isSatisfied($0, in: source) } || (entry.answered.map { $0 != source } ?? false)
        }
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
            if replacing {
                // An undo or a redo took the caret's cue away: the caret goes, with nothing kept, since the
                // library's text is what it was.
                replacing = false
                self.caret = nil
                dirty = false
                return
            }
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

    /// A cue of the list by its uuid, as the store holds it with the editor's own edits on it.
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

    /// A chunk's own text: the caret's as typed, and nothing for a hold, a
    /// clear or held text not typed into ("a clear or a hold counting as empty
    /// text"). What a break moves.
    public func ownText(_ cue: String) -> String {
        guard let chunk = document.chunk(cue) else { return "" }
        return cue == caret && dirty ? caretText : chunk.text
    }

    /// Whether the caret's chunk holds text typed in this visit, which is the chunk's own and not grayed.
    public func isTyped(_ cue: String) -> Bool {
        cue == caret && dirty
    }

    // MARK: - The caret (Spec 11 §5, "Typing")

    /// Spec 11 §5, "The sheet view" (G-50) — whether the page shows the
    /// document as one field of text; `view.json` keeps it, off at first.
    public var isSheet: Bool { editing.model.settings.textSheet }

    /// The page's Sheet toggle. The caret leaves its chunk first, as it would for any other view.
    public func setSheet(_ on: Bool) {
        guard on != isSheet else { return }
        leave()
        editing.model.settings.textSheet = on
        editing.model.changed([.edit])
    }

    /// The caret entered a chunk. In the sheet view (`sheet`) held text shows
    /// as a blank line, so the chunk's text starts empty there (G-50).
    public func enter(_ uuid: String, sheet: Bool = false) {
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
        if let ghost = removed, ghost.cue == uuid {
            caret = uuid
            caretText = ghost.text
            return
        }
        guard let chunk = document.chunk(uuid), chunk.isEditable else { return }
        caret = uuid
        caretText = sheet ? chunk.text : Self.editable(chunk)
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

    /// Puts the caret in a chunk with `text` as its own, already sent, and tells the page where it goes.
    private func moveCaret(to uuid: String, text: String, at location: Int) {
        // The caret moves first: the chunk it leaves may be one this editor's own edit removed, which is no cue
        // removed elsewhere.
        caret = uuid
        refresh()
        caretText = text
        dirty = false
        changedElsewhere = false
        known = cue(uuid).map { CueSays.about(channel, in: $0) }
        lastCue = cue(uuid)
        lastIndex = document.index(of: uuid) ?? lastIndex
        cadence.start(text, holdsBack: document.chunk(uuid)?.holdsBack ?? false)
        editing.selectFromText(cue: uuid)
        editing.model.changed([.edit])
        onCaret?(uuid, location)
    }

    /// The first character in an empty list: one insert of a cue with its write, and the caret goes on in it.
    private func firstCharacter(_ text: String) {
        guard let list = editing.list, !text.isEmpty else { return }
        let uuid = editing.makeUuid()
        guard let sending = TextEdits.firstCue(uuid: uuid, body: text, list: list.number, channel: channel),
              send(sending, shown: true, caretBefore: Self.emptyChunk) else { return }
        // What was typed has gone with the insert; what follows is typing on the new cue.
        moveCaret(to: uuid.uuidString.lowercased(), text: text, at: (text as NSString).length)
    }

    /// Sends one of the editor's edits, keeping the group its result names.
    /// `shown`: an edit that inserts, removes or rewrites cues, shown on the
    /// list until the engine's list holds it; refused, it goes, and the caret
    /// goes back to `caretBefore`.
    @discardableResult
    private func send(_ sending: Sending?, shown: Bool = false, caretBefore: String? = nil) -> Bool {
        guard let sending else { return false }
        pendingCount += 1
        let id = pendingCount
        if shown { pending.append(Pending(id: id, commands: sending.commands, answered: nil, caretBefore: caretBefore)) }
        var applied = false
        let cannot = editing.send(sending, then: { [weak self] outcome in
            applied = true
            guard let self else { return }
            if let group = outcome.group { self.ownGroups.insert(group) }
            if let index = self.pending.firstIndex(where: { $0.id == id }) { self.pending[index].answered = self.editing.list }
        }, answered: { [weak self] in
            guard let self, !applied, let index = self.pending.firstIndex(where: { $0.id == id }) else { return }
            // Refused: the edit stops showing, and the page shows the list as the engine has it; the caret goes back
            // to where it was, its text as the library has it: "a rejection puts the control back".
            let entry = self.pending.remove(at: index)
            // A caret in a cue the refused edit made has no cue to stay in, and nothing removed it elsewhere.
            let made = entry.commands.compactMap { command -> String? in
                guard case .edit(let edit) = command, case .insert("cues", _, let value) = edit.action,
                      let cue = try? JSONCoding.decode(Cue.self, from: value) else { return nil }
                return cue.uuid.uuidString.lowercased()
            }
            if let caret = self.caret, made.contains(caret) { self.caret = nil }
            self.refresh()
            self.caretReturns(to: entry.caretBefore)
            self.editing.model.changed([.edit])
        })
        guard cannot == nil else {
            pending.removeAll { $0.id == id }
            return false
        }
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

    /// A refused edit took the caret's chunk away, or changed it: the caret
    /// goes back to the chunk it was in, or an empty list's one chunk.
    private func caretReturns(to before: String?) {
        guard let before else { return }
        if before == Self.emptyChunk {
            guard isEmptyList else { return }
            caret = Self.emptyChunk
            dirty = false
            known = nil
            cadence.start(caretText, holdsBack: false)
            onCaret?(Self.emptyChunk, (caretText as NSString).length)
            return
        }
        guard let chunk = document.chunk(before), chunk.isEditable else {
            caret = nil
            return
        }
        let text = Self.editable(chunk)
        moveCaret(to: before, text: text, at: (text as NSString).length)
    }

    // MARK: - Breaks (Spec 11 §5, E2)

    /// One chunk as a break sees it, by its cue's uuid.
    private func side(_ uuid: String) -> TextSide? {
        guard let chunk = document.chunk(uuid), chunk.isEditable, let cue = cue(uuid) else { return nil }
        return TextSide(chunk: chunk, cue: cue, text: ownText(uuid), typed: isTyped(uuid))
    }

    /// Spec 11 §5, "Split" — "⌥Return, or Edit ▸ Split Cue, at the caret":
    /// one group, and the caret goes on at the start of the new cue's chunk.
    /// `location` is the caret's place in its chunk's text.
    public func split(at location: Int) {
        guard let caret, caret != Self.emptyChunk, removed?.cue != caret, let side = side(caret), let list,
              let index = list.cues.firstIndex(where: { $0.uuid == side.cue.uuid }) else { return }
        let uuid = editing.makeUuid()
        let split = TextBreaks.split(side, at: location, index: index, uuid: uuid, list: list.number, channel: channel)
        guard send(split.sending, shown: true, caretBefore: caret) else { return }
        // Spec 11 §10 — "a split, a merge or a moved break says what it did ("New cue 5 after cue 4")".
        announce(Strings.text(.textSaidSplit, index + 2, index + 1))
        moveCaret(to: uuid.uuidString.lowercased(), text: split.below, at: 0)
    }

    /// Spec 11 §5, "Merge" — "Backspace at the start of a chunk joins it to the chunk above". Nothing reaches into a
    /// row of other content: "Backspace at the start of a chunk under such a row does nothing."
    public func mergeUp() {
        guard let caret, let index = document.index(of: caret), index > 0 else { return }
        merge(upper: document.chunks[index - 1].cue, lower: caret)
    }

    /// "and forward Delete at the end of a chunk joins the one below to it".
    public func mergeDown() {
        guard let caret, let index = document.index(of: caret), index + 1 < document.chunks.count else { return }
        merge(upper: caret, lower: document.chunks[index + 1].cue)
    }

    /// "The editor asks first when the second cue has anything beyond its text
    /// on this channel ... or is the live or the armed cue ... Merge is never
    /// the sheet's default."
    private func merge(upper: String, lower: String) {
        guard side(upper) != nil, let lowerSide = side(lower), let into = document.chunk(upper)?.number else { return }
        if let question = MergeQuestion.of(lowerSide.chunk, cue: lowerSide.cue, into: into, channel: channel) {
            editing.model.ask(.mergeCues(question)) { [weak self] in self?.performMerge(upper: upper, lower: lower) }
        } else {
            performMerge(upper: upper, lower: lower)
        }
    }

    private func performMerge(upper: String, lower: String) {
        guard let upperSide = side(upper), let lowerSide = side(lower), let list else { return }
        let merge = TextBreaks.merge(upper: upperSide, lower: lowerSide, list: list.number, channel: channel)
        guard send(merge.sending, shown: true, caretBefore: caret) else { return }
        announce(Strings.text(.textSaidMerge, lowerSide.chunk.number, upperSide.chunk.number))
        moveCaret(to: upper, text: merge.joined, at: merge.joinAt)
    }

    /// Spec 11 §5, "Moving a break" (G-48) — Move Line to Previous Cue moves
    /// the caret's first line to the end of the chunk above, and Move Line to
    /// Next Cue its last line to the start of the chunk below. The line's
    /// place in its chunk is read from the caret's `location`; nil when the
    /// caret isn't on that line or the move would take the chunk's last line.
    private func lineMove(previous: Bool, at location: Int) -> (upper: String, lower: String, lines: Int, line: Int, column: Int)? {
        guard let caret, caret != Self.emptyChunk, let index = document.index(of: caret) else { return nil }
        let text = ownText(caret) as NSString
        let at = max(0, min(location, text.length))
        let before = text.substring(to: at)
        let line = before.filter { $0 == "\n" }.count
        let count = TextBreaks.lines(ownText(caret)).count
        guard count >= 2 else { return nil }
        let column = (before as NSString).length - ((before.range(of: "\n", options: .backwards)?.upperBound).map { (String(before[..<$0]) as NSString).length } ?? 0)
        if previous {
            guard line == 0, index > 0 else { return nil }
            return (document.chunks[index - 1].cue, caret, 1, line, column)
        }
        guard line == count - 1, index + 1 < document.chunks.count else { return nil }
        return (caret, document.chunks[index + 1].cue, -1, line, column)
    }

    /// Whether Move Line to Previous Cue or Next Cue can move a line now.
    public func canMoveLine(previous: Bool, at location: Int) -> Bool {
        guard let move = lineMove(previous: previous, at: location), let upper = side(move.upper), let lower = side(move.lower) else { return false }
        return TextBreaks.move(move.lines, upper: upper, lower: lower, list: 0, channel: channel) != nil
    }

    /// Edit ▸ Move Line to Previous Cue (⌥⌘↑) and Move Line to Next Cue
    /// (⌥⌘↓): the break moves by one line, and the caret follows its line.
    public func moveLine(previous: Bool, at location: Int) {
        guard let move = lineMove(previous: previous, at: location) else { return }
        guard let result = moveBreak(upper: move.upper, lower: move.lower, by: move.lines) else { return }
        if previous {
            // The line is now the upper chunk's last.
            let lines = TextBreaks.lines(result.upper)
            let start = (lines.dropLast().joined(separator: "\n") as NSString).length + (lines.count > 1 ? 1 : 0)
            moveCaret(to: move.upper, text: result.upper, at: start + move.column)
        } else {
            moveCaret(to: move.lower, text: result.lower, at: move.column)
        }
    }

    /// Spec 11 §5, "Moving a break" — the break above `cue`'s chunk dragged by
    /// `lines`: down (positive) gives the upper chunk the chunk's first lines;
    /// up (negative) gives the chunk the upper chunk's last lines. "A break
    /// never passes a chunk's last line." The caret stays in its chunk.
    public func moveBreak(above cue: String, by lines: Int) {
        guard let index = document.index(of: cue), index > 0 else { return }
        let upper = document.chunks[index - 1].cue
        guard let result = moveBreak(upper: upper, lower: cue, by: lines) else { return }
        if caret == upper || caret == cue, let caret {
            let text = caret == upper ? result.upper : result.lower
            moveCaret(to: caret, text: text, at: (text as NSString).length)
        } else {
            refresh()
            editing.model.changed([.edit])
        }
    }

    @discardableResult
    private func moveBreak(upper: String, lower: String, by lines: Int) -> TextBreaks.Move? {
        guard let upperSide = side(upper), let lowerSide = side(lower), let list,
              let move = TextBreaks.move(lines, upper: upperSide, lower: lowerSide, list: list.number, channel: channel),
              send(move.sending, shown: true, caretBefore: caret) else { return nil }
        let receiver = lines > 0 ? upperSide.chunk.number : lowerSide.chunk.number
        announce(Strings.counted(.textSaidMoved, abs(lines), receiver))
        return move
    }

    /// The most lines a break above `cue`'s chunk can move: up (negative) and down (positive).
    public func breakRange(above cue: String) -> ClosedRange<Int> {
        guard let index = document.index(of: cue), index > 0, side(cue) != nil, side(document.chunks[index - 1].cue) != nil else { return 0...0 }
        let up = TextBreaks.lines(ownText(document.chunks[index - 1].cue)).count
        let down = TextBreaks.lines(ownText(cue)).count
        return -max(0, up - 1)...max(0, down - 1)
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
        if !send(Sending([TextEdits.insert(cue, at: at, list: list.number)]), shown: true) { removed = ghost }
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

    /// Tells VoiceOver what a break did, without a word in the header.
    private func announce(_ text: String) {
        onSay?(text)
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
