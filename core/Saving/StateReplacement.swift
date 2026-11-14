// OCore — Spec 3 §8, restores: the effects of replacing ShowState wholesale.

import Foundation

/// Spec 3 §8 — "Restores replace ShowState wholesale: in v1 restore-last-state
/// does, from `state/last.json` (Spec 9 §4), and in v1.5 runtime undo does ...
/// The projection is not involved except to re-derive effects: the engine
/// diffs old and new state and synthesizes `transition` effects as cuts,
/// `attribute` effects for every changed attribute, and a `pointer` effect".
public enum StateReplacement {
    /// The effects of going from `old` to `new` in one step, in a fixed
    /// order: each channel in number order (its content as a cut, each
    /// changed attribute, its lock), then the outputs, the stacks' blackout
    /// and mutes, the popups, and last the pointer.
    ///
    /// A cut is a `transition` effect of no duration that names no
    /// transition, so nothing dissolves (Spec 9 §4, "Every change is a cut").
    /// What else the state holds (an output's stack, a stack's blackout and
    /// mutes, a popup's text, a lock) follows as the effect Spec 3 §6 gives
    /// that change, with no transition, so whoever mirrors state hears of it.
    /// The pointer effect is always there, and never arms anything: restores
    /// "always land with `armed` cleared" (Spec 3 §5).
    public static func effects(from old: ShowState, to new: ShowState) -> [Effect] {
        var effects: [Effect] = []
        for number in Set(old.channels.keys).union(new.channels.keys).sorted() {
            let before = old.channels[number]
            guard let after = new.channels[number] else {
                // A channel the new state doesn't have shows nothing.
                if let before, !before.content.isEmpty { effects.append(cut(number, from: before.content, to: .empty)) }
                continue
            }
            let was = before?.content ?? .empty
            if was != after.content { effects.append(cut(number, from: was, to: after.content)) }
            if let before {
                let (a, b) = (before.attributes, after.attributes)
                if a.grade.value != b.grade.value {
                    effects.append(.attribute(channel: number, attribute: .grade, old: .grade(a.grade.value), new: .grade(b.grade.value), ms: nil))
                }
                if a.transition.value != b.transition.value {
                    effects.append(.attribute(channel: number, attribute: .transition, old: .transition(a.transition.value),
                                              new: .transition(b.transition.value), ms: nil))
                }
                if a.audioTransition.value != b.audioTransition.value {
                    effects.append(.attribute(channel: number, attribute: .audioTransition, old: .audioTransition(a.audioTransition.value),
                                              new: .audioTransition(b.audioTransition.value), ms: nil))
                }
                if a.gain.value != b.gain.value {
                    effects.append(.attribute(channel: number, attribute: .gain, old: .gain(a.gain.value), new: .gain(b.gain.value), ms: nil))
                }
                if a.chase.value != b.chase.value {
                    effects.append(.attribute(channel: number, attribute: .chase, old: .chase(a.chase.value), new: .chase(b.chase.value), ms: nil))
                }
            }
            if (before?.lock ?? false) != after.lock {
                effects.append(.applied(.channelLock(channel: .number(number), locked: after.lock)))
            }
        }
        for output in new.outputs.keys.sorted() {
            guard let stack = new.outputs[output], old.outputs[output] != stack else { continue }
            effects.append(.stackSwitch(output: output, old: old.outputs[output] ?? stack, new: stack, transition: nil))
        }
        for number in Set(old.stacks.keys).union(new.stacks.keys).sorted() {
            let before = old.stacks[number] ?? StackState()
            let after = new.stacks[number] ?? StackState()
            if before.blackout != after.blackout {
                effects.append(.blackout(stack: number, old: before.blackout, new: after.blackout, transition: nil))
            }
            for channel in before.muted.symmetricDifference(after.muted).sorted() {
                effects.append(.mute(stack: number, channel: channel, old: before.muted.contains(channel), new: after.muted.contains(channel)))
            }
        }
        for slot in Set(old.popups.keys).union(new.popups.keys).sorted() where old.popups[slot] != new.popups[slot] {
            effects.append(.variable(popup: slot, text: new.popups[slot], clearAfterMs: nil))
        }
        effects.append(.pointer(old: old.pointer, new: new.pointer, armed: nil))
        return effects
    }

    private static func cut(_ channel: Int, from: ContentInstance, to: ContentInstance) -> Effect {
        .transition(TransitionEffect(channel: channel, from: from, to: to, transition: 0, ms: 0, audioTransition: 0, audioMs: 0))
    }
}
