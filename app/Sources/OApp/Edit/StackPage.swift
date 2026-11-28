// OApp — Spec 11 §6, the stack editor: the stack, its slots, the outputs, the channels and the audio routing, as values,
// and the edits its controls send.

import Foundation
import OCore

/// Spec 11 §6 — one row of the slot list, top first: "Each row has the
/// channel's number and label, its preset and its opacity".
public struct StackSlotRow: Equatable, Sendable {
    public var channel: Int
    /// The channel's label; empty for a channel number the library doesn't have.
    public var label: String
    /// The slot's own preset; nil is None, "which means the stack's default,
    /// else the channel's, else Preset 1".
    public var preset: Int?
    /// "The row names the preset the slot resolves to" (Spec 6 §2).
    public var resolved: Int
    public var opacity: Double
    /// Its place in the stack's `slots`, which run bottom to top (Spec 1 §2).
    public var index: Int
}

/// Spec 11 §6 — an output in the Outputs column: "its number and label, its
/// live stack, its default stack and its state from the `outputs` topic".
public struct StackOutputRow: Equatable, Sendable {
    public var number: Int
    public var label: String
    public var liveStack: Int
    public var defaultStack: Int
    public var state: OutputDot.State
}

/// Spec 11 §6 — a channel in the Channels column and the audio routing
/// table: "those the selected stack holds marked".
public struct StackChannelRow: Equatable, Sendable {
    public var number: Int
    public var label: String
    public var isHeld: Bool
    public var audioOutputs: [Int]
}

/// Spec 11 §6 — the stack editor, worked out from the catalog and the
/// outputs' dots: the selected stack and its slots, every output, the stacks
/// no output shows, and the library's channels.
public struct StackPage: Equatable, Sendable {
    public var stack: Stack?
    /// Top first: "below, its slots as a vertical list, the bottom slot at the bottom".
    public var slots: [StackSlotRow] = []
    public var outputs: [StackOutputRow] = []
    /// "under "Not on an output", the stacks no output shows".
    public var unshown: [Stack] = []
    public var channels: [StackChannelRow] = []
    public var audioOutputs: [AudioOutput] = []
    /// The outputs showing the selected stack now: adding or removing a slot asks first there.
    public var shownOn: [Int] = []
    /// Every stack, in number order, for the header's picker.
    public var stacks: [Stack] = []

    public init() {}

    public static func make(catalog: Catalog, stack number: Int?, dots: [OutputDot]) -> StackPage {
        var page = StackPage()
        page.stacks = catalog.stacks.sorted { $0.number < $1.number }
        let channels = Dictionary(catalog.channels.map { ($0.number, $0) }, uniquingKeysWith: { first, _ in first })
        page.outputs = catalog.outputs.sorted { $0.number < $1.number }.map { output in
            let dot = dots.first { $0.number == output.number }
            return StackOutputRow(number: output.number, label: output.label, liveStack: dot?.stack ?? output.defaultStack,
                                  defaultStack: output.defaultStack, state: dot?.state ?? .absent)
        }
        let shown = Set(page.outputs.map(\.liveStack))
        page.unshown = page.stacks.filter { !shown.contains($0.number) }
        page.stack = number.flatMap { n in page.stacks.first { $0.number == n } }
        page.audioOutputs = catalog.audioOutputs.sorted { $0.number < $1.number }
        let held = Set(page.stack?.slots.map(\.channel) ?? [])
        page.channels = catalog.channels.sorted { $0.number < $1.number }.map {
            StackChannelRow(number: $0.number, label: $0.label, isHeld: held.contains($0.number), audioOutputs: $0.audioOutputs)
        }
        if let stack = page.stack {
            page.shownOn = page.outputs.filter { $0.liveStack == stack.number }.map(\.number)
            page.slots = stack.slots.enumerated().reversed().map { index, slot in
                // Spec 6 §2 — the slot's preset, else the stack's default, else the channel's, else Preset 1.
                let resolved = slot.preset ?? stack.defaultPreset ?? channels[slot.channel]?.defaultPreset ?? 1
                return StackSlotRow(channel: slot.channel, label: channels[slot.channel]?.label ?? "", preset: slot.preset,
                                    resolved: catalog.presets.contains { $0.number == resolved } ? resolved : 1,
                                    opacity: slot.opacity, index: index)
            }
        }
        return page
    }

    /// The place in `slots` a row dropped above the row at `row` (0 = top) takes, or below the last for `row == count`.
    public func slotIndex(droppedAt row: Int) -> Int {
        max(0, slots.count - max(0, min(row, slots.count)))
    }
}

/// Spec 11 §6 — the edits the stack editor sends, each one Spec 5 edit.
public enum StackEdits {
    private static func edit(_ address: EditAddress, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(address, action))])
    }

    /// "a picker offering None ... or a preset by number and label (`edit stack S slot C preset P`)".
    public static func slotPreset(stack: Int, channel: Int, preset: Int?) -> Sending {
        edit(.slot(stack: stack, channel: channel), .set(path: "preset", value: preset.map { .number(Double($0)) } ?? .null))
    }

    /// "a slider from 0 to 100% (`… opacity 0.8`)".
    public static func slotOpacity(stack: Int, channel: Int, opacity: Double) -> Sending {
        edit(.slot(stack: stack, channel: channel), .set(path: "opacity", value: .number((min(1, max(0, opacity)) * 100).rounded() / 100)))
    }

    /// "Rows drag to a new place (`edit stack S slot C move K`)", K its place in `slots`, from 0 at the bottom.
    public static func moveSlot(stack: Int, channel: Int, to index: Int) -> Sending {
        edit(.slot(stack: stack, channel: channel), .move(path: nil, from: nil, at: index))
    }

    /// "Remove from Stack (`edit stack S slot C remove`)".
    public static func removeSlot(stack: Int, channel: Int) -> Sending {
        edit(.slot(stack: stack, channel: channel), .remove(path: nil, at: nil))
    }

    /// "A channel dragged in ... adds a slot where it lands (`edit stack S insert slots K {"channel": C, "preset": null,
    /// "opacity": 1, "mute": false}`)".
    public static func insertSlot(stack: Int, channel: Int, at index: Int) -> Sending {
        edit(.numbered(.stack, stack), .insert(path: "slots", at: index, value: .object([
            "channel": .number(Double(channel)), "preset": .null, "opacity": .number(1), "mute": .bool(false),
        ])))
    }

    /// "The stack's own fields ... label; base, black or transparent; default preset, None or a preset; and gamma
    /// blend ... Each is an `edit.set`."
    public static func set(stack: Int, _ path: String, _ value: JSONValue) -> Sending {
        edit(.numbered(.stack, stack), .set(path: path, value: value))
    }

    /// "New Stack (`edit stack create`, with an empty label the page shows as "Stack N" until one is typed)".
    public static func create() -> Sending { edit(.numbered(.stack, nil), .create(body: nil, folder: nil, title: nil)) }

    /// "Duplicate (`edit stack S duplicate`)".
    public static func duplicate(stack: Int) -> Sending { edit(.numbered(.stack, stack), .duplicate(to: nil, title: nil, picks: EditPicks())) }

    /// "Renumber…, with swap for a taken number".
    public static func renumber(stack: Int, to number: Int, swap: Bool) -> Sending {
        edit(.numbered(.stack, stack), swap ? .swap(with: number) : .renumber(to: number))
    }

    /// "Delete, refused while an output shows the stack".
    public static func delete(stack: Int) -> Sending { edit(.numbered(.stack, stack), .delete) }

    /// "its default stack (`edit output N defaultStack M`), and its switch and blackout transitions
    /// (`edit output N transitions.switch T`, `… transitions.blackout T`)".
    public static func output(_ number: Int, _ path: String, _ value: Int?) -> Sending {
        edit(.numbered(.output, number), .set(path: path, value: value.map { .number(Double($0)) } ?? .null))
    }

    /// "each cell a checkbox that sends `edit channel N audioOutputs [...]` with the channel's new list ..., keeping
    /// the numbers this machine has no audio output for".
    public static func audioOutputs(channel: Int, current: [Int], output: Int, on: Bool) -> Sending? {
        var list = current.filter { $0 != output }
        if on { list.append(output) }
        list.sort()
        guard list != current.sorted() else { return nil }
        return edit(.numbered(.channel, channel), .set(path: "audioOutputs", value: .array(list.map { .number(Double($0)) })))
    }
}
