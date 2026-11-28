// OApp — Spec 11 §7, the channel sheet: the channel list, the selected channel and the stacks that hold it, as
// values, and the edits its controls send.

import Foundation
import OCore

/// Spec 11 §7 — one row of the channel list: "each with its number, label,
/// usual content and the stacks that hold it".
public struct ChannelListRow: Equatable, Sendable {
    public var number: Int
    public var label: String
    public var usualContent: UsualContent
    /// The stacks whose slots name it, by number.
    public var stacks: [Int]
}

/// Spec 11 §7 — the channel sheet, worked out from the catalog, the outputs'
/// dots and which channels hold content now.
public struct ChannelPage: Equatable, Sendable {
    public var rows: [ChannelListRow] = []
    public var channel: Channel?
    /// "The right column lists the stacks that hold the channel ..., and Add to Stack ▸ for the others".
    public var holders: [Stack] = []
    public var others: [Stack] = []
    public var audioOutputs: [AudioOutput] = []
    /// The outputs whose live stack holds the selected channel: adding it to a stack or taking it out asks first there.
    public var shownOn: [Int] = []
    /// Whether the selected channel's content is on an output now: "Renumber is refused while the channel has
    /// content in a stack an output shows" (`onAir`, as for Delete).
    public var isOnAir = false

    public init() {}

    /// `content` names the channels that hold content now, from the `channels` topic.
    public static func make(catalog: Catalog, channel number: Int?, dots: [OutputDot], content: Set<Int>) -> ChannelPage {
        var page = ChannelPage()
        let stacks = catalog.stacks.sorted { $0.number < $1.number }
        page.rows = catalog.channels.sorted { $0.number < $1.number }.map { channel in
            ChannelListRow(number: channel.number, label: channel.label, usualContent: channel.usualContent,
                           stacks: stacks.filter { $0.slots.contains { $0.channel == channel.number } }.map(\.number))
        }
        page.audioOutputs = catalog.audioOutputs.sorted { $0.number < $1.number }
        guard let number, let channel = catalog.channels.first(where: { $0.number == number }) else { return page }
        page.channel = channel
        page.holders = stacks.filter { $0.slots.contains { $0.channel == number } }
        page.others = stacks.filter { stack in !stack.slots.contains { $0.channel == number } }
        page.shownOn = Self.shownOn(channel: number, catalog: catalog, dots: dots)
        page.isOnAir = Self.isOnAir(channel: number, catalog: catalog, dots: dots, content: content)
        return page
    }

    /// The outputs presenting a stack that holds the channel.
    static func shownOn(channel: Int, catalog: Catalog, dots: [OutputDot]) -> [Int] {
        let holding = Set(catalog.stacks.filter { $0.slots.contains { $0.channel == channel } }.map(\.number))
        return dots.filter { $0.state != .absent && holding.contains($0.stack) }.map(\.number).sorted()
    }

    /// "the channel has content in a stack an output shows". A channel sounding on an audio output is on air too
    /// (Spec 5 §6); the engine says so when it refuses, as it is the one that knows what sounds.
    public static func isOnAir(channel: Int, catalog: Catalog, dots: [OutputDot], content: Set<Int>) -> Bool {
        content.contains(channel) && !shownOn(channel: channel, catalog: catalog, dots: dots).isEmpty
    }
}

/// Spec 11 §7 — what a channel's Render size is: "largest, or a width and height".
public enum RenderSizeChoice {
    /// The value an edit sends: `"largest"`, or `{"height": H, "width": W}`; nil for a size that isn't one.
    public static func value(largest: Bool, width: String, height: String) -> JSONValue? {
        if largest { return .string("largest") }
        guard let w = Int(width.trimmingCharacters(in: .whitespaces)), let h = Int(height.trimmingCharacters(in: .whitespaces)),
              w > 0, h > 0, w <= 16384, h <= 16384 else { return nil }
        return .object(["width": .number(Double(w)), "height": .number(Double(h))])
    }
}

/// Spec 11 §7 — the edits the channel sheet sends, each one Spec 5 edit.
public enum ChannelEdits {
    private static func edit(_ address: EditAddress, _ action: EditAction) -> Sending {
        Sending([.edit(EditCommand(address, action))])
    }

    /// "Each field is an `edit.set` on commit, apart from the number."
    public static func set(channel: Int, _ path: String, _ value: JSONValue) -> Sending {
        edit(.numbered(.channel, channel), .set(path: path, value: value))
    }

    /// "default gain (decibels, within ±60)", to a tenth.
    public static func gain(channel: Int, decibels: Double) -> Sending {
        set(channel: channel, "defaults.gain", .number((min(60, max(-60, decibels)) * 10).rounded() / 10))
    }

    /// "Changing it sends `edit channel N renumber M` ...; a taken number offers Swap (`swap`)."
    public static func renumber(channel: Int, to number: Int, swap: Bool) -> Sending {
        edit(.numbered(.channel, channel), swap ? .swap(with: number) : .renumber(to: number))
    }

    /// "New Channel (`edit channel create`, with the first-run channels' defaults ...)": the engine gives it them.
    public static func create() -> Sending { edit(.numbered(.channel, nil), .create(body: nil, folder: nil, title: nil)) }

    /// "Duplicate (`edit channel N duplicate`)".
    public static func duplicate(channel: Int) -> Sending { edit(.numbered(.channel, channel), .duplicate(to: nil, title: nil, picks: EditPicks())) }

    /// "Delete".
    public static func delete(channel: Int) -> Sending { edit(.numbered(.channel, channel), .delete) }
}
