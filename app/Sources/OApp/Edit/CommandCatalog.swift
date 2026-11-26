// OApp — Spec 11 §4 and §9 as corrected 2026-11-25: the palette's command browser, a tree of the commands grouped by
// what they touch, each with the fields of its small form and the command it builds; and what a macro's row says is
// wrong with it.

import Foundation
import OCore

/// One field of a command's small form.
public struct CommandField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A pick among numbered things that exist, or a playlist's title or a pool item.
        case pick(Pick)
        /// On, off or toggle.
        case state
        case transport
        case endBehavior
        /// Lock or unlock.
        case lock
        /// A whole number typed: a cue's or an item's.
        case number
        case text
        /// Seconds, as Spec 2's durations (`timer N set`); optional ones may be left empty.
        case seconds
        /// Milliseconds, empty for the object's own.
        case ms
        case decibels
        /// A tick box (a timer's "counts up").
        case flag
    }

    public enum Pick: Equatable, Sendable {
        case channel, stack, output, audioOutput, timer, popup, list, playlist, media
        /// A grade, or None.
        case grade
        case transition, audioTransition
    }

    public var id: String
    public var label: StringKey
    public var kind: Kind
    public var optional = false
}

/// A value a field holds.
public enum CommandValue: Equatable, Sendable {
    case int(Int)
    case text(String)
    case bool(Bool)
}

/// One command of the browser: its title, its form, and why it can't be added, if it can't.
public struct CommandLeaf: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case next, previous, cue, listCue, itemCue, itemSection, playlist, disarm
        case writeMedia, writeText, clear, reset, transport, endBehavior, lock, freeze, grade, transition, audioTransition, gain
        case outputStack, blackout, mute
        case audioMute
        case macro(Int)
        case timerSet, timerStart, timerPause, timerReset
        case popupSet, popupClear
        case clearAll, preflight, snapshot, undo, redo
    }

    public var kind: Kind
    public var title: String
    public var fields: [CommandField]
    /// Spec 11 §4 — a macro that would call the macro being edited again is "marked Recursive and not offered".
    public var refused: String?
}

/// One group of the tree.
public struct CommandGroup: Equatable, Sendable {
    public var title: String
    public var leaves: [CommandLeaf]
}

/// Spec 11 §4 as corrected 2026-11-25 — "a tree of the commands, grouped by what they touch and offering only what
/// exists", with the Channels group in a macro (§9).
@MainActor
public enum CommandCatalog {
    /// The tree for a cue's commands, or for macro `macro`'s, which adds Channels and marks the recursive macros.
    public static func groups(catalog: Catalog, macro: Int? = nil) -> [CommandGroup] {
        let settings = catalog.settings ?? MachineSettings()
        func field(_ id: String, _ label: StringKey, _ kind: CommandField.Kind, optional: Bool = false) -> CommandField {
            CommandField(id: id, label: label, kind: kind, optional: optional)
        }
        func leaf(_ kind: CommandLeaf.Kind, _ title: StringKey, _ fields: [CommandField] = []) -> CommandLeaf {
            CommandLeaf(kind: kind, title: Strings.text(title), fields: fields)
        }
        let channel = field("channel", .editFormChannel, .pick(.channel))
        var groups: [CommandGroup] = []
        func add(_ title: StringKey, _ leaves: [CommandLeaf]) {
            if !leaves.isEmpty { groups.append(CommandGroup(title: Strings.text(title), leaves: leaves)) }
        }
        add(.editBrowserPlayback, [
            leaf(.next, .editBrowserNext), leaf(.previous, .editBrowserPrevious),
            leaf(.cue, .editBrowserCue, [field("cue", .editBrowserCueNumber, .number)]),
            catalog.lists.isEmpty ? nil : leaf(.listCue, .editBrowserListCue, [field("list", .editBrowserList, .pick(.list)),
                                                                               field("cue", .editBrowserCueNumber, .number)]),
            leaf(.itemCue, .editBrowserItemCue, [field("item", .editBrowserItem, .number), field("cue", .editBrowserCueNumber, .number)]),
            leaf(.itemSection, .editBrowserItemSection, [field("item", .editBrowserItem, .number), field("section", .editBrowserSection, .text)]),
            catalog.playlists.isEmpty ? nil : leaf(.playlist, .editBrowserPlaylist, [field("playlist", .editBrowserPlaylistName, .pick(.playlist))]),
            leaf(.disarm, .editBrowserDisarm),
        ].compactMap { $0 })
        if macro != nil, !catalog.channels.isEmpty {
            let ms = field("ms", .editFormMs, .ms, optional: true)
            add(.editPaletteChannels, [
                leaf(.writeMedia, .editPaletteWriteMedia, [channel, field("media", .editFormMedia, .pick(.media))]),
                leaf(.writeText, .editPaletteWriteText, [channel, field("body", .editContentFormBody, .text)]),
                leaf(.clear, .editPaletteClear, [channel]),
                leaf(.reset, .editPaletteReset, [channel]),
                leaf(.transport, .editBrowserTransport, [channel, field("mode", .editBrowserMode, .transport)]),
                leaf(.endBehavior, .editBrowserEndBehavior, [channel, field("mode", .editBrowserAtEnd, .endBehavior)]),
                leaf(.lock, .editBrowserLock, [channel, field("locked", .editFormState, .lock)]),
                leaf(.freeze, .editBrowserFreeze, [channel, field("state", .editFormState, .state)]),
                catalog.grades.isEmpty ? nil : leaf(.grade, .editPaletteGrade, [channel, field("ref", .editFormGrade, .pick(.grade)), ms]),
                catalog.transitions.isEmpty ? nil : leaf(.transition, .editPaletteTransition, [channel, field("ref", .editFormTransition, .pick(.transition)), ms]),
                catalog.audioTransitions.isEmpty ? nil : leaf(.audioTransition, .editPaletteAudioTransition,
                                                              [channel, field("ref", .editFormAudioTransition, .pick(.audioTransition)), ms]),
                leaf(.gain, .editPaletteGain, [channel, field("db", .editFormGain, .decibels)]),
            ].compactMap { $0 })
        }
        add(.editPaletteStacks, [
            catalog.outputs.isEmpty || catalog.stacks.isEmpty ? nil : leaf(.outputStack, .editPaletteOutputStack,
                                                                           [field("output", .editFormOutput, .pick(.output)), field("stack", .editFormStack, .pick(.stack))]),
            catalog.stacks.isEmpty ? nil : leaf(.blackout, .editPaletteBlackout, [field("stack", .editFormStack, .pick(.stack)), field("state", .editFormState, .state)]),
            catalog.stacks.isEmpty || catalog.channels.isEmpty ? nil : leaf(.mute, .editPaletteMute,
                                                                            [field("stack", .editFormStack, .pick(.stack)), channel, field("state", .editFormState, .state)]),
        ].compactMap { $0 })
        add(.editBrowserAudio, catalog.audioOutputs.isEmpty ? [] : [
            leaf(.audioMute, .editBrowserAudioMute, [field("audio", .editBrowserAudioOutput, .pick(.audioOutput)), field("state", .editFormState, .state)]),
        ])
        add(.editPaletteMacros, catalog.macros.map { item in
            var leaf = CommandLeaf(kind: .macro(item.number), title: Strings.text(.editPaletteMacro, item.number, item.label), fields: [])
            if let macro, MacroCheck.reaches(item.number, macro, macros: catalog.macros) { leaf.refused = Strings.text(.editCommandsTagRecursive) }
            return leaf
        })
        add(.editPaletteTimers, settings.timers > 0 ? [
            leaf(.timerSet, .editPaletteTimerSet, [field("timer", .editFormTimer, .pick(.timer)), field("duration", .editFormDuration, .seconds),
                                                    field("up", .editFormCountsUp, .flag)]),
            leaf(.timerStart, .editBrowserTimerStart, [field("timer", .editFormTimer, .pick(.timer))]),
            leaf(.timerPause, .editBrowserTimerPause, [field("timer", .editFormTimer, .pick(.timer))]),
            leaf(.timerReset, .editBrowserTimerReset, [field("timer", .editFormTimer, .pick(.timer))]),
        ] : [])
        add(.editPalettePopups, settings.popups > 0 ? [
            leaf(.popupSet, .editPalettePopupSet, [field("popup", .editFormPopup, .pick(.popup)), field("text", .editFormText, .text),
                                                    field("after", .editFormClearAfter, .seconds, optional: true)]),
            leaf(.popupClear, .editBrowserPopupClear, [field("popup", .editFormPopup, .pick(.popup))]),
        ] : [])
        add(.editPaletteSystem, [
            leaf(.clearAll, .clearsClearAll), leaf(.preflight, .editBrowserPreflight), leaf(.snapshot, .editBrowserSnapshot),
            leaf(.undo, .editBrowserUndo), leaf(.redo, .editBrowserRedo),
        ])
        return groups
    }

    /// "a search field over a tree": the groups with only the commands whose title has the words typed, case and
    /// accents ignored; empty, everything.
    public static func filter(_ groups: [CommandGroup], _ query: String) -> [CommandGroup] {
        let words = query.split(separator: " ").map { String($0) }
        guard !words.isEmpty else { return groups }
        func has(_ text: String) -> Bool {
            words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return groups.compactMap { group in
            let leaves = has(group.title) ? group.leaves : group.leaves.filter { has($0.title) }
            return leaves.isEmpty ? nil : CommandGroup(title: group.title, leaves: leaves)
        }
    }

    /// A pick's choices, in number order: what the value is and how it reads.
    public static func choices(_ pick: CommandField.Pick, catalog: Catalog, media: [MediaItem]) -> [(value: CommandValue, title: String)] {
        func numbered(_ items: [(Int, String)]) -> [(value: CommandValue, title: String)] {
            items.sorted { $0.0 < $1.0 }.map { (.int($0.0), EditModeWording.numbered($0.0, $0.1)) }
        }
        let settings = catalog.settings ?? MachineSettings()
        switch pick {
        case .channel: return numbered(catalog.channels.map { ($0.number, $0.label) })
        case .stack: return numbered(catalog.stacks.map { ($0.number, $0.label) })
        case .output: return numbered(catalog.outputs.map { ($0.number, $0.label) })
        case .audioOutput: return numbered(catalog.audioOutputs.map { ($0.number, $0.label) })
        case .timer: return settings.timers > 0 ? (1...settings.timers).map { (.int($0), String($0)) } : []
        case .popup: return settings.popups > 0 ? (1...settings.popups).map { (.int($0), String($0)) } : []
        case .list: return numbered(catalog.lists.filter { !$0.local }.map { ($0.number, $0.title) })
        case .playlist: return catalog.playlists.map { (.text($0.playlist.title), $0.playlist.title) }
        case .media:
            return media.filter { $0.presence == "ok" }.map { (.text($0.id), ($0.entry.path as NSString).lastPathComponent) }
        case .grade: return [(.int(0), Strings.text(.editChipFormNone))] + numbered(catalog.grades.map { ($0.number, $0.label) })
        case .transition: return numbered(catalog.transitions.map { ($0.number, $0.label) })
        case .audioTransition: return numbered(catalog.audioTransitions.map { ($0.number, $0.label) })
        }
    }

    /// The command a leaf builds from its form's values; nil while a field it needs is missing or doesn't read.
    public static func build(_ kind: CommandLeaf.Kind, _ values: [String: CommandValue]) -> Command? {
        func int(_ id: String) -> Int? { if case .int(let n)? = values[id] { return n } else { return nil } }
        func text(_ id: String) -> String? { if case .text(let t)? = values[id] { return t } else { return nil } }
        func flag(_ id: String) -> Bool { if case .bool(let b)? = values[id] { return b } else { return false } }
        func state() -> SwitchState? { text("state").flatMap(SwitchState.init(rawValue:)) }
        let channel = int("channel").map(Target.number)
        switch kind {
        case .next: return .next
        case .previous: return .previous
        case .cue: return int("cue").flatMap { $0 >= 1 ? .cue($0) : nil }
        case .listCue:
            guard let list = int("list"), let cue = int("cue"), cue >= 1 else { return nil }
            return .listCue(list: list, cue: cue)
        case .itemCue:
            guard let item = int("item"), let cue = int("cue"), item >= 1, cue >= 1 else { return nil }
            return .itemCue(item: item, cue: cue)
        case .itemSection:
            guard let item = int("item"), item >= 1, let section = text("section"), !section.isEmpty else { return nil }
            return .itemSection(item: item, section: section)
        case .playlist: return text("playlist").map { .playlistLoad(title: $0) }
        case .disarm: return .disarm
        case .writeMedia:
            guard let channel, let ref = text("media") else { return nil }
            return .channelWrite(ChannelWrite(channel: channel, content: .media(MediaContent(ref: ref))))
        case .writeText:
            guard let channel else { return nil }
            return .channelWrite(ChannelWrite(channel: channel, content: .text(fields: ["body": text("body") ?? ""])))
        case .clear: return channel.map { .channelClear(channel: $0) }
        case .reset: return channel.map { .channelReset(channel: $0) }
        case .transport:
            guard let channel, let mode = text("mode").flatMap(TransportMode.init(rawValue:)) else { return nil }
            return .channelTransport(channel: channel, mode: mode)
        case .endBehavior:
            guard let channel, let mode = text("mode").flatMap(EndBehavior.init(rawValue:)) else { return nil }
            return .channelEndBehavior(channel: channel, mode: mode)
        case .lock: return channel.map { .channelLock(channel: $0, locked: flag("locked")) }
        case .freeze:
            guard let channel, let state = state() else { return nil }
            return .channelFreeze(channel: channel, state: state)
        case .grade:
            guard let channel, let ref = int("ref") else { return nil }
            return .channelGrade(channel: channel, ref: ref, ms: int("ms"))
        case .transition:
            guard let channel, let ref = int("ref") else { return nil }
            return .channelTransition(channel: channel, ref: ref, ms: int("ms"))
        case .audioTransition:
            guard let channel, let ref = int("ref") else { return nil }
            return .channelAudioTransition(channel: channel, ref: ref, ms: int("ms"))
        case .gain:
            guard let channel, let db = text("db").flatMap(Double.init), (-60...60).contains(db) else { return nil }
            return .channelGain(channel: channel, db: db)
        case .outputStack:
            guard let output = int("output"), let stack = int("stack") else { return nil }
            return .outputStack(output: output, stack: stack)
        case .blackout:
            guard let stack = int("stack"), let state = state() else { return nil }
            return .stackBlackout(stack: .number(stack), state: state)
        case .mute:
            guard let stack = int("stack"), let channel = int("channel"), let state = state() else { return nil }
            return .stackMute(stack: stack, channel: channel, state: state)
        case .audioMute:
            guard let audio = int("audio"), let state = state() else { return nil }
            return .audioMute(audio: .number(audio), state: state)
        case .macro(let number): return .macro(number)
        case .timerSet:
            guard let timer = int("timer"), let ms = int("duration") else { return nil }
            return .timerSet(timer: timer, ms: ms, up: flag("up"))
        case .timerStart: return int("timer").map { .timerStart(timer: $0) }
        case .timerPause: return int("timer").map { .timerPause(timer: $0) }
        case .timerReset: return int("timer").map { .timerReset(timer: $0) }
        case .popupSet:
            guard let popup = int("popup") else { return nil }
            return .popupSet(popup: popup, text: text("text") ?? "", clearAfterMs: int("after"))
        case .popupClear: return int("popup").map { .popupClear(popup: $0) }
        case .clearAll: return .systemClearAll
        case .preflight: return .systemPreflight
        case .snapshot: return .systemSnapshot
        case .undo: return .undo
        case .redo: return .redo
        }
    }
}

/// Spec 11 §9 as corrected 2026-11-25 — what a macro's row says is wrong with it, in a short tag.
public enum MacroCheck {
    /// Whether running macro `from` comes back to macro `target`: it is `target`, or a macro it calls does.
    public static func reaches(_ from: Int, _ target: Int, macros: [Macro]) -> Bool {
        var seen: Set<Int> = []
        var queue = [from]
        while let n = queue.popLast() {
            if n == target { return true }
            guard seen.insert(n).inserted, let macro = macros.first(where: { $0.number == n }) else { continue }
            for entry in macro.commands { if case .macro(let next) = entry.command { queue.append(next) } }
        }
        return false
    }

    /// "Recursive (it calls a macro that calls this one ...), Missing (it names a macro, a channel, a stack, an
    /// output, a grade or a transition that doesn't exist), Unknown (kept verbatim ...), and Edits library".
    public static func warning(_ command: Command, in macro: Int, catalog: Catalog, media: [MediaItem]) -> CueCommandLine.Warning? {
        if command.isUnknown || command.isInvalid { return .keptVerbatim }
        if case .macro(let n) = command, reaches(n, macro, macros: catalog.macros) { return .recursive }
        var missing = false
        func check(_ type: NumberedType, _ numbers: [Int]) {
            command.forEachReference(of: type) { n in
                if n != 0, !numbers.contains(n) { missing = true }
            }
        }
        check(.macro, catalog.macros.map(\.number))
        check(.channel, catalog.channels.map(\.number))
        check(.stack, catalog.stacks.map(\.number))
        check(.output, catalog.outputs.map(\.number))
        check(.grade, catalog.grades.map(\.number))
        check(.transition, catalog.transitions.map(\.number))
        check(.audioTransition, catalog.audioTransitions.map(\.number))
        check(.audioOutput, catalog.audioOutputs.map(\.number))
        if case .channelWrite(let write) = command, case .media(let content) = write.content, !media.contains(where: { $0.id == content.ref }) {
            missing = true
        }
        if missing { return .missing }
        if case .edit = command { return .changesLibrary }
        return nil
    }
}

/// Spec 11 §9 as corrected 2026-11-25 — the stage's transition preview: how much of the outgoing picture, the colour
/// and the incoming picture make the frame at linear progress `t`, "as Spec 4 §7 says the channel pass does".
public enum TransitionMix {
    public static func weights(_ type: TransitionType, easing: Easing, at t: Double) -> (outgoing: Double, color: Double, incoming: Double) {
        let p = min(1, max(0, t))
        switch type {
        case .cut:
            return p > 0 ? (0, 0, 1) : (1, 0, 0)
        case .dissolve:
            let e = EasingCurve.value(easing, at: p)
            return (1 - e, 0, e)
        case .fadeThroughColor:
            // "t < 0.5: lerp(outgoing, colour, 2t); else lerp(colour, incoming, 2t - 1)".
            let e = EasingCurve.value(easing, at: p)
            return e < 0.5 ? (1 - 2 * e, 2 * e, 0) : (0, 2 - 2 * e, 2 * e - 1)
        }
    }
}

/// Spec 11 §9 as corrected 2026-11-25 — the stage's audio lanes: the outgoing's and incoming's gain at a time from
/// the trigger, and where the picture's transition starts. "The offset is measured from the trigger, not from the
/// picture: a J cut delays the picture transition, an L cut delays the audio transition" (UX spec).
public enum AudioFade {
    /// When the sound's change starts and when the picture's does, in ms after the trigger.
    public static func starts(_ t: AudioTransition) -> (sound: Int, picture: Int) {
        (max(0, t.offsetMs), max(0, -t.offsetMs))
    }

    public static func gains(_ t: AudioTransition, at ms: Double) -> (outgoing: Double, incoming: Double) {
        let start = Double(starts(t).sound)
        let length = Double(max(0, t.ms))
        func ramp(_ from: Double, _ duration: Double) -> Double {
            guard duration > 0 else { return ms >= from ? 1 : 0 }
            return EasingCurve.value(t.easing, at: (ms - from) / duration)
        }
        switch t.type {
        case .cut:
            let after = ms >= start ? 1.0 : 0
            return (1 - after, after)
        case .crossfade:
            let e = ramp(start, length)
            return (1 - e, e)
        case .fadeThroughSilence:
            return (1 - ramp(start, length / 2), ramp(start + length / 2, length / 2))
        }
    }
}
