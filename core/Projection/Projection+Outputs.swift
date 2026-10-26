// OCore — Spec 3 §6, output, stack and popup commands.

extension Fold {
    func resolve(_ switchState: SwitchState, current: Bool) -> Bool {
        switch switchState {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }

    /// Spec 2 §3 — `output N stack M`: "Switches the output's live stack with
    /// its switch transition." Spec 3 §6 — `stackSwitch` carries "output,
    /// old, new, transition ref". An unknown output or stack is a `noop`.
    mutating func outputStack(_ output: Int, _ stack: Int, command: Command) {
        guard let old = state.outputs[output], context.machine.stack(stack) != nil, old != stack else {
            effects.append(.noop(command))
            return
        }
        state.outputs[output] = stack
        effects.append(.stackSwitch(output: output, old: old, new: stack,
                                    transition: context.machine.output(output)?.transitions.switch))
    }

    /// Spec 2 §3 — `stack N blackout on | off | toggle`: "Mutes every slot
    /// with the output's blackout transition; video only." The transition is
    /// the blackout transition of the first output currently showing the
    /// stack, or nil when no output shows it.
    mutating func stackBlackout(_ stack: Int, _ switchState: SwitchState, command: Command) {
        guard var stackState = state.stacks[stack] else {
            effects.append(.noop(command))
            return
        }
        let new = resolve(switchState, current: stackState.blackout)
        guard new != stackState.blackout else {
            effects.append(.noop(command))
            return
        }
        let old = stackState.blackout
        stackState.blackout = new
        state.stacks[stack] = stackState
        let showing = state.outputs.filter { $0.value == stack }.keys.sorted().first
        effects.append(.blackout(stack: stack, old: old, new: new,
                                 transition: showing.flatMap { context.machine.output($0)?.transitions.blackout }))
    }

    /// Spec 2 §3 — `stack N mute CHANNEL on | off | toggle`: "Mutes one
    /// channel's slot in that stack."
    mutating func stackMute(_ stack: Int, _ channel: Int, _ switchState: SwitchState, command: Command) {
        guard var stackState = state.stacks[stack] else {
            effects.append(.noop(command))
            return
        }
        let old = stackState.muted.contains(channel)
        let new = resolve(switchState, current: old)
        guard new != old else {
            effects.append(.noop(command))
            return
        }
        if new { stackState.muted.insert(channel) } else { stackState.muted.remove(channel) }
        state.stacks[stack] = stackState
        effects.append(.mute(stack: stack, channel: channel, old: old, new: new))
    }

    /// Spec 3 §4 — "Popups write `popups[N]`; the effect is `variable` so
    /// boxes that opted into transitioning on change can do so."
    mutating func popupSet(_ popup: Int, _ text: String, clearAfterMs: Int?, command: Command) {
        guard state.popups[popup] != text else {
            effects.append(.noop(command))
            return
        }
        state.popups[popup] = text
        effects.append(.variable(popup: popup, text: text, clearAfterMs: clearAfterMs))
    }

    /// Spec 2 §3 — `popup N clear`: "Clears the slot."
    mutating func popupClear(_ popup: Int, command: Command) {
        guard state.popups.removeValue(forKey: popup) != nil else {
            effects.append(.noop(command))
            return
        }
        effects.append(.variable(popup: popup, text: nil, clearAfterMs: nil))
    }
}
