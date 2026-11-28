// OCore — Spec 11 §3, the `uses` query's answer: what refers to a numbered
// object, by kind, counted over both roots.

import Foundation

/// Spec 11 §3 — "`uses` lists what refers to a numbered object, counted over
/// both roots' documents on this machine, as `mediaUse` counts media (Spec 8
/// §7)". "`counts` covers everything, per kind; the entries stop at 500 in
/// all, with `more` true beyond."
///
/// Read from `References`, the one reader of every place that names a
/// numbered object, so what `uses` lists is what a renumber rewrites (Spec 1
/// §4) and what an edit's checks count (Spec 5 §6). Pure: the roots in, the
/// answer out.
public struct Uses: Equatable, Sendable {
    /// Spec 11 §3 — "Kinds and entries. `channels`, `stacks`, `presets`,
    /// `boxes`, `outputs`, `audiooutputs`, `cues`, `macros`, `keys` (key
    /// bindings and scheduler entries), `media` and `machine`", in the order
    /// the entries fill to the limit.
    public static let kinds = ["channels", "stacks", "presets", "boxes", "outputs", "audiooutputs", "cues", "macros", "keys", "media", "machine"]

    /// Spec 11 §3 — "Objects: `channel`, `preset`, `textstyle`, `grade`,
    /// `transition`, `audiotransition`, `macro`, `stack`, `output` and
    /// `audiooutput`. Media keep `mediaUse` and lists `listUse`": the name
    /// the query gives each, which is also the member its number is under.
    public static let objects: [String: NumberedType] = [
        "channel": .channel, "preset": .preset, "textstyle": .textStyle, "grade": .grade, "transition": .transition,
        "audiotransition": .audioTransition, "macro": .macro, "stack": .stack, "output": .output, "audiooutput": .audioOutput,
    ]

    /// Spec 11 §3 — "the entries stop at 500 in all".
    public static let limit = 500

    /// Every kind's count, used or not.
    public var counts: [String: Int]
    /// The entries of each kind that has any, in the roots' order, up to the limit over all kinds.
    public var entries: [String: [JSONValue]]
    /// Whether there are more entries than the limit let through.
    public var more: Bool

    /// The answer's fields: `more`, `counts` and `uses`.
    public var fields: [String: JSONValue] {
        ["more": .bool(more),
         "counts": .object(counts.mapValues { .number(Double($0)) }),
         "uses": .object(entries.mapValues { .array($0) })]
    }

    /// Spec 11 §3 — what refers to the object `type` `number`. "A channel,
    /// stack, output or audio-output entry carries its number and the `field`
    /// or slot that refers; a preset entry its `preset` and `layout`; a box
    /// entry its preset, layout and place; a cue entry `listUuid` (or
    /// `local`), `list`, `cue`, its number and its label; a macro entry its
    /// `macro` and the command's place; a key entry its `device` and `key`,
    /// or a scheduler entry's place; a media entry its `media` id and
    /// `field`; a machine entry its `field`." And "for a preset, also the
    /// slots that reach it by fallback (Spec 6 §2), marked `fallback`".
    ///
    /// A slot is named by its channel, as an edit names it (Spec 5 §3). A
    /// layout is `"*"` or its stack's number. A cue is one entry however many
    /// of its commands name the object, as `mediaUse` counts cues; a macro's
    /// commands are an entry each, by place from 0. A number that no object
    /// has is answered for like any other: what still names it is what the
    /// reference report flags (Spec 1 §8).
    public static func of(_ type: NumberedType, _ number: Int, library: Library, machine: Machine, limit: Int = Uses.limit) -> Uses {
        var found: [String: [JSONValue]] = [:]
        // A local copy's cues keep their master's uuids (Spec 1 §2), so a cue is told apart by its list as well.
        var cuesSeen: Set<String> = []
        // Stack entries are kept with their stack, so the slots that reach a preset by fallback sort in beside the rest.
        var stacks: [(stack: Int, entry: JSONValue)] = []
        func n(_ value: Int) -> JSONValue { .number(Double(value)) }
        func layout(_ key: LayoutKey) -> JSONValue {
            if case .stack(let stack) = key { return n(stack) }
            return .string(key.string)
        }

        for reference in References.to(type, number, library: library, machine: machine) {
            switch reference.site {
            case .channel(let channel, let field):
                found["channels", default: []].append(.object(["channel": n(channel), "field": .string(field)]))
            case .stack(let stack, let field):
                stacks.append((stack, .object(["stack": n(stack), "field": .string(field)])))
            case .slot(let stack, let channel, _):
                stacks.append((stack, .object(["stack": n(stack), "slot": n(channel)])))
            case .layout(let preset, let key):
                found["presets", default: []].append(.object(["preset": n(preset), "layout": layout(key)]))
            case .box(let preset, let key, let box, let field):
                found["boxes", default: []].append(.object(["preset": n(preset), "layout": layout(key), "box": n(box), "field": .string(field)]))
            case .output(let output, let field):
                found["outputs", default: []].append(.object(["output": n(output), "field": .string(field)]))
            case .audioOutput(let output, let field):
                found["audiooutputs", default: []].append(.object(["audiooutput": n(output), "field": .string(field)]))
            case .cue(let place, _):
                guard cuesSeen.insert("\(place.local) \(place.listUuid) \(place.cue)").inserted else { continue }
                found["cues", default: []].append(.object([
                    place.local ? "local" : "listUuid": .string(place.listUuid.uuidString.lowercased()), "list": n(place.list),
                    "cue": .string(place.cue.uuidString.lowercased()), "number": n(place.number), "label": .string(place.label),
                ]))
            case .macro(let macro, _, let command):
                found["macros", default: []].append(.object(["macro": n(macro), "command": n(command)]))
            case .key(let device, let key, let at):
                // "a key entry its `device` and `key`, or a scheduler entry's place".
                found["keys", default: []].append(.object(key.map { ["device": .string(device), "key": .string($0)] } ?? ["device": .string(device), "at": n(at)]))
            case .media(let id, _, let field):
                found["media", default: []].append(.object(["media": .string(id), "field": .string(field)]))
            case .machine(let field):
                found["machine", default: []].append(.object(["field": .string(field)]))
            }
        }

        // Spec 6 §2 — "the slot's preset, else the stack's default, else the channel's default, else Preset 1": a
        // slot that draws this preset without naming it. One that names a preset nothing has draws Preset 1.
        if type == .preset {
            for stack in machine.stacks {
                for slot in stack.slots where slot.preset != number {
                    let reached = library.resolvedPreset(slot.preset ?? stack.defaultPreset ?? library.channel(slot.channel)?.defaultPreset)
                    if reached.number == number {
                        stacks.append((stack.number, .object(["stack": n(stack.number), "slot": n(slot.channel), "fallback": .bool(true)])))
                    }
                }
            }
        }
        if !stacks.isEmpty {
            // By stack, each stack's entries in the order found: its own fields and slots, then the fallbacks.
            found["stacks"] = stacks.enumerated().sorted { ($0.element.stack, $0.offset) < ($1.element.stack, $1.offset) }.map(\.element.entry)
        }

        var counts: [String: Int] = [:]
        var entries: [String: [JSONValue]] = [:]
        var room = max(0, limit)
        var more = false
        for kind in kinds {
            let all = found[kind] ?? []
            counts[kind] = all.count
            guard !all.isEmpty else { continue }
            if all.count > room { more = true }
            let kept = Array(all.prefix(room))
            room -= kept.count
            if !kept.isEmpty { entries[kind] = kept }
        }
        return Uses(counts: counts, entries: entries, more: more)
    }
}
