// OApp — Spec 10 §5, §6, §10 and §14, the edits in words: menu titles, reasons, rejections, Undo and Redo, confirmations.

import Foundation
import OCore

/// A confirmation's words: the question, what stands under it, and the
/// button that does it. "A button that deletes, restores or quits is never
/// a sheet's default, so Return can't press it" (Spec 10 §9): Cancel is the
/// other button, and Escape presses it.
public struct ConfirmationWords: Equatable, Sendable {
    public var title: String
    public var body: [String]
    public var button: String
}

/// Spec 10 §5, §6, §10 and §14 — the edits' models in the spec's words, every one from the string catalog.
@MainActor
public enum EditWording {
    // MARK: Menus

    /// A menu entry's title.
    public static func title(_ entry: MenuEntry) -> String {
        switch entry.kind {
        case .separator: return ""
        case .makeLive: return Strings.text(.menuMakeLive)
        case .renamePlaylist, .renameHeader, .renameList, .renameFolder: return Strings.text(.menuRename)
        case .dateAndTime: return Strings.text(.menuDateAndTime)
        case .duplicatePlaylist: return Strings.text(.menuDuplicateAs)
        case .archiveCopy: return Strings.text(.menuArchiveCopy)
        case .archive: return Strings.text(.menuArchive)
        case .restoreFromArchive: return Strings.text(.menuRestoreFromArchive)
        case .deletePlaylist, .deleteList, .deleteMedia: return Strings.text(.menuDelete)
        case .removeItem: return Strings.text(.menuRemoveFromPlaylist)
        case .addHeaderAbove: return Strings.text(.menuAddHeaderAbove)
        case .showInLibrary: return Strings.text(.menuShowInLibrary)
        case .addToPlaylistMenu: return Strings.text(.menuAddToPlaylist)
        case .addToPlaylist: return entry.name
        case .duplicateList: return Strings.text(.menuDuplicate)
        case .openInTextEditor: return Strings.text(.menuOpenInTextEditor)
        case .restoreVersion: return Strings.text(.menuRestoreVersion)
        case .newListHere: return Strings.text(.menuNewListHere)
        case .newFolder: return Strings.text(.menuNewFolder)
        case .deleteFolder: return Strings.text(.menuDeleteFolder)
        case .fire: return Strings.text(.menuFire)
        case .editText: return Strings.text(.menuEditText)
        case .editCue: return Strings.text(.menuEditCue)
        case .note: return Strings.text(.menuNote)
        case .triggerMenu: return Strings.text(.menuTrigger)
        case .triggerGo: return Strings.text(.menuTriggerGo)
        case .triggerTime: return Strings.text(.menuTriggerTime)
        case .advanceAfter: return Strings.text(.menuTriggerAdvance)
        case .duplicateSection: return Strings.text(.menuDuplicateSection)
        case .hold: return Strings.text(.nextHold)
        case .gradeMenu(let channel): return Strings.text(.menuGradeFor, channel, entry.name)
        case .grade(_, let grade): return grade == nil ? Strings.text(.stripGradeNone) : entry.name
        case .fireTo(let channel): return Strings.text(.menuFireTo, channel, entry.name)
        case .fireToMenu: return Strings.text(.menuFireToAsk)
        case .defaults: return Strings.text(.menuDefaults)
        case .replace: return Strings.text(.menuReplace)
        case .reveal: return Strings.text(.menuReveal)
        }
    }

    /// "An action the app can't take now ... shows disabled with the reason" (Spec 10 §1).
    public static func reason(_ reason: CannotEdit) -> String {
        switch reason {
        case .unavailable(let unavailable): return UnavailableWording.sentence(for: unavailable)
        case .archived: return Strings.text(.cannotArchived)
        case .localCopy: return Strings.text(.cannotLocalCopy)
        case .renumberToEdit: return Strings.text(.cannotRenumberToEdit)
        case .liveNow: return Strings.text(.cannotLiveNow)
        case .alreadyLive: return Strings.text(.cannotAlreadyLive)
        case .folderNotEmpty: return Strings.text(.cannotFolderNotEmpty)
        case .missing: return Strings.text(.cannotMissing)
        case .removed: return Strings.text(.cannotRemoved)
        case .fire(let refusal): return ShowWording.refusal(refusal)
        case .dropOnThePool: return Strings.text(.cannotDropOnThePool)
        case .later: return Strings.text(.unavailableLater)
        }
    }

    // MARK: Rejections (Spec 10 §10)

    private static let rejections: [String: StringKey] = [
        "unknownObject": .rejectedUnknownObject, "unknownPath": .rejectedUnknownPath, "readOnlyField": .rejectedReadOnlyField,
        "badValue": .rejectedBadValue, "unknownReference": .rejectedUnknownReference, "duplicate": .rejectedDuplicate,
        "danglingReferences": .rejectedDanglingReferences, "protected": .rejectedProtected, "onAir": .rejectedOnAir, "archived": .rejectedArchived,
        "notEmpty": .rejectedNotEmpty, "cycle": .rejectedCycle, "operatorLock": .rejectedOperatorLock, "readOnlyLibrary": .rejectedReadOnlyLibrary,
        "conflict": .rejectedConflict, "notInV1": .rejectedNotInV1, "noTrash": .rejectedNoTrash, "diskFull": .rejectedDiskFull,
        "noPasscode": .rejectedNoPasscode, "keychain": .rejectedKeychain, "unreadable": .rejectedUnreadable, "unsupported": .rejectedUnsupported,
        "changed": .rejectedChanged, "notListed": .rejectedNotListed,
    ]

    /// The codes the app has a sentence for: every one of Spec 5 §6 and Spec 8 §7.
    public static var rejectionCodes: [String] { rejections.keys.sorted() }

    /// "Rejections come back as a short message in plain words beside what
    /// was tried, from the code ... one sentence for each code of Spec 5 §6
    /// and Spec 8 §7." A code the app doesn't know is shown as the engine sent it.
    public static func rejection(code: String) -> String {
        rejections[code].map { Strings.text($0) } ?? Strings.text(.rejectedOther, code)
    }

    public static func rejection(_ rejection: EngineRejection) -> String {
        self.rejection(code: rejection.code)
    }

    /// A short message, as it stands beside what was tried.
    public static func notice(_ notice: Notice) -> String {
        switch notice {
        case .rejected(let rejection): return self.rejection(rejection)
        case .done(let undo, let kind, let object): return done(undo: undo, kind: kind, object: object)
        case .notSent(let reason): return Strings.text(.noticeNotSent, self.reason(reason))
        }
    }

    // MARK: Undo and redo (Spec 10 §10)

    private static func name(_ kind: HistoryKind) -> String {
        switch kind {
        case .rename: return Strings.text(.historyKindRename)
        case .typing: return Strings.text(.historyKindTyping)
        case .add: return Strings.text(.historyKindAdd)
        case .remove: return Strings.text(.historyKindRemove)
        case .move: return Strings.text(.historyKindMove)
        case .duplicate: return Strings.text(.historyKindDuplicate)
        case .deleteMedia: return Strings.text(.historyKindDeleteMedia)
        case .restore: return Strings.text(.historyKindRestore)
        case .change: return Strings.text(.historyKindChange)
        }
    }

    /// The app's own sources: a step from any other is said to be.
    private static let ownSources: Set<String> = ["ui", "key", "commandbar"]

    /// "Undo Rename ... with "(N changes)" for a group of several, and the
    /// source when it wasn't this app: "Undo Rename (from OSC)"." With no
    /// step, plain Undo or Redo.
    public static func menuTitle(undo: Bool, step: HistoryStatus.Step?) -> String {
        guard let step else { return Strings.text(undo ? .menuUndo : .menuRedo) }
        let kind = name(HistoryKind.of(text: step.text))
        let source = ownSources.contains(step.source) || step.source.isEmpty ? nil : ShowWording.origin(.source(step.source))
        let changes = step.commands > 1 ? Strings.counted(.historyChanges, step.commands) : nil
        switch (changes, source) {
        case (nil, nil): return Strings.text(undo ? .historyUndo : .historyRedo, kind)
        case (let detail?, nil), (nil, let detail?): return Strings.text(undo ? .historyUndoDetail : .historyRedoDetail, kind, detail)
        case (let changes?, let source?): return Strings.text(undo ? .historyUndoDetails : .historyRedoDetails, kind, changes, source)
        }
    }

    private static func object(_ object: EditedObject) -> String {
        switch object {
        case .playlist(let title): return Strings.text(.historyObjectPlaylist, title)
        case .item(let playlist): return Strings.text(.historyObjectItem, playlist)
        case .list(let title): return Strings.text(.historyObjectList, title)
        case .cue(let list): return Strings.text(.historyObjectCue, list)
        case .folder(let path): return Strings.text(.historyObjectFolder, path)
        case .media(let name): return Strings.text(.historyObjectMedia, name)
        case .library: return Strings.text(.historyObjectLibrary)
        }
    }

    /// "After an undo or a redo, the window says for three seconds what
    /// changed: "Undid the rename of the playlist Sunday"."
    public static func done(undo: Bool, kind: HistoryKind, object: EditedObject) -> String {
        let undid: [HistoryKind: StringKey] = [.rename: .historyUndidRename, .typing: .historyUndidTyping, .add: .historyUndidAdd, .remove: .historyUndidRemove,
                                              .move: .historyUndidMove, .duplicate: .historyUndidDuplicate, .deleteMedia: .historyUndidDeleteMedia,
                                              .restore: .historyUndidRestore, .change: .historyUndidChange]
        let redid: [HistoryKind: StringKey] = [.rename: .historyRedidRename, .typing: .historyRedidTyping, .add: .historyRedidAdd, .remove: .historyRedidRemove,
                                              .move: .historyRedidMove, .duplicate: .historyRedidDuplicate, .deleteMedia: .historyRedidDeleteMedia,
                                              .restore: .historyRedidRestore, .change: .historyRedidChange]
        let key = (undo ? undid : redid)[kind] ?? (undo ? .historyUndidChange : .historyRedidChange)
        return Strings.text(key, self.object(object))
    }

    // MARK: Confirmations (Spec 10 §5, §10, §14)

    /// Spec 10 §15 — "lists the system's list formatter ("12 cues, 1 macro
    /// and 2 keys")": joined as the Mac's region joins a list, so a Mac set
    /// to the United States writes the comma before "and".
    public static func joined(_ parts: [String], locale: Locale = .current) -> String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: parts) ?? parts.joined(separator: ", ")
    }

    /// "12 cues, 1 macro and 2 keys": the counts that aren't zero.
    public static func uses(_ use: MediaUseCount, locale: Locale = .current) -> String {
        var parts: [String] = []
        if use.cues > 0 { parts.append(Strings.counted(.useCues, use.cues)) }
        if use.macros > 0 { parts.append(Strings.counted(.useMacros, use.macros)) }
        if use.presets > 0 { parts.append(Strings.counted(.usePresets, use.presets)) }
        if use.keys > 0 { parts.append(Strings.counted(.useKeys, use.keys)) }
        return joined(parts, locale: locale)
    }

    public static func words(_ confirmation: Confirmation, locale: Locale = .current) -> ConfirmationWords {
        switch confirmation {
        case .deletePlaylist(let title, let isLive):
            return ConfirmationWords(title: Strings.text(.confirmDeletePlaylistTitle, title),
                                     body: [Strings.text(isLive ? .confirmDeletePlaylistLive : .confirmDeletePlaylistBody)], button: Strings.text(.confirmDelete))
        case .removeLiveItem(let title):
            return ConfirmationWords(title: Strings.text(.confirmRemoveLiveItemTitle, title), body: [Strings.text(.confirmRemoveLiveItemBody)],
                                     button: Strings.text(.confirmRemove))
        case .deleteList(let title, let playlists):
            let body = playlists.isEmpty ? Strings.text(.confirmDeleteListUnlinked)
                : Strings.counted(.confirmDeleteListLinked, playlists.count, joined(playlists, locale: locale))
            return ConfirmationWords(title: Strings.text(.confirmDeleteListTitle, title), body: [body], button: Strings.text(.confirmDelete))
        case .deleteMedia(let name, let use):
            let body = use.total > 0 ? Strings.text(.confirmDeleteMediaUsed, uses(use, locale: locale)) : Strings.text(.confirmDeleteMediaUnused)
            return ConfirmationWords(title: Strings.text(.confirmDeleteMediaTitle, name), body: [body], button: Strings.text(.confirmDelete))
        case .restoreVersion(let version, let title, let keptAt, let cues, let onAir):
            var body = [Strings.text(.confirmRestoreVersionBody)]
            if onAir { body.append(Strings.text(.confirmRestoreVersionOnAir)) }
            return ConfirmationWords(title: Strings.text(.confirmRestoreVersionTitle, version, title, keptAt, Strings.counted(.gridCues, cues)),
                                     body: body, button: Strings.text(.confirmRestore))
        case .restoreSnapshot(let takenAt, let mastersReadOnly):
            return ConfirmationWords(title: Strings.text(mastersReadOnly ? .confirmRestoreSnapshotTitleMachine : .confirmRestoreSnapshotTitle, takenAt),
                                     body: [Strings.text(.confirmRestoreSnapshotBody)], button: Strings.text(.confirmRestore))
        }
    }

    /// When something was kept or taken, from the engine's ISO date: "Nov 1 at 09:12". A date that doesn't read shows as it came.
    public static func when(_ iso: String, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let parser = ISO8601DateFormatter()
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: iso)
        }
        guard let date else { return iso }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: date)
    }
}
