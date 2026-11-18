// OApp — Spec 10 §10, the show-mode window's edits: sending one, what comes back, Undo and Redo.

import Foundation
import OCore

/// Where a short message stands: "beside what was tried" (Spec 10 §10).
public enum NoticePlace: Hashable, Sendable, CaseIterable {
    case top, left, grid, pool, strip

    var change: ShowModel.Change {
        switch self {
        case .top: return .top
        case .left: return .left
        case .grid: return .grid
        case .pool: return .pool
        case .strip: return .strip
        }
    }
}

/// A short message in plain words, shown for a few seconds where the operator was working.
public enum Notice: Equatable, Sendable {
    /// "Rejections come back as a short message in plain words beside what was tried, from the code".
    case rejected(EngineRejection)
    /// "After an undo or a redo, the window says for three seconds what changed".
    case done(undo: Bool, kind: HistoryKind, object: EditedObject)
    /// Something that couldn't be sent, with why.
    case notSent(CannotEdit)
    /// File ▸ Take Snapshot was done (Spec 10 §14).
    case snapshotTaken

    /// How long it stands: three seconds for what an undo changed, as the
    /// spec says, and for a snapshot taken; five for a refusal, which is
    /// read rather than glanced at (Area 13 reading).
    public var seconds: TimeInterval {
        switch self {
        case .done, .snapshotTaken: return 3
        default: return 5
        }
    }
}

extension ShowModel {
    // MARK: - Sending an edit (Spec 10 §10)

    /// Sends an edit. A refusal is said beside what was tried; `done` runs
    /// when the engine applied it (or found nothing to change), with its
    /// result, which names what the engine picked (Spec 10 §3, "Results").
    /// Nothing goes, and nothing is kept, while the engine is away.
    @discardableResult
    public func edit(_ sending: Sending, at place: NoticePlace, then done: (@MainActor (CommandOutcome) -> Void)? = nil) -> Bool {
        guard store.cannotSend == nil, let transmit, let request = sending.request else { return false }
        transmit(request) { [weak self] reply in
            guard let self, let outcome = reply?.outcome else { return }
            if outcome.kind == .rejected {
                self.say(.rejected(outcome.rejection ?? EngineRejection(code: "", message: "")), at: place)
            } else {
                done?(outcome)
            }
        }
        return true
    }

    /// A field commits (Spec 10 §10, "Text fields"): "each send one edit
    /// when they commit, never while typing ... A commit that can't be sent,
    /// because the lock came on or the engine went away, leaves the field
    /// open with its text, the reason and Copy." Returns why it couldn't be
    /// sent, or nil when it went or there was nothing to send, so the field
    /// may close.
    public func commit(_ sending: Sending?, master: Bool, at place: NoticePlace, then done: (@MainActor (CommandOutcome) -> Void)? = nil) -> CannotEdit? {
        guard let sending, sending.request != nil else { return nil }
        if let cannot = store.cannotEdit(master: master) { return .unavailable(cannot) }
        return edit(sending, at: place, then: done) ? nil : .unavailable(.engineAway)
    }

    /// Shows a message at a place for its few seconds; a newer one there takes its place.
    public func say(_ notice: Notice, at place: NoticePlace) {
        notices[place] = notice
        noticeTasks[place]?.cancel()
        noticeTasks[place] = later(notice.seconds) { [weak self] in
            guard let self else { return }
            self.notices[place] = nil
            self.noticeTasks[place] = nil
            self.changed([place.change])
        }
        changed([place.change])
    }

    /// Takes a message down before its time, as when the operator starts something else there.
    public func dismissNotice(at place: NoticePlace) {
        guard notices[place] != nil else { return }
        notices[place] = nil
        noticeTasks[place]?.cancel()
        noticeTasks[place] = nil
        changed([place.change])
    }

    // MARK: - Undo and redo (Spec 10 §10)

    /// "Both are disabled under the lock and while the engine is away."
    public var cannotUndo: Unavailable? { store.cannotEdit(master: false) }

    /// The step Edit ▸ Undo would undo, or nil when it is disabled.
    public var undoStep: HistoryStatus.Step? { cannotUndo == nil ? store.history.undo : nil }
    public var redoStep: HistoryStatus.Step? { cannotUndo == nil ? store.history.redo : nil }

    /// "Edit ▸ Undo and Redo send `undo` and `redo` (Spec 5 §8). ... After
    /// an undo or a redo, the window says for three seconds what changed".
    @discardableResult
    public func undo() -> Bool { step(undo: true) }

    @discardableResult
    public func redo() -> Bool { step(undo: false) }

    private func step(undo: Bool) -> Bool {
        guard let step = undo ? undoStep : redoStep else { return false }
        // What the step did is read now: once it is undone, the history's top is another step.
        let kind = HistoryKind.of(text: step.text)
        let object = EditedObject.of(text: step.text, catalog: store.catalog, media: store.media)
        return edit(undo ? Edits.undo() : Edits.redo(), at: .top) { [weak self] outcome in
            guard outcome.kind == .ok else { return }
            self?.say(.done(undo: undo, kind: kind, object: object), at: .top)
        }
    }

    // MARK: - Who may edit what (Spec 10 §10)

    /// Why this Mac's own documents, its playlists, can't be edited now.
    public var cannotEditMachine: Unavailable? { store.cannotEdit(master: false) }
    /// Why the library's masters can't be edited now.
    public var cannotEditMasters: Unavailable? { store.cannotEdit(master: true) }
}
