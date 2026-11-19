// OCore — Spec 11 §3 and Spec 1 §4: every place in both roots that names a
// numbered object, with where it is.
//
// One reader for the references `Identity.apply` rewrites: the `uses` query
// lists them (Spec 11 §3), an edit's checks ask whether a number is still
// named (Spec 5 §6, checks 5 and 6), a `create` picks a number past them
// (Spec 5 §4), and a machine-level renumber warns about the portable ones it
// leaves (Spec 5 §4). Pure: the roots in, a list out.

import Foundation

/// Spec 1 §4 — "A reference from one object to another is the target's
/// number, nothing else": one such reference, the object it names and the
/// place that names it.
public struct Reference: Equatable, Sendable {
    public var type: NumberedType
    public var number: Int
    public var site: Site

    public init(_ type: NumberedType, _ number: Int, at site: Site) {
        self.type = type
        self.number = number
        self.site = site
    }

    /// Spec 11 §3 — "a cue entry `listUuid` (or `local`), `list`, `cue`, its
    /// number and its label": the cue a command is in. `number` is the cue's
    /// place in its list, from 1, as people see it (Spec 1 §4).
    public struct CuePlace: Equatable, Sendable {
        public var listUuid: UUID
        public var list: Int
        /// The list is a local copy, in the machine root (Spec 1 §2).
        public var local: Bool
        public var cue: UUID
        public var number: Int
        public var label: String

        public init(listUuid: UUID, list: Int, local: Bool, cue: UUID, number: Int, label: String) {
            self.listUuid = listUuid
            self.list = list
            self.local = local
            self.cue = cue
            self.number = number
            self.label = label
        }
    }

    /// Spec 11 §3 — where a reference is: "A channel, stack, output or
    /// audio-output entry carries its number and the `field` or slot that
    /// refers; a preset entry its `preset` and `layout`; a box entry its
    /// preset, layout and place; a cue entry ...; a macro entry its `macro`
    /// and the command's place; a key entry its `device` and `key`, or a
    /// scheduler entry's place; a media entry its `media` id and `field`; a
    /// machine entry its `field`." Places count from 0, as paths do (Spec 5 §3).
    public enum Site: Equatable, Sendable {
        /// A field of a channel: `defaultPreset`, `defaults.transition`,
        /// `defaults.audioTransition` or `audioOutputs`.
        case channel(Int, field: String)
        /// A field of a stack: `defaultPreset`.
        case stack(Int, field: String)
        /// A slot, named by its channel (Spec 5 §3): its `channel` or its `preset`.
        case slot(stack: Int, channel: Int, field: String)
        /// A preset's layout for a stack, which names that stack by its key.
        case layout(preset: Int, layout: LayoutKey)
        /// A box, by its place in its layout: `textStyle.fromStyle`,
        /// `transition.ref` or `grade`.
        case box(preset: Int, layout: LayoutKey, box: Int, field: String)
        /// A field of an output: `defaultStack`, `transitions.switch`,
        /// `transitions.blackout` or `keyFillPartner`.
        case output(Int, field: String)
        /// A field of an audio output: `device`, when it embeds into an output.
        case audioOutput(Int, field: String)
        /// A command of a cue, its riders, guard and held edit with it.
        case cue(CuePlace, command: Int)
        /// A command of a macro, in the library or the machine root.
        case macro(Int, machineLevel: Bool, command: Int)
        /// A key binding or a scheduler entry, which has no key: its place in
        /// the bindings.
        case key(device: String, key: String?, at: Int)
        /// A media index entry's default, in the library index or the machine's.
        case media(String, machineIndex: Bool, field: String)
        /// A machine setting: `thumbnailStack`, `startupMacro`,
        /// `shutdownMacro` or `dropChannels.KIND`.
        case machine(field: String)

        /// Spec 1 §2 — "Portable objects live in the library and travel
        /// between campuses": whether this place is in a library document.
        /// Spec 5 §4 — a machine-level renumber "leaves portable documents
        /// alone".
        public var isPortable: Bool {
            switch self {
            case .channel, .layout, .box: return true
            case .cue(let place, _): return !place.local
            case .macro(_, let machineLevel, _): return !machineLevel
            case .media(_, let machineIndex, _): return !machineIndex
            case .stack, .slot, .output, .audioOutput, .key, .machine: return false
            }
        }
    }
}

/// Spec 11 §3 — "what refers to a numbered object, counted over both roots'
/// documents on this machine".
public enum References {
    /// Every reference in both roots, in the roots' order: the library's
    /// channels, presets, lists, macros and media index, then the machine's
    /// stacks, outputs, audio outputs, local copies, macros, key bindings,
    /// media index and settings. A reference is listed whether or not the
    /// object it names exists (Spec 1 §8 tolerates a broken one).
    public static func all(library: Library, machine: Machine) -> [Reference] {
        var out: [Reference] = []
        func add(_ type: NumberedType, _ number: Int?, _ site: Reference.Site) {
            if let number { out.append(Reference(type, number, at: site)) }
        }
        func commands(_ entries: [GuardedCommand], _ site: (Int) -> Reference.Site) {
            for (index, entry) in entries.enumerated() {
                let at = site(index)
                _ = entry.command.mapReferences { type, number in
                    out.append(Reference(type, number, at: at))
                    return number
                }
                _ = entry.when?.mapReferences { type, number in
                    out.append(Reference(type, number, at: at))
                    return number
                }
            }
        }
        func cues(of list: List, local: Bool) {
            for (index, cue) in list.cues.enumerated() {
                let place = Reference.CuePlace(listUuid: list.uuid, list: list.number, local: local, cue: cue.uuid, number: index + 1,
                                               label: cue.label)
                commands(cue.commands) { .cue(place, command: $0) }
            }
        }
        func media(_ entries: [MediaEntry], machineIndex: Bool) {
            for entry in entries {
                add(.grade, entry.defaults.grade, .media(entry.id, machineIndex: machineIndex, field: "defaults.grade"))
                add(.channel, entry.defaults.defaultChannel, .media(entry.id, machineIndex: machineIndex, field: "defaults.defaultChannel"))
            }
        }

        // The library (Spec 1 §2).
        for channel in library.channels {
            add(.preset, channel.defaultPreset, .channel(channel.number, field: "defaultPreset"))
            add(.transition, channel.defaults.transition, .channel(channel.number, field: "defaults.transition"))
            add(.audioTransition, channel.defaults.audioTransition, .channel(channel.number, field: "defaults.audioTransition"))
            for output in channel.audioOutputs { add(.audioOutput, output, .channel(channel.number, field: "audioOutputs")) }
        }
        for preset in library.presets {
            for key in preset.layouts.keys.sorted() {
                guard let layout = preset.layouts[key] else { continue }
                if case .stack(let stack) = key { add(.stack, stack, .layout(preset: preset.number, layout: key)) }
                for (index, box) in layout.boxes.enumerated() {
                    add(.textStyle, box.textStyle?.fromStyle, .box(preset: preset.number, layout: key, box: index, field: "textStyle.fromStyle"))
                    add(.transition, box.transition.ref, .box(preset: preset.number, layout: key, box: index, field: "transition.ref"))
                    add(.grade, box.grade, .box(preset: preset.number, layout: key, box: index, field: "grade"))
                }
            }
        }
        for list in library.lists { cues(of: list, local: false) }
        for macro in library.macros { commands(macro.commands) { .macro(macro.number, machineLevel: false, command: $0) } }
        media(library.mediaIndex.entries, machineIndex: false)

        // The machine root (Spec 1 §3).
        for stack in machine.stacks {
            add(.preset, stack.defaultPreset, .stack(stack.number, field: "defaultPreset"))
            for slot in stack.slots {
                add(.channel, slot.channel, .slot(stack: stack.number, channel: slot.channel, field: "channel"))
                add(.preset, slot.preset, .slot(stack: stack.number, channel: slot.channel, field: "preset"))
            }
        }
        for output in machine.outputs {
            add(.stack, output.defaultStack, .output(output.number, field: "defaultStack"))
            add(.transition, output.transitions.switch, .output(output.number, field: "transitions.switch"))
            add(.transition, output.transitions.blackout, .output(output.number, field: "transitions.blackout"))
            add(.output, output.keyFillPartner, .output(output.number, field: "keyFillPartner"))
        }
        for audio in machine.audioOutputs {
            if case .sdiOutput(let output) = audio.device { add(.output, output, .audioOutput(audio.number, field: "device")) }
        }
        for list in machine.localLists { cues(of: list, local: true) }
        for macro in machine.macros { commands(macro.commands) { .macro(macro.number, machineLevel: true, command: $0) } }
        for (index, binding) in machine.keys.enumerated() {
            let at = Reference.Site.key(device: binding.device, key: binding.key, at: index)
            _ = binding.command.mapReferences { type, number in
                out.append(Reference(type, number, at: at))
                return number
            }
        }
        media(machine.mediaLocal.entries, machineIndex: true)
        add(.stack, machine.settings.thumbnailStack, .machine(field: "thumbnailStack"))
        add(.macro, machine.settings.startupMacro, .machine(field: "startupMacro"))
        add(.macro, machine.settings.shutdownMacro, .machine(field: "shutdownMacro"))
        add(.channel, machine.settings.dropChannels?.video, .machine(field: "dropChannels.video"))
        add(.channel, machine.settings.dropChannels?.image, .machine(field: "dropChannels.image"))
        add(.channel, machine.settings.dropChannels?.audio, .machine(field: "dropChannels.audio"))
        return out
    }

    /// Spec 11 §3 — "what refers to a numbered object": the references to
    /// one object, in the roots' order.
    public static func to(_ type: NumberedType, _ number: Int, library: Library, machine: Machine) -> [Reference] {
        all(library: library, machine: machine).filter { $0.type == type && $0.number == number }
    }

    /// Spec 5 §4 — "one more than the highest of that type in use or named by
    /// any reference": every number of a type that anything names.
    public static func numbers(of type: NumberedType, library: Library, machine: Machine) -> Set<Int> {
        Set(all(library: library, machine: machine).filter { $0.type == type }.map(\.number))
    }
}
