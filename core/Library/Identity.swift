// OCore — Spec 1 §4, identity: numbers, renumbering, cue addressing, replace media.

import Foundation

/// Spec 1 §4 — "Each numbered type has its own space of positive integers."
public enum NumberedType: String, CaseIterable, Sendable {
    case channel, preset, textStyle, grade, transition, audioTransition, macro, list, stack, output, audioOutput, input

    public var displayName: String {
        switch self {
        case .textStyle: return "text style"
        case .audioTransition: return "audio transition"
        case .audioOutput: return "audio output"
        default: return rawValue
        }
    }

    /// Spec 5 §3 — the word an edit names this type by, which is also its
    /// field in the object form: `channel 2`, `textstyle 1`, `audiotransition
    /// 1`, `audiooutput 1`.
    public var editWord: String { rawValue.lowercased() }

    public init?(editWord: String) {
        guard let type = NumberedType.allCases.first(where: { $0.editWord == editWord.lowercased() }) else { return nil }
        self = type
    }
}

/// What `Identity.renumber` and `Identity.swap` did.
public enum RenumberOutcome: Equatable, Sendable {
    case renumbered
    case numberTaken
    case noSuchObject
    case invalidNumber
}

/// Spec 1 §4 — "Renumbering is a library edit, not a rename. When an
/// object's number changes, every internal reference in the library and the
/// machine root is rewritten in the same save... Moving to a number that is
/// already taken offers a swap, which renumbers both objects and rewrites both
/// sets of references. The `uuid` never changes."
public enum Identity {
    /// Spec 7 §2 — a list is renumbered alone: of two lists sharing a number,
    /// the one that number reaches, the first.
    public static func renumber(_ type: NumberedType, from: Int, to: Int, library: inout Library, machine: inout Machine) -> RenumberOutcome {
        guard to >= 1 else { return .invalidNumber }
        guard exists(type, from, library, machine) else { return .noSuchObject }
        if from == to { return .renumbered }
        guard !exists(type, to, library, machine) else { return .numberTaken }
        let lists = library.list(number: from).map { [$0.uuid: to] } ?? [:]
        apply(type, map: [from: to], lists: type == .list ? lists : [:], library: &library, machine: &machine)
        return .renumbered
    }

    public static func swap(_ type: NumberedType, _ a: Int, _ b: Int, library: inout Library, machine: inout Machine) -> RenumberOutcome {
        guard a >= 1, b >= 1 else { return .invalidNumber }
        guard exists(type, a, library, machine), exists(type, b, library, machine) else { return .noSuchObject }
        if a == b { return .renumbered }
        var lists: [UUID: Int] = [:]
        if type == .list, let listA = library.list(number: a), let listB = library.list(number: b) {
            lists = [listA.uuid: b, listB.uuid: a]
        }
        apply(type, map: [a: b, b: a], lists: lists, library: &library, machine: &machine)
        return .renumbered
    }

    // MARK: - Implementation

    static func exists(_ type: NumberedType, _ number: Int, _ library: Library, _ machine: Machine) -> Bool {
        switch type {
        case .channel: return library.channel(number) != nil
        case .preset: return library.preset(number) != nil
        case .textStyle: return library.textStyle(number) != nil
        case .grade: return library.grade(number) != nil
        case .transition: return library.transition(number) != nil
        case .audioTransition: return library.audioTransition(number) != nil
        case .macro: return library.macro(number) != nil || machine.macro(number) != nil
        case .list: return library.list(number: number) != nil
        case .stack: return machine.stack(number) != nil
        case .output: return machine.output(number) != nil
        case .audioOutput: return machine.audioOutput(number) != nil
        case .input: return machine.input(number) != nil
        }
    }

    /// Renumber the objects of one type by `map` and rewrite every reference
    /// to them in both roots. Lists are renumbered by uuid (`lists`, Spec 7
    /// §2), and a playlist link follows the list it finds, by its uuid or, in
    /// a hand-made file, by number (Spec 7 §3); commands name numbers, so
    /// they follow `map`.
    static func apply(_ type: NumberedType, map: [Int: Int], lists: [UUID: Int] = [:], library: inout Library, machine: inout Machine) {
        // Which list each playlist link finds before anything moves.
        let linkTargets: [[UUID?]] = machine.playlists.map { playlist in
            playlist.items.map { item in
                guard case .linked = item.kind else { return nil }
                return library.list(for: item.kind)?.uuid
            }
        }
        let transform: (NumberedType, Int) -> Int = { found, n in found == type ? (map[n] ?? n) : n }
        func number(_ n: Int, _ t: NumberedType) -> Int { transform(t, n) }
        func rewrite(_ entries: inout [GuardedCommand]) {
            for i in entries.indices {
                entries[i].command = entries[i].command.mapReferences(transform)
                entries[i].when = entries[i].when?.mapReferences(transform)
            }
        }

        // The objects themselves.
        switch type {
        case .channel: library.channels = renumbered(library.channels, map) { $0.number } set: { $0.number = $1 }
        case .preset: library.presets = renumbered(library.presets, map) { $0.number } set: { $0.number = $1 }
        case .textStyle: library.textStyles = renumbered(library.textStyles, map) { $0.number } set: { $0.number = $1 }
        case .grade: library.grades = renumbered(library.grades, map) { $0.number } set: { $0.number = $1 }
        case .transition: library.transitions = renumbered(library.transitions, map) { $0.number } set: { $0.number = $1 }
        case .audioTransition: library.audioTransitions = renumbered(library.audioTransitions, map) { $0.number } set: { $0.number = $1 }
        case .macro:
            library.macros = renumbered(library.macros, map) { $0.number } set: { $0.number = $1 }
            machine.macros = renumbered(machine.macros, map) { $0.number } set: { $0.number = $1 }
        case .list:
            // Spec 7 §2 — the lists this edit reaches, in the order they loaded in.
            var moved = library.lists
            for i in moved.indices {
                if let to = lists[moved[i].uuid] { moved[i].number = to }
            }
            library.lists = moved.enumerated()
                .sorted { ($0.element.number, $0.offset) < ($1.element.number, $1.offset) }
                .map(\.element)
        case .stack: machine.stacks = renumbered(machine.stacks, map) { $0.number } set: { $0.number = $1 }
        case .output: machine.outputs = renumbered(machine.outputs, map) { $0.number } set: { $0.number = $1 }
        case .audioOutput: machine.audioOutputs = renumbered(machine.audioOutputs, map) { $0.number } set: { $0.number = $1 }
        case .input: machine.inputs = renumbered(machine.inputs, map) { $0.number } set: { $0.number = $1 }
        }

        // Channels (Spec 1 §2).
        for i in library.channels.indices {
            library.channels[i].defaultPreset = number(library.channels[i].defaultPreset, .preset)
            library.channels[i].defaults.transition = number(library.channels[i].defaults.transition, .transition)
            library.channels[i].defaults.audioTransition = number(library.channels[i].defaults.audioTransition, .audioTransition)
            library.channels[i].audioOutputs = library.channels[i].audioOutputs.map { number($0, .audioOutput) }
        }
        // Presets: per-stack layouts and the boxes' text style, transition and grade.
        for i in library.presets.indices {
            var layouts: [LayoutKey: Layout] = [:]
            for (key, var layout) in library.presets[i].layouts {
                for b in layout.boxes.indices {
                    if let from = layout.boxes[b].textStyle?.fromStyle { layout.boxes[b].textStyle?.fromStyle = number(from, .textStyle) }
                    layout.boxes[b].transition.ref = number(layout.boxes[b].transition.ref, .transition)
                    if let grade = layout.boxes[b].grade { layout.boxes[b].grade = number(grade, .grade) }
                }
                if case .stack(let n) = key {
                    layouts[.stack(number(n, .stack))] = layout
                } else {
                    layouts[key] = layout
                }
            }
            library.presets[i].layouts = layouts
        }
        // Commands in lists, local copies, macros and key bindings; guards too.
        for l in library.lists.indices { for c in library.lists[l].cues.indices { rewrite(&library.lists[l].cues[c].commands) } }
        for l in machine.localLists.indices { for c in machine.localLists[l].cues.indices { rewrite(&machine.localLists[l].cues[c].commands) } }
        for m in library.macros.indices { rewrite(&library.macros[m].commands) }
        for m in machine.macros.indices { rewrite(&machine.macros[m].commands) }
        for k in machine.keys.indices { machine.keys[k].command = machine.keys[k].command.mapReferences(transform) }
        // Index defaults (Spec 1 §7).
        for e in library.mediaIndex.entries.indices {
            if let g = library.mediaIndex.entries[e].defaults.grade { library.mediaIndex.entries[e].defaults.grade = number(g, .grade) }
            if let ch = library.mediaIndex.entries[e].defaults.defaultChannel { library.mediaIndex.entries[e].defaults.defaultChannel = number(ch, .channel) }
        }
        for e in machine.mediaLocal.entries.indices {
            if let g = machine.mediaLocal.entries[e].defaults.grade { machine.mediaLocal.entries[e].defaults.grade = number(g, .grade) }
            if let ch = machine.mediaLocal.entries[e].defaults.defaultChannel { machine.mediaLocal.entries[e].defaults.defaultChannel = number(ch, .channel) }
        }
        // Stacks (Spec 1 §3).
        for s in machine.stacks.indices {
            if let p = machine.stacks[s].defaultPreset { machine.stacks[s].defaultPreset = number(p, .preset) }
            for i in machine.stacks[s].slots.indices {
                machine.stacks[s].slots[i].channel = number(machine.stacks[s].slots[i].channel, .channel)
                if let p = machine.stacks[s].slots[i].preset { machine.stacks[s].slots[i].preset = number(p, .preset) }
            }
        }
        // Outputs, audio outputs, playlists, settings.
        for o in machine.outputs.indices {
            machine.outputs[o].defaultStack = number(machine.outputs[o].defaultStack, .stack)
            if let partner = machine.outputs[o].keyFillPartner { machine.outputs[o].keyFillPartner = number(partner, .output) }
            machine.outputs[o].transitions.switch = number(machine.outputs[o].transitions.switch, .transition)
            machine.outputs[o].transitions.blackout = number(machine.outputs[o].transitions.blackout, .transition)
        }
        for a in machine.audioOutputs.indices {
            if case .sdiOutput(let n) = machine.audioOutputs[a].device { machine.audioOutputs[a].device = .sdiOutput(number(n, .output)) }
        }
        if type == .list {
            for p in machine.playlists.indices {
                for i in machine.playlists[p].items.indices {
                    guard case .linked(_, let listUuid) = machine.playlists[p].items[i].kind,
                          let target = linkTargets[p][i], let to = lists[target] else { continue }
                    machine.playlists[p].items[i].kind = .linked(list: to, listUuid: listUuid)
                }
            }
        }
        machine.settings.thumbnailStack = number(machine.settings.thumbnailStack, .stack)
        if let m = machine.settings.startupMacro { machine.settings.startupMacro = number(m, .macro) }
        if let m = machine.settings.shutdownMacro { machine.settings.shutdownMacro = number(m, .macro) }
    }

    /// Objects renumbered by `map`, back in number order.
    static func renumbered<T>(_ objects: [T], _ map: [Int: Int], number: (T) -> Int, set: (inout T, Int) -> Void) -> [T] {
        var out = objects
        for i in out.indices {
            if let to = map[number(out[i])] { set(&out[i], to) }
        }
        return out.sorted { number($0) < number($1) }
    }
}

/// Spec 1 §4 — "Cue addressing... The two user-facing addresses from the UX
/// spec are both resolved at the moment of use: `list 42 cue 3` through list
/// number and position, `item 4 cue 3` through playlist position and cue
/// position."
public enum CueAddressing {
    public static func cue(list number: Int, cue position: Int, in library: Library) -> Cue? {
        library.list(number: number)?.cue(at: position)
    }

    /// Spec 1 §3 — the list a playlist item names: a linked master by number,
    /// or a local copy by uuid in the machine root (falling back to a master
    /// with that uuid). Headers name none.
    public static func list(forItem item: Int, in playlist: Playlist, library: Library, machine: Machine) -> List? {
        guard item >= 1, item <= playlist.items.count else { return nil }
        return list(for: playlist.items[item - 1].kind, library: library, machine: machine)
    }

    /// Spec 7 §3 — the list an item names: a linked master by its uuid, or by
    /// number when it has none (`Library.list(for:)`), or a local copy by uuid
    /// in the machine root, falling back to a master with that uuid.
    public static func list(for kind: PlaylistItem.Kind, library: Library, machine: Machine) -> List? {
        if case .local(let uuid) = kind { return machine.localList(uuid: uuid) ?? library.list(uuid: uuid) }
        return library.list(for: kind)
    }

    public static func cue(item: Int, cue position: Int, in playlist: Playlist, library: Library, machine: Machine) -> Cue? {
        list(forItem: item, in: playlist, library: library, machine: machine)?.cue(at: position)
    }
}
