// OApp — Spec 11 §2, §4 and §10, edit mode's models in words: what the operator reads and what VoiceOver says.

import Foundation
import OCore

/// Spec 11 §10 — "Every string is in the app's catalog (Spec 10 §15)": the
/// one place edit mode's models become text. The views compose nothing
/// themselves.
@MainActor
public enum EditModeWording {
    // MARK: - The frame (Spec 11 §2)

    public static func page(_ page: EditPage) -> String {
        switch page {
        case .cues: return Strings.text(.editPageCues)
        case .text: return Strings.text(.editPageText)
        case .stacks: return Strings.text(.editPageStacks)
        case .channels: return Strings.text(.editPageChannels)
        case .presets: return Strings.text(.editPagePresets)
        case .objects: return Strings.text(.editPageObjects)
        }
    }

    public static func tab(_ tab: BrowserTab) -> String {
        switch tab {
        case .playlists: return Strings.text(.editTabPlaylists)
        case .library: return Strings.text(.editTabLibrary)
        case .media: return Strings.text(.editTabMedia)
        }
    }

    public static func mediaView(_ view: MediaListView) -> String {
        Strings.text(view == .grid ? .editMediaGrid : .editMediaList)
    }

    /// "where the list came from and its title, "Sunday 9:00 › Amazing Grace", or "Library › Amazing Grace"".
    public static func crumb(_ crumb: EditCrumb?) -> String {
        guard let crumb else { return "" }
        return Strings.text(.editCrumb, crumb.source ?? Strings.text(.editCrumbLibrary), crumb.title)
    }

    /// An item of the monitors' stack picker.
    public static func stack(number: Int, label: String) -> String {
        Strings.text(.editStack, number, label)
    }

    /// A numbered object as a picker names it: "by number and label" (Spec 11 §1), "2 Clock", or its number alone.
    public static func numbered(_ number: Int, _ label: String) -> String {
        label.isEmpty ? String(number) : "\(number) \(label)"
    }

    private static func numbers(_ numbers: [Int]) -> String {
        numbers.map(String.init).joined(separator: ", ")
    }

    /// "with a pill naming those outputs, "On air · Out 1, 2"; when none does ... the pill says "Preview only"".
    public static func pill(_ panel: ProgramPanel, locale: Locale = .current) -> String {
        panel.isOnAir ? Strings.text(.editProgramOnAir, numbers(panel.outputs)) : Strings.text(.editProgramPreviewOnly)
    }

    /// VoiceOver: ""Preview: cue 3 on stack 1 Main"".
    public static func previewSpoken(cue: Int?, stack: Int, label: String) -> String {
        guard let cue else { return Strings.text(.editPreviewSpokenEmpty) }
        return Strings.text(.editPreviewSpoken, cue, stack, label)
    }

    /// VoiceOver: ""Program: stack 1 Main, on air on outputs 1 and 2"".
    public static func programSpoken(_ panel: ProgramPanel, label: String, locale: Locale = .current) -> String {
        guard panel.isOnAir else { return Strings.text(.editProgramSpokenPreviewOnly, panel.stack, label) }
        return Strings.text(.editProgramSpokenOnAir, panel.stack, label, EditWording.joined(panel.outputs.map(String.init), locale: locale))
    }

    public static func engineSpoken(_ engine: EditStatus.Engine) -> String {
        switch engine {
        case .fine: return Strings.text(.editEngineFine)
        case .attention: return Strings.text(.editEngineAttention)
        case .away: return Strings.text(.editEngineAway)
        }
    }

    // MARK: - The Cues page's header and grid (Spec 11 §4)

    /// "its cue count and its version": "14 cues · version 17".
    public static func meta(cues: Int, version: Int) -> String {
        Strings.counted(.editCuesMeta, cues, version)
    }

    /// "A local item's list opens read-only with "Local copies are edited
    /// from v1.5" (L2)"; any other reason in show mode's words.
    public static func readOnly(_ reason: CannotEdit) -> String {
        if case .localCopy = reason { return Strings.text(.editCuesLocalCopy) }
        return EditWording.reason(reason)
    }

    /// "that list's page says "Another list shares number 57"".
    public static func sharedNumber(_ number: Int) -> String {
        Strings.text(.editCuesSharedNumber, number)
    }

    /// A row's name: the channel's label, or ""No channel 7"".
    public static func row(_ row: CueGridRow) -> String {
        row.exists ? row.label : Strings.text(.editCuesNoChannel, row.channel)
    }

    /// The badge on a tile: "the transition rider's duration".
    public static func badge(ms: Int, locale: Locale = .current) -> String {
        ShowWording.span(ms: ms, locale: locale)
    }

    /// What a tile or the inspector names a content by: a media item's name,
    /// a text's first line, a slide, an input.
    public static func content(_ content: CueGridContent) -> String {
        switch content {
        case .media(_, let tile): return tile?.name ?? Strings.text(.editCellMissing)
        case .text(let text): return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        case .slide: return Strings.text(.editCellSlide)
        case .input(let input): return Strings.text(.editCellInput, input)
        }
    }

    // MARK: - Chips (Spec 11 §4, "Attribute chips")

    public static func name(_ kind: CueAttribute.Kind) -> String {
        switch kind {
        case .transition: return Strings.text(.editChipTransition)
        case .audioTransition: return Strings.text(.editChipAudioTransition)
        case .grade: return Strings.text(.editChipGrade)
        case .gain: return Strings.text(.editChipGain)
        }
    }

    public static func scope(_ scope: Scope) -> String {
        Strings.text(scope == .once ? .editScopeOnce : .editScopeTrack)
    }

    private static func decibels(_ db: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return Strings.text(.editChipDb, formatter.string(from: NSNumber(value: db)) ?? String(db))
    }

    private static func spokenSpan(ms: Int, locale: Locale) -> String {
        if ms == 1000 { return Strings.text(.editSecondSpoken) }
        guard let seconds = TimeText.shortSeconds(ms: ms, locale: locale) else { return TimeText.clock(ms: ms) }
        return Strings.text(.editSecondsSpoken, seconds)
    }

    /// An attribute's value: the object's label, or its kind and number
    /// where it has none, with its duration; a gain in decibels.
    public static func value(_ attribute: CueAttribute, catalog: Catalog?, spoken: Bool = false, locale: Locale = .current) -> String {
        let label: String?
        switch attribute.kind {
        case .transition: label = catalog?.transitions.first { $0.number == attribute.ref }?.label
        case .audioTransition: label = catalog?.audioTransitions.first { $0.number == attribute.ref }?.label
        case .grade: label = catalog?.grades.first { $0.number == attribute.ref }?.label
        case .gain: return decibels(attribute.db ?? 0, locale: locale)
        }
        let named = label.flatMap { $0.isEmpty ? nil : $0 } ?? Strings.text(.editChipNumbered, name(attribute.kind), attribute.ref ?? 0)
        guard let ms = attribute.ms else { return named }
        return Strings.text(.editChipTimed, named, spoken ? spokenSpan(ms: ms, locale: locale) : ShowWording.span(ms: ms, locale: locale))
    }

    /// A chip as its button reads and as VoiceOver says it: "a chip is a
    /// button whose label says its value and scope ("Grade 3, from here
    /// on")"; "a faint + and its name for one the cue doesn't write".
    public static func chip(_ chip: AttributeChip, catalog: Catalog?, locale: Locale = .current) -> (title: String, spoken: String, isSet: Bool) {
        switch chip.value {
        case .mixed:
            let mixed = Strings.text(.editChipMixed)
            return (mixed, Strings.text(.editChipSpoken, name(chip.kind), mixed), true)
        case .same(nil):
            let add = Strings.text(.editChipAdd, name(chip.kind))
            return (add, add, false)
        case .same(let attribute?):
            let scope = self.scope(chip.scope)
            return (Strings.text(.editChipScoped, value(attribute, catalog: catalog, locale: locale), scope),
                    Strings.text(.editChipSpoken, value(attribute, catalog: catalog, spoken: true, locale: locale), scope), true)
        }
    }

    // MARK: - VoiceOver for the grid (Spec 11 §10)

    /// "a cell says what the cue does there ("Cue 3, channel 2 Foreground:
    /// writes text, That saved a wretch like me, dissolve 0.5 seconds";
    /// "holds Amber Haze from cue 1"; "clears"), with its attribute writes
    /// after it."
    public static func cell(_ cell: CueGridCell, cue: Int, row: CueGridRow, catalog: Catalog?, locale: Locale = .current) -> String {
        var does: String
        switch (cell.state, cell.content) {
        case (.write, .text(let text)?): does = Strings.text(.editCellWritesText, text.replacingOccurrences(of: "\n", with: " "))
        case (.write, .slide?): does = Strings.text(.editCellWritesSlide)
        case (.write, .input(let input)?): does = Strings.text(.editCellWritesInput, input)
        case (.write, let content?): does = Strings.text(.editCellWritesMedia, self.content(content))
        case (.clear, _), (.write, nil): does = Strings.text(.editCellClears)
        case (.hold, let content?):
            let held: String
            if case .text = content { held = Strings.text(.editCellText) } else { held = self.content(content) }
            does = cell.heldFrom.map { Strings.text(.editCellHoldsFrom, held, $0) } ?? Strings.text(.editCellHolds, held)
        case (.hold, nil): does = Strings.text(.editCellHoldsNothing)
        }
        for attribute in cell.attributes { does += ", " + value(attribute, catalog: catalog, spoken: true, locale: locale) }
        return Strings.text(.editCellSpoken, cue, row.channel, self.row(row), does)
    }

    /// "Its column headers are the cues, each saying its number, label,
    /// section, trigger, and "live" on the live cue".
    public static func header(_ cell: CueCell, locale: Locale = .current) -> String {
        var parts: [String] = []
        if !cell.label.isEmpty { parts.append(cell.label) }
        if let section = cell.section, !section.isEmpty, section != cell.label { parts.append(section) }
        parts.append(ShowWording.trigger(cell, locale: locale))
        if cell.isLive { parts.append(Strings.text(.editCuesLive)) }
        return Strings.text(.editCuesHeaderSpoken, cell.number, parts.joined(separator: ", "))
    }

    /// "its row headers are the channels, each saying its number and label and whether it is folded".
    public static func rowSpoken(_ row: CueGridRow) -> String {
        var spoken = "\(row.channel) " + self.row(row)
        if row.isFolded { spoken += ", " + Strings.text(.editCuesFolded) }
        if row.isHidden, row.exists { spoken += ", " + Strings.text(.editCuesHidden) }
        return spoken
    }

    /// Spec 11 §4 — a row's eye, by what pressing it does: "Hide 2 Foreground from the Preview" or "Show … in the Preview".
    public static func eye(_ row: CueGridRow) -> String {
        Strings.text(row.isHidden ? .editCuesShow : .editCuesHide, "\(row.channel) " + self.row(row))
    }

    /// Spec 11 §2 — the Preview's header "and a pill while channels are hidden ("Hiding 2 channels")".
    public static func hiding(_ count: Int) -> String {
        Strings.counted(.editPreviewHiding, count)
    }

    // MARK: - The inspector (Spec 11 §4)

    /// "Its header says "Cue 3 of 14"".
    public static func title(_ inspector: CueInspector) -> String {
        guard let number = inspector.number else { return Strings.text(.editInspectorNone) }
        if inspector.isMulti { return Strings.text(.editInspectorSeveral, inspector.selected, inspector.count) }
        return Strings.text(.editInspectorCue, number, inspector.count)
    }

    /// "The inspector's header says which ("Fires in Sunday")", or why it can't.
    public static func fire(_ note: FireNote) -> String? {
        switch note {
        case .fires(let playlist?): return Strings.text(.editFireIn, playlist)
        case .fires(nil): return Strings.text(.editFireLibrary)
        case .refused(let refusal): return ShowWording.refusal(refusal)
        case .unavailable: return nil
        }
    }

    /// ""Cue 2's advance-after (8 s) and this cue's Time (12 s) both arm
    /// this cue; 8 s wins."" `selected` is the one selected cue's number,
    /// or nil for several.
    public static func pair(_ warning: PairWarning, selected: Int?, locale: Locale = .current) -> String {
        let advance = ShowWording.span(ms: warning.advanceMs, locale: locale)
        let time = ShowWording.span(ms: warning.timeMs, locale: locale)
        let wins = ShowWording.span(ms: warning.winsMs, locale: locale)
        if selected == warning.timeCue { return Strings.text(.editTriggerPairThis, warning.advanceCue, advance, time, wins) }
        return Strings.text(.editTriggerPair, warning.advanceCue, advance, warning.timeCue, time, wins)
    }

    public static func state(_ state: CueGridCell.State) -> String {
        switch state {
        case .write: return Strings.text(.editStateWrite)
        case .clear: return Strings.text(.editStateClear)
        case .hold: return Strings.text(.editStateHold)
        }
    }

    /// "The three-way control is a segmented control that names its state ("Channel 2 Foreground: write, text")".
    public static func stateSpoken(channel: Int, label: String, state: CueGridCell.State, content: CueGridContent?) -> String {
        let said: String
        switch state {
        case .write:
            let kind: String
            switch content {
            case .text?: kind = Strings.text(.editCellText)
            case .media(_, let tile)?: kind = tile.map { ShowWording.kind($0.kind) } ?? Strings.text(.editCellMissing)
            case .slide?: kind = Strings.text(.editCellSlide)
            case .input(let input)?: kind = Strings.text(.editCellInput, input)
            case nil: kind = ""
            }
            said = kind.isEmpty ? Strings.text(.editStateWrite) : Strings.text(.editStateSpokenWrite, kind)
        case .clear: said = Strings.text(.editStateSpokenClear)
        case .hold: said = Strings.text(.editStateSpokenHold)
        }
        return Strings.text(.editStateSpoken, channel, label, said)
    }

    /// A command row's warning, in words.
    public static func warning(_ warning: CueCommandLine.Warning) -> String {
        Strings.text(warning == .changesLibrary ? .editCommandsChangesLibrary : .editCommandsKept)
    }

    /// Spec 11 §2, "Rejections and warnings" — what the notice line says.
    public static func notice(_ notice: EditNotice, locale: Locale = .current) -> String {
        switch notice {
        case .rejected(let rejection): return EditWording.rejection(rejection)
        case .notSent(let reason): return readOnly(reason)
        case .warnings(let warnings): return warnings.joined(separator: " · ")
        case .skipped(let count): return Strings.counted(.editNoticeSkipped, count)
        case .onAir(let outputs):
            // "On air on outputs 1 and 2: this shows at once."
            let numbers = EditWording.joined(outputs.map(String.init), locale: locale)
            return Strings.text(outputs.count == 1 ? .editNoticeOnAirOne : .editNoticeOnAirMany, numbers)
        }
    }
}
