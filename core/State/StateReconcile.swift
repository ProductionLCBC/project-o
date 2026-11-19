// OCore — Spec 5 §1 and §2 as corrected 2026-11-18: ShowState's entries
// follow the channels, stacks and outputs the documents have.

import Foundation

extension ShowState {
    /// Spec 5 §1 — "a channel or a stack that an edit makes gets its empty
    /// entry in ShowState, and one that an edit deletes loses it"; §2 — "a
    /// new channel or stack starts with an empty entry in ShowState, a
    /// deleted one's entry goes, and every other entry stays as it was. A
    /// deleted stack's mutes go with it, and a stack's mute of a channel goes
    /// when that channel's slot is removed."
    ///
    /// The state for these roots: every channel and stack the roots have,
    /// each as it was when the state already held it and as
    /// `ShowState.fresh` makes it when it didn't; an output on the stack it
    /// was on while that stack exists, else on its default stack. The
    /// pointer, the armed trigger and the popups are untouched. State is held
    /// by number (Spec 3 §2), so a renumbered channel starts empty under its
    /// new number. A state made for these roots comes back as it is.
    public func reconciled(library: Library, machine: Machine) -> ShowState {
        let fresh = ShowState.fresh(library: library, machine: machine)
        var out = self
        out.channels = fresh.channels.merging(channels.filter { fresh.channels[$0.key] != nil }) { _, held in held }
        out.stacks = [:]
        for stack in machine.stacks {
            var entry = stacks[stack.number] ?? StackState()
            entry.muted = entry.muted.intersection(stack.slots.map(\.channel))
            out.stacks[stack.number] = entry
        }
        out.outputs = [:]
        for output in machine.outputs {
            if let showing = outputs[output.number], machine.stack(showing) != nil {
                out.outputs[output.number] = showing
            } else {
                out.outputs[output.number] = output.defaultStack
            }
        }
        return out
    }
}
