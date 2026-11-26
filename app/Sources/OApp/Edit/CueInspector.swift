// OApp — Spec 11 §4, "The inspector": what its four columns show for the selected cue or cues; and Spec 11 §2's short status.

import Foundation
import OCore

/// Spec 11 §4, "Multi-cue editing" — "A field whose cues differ reads "Mixed"."
public enum Mixed<Value: Equatable & Sendable>: Equatable, Sendable {
    case same(Value)
    case mixed

    /// One value for the cues' values: theirs when they agree.
    static func of(_ values: [Value]) -> Mixed<Value>? {
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? .same(first) : .mixed
    }
}

/// Spec 11 §4, "The Trigger column" — "When this cue's Time and the previous
/// cue's advance-after are both set, or this cue's advance-after and the
/// next cue's Time, the column says which one wins, the shorter (Spec 3 §5):
/// "Cue 2's advance-after (8 s) and this cue's Time (12 s) both arm this
/// cue; 8 s wins."" Cues by their numbers.
public struct PairWarning: Equatable, Sendable {
    public var advanceCue: Int
    public var advanceMs: Int
    /// The cue both arm: the one with the Time trigger.
    public var timeCue: Int
    public var timeMs: Int

    public init(advanceCue: Int, advanceMs: Int, timeCue: Int, timeMs: Int) {
        self.advanceCue = advanceCue
        self.advanceMs = advanceMs
        self.timeCue = timeCue
        self.timeMs = timeMs
    }

    /// "the shorter".
    public var winsMs: Int { min(advanceMs, timeMs) }
}

/// Spec 11 §4, "Commands" — one row of the Commands column.
public struct CueCommandLine: Equatable, Sendable {
    public enum Warning: Equatable, Sendable {
        /// "An edit held by the cue shows a warning that it changes the library when fired (Spec 5 §2)."
        case changesLibrary
        /// "A command kept verbatim because it is unknown shows Spec 1 §6's warning and can only be removed."
        case keptVerbatim
        /// Spec 11 §9 as corrected 2026-11-25 — "Recursive (it calls a macro that calls this one, the engine's `cycle`)".
        case recursive
        /// "Missing (it names a macro, a channel, a stack, an output, a grade or a transition that doesn't exist)".
        case missing
    }

    /// Its place in the cue's commands.
    public var position: Int
    /// "each as its plain name (Spec 10 §15)".
    public var name: String
    public var warning: Warning?
    public var canEdit: Bool
    public var canMoveUp: Bool
    public var canMoveDown: Bool
}

/// Spec 11 §4, "Attribute chips" — one chip of the Channel column.
public struct AttributeChip: Equatable, Sendable {
    public var kind: CueAttribute.Kind
    /// What the selected cues write of it: nil for "a faint + and its name for one the cue doesn't write".
    public var value: Mixed<CueAttribute?>
    /// The scope it reads, or the one a new chip starts on (Spec 11 §4, "Tracking off").
    public var scope: Scope
    /// "with Clear or Hold ... its popover offers no scope".
    public var offersScope: Bool
}

/// Spec 11 §4, "The inspector" — "shows the selected cue in four columns",
/// and for several cues "is reduced (UX spec)".
public struct CueInspector: Equatable, Sendable {
    /// "Cue 3 of 14": the first selected cue's number, the list's count, and how many are selected.
    public var number: Int?
    public var count = 0
    public var selected = 0
    public var isLive = false
    public var isMulti: Bool { selected > 1 }

    // The Cue column.
    public var label: Mixed<String>?
    public var section: Mixed<String>?
    /// "a combo box offering the list's sections and E3's names".
    public var sections: [String] = []
    public var note = ""

    // The Trigger column.
    public var trigger: Mixed<CueTrigger.Kind>?
    public var advanceAfterMs: Mixed<Int?>?
    public var pairWarnings: [PairWarning] = []
    /// What Use Previous Video's Length would fill Time with, or nil when the previous cue plays no timed media.
    public var previousVideoMs: Int?

    // The Commands column; empty for several cues, where it "says to select one cue".
    public var commands: [CueCommandLine] = []

    // The Channel column.
    public var channel: Int?
    public var channelLabel = ""
    public var channelExists = true
    /// The selected cell's state and what it shows; nil for several cues.
    public var state: CueGridCell.State?
    public var content: CueGridContent?
    public var heldFrom: Int?
    public var chips: [AttributeChip] = []

    /// E3's section names, in the order a song runs.
    public static let sectionNames = ["Intro", "Verse", "Pre-Chorus", "Chorus", "Bridge", "Tag", "Interlude", "Instrumental", "Outro", "Ending"]

    public init() {}

    @MainActor
    public static func make(list: List, grid: CueGridModel, selection: CueGridSelection, catalog: Catalog, media: [MediaItem]) -> CueInspector {
        var inspector = CueInspector()
        inspector.count = list.cues.count
        let indices = list.cues.indices.filter { selection.cues.contains(list.cues[$0].uuid.uuidString.lowercased()) }
        let cues = indices.map { list.cues[$0] }
        inspector.selected = cues.count
        inspector.sections = sections(of: list)
        inspector.channel = selection.channel
        if let channel = selection.channel, let row = grid.row(of: channel) {
            inspector.channelLabel = grid.rows[row].label
            inspector.channelExists = grid.rows[row].exists
        }
        guard let first = indices.first else { return inspector }
        inspector.number = first + 1
        inspector.isLive = grid.headers.indices.contains(first) && grid.headers[first].isLive

        inspector.label = Mixed.of(cues.map(\.label))
        inspector.section = Mixed.of(cues.map { $0.section ?? "" })
        inspector.note = cues.count == 1 ? cues[0].note : ""
        inspector.trigger = Mixed.of(cues.map(\.trigger.kind))
        inspector.advanceAfterMs = Mixed.of(cues.map(\.advanceAfterMs))
        inspector.pairWarnings = pairWarnings(in: list, for: indices)
        inspector.previousVideoMs = cues.count == 1 ? previousVideoMs(in: list, before: first, media: media) : nil

        if cues.count == 1 {
            let rows = CueEdits.others(in: cues[0])
            inspector.commands = rows.enumerated().map { index, row in
                let command = row.entry.command
                let kept = command.isUnknown || command.isInvalid
                var warning: CueCommandLine.Warning?
                if kept { warning = .keptVerbatim } else if case .edit = command { warning = .changesLibrary }
                return CueCommandLine(position: row.position, name: kept ? command.cmd : KeyWording.plain(command), warning: warning,
                                      canEdit: !kept, canMoveUp: index > 0, canMoveDown: index < rows.count - 1)
            }
        }

        if let channel = selection.channel {
            let says = cues.map { CueSays.about(channel, in: $0) }
            let tracking = catalog.settings?.tracking
            inspector.chips = CueAttribute.Kind.allCases.map { kind in
                let tracks: Bool
                switch kind {
                case .transition: tracks = tracking?.transition ?? true
                case .audioTransition: tracks = tracking?.audioTransition ?? true
                case .grade: tracks = tracking?.grade ?? true
                case .gain: tracks = tracking?.gain ?? true
                }
                let value = Mixed.of(says.map { $0.attribute(kind) }) ?? .same(nil)
                let scope: Scope
                if case .same(let attribute?) = value {
                    scope = CueChips.shownScope(of: attribute, tracking: tracks)
                } else {
                    scope = says.first.map { CueChips.scope(for: kind, in: $0, tracking: tracks) } ?? (tracks ? .track : .once)
                }
                return AttributeChip(kind: kind, value: value, scope: scope, offersScope: says.contains(where: CueChips.offersScope))
            }
            if cues.count == 1, let row = grid.row(of: channel), grid.cells[row].indices.contains(first) {
                let cell = grid.cells[row][first]
                inspector.state = cell.state
                inspector.content = cell.content
                inspector.heldFrom = cell.heldFrom
            }
        }
        return inspector
    }

    /// The list's sections in the order they first appear, then E3's names it doesn't use yet.
    private static func sections(of list: List) -> [String] {
        var names: [String] = []
        for cue in list.cues {
            if let section = cue.section, !section.isEmpty, !names.contains(section) { names.append(section) }
        }
        for name in sectionNames where !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
        return names
    }

    /// "The pair warning counts every selected cue": each pair once, in the list's order.
    private static func pairWarnings(in list: List, for indices: [Int]) -> [PairWarning] {
        var warnings: [PairWarning] = []
        func pair(advance: Int, time: Int) {
            guard list.cues.indices.contains(advance), list.cues.indices.contains(time), let advanceMs = list.cues[advance].advanceAfterMs,
                  case .time(let timeMs) = list.cues[time].trigger.kind else { return }
            let warning = PairWarning(advanceCue: advance + 1, advanceMs: advanceMs, timeCue: time + 1, timeMs: timeMs)
            if !warnings.contains(warning) { warnings.append(warning) }
        }
        for index in indices {
            pair(advance: index - 1, time: index)
            pair(advance: index, time: index + 1)
        }
        return warnings.sorted { $0.timeCue < $1.timeCue }
    }

    /// "Use Previous Video's Length fills Time with the duration of the
    /// previous cue's first media write in channel order, within its in and
    /// out points, as a number copied once (UX spec)."
    private static func previousVideoMs(in list: List, before index: Int, media: [MediaItem]) -> Int? {
        guard index > 0 else { return nil }
        var writes: [(channel: Int, content: MediaContent)] = []
        for entry in list.cues[index - 1].commands {
            if case .channelWrite(let write) = entry.command, case .number(let channel) = write.channel, case .media(let content) = write.content {
                writes.append((channel, content))
            }
        }
        guard let first = writes.sorted(by: { $0.channel < $1.channel }).first,
              let item = media.first(where: { $0.id == first.content.ref }), let duration = item.entry.durationMs,
              item.entry.kind == .video || item.entry.kind == .audio else { return nil }
        let start = first.content.inMs ?? item.entry.defaults.trimInMs ?? 0
        let end = first.content.outMs ?? item.entry.defaults.trimOutMs ?? duration
        return max(0, min(end, duration) - max(0, start))
    }
}

/// Spec 11 §2, the top bar's right end in edit mode — "the saving pill ...
/// and the engine pill ... Before them, an output that isn't presenting or
/// is blacked out shows as its show-mode dot, and each of show mode's tags
/// shows while it applies (Spec 10 §8), so nothing show mode's bar reports
/// is missed here."
public struct EditStatus: Equatable, Sendable {
    public enum Engine: Equatable, Sendable {
        /// "a green dot and "Engine" while the engine is connected, every output is presenting and no badge stands".
        case fine
        /// Connected, with an output that isn't presenting or a badge standing: what is wrong shows beside the pill.
        case attention
        /// "While the engine isn't connected the pill is hollow and red, and the banner says why".
        case away
    }

    /// Show mode's saving tag; nil for "Saved".
    public var saving: SavingTag?
    public var engine: Engine
    public var dots: [OutputDot]
    /// Show mode's tags but the saving tag, which is the pill's.
    public var tags: [TopBarTag]

    public init(saving: SavingTag?, engine: Engine, dots: [OutputDot], tags: [TopBarTag]) {
        self.saving = saving
        self.engine = engine
        self.dots = dots
        self.tags = tags
    }

    public static func make(dots: [OutputDot], tags: [TopBarTag], isConnected: Bool) -> EditStatus {
        var saving: SavingTag?
        var others: [TopBarTag] = []
        var badge = false
        for tag in tags {
            switch tag {
            case .saving(let tag): saving = tag
            case .engine:
                badge = true
                others.append(tag)
            default: others.append(tag)
            }
        }
        let troubled = dots.contains { $0.state != .presenting } || badge
        return EditStatus(saving: saving, engine: !isConnected ? .away : (troubled ? .attention : .fine),
                          dots: dots.filter { $0.state != .presenting || $0.isBlackedOut }, tags: others)
    }
}

/// Spec 11 §2, "Program" — "the live picture of the same stack ... outlined
/// in the live red while an output shows it, with a pill naming those
/// outputs, "On air · Out 1, 2"; when none does, the outline is plain and
/// the pill says "Preview only". A blacked-out stack is dimmed and labelled
/// as in show mode's preview."
public struct ProgramPanel: Equatable, Sendable {
    public var stack: Int
    /// The outputs presenting the stack, by number.
    public var outputs: [Int]
    public var isBlackedOut: Bool

    public var isOnAir: Bool { !outputs.isEmpty }

    public static func make(stack: Int, dots: [OutputDot]) -> ProgramPanel {
        let showing = dots.filter { $0.stack == stack }
        return ProgramPanel(stack: stack, outputs: showing.filter { $0.state == .presenting }.map(\.number).sorted(),
                            isBlackedOut: showing.contains(where: \.isBlackedOut))
    }
}
