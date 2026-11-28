// OCore — Spec 5 §4 and §6 for stacks, their slots, and an output's default
// stack and transitions (Spec 11 §6, §11). Machine-level, so they pass on a
// `readOnlyMasters` machine (Spec 5 §7).

import Foundation

extension Editor {
    /// Spec 11 §6 — "New Stack (`edit stack create`, with an empty label ...);
    /// Duplicate ...; Renumber…, ... refused while an output shows the stack,
    /// and Swap while an output shows either stack (`onAir`, ...); and
    /// Delete, refused while an output shows the stack (E-7)".
    static var stacks: Shelf<Stack> {
        var rules = ObjectRules<Stack>()
        rules.held = { editor, stack, verb in
            guard let state = editor.live, OnAir.stack(stack.number, state: state, machine: editor.machine) else { return nil }
            return Rejection(reason: .onAir, message: "an output shows stack \(stack.number); switch it to another stack before this one is \(verb)")
        }
        rules.heldPair = { editor, a, b in
            guard let state = editor.live else { return nil }
            return [a, b].first { OnAir.stack($0.number, state: state, machine: editor.machine) }.map {
                Rejection(reason: .onAir, message: "an output shows stack \($0.number); switch it to another stack before the swap")
            }
        }
        rules.settled = { editor, old, stack in
            // Spec 5 §6, check 6 — "a channel within a stack (P13)". A document that came with a channel twice keeps it
            // (Spec 6 §2, "A later slot stays in the document as read"); no edit adds another.
            func repeats(_ slots: [StackSlot]) -> Int { slots.count - Set(slots.map(\.channel)).count }
            if repeats(stack.slots) > (old.map { repeats($0.slots) } ?? 0) {
                let twice = Dictionary(grouping: stack.slots, by: \.channel).filter { $0.value.count > 1 }.keys.sorted()
                throw editor.reject(.duplicate, "stack \(stack.number) already holds channel \(twice.map(String.init).joined(separator: ", ")): a channel appears once per stack")
            }
            if let preset = stack.defaultPreset, preset != old?.defaultPreset, let found = editor.library.preset(preset) {
                editor.warnOfStackDefault(found, stacks: [stack])
            }
        }
        return Shelf(type: .stack, table: EditFields.stack, read: { $0.machine.stacks }, write: { $0.machine.stacks = $1 },
                     fresh: { Stack(number: $0, slots: [], label: "", uuid: $1) }, rules: rules)
    }

    /// Spec 5 §6 — the result warns of "a preset used as a stack default
    /// without a pixel box or a body box at offset 0 (the UX spec's preset
    /// editor)"; Spec 6 §3 — it "counts only boxes at offset 0". The layout
    /// read is the one each stack would draw: its own, else `*`.
    mutating func warnOfStackDefault(_ preset: Preset, stacks: [Stack]) {
        for stack in stacks where stack.defaultPreset == preset.number {
            let boxes = (preset.layout(for: stack.number)?.boxes ?? []).filter { $0.offset == 0 }
            var missing: [String] = []
            if !boxes.contains(where: { $0.binding.kind == .pixels }) { missing.append("no pixel box") }
            if !boxes.contains(where: { $0.binding.kind == .field(name: "body") }) { missing.append("no body box") }
            if !missing.isEmpty {
                warnings.append("preset \(preset.number) is stack \(stack.number)'s default and has \(missing.joined(separator: " and ")) at offset 0")
            }
        }
    }

    // MARK: - A slot (Spec 5 §3: "a slot, named by its channel")

    /// Spec 11 §6 — a slot's preset and opacity (`edit stack S slot C preset
    /// P`, `… opacity 0.8`), its place (`… move K`) and `… remove`. Spec 6 §2
    /// — "An edit that names the channel's slot reaches the first."
    mutating func editSlot(stack number: Int, channel: Int, _ action: EditAction) throws -> (EditCommand, EditCommand?) {
        guard let stack = machine.stack(number) else { throw reject(.unknownObject, "stack \(number) does not exist") }
        guard let index = stack.slots.firstIndex(where: { $0.channel == channel }) else {
            throw reject(.unknownObject, "stack \(number) has no slot for channel \(channel)")
        }
        let address = EditAddress.slot(stack: number, channel: channel)
        let logged = EditCommand(address, action)
        let none: () -> UUID = { UUID() }

        switch action {
        case .set(let path, let value):
            if path == "channel" {
                throw reject(.readOnlyField, "a slot's channel is what names it; remove the slot and insert another")
            }
            let (_, inverse) = try edit(Editor.stacks, number, .set(path: "slots.\(index).\(path)", value: value), makeUUID: none)
            switch inverse?.action {
            case .set(_, let previous)?: return (logged, EditCommand(address, .set(path: path, value: previous)))
            case .unset?: return (logged, EditCommand(address, .unset(path: path)))
            default: return (logged, nil)
            }
        case .unset(let path):
            let (_, inverse) = try edit(Editor.stacks, number, .unset(path: "slots.\(index).\(path)"), makeUUID: none)
            guard case .set(_, let previous)? = inverse?.action else { return (logged, nil) }
            return (logged, EditCommand(address, .set(path: path, value: previous)))
        case .remove(nil, nil):
            // Its inverse is "`edit.insert` of the removed value at its old position".
            let (_, inverse) = try edit(Editor.stacks, number, .remove(path: "slots", at: index), makeUUID: none)
            return (logged, inverse)
        case .move(nil, nil, let at):
            let (_, inverse) = try edit(Editor.stacks, number, .move(path: "slots", from: index, at: at), makeUUID: none)
            guard inverse != nil else { return (logged, nil) }
            return (logged, EditCommand(address, .move(path: nil, from: nil, at: index)))
        default:
            throw reject(.badValue, "\(action.verb) does not apply to a slot" + (action.verb == "delete" ? "; remove it" : ""))
        }
    }

    // MARK: - An output's default stack and transitions (Spec 11 §6)

    /// Spec 11 §6 — "Editable here: its default stack (`edit output N
    /// defaultStack M`), and its switch and blackout transitions (`edit
    /// output N transitions.switch T`, `… transitions.blackout T`)". The
    /// rest of an output is edited in Settings, Area 17's (Spec 10 §16).
    mutating func editOutput(_ number: Int?, _ action: EditAction) throws -> (EditCommand, EditCommand?) {
        guard case .set(let text, _) = action else {
            throw reject(.notInV1, "an output's \(action.verb) comes with Area 17; edit mode edits its default stack and transitions")
        }
        if let first = EditPath(text)?.components.first, EditFields.outputLater.contains(first) {
            throw reject(.notInV1, "an output's \(first) is edited in Settings, which comes with Area 17")
        }
        guard let number, let index = machine.outputs.firstIndex(where: { $0.number == number }) else {
            throw reject(.unknownObject, "output \(number.map(String.init) ?? "") does not exist")
        }
        let address = EditAddress.numbered(.output, number)
        let logged = EditCommand(address, action)
        let part = try editPart(action, table: EditFields.output, tree: encode(machine.outputs[index]), of: "output \(number)", owner: .output)
        guard let inverse = part.inverse else { return (logged, nil) }
        let updated: Output = try read(part.tree, "output \(number)")
        guard updated != machine.outputs[index] else { return (logged, nil) }
        machine.outputs[index] = updated
        changes.append(Editor.changed(.output, number, [part.path]))
        return (logged, EditCommand(address, inverse))
    }
}
