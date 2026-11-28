// OCore — Spec 5 §6, check 7: what is on air, for the edits and the restores
// that must leave it alone.

import Foundation

/// Spec 5 §6, check 7 — "An object on air can't be deleted, renumbered or
/// swapped until it is off air, a swap checking both objects, since ShowState
/// holds them by number (Spec 11 §6, §7): a channel with content in a stack
/// that an output shows, a channel whose content has sound and is routed to
/// an audio output this machine has, since the sound would stop (Adam's
/// answer of 2026-11-18), or a stack that an output shows (choice E-7)."
public enum OnAir {
    /// The stacks the outputs show: each output's stack in the state, or its
    /// default stack where the state has none.
    public static func shownStacks(state: ShowState, machine: Machine) -> Set<Int> {
        Set(machine.outputs.map { state.outputs[$0.number] ?? $0.defaultStack })
    }

    /// "a stack that an output shows".
    public static func stack(_ number: Int, state: ShowState, machine: Machine) -> Bool {
        shownStacks(state: state, machine: machine).contains(number)
    }

    /// Whether a channel holds anything.
    public static func hasContent(_ channel: Int, state: ShowState) -> Bool {
        guard let content = state.channels[channel]?.content else { return false }
        return content != .empty
    }

    /// Whether a stack an output shows holds the channel.
    public static func inShownStack(_ channel: Int, state: ShowState, machine: Machine) -> Bool {
        shownStacks(state: state, machine: machine).contains { stack in
            machine.stack(stack)?.slots.contains { $0.channel == channel } ?? false
        }
    }

    /// "a channel with content in a stack that an output shows".
    public static func showing(_ channel: Int, state: ShowState, machine: Machine) -> Bool {
        hasContent(channel, state: state) && inShownStack(channel, state: state, machine: machine)
    }

    /// "a channel whose content has sound and is routed to an audio output
    /// this machine has": media the index says carries audio, on a channel
    /// one of whose audio outputs exists here. Paused or muted, it is still
    /// what the room would lose.
    public static func sounding(_ channel: Int, state: ShowState, library: Library, machine: Machine) -> Bool {
        guard case .media(let media)? = state.channels[channel]?.content,
              let entry = MediaResolver.entry(for: media.ref, library: library.mediaIndex, machine: machine.mediaLocal)?.entry,
              entry.hasAudio || entry.kind == .audio || entry.kind == .audioSet,
              let routed = library.channel(channel)?.audioOutputs else { return false }
        return routed.contains { machine.audioOutput($0) != nil }
    }

    /// Whether a channel is on air: showing or sounding.
    public static func channel(_ channel: Int, state: ShowState, library: Library, machine: Machine) -> Bool {
        showing(channel, state: state, machine: machine) || sounding(channel, state: state, library: library, machine: machine)
    }
}
